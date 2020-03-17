# 非同期タスクの起動

では次に非同期タスクがどのようにランタイムに登録されるのかを見ていきましょう！非同期タスクは次のようなコードで起動することが出来ます。この節ではこの`spawn`関数を呼び出すとどのような動作をしてランタイムのタスクキューに格納されるのかを見ていきます。

```rust
let handle = task::spawn(async {
    1 + 2
});

assert_eq!(handle.await, 3);
```

## spawn

では早速`spawn`関数を見ていきましょう。この関数自体は非同期タスクの抽象化である`Future`を引数として受け取り、`Builder`構造体を作っています。そして、非同期タスクのハンドラーである JoinHandle を返します。 JoinHandle を介して非同期タスク完了を待機したり実行をキャンセルしたり出来ます。

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
/// Task builder that configures the settings of a new task.
#[derive(Debug, Default)]
pub struct Builder {
    pub(crate) name: Option<String>,
}

impl Builder {
    /// Creates a new builder.
    #[inline]
    pub fn new() -> Builder {
        Builder { name: None }
    }

    /// Configures the name of the task.
    #[inline]
    pub fn name(mut self, name: String) -> Builder {
        self.name = Some(name);
        self
    }

    /// Spawns a task with the configured settings.
    pub fn spawn<F, T>(self, future: F) -> io::Result<JoinHandle<T>>
    where
        F: Future<Output = T> + Send + 'static,
        T: Send + 'static,
    {
        // Create a new task handle.
        let task = Task::new(self.name);

        // Log this `spawn` operation.
        trace!("spawn", {
            task_id: task.id().0,
            parent_task_id: Task::get_current(|t| t.id().0).unwrap_or(0),
        });

        let future = async move {
            // Drop task-locals on exit.
            defer! {
                Task::get_current(|t| unsafe { t.drop_locals() });
            }

            // Log completion on exit.
            defer! {
                trace!("completed", {
                    task_id: Task::get_current(|t| t.id().0),
                });
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
