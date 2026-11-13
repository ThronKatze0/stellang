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
        ("fn main() { println(1.5 & 1) }", "works on ints, not float"),
        ("fn main() { println(0x) }", "expected digits after the number prefix"),
        ("fn main() { println(0b102) }", "not a valid base-2 number"),
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

#[test]
fn generics_and_traits() {
    let src = r##"
trait Show {
    fn show(self) -> str
    fn loud(self) -> str { return self.show().upper() + "!" }
}

struct Point { x: int, y: int }
impl Show for Point {
    fn show(self) -> str { return "(${self.x}, ${self.y})" }
}
impl Show for int {
    fn show(self) -> str { return "#${self}" }
}

struct Box<T> {
    value: T

    fn get(self) -> T { return self.value }
    fn map<U>(self, f: fn(T) -> U) -> Box<U> { return Box { value: f(self.value) } }
}

struct Stack<T> {
    items: [T] = []

    fn new() -> Stack<T> { return Stack {} }
    fn push(self, x: T) { self.items.push(x) }
    fn pop(self) -> T? { return self.items.pop() }
    fn len(self) -> int { return self.items.len() }
}

enum Tree<T> {
    Leaf
    Node(Tree<T>, T, Tree<T>)

    fn size(self) -> int {
        return match self {
            .Leaf => 0,
            .Node(l, _, r) => l.size() + 1 + r.size()
        }
    }
}

fn insert<T>(t: Tree<T>, x: T, less: fn(T, T) -> bool) -> Tree<T> {
    return match t {
        .Leaf => Tree.Node(.Leaf, x, .Leaf),
        .Node(l, v, r) => if less(x, v) { Tree.Node(insert(l, x, less), v, r) } else { Tree.Node(l, v, insert(r, x, less)) }
    }
}

fn walk<T>(t: Tree<T>, out: [T]) {
    if let .Node(l, v, r) = t {
        walk(l, out)
        out.push(v)
        walk(r, out)
    }
}

fn first<T>(xs: [T]) -> T? {
    if xs.is_empty() { return none }
    return xs[0]
}

fn largest<T>(xs: [T]) -> T {
    var best = xs[0]
    for x in xs { if x > best { best = x } }
    return best
}

fn all_shown<T: Show>(xs: [T]) -> str {
    return xs.map(x => x.show()).join(" ")
}

fn pair<A, B>(a: A, b: B) -> Pair<A, B> { return Pair { a, b } }
struct Pair<A, B> { a: A, b: B }

fn main() {
    let b = Box { value: 41 }
    println(b.get() + 1)
    let s = b.map(x => "n=${x}")
    println(s.value)
    let st: Stack<str> = Stack.new()
    st.push("a")
    st.push("b")
    println(st.len())
    println(st.pop() ?? "?")
    var t: Tree<int> = .Leaf
    for x in [5, 2, 8, 1, 9] { t = insert(t, x, (a, b) => a < b) }
    println(t.size())
    let out: [int] = []
    walk(t, out)
    println(out)
    println(first(["x", "y"]) ?? "none")
    println(largest([3.5, 9.25, 1.0]))
    println(largest(["pear", "apple"]))
    println(all_shown([Point { x: 1, y: 2 }, Point { x: 3, y: 4 }]))
    println(all_shown([1, 2]))
    println(Point { x: 0, y: 0 }.loud())
    let p = pair(1, "one")
    println(p)
    println(b)
}
"##;
    ok("generics", src, "42\nn=41\n2\nb\n5\n[1, 2, 5, 8, 9]\nx\n9.25\npear\n(1, 2) (3, 4)\n#1 #2\n(0, 0)!\nPair { a: 1, b: \"one\" }\nBox { value: 41 }\n");
    let bad = |src: &str, msg: &str| {
        let (code, _, err) = run("generics-bad", src);
        assert_eq!(code, -1);
        assert!(err.contains(msg), "{err}");
    };
    bad("trait Show { fn show(self) -> str }\nfn f<T: Show>(x: T) -> str { return x.show() }\nfn main() { println(f(1.5)) }", "float doesn't implement `Show`");
    bad("struct Stack<T> { items: [T] = []\n fn new() -> Stack<T> { return Stack {} } }\nfn main() { let s = Stack.new() }", "can't tell what `T` is");
    bad("struct Box<T> { v: T }\nfn main() { let b: Box = Box { v: 1 } }", "`Box` needs type arguments");
    bad("fn bad<T>(x: T) -> T { return x.nope() }\nfn main() { bad(1) }", "(in `bad<int>`)");
    bad("trait Show { fn show(self) -> str }\nstruct P {}\nimpl Show for P { }\nfn main() {}", "missing `fn show`");
}

#[test]
fn jsx_server_rendering() {
    let src = r##"
struct Todo { id: int, title: str, done: bool = false }

struct CardProps { title: str, footer: str = "the end", children: Node }

fn Card(p: CardProps) -> Node {
    return <section class="card">
        <h2>{p.title}</h2>
        {p.children}
        <footer>{p.footer}</footer>
    </section>
}

fn Badge(n: int, label: str?) -> Node {
    return <span class="badge" title={label}>{n}</span>
}

fn TodoList(todos: [Todo]) -> Node {
    return <ul>
        for t in todos {
            <li key={t.id} class={if t.done { "done" } else { "open" }}>
                <input type="checkbox" checked={t.done} onclick={() => println("x")} />
                " ${t.title}"
            </li>
        }
        if todos.is_empty() { <li>"nothing to do"</li> }
    </ul>
}

fn main() {
    let todos = [Todo { id: 1, title: "write <jsx>" }, Todo { id: 2, title: "ship it", done: true }]
    let page = <>
        <Card title="Todos & more">
            <TodoList todos={todos} />
            <Badge n={todos.len()} />
            <Badge n={7} label="seven" />
        </Card>
        {todos.map(t => <i>{t.title}</i>)}
    </>
    println(page)
}
"##;
    let want = "<section class=\"card\"><h2>Todos &amp; more</h2><ul><li data-key=\"1\" class=\"open\"><input type=\"checkbox\"> write &lt;jsx&gt;</li><li data-key=\"2\" class=\"done\"><input type=\"checkbox\" checked> ship it</li></ul><span class=\"badge\">2</span><span class=\"badge\" title=\"seven\">7</span><footer>the end</footer></section><i>write &lt;jsx&gt;</i><i>ship it</i>\n";
    ok("jsx", src, want);
    let bad = |src: &str, msg: &str| {
        let (code, _, err) = run("jsx-bad", src);
        assert_eq!(code, -1);
        assert!(err.contains(msg), "{err}");
    };
    bad("fn main() { let x = <div><p>\"a\"</div> }", "`</div>` doesn't close `<p>`");
    bad("fn main() { let x = <input>\"a\"</input> }", "<input> can't have children");
    bad("fn Card(title: str) -> Node { return <b>{title}</b> }\nfn main() { let x = <Card titel=\"a\" /> }", "<Card> has no prop `titel`");
    bad("fn Card(title: str) -> Node { return <b>{title}</b> }\nfn main() { let x = <Card /> }", "<Card> needs `title`");
    bad("fn main() { let x = <button onclick={() => 1}>\"a\"</button>\n let y = <b onclick={(a: int) => println(a)} /> }", "an event handler is a fn() or a fn(str)");
}

#[test]
fn from_json_decodes_types() {
    let src = r##"
import json

enum Shape { Circle(float), Rect { w: float, h: float }, Pair(int, str), Empty }
enum Color { Red, Green }
struct Todo { id: int, title: str, done: bool = false, tags: [str] = [], note: str? }
struct Data { todos: [Todo], counts: {str: int}, byid: {int: str}, shapes: [Shape], color: Color, ids: {int} }

fn main() -> void! {
    let d = Data {
        todos: [Todo { id: 1, title: "a", tags: ["x"] }, Todo { id: 2, title: "b \"q\"", done: true, note: "n" }],
        counts: {"a": 1}, byid: {7: "seven"}, shapes: [Shape.Circle(2.5), Shape.Rect { w: 1.0, h: 2.0 }, Shape.Pair(3, "p"), Shape.Empty],
        color: .Green, ids: {1, 2}
    }
    let text = to_json(d)
    println(text)
    let back: Data = from_json(text)?
    println(to_json(back) == text)
    let t: Todo = from_json("{\"id\": 5, \"title\": \"partial\"}")?
    println(t)
    let xs: [int] = from_json("[1, 2, 3]")?
    println(xs)
    let bad: Todo = from_json("{\"id\": 5}") catch (Todo { id: 0, title: "fallback" })
    println(bad.title)
    let ys: [int] = from_json("[1, \"x\"]") catch m {
        println(m)
        [0]
    }
    println(ys)
    let r: [int]! = from_json("{oops")
    if let err(m) = r { println(m) }
}
"##;
    let (code, out, err) = run("fromjson", src);
    assert_eq!(code, 0, "{err}");
    let lines: Vec<&str> = out.lines().collect();
    assert_eq!(lines[1], "true");
    assert_eq!(lines[2], "Todo { id: 5, title: \"partial\", done: false, tags: [], note: none }");
    assert_eq!(lines[3..].join("\n"), "[1, 2, 3]\nfallback\nfrom_json: expected a number\n[0]\nbad JSON at 1: expected `\"`, found `o`");
}

/// `--web` builds a WebAssembly module and its loader (when this machine has the WASI libc).
#[test]
fn web_build() {
    let dir = tmpdir("web");
    let file = dir.join("app.st");
    fs::write(&file, "import web\n\nfn App() -> Node {\n    let n = signal(0)\n    return <button onclick={() => n.set(n.get() + 1)}>\"clicked ${n.get()}\"</button>\n}\n\nfn main() {\n    web.mount(\"#app\", () => <App />)\n}\n").unwrap();
    let out = Command::new(BIN).arg("--web").arg(&file).arg("-o").arg(dir.join("dist/app")).output().unwrap();
    let err = String::from_utf8_lossy(&out.stderr);
    if !out.status.success() && err.contains("WASI") {
        eprintln!("skipping: no WASI libc here");
        return;
    }
    assert!(out.status.success(), "{err}");
    let wasm = fs::read(dir.join("dist/app.wasm")).unwrap();
    assert_eq!(&wasm[..4], b"\0asm");
    assert!(fs::read_to_string(dir.join("dist/app.js")).unwrap().contains("st_dispatch"));
    assert!(fs::read_to_string(dir.join("dist/app.html")).unwrap().contains("<script src=\"app.js\">"));
    // the same app natively: mount renders once to stdout (handlers aren't rendered on the server)
    let (code, html, _) = run("web-native", &fs::read_to_string(&file).unwrap());
    assert_eq!((code, html.as_str()), (0, "<button>clicked 0</button>\n"));
    // server-only modules are refused
    fs::write(&file, "import http\nfn main() {}\n").unwrap();
    let out = Command::new(BIN).arg("--web").arg(&file).output().unwrap();
    assert!(String::from_utf8_lossy(&out.stderr).contains("`import http` only works on the server"));
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
    // completion works on code that doesn't parse yet: `.` after a value, and a `.Variant` shorthand
    let change = |version: u32, text: &str| {
        let t = text.replace('\n', "\\n").replace('"', "\\\"");
        format!(r#"{{"jsonrpc":"2.0","method":"textDocument/didChange","params":{{"textDocument":{{"uri":"{uri}","version":{version}}},"contentChanges":[{{"text":"{t}"}}]}}}}"#)
    };
    send(change(2, &src.replace("    println(nope)\n", "    let t: Shape = .\n")));
    recv(); // diagnostics
    send(format!(r#"{{"jsonrpc":"2.0","id":6,"method":"textDocument/completion","params":{{"textDocument":{{"uri":"{uri}"}},"position":{{"line":10,"character":20}}}}}}"#));
    let variants = recv();
    send(change(3, &src.replace("    println(nope)\n", "    s.\n")));
    recv();
    send(format!(r#"{{"jsonrpc":"2.0","id":7,"method":"textDocument/completion","params":{{"textDocument":{{"uri":"{uri}"}},"position":{{"line":10,"character":6}}}}}}"#));
    let members = recv();
    // a quick fix for a misspelled name
    send(change(4, &src.replace("println(nope)", "println(aera(s))")));
    let tdiags = recv();
    let diag = tdiags.split(r#""diagnostics":["#).nth(1).unwrap_or("").trim_end_matches("]}}").to_string();
    send(format!(r#"{{"jsonrpc":"2.0","id":8,"method":"textDocument/codeAction","params":{{"textDocument":{{"uri":"{uri}"}},"range":{{"start":{{"line":10,"character":0}},"end":{{"line":10,"character":0}}}},"context":{{"diagnostics":[{diag}]}}}}}}"#));
    let fixes = recv();
    send(r#"{"jsonrpc":"2.0","id":5,"method":"shutdown"}"#.into());
    recv();
    send(r#"{"jsonrpc":"2.0","method":"exit"}"#.into());
    lsp.wait().unwrap();
    assert!(init.contains("semanticTokensProvider") && init.contains("hoverProvider"), "{init}");
    assert!(diags.contains("unknown name `nope`") && diags.contains(r#""line":10"#), "{diags}");
    assert!(hover.contains("fn area(s: Shape) -> float") && hover.contains("How big it is."), "{hover}");
    assert!(hover_let.contains("let s: Shape"), "{hover_let}");
    assert!(tokens.contains(r#""data":["#) && tokens.len() > 100, "{tokens}");
    assert!(variants.contains(r#""label":"Circle""#) && variants.contains(r#""label":"Empty""#) && !variants.contains(r#""label":"area""#), "{variants}");
    assert!(members.contains(r#""label":"match""#) && members.contains("match s {"), "{members}");
    assert!(fixes.contains("Change to `area`"), "{fixes}");
}

#[test]
fn default_parameters() {
    let src = r#"
const BASE = 10
fn add(a: int, b: int = BASE, tags: {str: str} = {}, names: [str] = []) -> int {
    return a + b + tags.len() + names.len()
}
struct S {
    x: int,
    fn get(self, plus: int = 1) -> int { return self.x + plus }
}
fn main() {
    println(add(1))
    println(add(1, 2))
    println(add(1, 2, {"a": "b"}, ["x", "y"]))
    println(S { x: 5 }.get())
    println(S { x: 5 }.get(10))
}"#;
    ok("defaults", src, "11\n3\n6\n6\n15\n");
    let src = r#"
enum Role { Admin, Member }
const BASE = 10
fn twice(x: int) -> int { return x * 2 }
struct U { name: str, role: Role = .Member, w: float = 1, tags: [str] = [], note: str? }
enum Shape { Rect { w: float, h: float = twice(BASE) } }
fn f(a: int = twice(BASE), r: Role = .Admin, m: {str: int} = {}) -> str { return "${a} ${r} ${m.len()}" }
fn main() {
    println(f())
    println(U { name: "x" })
    println(Shape.Rect { w: 1.0 })
}"#;
    ok("defaults_kinds", src, "20 Admin 0\nU { name: \"x\", role: Member, w: 1.0, tags: [], note: none }\nRect { w: 1.0, h: 20.0 }\n");
    for (src, want) in [
        ("fn f(a: int = 1, b: int) {}\nfn main() {}", "needs a default too"),
        ("fn f(a: int, b: int = 2) {}\nfn main() { f() }", "takes 1 to 2 argument(s), got 0"),
        ("fn f(a: int = 2) {}\nfn main() { f(1, 2) }", "takes 0 to 1 argument(s), got 2"),
        // a wrong default is caught where it's declared, even if no call ever leaves it out
        ("fn f(a: int = \"x\") {}\nfn main() {}", "1:15: error: expected int, found str"),
        ("struct S { a: int = \"x\" }\nfn main() {}", "1:21: error: expected int, found str"),
        ("enum E { V { a: str = 1 } }\nfn main() {}", "1:23: error: expected str, found int"),
        ("struct S { x: int, fn g(self, a: bool = 3) {} }\nfn main() {}", "1:41: error: expected bool, found int"),
        ("fn f(a: int, b: int = a) {}\nfn main() {}", "unknown name `a`"),
    ] {
        let (code, _, err) = run("defaults_bad", src);
        assert!(code == -1 && err.contains(want), "{src}\n{err}");
    }
}

#[test]
fn url_encode_sleep_now_ms() {
    let src = r#"
fn main() {
    println(url_encode("Hide on bush"))
    println(url_encode("a#b/c?d=e&f+g"))
    println(url_encode("Grüße"))
    println(url_encode("🦀"))
    println(url_encode("AZaz09-_.~"))
    println(url_encode(""))
    let t = now_ms()
    sleep(50)
    println(now_ms() - t >= 50)
}"#;
    ok(
        "url_encode",
        src,
        "Hide%20on%20bush\na%23b%2Fc%3Fd%3De%26f%2Bg\nGr%C3%BC%C3%9Fe\n%F0%9F%A6%80\nAZaz09-_.~\n\ntrue\n",
    );
    let (code, _, err) = run("sleep_bad", "fn main() { sleep(\"1\") }");
    assert!(code == -1 && err.contains("expected int"), "{err}");
    let (code, _, err) = run("now_ms_bad", "fn now_ms() -> int { return 1 }\nfn main() {}");
    assert!(code == -1 && err.contains("already defined"), "{err}");
}

/// `args()`, `read_line()` and `exit(code)`: command-line programs.
#[test]
fn args_read_line_exit() {
    let dir = tmpdir("cli");
    let (file, exe) = (dir.join("main.st"), dir.join("main"));
    fs::write(
        &file,
        r#"
fn main() {
    let a = args()
    println("${a.len()} ${a}")
    print("name? ")
    var n = 0
    while let line = read_line() {
        n += 1
        println("[${line}]")
    }
    println("lines ${n}")
    if a.contains("--fail") {
        exit(3)
    }
    println("done")
}"#,
    )
    .unwrap();
    let c = Command::new(BIN).arg(&file).arg("-o").arg(&exe).output().unwrap();
    assert!(c.status.success(), "{}", String::from_utf8_lossy(&c.stderr));
    let go = |argv: &[&str], input: &str| {
        let mut p = Command::new(&exe).args(argv).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
        p.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
        let o = p.wait_with_output().unwrap();
        (o.status.code().unwrap(), String::from_utf8_lossy(&o.stdout).into_owned())
    };
    // CRLF is stripped, and a last line without a line break still counts
    assert_eq!(go(&["x", "y z"], "ada\r\nbob\nlast"), (0, "2 [\"x\", \"y z\"]\nname? [ada]\n[bob]\n[last]\nlines 3\ndone\n".into()));
    // exit flushes what was printed and ends with its code
    assert_eq!(go(&["--fail"], ""), (3, "1 [\"--fail\"]\nname? lines 0\n".into()));
    assert_eq!(go(&[], "\n"), (0, "0 []\nname? []\nlines 1\ndone\n".into()));

    let (code, out, _) = run("exit_int", "fn main() -> int {\n    println(\"bye\")\n    exit(7)\n    return 1\n}");
    assert_eq!((code, out.as_str()), (7, "bye\n"));
    let (code, _, err) = run("exit_bad", "fn main() { exit(\"1\") }");
    assert!(code == -1 && err.contains("expected int"), "{err}");
    let (code, _, err) = run("args_bad", "fn main() { println(args(1)) }");
    assert!(code == -1 && err.contains("takes no arguments"), "{err}");
    let (code, _, err) = run("read_line_type", "fn main() { let s: str = read_line() }");
    assert!(code == -1, "{err}");
}

/// `http.fetch` against a local stellang server: statuses (404 and 429 are answers, not errors),
/// headers, JSON, POST bodies, and errors for refused connections and timeouts. No internet needed.
#[test]
fn http_fetch() {
    let dir = tmpdir("fetch");
    let server_src = r#"
import http

fn main() -> void! {
    let app = http.app()
    app.log = false
    app.get("/users/:id", (req, res) => {
        if req.param("id") == "404" {
            res.status(404).json("{\"status\":{\"message\":\"Data not found\"}}")
            return
        }
        res.set("X-Rate", "7").json("{\"id\":\"${req.param("id")}\",\"token\":\"${req.header("x-riot-token") ?? ""}\"}")
    })
    app.get("/limited", (req, res) => res.status(429).set("Retry-After", "2").send("slow down"))
    app.post("/echo", (req, res) => res.status(201).send("${req.method} ${req.header("x-test") ?? "-"} ${req.body}"))
    app.delete("/items/:id", (req, res) => res.send("deleted ${req.param("id")}"))
    app.get("/cookies", (req, res) => {
        res.cookie("a", "1; Expires=Wed, 21 Oct 2026 07:28:00 GMT").cookie("b", "2").send("${req.query.get("start") ?? "-"} ${req.query.get("q") ?? "-"}")
    })
    app.listen(int(env("PORT"))?)?
}"#;
    let client_src = r#"
import http
import json

fn main() -> void! {
    let base = "http://127.0.0.1:${env("PORT")}"
    let r = http.fetch("${base}/users/${url_encode("ada lovelace")}", {"X-Riot-Token": "secret"})?
    println(r.status)
    println(r.header("content-type") ?? "?")
    println(r.header("X-RATE") ?? "?")
    println(r.headers.get("x-rate") ?? "?")
    let user = r.json()?
    println(user.get("id")?.as_str() ?? "?")
    println(user.get("token")?.as_str() ?? "?")

    let missing = http.fetch("${base}/users/404")?
    println(missing.status)
    println(missing.json()?.get("status")?.get("message")?.as_str() ?? "?")

    let limited = http.fetch("${base}/limited")?
    println(limited.status)
    println((int(limited.header("retry-after") ?? "1") catch 1) * 1000)

    let posted = http.request("post", "${base}/echo", {"X-Test": "yes"}, "{\"a\":1}")?
    println("${posted.status} ${posted.body}")
    let deleted = http.request("DELETE", "${base}/items/3")?
    println("${deleted.status} ${deleted.body}")

    let c = http.fetch("${base}/cookies?${http.query({"start": "0", "q": "a b&c"})}")?
    println(c.body)
    println(c.header_all("Set-Cookie"))
    println(c.header_all("x-none").len())
    println(http.query({}) == "")

    let refused = http.fetch("http://127.0.0.1:${env("CLOSED_PORT")}/") catch e {
        println("refused: ${e}")
        return
    }
    println("unexpected ${refused.status}")
}"#;
    let build = |name: &str, src: &str| {
        let (file, exe) = (dir.join(format!("{name}.st")), dir.join(name));
        fs::write(&file, src).unwrap();
        let c = Command::new(BIN).arg(&file).arg("-o").arg(&exe).output().unwrap();
        assert!(c.status.success(), "{}", String::from_utf8_lossy(&c.stderr));
        exe
    };
    let (server_exe, client_exe) = (build("server", server_src), build("client", client_src));
    let port = (20000 + (std::process::id() + 13) % 20000) as u16;
    let mut server = Command::new(&server_exe).env("PORT", port.to_string()).stdout(Stdio::null()).spawn().unwrap();
    for _ in 0..100 {
        if TcpStream::connect(("127.0.0.1", port)).is_ok() {
            break;
        }
        thread::sleep(Duration::from_millis(50));
    }
    // a port nobody listens on
    let closed = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let closed_port = closed.local_addr().unwrap().port();
    drop(closed);
    let out = Command::new(&client_exe).env("PORT", port.to_string()).env("CLOSED_PORT", closed_port.to_string()).output().unwrap();
    server.kill().unwrap();
    let (stdout, stderr) = (String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    assert!(out.status.success(), "{stdout}\n{stderr}");
    let lines: Vec<&str> = stdout.lines().collect();
    let want = [
        "200",
        "application/json",
        "7",
        "7",
        "ada lovelace",
        "secret",
        "404",
        "Data not found",
        "429",
        "2000",
        "201 POST yes {\"a\":1}",
        "200 deleted 3",
        "0 a b&c",
        r#"["a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/; HttpOnly", "b=2; Path=/; HttpOnly"]"#,
        "0",
        "true",
    ];
    assert_eq!(lines.len(), want.len() + 1, "{stdout}");
    assert_eq!(lines[..want.len()], want);
    assert!(lines[want.len()].starts_with("refused: connect: GET http://127.0.0.1:"), "{stdout}");
}

/// A server that accepts the connection but never answers: fetch gives up after `timeout_ms` with an error.
#[test]
fn http_fetch_timeout() {
    let hang = std::net::TcpListener::bind("127.0.0.1:0").unwrap(); // never accepted: the kernel queues the connection
    let port = hang.local_addr().unwrap().port();
    let src = format!(
        r#"
import http

fn main() {{
    let start = now_ms()
    let r = http.fetch("http://127.0.0.1:{port}/slow", {{}}, 300) catch e {{
        println("error after ${{now_ms() - start >= 250 && now_ms() - start < 5000}}")
        println(e.starts_with("timeout: GET http://127.0.0.1:"))
        return
    }}
    println("got ${{r.status}}")
}}"#
    );
    let (code, out, err) = run("fetch_timeout", &src);
    drop(hang);
    assert_eq!((code, out.as_str(), err.as_str()), (0, "error after true\ntrue\n", ""));
}

/// A hand-written keep-alive server that numbers its connections: three fetches share one connection,
/// and a body over 64 MB stops with a `too_large:` error. Unknown hosts give `dns:`.
#[test]
fn http_fetch_reuse_and_limits() {
    use std::io::{BufRead, BufReader};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    thread::spawn(move || {
        for (n, conn) in listener.incoming().enumerate() {
            let Ok(conn) = conn else { return };
            thread::spawn(move || {
                let mut w = conn.try_clone().unwrap();
                let mut r = BufReader::new(conn);
                loop {
                    let mut first = String::new();
                    if r.read_line(&mut first).unwrap_or(0) == 0 {
                        return;
                    }
                    loop {
                        let mut line = String::new();
                        if r.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                            break;
                        }
                    }
                    if first.contains("/big") {
                        let size = (64usize << 20) + 1;
                        if write!(w, "HTTP/1.1 200 OK\r\nContent-Length: {size}\r\n\r\n").is_err() {
                            return;
                        }
                        let chunk = vec![b'a'; 1 << 20];
                        let mut left = size;
                        while left > 0 {
                            let k = left.min(chunk.len());
                            if w.write_all(&chunk[..k]).is_err() {
                                return;
                            }
                            left -= k;
                        }
                    } else {
                        let body = format!("conn {}", n + 1);
                        if write!(w, "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{body}", body.len()).is_err() {
                            return;
                        }
                    }
                }
            });
        }
    });
    let src = format!(
        r#"
import http

fn main() -> void! {{
    let base = "http://127.0.0.1:{port}"
    for i in 0..3 {{
        println(http.fetch("${{base}}/n/${{i}}")?.body)
    }}
    let big = http.fetch("${{base}}/big", {{}}, 20000) catch e {{
        println(e.starts_with("too_large: GET ${{base}}/big: "))
        return
    }}
    println("unexpected ${{big.body.len()}}")
}}"#
    );
    ok("fetch_reuse", &src, "conn 1\nconn 1\nconn 1\ntrue\n");
    let src = r#"
import http

fn main() {
    let r = http.fetch("http://no-such-host.invalid/", {}, 3000) catch e {
        println(e.starts_with("dns: GET http://no-such-host.invalid/: "))
        return
    }
    println("got ${r.status}")
}"#;
    ok("fetch_dns", src, "true\n");
}

#[test]
fn url_decode_builtin() {
    let src = r#"
fn main() {
    println(url_decode("Hide%20on%20bush"))
    println(url_decode("a+b%2Bc"))
    println(url_decode("Gr%C3%BC%C3%9Fe"))
    println(url_decode("100%"))
    println(url_decode(url_encode("a/b?c=d&e+f 🦀")))
}"#;
    ok("url_decode", src, "Hide on bush\na b+c\nGrüße\n100%\na/b?c=d&e+f 🦀\n");
    let (code, _, err) = run("url_decode_bad", "fn main() { url_decode(1) }");
    assert!(code == -1 && err.contains("expected str"), "{err}");
}

/// Defaults where the types only become known per instance: generic functions and types, trait default
/// methods, methods on builtin types, and JSX props.
#[test]
fn defaults_with_generics_traits_and_jsx() {
    let src = r#"
struct Box<T> { v: T, n: int = 3, tags: [T] = [] }
fn wrap<T>(x: T, times: int = 2, extra: [T] = []) -> str { return "${x} ${times} ${extra.len()}" }
trait Greet {
    fn hi(self, p: str = "hey") -> str { return "${p} from ${self.name()}" }
    fn name(self) -> str
}
struct P { n: str }
impl Greet for P { fn name(self) -> str { return self.n } }
impl int { fn plus(self, k: int = 1) -> int { return self + k } }
fn Badge(label: str, n: int = 0) -> Node { return <b title={label}>{n}</b> }
fn main() {
    println(wrap(5))
    println(wrap("a", 7, ["b"]))
    println(Box { v: 1 })
    println(Box { v: "s" })
    println(P { n: "ada" }.hi())
    println(P { n: "ada" }.hi("yo"))
    println(41.plus())
    println(<Badge label="x" />)
}"#;
    ok(
        "defaults_generic",
        src,
        "5 2 0\na 7 1\nBox { v: 1, n: 3, tags: [] }\nBox { v: \"s\", n: 3, tags: [] }\nhey from ada\nyo from ada\n42\n<b title=\"x\">0</b>\n",
    );
    for (src, want) in [
        ("fn wrap<T>(x: T, n: int = \"x\") -> int { return n }\nfn main() { println(wrap(1)) }", "1:27: error: expected int, found str"),
        ("fn wrap<T>(x: T, n: int = 1) -> int { return n }\nfn main() { println(wrap()) }", "`wrap` takes 1 to 2 argument(s), got 0"),
    ] {
        let (code, _, err) = run("defaults_generic_bad", src);
        assert!(code == -1 && err.contains(want), "{src}\n{err}");
    }
}

/// `chars()` splits by character (UTF-8 aware), and """strings""" span lines.
#[test]
fn chars_and_long_strings() {
    let src = "const CSS = \"\"\"\n  a { color: \"red\" }\n  b ${1 + 1}\n\"\"\"\nfn main() {\n    let cs = \"aß€✦\".chars()\n    println(\"${cs.len()} ${cs[1]} ${cs[3]}\")\n    print(CSS)\n}\n";
    assert_eq!(run("chars_long", src), (0, "4 ß ✦\n  a { color: \"red\" }\n  b 2\n".into(), "".into()));
}

#[test]
fn bitwise_and_hex() {
    let src = r#"
struct Box<T> { v: T }
fn main() {
    let b: Box<Box<int>> = Box { v: Box { v: 0xff } }   // `>>` still closes two type arguments
    println(b.v.v)
    println(0x10 | 0b0011 & 0b10)        // & binds tighter than |
    println(1 << 40 >> 38)
    println(~0 ^ 0xF0)
    println(0xFFFF_FFFF_FFFF_FFFF)       // 64 bits: -1
    println(0o755)
    println(5 & 4 == 4)                  // and tighter than ==
    println(1 << 64)                     // shift amounts wrap at 64
    println(-16 >> 2)                    // arithmetic shift
}
"#;
    ok("bitwise", src, "255\n18\n4\n-241\n-1\n493\ntrue\n1\n-4\n");
}

/// `stellang --kernel`: StellaOS boots in QEMU, runs shell commands typed on the serial console,
/// and powers off with main's exit code. Skipped when QEMU isn't installed.
#[test]
fn kernel_boots_stellaos() {
    use std::io::Write;
    use std::process::Stdio;
    if Command::new("qemu-system-riscv64").arg("--version").output().is_err() {
        eprintln!("skipped: no qemu-system-riscv64");
        return;
    }
    let dir = tmpdir("kernel");
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let elf = dir.join("os.elf");
    let c = Command::new(BIN).arg("--kernel").arg(root.join("examples/stellaos/os.st")).arg("-o").arg(&elf).output().unwrap();
    assert!(c.status.success(), "{}", String::from_utf8_lossy(&c.stderr));

    let mut q = Command::new("qemu-system-riscv64")
        .args(["-machine", "virt", "-m", "128M", "-nographic", "-bios", "default", "-kernel"])
        .arg(&elf)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = q.stdin.take().unwrap();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(1500));
        for cmd in ["write a.txt hi there", "cat a.txt", "calc (1 << 10) | 0x0f", "ls", "mem", "nope", "shutdown"] {
            stdin.write_all(format!("{cmd}\r").as_bytes()).unwrap();
            stdin.flush().unwrap();
            std::thread::sleep(std::time::Duration::from_millis(300));
        }
    });
    let out = q.wait_with_output().unwrap();
    let text = String::from_utf8_lossy(&out.stdout).replace('\r', "");
    assert_eq!(out.status.code(), Some(0), "{text}");
    for want in ["StellaOS 0.3", "hi there\n", "1039  (0x40f)", "a.txt  (9 B)", "hello.st", "RAM      128.0 MiB", "unknown command: nope", "bye!"] {
        assert!(text.contains(want), "missing {want:?} in:\n{text}");
    }

    // a panic in the kernel: QEMU exits with 101, like a native program
    let file = dir.join("boom.st");
    fs::write(&file, "import kernel\nfn main() {\n let xs = [1]\n println(xs[3])\n}\n").unwrap();
    let c = Command::new(BIN).arg("--kernel").arg(&file).arg("-o").arg(dir.join("boom.elf")).output().unwrap();
    assert!(c.status.success(), "{}", String::from_utf8_lossy(&c.stderr));
    let out = Command::new("qemu-system-riscv64")
        .args(["-machine", "virt", "-m", "64M", "-nographic", "-bios", "default", "-kernel"])
        .arg(dir.join("boom.elf"))
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(101));
    assert!(String::from_utf8_lossy(&out.stdout).contains("boom.st:4:12: panic: index out of bounds"));

    // host-only modules are refused
    fs::write(&file, "import http\nfn main() {}\n").unwrap();
    let c = Command::new(BIN).arg("--kernel").arg(&file).output().unwrap();
    assert!(String::from_utf8_lossy(&c.stderr).contains("needs a host operating system"));
}

/// StellaOS's desktop, driven like a person would: keys typed on the (virtio) keyboard go to the
/// focused Terminal window and from there to the shell; a double click on a desktop icon opens an
/// app; files written in one boot are on the disk in the next.
#[test]
fn stellaos_desktop() {
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixStream;
    use std::process::Stdio;
    use std::time::Duration;
    if Command::new("qemu-system-riscv64").arg("--version").output().is_err() {
        eprintln!("skipped: no qemu-system-riscv64");
        return;
    }
    let dir = tmpdir("desktop");
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let elf = dir.join("os.elf");
    let c = Command::new(BIN).arg("--kernel").arg(root.join("examples/stellaos/os.st")).arg("-o").arg(&elf).output().unwrap();
    assert!(c.status.success(), "{}", String::from_utf8_lossy(&c.stderr));
    let disk = dir.join("disk.img");
    fs::File::create(&disk).unwrap().set_len(4 << 20).unwrap();

    let boot = |steps: &dyn Fn(&mut dyn FnMut(&str), &mut dyn FnMut(&str)), tag: &str| -> String {
        let sock = dir.join(format!("qmp-{tag}"));
        let mut q = Command::new("qemu-system-riscv64")
            .args(["-machine", "virt", "-m", "256M", "-bios", "default", "-display", "none", "-serial", "stdio"])
            .args(["-global", "virtio-mmio.force-legacy=false", "-device", "ramfb"])
            .args(["-device", "virtio-keyboard-device", "-device", "virtio-tablet-device"])
            .arg("-drive")
            .arg(format!("file={},if=none,format=raw,id=d0", disk.display()))
            .args(["-device", "virtio-blk-device,drive=d0", "-qmp"])
            .arg(format!("unix:{},server,nowait", sock.display()))
            .arg("-kernel")
            .arg(&elf)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut stdin = q.stdin.take().unwrap();
        // a watchdog: if something goes wrong, QEMU mustn't outlive the test
        let pid = q.id();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(90));
            let _ = Command::new("kill").arg(pid.to_string()).status();
        });
        std::thread::sleep(Duration::from_millis(3000));
        let qmp = UnixStream::connect(&sock).unwrap();
        let mut reader = BufReader::new(qmp.try_clone().unwrap());
        let mut w = qmp;
        let mut line = String::new();
        reader.read_line(&mut line).unwrap(); // the greeting
        let mut cmd = move |json: String| {
            w.write_all(json.as_bytes()).unwrap();
            w.write_all(b"\n").unwrap();
            loop {
                let mut l = String::new();
                reader.read_line(&mut l).unwrap();
                if l.contains("\"return\"") || l.contains("\"error\"") {
                    assert!(!l.contains("error"), "QMP: {l}");
                    break;
                }
            }
        };
        cmd(r#"{"execute": "qmp_capabilities"}"#.into());
        // keys: by QEMU's key names
        let mut keys = |text: &str| {
            for ch in text.chars() {
                let k = match ch {
                    ' ' => "spc".to_string(),
                    '-' => "minus".to_string(),
                    '.' => "dot".to_string(),
                    '/' => "slash".to_string(),
                    '\n' => "ret".to_string(),
                    c => c.to_string(),
                };
                for down in [true, false] {
                    cmd(format!(r#"{{"execute": "input-send-event", "arguments": {{"events": [{{"type": "key", "data": {{"down": {down}, "key": {{"type": "qcode", "data": "{k}"}}}}}}]}}}}"#));
                    std::thread::sleep(Duration::from_millis(25));
                }
            }
        };
        let mut serial = |text: &str| {
            stdin.write_all(text.as_bytes()).unwrap();
            stdin.flush().unwrap();
            std::thread::sleep(Duration::from_millis(500));
        };
        steps(&mut keys, &mut serial);
        let out = q.wait_with_output().unwrap();
        let text = String::from_utf8_lossy(&out.stdout).replace('\r', "");
        assert_eq!(out.status.code(), Some(0), "{text}");
        text
    };

    let text = boot(
        &|keys, serial| {
            serial("windows\r");
            // typed into the Terminal window (focused at boot), run by the shell
            keys("echo typed on the desktop\n");
            std::thread::sleep(Duration::from_millis(400));
            keys("write kept.txt from the first boot\n");
            std::thread::sleep(Duration::from_millis(400));
            serial("open snake\r");
            serial("windows\r");
            serial("shutdown\r");
        },
        "a",
    );
    for want in ["1  Terminal", "(focused)", "\ntyped on the desktop\n", "Snake  432x364", "bye!"] {
        assert!(text.contains(want), "missing {want:?} in:\n{text}");
    }
    let text = boot(
        &|_keys, serial| {
            serial("cat kept.txt\r");
            serial("shutdown\r");
        },
        "b",
    );
    assert!(text.contains("\nfrom the first boot\n"), "the file didn't survive the reboot:\n{text}");
}

/// StellaOS's network stack under attack. QEMU puts the kernel on a LAN with this test (a UDP
/// socket carrying raw Ethernet frames); we are 10.0.2.66, its gateway, DNS server and web server,
/// and also the attacker: a port scan, ARP poisoning, thousands of malformed frames, a ping flood,
/// hostile DNS answers and TCP injection. Afterwards it must still work.
#[test]
fn stellaos_network() {
    use std::io::{Read, Write};
    use std::net::UdpSocket;
    use std::process::Stdio;
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};
    if Command::new("qemu-system-riscv64").arg("--version").output().is_err() {
        eprintln!("skipped: no qemu-system-riscv64");
        return;
    }
    let dir = tmpdir("network");
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let elf = dir.join("os.elf");
    let c = Command::new(BIN).arg("--kernel").arg(root.join("examples/stellaos/os.st")).arg("-o").arg(&elf).output().unwrap();
    assert!(c.status.success(), "{}", String::from_utf8_lossy(&c.stderr));

    let sock = UdpSocket::bind("127.0.0.1:0").unwrap();
    sock.set_read_timeout(Some(Duration::from_millis(20))).unwrap();
    let ours = sock.local_addr().unwrap().port();
    let qemu_port = UdpSocket::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port(); // a free port for QEMU's end
    let mut q = Command::new("qemu-system-riscv64")
        .args(["-machine", "virt", "-m", "256M", "-nographic", "-bios", "default"])
        .args(["-global", "virtio-mmio.force-legacy=false", "-device", "virtio-rng-device", "-netdev"])
        .arg(format!("dgram,id=d0,local.type=inet,local.host=127.0.0.1,local.port={qemu_port},remote.type=inet,remote.host=127.0.0.1,remote.port={ours}"))
        .args(["-device", "virtio-net-device,netdev=d0", "-kernel"])
        .arg(&elf)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let pid = q.id();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(120));
        let _ = Command::new("kill").arg(pid.to_string()).status();
    });
    let mut stdin = q.stdin.take().unwrap();
    let mut stdout = q.stdout.take().unwrap();
    let out = Arc::new(Mutex::new(Vec::new()));
    let sink = out.clone();
    std::thread::spawn(move || {
        let mut buf = [0u8; 4096];
        while let Ok(n) = stdout.read(&mut buf) {
            if n == 0 {
                break;
            }
            sink.lock().unwrap().extend_from_slice(&buf[..n]);
        }
    });
    let text = || String::from_utf8_lossy(&out.lock().unwrap()).replace('\r', "");
    let clear = || out.lock().unwrap().clear();

    const GMAC: [u8; 6] = [0x52, 0x54, 0, 0x12, 0x34, 0x56];
    const AMAC: [u8; 6] = [2, 0, 0, 0, 0, 0x66];
    const GIP: [u8; 4] = [10, 0, 2, 15];
    const AIP: [u8; 4] = [10, 0, 2, 66];
    fn csum(b: &[u8]) -> u16 {
        let mut s: u32 = 0;
        for c in b.chunks(2) {
            s += (c[0] as u32) << 8 | *c.get(1).unwrap_or(&0) as u32;
        }
        while s >> 16 != 0 {
            s = (s & 0xffff) + (s >> 16);
        }
        !(s as u16)
    }
    fn eth(kind: u16, payload: &[u8], dst: [u8; 6], src: [u8; 6]) -> Vec<u8> {
        [&dst[..], &src[..], &kind.to_be_bytes(), payload].concat()
    }
    fn ip(proto: u8, payload: &[u8], frag: u16, total: Option<u16>, ihl: u8) -> Vec<u8> {
        let tot = total.unwrap_or(20 + payload.len() as u16);
        let mut h = vec![0x40 | ihl, 0];
        h.extend(tot.to_be_bytes());
        h.extend([0x12, 0x34]);
        h.extend(frag.to_be_bytes());
        h.extend([64, proto, 0, 0]);
        h.extend(AIP);
        h.extend(GIP);
        let c = csum(&h);
        h[10..12].copy_from_slice(&c.to_be_bytes());
        [h, payload.to_vec()].concat()
    }
    fn tcp(sport: u16, dport: u16, seq: u32, ack: u32, flags: u8, data: &[u8]) -> Vec<u8> {
        let mut h = Vec::new();
        h.extend(sport.to_be_bytes());
        h.extend(dport.to_be_bytes());
        h.extend(seq.to_be_bytes());
        h.extend(ack.to_be_bytes());
        h.extend([0x50, flags, 0xff, 0xff, 0, 0, 0, 0]);
        h.extend(data);
        let pseudo = [&AIP[..], &GIP[..], &[0, 6], &(h.len() as u16).to_be_bytes()].concat();
        let c = csum(&[pseudo, h.clone()].concat());
        h[16..18].copy_from_slice(&c.to_be_bytes());
        h
    }
    fn icmp(kind: u8, id: u16, seq: u16, data: &[u8]) -> Vec<u8> {
        let mut b = vec![kind, 0, 0, 0];
        b.extend(id.to_be_bytes());
        b.extend(seq.to_be_bytes());
        b.extend(data);
        let c = csum(&b);
        b[2..4].copy_from_slice(&c.to_be_bytes());
        b
    }
    let to = format!("127.0.0.1:{qemu_port}");
    let send = |f: &[u8]| {
        sock.send_to(f, &to).unwrap();
    };
    let ip4 = |proto: u8, p: &[u8]| eth(0x800, &ip(proto, p, 0x4000, None, 5), GMAC, AMAC);

    // our side of the LAN: answer ARP for 10.0.2.66, pings, DNS, HTTP (with attacks mixed in)
    struct State {
        honest_dns: bool,
        frames: Vec<Vec<u8>>,
        http_isn: u32,
        http_done: bool,
    }
    let st = std::cell::RefCell::new(State { honest_dns: false, frames: vec![], http_isn: 0x1234_0000, http_done: false });
    let serve = |f: &[u8]| {
        if f.len() < 34 || f[6..12] != GMAC {
            return;
        }
        st.borrow_mut().frames.push(f.to_vec());
        if f[12..14] == [8, 6] && f[20..22] == [0, 1] && f[38..42] == AIP {
            let arp = [&[0, 1, 8, 0, 6, 4, 0, 2][..], &AMAC, &AIP, &GMAC, &GIP].concat();
            send(&eth(0x806, &arp, GMAC, AMAC));
            return;
        }
        if f[12..14] != [8, 0] {
            return;
        }
        let body = &f[34..];
        match f[23] {
            1 if body[0] == 8 => {
                let id = u16::from_be_bytes([body[4], body[5]]);
                let seq = u16::from_be_bytes([body[6], body[7]]);
                send(&ip4(1, &icmp(0, id, seq, &body[8..])));
            }
            17 if body[2..4] == [0, 53] => {
                let sport = [body[0], body[1]];
                let qmsg = &body[8..];
                let (id, question) = (&qmsg[..2], &qmsg[12..]);
                let udp = |payload: Vec<u8>| {
                    let mut u = vec![0, 53, sport[0], sport[1]];
                    u.extend((8 + payload.len() as u16).to_be_bytes());
                    u.extend([0, 0]);
                    u.extend(payload);
                    send(&ip4(17, &u));
                };
                let answer_a = [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4];
                if st.borrow().honest_dns {
                    udp([id, &[0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0], question, &answer_a, &AIP].concat());
                } else {
                    // a wrong id; a compression loop; an answer to another question
                    udp([&[id[0] ^ 1, id[1]], &[0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0][..], question, &answer_a, &[1, 2, 3, 4]].concat());
                    udp([id, &[0x81, 0x80, 0, 1, 0, 2, 0, 0, 0, 0], question, &[0xc0, 0x30, 0xc0, 0x2e, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 1, 2, 3, 4]].concat());
                    udp([id, &[0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0], b"\x03bad\x07example\0\0\x01\0\x01", &answer_a, &[1, 2, 3, 4]].concat());
                }
            }
            6 if body[2..4] == [0, 80] => {
                let sport = u16::from_be_bytes([body[0], body[1]]);
                let seq = u32::from_be_bytes([body[4], body[5], body[6], body[7]]);
                let flags = body[13];
                let data = &body[(body[12] >> 4) as usize * 4..];
                let s = st.borrow().http_isn;
                let seg = |sq: u32, ak: u32, fl: u8, d: &[u8]| send(&ip4(6, &tcp(80, sport, sq, ak, fl, d)));
                if flags & 2 != 0 {
                    seg(s, seq + 1, 0x12, b"");
                } else if !data.is_empty() && !st.borrow().http_done {
                    st.borrow_mut().http_done = true;
                    let next = seq + data.len() as u32;
                    seg(s + 1 + 1000, next, 0x04, b""); // a reset inside the window: must be challenged, not obeyed
                    seg(s + 1 + 5000, next, 0x18, b"EVIL DATA"); // out of order: dropped
                    seg(s + 1, next, 0x02, b""); // a SYN on the open connection: challenged
                    let page = b"<html>REAL PAGE</html>";
                    let resp = [format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", page.len()).as_bytes(), page].concat();
                    seg(s + 1, next, 0x19, &resp);
                } else if flags & 1 != 0 {
                    seg(s + 2 + 22 + 60, seq + 1, 0x10, b"");
                }
            }
            _ => {}
        }
    };
    let pump = |d: Duration| {
        let end = Instant::now() + d;
        let mut buf = [0u8; 2048];
        while Instant::now() < end {
            if let Ok(n) = sock.recv(&mut buf) {
                serve(&buf[..n]);
            }
        }
    };
    let mut sh = |cmd: &str, wait: u64| {
        stdin.write_all(format!("{cmd}\r").as_bytes()).unwrap();
        stdin.flush().unwrap();
        pump(Duration::from_millis(wait));
    };
    let guest_ip = |st: &std::cell::RefCell<State>| st.borrow().frames.iter().filter(|f| f[12..14] == [8, 0]).count();

    pump(Duration::from_millis(2500));
    sh("ifconfig set 10.0.2.15/24 10.0.2.66", 300);
    sh("dns 10.0.2.66", 300);
    // 1. stealth: pings, a SYN scan of 300 ports and UDP to closed ports get no answer at all
    st.borrow_mut().frames.clear();
    for i in 0..5 {
        send(&ip4(1, &icmp(8, 77, i, b"hello")));
    }
    for port in 1..=300 {
        send(&ip4(6, &tcp(40000, port, 0xabcd_0000 + port as u32, 0, 0x02, b"")));
    }
    for port in 1..200u16 {
        send(&ip4(17, &[&[0x13, 0x88][..], &port.to_be_bytes(), &[0, 12, 0, 0], b"hihi"].concat()));
    }
    pump(Duration::from_millis(2000));
    assert_eq!(guest_ip(&st), 0, "something answered the scan:\n{}", text());
    // 2. an unasked ARP answer claiming 10.0.2.66 is elsewhere must not poison the cache
    sh("ping -c 1 10.0.2.66", 1500);
    let evil = [2, 0, 0, 0, 0, 0xee];
    for _ in 0..5 {
        send(&eth(0x806, &[&[0, 1, 8, 0, 6, 4, 0, 2][..], &evil, &AIP, &GMAC, &GIP].concat(), GMAC, evil));
    }
    pump(Duration::from_millis(300));
    clear();
    sh("arp", 500);
    assert!(text().contains("02:00:00:00:00:66") && !text().contains("02:00:00:00:00:ee"), "ARP cache poisoned:\n{}", text());
    // 3. 3000 malformed frames: lying lengths, fragments, garbage of every kind
    let mut seed: u32 = 12345;
    let mut rnd = move || {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        seed
    };
    for i in 0..3000 {
        let len = (rnd() % 300) as usize;
        let junk: Vec<u8> = (0..len).map(|_| rnd() as u8).collect();
        let dst = if rnd() % 2 == 0 { GMAC } else { [0xff; 6] };
        let f = match rnd() % 4 {
            0 => eth(0x806, &junk, dst, AMAC),
            1 => eth(rnd() as u16, &junk, dst, AMAC),
            _ => {
                let proto = [1u8, 6, 17, 2, 255][(rnd() % 5) as usize];
                let total = [None, None, Some(0), Some(19), Some(60000), Some(21)][(rnd() % 6) as usize];
                let ihl = [5u8, 5, 5, 0, 15, 6][(rnd() % 6) as usize];
                let frag = [0x4000u16, 0x2000, 0x0010, 0][(rnd() % 4) as usize];
                eth(0x800, &ip(proto, &junk, frag, total, ihl), dst, AMAC)
            }
        };
        send(&f);
        if i % 200 == 0 {
            pump(Duration::from_millis(10));
        }
    }
    pump(Duration::from_millis(1000));
    clear();
    sh("uname", 500);
    assert!(text().contains("StellaOS"), "the kernel didn't survive malformed frames:\n{}", text());
    // 4. a ping flood, with answering on: rate-limited
    sh("firewall ping on", 300);
    st.borrow_mut().frames.clear();
    for i in 0..300 {
        send(&ip4(1, &icmp(8, 99, i, b"flood")));
    }
    pump(Duration::from_millis(2500));
    let replies = st.borrow().frames.iter().filter(|f| f[12..14] == [8, 0] && f[23] == 1 && f[34] == 0).count();
    assert!(replies > 0 && replies <= 45, "{replies} ping replies");
    sh("firewall ping off", 300);
    // 5. hostile DNS answers are all refused; an honest one is taken
    clear();
    sh("host evil.example", 5500);
    // (the looping answer is taken apart safely and yields nothing: "no IPv4 address", or no answer at all)
    assert!(!text().contains("1.2.3.4") && (text().contains("no IPv4 address") || text().contains("no answer")), "{}", text());
    st.borrow_mut().honest_dns = true;
    clear();
    sh("host good.example", 1500);
    assert!(text().contains("good.example has address 10.0.2.66"), "{}", text());
    // 6. TCP: a reset inside the window, stray data and a SYN while fetching don't break the connection
    clear();
    sh("fetch http://good.example/", 4000);
    assert!(text().contains("REAL PAGE") && !text().contains("EVIL") && !text().contains("reset"), "{}", text());
    // 7. still well, and the log says what happened
    clear();
    sh("ping -c 2 10.0.2.66", 3000);
    assert!(text().contains("2 sent, 2 received"), "{}", text());
    clear();
    sh("firewall log", 500);
    sh("shutdown", 1000);
    let status = q.wait().unwrap();
    let t = text();
    assert_eq!(status.code(), Some(0), "{t}");
    for want in ["refused an IP fragment", "challenged, not obeyed", "doesn't match our question"] {
        assert!(t.contains(want), "missing {want:?} in the security log:\n{t}");
    }
}

/// StellaOS's cryptography (SHA-2, HMAC, X25519, ChaCha20-Poly1305, AES-GCM, RSA, ECDSA, X.509),
/// checked against known answers inside QEMU (tests/stellaos_crypto.st).
#[test]
fn stellaos_crypto() {
    if Command::new("qemu-system-riscv64").arg("--version").output().is_err() {
        eprintln!("skipped: no qemu-system-riscv64");
        return;
    }
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let dir = tmpdir("crypto");
    for e in fs::read_dir(root.join("examples/stellaos")).unwrap() {
        let p = e.unwrap().path();
        fs::copy(&p, dir.join(p.file_name().unwrap())).unwrap();
    }
    fs::copy(root.join("tests/stellaos_crypto.st"), dir.join("crypto_test.st")).unwrap();
    let elf = dir.join("t.elf");
    let c = Command::new(BIN).arg("--kernel").arg(dir.join("crypto_test.st")).arg("-o").arg(&elf).output().unwrap();
    assert!(c.status.success(), "{}", String::from_utf8_lossy(&c.stderr));
    let out = Command::new("qemu-system-riscv64")
        .args(["-machine", "virt", "-m", "128M", "-nographic", "-bios", "default", "-kernel"])
        .arg(&elf)
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout).replace('\r', "");
    assert!(text.contains("ok ecdsa p-384\n") && text.contains("\ndone") && !text.contains("FAIL"), "{text}");
}

/// StellaOS's JavaScript engine and DOM (tests/stellaos_js.st): the language, the DOM and events,
/// and the sandbox (runaway loops stopped, deep recursion and catastrophic regexes contained, no
/// network, no eval, the toolkit's own attributes off limits), inside QEMU.
#[test]
fn stellaos_js() {
    if Command::new("qemu-system-riscv64").arg("--version").output().is_err() {
        eprintln!("skipped: no qemu-system-riscv64");
        return;
    }
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let dir = tmpdir("jsengine");
    for e in fs::read_dir(root.join("examples/stellaos")).unwrap() {
        let p = e.unwrap().path();
        fs::copy(&p, dir.join(p.file_name().unwrap())).unwrap();
    }
    fs::copy(root.join("tests/stellaos_js.st"), dir.join("js_test.st")).unwrap();
    let elf = dir.join("t.elf");
    let c = Command::new(BIN).arg("--kernel").arg(dir.join("js_test.st")).arg("-o").arg(&elf).output().unwrap();
    assert!(c.status.success(), "{}", String::from_utf8_lossy(&c.stderr));
    let out = Command::new("qemu-system-riscv64")
        .args(["-machine", "virt", "-m", "256M", "-nographic", "-bios", "default", "-kernel"])
        .arg(&elf)
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout).replace('\r', "");
    assert!(text.contains("passed 21/21") && !text.contains("FAIL"), "{text}");
}

/// HTTPS in StellaOS against real TLS 1.3 servers (openssl s_server on the host, reached through
/// QEMU's user network): an unknown root is refused, so is a certificate for another name; with the
/// root added to /etc/ca, the page loads (one server picks AES-128-GCM, the other ChaCha20).
#[test]
fn stellaos_https() {
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::process::Stdio;
    use std::time::Duration;
    if Command::new("qemu-system-riscv64").arg("--version").output().is_err() || Command::new("openssl").arg("version").output().is_err() {
        eprintln!("skipped: needs qemu-system-riscv64 and openssl");
        return;
    }
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let dir = tmpdir("https");
    let elf = dir.join("os.elf");
    let c = Command::new(BIN).arg("--kernel").arg(root.join("examples/stellaos/os.st")).arg("-o").arg(&elf).output().unwrap();
    assert!(c.status.success(), "{}", String::from_utf8_lossy(&c.stderr));
    // a test CA (P-384) and two server certificates (P-256): one for 10.0.2.2, one for another name
    let ssl = |args: &[&str]| {
        let o = Command::new("openssl").args(args).current_dir(&dir).output().unwrap();
        assert!(o.status.success(), "openssl {args:?}: {}", String::from_utf8_lossy(&o.stderr));
    };
    ssl(&["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:secp384r1", "-keyout", "ca.key", "-out", "ca.pem", "-days", "30", "-nodes", "-subj", "/CN=Stella Test CA", "-addext", "basicConstraints=critical,CA:TRUE"]);
    for (name, san) in [("good", "IP:10.0.2.2"), ("wrong", "DNS:wrong.example")] {
        fs::write(dir.join(format!("{name}.ext")), format!("subjectAltName={san}\nbasicConstraints=CA:FALSE\n")).unwrap();
        ssl(&["req", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-keyout", &format!("{name}.key"), "-out", &format!("{name}.csr"), "-nodes", "-subj", "/CN=test"]);
        ssl(&["x509", "-req", "-in", &format!("{name}.csr"), "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-out", &format!("{name}.pem"), "-days", "30", "-extfile", &format!("{name}.ext")]);
    }
    let free = || TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let (good_port, wrong_port) = (free(), free());
    let mut servers = vec![];
    for (name, port, suite) in [("good", good_port, "TLS_AES_128_GCM_SHA256"), ("wrong", wrong_port, "TLS_CHACHA20_POLY1305_SHA256")] {
        servers.push(
            Command::new("openssl")
                .args(["s_server", "-quiet", "-tls1_3", "-www", "-ciphersuites", suite, "-accept"])
                .arg(port.to_string())
                .args(["-cert", &format!("{name}.pem"), "-key", &format!("{name}.key")])
                .current_dir(&dir)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
        );
    }
    // the CA certificate, over plain HTTP, for the kernel to fetch into /etc/ca
    let pem = fs::read(dir.join("ca.pem")).unwrap();
    let http = TcpListener::bind("127.0.0.1:0").unwrap();
    let http_port = http.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for s in http.incoming() {
            let mut s = s.unwrap();
            let mut buf = [0u8; 2048];
            let _ = s.read(&mut buf);
            let _ = s.write_all(format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", pem.len()).as_bytes());
            let _ = s.write_all(&pem);
        }
    });
    std::thread::sleep(Duration::from_millis(500));
    let mut q = Command::new("qemu-system-riscv64")
        .args(["-machine", "virt", "-m", "256M", "-nographic", "-bios", "default"])
        .args(["-global", "virtio-mmio.force-legacy=false", "-device", "virtio-rng-device"])
        .args(["-netdev", "user,id=n0", "-device", "virtio-net-device,netdev=n0", "-kernel"])
        .arg(&elf)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let pid = q.id();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(120));
        let _ = Command::new("kill").arg(pid.to_string()).status();
    });
    let mut stdin = q.stdin.take().unwrap();
    std::thread::sleep(Duration::from_millis(3000));
    for (cmd, wait) in [
        (format!("fetch https://10.0.2.2:{good_port}/"), 6000),
        ("mkdir /etc/ca".to_string(), 300),
        (format!("fetch http://10.0.2.2:{http_port}/ca.pem -o /etc/ca/test.pem"), 2000),
        (format!("fetch -i https://10.0.2.2:{good_port}/"), 8000),
        (format!("fetch https://10.0.2.2:{wrong_port}/"), 8000),
        ("shutdown".to_string(), 1000),
    ] {
        stdin.write_all(format!("{cmd}\r").as_bytes()).unwrap();
        stdin.flush().unwrap();
        std::thread::sleep(Duration::from_millis(wait));
    }
    let out = q.wait_with_output().unwrap();
    for mut s in servers {
        let _ = s.kill();
    }
    let text = String::from_utf8_lossy(&out.stdout).replace('\r', "");
    for want in [
        "the certificate can't be trusted: the certificate isn't signed by anyone we trust",
        "saved /etc/ca/test.pem",
        "HTTP 200 ok",
        "TLS 1.3 · AES-128-GCM · certificate from",
        "s_server",
        "the certificate is for wrong.example, not 10.0.2.2",
    ] {
        assert!(text.contains(want), "missing {want:?} in:\n{text}");
    }
}

/// A field default that builds another struct with defaults (from another module) makes that
/// struct's default functions once, not twice.
#[test]
fn nested_field_defaults() {
    let m = "struct E {\n    h: [str] = [],\n    n: int = 2,\n}\n";
    let src = "import m\nstruct Outer {\n    e: m.E = m.E {},\n}\nfn main() {\n    let o = Outer {}\n    println(o.e.n + m.E {}.h.len())\n}\n";
    assert_eq!(run_with("nested_defaults", src, &[("m", m)]), (0, "2\n".into(), "".into()));
}
