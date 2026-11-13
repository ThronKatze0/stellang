<p align="center"><img src=".github/logo.svg" alt="stellang" width="480"></p>

<p align="center">
  <b>A small compiled language that reads like Rust, Swift and TypeScript had a baby.</b><br>
  Structs and enums with methods · pattern matching · <code>T?</code> options and <code>T!</code> results · an Express-style web framework with WebSockets in std · a language server for any editor.
</p>

<p align="center">
  <a href="https://github.com/ThronKatze0/stellang/actions/workflows/ci.yml"><img src="https://github.com/ThronKatze0/stellang/actions/workflows/ci.yml/badge.svg" alt="ci"></a>
  <img src="https://img.shields.io/badge/frontend-Rust-orange?logo=rust" alt="Rust">
  <img src="https://img.shields.io/badge/backend-LLVM-262D3A?logo=llvm" alt="LLVM">
  <img src="https://img.shields.io/badge/memory-Boehm%20GC-7b5cff" alt="GC">
  <img src="https://img.shields.io/badge/deps-zero%20crates-success" alt="zero deps">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
</p>

---

Rust frontend, LLVM backend (via clang), garbage collected (Boehm GC). No crates, ~8k lines total.

## Quick start

```sh
cargo install --path .              # puts `stellang` on your PATH (needs clang + libgc)
stellang examples/server.st         # like cc: -o out, -O0..-O3 (default -O2), --emit-llvm
./server                            # http://localhost:8080
stellang examples/todos.st && ./todos   # a JSON API + WebSocket feed + static page, modeled with enums
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

## Modeling with structs and enums

```rust
enum Shape {
    Circle(radius: float),                 // values in parentheses (names are optional)
    Rect { w: float, h: float = 1.0 },     // or named fields, with defaults
    Empty,

    fn area(self) -> float {               // methods can live right in the type (or in `impl Shape`)
        return match self {
            Circle(r) => 3.14 * r * r,
            Rect { w, h } => w * h,
            Empty => 0.0,
        }                                  // leave a variant out and it's a compile error
    }

    fn square(side: float) -> Shape {      // no `self`: a static function, Shape.square(2.0)
        return .Rect { w: side, h: side }  // `.Variant` when the type is known from context
    }
}

enum Expr {                                // recursive is fine
    Num(int),
    Add(Expr, Expr),
    Mul(Expr, Expr),
}

fn eval(e: Expr) -> int {
    return match e {
        Num(n) => n,
        Add(a, b) => eval(a) + eval(b),
        Mul(Num(0), _) | Mul(_, Num(0)) => 0,         // nested patterns, `|`
        Mul(a, b) => eval(a) * eval(b),
    }
}

struct User {
    name: str,
    email: str?,                           // optional fields default to none
    role: Role = .Member,                  // fields can have defaults
}

enum Role { Admin, Member, Guest }

let shapes: [Shape] = [.Circle(1.0), Shape.Rect { w: 2.0 }, Shape.square(3.0), .Empty]
let bob = User { name: "bob" }             // User { name: "bob", email: none, role: Member }
println(Shape.Circle(1.0) == .Circle(1.0))   // == compares contents (structs, enums, lists, maps, sets)
println(to_json(bob))                      // {"name":"bob","email":null,"role":"Member"}
```

## Options: `T?`, never null

There is no null. A value that might be missing is a `T?`, built into the language just like `T!`:

```rust
fn find(users: [User], name: str) -> User? {
    for u in users { if u.name == name { return u } }   // a plain User becomes some(User)
    return none
}

fn domain(users: [User], name: str) -> str? {
    let u = find(users, name)?             // `?` passes none up (like it passes errors up in T!)
    return u.email?.split("@")[1]          // `?.` chains: none if email is none
}

let email = bob.email ?? "no email"        // fallback; `catch "no email"` works too
if let u = find(users, "ada") { println(u.name) }        // look inside
let u = find(users, "ada") else { return }               // or leave
while let top = stack.last() { stack.pop() }
match find(users, "eve") {
    some(u) => println(u.name),
    none => println("nobody"),
}
let n = ages.get("dave") ?? 0              // map.get, list.get/first/last/find give T?
```

## Patterns everywhere

```rust
let label = match code {
    200 | 201 => "ok",
    n if n >= 500 => "server error",       // guards
    _ => "other",
}
if let Rect { w } = shape { }              // fields you leave out are ignored
let Circle(r) = shape else { return err("not a circle") }
let Point { x, y } = p                     // destructure a struct
let size = if r > 1.0 { "big" } else { "small" }       // `if` is an expression
let n = int(s) catch e { -1 }              // a catch block can end with the fallback value
const MAX_USERS = 100                      // top-level constants
```

## Built in (no imports)

```rust
let ages = {"alice": 31, "bob": 25}        // {str: int}; keeps insertion order
ages["carol"] = 40
let n = ages.get("dave", 0)                 // or ages.get("dave") -> int?, or ages["dave"] (panics if missing)
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

- Functions: `print println str int float min max abs env panic some to_json`.
- `str`: `len is_empty split lines chars find count slice trim trim_start trim_end lower upper starts_with
  ends_with contains replace repeat reverse`, `s[i]`, `<` `>` compare.
- `float`: `floor ceil round sqrt abs`.
- `[T]`: `len is_empty push pop insert remove slice contains index_of sort reverse map filter any all sum join`,
  and `first last get(i) find(pred)` giving `T?`.
- `T?`: `?`, `?.`, `??`, `catch`, `if let`, `match`, and `is_some is_none unwrap`.
- `{K: V}`: `m[k]`, `m[k] = v`, `len is_empty get contains remove keys values`. Keys are int, str or bool.
- `{T}`: `len is_empty add contains remove to_list`.
- `in` works on strs, lists, maps and sets; `for` loops over all of them (maps and sets loop over a snapshot).
- `"${expr}"` interpolates anything; write `\${` for a literal `${`.

## Standard library (in `std/`, written in stellang)

- `http`: an Express-style framework on a single-threaded event loop (like Node): many connections at once,
  HTTP/1.1 keep-alive, WebSockets, timers.
  - Routes: `app.get/post/put/patch/delete/all(path, (req, res) => ...)` with `:params` and a trailing `*`.
    Handlers return `void!`, so `?` works inside them; an error becomes a `500`.
  - Middleware: `app.use((req, res, next) => { ...; next() })`, `app.use_at("/api", ...)`.
  - `app.static("/public", "./public")`, `app.every(ms, f)`, `app.after(ms, f)`, `app.listen(port) -> void!`.
  - `req.method path url body`, `req.param(name)`, `req.query` / `req.headers` / `req.cookies` maps,
    `req.header(name) -> str?`, `req.cookie(name) -> str?`, `req.json() -> json.Json!`.
  - `res.status(code)`, `res.set(name, value)`, `res.type(ct)` (all chainable), `res.send/html/json(body)`,
    `res.redirect(url)`, `res.cookie(name, value)`, `res.send_file(path)`, `res.end()`.
- WebSockets, like express-ws:

  ```rust
  app.ws("/chat/:room", (ws, req) => {
      let name = req.query.get("name") ?? "guest"
      ws.broadcast("${name} joined")              // every other socket on this path
      ws.on_message(msg => ws.broadcast("${name}: ${msg}"))
      ws.on_close(() => ws.broadcast("${name} left"))
  })
  for ws in app.clients("/chat/lobby") { ws.send("hi all") }   // also ws.close(), ws.peers()
  ```

- `json`: `json.parse(text) -> Json!` into an enum `Json { Null, Bool, Num, Str, Arr, Obj }` with
  `get(key) at(i) as_str as_int as_float as_bool as_list -> T?` and `stringify()`.
  (Your own types go to JSON with the builtin `to_json(value)`.)
- `fs`: `read write append remove mkdir list -> T!`, `exists is_dir`, `size -> int?`.
- `net`: `net.listen(port) -> Listener!`, `listener.accept() -> Conn!`, `conn.read() -> str!`,
  `conn.write(s) -> void!`, `conn.close()`. Wraps POSIX sockets from the C runtime.

## Editor support

`stellang lsp` is a language server built into the compiler: errors as you type, hover types and doc comments,
inlay type hints, completion, signature help, go to definition (into `std` too), references, rename, symbols,
folding, formatting and semantic highlighting.
It runs the real lexer, parser and type checker, so it keeps up with the language by itself.
The fallback grammars come out of the compiler's keyword table (`stellang grammar textmate|vim`), and a test
fails if the copies in `editors/` go stale.

- **Neovim** (0.9+): add `editors/nvim` to your runtimepath, e.g. with lazy.nvim:

  ```lua
  { dir = "~/src/stellang/editors/nvim", ft = "stellang", opts = { format_on_save = true },
    config = function(_, opts) require("stellang").setup(opts) end }
  ```

  or with no plugin manager: `vim.opt.rtp:append("~/src/stellang/editors/nvim")`.
- **VS Code**: install the `.vsix` (Extensions → `…` → *Install from VSIX…*). The platform builds from CI
  (`vscode extension` workflow, attached to `v*` releases) include the compiler, so that's all you need for the
  editor features. Or build it: `cd editors/vscode && npm install && npm run package`. Besides the server features
  it adds Run (`Ctrl+F5`, ▶ in the title bar, `▶ Run | Build` above `main`), build/check tasks with a problem
  matcher, snippets, a file icon and Markdown code-block highlighting. See [editors/vscode](editors/vscode/README.md).
- **Anything else** with LSP support: run `stellang lsp` for `*.st` files.

## Safety

No null (use `T?`), no pointers, no manual free, no uninitialized values. Out-of-bounds indexing, bad slices,
a missing map key with `m[k]`, integer division by zero, `pop()` on an empty list and `panic()` stop the program with exit code 101 and a
`file:line:col` message. An error returned from `main` prints `error: ...` and exits with 1.

The emoji keywords from the beginning still work as a joke: `stellang fmt --emoji file.st` turns
`fn struct if else while let var return break { } ;` into `🦍 🦧 🦅 🐒 🐭 🦦 🦁 🐺 🦭 ⭐ ❤️` (and `--plain` back).

## License

MIT, see [LICENSE](LICENSE). Contributions welcome: `./setup.sh` installs the toolchain, `cargo test` runs
the compiler tests, and `cd editors/vscode && npm test` checks the extension inside a real VS Code.
