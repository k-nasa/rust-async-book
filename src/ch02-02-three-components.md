では、以下のコードの実装を読んでいきます。

https://github.com/async-rs/async-std/tree/new-scheduler/src/rt/runtime.rs

---

ちなみにこのコードに関する議論はこの PR で行われています。

https://github.com/async-rs/async-std/pull/631

---

ここからは Rust のコードがゴリゴリ出てくるので、Rust をやったことがない人にとっては学習コストが上がってくるかと思います。ともに頑張りましょう！

# 主要なコンポーネントの基本構造

この節では主要なコンポーネントの基本構造を見ていきます。Runtime は主要な３つのコンポーネントを上手く組み合わせて非同期タスクをを実行するのが仕事になります。なので、最初にそれぞれのコンポーネントの基本的な構造や役割を説明していきます。これから説明していくコンポーネントはランタイムを含め次の 4 つです。

- Runtime
- Machine
- Processor
- Reactor

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

Runtime の定義に`Injector`という型がありましたね。`Injector`とはなんでしょうか？これは複数のスレッド間で共有できるキューです。今回は主に実行待ちの非同期タスクを保持するために用いられます。

実際にランタイムが非同期タスクが保持したり、取り出したりといった動作は後から見ていきましょう。

```rust
// Injectorのコード例
// pushやstealで出し入れを行う

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

タスクキューは`Runnable`型を保持します。ここではコードは簡略化しますが`Runnable`型は`run`メソッドを持ち、これを実行することで非同期タスクを実際に動かすことが出来ます。

```rust
pub struct Runnable(async_task::Task<Task>);

impl Runnable {
    pub fn run(self) {
      // run task
      // TODO ここで端折らずに説明しても良いかも知れない。 -> 自分が理解しきってないのでここでは説明できないが
    }
}
```

### Stealer

次に`Stealer`について見ていきましょう。`Stealer`はキューそのものではなく、キューからタスクを取得するときのためのハンドラーです。

詳細はあとから見ていきますが、各プロセッサーが各々で実行待ちのタスクを保持するローカルキューを持っています。そして、自分のローカルキューからタスクをどんどん消費していきます。しかし、この時、自分のローカルキューからタスクが無くなったらどうなるでしょうか？(すべてのタスクを消費した勤勉なプロセッサーが居た場合ですね。) 他のプロセッサーがせこせこ働いているのに自分だけ休むわけには行きませんよね。実行可能なタスクを見つける方法の１つは Runtime が持つグローバルキューからタスクを貰い受けることですね。ではグローバルキューにタスクがない時はどうでしょうか？ この時プロセッサーは他のプロセッサーの実行待ちのタスクを盗みます。 このときに別のプロセッサーからタスクを取得するためのハンドラーが`Stealer`になります。

主な使い方としては`Injector`と変わりませんが一応コード例を紹介しておきます。

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

これはシンプルにスケジューラーの状態を持つ型です。次のような定義になっています。詳細はここでは考える必要はありませんが、後々のコードを読んでいくときにどのような状態を持っていくか知っておいたほうが良いので紹介します。

TODO もっと詳しく

```rust
// スケジューラーの状態
struct Scheduler {
    /// Set to `true` every time before a machine blocks polling the reactor.
    progress: bool,

    /// Set to `true` while a machine is polling the reactor.
    polling: bool,

    //アイドル状態のプロセッサーリスト
    processors: Vec<Processor>,

    // 動作しているMachineリスト(Machineはスレッドのことだと思って差し支えない)
    machines: Vec<Arc<Machine>>,
}
```

次に`Runtime`の定義で出てきた主要な 3 つのコンポーネントを見ていきます。
おさらいすると次の３つでしたね。

- Machine
- Processor
- Reactor

`Machine`から見てきましょう。

## Machine の基本構造

```rust
// プロセッサーで動作しているスレッド
struct Machine {
    // プロセッサーを保持する。
    // このMachineがアイドル状態の時に他のMachineがプロセッサーを奪う時がある
    processor: Spinlock<Option<Processor>>,

    // タスクを実行するたびにtrueがセットされる
    progress: AtomicBool,
}
```

OS スレッドに付き一つの Machine があります。これはスレッドが起動する時、停止するときも連動して、Machine の生成、破棄が行われます。つまり、OS スレッドの個数分の Machine オブジェクトを Runtime が管理しています。すこし`processor`の定義について見ていきましょう。`processor`は`Spinlock`という型でラップされた`Option<Processor>`です。 Processor というのはここでは実行権を持つか持たないかを表すものだと考えていいでしょう。Machine に Processor が割り当てられていないとき(つまり processor が None のとき)は Machine は非同期タスクの実行権を持ちません。ランタイムは実行開始時に、いくつかの Processor オブジェクトを持ちます。現状では Processor の数は cpu のコア数分です。この Processor オブジェクトを実行したい Machine に割り当てることによって、cpu のコア数より大幅に大きい数の Machine が走らないように数を制限しています。 Machine は OS スレッドにつき 1 つなので、cpu のコア数より大幅に大きい数の Machine が走らないということは、OS スレッドが多分に作られないということでもあります。

また、progress が false になっている Machine(動作中ではないスレッド)は Processor(実行権) を他の Machine に移譲します。この Processor の移譲処理はランタイムが行っています。

### コラム Option 型の説明を少々

Rust をやったことがない方のために`Option`型を説明します。`Option`型は他の言語風に言うなら Null 許容型です。実装としては次のようなただの enum 型です。
null のある言語であれば、値がない時(例えば DB への検索で、検索条件にマッチするレコードが無かったとき)に null を使えばよいのですが、Rust には null に相当する値はありません。
なので、値がない可能性がある場合には`Option`型を使います。

```rust
pub enum Option<T> {
    // 値がない時
    None,

    // 値がある時、`T`型をSomeでラップして返す。
    // `T`型は何でも良い
    Some(T),
}

```

### コラム スピンロック(Spinlock)とは

ここからはスピンロックの具体的な実装を見ていきますが、ランタイムの仕組みとは**ほとんど関係ありません！**なので、興味のない人は読み飛ばしても大丈夫です。この説の内容を知っていなくても本書は最後まで読み進められるように設計されているのでご安心を。

スピンロックは名前の通り、ロックの一種です。ロックが獲得できない間、単純に無限ループ(スピン)によってロックの獲得を待つような仕組みです。これは一種のビジーウェイト状態を発生させるため、ロック待ち時間が長くなると CPU を無駄に消費してしまう場合があります。

スピンロックの具体的な実装は次のようになってます(すこし簡略化しています。)

```rust
pub struct Spinlock<T> {
    // ロックされていない(false) or ロックされている(true)
    // (余談ですが、flagというフィールド名ではなくlockedなどに変更したほうが分かりやすいのではないかと思います。)
    flag: AtomicBool,

    // 保持するデータ
    value: UnsafeCell<T>,
}

// Spinlockはスレッドセーフであると宣言する
unsafe impl<T: Send> Send for Spinlock<T> {}
unsafe impl<T: Send> Sync for Spinlock<T> {}

impl<T> Spinlock<T> {
    // コンストラクタ
    pub const fn new(value: T) -> Spinlock<T> {
        Spinlock {
            flag: AtomicBool::new(false),
            value: UnsafeCell::new(value),
        }
    }

    // ロックを試みる
    pub fn lock(&self) -> SpinlockGuard<'_, T> {
        let backoff = Backoff::new();

        // flagがtrueの場合(他によってロックされている場合)は無限にループを続ける
        // falseの時はflagにtrueをセットしてループから抜ける。
        // 値の確認と値の変更は一気にやらないと競合状態が発生してしまう。
        // そのため`swap`を使用している。
        while self.flag.swap(true, Ordering::Acquire) {
            // TODO ここの意味がわかってないので調べる
            backoff.snooze();
        }

        SpinlockGuard { parent: self }
    }
}

// ロックを保持するガード
pub struct SpinlockGuard<'a, T> {
    parent: &'a Spinlock<T>,
}

// デストラクタ
impl<'a, T> Drop for SpinlockGuard<'a, T> {
    fn drop(&mut self) {
        // ロックの開放時は単にflagをfalseにする。
        self.parent.flag.store(false, Ordering::Release);
    }
}

impl<'a, T> Deref for SpinlockGuard<'a, T> {
    type Target = T;

    fn deref(&self) -> &T {
        unsafe { &*self.parent.value.get() }
    }
}

impl<'a, T> DerefMut for SpinlockGuard<'a, T> {
    fn deref_mut(&mut self) -> &mut T {
        unsafe { &mut *self.parent.value.get() }
    }
}
```

TODO Atomic 変数やメモリ順序についての説明を余裕があったら書く。

## Processor の基本構造

それでは本題に戻りましょう。先程までに Machine の基本構造を見ていきましたね。次に Processor の基本構造を見ていきましょう。

```rust
struct Processor {
    // ローカルタスクキュー
    worker: Worker<Runnable>,

    // 次に実行すべき非同期タスクを保持する
    slot: Option<Runnable>,
}
```

グローバルキューだけで非同期タスクを管理するようにしてしまうと、複数の Processor がグローバルキューから非同期タスクを取り出そうとしたときに競合状態が発生してしまいます。そのため、各々の Processor が実行すべき非同期タスクをローカルタスクキューに保持していく形となっています。また、ローカルキューをスキップする最適化として、slot に次に実行する非同期タスクを保持しています。

## Reactor

TODO Reactor の説明を書く

```rust
/// The state of a networking driver.
pub struct Reactor {
    /// A mio instance that polls for new events.
    poller: mio::Poll,

    /// A list into which mio stores events.
    events: Mutex<mio::Events>,

    /// A collection of registered I/O handles.
    entries: Mutex<Slab<Arc<Entry>>>,

    /// Dummy I/O handle that is only used to wake up the polling thread.
    notify_reg: (mio::Registration, mio::SetReadiness),

    /// An identifier for the notification handle.
    notify_token: mio::Token,
}

/// Data associated with a registered I/O handle.
#[derive(Debug)]
struct Entry {
    /// A unique identifier.
    token: mio::Token,

    /// Tasks that are blocked on reading from this I/O handle.
    readers: Mutex<Vec<Waker>>,

    /// Tasks that are blocked on writing to this I/O handle.
    writers: Mutex<Vec<Waker>>,
}
```
