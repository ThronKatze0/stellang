// {{name}}: a command-line tool. It counts the words in a file (FILE=path, default: this file).
import fs

struct Count {
    lines: int = 0,
    words: int = 0,
    chars: int = 0,
}

fn count(text: str) -> Count {
    let c = Count {}
    for line in text.lines() {
        c.lines += 1
        c.chars += line.len()
        c.words += line.split(" ").filter(w => !w.trim().is_empty()).len()
    }
    return c
}

fn main() -> void! {
    var path = env("FILE")
    if path.is_empty() { path = "main.st" }
    let text = fs.read(path) catch e {
        println("can't read ${path}: ${e}")
        return
    }
    let c = count(text)
    println("${path}: ${c.lines} lines, ${c.words} words, ${c.chars} chars")
}
