# 非同期処理について

## 非同期処理とは？

多くのプログラミング言語はコードの実行の仕方として同期処理と非同期処理という分類があります。

### 同期処理

同期処理ではコードを順番に処理していき、ひとつの処理が終わるまでは次の行のコードを処理しません。書いた順番に動作するため、とても直感的です。しかし、同期的にブロックする処理が行われていた場合、一つの処理が終わるまで、次の処理へ進むことが出来ません。

次のコードを例に考えてみましょう。`sleep`関数は指定した時間だけ(今回は 1 秒)スレッドの動作をブロックします。なので、２つ目の`println`が実行されるまでに１秒かかってしまいます。

```rust
use std::{thread::sleep, time::Duration};

println!("開始");
sleep(Duration::from_secs(1));
println!("このコードが実行されるまで1秒ブロックされる")
```

コード例では`sleep`関数を使いましたが、通常は何かしらの重たい処理が入ると考えて下さい。その時、重たい処理が間にあると大きな待ちが生まれてしまいますね。

### 非同期処理

非同期処理はコードを順番に処理していくという部分は変わらないのですが、一つの処理が終わるのを待たずに次の処理を実行します。

Rust の`async/awat`を用いて非同期関数の例を示します。３つの非同期関数を考えてみましょう。関数のシグネチャから、歌を歌うためには前もって歌を学ぶ必要があります。ですが、歌を学んだ後に歌うのと同時に踊ることは可能ですよね？

```rust
async fn lern_song() -> Song { // do something  }
async fn sing_song(song: Song) -> Song { // do something  }
async fn lern_song() { // do something  }
```

歌の学習、歌うこと、ダンスを行う方法の一つは１つ１つ実行することです。

```rust
fn main() {
  let song = block_on(learn_song()); // block_onで非同期関数の完了を待つ
  block_on(sing_song(song));
  block_on(dance());
}
```

この方法では１つのことを順番に実行しているだけなので、最高のパフォーマンスを実現しているわけではありません。明らかに、歌を学んだ後に「歌う」と「踊る」は同時に実行できますよね。

```rust
async fn learn_and_sing() {
    let song = learn_song().await;
    sing_song(song).await;
}

async fn async_main() {
    let f1 = learn_and_sing();
    let f2 = dance();

    futures::join!(f1, f2);
}

fn main() {
    block_on(async_main());
}
```
