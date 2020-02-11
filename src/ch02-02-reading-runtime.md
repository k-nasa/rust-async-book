# 読んでいきましょう！

では、以下のコードの実装を読んでいきます。

https://github.com/async-rs/async-std/tree/new-scheduler/src/rt

---

ちなみにこのコードに関する議論はこの PR で行われています。

https://github.com/async-rs/async-std/pull/631

---

ここからは Rust のコードがゴリゴリ出てくるので、Rust をやったことがない人にとっては学習コストが上がってくるかと思います。僕も Rust あんまり分からないので一緒に雰囲気で読んでいきましょう！(Rust 詳しい方！間違ったところがあったら教えて下さい！orz)

## Runtime の基本構造

まずは、今回メインとなる Runtime 型の定義を見ていきます。

```rust
pub struct Runtime {
    // リアクター TODO リアクターの説明をする。まだ理解していないので後から書く!!
    reactor: Reactor,

    // グローバルな非同期タスクのキュー
    // キューの中身の型はRunnable
    injector: Injector<Runnable>,

    // 後述するProcessorのローカルキューからタスクをもらうためのハンドラー
    stealers: Vec<Stealer<Runnable>>,

    // スケジューラーの状態
    sched: Mutex<Scheduler>,
}
```

`Runtime`は次のものを持つことが分かります。

- グローバルな非同期タスクのキュー
- 各`Processor`の持つローカルキューからタスクを盗むためのハンドラー(詳細は後述します!)
- リアクター TODO 詳細な説明を書くべきでは？
- スケジューラーの状態

少し、定義時に出てきた型について見ていきましょう。これらはどのようなものなのでしょうか？

### Injector

Runtime の定義に`Injector`という型がありましたね。`Injector`とはなんでしょうか？これは複数のスレッド間で共有できるキューです。今回は主に実行待ちの非同期タスクを保持するために用いられます。(`crossbeam_deque`というクレートのものが使われています。)

(実際に非同期タスクがエンキューされたり、取り出されたりといった処理は後から見ていきましょう)

```rust
use crossbeam_deque::{Injector, Steal};

let q = Injector::new();
q.push(1);
q.push(2);

assert_eq!(q.steal(), Steal::Success(1));
assert_eq!(q.steal(), Steal::Success(2));
assert_eq!(q.steal(), Steal::Empty);

// `steal`でEmpty, Retry, Successのどれかを返す。
// pub enum Steal<T> {
//     Empty,
//     Success(T),
//     Retry,
// }
```

### Runnable

そして、タスクキューは`Runnable`型を保持します。ここではコードは簡略化しますが`Runnable`型は`run`メソッドを持ち、これを実行することで非同期タスクを実際に動かすことが出来ます。

```rust
pub struct Runnable(async_task::Task<Task>);

impl Runnable {
    pub fn run(self) {
      // run task
    }
}
```

### Stealer

次に`Stealer`について見ていきましょう。`Stealer`はキューそのものではなく、キューからタスクを取得するときのためのハンドラーです。

詳細はあとから見ていきますが、各プロセッサーが各々で実行待ちのタスクを保持するローカルキューを持っています。そして、自分のローカルキューからタスクをどんどん消費していきます。しかし、この時、自分のローカルキューからタスクが無くなったらどうなるでしょうか？(すべてのタスクを消費した勤勉なプロセッサーが居た場合ですね。) 他のプロセッサーがせこせこ働いているのに自分だけ休むわけには行きませんよね。実行可能なタスクを見つける方法１つは Runtime が持つグローバルキューからタスクを貰い受けることですね。ではグローバルキューにタスクがない時はどうでしょうか？ この時プロセッサーは他のプロセッサーの実行待ちのタスクを盗みます。 このときに別のプロセッサーからタスクを取得するためのハンドラーが`Stealer`になります。

雑にコード例を貼っておきます、、、

```rust
use crossbeam_deque::{Steal, Worker};

let w = Worker::new_lifo(); //LIFOなキューを初期化
w.push(1);
w.push(2);

let s = w.stealer();
assert_eq!(s.steal(), Steal::Success(1));
assert_eq!(s.steal(), Steal::Success(2));
assert_eq!(s.steal(), Steal::Empty);
```

### Scheduler

これはシンプルにスケジューラーの状態を持つ型です。次のような定義になっています。詳細はここでは考える必要はありませんが、後々のコードを読んでいくときに知っておいたほうが良いので紹介します。

```rust
// スケジューラーの状態
struct Scheduler {
    /// Set to `true` every time before a machine blocks polling the reactor.
    progress: bool,

    /// Set to `true` while a machine is polling the reactor.
    polling: bool,

    /// Idle processors.
    processors: Vec<Processor>,

    /// Running machines.
    machines: Vec<Arc<Machine>>,
}
```

次に`Runtime`の定義で出てきた主要な 3 つの型を見ていきます。`Runtime`はこれらを上手く組み合わせて非同期タスクをを実行するのが仕事になります。

- Reactor
- Machine
- Processor

`Reactor`は後回しにして最初に`Machine`から見てきましょう。

## Machine の基本構造

```rust
// プロセッサーで動作しているスレッド
struct Machine {
    // プロセッサーを保持する。
    // このMachineがアイドル状態の時に他のMachineがプロセッサーを奪う時がある。
    processor: Spinlock<Option<Processor>>,

    /// Gets set to `true` before running every task to indicate the machine is not stuck.
    progress: AtomicBool,
}
```
