mod codegen;
mod fmt;
mod lexer;
mod parser;

use codegen::Unit;
use std::io::Write;
use std::path::Path;
use std::process::{exit, Command, Stdio};
use std::{env, fs};

const RUNTIME: &str = include_str!("runtime.c");

/// The standard library, written in stellang and built into the compiler.
const STD: &[(&str, &str)] = &[("net", include_str!("../std/net.st")), ("http", include_str!("../std/http.st"))];

const USAGE: &str = "usage:
  stellang <file.st> [-o <out>] [-O0|-O1|-O2|-O3|-Os] [--emit-llvm]   compile
  stellang fmt [--emoji|--plain] <file.st>                              re-indent in place";

fn die(msg: impl std::fmt::Display) -> ! {
    eprintln!("stellang: {msg}");
    exit(1)
}

fn read(path: &str) -> String {
    fs::read_to_string(path).unwrap_or_else(|e| die(format!("{path}: {e}")))
}

fn report<T>(path: &str, r: Result<T, lexer::Error>) -> T {
    r.unwrap_or_else(|(p, m)| {
        eprintln!("{path}:{}:{}: error: {m}", p.line, p.col);
        exit(1)
    })
}

/// Parse `file` as module `name`, then everything it imports (std modules, or `<name>.st` next to it).
fn load(units: &mut Vec<Unit>, name: &str, file: String, src: &str) {
    let module = report(&file, lexer::lex(src).and_then(parser::parse));
    let dir = Path::new(&file).parent().map(Path::to_path_buf).unwrap_or_default();
    let imports = module.imports.clone();
    units.push(Unit { name: name.into(), file: file.clone(), module });
    for (imp, pos) in imports {
        if units.iter().any(|u| u.name == imp) {
            continue;
        }
        if let Some((_, src)) = STD.iter().find(|s| s.0 == imp) {
            load(units, &imp, format!("<std>/{imp}.st"), src);
            continue;
        }
        let path = dir.join(format!("{imp}.st"));
        let Ok(src) = fs::read_to_string(&path) else {
            report::<()>(&file, Err((pos, format!("cannot find module `{imp}` (looked for {})", path.display()))));
            unreachable!()
        };
        load(units, &imp, path.display().to_string(), &src);
    }
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.first().is_some_and(|a| a == "fmt") {
        let (mode, file) = match &args[1..] {
            [f] => (None, f),
            [m, f] if m == "--emoji" => (Some(true), f),
            [m, f] if m == "--plain" => (Some(false), f),
            _ => die(USAGE),
        };
        let out = report(file, fmt::format(&read(file), mode));
        fs::write(file, out).unwrap_or_else(|e| die(format!("{file}: {e}")));
        return;
    }

    let (mut input, mut out, mut opt, mut emit) = (None, None, "-O2".to_string(), false);
    let mut args = args.into_iter();
    while let Some(a) = args.next() {
        match a.as_str() {
            "-o" => out = Some(args.next().unwrap_or_else(|| die("-o needs a file name"))),
            "--emit-llvm" | "-S" => emit = true,
            "-O0" | "-O1" | "-O2" | "-O3" | "-Os" | "-Oz" => opt = a.clone(),
            "-h" | "--help" => return println!("{USAGE}"),
            _ if a.starts_with('-') => die(format!("unknown option {a}\n{USAGE}")),
            _ => input = Some(a.clone()),
        }
    }
    let Some(input) = input else { die(USAGE) };
    let mut units = vec![];
    load(&mut units, "", input.clone(), &read(&input));
    let ir = codegen::compile(&units).unwrap_or_else(|(file, p, m)| {
        eprintln!("{file}:{}:{}: error: {m}", p.line, p.col);
        exit(1)
    });

    // clang runs the LLVM optimizer, compiles the C runtime, and links against Boehm GC
    let stem = Path::new(&input).file_stem().unwrap().to_string_lossy().into_owned();
    let out = out.unwrap_or(if emit { format!("{stem}.ll") } else { stem });
    let rt = env::temp_dir().join(format!("stellang-rt-{}.c", std::process::id()));
    let mut cmd = Command::new("clang");
    cmd.args([opt.as_str(), "-Wno-override-module", "-x", "ir", "-"]);
    if emit {
        cmd.args(["-S", "-emit-llvm"]);
    } else {
        fs::write(&rt, RUNTIME).unwrap_or_else(|e| die(e));
        cmd.args(["-x", "c"]).arg(&rt).arg("-lgc");
    }
    cmd.args(["-o", &out]);
    let mut child = cmd.stdin(Stdio::piped()).spawn().unwrap_or_else(|e| die(format!("cannot run clang: {e}")));
    child.stdin.take().unwrap().write_all(ir.as_bytes()).unwrap_or_else(|e| die(e));
    let ok = child.wait().is_ok_and(|s| s.success());
    let _ = fs::remove_file(&rt);
    if !ok {
        die("clang rejected the generated code (compiler bug)");
    }
}
