<p align="center"><img src=".github/logo.svg" alt="stellang" width="480"></p>

<p align="center">
  <b>A small compiled language that reads like Rust, Swift and TypeScript had a baby.</b><br>
  Structs with methods · arrow functions · <code>T!</code> results · an Express-style web framework in std.
</p>

<p align="center">
  <a href="https://github.com/ThronKatze0/stellang/actions/workflows/ci.yml"><img src="https://github.com/ThronKatze0/stellang/actions/workflows/ci.yml/badge.svg" alt="ci"></a>
  <img src="https://img.shields.io/badge/frontend-Rust-orange?logo=rust" alt="Rust">
  <img src="https://img.shields.io/badge/backend-LLVM-262D3A?logo=llvm" alt="LLVM">
  <img src="https://img.shields.io/badge/memory-Boehm%20GC-7b5cff" alt="GC">
  <img src="https://img.shields.io/badge/deps-zero%20crates-success" alt="zero deps">
</p>

---

Rust frontend, LLVM backend (via clang), garbage collected (Boehm GC). No crates, ~4.6k lines total.

## Quick start

```sh
cargo install --path .              # puts `stellang` on your PATH (needs clang + libgc)
stellang examples/server.st         # like cc: -o out, -O0..-O3 (default -O2), --emit-llvm
./server                            # http://localhost:8080
```

## A web server

```rust
import http

fn main() -> void! {
    let app = http.app()
    var visits = 0

    app.get("/", (req, res) => {
        visits += 1
        res.html("<h1>hello</h1><p>visit number ${visits}</p>")
    })

    app.get("/hello/:name", (req, res) => res.send("hi ${req.param("name")}"))

    app.get("/square/:n", (req, res) => {
        let n = int(req.param("n")) catch e {
            res.status(400).send(e)
            return
        }
        res.send(str(n * n))
    })

    app.listen(8080)?
}
```

## The language in one screen

```rust
import geo                              // geo.st next to this file, or a std module (net, http)

struct Point {                          // structs are objects: passed by reference, like Java/JS
    x: int,
    y: int,
}

impl Point {                            // methods, Rust-style
    fn dist2(self) -> int {
        return self.x * self.x + self.y * self.y
    }
}

fn parse_port(s: str) -> int! {         // `int!` = an int or an error message
    let n = int(s)?                     // `?` passes the error up to the caller
    if n < 1 || n > 65535 {
        return err("port out of range")
    }
    return n                            // a plain value is the success case
}

fn main() {
    let p = Point { x: 3, y: 4 }        // `let` can't be reassigned...
    var total = 0                       // ...`var` can
    total += p.dist2()

    let port = parse_port("80") catch 8080      // fallback value on error
    let other = parse_port("x") catch e {       // or handle it (block must leave: return/break/continue)
        println("bad port: ${e}")
        return
    }
    match parse_port("443") {
        ok(n) => println(n),
        err(e) => println(e),
    }

    let double = (x: int) => x * 2     // arrow functions; types are inferred when passed as arguments
    let nums = [1, 2, 3]
    for n in nums { total += double(n) }
    for i in 0..10 { if i == 5 { break } }
    while total > 100 { total -= 100 }
}
```

- Types: `int`, `float`, `bool`, `str`, `[T]` lists, `{K: V}` maps, `{T}` sets, structs,
  `fn(int, str) -> bool`, and `T!` results.
- Lambdas capture variables by reference (like JS), so `visits += 1` inside a handler sticks.
- Statements end at the end of the line (`;` is optional). Using a `T!` without handling it is a compile error.
- `extern fn name(x: int) -> str` calls C. That's how `std/net.st` talks to the sockets in `src/runtime.c`.

## Built in (no imports)

```rust
let ages = {"alice": 31, "bob": 25}        // {str: int}; keeps insertion order
ages["carol"] = 40
let n = ages.get("dave", 0)                 // or ages.get("dave") -> int!, or ages["dave"] (panics if missing)
for name, age in ages { println("${name} is ${age}") }

let seen = {1, 2, 3}                        // {int}
seen.add(4)
if 2 in seen && "ell" in "hello" && 3 in [1, 2, 3] { ... }

let xs = [5, 3, 8]
xs.sort()
println(xs.filter(x => x > 3).map(x => x * 10))   // [50, 80]
for i, x in xs { println("${i}: ${x}") }

let area = 3.14 * r * r                     // int and float mix; int(2.9) == 2, float("1.5")?
println({"pt": Point { x: 1.0, y: 2.0 }})  // print and "${}" show anything: {"pt": Point { x: 1.0, y: 2.0 }}
```

- Functions: `print println str int float min max abs env panic`.
- `str`: `len is_empty split lines chars find count slice trim trim_start trim_end lower upper starts_with
  ends_with contains replace repeat reverse`, `s[i]`, `<` `>` compare.
- `float`: `floor ceil round sqrt abs`.
- `[T]`: `len is_empty push pop insert remove slice contains index_of sort reverse map filter any all sum join`.
- `{K: V}`: `m[k]`, `m[k] = v`, `len is_empty get contains remove keys values`. Keys are int, str or bool.
- `{T}`: `len is_empty add contains remove to_list`.
- `in` works on strs, lists, maps and sets; `for` loops over all of them (maps and sets loop over a snapshot).
- `"${expr}"` interpolates anything; write `\${` for a literal `${`.

## Standard library (in `std/`, written in stellang)

- `net`: `net.listen(port) -> Listener!`, `listener.accept() -> Conn!`, `conn.read() -> str!`,
  `conn.write(s) -> void!`, `conn.close()`. Wraps POSIX sockets from the C runtime.
- `http`: `http.app()`, `app.get/post(path, (req, res) => ...)` with `:params`, `app.listen(port) -> void!`.
  `req.method/path/query/body`, `req.param(name)`, `req.header(name)`, `req.params`/`req.headers` maps;
  `res.send/html/json(body)`, `res.status(code)` (chainable).

## Safety

No null, no pointers, no manual free, no uninitialized values. Out-of-bounds indexing, bad slices,
a missing map key with `m[k]`, integer division by zero, `pop()` on an empty list and `panic()` stop the program with exit code 101 and a
`file:line:col` message. An error returned from `main` prints `error: ...` and exits with 1.

The emoji keywords from the beginning still work as a joke: `stellang fmt --emoji file.st` turns
`fn struct if else while let var return break { } ;` into `🦍 🦧 🦅 🐒 🐭 🦦 🦁 🐺 🦭 ⭐ ❤️` (and `--plain` back).
