use std::io::{Read, Write};
use std::net::TcpStream;
use std::process::{Command, Stdio};
use std::{env, fs, thread, time::Duration};

const BIN: &str = env!("CARGO_BIN_EXE_stellang");

fn tmpdir(name: &str) -> std::path::PathBuf {
    let d = env::temp_dir().join(format!("stellang-test-{}-{name}", std::process::id()));
    fs::create_dir_all(&d).unwrap();
    d
}

/// Compile `src` (plus extra module files) and run it. Returns (exit code, stdout, stderr); -1 = compile failed.
fn run_with(name: &str, src: &str, modules: &[(&str, &str)]) -> (i32, String, String) {
    let dir = tmpdir(name);
    for (m, s) in modules {
        fs::write(dir.join(format!("{m}.st")), s).unwrap();
    }
    let (file, exe) = (dir.join("main.st"), dir.join("main"));
    fs::write(&file, src).unwrap();
    let c = Command::new(BIN).arg(&file).arg("-o").arg(&exe).output().unwrap();
    if !c.status.success() {
        return (-1, String::new(), String::from_utf8_lossy(&c.stderr).into());
    }
    let r = Command::new(&exe).output().unwrap();
    let s = |b: &[u8]| String::from_utf8_lossy(b).into_owned();
    (r.status.code().unwrap(), s(&r.stdout), s(&r.stderr))
}

fn run(name: &str, src: &str) -> (i32, String, String) {
    run_with(name, src, &[])
}

fn ok(name: &str, src: &str, out: &str) {
    assert_eq!(run(name, src), (0, out.into(), "".into()));
}

#[test]
fn basics() {
    let src = r#"
fn fib(n: int) -> int {
    if n < 2 {
        return n
    }
    return fib(n - 1) + fib(n - 2)
}

fn main() -> int {
    for i in 0..10 {
        print(fib(i))
        print(" ")
    }
    println("")
    var total = 0
    for x in [1, 2, 3, 4, 5, 6] {
        if x == 2 {
            continue
        } else if x == 5 {
            break
        }
        total += x
    }
    println(total)
    var n = 0
    while n < 100 { n = n * 2 + 1 }
    println(n)
    let big = 1_000_000
    println(big / 3 % 7)
    return 7
}"#;
    assert_eq!(run("basics", src), (7, "0 1 1 2 3 5 8 13 21 34 \n8\n127\n0\n".into(), "".into()));
}

#[test]
fn structs_and_methods() {
    let src = r#"
struct Point {
    x: int,
    y: int,
}

impl Point {
    fn add(self, other: Point) -> Point {
        return Point { x: self.x + other.x, y: self.y + other.y }
    }
    fn move_by(self, dx: int) {
        self.x += dx
    }
    fn show(self) -> str {
        return "(" + str(self.x) + ", " + str(self.y) + ")"
    }
}

struct Team {
    name: str,
    members: [str],
}

fn main() {
    let a = Point { x: 1, y: 2 }
    let b = a.add(Point { x: 10, y: 20 })
    println(b.show())
    let alias = b
    alias.move_by(5)
    println(b.show())
    let x = 3
    let y = 4
    println(Point { x, y }.show())
    let team = Team { name: "core", members: [] }
    team.members.push("ada")
    team.members.push("linus")
    println(team.name + ": " + team.members.join(", "))
    let pts: [Point] = []
    for i in 0..3 { pts.push(Point { x: i, y: i * i }) }
    pts[2].y = 99
    println(pts[2].show() + " " + str(pts.len()))
}"#;
    ok("structs", src, "(11, 22)\n(16, 22)\n(3, 4)\ncore: ada, linus\n(2, 99) 3\n");
}

#[test]
fn lambdas_and_closures() {
    let src = r#"
fn apply(f: fn(int) -> int, x: int) -> int {
    return f(x)
}

fn make_counter() -> fn() -> int {
    var count = 0
    return () => {
        count += 1
        return count
    }
}

fn double(x: int) -> int { return x * 2 }

fn main() {
    println(apply(x => x + 1, 41))
    println(apply((x) => x * x, 7))
    println(apply(double, 21))
    let add = (a: int, b: int) => a + b
    println(add(2, 3))
    let next = make_counter()
    next()
    next()
    println(next())
    var log: [str] = []
    let say = (msg: str) => log.push(msg)
    say("a")
    say("b")
    println(log.join(""))
    var sum = 0
    let nums = [1, 2, 3]
    let each = (f: fn(int)) => {
        for n in nums { f(n) }
    }
    each(n => { sum += n })
    println(sum)
    let handlers: [fn(int) -> int] = [x => x + 1, x => x * 10]
    println(handlers[1](5))
}"#;
    ok("lambda", src, "42\n49\n42\n5\n3\nab\n6\n50\n");
}

#[test]
fn results() {
    let src = r#"
fn parse_port(s: str) -> int! {
    let n = int(s)?
    if n < 1 || n > 65535 {
        return err("port out of range: " + str(n))
    }
    return n
}

fn check(s: str) -> str {
    return match parse_port(s) {
        ok(p) => "ok " + str(p),
        err(e) => "error: " + e,
    }
}

fn save(fail: bool) -> void! {
    if fail { return err("disk full") }
}

fn main() -> void! {
    println(check("8080"))
    println(check("99999"))
    println(check("abc"))
    let p = parse_port("x") catch 3000
    println(p)
    let q = parse_port("70000") catch e {
        println("caught: " + e)
        return
    }
    println("unreachable " + str(q))
}"#;
    assert_eq!(
        run("results", src),
        (0, "ok 8080\nerror: port out of range: 99999\nerror: not a number: \"abc\"\n3000\ncaught: port out of range: 70000\n".into(), "".into())
    );
    let fails = "fn step() -> int! { return err(\"boom\") }\nfn main() -> void! {\n let x = step()?\n println(x)\n}";
    assert_eq!(run("mainfail", fails), (1, "".into(), "error: boom\n".into()));
    let caught = "fn save() -> void! { return err(\"disk full\") }\nfn main() { save() catch e { println(e) }\n println(\"after\") }";
    ok("catchvoid", caught, "disk full\nafter\n");
}

#[test]
fn match_and_strings() {
    let src = r#"
fn kind(code: int) -> str {
    return match code {
        200 => "ok",
        404 => "missing",
        -1 => "broken",
        _ => "other",
    }
}

fn main() {
    println(kind(404) + " " + kind(-1) + " " + kind(7))
    let method = "POST"
    match method {
        "GET" => println("get"),
        "POST" => {
            println("post")
        },
        _ => {},
    }
    let s = "  Hello, World  ".trim()
    println(s.len())
    println(s.lower() + "|" + s.upper())
    println(s.find("World"))
    println(s.slice(0, 5))
    println(s.starts_with("Hell") && s.ends_with("ld") && s.contains(", "))
    println(s.replace("l", "L"))
    let parts = "a=1&b=2&c=3".split("&")
    println(parts.len())
    println(parts[1].split("=")[1])
    var acc = ""
    for i in 0..200000 { acc = "x" + str(i) }
    println(acc)
}"#;
    ok("match", src, "missing broken other\npost\n12\nhello, world|HELLO, WORLD\n7\nHello\ntrue\nHeLLo, WorLd\n3\n2\nx199999\n");
}

#[test]
fn modules() {
    let geo = r#"
struct Rect {
    w: int,
    h: int,
}

impl Rect {
    fn area(self) -> int { return self.w * self.h }
}

fn square(n: int) -> Rect {
    return Rect { w: n, h: n }
}
"#;
    let src = r#"
import geo

fn main() {
    let r = geo.Rect { w: 3, h: 4 }
    println(r.area())
    println(geo.square(5).area())
    let make: fn(int) -> geo.Rect = geo.square
    println(make(2).area())
}"#;
    assert_eq!(run_with("modules", src, &[("geo", geo)]), (0, "12\n25\n4\n".into(), "".into()));
    let (code, _, err) = run("nomod", "import nothere\nfn main() {}");
    assert_eq!(code, -1);
    assert!(err.contains("cannot find module `nothere`"), "{err}");
}

#[test]
fn runtime_panics() {
    for (name, src, msg) in [
        ("oob", "fn main() {\n let a = [1, 2, 3]\n let i = 3\n println(a[i])\n}", "index out of bounds"),
        ("div", "fn main() {\n let z = 0\n println(1 / z)\n}", "division by zero"),
        ("slice", "fn main() { println(\"abc\".slice(1, 9)) }", "slice() out of range"),
        ("pop", "fn main() {\n let v: [int] = []\n v.pop()\n}", "pop() on an empty list"),
        ("panic", "fn main() { panic(\"custom\") }", "panic: custom"),
        ("key", "fn main() {\n let m = {\"a\": 1}\n println(m[\"b\"])\n}", "key not in map"),
        ("remove", "fn main() { [1].remove(1) }", "index out of bounds"),
    ] {
        let (code, _, err) = run(name, src);
        assert_eq!(code, 101, "{name}: {err}");
        assert!(err.contains(msg), "{name}: {err}");
    }
}

#[test]
fn compile_errors() {
    let cases = [
        ("fn main() {\n let x = 1\n x = 2\n}", "declare it with `var`"),
        ("fn f() -> int { if true { return 1 } }\nfn main() {}", "must return a int on every path"),
        ("fn f() -> int! { return 1 }\nfn main() { f() }", "error is ignored"),
        ("fn f() -> int { return int(\"1\")? }\nfn main() {}", "function must return a result"),
        ("fn main() { let x = [] }", "empty list"),
        ("fn main() { let f = x => x }", "can't tell the type of `x`"),
        ("fn main() { nope(1) }", "unknown function"),
        ("fn main() { break }", "outside of a loop"),
        ("struct P { x: int }\nfn main() { let p = P { y: 1 } }", "has no field `y`"),
        ("struct P { x: int }\nfn main() { let p = P {} }", "missing field `x`"),
        ("fn main() { let s = \"a\" + 1 }", "or str(x)"),
        ("fn main() { let m = {} }", "empty map"),
        ("fn main() { let s = {1.5} }", "must be int, str or bool"),
        ("fn main() { for a, b in 0..3 {} }", "one number at a time"),
        ("fn main() { let n = int(\"1\") catch e { println(e) } }", "must leave"),
        ("enum S { A, B(int) }\nfn main() { match S.A { A => {} } }", "doesn't handle S.B"),
        ("enum S { A, B }\nfn main() { let s = .A }", "which enum `.A`"),
        ("enum S { A(int) }\nfn main() { let s = S.A }", "holds values"),
        ("enum S { A, B(int) }\nfn main() { let B(n) = S.A }", "might not match"),
        ("fn main() { let x: int? = 1\n println(x + 1) }", "unwrap it first"),
        ("fn main() { let x = none }", "what kind of `none`"),
        ("fn f() -> int { let x: int? = none\n return x? }\nfn main() {}", "must return an optional"),
        ("const X = 1\nfn main() { X = 2 }", "is a constant"),
        ("struct P { x: int, y: int = 0 }\nfn main() { let p = P { y: 1 } }", "missing field `x`"),
        ("fn main() { match 1 { 1 | x => {}, _ => {} } }", "can't bind names"),
        ("fn main() { let x: int? = 1\n let y = x else { println(1) } }", "must leave"),
        ("fn main() { match 1 { _ => 1, 2 => 2 } }", "can never run"),
    ];
    for (i, (src, msg)) in cases.iter().enumerate() {
        let (code, _, err) = run(&format!("err{i}"), src);
        assert_eq!(code, -1, "case {i} should fail to compile");
        assert!(err.contains(msg), "case {i}: {err}");
    }
}

#[test]
fn emoji_fmt() {
    let dir = tmpdir("fmt");
    let file = dir.join("a.st");
    let plain = "fn main() -> int {\nvar n = 0\nwhile true {\nn += 1\nif n == 3 { break }\n}\nreturn n;\n}\n";
    fs::write(&file, plain).unwrap();
    assert!(Command::new(BIN).args(["fmt", "--emoji"]).arg(&file).status().unwrap().success());
    assert_eq!(
        fs::read_to_string(&file).unwrap(),
        "🦍 main() -> int ⭐\n    🦁 n = 0\n    🐭 true ⭐\n        n += 1\n        🦅 n == 3 ⭐ 🦭 ⭐\n    ⭐\n    🐺 n❤️\n⭐\n"
    );
    let exe = dir.join("a");
    assert!(Command::new(BIN).arg(&file).arg("-o").arg(&exe).status().unwrap().success());
    assert_eq!(Command::new(&exe).status().unwrap().code(), Some(3));
    assert!(Command::new(BIN).args(["fmt", "--plain"]).arg(&file).status().unwrap().success());
    assert_eq!(fs::read_to_string(&file).unwrap(), plain.replace("var", "    var").replace("while", "    while")
        .replace("n += 1", "        n += 1").replace("if n", "        if n").replace("}\nreturn", "    }\n    return"));
}

#[test]
fn http_server() {
    let dir = tmpdir("http");
    let exe = dir.join("server");
    let src = concat!(env!("CARGO_MANIFEST_DIR"), "/examples/server.st");
    assert!(Command::new(BIN).arg(src).arg("-o").arg(&exe).status().unwrap().success());
    let port = 20000 + std::process::id() % 20000;
    let mut server = Command::new(&exe).env("PORT", port.to_string()).stdout(Stdio::null()).spawn().unwrap();
    let send = |req: String| -> String {
        for _ in 0..50 {
            if let Ok(mut s) = TcpStream::connect(("127.0.0.1", port as u16)) {
                s.write_all(req.as_bytes()).unwrap();
                let mut out = String::new();
                s.read_to_string(&mut out).unwrap();
                return out;
            }
            thread::sleep(Duration::from_millis(50));
        }
        panic!("server never came up");
    };
    let get = |path: &str| send(format!("GET {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"));
    let first = get("/");
    let second = get("/");
    let hello = get("/hello/ada");
    let square = get("/square/12");
    let bad = get("/square/abc");
    let echo = send("POST /echo HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Length: 7\r\n\r\n{\"a\":1}".into());
    // keep-alive: two pipelined requests on one connection, then close
    let both = send("GET /hello/a HTTP/1.1\r\nHost: x\r\n\r\nGET /hello/b HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".into());
    let missing = get("/nope");
    server.kill().unwrap();
    assert!(first.starts_with("HTTP/1.1 200 OK\r\n") && first.contains("visit number 1"), "{first}");
    assert!(second.contains("visit number 2"), "{second}");
    assert!(hello.ends_with("\r\n\r\nhi ada!"), "{hello}");
    assert!(square.ends_with("\r\n\r\n144"), "{square}");
    assert!(bad.starts_with("HTTP/1.1 400 Bad Request") && bad.contains("not a number"), "{bad}");
    assert!(echo.contains("application/json") && echo.ends_with("{\"a\":1}"), "{echo}");
    assert!(missing.starts_with("HTTP/1.1 404 Not Found"), "{missing}");
    assert!(both.contains("keep-alive") && both.contains("hi a!") && both.ends_with("hi b!"), "{both}");
}

#[test]
fn prelude() {
    let src = r#"
struct Point {
    x: float,
    y: float,
}

fn main() {
    let r = 2
    println(3.5 * r)
    println([0.1 + 0.2, 10.0 / 4, 1e3, float("2.5") catch 0.0])
    println([int(7.9), 10 / 4, min(3, 7), max(3, 7), abs(-4)])
    println(Point { x: 1, y: 2.5 })

    let name = "stella"
    println("hi ${name.upper()}, ${1 + 2} things, \${not this}")
    println(["ab".repeat(2), name[0], "abc".reverse(), "a b".split(" ").join("+")])
    println("ell" in name && "apple" < "banana" && "".is_empty())
    for i, c in "hey" { print("${i}${c} ") }
    println()

    var ages = {"alice": 31, "bob": 25}
    ages["carol"] = 40
    ages["bob"] += 1
    ages.remove("alice")
    println(ages)
    println([ages.get("dave", 0), ages.get("dave") catch -1, ages.len()])
    for k, v in ages { print("${k}=${v} ") }
    println()
    let counts: {str: int} = {}
    for w in "a b a c a".split(" ") { counts[w] = counts.get(w, 0) + 1 }
    println(counts)

    var seen = {1, 2}
    seen.add(2)
    seen.add(10)
    println(seen)
    println([5 in seen, 10 in seen])

    var xs = [5, 3, 8, 1]
    xs.sort()
    println(xs.map(x => x * 10))
    println(xs.filter(x => x > 2).map(x => "n${x}"))
    println([xs.sum(), xs.index_of(8)])
    println([xs.contains(8), xs.any(x => x > 7), xs.all(x => x > 7)])
    xs.insert(0, 99)
    println(xs.remove(1))
    xs.reverse()
    println([xs, xs.slice(1, 3)])
    println(xs.join(", "))
    for i, x in xs { print("${i}:${x} ") }
    println()
}"#;
    let out = "7.0
[0.30000000000000004, 2.5, 1000.0, 2.5]
[7, 2, 3, 7, 4]
Point { x: 1.0, y: 2.5 }
hi STELLA, 3 things, ${not this}
[\"abab\", \"s\", \"cba\", \"a+b\"]
true
0h 1e 2y 
{\"bob\": 26, \"carol\": 40}
[0, -1, 2]
bob=26 carol=40 
{\"a\": 3, \"b\": 1, \"c\": 1}
{1, 2, 10}
[false, true]
[10, 30, 50, 80]
[\"n3\", \"n5\", \"n8\"]
[17, 3]
[true, true, false]
1
[[8, 5, 3, 99], [5, 3]]
8, 5, 3, 99
0:8 1:5 2:3 3:99 
";
    ok("prelude", src, out);
}

#[test]
fn enums_and_options() {
    let src = r#"
const PI = 3.0

enum Shape {
    Circle(radius: float),
    Rect { w: float, h: float = 1.0 },
    Empty,

    fn area(self) -> float {
        return match self {
            Circle(r) => PI * r * r,
            Rect { w, h } => w * h,
            Empty => 0.0,
        }
    }

    fn square(side: float) -> Shape {
        return .Rect { w: side, h: side }
    }
}

enum Expr {
    Num(int),
    Add(Expr, Expr),
    Mul(Expr, Expr),
}

fn eval(e: Expr) -> int {
    return match e {
        Num(n) => n,
        Add(a, b) => eval(a) + eval(b),
        Mul(Num(0), _) | Mul(_, Num(0)) => 0,
        Mul(a, b) => eval(a) * eval(b),
    }
}

enum Role { Admin, Member }

struct User {
    name: str,
    email: str?,
    role: Role = .Member,
}

fn domain(users: [User], name: str) -> str? {
    let u = users.find(u => u.name == name)?
    return u.email?.split("@")[1]
}

fn size(n: int) -> str {
    return match n {
        0 => "zero",
        1 | 2 | 3 => "small",
        x if x < 0 => "negative",
        _ => "big",
    }
}

fn main() -> void! {
    let shapes: [Shape] = [.Circle(1.0), Shape.Rect { w: 2.0 }, Shape.square(3.0), .Empty]
    println(shapes)
    println(shapes.map(s => s.area()))
    let e = Expr.Add(.Num(2), .Mul(.Num(3), .Num(4)))
    println("${e} = ${eval(e)} ${eval(.Mul(.Num(0), .Num(9)))}")
    println([Shape.Circle(1.0) == .Circle(1.0), Shape.Empty == .Circle(1.0), [1, 2] == [1, 2]])

    let users = [User { name: "ada", email: "ada@math.org", role: .Admin }, User { name: "bob" }]
    println(users[1])
    println([domain(users, "ada"), domain(users, "bob"), domain(users, "eve")])
    if let Admin = users[0].role { println("ada is admin") }
    if let u = users.find(u => u.name == "bob") { println("bob's email: ${u.email ?? "-"}") }
    let n: int? = none
    println([n ?? 7, n catch 8, some(3) ?? 0])
    match users.get(5) {
        some(u) => println(u.name),
        none => println("nobody"),
    }
    let Circle(r) = shapes[0] else { return err("not a circle") }
    let kind = if r > 0.5 { "big" } else { "small" }
    println("${r} ${kind}")
    println([size(0), size(2), size(-5), size(50)])
    let stack = [1, 2, 3]
    while let top = stack.last() {
        print(top)
        stack.pop()
    }
    println()
    let ages = {"ann": 3}
    println([ages.get("ann") ?? 0, ages.get("zed") ?? 0])
    println(to_json(users))
    println(to_json([Shape.Circle(1.0), .Empty]))
    let r2 = int("x") catch e { -1 }
    println(r2)
}"#;
    let out = r#"[Circle(radius: 1.0), Rect { w: 2.0, h: 1.0 }, Rect { w: 3.0, h: 3.0 }, Empty]
[3.0, 2.0, 9.0, 0.0]
Add(Num(2), Mul(Num(3), Num(4))) = 14 0
[true, false, true]
User { name: "bob", email: none, role: Member }
["math.org", none, none]
ada is admin
bob's email: -
[7, 8, 3]
nobody
1.0 big
["zero", "small", "negative", "big"]
321
[3, 0]
[{"name":"ada","email":"ada@math.org","role":"Admin"},{"name":"bob","email":null,"role":"Member"}]
[{"type":"Circle","radius":1.0},{"type":"Empty"}]
-1
"#;
    ok("enums", src, out);
}

#[test]
fn json_and_fs() {
    let dir = tmpdir("jsonfs");
    let file = dir.join("x.txt");
    let src = format!(
        r#"
import json
import fs

fn main() -> void! {{
    let doc = json.parse("{{\"user\": {{\"name\": \"ada\", \"tags\": [1, true, null]}}, \"e\": \"\\u00e9\"}}")?
    println(doc.stringify())
    println(doc.get("user")?.get("name")?.as_str() ?? "anon")
    println(doc.get("nope")?.as_str() ?? "anon")
    match json.parse("[1, 2") {{
        ok(v) => println(v),
        err(e) => println(e),
    }}
    fs.write("{f}", "hello\n")?
    fs.append("{f}", "more\n")?
    print(fs.read("{f}")?)
    println(fs.size("{f}"))
    println(fs.read("/nope") catch e {{ "failed" }})
}}"#,
        f = file.display()
    );
    ok("jsonfs", &src, "{\"user\":{\"name\":\"ada\",\"tags\":[1,true,null]},\"e\":\"\u{e9}\"}\nada\nanon\nbad JSON at 5: expected `,`, found the end\nhello\nmore\n11\nfailed\n");
}

/// A minimal WebSocket client: handshake, masked text frames, and reading frames back.
fn ws_connect(port: u16, path: &str) -> TcpStream {
    let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    write!(s, "GET {path} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n").unwrap();
    let mut head = Vec::new();
    let mut b = [0u8];
    while !head.ends_with(b"\r\n\r\n") {
        s.read_exact(&mut b).unwrap();
        head.push(b[0]);
    }
    let head = String::from_utf8(head).unwrap();
    // the accept key for the RFC 6455 sample nonce
    assert!(head.starts_with("HTTP/1.1 101") && head.contains("s3pPLMBiTxaQ9kYGzzhZRbK+xOo="), "{head}");
    s
}

fn ws_send(s: &mut TcpStream, msg: &str) {
    let mask = [1u8, 2, 3, 4];
    let mut f = vec![0x81, 0x80 | msg.len() as u8];
    f.extend(mask);
    f.extend(msg.bytes().enumerate().map(|(i, b)| b ^ mask[i % 4]));
    s.write_all(&f).unwrap();
}

fn ws_recv(s: &mut TcpStream) -> String {
    let mut h = [0u8; 2];
    s.read_exact(&mut h).unwrap();
    let mut d = vec![0u8; (h[1] & 127) as usize];
    s.read_exact(&mut d).unwrap();
    String::from_utf8(d).unwrap()
}

#[test]
fn websockets_and_middleware() {
    let src = r#"
import http

fn main() -> void! {
    let app = http.app()
    app.log = false
    app.use((req, res, next) => {
        res.set("x-seen", "yes")
        if req.path == "/blocked" {
            res.status(403).send("no")
            return
        }
        next()
    })
    app.get("/fail", (req, res) => {
        let n = int("x")?
        res.send(str(n))
    })
    app.put("/items/:id", (req, res) => res.status(201).send("put ${req.param("id")} ${req.query.get("q") ?? "-"} ${req.cookie("c") ?? "-"}"))
    app.get("/files/*", (req, res) => res.send("file ${req.param("*")}"))
    app.ws("/chat", (ws, req) => {
        let name = req.query.get("name") ?? "?"
        ws.send("welcome ${name}")
        ws.on_message(msg => {
            if msg == "who" {
                ws.send("${app.clients("/chat").len()} here")
            } else {
                ws.broadcast("${name}: ${msg}")
            }
        })
        ws.on_close(() => ws.broadcast("${name} left"))
    })
    let port = int(env("PORT"))?
    app.listen(port)?
}"#;
    let dir = tmpdir("ws");
    let (file, exe) = (dir.join("main.st"), dir.join("main"));
    fs::write(&file, src).unwrap();
    let c = Command::new(BIN).arg(&file).arg("-o").arg(&exe).output().unwrap();
    assert!(c.status.success(), "{}", String::from_utf8_lossy(&c.stderr));
    let port = (20000 + (std::process::id() + 7) % 20000) as u16;
    let mut server = Command::new(&exe).env("PORT", port.to_string()).stdout(Stdio::null()).spawn().unwrap();
    let send = |req: &str| -> String {
        for _ in 0..50 {
            if let Ok(mut s) = TcpStream::connect(("127.0.0.1", port)) {
                s.write_all(req.as_bytes()).unwrap();
                let mut out = String::new();
                s.read_to_string(&mut out).unwrap();
                return out;
            }
            thread::sleep(Duration::from_millis(50));
        }
        panic!("server never came up");
    };
    let blocked = send("GET /blocked HTTP/1.1\r\nConnection: close\r\n\r\n");
    let fail = send("GET /fail HTTP/1.1\r\nConnection: close\r\n\r\n");
    let put = send("PUT /items/a%20b?q=hi+there HTTP/1.1\r\nCookie: c=1; d=2\r\nConnection: close\r\n\r\n");
    let files = send("GET /files/a/b.txt HTTP/1.1\r\nConnection: close\r\n\r\n");
    let wrong = send("POST /items/1 HTTP/1.1\r\nConnection: close\r\n\r\n");

    let mut a = ws_connect(port, "/chat?name=ann");
    let mut b = ws_connect(port, "/chat?name=bob");
    let welcome = (ws_recv(&mut a), ws_recv(&mut b));
    ws_send(&mut a, "hello");
    let got = ws_recv(&mut b);
    ws_send(&mut b, "who");
    let who = ws_recv(&mut b);
    drop(b);
    let left = ws_recv(&mut a);
    server.kill().unwrap();

    assert!(blocked.starts_with("HTTP/1.1 403") && blocked.contains("x-seen: yes") && blocked.ends_with("no"), "{blocked}");
    assert!(fail.starts_with("HTTP/1.1 500") && fail.contains("not a number"), "{fail}");
    assert!(put.starts_with("HTTP/1.1 201") && put.ends_with("put a b hi there 1"), "{put}");
    assert!(files.ends_with("file a/b.txt"), "{files}");
    assert!(wrong.starts_with("HTTP/1.1 404"), "{wrong}");
    assert_eq!(welcome, ("welcome ann".into(), "welcome bob".into()));
    assert_eq!(got, "ann: hello");
    assert_eq!(who, "2 here");
    assert_eq!(left, "bob left");
}

/// The editor grammars are generated from the compiler's keyword table; the copies in `editors/`
/// must match (regenerate with `stellang grammar textmate|vim`).
#[test]
fn editor_grammars_are_current() {
    for (kind, file) in [("textmate", "editors/vscode/syntaxes/stellang.tmLanguage.json"), ("vim", "editors/nvim/syntax/stellang.vim")] {
        let out = Command::new(BIN).args(["grammar", kind]).output().unwrap();
        let want = String::from_utf8(out.stdout).unwrap();
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(file);
        assert_eq!(fs::read_to_string(&path).unwrap(), want, "{file} is stale: run `stellang grammar {kind} > {file}`");
    }
}

#[test]
fn language_server() {
    use std::io::BufRead;
    let dir = tmpdir("lsp");
    let file = dir.join("main.st");
    let uri = format!("file://{}", file.display());
    let src = "enum Shape { Circle(float), Empty }\n\n// How big it is.\nfn area(s: Shape) -> float {\n    return match s { Circle(r) => r * r, Empty => 0.0 }\n}\n\nfn main() {\n    let s = Shape.Circle(2.0)\n    println(area(s))\n    println(nope)\n}\n";
    fs::write(&file, src).unwrap();
    let mut lsp = Command::new(BIN).arg("lsp").stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
    let mut input = lsp.stdin.take().unwrap();
    let mut output = std::io::BufReader::new(lsp.stdout.take().unwrap());
    let mut send = |body: String| write!(input, "Content-Length: {}\r\n\r\n{body}", body.len()).unwrap();
    let mut recv = || -> String {
        let mut len = 0;
        loop {
            let mut line = String::new();
            output.read_line(&mut line).unwrap();
            if line.trim().is_empty() { break }
            if let Some(n) = line.strip_prefix("Content-Length: ") { len = n.trim().parse().unwrap() }
        }
        let mut buf = vec![0; len];
        output.read_exact(&mut buf).unwrap();
        String::from_utf8(buf).unwrap()
    };
    let text = src.replace('\n', "\\n").replace('"', "\\\"");
    send(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}"#.into());
    let init = recv();
    send(format!(r#"{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":"{uri}","languageId":"stellang","version":1,"text":"{text}"}}}}}}"#));
    let diags = recv();
    send(format!(r#"{{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{{"textDocument":{{"uri":"{uri}"}},"position":{{"line":9,"character":13}}}}}}"#));
    let hover = recv();
    send(format!(r#"{{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{{"textDocument":{{"uri":"{uri}"}},"position":{{"line":8,"character":9}}}}}}"#));
    let hover_let = recv();
    send(format!(r#"{{"jsonrpc":"2.0","id":4,"method":"textDocument/semanticTokens/full","params":{{"textDocument":{{"uri":"{uri}"}}}}}}"#));
    let tokens = recv();
    send(r#"{"jsonrpc":"2.0","id":5,"method":"shutdown"}"#.into());
    recv();
    send(r#"{"jsonrpc":"2.0","method":"exit"}"#.into());
    lsp.wait().unwrap();
    assert!(init.contains("semanticTokensProvider") && init.contains("hoverProvider"), "{init}");
    assert!(diags.contains("unknown name `nope`") && diags.contains(r#""line":10"#), "{diags}");
    assert!(hover.contains("fn area(s: Shape) -> float") && hover.contains("How big it is."), "{hover}");
    assert!(hover_let.contains("let s: Shape"), "{hover_let}");
    assert!(tokens.contains(r#""data":["#) && tokens.len() > 100, "{tokens}");
}
