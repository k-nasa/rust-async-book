# ランタイムの起動と主な動作

ではここからランタイムの動作を見ていきましょう。最初に、ランタイムそのものはいつ起動しているのかを見ていきます。

そもそもランタイムはいくつも動作させるものではありませんよね？なので、最初に必要になったときだけランタイムを起動して、以後起動したランタイムを参照するようにしたいです。そういった用途では、`once_cell`というライブラリの`Lazy`が使えます。次のコードはランタイムの定義です。

```rust
use std::thread;
use once_cell::sync::Lazy;

// グローバルランタイム
// 非同期タスクを登録するときなどに、ランタイムを参照する必要がある。
// この時はすべてこのRUNTIMEを参照することになる。
// このstatic変数RUNTIME以外にRuntimeが作られることはない。
pub static RUNTIME: Lazy<Runtime> = Lazy::new(|| {

    // ネイティブスレッドを一つ起動する。
    // そしてそのスレッドではRUNTIME.run()を実行する。
    // あとで実装を見ていくが、RUNTIME.run()は無限ループするのでこのスレッド上でランタイムは常に動作し続けることになる。
    thread::Builder::new()
        .name("async-std/runtime".to_string())
        .spawn(|| abort_on_panic(|| RUNTIME.run()))
        .expect("cannot start a runtime thread");

    // 今後、RUNTIMEを参照した時はすべてこのオブジェクトを見ることになる。
    // 先程のスレッドが起動されることはない。
    Runtime::new()
});
```

RUNTIME という static 変数を定義しています。この変数は最初に参照されたときに、`Lazy::new`の引数のクロージャが呼び出されます。つまり次の部分です。

```rust
|| {
  thread::Builder::new()
    .name("async-std/runtime".to_string())
    .spawn(|| abort_on_panic(|| RUNTIME.run()))
    .expect("cannot start a runtime thread");

  Runtime::new() //2度目以降の参照ではこのオブジェクトが参照される
}
```

そして、２度目以降の参照では RUNTIME は初期化時のクロージャの返り値として見られます。つまり、最初の参照では、ランタイムの動作用のスレッドが起動され、２度目以降の参照では動作している、`Runtime`への参照になるということです。Runtime への何かしらの処理(非同期タスクの登録など)はすべてこの RUNTIME 変数から行われるため複数のランタイムを起動してしまうこともありません。また、ランタイムは必要になるまで起動されないので、無駄にリソースを食いつぶすこともありません。

## Runtime::new

では、起動時の非同期ランタイムの持つ情報は初期状態でどの様になっているのでしょうか？次のコードは Runtime のコンストラクタです。

```rust
pub fn new() -> Runtime {
    let cpus = num_cpus::get().max(1);

    // cpuのコア数文だけ、Processorを生成する。
    let processors: Vec<_> = (0..cpus).map(|_| Processor::new()).collect();

    // 各々のProcessorが持つローカルタスクキューから非同期タスクを取得するためのハンドラーを作っておく。
    let stealers = processors.iter().map(|p| p.worker.stealer()).collect();

    Runtime {
        reactor: Reactor::new().unwrap(),

        // グローバルタスクキューは初期化時は空
        injector: Injector::new(),
        stealers,
        sched: Mutex::new(Scheduler {
            processors,

            // 前節で紹介したとおり、Machineは非同期タスクを実行するために起動するOSスレッドの抽象化である。
            // 初期化時点では実行すべき非同期タスクは1つもないため、実行用のスレッドを起動する必要もない。
            // そのため、machinesは空のベクターでよい。
            // あとから見ていきますが、このmachinesは既存のスレッド数では非同期タスクを処理しきれなくなったときに、その都度作られます。
            machines: Vec::new(),

            progress: false,
            polling: false,
        }),
    }
}
```

次にランタイム用スレッドでは実際にどのような処理が行われているかを見ていきましょう。コードで言うと`RUNTIME.run()`の部分です。ここを見ていきましょう！

## RUNTIME.run()

コードは多少簡略化していますが、次のようになっています。このコードは一気に読むには少し多いので、ポイントに絞って簡略化したコードをもとに説明していきます。小分けの説明をした後にこのコードに戻ってくるとスルスルっと理解できるはずです。

```rust
pub fn run(&self) {
    scope(|s| {
        // スリープ時間のもとになるカウンター
        // ループの最後の方で使用している
        let mut idle = 0;

        // スリープする時間
        let mut delay = 0;

        loop {
            // make_machinesは必要になるmachineのリストを返す
            for m in self.make_machines() {
                idle = 0; // カウンターを初期化

                // 非同期タスク実行用のスレッドを1つ起動する
                s.builder()
                    .name("async-std/machine".to_string())
                    .spawn(move |_| {
                        abort_on_panic(|| {
                            // Machine::runメソッドを呼び出す。
                            // 詳細な動作は後で見ていきましょう！
                            m.run(self);
                        })
                    })
                    .expect("cannot start a machine thread");
            }

            if idle > 10 {
                // 10回以上何もせずにループしていた場合、
                // 次のループ以降のスリープ時間を2倍ずつ増やしていく
                // このときに最大スリープ時間は10,000マイクロ秒としている(10ミリ秒)
                delay = (delay * 2).min(10_000);
            } else {
                // ループのたびにidelをインクリメントする
                idle += 1;

                // idelが10に満たないときはスリープ時間は一律で1,000マイクロ秒となる(1ミリ秒)
                delay = 1000;
            }

            // 指定されたマイクロ秒分だけスリープする
            thread::sleep(Duration::from_micros(delay));
        }
    })
    .unwrap();
}
```

次のコードはランタイムの動作を一時的に止める`sleep`処理のところのみを取り出しました。

```rust
if idle > 10 {
    // 10回以上何もせずにループしていた場合、
    // 次のループ以降のスリープ時間を2倍ずつ増やしていく
    // このときに最大スリープ時間は10,000マイクロ秒としている(10ミリ秒)
    delay = (delay * 2).min(10_000);
} else {
    // ループのたびにidelをインクリメントする
    idle += 1;

    // idelが10に満たないときはスリープ時間は一律で1,000マイクロ秒となる(1ミリ秒)
    delay = 1000;
}

// 指定されたマイクロ秒分だけスリープする
thread::sleep(Duration::from_micros(delay));
```

ランタイムは無限ループで動作しています。そして、新しく Machine を生成するべきかを毎回判断しています。そのため、新しく machine を作る必要がない状態が続いた場合 cup を無駄に消費し続けることになります。なので、毎回ループの最後にスリープ処理をはさみ、スリープ時間は何もしなかった回数(idel)に応じて増加していくという方式をとっています。

次に残りの部分を見ていきましょう。

```rust
pub fn run(&self) {
    loop {
        // make_machinesは必要になるmachineのリストを返す
        for m in self.make_machines() {
            idle = 0; // idelカウンターを初期化

            // 非同期タスク実行用のスレッドを1つ起動する
            s.builder()
                .name("async-std/machine".to_string())
                .spawn(move |_| {
                    abort_on_panic(|| {
                        // Machine::runメソッドを呼び出す。
                        // 詳細な動作は後で見ていきましょう！
                        m.run(self);
                    })
                })
                .expect("cannot start a machine thread");
        }

        // 先ほど説明したスリープ処理が入る
    }
}
```

まず、`make_machines`で必要な個数分の machine のリスト返します。そして、その個数分の非同期タスク実行用のスレッドを起動します。その中で、実行すべき非同期タスクの見つけ、実行しています。

ここまでで、ランタイムの起動時の説明は以上です。
次からは必要になる machine 数を判定する`make_machines`と実際にタスクを処理していく`Machine::run`の動作を見ていきましょう。

## make_machines

make_machines を呼び出すことで、必要なときに必要な文だけ Machine(os thread)を起動させることが出来ます。また、必要なくなった Machine が持っている processor(実行権限)を奪い、他の Machine に割り当てることで不必要にリソースを使わなくて済むようにしています。

```rust
/// 起動すべきMachineのリストを返す関数
fn make_machines(&self) -> Vec<Arc<Machine>> {
    let mut sched = self.sched.lock().unwrap();
    let mut to_start = Vec::new(); // 新しいMachineのリスト

    for m in &mut sched.machines {
        // 動作していないmachineからprocessorを奪う
        // この判定の時progressがtrueであってもfalseがセットされるため、
        // 次にmake_machinesが呼び出されるとprocessorを奪われる可能性がある
        // ただし、machineは動作時に自身のprogressをtrueにするため、必ずprocessorを奪われるわけではない
        if !m.progress.swap(false, Ordering::SeqCst) {
            // processorにNoneをセットして、processorを奪う
            let opt_p = m.processor.try_lock().and_then(|mut p| p.take());

            if let Some(p) = opt_p {
                // 奪ったprocessorを使用して新しいMachineを作る
                *m = Arc::new(Machine::new(p));
                to_start.push(m.clone());
            }
        }
    }

    if !sched.polling && !sched.progress {
        // processorリストから一つ取り出す
        // 取り出せない時(リストが空の時)は何もしない
        if let Some(p) = sched.processors.pop() {
            let m = Arc::new(Machine::new(p));
            to_start.push(m.clone());
            sched.machines.push(m);
        }

        sched.progress = false;
    }

    to_start
}
```

## Machine::run (簡易版)

では今から async-std ランタイムの心臓部である`Machine::run`のコードを呼んでいきます。コード行数としては 100 行を超えるため、最初は面を喰らうかもしれません。ただ一つ一つの処理では難しいことはしていません。初見では理解できなくても数回読んでみることで理解できるはずです。なので共に頑張って読んでいきましょう！

```rust
fn run(&self, rt: &Runtime) {
    const YIELDS: u32 = 3;
    const SLEEPS: u32 = 10;

    let mut fails = 0; // タスクが見つからずに、何も実行しなかった回数

    loop {
        // machineの状態を動作中に変更
        self.progress.store(true, Ordering::SeqCst);

        // 実行すべき非同期タスクを探す
        // この時のタスクを探す順序としては次のようになっている
        // 1. このmachineの持つprocessorのローカルタスクキュー
        // 2. ランタイムの持つグローバルタスクキュー
        // 3. 他のprocessorのローカルタスクキューから盗む
        if let Steal::Success(task) = self.find_task(rt) {
            task.run();

            fails = 0; // タスクを実行したので、何も実行しなかったカウントを初期化する

            continue;
        }

        fails += 1; // タスクを実行しなかった回数をインクリメント

        if fails <= YIELDS {
            // 連続で実行すべきタスクが見つからなかった回数がYIELDS未満の時
            // このスレッドをしばらくの間実行しないことをOSスケジューラーに伝える
            thread::yield_now();
            continue;
        }

        // 更に、連続でタスクが見つからなかった場合
        // しばらくの間スリープします
        if fails <= YIELDS + SLEEPS {
            // 他のMachineにprocessorを盗まれないようにロックを保持
            let opt_p = self.processor.lock().take();

            thread::sleep(Duration::from_micros(10)); // 10μsスリープ
            *self.processor.lock() = opt_p;
            continue;
        }

        // 以下、更に連続でタスクが見つからなかった場合

        let mut sched = rt.sched.lock().unwrap();

        let m = match sched
            .machines
            .iter()
            .position(|elem| ptr::eq(&**elem, self)) // schedのmachineリストに現在実行しているmachineがあるか
        {
            None => break, // 無いなら、processorを盗まれているため、ループを終了してこのmachineに紐づくスレッドを閉じる
            Some(pos) => sched.machines.swap_remove(pos),
        };

        sched.polling = true;
        drop(sched); // schedをdropすることによって取得したロックを解放している

        // reactorをpollしてI/Oイベントによってブロックされた非同期タスクが再開可能かどうかを問い合わせる。
        // 引数としてtimeout時間を渡している。このときNoneを渡しているためtimeout時間は指定されていない
        // つまり、何かしらの非同期タスクが再開可能になるもしくは新しい非同期タスクが生成されるまでこのMachineの動作はブロックする。
        rt.reactor.poll(None).unwrap();

        sched = rt.sched.lock().unwrap();
        sched.polling = false;
        sched.machines.push(m);
        sched.progress = true;

        fails = 0;
    }

    // ループ終了後の処理
    // つまり、Machineに紐づくスレッドが閉じられるときの前処理を実行する

    let opt_p = self.processor.lock().take();

    // このmachineの持つprocessorをschedulerのprocessorリストに戻す
    // その後、schedulerの持つmachineリストからこのMachineを削除する
    if let Some(p) = opt_p {
        let mut sched = rt.sched.lock().unwrap();
        sched.processors.push(p);
        sched.machines.retain(|elem| !ptr::eq(&**elem, self));
    }
}
```

ここまででランタイムの大まかな処理は終わりです。
長いことお疲れさまでした！
