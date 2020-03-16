# 非同期タスクの起動

では次に非同期タスクがどのようにランタイムに登録されるのかを見ていきましょう！非同期タスクは次のようなコードで起動することが出来ます。この節ではこの`spawn`関数を呼び出すとどのような動作をしてランタイムのタスクキューに格納されるのかを見ていきます。

```rust
let handle = task::spawn(async {
    1 + 2
});

assert_eq!(handle.await, 3);
```

## spawn

では早速`spawn`関数を見ていきましょう。この関数自体は非同期タスクの抽象化である`Future`を引数として受け取り、`Builder`構造体を作っています。

```rust
pub fn spawn<F, T>(future: F) -> JoinHandle<T>
where
    F: Future<Output = T> + Send + 'static,
    T: Send + 'static,
{
    Builder::new().spawn(future).expect("cannot spawn task")
}
```

## Builder::spawn

では次に`Builder`のコードを読んできましょう。

```rust
pub struct Builder {
    pub(crate) name: Option<String>,
}

impl Builder {
    pub fn new() -> Builder {
        Builder { name: None }
    }

    pub fn spawn<F, T>(self, future: F) -> io::Result<JoinHandle<T>>
    where
        F: Future<Output = T> + Send + 'static,
        T: Send + 'static,
    {
        let task = Task::new(self.name);

        let future = async move {
            // タスクが完了したときにメモリから非同期タスクを解放する
            defer! {
                Task::get_current(|t| unsafe { t.drop_locals() });
            }

            future.await
        };

        let schedule = move |t| RUNTIME.schedule(Runnable(t));
        let (task, handle) = async_task::spawn(future, schedule, task);
        task.schedule();
        Ok(JoinHandle::new(handle))
    }
}
```
