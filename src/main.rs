mod codegen;
mod fmt;
mod grammar;
mod json;
mod lexer;
mod lsp;
mod parser;

use codegen::Unit;
use std::collections::HashMap;
use std::io::Write;
use std::path::Path;
use std::process::{exit, Command, Stdio};
use std::{env, fs};

const RUNTIME: &str = include_str!("runtime.c");

/// The standard library, written in stellang and built into the compiler.
pub const STD: &[(&str, &str)] = &[
    ("net", include_str!("../std/net.st")),
    ("http", include_str!("../std/http.st")),
    ("fs", include_str!("../std/fs.st")),
    ("json", include_str!("../std/json.st")),
];

const USAGE: &str = "usage:
  stellang <file.st> [-o <out>] [-O0|-O1|-O2|-O3|-Os] [--emit-llvm]   compile
  stellang check <file.st>                                             type-check only
  stellang fmt [--emoji|--plain] <file.st>                              re-indent in place
  stellang lsp                                                         language server (stdio)
  stellang grammar textmate|vim                                        print a syntax grammar";

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

/// Where to find sources: std modules, files on disk, and (in the editor) unsaved buffers.
pub struct Sources<'a> {
    pub std_dir: Option<&'a str>, // name std files after their copies here (the editor can open them)
    pub open: &'a HashMap<String, String>,
}

/// Parse `file` as module `name`, then everything it imports (std modules, or `<name>.st` next to it).
pub fn load(units: &mut Vec<Unit>, name: &str, file: String, src: &str, srcs: &Sources) -> Result<(), (String, lexer::Pos, String)> {
    let module = lexer::lex(src).and_then(parser::parse).map_err(|(p, m)| (file.clone(), p, m))?;
    let dir = Path::new(&file).parent().map(Path::to_path_buf).unwrap_or_default();
    let imports = module.imports.clone();
    units.push(Unit { name: name.into(), file: file.clone(), module });
    for (imp, pos) in imports {
        if units.iter().any(|u| u.name == imp) {
            continue;
        }
        if let Some((_, src)) = STD.iter().find(|s| s.0 == imp) {
            let f = match srcs.std_dir {
                Some(d) => format!("{d}/{imp}.st"),
                None => format!("<std>/{imp}.st"),
            };
            load(units, &imp, f, src, srcs)?;
            continue;
        }
        let path = dir.join(format!("{imp}.st")).display().to_string();
        let src = match srcs.open.get(&path) {
            Some(s) => s.clone(),
            None => fs::read_to_string(&path).map_err(|_| (file.clone(), pos, format!("cannot find module `{imp}` (looked for {path})")))?,
        };
        load(units, &imp, path, &src, srcs)?;
    }
    Ok(())
}

fn load_or_exit(input: &str) -> Vec<Unit> {
    let mut units = vec![];
    let none = HashMap::new();
    load(&mut units, "", input.to_string(), &read(input), &Sources { std_dir: None, open: &none }).unwrap_or_else(|(file, p, m)| {
        eprintln!("{file}:{}:{}: error: {m}", p.line, p.col);
        exit(1)
    });
    units
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("lsp") => return lsp::run(),
        Some("grammar") => match args.get(1).map(String::as_str) {
            Some("textmate") => return print!("{}", grammar::textmate()),
            Some("vim") => return print!("{}", grammar::vim()),
            _ => die(USAGE),
        },
        Some("check") => {
            let Some(input) = args.get(1) else { die(USAGE) };
            let units = load_or_exit(input);
            if let Err((file, p, m)) = codegen::check(&units, false).0 {
                eprintln!("{file}:{}:{}: error: {m}", p.line, p.col);
                exit(1)
            }
            return;
        }
        _ => {}
    }
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
    let units = load_or_exit(&input);
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
