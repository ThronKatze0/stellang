<p align="center"><img src=".github/logo.svg" alt="stellang" width="480"></p>

<p align="center">
  <b>A small compiled language that reads like Rust, Swift and TypeScript had a baby.</b><br>
  Structs and enums with methods · generics and traits · pattern matching · <code>T?</code> options and <code>T!</code> results · JSX in the language · full stack: native servers and WebAssembly browser apps from the same code · a language server for any editor.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/frontend-Rust-orange?logo=rust" alt="Rust">
  <img src="https://img.shields.io/badge/backend-LLVM-262D3A?logo=llvm" alt="LLVM">
  <img src="https://img.shields.io/badge/memory-Boehm%20GC-7b5cff" alt="GC">
  <img src="https://img.shields.io/badge/deps-zero%20crates-success" alt="zero deps">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
</p>

---

Rust frontend, LLVM backend (via clang), garbage collected (Boehm GC natively, its own collector in WebAssembly),
HTTPS client on libcurl. No crates.

## Quick start

```sh
cargo install --path .              # puts `stellang` on your PATH (needs clang, libgc and libcurl)
stellang examples/server.st         # like cc: -o out, -O0..-O3 (default -O2), --emit-llvm
./server                            # http://localhost:8080
stellang examples/todos.st && ./todos   # a JSON API + WebSocket feed + static page, modeled with enums
stellang dev examples/fullstack     # server rendering + a WebAssembly client, rebuilt on every save
stellang --web app.st               # a browser app: app.wasm + app.js (+ app.html to open)
```

Browser builds also need the WASI C library and clang's wasm32 runtime
(Debian/Ubuntu: `apt install wasi-libc libclang-rt-18-dev-wasm32`; `./setup.sh` installs everything).

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

## Full stack, one language

Components are functions that return JSX. The server renders them to HTML; the browser runs the same
code compiled to WebAssembly, takes over the page and re-renders when a `signal` changes. Types go
over the wire with `to_json` and come back with `from_json`.

```rust
// shared.st: used by both sides
import web
import json

struct Todo { id: int, title: str, done: bool = false }

fn App(initial: [Todo]) -> Node {
    let todos = signal(initial)              // state that survives re-rendering
    let draft = signal("")
    let add = () => web.post("/api/todos", to_json(Todo { id: 0, title: draft.get() }), r => {
        todos.set(from_json(r.body) catch todos.get())   // decoded into [Todo]
        draft.set("")
    })
    return <main>
        <form onsubmit={_ => add()}>
            <input value={draft.get()} oninput={v => draft.set(v)} placeholder="What next?" />
            <button disabled={draft.get() == ""}>"Add"</button>
        </form>
        <ul>
            for t in todos.get() {
                <li key={t.id} class={if t.done { "done" } else { "" }}>{t.title}</li>
            }
        </ul>
    </main>
}
```

```rust
// server.st
import http
import json
import web
import shared

fn main() -> void! {
    var todos: [shared.Todo] = []
    let app = http.app()
    app.get("/", (req, res) => res.page(
        <html>
            <body>
                <div id="app"><shared.App initial={todos} /></div>
                {web.data("todos", to_json(todos))}
                <script src="/client.js"></script>
            </body>
        </html>))
    app.post("/api/todos", (req, res) => {
        let t: shared.Todo = from_json(req.body)?   // a bad body becomes a 500
        todos.push(shared.Todo { id: todos.len() + 1, title: t.title })
        res.json(to_json(todos))
    })
    app.static("/", "./public")
    app.listen(8080)?
}
```

```rust
// client.st
import web
import shared

fn main() {
    let todos: [shared.Todo] = from_json(web.read_data("todos")) catch []
    web.mount("#app", () => <shared.App initial={todos} />)
}
```

`stellang dev` builds `client.st` into `public/client.wasm` + `client.js`, builds and runs `server.st`, and does
it again whenever a `.st` file changes. The whole thing is in [examples/fullstack](examples/fullstack).

**JSX.** Text is a string literal (`<p>"Hello, ${name}"</p>`); `{value}` shows a value (text, numbers, a `Node`,
a `[Node]`, an optional); children can also be `for x in xs { ... }` and `if c { ... } else { ... }`.
Attributes take `"text"`, `{value}` or nothing (`disabled`); a `bool` attribute is there or not; `key={id}`
keeps list items apart. `<Card title="x">children</Card>` calls `fn Card(title: str, children: Node) -> Node`,
or fills the fields (and their defaults) of its one props struct. Text and values are escaped; `web.raw(html)`
is the way around that. Events: `onclick={() => ...}`, `oninput={value => ...}`, `onchange`, `onkeydown={key => ...}`,
`onsubmit={fields => ...}`, `onfocus`, `onblur`, ...

**In the browser** (`import web`): `web.mount(selector, () => <App />)`; `signal(x)` gives a `Signal<T>` with
`get set update`, kept from render to render (call them at the top of a component, the same way each time);
`web.every(ms, f)`, `web.after(ms, f)`, `web.cancel(id)`; `web.get/post/request(..., r => ...)` with
`r.status r.body r.is_ok() r.json()`; `web.location() navigate(path) set_title(t)`; `web.load(key)`/`save(key, value)`
(localStorage); `web.data(id, json)` / `web.read_data(id)` to hand server data to the app. The page is patched in
place, so focus, selection and what's typed survive a re-render; a panic shows up on the page.
`print` goes to the browser console. A typical app is 30–60 KB of WebAssembly.

## Calling an API

```rust
import http

fn main() -> void! {
    let key = env("RIOT_API_KEY")
    let id = "${url_encode("Hide on bush")}/${url_encode("KR1")}"      // -> Hide%20on%20bush/KR1
    let url = "https://asia.api.riotgames.com/riot/account/v1/accounts/by-riot-id/${id}"
    var r = http.fetch(url, {"X-Riot-Token": key})?                  // only network trouble is an error
    if r.status == 429 {                                               // rate limited: wait and try once more
        sleep((int(r.header("retry-after") ?? "1") catch 1) * 1000)
        r = http.fetch(url, {"X-Riot-Token": key}, 5000)?              // timeout in ms (default 8000)
    }
    if r.status == 404 {
        return err("no such player")
    }
    let acc = r.json()?
    println(acc.get("puuid")?.as_str() ?? "?")
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

fn greet(name: str, greeting: str = "hi") -> str {   // trailing parameters can have defaults
    return "${greeting} ${name}"        // greet("ada"), greet("ada", "hello")
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

## Generics and traits

```rust
struct Stack<T> {
    items: [T] = []

    fn push(self, x: T) { self.items.push(x) }
    fn pop(self) -> T? { return self.items.pop() }
    fn map<U>(self, f: fn(T) -> U) -> Stack<U> { return Stack { items: self.items.map(f) } }
}

enum Tree<T> {
    Leaf
    Node(Tree<T>, T, Tree<T>)
}

fn largest<T>(xs: [T]) -> T? {                  // checked for each type it's used with
    var best = xs.first()?
    for x in xs { if x > best { best = x } }
    return best
}

trait Show {
    fn show(self) -> str
    fn shout(self) -> str { return self.show().upper() + "!" }   // a default
}
impl Show for Point { fn show(self) -> str { return "(${self.x}, ${self.y})" } }
impl Show for int { fn show(self) -> str { return "#${self}" } }

fn all<T: Show>(xs: [T]) -> str { return xs.map(x => x.show()).join(", ") }

let s: Stack<str> = Stack {}                     // or inferred: Stack { items: ["a"] }
let t: Tree<int> = .Node(.Leaf, 1, .Leaf)
println("${largest([3, 9, 4]) ?? 0} ${all([Point { x: 1, y: 2 }])} ${all([1, 2])}")   // 9 (1, 2) #1, #2
```

Type arguments are inferred from the arguments, field values and the type the result goes into. Each use with
new types makes a specialized copy (like Rust and C++), so generic code is as fast as hand-written code.
A bound like `T: Show + Eq` is checked where the function is used, with an error that says what's missing.

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

- Functions: `print println str int float min max abs env panic some to_json from_json sleep now_ms url_encode
  url_decode`.
  `from_json(text)` decodes into the type the code expects (`let t: Todo = from_json(body)?`): structs (missing
  fields take their defaults), enums, lists, maps, sets and optionals, the reverse of `to_json`.
  - `sleep(ms)` blocks; `now_ms() -> int` reads a monotonic clock (for timing, TTL caches, uptime).
  - `url_encode(s) -> str` percent-encodes UTF-8 bytes for a URL path segment or query value; only
    `A-Z a-z 0-9 - _ . ~` stay as they are (a bit stricter than JavaScript's `encodeURIComponent`,
    which also leaves `! * ' ( )`; servers decode both the same).
  - `url_decode(s) -> str` undoes `%XX` escapes. Like form data and query strings, it also turns `+` into a
    space, so a literal `+` must arrive as `%2B` (which `url_encode` does).
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
- Client (HTTP and HTTPS, libcurl underneath):
  - `http.fetch(url, headers = {}, timeout_ms = 8000) -> FetchResponse!` sends a GET;
    `http.request(method, url, headers = {}, body = "", timeout_ms = 8000) -> FetchResponse!` any method.
  - `FetchResponse { status, headers, body }` with `r.header(name) -> str?` (case-insensitive; `headers` has
    lowercase names) and `r.json() -> json.Json!`. Redirects are followed and gzip is decoded.
  - A header sent more than once is joined with `, ` in `headers`. That breaks `set-cookie`, so
    `r.header_all("set-cookie") -> [str]` gives each value on its own (like JavaScript's `getSetCookie()`).
  - `http.query({"start": "0", "count": "20"})` -> `start=0&count=20`, names and values `url_encode`-d, in the
    map's order.
  - Every HTTP status, `404` and `429` included, is a normal response: check `r.status`. Only DNS, connection,
    TLS and timeout problems come back as `err(...)`. The error starts with its kind, so you can tell whether a
    retry makes sense: `timeout:`, `dns:`, `connect:` (refused, reset or cut off), `tls:`, `too_large:` (the
    body is over 64 MB) or `other:`, e.g. `if e.starts_with("timeout:") { ... }`.
  - Connections are kept open and reused: the next fetch to the same host skips the TCP and TLS handshakes.
  - `CURL_CA_BUNDLE` or `SSL_CERT_FILE` point it at a different CA bundle; `https_proxy`/`no_proxy` are honored.
  - It blocks until the answer is there. Inside a server handler that holds up the whole event loop (up to
    `timeout_ms`), so keep timeouts short and cache answers.
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
- `web`: browser apps (see *Full stack* above). On the server the same components render to HTML: `mount` prints
  the page once, and `signal`, timers and requests are inert. `res.page(<html>...</html>)` sends a whole page.
- `net`: `net.listen(port) -> Listener!`, `listener.accept() -> Conn!`, `conn.read() -> str!`,
  `conn.write(s) -> void!`, `conn.close()`. Wraps POSIX sockets from the C runtime.

## Editor support

`stellang lsp` is a language server built into the compiler: errors as you type, hover types and doc comments,
inlay type and parameter hints, completion that asks the type checker (members of any expression, the variants an
enum slot needs, missing struct fields, match arms, postfix snippets like `x.match`, auto-import), quick fixes
(add missing match arms, import a module, did-you-mean), signature help, go to definition (into `std` too),
references, rename, symbols, folding, formatting and semantic highlighting. In JSX it completes components (with
their required props), HTML elements, props, attributes and events, and the tag to close.
It runs the real lexer, parser and type checker, so it keeps up with the language by itself.
The fallback grammars come out of the compiler's keyword table (`stellang grammar textmate|vim`), and a test
fails if the copies in `editors/` go stale.

- **Neovim** (0.9+): add `editors/nvim` to your runtimepath, e.g. with lazy.nvim:

  ```lua
  { dir = "~/src/stellang/editors/nvim", ft = "stellang", opts = { format_on_save = true },
    config = function(_, opts) require("stellang").setup(opts) end }
  ```

  or with no plugin manager: `vim.opt.rtp:append("~/src/stellang/editors/nvim")`.
- **VS Code**: run `editors/vscode/install.sh` (builds the compiler, packages the extension with it inside, and installs
  it with `code`; pass `codium` or `cursor` for those). Or build a `.vsix` to share (`cd editors/vscode && npm install && npm run package`; it includes the
  compiler) and install it from Extensions → `…` → *Install from VSIX…*. Besides the server features
  it adds two star themes (Stellang Nebula and Daybreak), a sidebar with your programs, types and HTTP routes, a runner
  that spots server addresses (Open in Browser, stop, restart), runs full-stack apps under `stellang dev` and serves
  browser apps, project templates (including full-stack and browser apps), a Get Started walkthrough,
  Show LLVM IR, build/check tasks with a problem matcher, a file icon and Markdown code-block highlighting. See [editors/vscode](editors/vscode/README.md).
- **Anything else** with LSP support: run `stellang lsp` for `*.st` files.

## Safety

No null (use `T?`), no pointers, no manual free, no uninitialized values. Out-of-bounds indexing, bad slices,
a missing map key with `m[k]`, integer division by zero, `pop()` on an empty list and `panic()` stop the program with exit code 101 and a
`file:line:col` message. An error returned from `main` prints `error: ...` and exits with 1.

## License

MIT, see [LICENSE](LICENSE). Contributions welcome: `./setup.sh` installs the toolchain, `cargo test` runs
the compiler tests, and `cd editors/vscode && npm test` checks the extension inside a real VS Code.
