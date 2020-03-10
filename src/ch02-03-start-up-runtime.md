ではここからランタイムの動作を見ていきましょう。最初に、ランタイムそのものはいつ起動しているのかを見ていきます。

# ランタイムの起動

そもそもランタイムはいくつも動作させるものではありませんよね？なので、最初に必要になったときだけランタイムを起動して、以後起動したランタイムを参照するようにしたいです。そういった用途では、`once_cell`というライブラリの`Lazy`が使えます。次のコードを見て下さい。

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

  Runtime::new()
}
```

そして、２度目以降の参照では RUNTIME は初期化時のクロージャの返り値として見られます。つまり、最初の参照では、ランタイムの動作用のスレッドが起動され、２度目以降の参照では動作している、`Runtime`への参照になるということです。
Runtime への何かしらの処理(非同期タスクの登録など)はすべてこの RUNTIME 変数から行われるため複数のランタイムを起動してしまうこともありません。また、ランタイムは必要になるまで起動されないので、無駄にリソースを食いつぶすこともありません。

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

TODO: 詳しい説明

```rust
/// 起動すべきMachineのリストを返す関数
fn make_machines(&self) -> Vec<Arc<Machine>> {
    let mut sched = self.sched.lock().unwrap();
    let mut to_start = Vec::new(); // 新しいMachineのリスト

    for m in &mut sched.machines {
        // 動作していないmachineからprocessorを奪う
        // この判定の時時、progressがtrueであってもfalseがセットされるため、
        // 次回にはprocessorが奪われることになる
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

```rust
fn run(&self, rt: &Runtime) {
    const YIELDS: u32 = 3;
    const SLEEPS: u32 = 10;
    const RUNS: u32 = 64;

    let mut runs = 0; // 連続でタスクを実行し続けた回数
    let mut fails = 0; // タスクが見つからずに、何も実行しなかった回数

    loop {
        // machineの状態を動作中に変更
        self.progress.store(true, Ordering::SeqCst);

        // runsが定数RUNSを超えた場合、つまり、1つのタスクを実行し続けている場合
        // 無限にそのタスクを実行し続けるのを防ぐために、別のタスクを実行する
        if runs >= RUNS {
            runs = 0;

            if let Some(p) = self.processor.lock().as_mut() {
                // グローバルタスクキューから非同期タスクを盗む
                if let Steal::Success(task) = p.steal_from_global(rt) {
                    // 盗めた場合、次に実行すべきタスクを盗んだ非同期タスクに切り替える
                    // processorのslotにタスクをセットする
                    p.schedule(rt, task);
                }

                // slotのタスクをprocessorのローカルタスクキューに戻し、別の非同期タスクを実行する
                p.flush_slot(rt);
            }
        }

        // グローバルタスクキューまたはローカルタスクキューからタスクを取り出す
        if let Steal::Success(task) = self.find_task(rt) {
            task.run();
            runs += 1;
            fails = 0;
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

        // One final check for available tasks while the scheduler is locked.
        if let Some(task) = iter::repeat_with(|| self.find_task(rt))
            .find(|s| !s.is_retry())
            .and_then(|s| s.success())
        {
            self.schedule(rt, task);
            continue;
        }

        if sched.polling {
            break;
        }

        let m = match sched
            .machines
            .iter()
            .position(|elem| ptr::eq(&**elem, self))
        {
            None => break, // The processor was stolen.
            Some(pos) => sched.machines.swap_remove(pos),
        };

        sched.polling = true;
        drop(sched);
        rt.reactor.poll(None).unwrap();

        sched = rt.sched.lock().unwrap();
        sched.polling = false;
        sched.machines.push(m);
        sched.progress = true;

        runs = 0;
        fails = 0;
    }

    let opt_p = self.processor.lock().take();

    if let Some(p) = opt_p {
        let mut sched = rt.sched.lock().unwrap();
        sched.processors.push(p);
        sched.machines.retain(|elem| !ptr::eq(&**elem, self));
    }
}

```
