# ランタイムの起動と主な動作

ではここからランタイムの動作を見ていきましょう。最初に、ランタイムそのものはいつ起動しているのかを見ていきます。

そもそもランタイムはいくつも動作させるものではありませんよね？なので、最初に必要になったときだけランタイムを起動して、以後起動したランタイムを参照するようにしたいです。そういった用途では、`once_cell`というクレートの`Lazy`が使えます。次のコードはランタイムの定義です。

```rust
use std::thread;
use once_cell::sync::Lazy;

// グローバルランタイム
// 非同期タスクを登録するときなどに、ランタイムを参照する必要がある。
// この時はすべてこのRUNTIMEを参照することになる。
// このstatic変数RUNTIME以外にRuntimeが作られることはない。
pub static RUNTIME: Lazy<Runtime> = Lazy::new(|| {

    // スレッドを一つ起動する。
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
    let processors: Vec<_> = (0..cpus).map(|_| Processor::new()).collect();

    let machines: Vec<_> = processors
        .into_iter()
        .map(|p| Arc::new(Machine::new(p)))
        .collect();

    let stealers = machines
        .iter()
        .map(|m| m.processor.lock().worker.stealer())
        .collect();

    Runtime {
        reactor: Reactor::new().unwrap(),
        injector: Injector::new(),
        stealers,
        machines,
        sched: Mutex::new(Scheduler { polling: false }),
    }
}
```

次にランタイム用スレッドでは実際にどのような処理が行われているかを見ていきましょう。コードで言うと`RUNTIME.run()`の部分です。ここを見ていきましょう！

## RUNTIME.run()

コードは多少簡略化していますが、次のようになっています。このコードは一気に読むには少し多いので、ポイントに絞って簡略化したコードをもとに説明していきます。小分けの説明をした後にこのコードに戻ってくるとスルスルっと理解できるはずです。

```rust
pub fn run(&self) {
    scope(|s| {
        for m in &self.machines {
            s.builder()
                .name("async-std/machine".to_string())
                .spawn(move |_| {
                    abort_on_panic(|| {
                        let _ = MACHINE.with(|machine| machine.set(m.clone()));
                        m.run(self);
                    })
                })
                .expect("cannot start a machine thread");
        }
    })
    .unwrap();
}
```

## Machine::run

では今から async-std ランタイムの心臓部である`Machine::run`のコードを呼んでいきます。コード行数としては 100 行を超えるため、最初は面を喰らうかもしれません。ただ一つ一つの処理では難しいことはしていません。初見では理解できなくても数回読んでみることで理解できるはずです。なので共に頑張って読んでいきましょう！

```rust
fn run(&self, rt: &Runtime) {
    /// Number of yields when no runnable task is found.
    const YIELDS: u32 = 3;
    /// Number of short sleeps when no runnable task in found.
    const SLEEPS: u32 = 10;
    /// Number of runs in a row before the global queue is inspected.
    const RUNS: u32 = 64;

    // The number of times the thread found work in a row.
    let mut runs = 0;
    // The number of times the thread didn't find work in a row.
    let mut fails = 0;

    loop {
        // Check if `task::yield_now()` was invoked and flush the slot if so.
        YIELD_NOW.with(|flag| {
            if flag.replace(false) {
                self.processor.lock().flush_slot(rt);
            }
        });

        // After a number of runs in a row, do some work to ensure no task is left behind
        // indefinitely. Poll the reactor, steal tasks from the global queue, and flush the
        // task slot.
        if runs >= RUNS {
            runs = 0;
            rt.quick_poll().unwrap();

            let mut p = self.processor.lock();
            if let Steal::Success(task) = p.steal_from_global(rt) {
                p.schedule(rt, task);
            }

            p.flush_slot(rt);
        }

        // Try to find a runnable task.
        if let Steal::Success(task) = self.find_task(rt) {
            task.run();
            runs += 1;
            fails = 0;
            continue;
        }

        fails += 1;

        // Yield the current thread a few times.
        if fails <= YIELDS {
            thread::yield_now();
            continue;
        }

        // Put the current thread to sleep a few times.
        if fails <= YIELDS + SLEEPS {
            thread::sleep(Duration::from_micros(10));
            continue;
        }

        // One final check for available tasks while the scheduler is locked.
        if let Some(task) = iter::repeat_with(|| self.find_task(rt))
            .find(|s| !s.is_retry())
            .and_then(|s| s.success())
        {
            self.schedule(rt, task);
            continue;
        }

        let mut sched = rt.sched.lock().unwrap();

        if sched.polling {
            thread::sleep(Duration::from_micros(10));
            continue;
        }

        sched.polling = true;
        drop(sched);

        rt.reactor.poll(None).unwrap();

        let mut sched = rt.sched.lock().unwrap();
        sched.polling = false;

        runs = 0;
        fails = 0;
    }
}
```

ここまででランタイムの大まかな処理は終わりです。
長いことお疲れさまでした！
