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
const RUNTIME_WEB: &str = include_str!("runtime_web.c");
const RUNTIME_GC: &str = include_str!("runtime_gc.c");
const RUNTIME_KLIBC: &str = include_str!("runtime_klibc.c");
const RUNTIME_KERNEL: &str = include_str!("runtime_kernel.c");
const RUNTIME_KERNEL_RV: &str = include_str!("runtime_kernel_rv.c");
const RUNTIME_KERNEL_X86: &str = include_str!("runtime_kernel_x86.c");
const BOOT_UEFI: &str = include_str!("boot_uefi.c");
const KERNEL_X86_LD: &str = include_str!("kernel_x86.ld");
const RUNTIME_FONT: &str = include_str!("runtime_font.c");
const KERNEL_LD: &str = include_str!("kernel.ld");
const LOADER: &str = include_str!("loader.js");

/// The standard library, written in stellang and built into the compiler.
pub const STD: &[(&str, &str)] = &[
    ("net", include_str!("../std/net.st")),
    ("http", include_str!("../std/http.st")),
    ("fs", include_str!("../std/fs.st")),
    ("json", include_str!("../std/json.st")),
    ("web", include_str!("../std/web.st")),
    ("kernel", include_str!("../std/kernel.st")),
    ("gfx", include_str!("../std/gfx.st")),
];

const USAGE: &str = "usage:
  stellang <file.st> [-o <out>] [-O0|-O1|-O2|-O3|-Os] [--emit-llvm]   compile
  stellang --web <app.st> [-o <out>]                                   compile for the browser (out.wasm + out.js)
  stellang --kernel [--arch x86_64] <os.st> [-o <out>]                 compile an operating system kernel (RISC-V 64, out.elf;
                                                                        x86_64: out.efi, a UEFI app for real PCs)
  stellang boot [--arch x86_64] [--gui] [--disk f.img] <os.st|os.elf|os.efi> [qemu args]
                                                                        build it and boot it in QEMU (--gui: with a display,
                                                                        keyboard and mouse; a disk image keeps files;
                                                                        a network card unless --no-net, a sound
                                                                        card unless --no-sound)
  stellang usb <os.st|os.efi> <folder>                                  put StellaOS on a USB stick (x86_64 UEFI): writes
                                                                        <folder>/EFI/BOOT/BOOTX64.EFI; <folder> is where the
                                                                        (FAT32) stick is mounted
  stellang dev [dir]                                                    full-stack dev loop: client.st -> public/, server.st; rebuild on change
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
        Some("dev") => return dev(args.get(1).map(String::as_str).unwrap_or(".")),
        Some("boot") => return boot(&args[1..]),
        Some("usb") => return usb(&args[1..]),
        Some("--version" | "-V") => return println!("stellang {}", env!("CARGO_PKG_VERSION")),
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

    let (mut input, mut out, mut opt, mut emit, mut web, mut kernel) = (None, None, "-O2".to_string(), false, false, false);
    let mut x86 = false;
    let mut args = args.into_iter();
    while let Some(a) = args.next() {
        match a.as_str() {
            "-o" => out = Some(args.next().unwrap_or_else(|| die("-o needs a file name"))),
            "--emit-llvm" | "-S" => emit = true,
            "--web" => web = true,
            "--kernel" => kernel = true,
            "--arch" => x86 = arch(args.next()),
            "-O0" | "-O1" | "-O2" | "-O3" | "-Os" | "-Oz" => opt = a.clone(),
            "-h" | "--help" => return println!("{USAGE}"),
            _ if a.starts_with('-') => die(format!("unknown option {a}\n{USAGE}")),
            _ => input = Some(a.clone()),
        }
    }
    let Some(input) = input else { die(USAGE) };
    if web {
        return build_web(&input, out, &opt, emit);
    }
    if kernel {
        build_kernel(&input, out, &opt, emit, x86);
        return;
    }
    let units = load_or_exit(&input);
    let ir = codegen::compile(&units).unwrap_or_else(|(file, p, m)| {
        eprintln!("{file}:{}:{}: error: {m}", p.line, p.col);
        exit(1)
    });

    // clang runs the LLVM optimizer, compiles the C runtime, and links against Boehm GC and libcurl
    let stem = Path::new(&input).file_stem().unwrap().to_string_lossy().into_owned();
    let out = out.unwrap_or(if emit { format!("{stem}.ll") } else { stem });
    let rt = env::temp_dir().join(format!("stellang-rt-{}.c", std::process::id()));
    let mut cmd = Command::new("clang");
    cmd.args([opt.as_str(), "-Wno-override-module", "-x", "ir", "-"]);
    if emit {
        cmd.args(["-S", "-emit-llvm"]);
    } else {
        fs::write(&rt, RUNTIME).unwrap_or_else(|e| die(e));
        cmd.args(["-x", "c"]).arg(&rt).args(["-lgc", "-lcurl"]);
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

/// `stellang --web app.st`: app.wasm (the program and the browser runtime) and app.js (the loader
/// that runs it in the page), plus a starter app.html if there's none.
fn build_web(input: &str, out: Option<String>, opt: &str, emit: bool) {
    let units = load_or_exit(input);
    for u in &units {
        for (imp, pos) in &u.module.imports {
            if ["net", "http", "fs"].contains(&imp.as_str()) {
                eprintln!("{}:{}:{}: error: `import {imp}` only works on the server, not in a --web app", u.file, pos.line, pos.col);
                exit(1)
            }
        }
    }
    let ir = codegen::compile_web(&units).unwrap_or_else(|(file, p, m)| {
        eprintln!("{file}:{}:{}: error: {m}", p.line, p.col);
        exit(1)
    });
    let stem = Path::new(input).file_stem().unwrap().to_string_lossy().into_owned();
    let base = out.map(|o| o.trim_end_matches(".wasm").trim_end_matches(".js").to_string()).unwrap_or(stem);
    if let Some(dir) = Path::new(&base).parent().filter(|d| !d.as_os_str().is_empty()) {
        fs::create_dir_all(dir).unwrap_or_else(|e| die(format!("{}: {e}", dir.display())));
    }
    if emit {
        fs::write(format!("{base}.ll"), ir).unwrap_or_else(|e| die(e));
        return;
    }
    let rt = env::temp_dir().join(format!("stellang-rt-web-{}.c", std::process::id()));
    fs::write(&rt, format!("{RUNTIME}\n{RUNTIME_GC}\n{RUNTIME_WEB}")).unwrap_or_else(|e| die(e));
    let sysroot = env::var("STELLANG_WASI_SYSROOT").unwrap_or_else(|_| "/usr".into());
    let wasm = format!("{base}.wasm");
    let mut cmd = Command::new("clang");
    cmd.args(["--target=wasm32-wasi", &format!("--sysroot={sysroot}"), opt, "-mexec-model=reactor", "-Wno-override-module"]);
    cmd.args(["-x", "ir", "-", "-x", "c", "-DST_WASM"]).arg(&rt);
    cmd.args(["-Wl,--export=st_start", "-Wl,--strip-all", "-o", &wasm]);
    let mut child = cmd.stdin(Stdio::piped()).spawn().unwrap_or_else(|e| die(format!("cannot run clang: {e}")));
    child.stdin.take().unwrap().write_all(ir.as_bytes()).unwrap_or_else(|e| die(e));
    let ok = child.wait().is_ok_and(|s| s.success());
    let _ = fs::remove_file(&rt);
    if !ok {
        die("clang couldn't build the WebAssembly module. It needs the WASI C library and the wasm32 compiler runtime \
             (Debian/Ubuntu: `apt install wasi-libc libclang-rt-dev-wasm32`), or set STELLANG_WASI_SYSROOT");
    }
    let name = Path::new(&base).file_name().unwrap().to_string_lossy().into_owned();
    fs::write(format!("{base}.js"), LOADER).unwrap_or_else(|e| die(e));
    let html = format!("{base}.html");
    if !Path::new(&html).exists() && env::var_os("STELLANG_NO_HTML").is_none() {
        let page = format!(
            "<!doctype html>\n<html>\n<head>\n  <meta charset=\"utf-8\">\n  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n  <title>{name}</title>\n</head>\n<body>\n  <div id=\"app\"></div>\n  <script src=\"{name}.js\"></script>\n</body>\n</html>\n"
        );
        fs::write(&html, page).unwrap_or_else(|e| die(e));
    }
}

/// `stellang --kernel os.st`: os.elf, a kernel for QEMU's RISC-V `virt` machine. The program, the C
/// runtime (with a small libc, runtime_klibc.c, and the boot code, runtime_kernel.c) and the
/// collector (runtime_gc.c) are compiled freestanding and linked with kernel.ld. Returns the .elf path.
/// `--arch riscv64|x86_64`: whether it's x86_64.
fn arch(a: Option<String>) -> bool {
    match a.as_deref() {
        Some("x86_64" | "x86-64" | "x86" | "amd64") => true,
        Some("riscv64" | "riscv" | "rv64") => false,
        _ => die("--arch: riscv64 or x86_64"),
    }
}

fn build_kernel(input: &str, out: Option<String>, opt: &str, emit: bool, x86: bool) -> String {
    let units = load_or_exit(input);
    for u in &units {
        for (imp, pos) in &u.module.imports {
            if ["net", "http", "fs"].contains(&imp.as_str()) {
                eprintln!("{}:{}:{}: error: `import {imp}` needs a host operating system; a --kernel program has `import kernel`", u.file, pos.line, pos.col);
                exit(1)
            }
        }
    }
    let ir = codegen::compile_kernel(&units).unwrap_or_else(|(file, p, m)| {
        eprintln!("{file}:{}:{}: error: {m}", p.line, p.col);
        exit(1)
    });
    let stem = Path::new(input).file_stem().unwrap().to_string_lossy().into_owned();
    let base = out.map(|o| o.trim_end_matches(".elf").trim_end_matches(".efi").to_string()).unwrap_or(stem);
    if let Some(dir) = Path::new(&base).parent().filter(|d| !d.as_os_str().is_empty()) {
        fs::create_dir_all(dir).unwrap_or_else(|e| die(format!("{}: {e}", dir.display())));
    }
    if emit {
        fs::write(format!("{base}.ll"), ir).unwrap_or_else(|e| die(e));
        return format!("{base}.ll");
    }
    if x86 {
        return build_kernel_x86(&ir, &base, opt);
    }
    let tmp = env::temp_dir().join(format!("stellang-kernel-{}", std::process::id()));
    fs::create_dir_all(&tmp).unwrap_or_else(|e| die(e));
    let rt = tmp.join("runtime.c");
    let ld = tmp.join("kernel.ld");
    fs::write(&rt, format!("{RUNTIME_KLIBC}\n{RUNTIME}\n{RUNTIME_GC}\n{RUNTIME_FONT}\n{RUNTIME_KERNEL}\n{RUNTIME_KERNEL_RV}")).unwrap_or_else(|e| die(e));
    fs::write(&ld, KERNEL_LD).unwrap_or_else(|e| die(e));
    let elf = format!("{base}.elf");
    let mut cmd = Command::new("clang");
    cmd.args(["--target=riscv64-unknown-elf", "-march=rv64gc", "-mabi=lp64d", "-mcmodel=medany", "-mno-relax"]);
    cmd.args(["-ffreestanding", "-fno-builtin", "-nostdlib", "-static", "-fuse-ld=lld", opt, "-Wno-override-module"]);
    cmd.args(["-x", "ir", "-", "-x", "c", "-DST_KERNEL", "-DGC_AUTO", "-Wno-unused-function"]).arg(&rt);
    cmd.arg(format!("-Wl,-T,{}", ld.display())).args(["-Wl,--gc-sections", "-ffunction-sections", "-fdata-sections", "-o", &elf]);
    let mut child = cmd.stdin(Stdio::piped()).spawn().unwrap_or_else(|e| die(format!("cannot run clang: {e}")));
    child.stdin.take().unwrap().write_all(ir.as_bytes()).unwrap_or_else(|e| die(e));
    let ok = child.wait().is_ok_and(|s| s.success());
    let _ = fs::remove_dir_all(&tmp);
    if !ok {
        die("clang couldn't build the kernel. It needs clang with the RISC-V target and lld \
             (Debian/Ubuntu: `apt install clang lld`)");
    }
    elf
}

/// The x86_64 kernel: a position-independent ELF (the program and the runtime, SysV ABI like a native
/// build), then the UEFI loader (boot_uefi.c, a PE) with that ELF inside. Returns the .efi path.
fn build_kernel_x86(ir: &str, base: &str, opt: &str) -> String {
    let tmp = env::temp_dir().join(format!("stellang-kernel-{}", std::process::id()));
    fs::create_dir_all(&tmp).unwrap_or_else(|e| die(e));
    let rt = tmp.join("runtime.c");
    let ld = tmp.join("kernel.ld");
    let elf = tmp.join("kernel.elf");
    let boot = tmp.join("boot.c");
    fs::write(&rt, format!("{RUNTIME_KLIBC}\n{RUNTIME}\n{RUNTIME_GC}\n{RUNTIME_FONT}\n{RUNTIME_KERNEL}\n{RUNTIME_KERNEL_X86}")).unwrap_or_else(|e| die(e));
    fs::write(&ld, KERNEL_X86_LD).unwrap_or_else(|e| die(e));
    fs::write(&boot, BOOT_UEFI).unwrap_or_else(|e| die(e));
    let mut cmd = Command::new("clang");
    cmd.args(["--target=x86_64-unknown-none-elf", "-fPIE", "-mno-red-zone", "-fno-stack-protector", "-fno-asynchronous-unwind-tables"]);
    cmd.args(["-ffreestanding", "-fno-builtin", "-nostdlib", "-fuse-ld=lld", opt, "-Wno-override-module"]);
    cmd.args(["-x", "ir", "-", "-x", "c", "-DST_KERNEL", "-DGC_AUTO", "-Wno-unused-function"]).arg(&rt);
    cmd.args(["-Wl,-pie", "-Wl,--no-dynamic-linker", "-Wl,-z,norelro", "-Wl,--gc-sections", "-ffunction-sections", "-fdata-sections"]);
    cmd.arg(format!("-Wl,-T,{}", ld.display())).arg("-o").arg(&elf);
    let mut child = cmd.stdin(Stdio::piped()).spawn().unwrap_or_else(|e| die(format!("cannot run clang: {e}")));
    child.stdin.take().unwrap().write_all(ir.as_bytes()).unwrap_or_else(|e| die(e));
    let ok = child.wait().is_ok_and(|s| s.success());
    let efi = format!("{base}.efi");
    let ok = ok
        && Command::new("clang")
            .args(["--target=x86_64-unknown-windows", "-ffreestanding", "-fno-builtin", "-nostdlib", "-fuse-ld=lld", "-O2"])
            .args(["-mno-stack-arg-probe", "-fno-stack-protector", "-Wl,-subsystem:efi_application", "-Wl,-entry:efi_main"])
            .arg(format!("-DKERNEL_ELF=\"{}\"", elf.display()))
            .arg(&boot)
            .args(["-o", &efi])
            .status()
            .is_ok_and(|s| s.success());
    let _ = fs::remove_dir_all(&tmp);
    if !ok {
        die("clang couldn't build the kernel. It needs clang with the x86 target and lld (Debian/Ubuntu: `apt install clang lld`)");
    }
    efi
}

/// `stellang boot os.st` (or os.elf): build the kernel if needed and boot it in QEMU, the console on
/// this terminal. QEMU's exit code is the kernel's (main's return value, 101 for a panic).
/// The host's audio, as QEMU names it: one that is likely there (QEMU won't start with one that isn't).
fn audio_driver() -> &'static str {
    if cfg!(target_os = "macos") {
        return "coreaudio";
    }
    if cfg!(windows) {
        return "dsound";
    }
    let runtime = env::var("XDG_RUNTIME_DIR").unwrap_or_default();
    if env::var_os("PULSE_SERVER").is_some() || (!runtime.is_empty() && Path::new(&runtime).join("pulse/native").exists()) {
        return "pa";
    }
    if Path::new("/dev/snd").exists() {
        return "alsa";
    }
    "none"
}

fn boot(args: &[String]) {
    let mut gui = false;
    let mut disk: Option<String> = None;
    let mut no_disk = false;
    let mut net = true;
    let mut sound = true;
    let mut x86 = false;
    let mut i = 0;
    while i < args.len() && args[i].starts_with("--") {
        match args[i].as_str() {
            "--gui" => gui = true,
            "--no-disk" => no_disk = true,
            "--no-net" => net = false,
            "--no-sound" => sound = false,
            "--arch" => {
                i += 1;
                x86 = arch(args.get(i).cloned());
            }
            "--disk" if i + 1 < args.len() => {
                i += 1;
                disk = Some(args[i].clone());
            }
            other => die(format!("boot: unknown option {other}\n{USAGE}")),
        }
        i += 1;
    }
    let args = &args[i..];
    let Some(input) = args.first() else { die(USAGE) };
    let x86 = x86 || input.ends_with(".efi");
    let elf = if input.ends_with(".elf") || input.ends_with(".efi") {
        input.clone()
    } else {
        let out = env::temp_dir().join(format!("stellang-boot-{}", std::process::id())).display().to_string();
        build_kernel(input, Some(out), "-O2", false, x86)
    };
    if x86 {
        return boot_x86(input, &elf, gui, &args[1..]);
    }
    // the disk: a file that keeps what the kernel writes, from one boot to the next
    let disk = if no_disk {
        None
    } else {
        let path = disk.map(std::path::PathBuf::from).unwrap_or_else(|| {
            let cache = env::var_os("XDG_CACHE_HOME")
                .map(std::path::PathBuf::from)
                .or_else(|| env::var_os("HOME").map(|h| Path::new(&h).join(".cache")))
                .unwrap_or_else(env::temp_dir);
            let stem = Path::new(input).file_stem().unwrap_or_default().to_string_lossy().into_owned();
            cache.join("stellang").join(format!("{stem}.img"))
        });
        if !path.exists() {
            if let Some(dir) = path.parent() {
                fs::create_dir_all(dir).unwrap_or_else(|e| die(format!("{}: {e}", dir.display())));
            }
            let f = fs::File::create(&path).unwrap_or_else(|e| die(format!("{}: {e}", path.display())));
            f.set_len(16 << 20).unwrap_or_else(|e| die(format!("{}: {e}", path.display())));
        }
        eprintln!("disk: {} (`--no-disk` to boot without one)", path.display());
        Some(path)
    };
    let qemu = env::var("STELLANG_QEMU").unwrap_or_else(|_| "qemu-system-riscv64".into());
    let mut cmd = Command::new(&qemu);
    cmd.args(["-machine", "virt", "-m", "512M", "-bios", "default", "-kernel", &elf, "-rtc", "base=localtime"]);
    cmd.args(["-global", "virtio-mmio.force-legacy=false"]); // virtio 1.x devices (what the drivers speak)
    if let Some(d) = &disk {
        cmd.arg("-drive").arg(format!("file={},if=none,format=raw,id=disk0", d.display()));
        cmd.args(["-device", "virtio-blk-device,drive=disk0"]);
    }
    // a source of random numbers (virtio-rng, fed from the host's /dev/urandom)
    cmd.args(["-device", "virtio-rng-device"]);
    if net {
        // a network card on QEMU's user-mode network: the kernel sees a 10.0.2.0/24 LAN (gateway
        // 10.0.2.2, DNS 10.0.2.3) and reaches the outside through the host; nothing outside can
        // connect in (no ports are forwarded)
        cmd.args(["-netdev", "user,id=net0", "-device", "virtio-net-device,netdev=net0"]);
    }
    if sound {
        // a sound card (virtio-sound), played through the host's audio: PulseAudio/PipeWire or ALSA on
        // Linux, Core Audio on macOS, DirectSound on Windows (STELLANG_AUDIO picks another QEMU
        // audio driver, `none` to keep quiet)
        let driver = env::var("STELLANG_AUDIO").unwrap_or_else(|_| audio_driver().into());
        cmd.arg("-audiodev").arg(format!("{driver},id=snd0"));
        cmd.args(["-device", "virtio-sound-device,audiodev=snd0"]);
    }
    if gui {
        // a window with the display (a ramfb framebuffer), a keyboard and a mouse (virtio-input; the
        // tablet reports absolute positions, so the pointer follows the host's); the console stays
        // on this terminal
        cmd.args(["-device", "ramfb", "-device", "virtio-keyboard-device", "-device", "virtio-tablet-device"]);
        cmd.args(["-serial", "mon:stdio"]);
    } else {
        cmd.arg("-nographic");
    }
    cmd.args(&args[1..]);
    let status = cmd.status().unwrap_or_else(|e| {
        die(format!("cannot run {qemu}: {e} (Debian/Ubuntu: `apt install qemu-system-misc`, macOS: `brew install qemu`)"))
    });
    if !input.ends_with(".elf") {
        let _ = fs::remove_file(&elf);
    }
    exit(status.code().unwrap_or(1));
}

/// `stellang usb os.st /media/me/STICK`: build StellaOS for x86_64 UEFI and copy it to where a PC's
/// firmware looks on a removable drive (EFI/BOOT/BOOTX64.EFI). Only a file is written, into a folder
/// the user names (the mounted stick); nothing writes to a device directly.
fn usb(args: &[String]) {
    let (Some(input), Some(folder)) = (args.first(), args.get(1)) else {
        die("usage: stellang usb <os.st|os.efi> <folder where the USB stick is mounted>")
    };
    if folder.starts_with("/dev/") || folder.starts_with("\\\\.\\") {
        die(format!("{folder} is a device: mount the stick (FAT32) and give its folder, like /media/$USER/STICK"));
    }
    let dir = Path::new(folder);
    if !dir.is_dir() {
        die(format!("{folder}: no such folder (mount the USB stick first; it needs a FAT32 file system)"));
    }
    let efi = if input.ends_with(".efi") {
        input.clone()
    } else {
        let out = env::temp_dir().join(format!("stellang-usb-{}", std::process::id())).display().to_string();
        build_kernel(input, Some(out), "-O2", false, true)
    };
    let boot = dir.join("EFI").join("BOOT");
    fs::create_dir_all(&boot).unwrap_or_else(|e| die(format!("{}: {e}", boot.display())));
    let target = boot.join("BOOTX64.EFI");
    let replaced = target.exists();
    let n = fs::copy(&efi, &target).unwrap_or_else(|e| die(format!("{}: {e}", target.display())));
    if !input.ends_with(".efi") {
        let _ = fs::remove_file(&efi);
    }
    println!("{}: StellaOS ({} KiB){}", target.display(), n / 1024, if replaced { ", replacing the one that was there" } else { "" });
    println!("Next: eject the stick safely, plug it into the PC, turn Secure Boot off in its firmware setup,");
    println!("and pick the stick in the one-time boot menu (often F12, F11, F10, F8 or Esc right after power-on).");
    println!("StellaOS runs from RAM and never writes to the PC's own disk.");
}

/// The firmware for QEMU's x86 PC: OVMF (UEFI), wherever the distribution put it.
fn ovmf() -> String {
    if let Ok(p) = env::var("STELLANG_OVMF") {
        return p;
    }
    let known = ["/usr/share/edk2/x64/OVMF.4m.fd", "/usr/share/edk2/x64/OVMF.fd", "/usr/share/ovmf/OVMF.fd", "/usr/share/OVMF/OVMF.fd",
        "/usr/share/qemu/OVMF.fd", "/usr/share/edk2-ovmf/x64/OVMF.fd", "/opt/homebrew/share/qemu/edk2-x86_64-code.fd",
        "/usr/local/share/qemu/edk2-x86_64-code.fd", "/usr/share/qemu/edk2-x86_64-code.fd"];
    known.iter().find(|p| Path::new(p).exists()).map(|p| p.to_string()).unwrap_or_else(|| {
        die("no UEFI firmware for QEMU found (Debian/Ubuntu: `apt install ovmf`, Arch: `pacman -S edk2-ovmf`), or set STELLANG_OVMF")
    })
}

/// `stellang boot --arch x86_64`: the .efi on a FAT drive QEMU makes from a folder (as it would be on
/// a USB stick: EFI/BOOT/BOOTX64.EFI), booted by OVMF. RAM only: no disk image, network or sound.
fn boot_x86(input: &str, efi: &str, gui: bool, extra: &[String]) {
    let dir = env::temp_dir().join(format!("stellang-esp-{}", std::process::id()));
    let boot = dir.join("EFI").join("BOOT");
    fs::create_dir_all(&boot).unwrap_or_else(|e| die(e));
    fs::copy(efi, boot.join("BOOTX64.EFI")).unwrap_or_else(|e| die(format!("{efi}: {e}")));
    let qemu = env::var("STELLANG_QEMU").unwrap_or_else(|_| "qemu-system-x86_64".into());
    let mut cmd = Command::new(&qemu);
    cmd.args(["-machine", "q35", "-cpu", "max", "-m", "1G", "-bios", &ovmf(), "-rtc", "base=localtime", "-net", "none"]);
    cmd.arg("-drive").arg(format!("format=raw,file=fat:rw:{}", dir.display()));
    cmd.args(["-device", "isa-debug-exit,iobase=0xf4,iosize=0x01"]);
    // a USB controller with a mouse, like a laptop's (the keyboard: PS/2, QEMU's default)
    cmd.args(["-device", "qemu-xhci", "-device", "usb-mouse"]);
    if gui {
        cmd.args(["-serial", "mon:stdio"]);
    } else {
        cmd.args(["-display", "none", "-serial", "mon:stdio"]);
    }
    cmd.args(extra);
    let status = cmd.status().unwrap_or_else(|e| die(format!("cannot run {qemu}: {e} (Debian/Ubuntu: `apt install qemu-system-x86`)")));
    let _ = fs::remove_dir_all(&dir);
    if !input.ends_with(".efi") {
        let _ = fs::remove_file(efi);
    }
    // isa-debug-exit: the kernel's code c comes out as c*2+1
    exit(status.code().map(|c| if c & 1 == 1 { c >> 1 } else { c }).unwrap_or(1));
}

/// `stellang dev [dir]`: build `client.st` for the browser (into `public/client.wasm` + `.js`) and
/// `server.st` natively, run the server in `dir`, and rebuild + restart when a .st file changes.
fn dev(dir: &str) {
    use std::time::{Duration, Instant, SystemTime};
    let dir = Path::new(dir);
    let server = dir.join("server.st");
    if !server.exists() {
        die(format!("no server.st in {} (a full-stack app has server.st, and client.st for the browser)", dir.display()));
    }
    let client = dir.join("client.st");
    let me = env::current_exe().unwrap_or_else(|e| die(e));
    let exe = env::temp_dir().join(format!("stellang-dev-{}", std::process::id()));
    fn sources(d: &Path, out: &mut Vec<(std::path::PathBuf, SystemTime)>) {
        let Ok(rd) = fs::read_dir(d) else { return };
        for e in rd.flatten() {
            let p = e.path();
            let name = e.file_name().to_string_lossy().into_owned();
            if p.is_dir() && !name.starts_with('.') && name != "public" && name != "target" && name != "node_modules" {
                sources(&p, out);
            } else if name.ends_with(".st") {
                out.push((p.clone(), e.metadata().and_then(|m| m.modified()).unwrap_or(SystemTime::UNIX_EPOCH)));
            }
        }
    }
    let snapshot = || {
        let mut v = vec![];
        sources(dir, &mut v);
        v.sort();
        v
    };
    let build = || -> bool {
        let t = Instant::now();
        if client.exists() {
            let out = dir.join("public").join("client");
            let ok = Command::new(&me).arg("--web").arg(&client).arg("-o").arg(&out).env("STELLANG_NO_HTML", "1").status().is_ok_and(|s| s.success());
            if !ok {
                return false;
            }
        }
        let ok = Command::new(&me).arg(&server).arg("-o").arg(&exe).arg("-O1").status().is_ok_and(|s| s.success());
        if ok {
            eprintln!("\x1b[2mstellang dev: built in {} ms\x1b[0m", t.elapsed().as_millis());
        }
        ok
    };
    let start = || Command::new(&exe).current_dir(dir).spawn().ok();
    eprintln!("stellang dev: {}{} \u{2014} watching for changes (Ctrl+C to stop)", if client.exists() { "client.st -> public/client.wasm, " } else { "" }, "server.st");
    let mut child = if build() { start() } else { None };
    let mut seen = snapshot();
    loop {
        std::thread::sleep(Duration::from_millis(300));
        if let Some(c) = &mut child {
            if let Ok(Some(status)) = c.try_wait() {
                eprintln!("stellang dev: the server stopped ({status}); waiting for changes");
                child = None;
            }
        }
        let now = snapshot();
        if now == seen {
            continue;
        }
        seen = now;
        if let Some(mut c) = child.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
        eprintln!("\x1b[2mstellang dev: change detected, rebuilding\x1b[0m");
        if build() {
            child = start();
        }
    }
}
