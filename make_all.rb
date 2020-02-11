all_file = File.open('./all.md', 'w+')

paths = [
  "./src/SUMMARY.md",
  "./src/ch00-00-preface.md",
  "./src/ch01-00.md",
  "./src/ch01-01-what_is_async_processing.md",
  "./src/ch01-02-why_async_processing_is_requeired.md",
  "./src/ch01-03-concurrency_parallelism.md",
  "./src/ch02-00.md",
  "./src/ch02-01-async-std-code-example.md",
  "./src/ch02-02-reading-runtime.md",
  "./src/ch03-00.md",
  "./src/ch04-00-conclusion.md"
]

paths.each do |path|
  f = File.open(path, 'r')

  text = f.read

  all_file.puts(text)
end
