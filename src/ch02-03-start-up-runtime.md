ではここからランタイムの動作を見ていきましょう。最初に、ランタイムそのものはいつ起動しているのかを見ていきます。

# ランタイムの起動

```rust
use std::thread;
use once_cell::sync::Lazy;

/// The global runtime.
pub static RUNTIME: Lazy<Runtime> = Lazy::new(|| {
    thread::Builder::new()
        .name("async-std/runtime".to_string())
        .spawn(|| abort_on_panic(|| RUNTIME.run()))
        .expect("cannot start a runtime thread");

    Runtime::new()
});
```
