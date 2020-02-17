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

では、起動時の非同期ランタイムの持つ情報は初期状態でどの様になっているのでしょうか？次のコードはRuntimeのコンストラクタです。

```rust
pub fn new() -> Runtime {
    let cpus = num_cpus::get().max(1);
    let processors: Vec<_> = (0..cpus).map(|_| Processor::new()).collect();
    let stealers = processors.iter().map(|p| p.worker.stealer()).collect();

    Runtime {
        reactor: Reactor::new().unwrap(),
        injector: Injector::new(),
        stealers,
        sched: Mutex::new(Scheduler {
            processors,
            machines: Vec::new(),
            progress: false,
            polling: false,
        }),
    }
}
```

次にランタイム用スレッドでは実際にどのような処理が行われているかを見ていきましょう。コードで言うと`RUNTIME.run()`の部分です。ここを見ていきましょう！

## RUNTIME.run()


```rust
pub fn run(&self) {
    scope(|s| {
        let mut idle = 0;
        let mut delay = 0;

        loop {
            // Get a list of new machines to start, if any need to be started.
            for m in self.make_machines() {
                idle = 0;

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

            // Sleep for a bit longer if the scheduler state hasn't changed in a while.
            if idle > 10 {
                delay = (delay * 2).min(10_000);
            } else {
                idle += 1;
                delay = 1000;
            }

            thread::sleep(Duration::from_micros(delay));
        }
    })
    .unwrap();
}
```
