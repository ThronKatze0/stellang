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
    let get = |path: &str| send(format!("GET {path} HTTP/1.1\r\nHost: localhost\r\n\r\n"));
    let first = get("/");
    let second = get("/");
    let hello = get("/hello/ada");
    let square = get("/square/12");
    let bad = get("/square/abc");
    let echo = send("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 7\r\n\r\n{\"a\":1}".into());
    let missing = get("/nope");
    server.kill().unwrap();
    assert!(first.starts_with("HTTP/1.1 200 OK\r\n") && first.contains("visit number 1"), "{first}");
    assert!(second.contains("visit number 2"), "{second}");
    assert!(hello.ends_with("\r\n\r\nhi ada!"), "{hello}");
    assert!(square.ends_with("\r\n\r\n144"), "{square}");
    assert!(bad.starts_with("HTTP/1.1 400 Bad Request") && bad.contains("not a number"), "{bad}");
    assert!(echo.contains("application/json") && echo.ends_with("{\"a\":1}"), "{echo}");
    assert!(missing.starts_with("HTTP/1.1 404 Not Found"), "{missing}");
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
