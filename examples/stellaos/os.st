// StellaOS: an operating system written in stellang. A shell on the serial console, a RAM
// filesystem, background jobs on timers, and a calculator, all running on bare metal.
//
//     stellang boot examples/stellaos/os.st          (QEMU, RISC-V 64; Ctrl-A X force-quits)
//
// The C underneath (src/runtime_kernel.c) only boots the machine, fields interrupts and hands out
// memory; everything you see is the stellang below.

import kernel
import ramfs
import calc
import desktop

const VERSION = "0.1"

struct Job {
    id: int,
    timer: int,
    what: str,
}

struct Shell {
    fs: ramfs.RamFs = ramfs.RamFs {},
    cwd: str = "/",
    ed: kernel.LineEditor = kernel.LineEditor {},
    jobs: [Job] = [],
    next_job: int = 1,
    running: bool = true,

    fn prompt(self) -> str {
        let e = kernel.ESC
        return "${e}[1;35mstella${e}[0m:${e}[1;34m${self.cwd}${e}[0m$ "
    }

    fn path(self, p: str) -> str {
        return self.fs.resolve(self.cwd, p)
    }

    fn run(self, line: str) -> void! {
        let words = line.trim().split(" ").filter(w => w != "")
        if words.is_empty() { return }
        let cmd = words[0]
        let args = words.slice(1, words.len())
        let rest = line.trim().slice(cmd.len(), line.trim().len()).trim()
        match cmd {
            "help" => help(),
            "echo" => println(rest),
            "clear" => kernel.clear_screen(),
            "uname" => println("StellaOS ${VERSION} (stellang, riscv64, QEMU virt)"),
            "uptime" => println("up ${seconds(kernel.uptime())}, ${kernel.ticks()} timer ticks"),
            "mem" => mem(),
            "gc" => {
                let before = kernel.memory().live
                kernel.gc()
                println("collected: ${size(kernel.memory().live)} live (was ${size(before)} after the last collection)")
            },
            "pwd" => println(self.cwd),
            "ls" => {
                let dir = self.path(args.get(0) ?? ".")
                if !self.fs.is_dir(dir) { return err("no such directory: ${dir}") }
                for name in self.fs.list(dir) {
                    if name.ends_with("/") {
                        println("${kernel.ESC}[1;34m${name}${kernel.ESC}[0m")
                    } else {
                        let bytes = self.fs.files[self.fs.resolve(dir, name)].len()
                        println("${name}  (${size(bytes)})")
                    }
                }
            },
            "cd" => {
                let dir = self.path(args.get(0) ?? "/")
                if !self.fs.is_dir(dir) { return err("no such directory: ${dir}") }
                self.cwd = dir
            },
            "mkdir" => self.fs.mkdir(self.path(need(args, 0, "mkdir <dir>")?))?,
            "cat" => print(self.fs.read(self.path(need(args, 0, "cat <file>")?))?),
            "write" | "append" => {
                let file = self.path(need(args, 0, "${cmd} <file> <text>")?)
                let text = rest.slice(args[0].len(), rest.len()).trim() + "\n"
                let old = if cmd == "append" { self.fs.read(file) catch "" } else { "" }
                self.fs.write(file, old + text)?
            },
            "edit" => self.edit(self.path(need(args, 0, "edit <file>")?))?,
            "rm" => self.fs.remove(self.path(need(args, 0, "rm <path>")?))?,
            "wc" => {
                let text = self.fs.read(self.path(need(args, 0, "wc <file>")?))?
                let words = text.split(" ").map(w => w.trim()).filter(w => w != "").len()
                println("${text.lines().len()} lines, ${words} words, ${text.len()} bytes")
            },
            "calc" => {
                let n = calc.eval(rest)?
                println("${n}  (${calc.hex(n)})")
            },
            "every" => self.every(args, rest)?,
            "jobs" => {
                if self.jobs.is_empty() { println("no jobs") }
                for j in self.jobs { println("[${j.id}] ${j.what}") }
            },
            "kill" => {
                let id = int(need(args, 0, "kill <job>")?)?
                let found = self.jobs.find(j => j.id == id)
                if let j = found { kernel.cancel(j.timer) } else { return err("no job ${id}") }
                self.jobs = self.jobs.filter(x => x.id != id)
            },
            "sleep" => sleep(int(need(args, 0, "sleep <ms>")?)?),
            "history" => {
                for i, h in self.ed.history { println("${i + 1}  ${h}") }
            },
            "peek" => {
                let addr = calc.eval(need(args, 0, "peek <address>")?)?
                let v = kernel.peek32(addr)
                println("${calc.hex(addr)}: ${calc.hex(v)}")
            },
            "shutdown" | "exit" | "poweroff" => {
                println("bye!")
                self.running = false
            },
            "desktop" => {
                let m = kernel.memory()
                let info = [
                    "RAM      ${size(m.ram)}",
                    "Heap     ${size(m.heap)}",
                    "Free     ${size(m.free)}",
                    "Files    ${self.fs.files.len()}, ${size(self.fs.used())}",
                    "Jobs     ${self.jobs.len()}",
                    "Up       ${seconds(kernel.uptime())}",
                ]
                let files = self.fs.files.keys()
                desktop.show(info, files)?
                println("the desktop is on the display (the shell keeps running here)")
            },
            "reboot" => kernel.reboot(),
            "panic" => panic("you asked for it"),
            _ => return err("unknown command: ${cmd} (try `help`)"),
        }
    }

    // `every <ms> <command>`: run a command in the background, on a timer
    fn every(self, args: [str], rest: str) -> void! {
        let ms = int(need(args, 0, "every <ms> <command>")?)?
        let cmd = rest.slice(args[0].len(), rest.len()).trim()
        if cmd == "" { return err("usage: every <ms> <command>") }
        if ms < 10 { return err("every: at least 10 ms") }
        let id = self.next_job
        self.next_job += 1
        let timer = kernel.every(ms, () => {
            self.run(cmd) catch e { println("[${id}] ${e}") }
        })
        self.jobs.push(Job { id, timer, what: "every ${ms} ms: ${cmd}" })
        println("[${id}] started (stop it with `kill ${id}`)")
    }

    // a tiny line editor: shows the file, then appends what you type until a line with just "."
    fn edit(self, file: str) -> void! {
        let old = self.fs.read(file) catch ""
        if old != "" { print(old) }
        println("${kernel.ESC}[2m(type lines to add; a line with just . saves)${kernel.ESC}[0m")
        var text = old
        let ed = kernel.LineEditor {}
        while true {
            let line = ed.read("")
            if line == "." { break }
            text += line + "\n"
        }
        self.fs.write(file, text)?
        println("saved ${file} (${size(text.len())})")
    }
}

fn need(args: [str], i: int, usage: str) -> str! {
    if let a = args.get(i) { return a }
    return err("usage: ${usage}")
}

fn help() {
    println("files     ls [dir]  cd <dir>  pwd  mkdir <dir>  cat <file>  rm <path>  wc <file>")
    println("          write <file> <text>  append <file> <text>  edit <file>")
    println("system    mem  gc  uptime  uname  history  clear  shutdown  reboot")
    println("jobs      every <ms> <command>  jobs  kill <job>  sleep <ms>")
    println("tools     echo <text>  calc <expr>  peek <address>  desktop  panic")
    println("keys      arrows edit and recall history, Ctrl-U clears the line, Ctrl-D exits")
}

fn mem() {
    let m = kernel.memory()
    println("RAM      ${size(m.ram)}")
    println("kernel   ${size(m.kernel)}  (code, globals, 512 KiB stack)")
    println("heap     ${size(m.heap)} taken from RAM, ${size(m.live)} live after the last collection")
    println("free     ${size(m.free)}")
    println("gc runs  ${m.collections}")
}

fn size(n: int) -> str {
    if n >= 1 << 20 { return "${n / (1 << 20)}.${n % (1 << 20) * 10 / (1 << 20)} MiB" }
    if n >= 1 << 10 { return "${n / (1 << 10)} KiB" }
    return "${n} B"
}

fn seconds(ms: int) -> str {
    let s = ms / 1000
    if s < 60 { return "${s}.${ms % 1000 / 100}s" }
    return "${s / 60}m ${s % 60}s"
}

fn banner() {
    let e = kernel.ESC
    println("")
    println("${e}[1;35m   ✦  StellaOS ${VERSION}${e}[0m")
    println("${e}[2m      an operating system written in stellang${e}[0m")
    let m = kernel.memory()
    println("${e}[2m      ${size(m.ram)} RAM, booted in ${kernel.uptime()} ms; type `help`${e}[0m")
    println("")
}

// the files a fresh boot starts with
fn setup(sh: Shell) -> void! {
    sh.fs.mkdir("/home")?
    sh.fs.mkdir("/etc")?
    sh.fs.write("/etc/motd", "Welcome to StellaOS. Everything here lives in RAM, so nothing survives a reboot.\n")?
    sh.fs.write("/home/hello.st", "fn main() {\n    println(\"hello from StellaOS\")\n}\n")?
}

fn main() {
    let sh = Shell {}
    setup(sh) catch e { println("setup: ${e}") }
    sh.cwd = "/home"
    banner()
    print(sh.fs.read("/etc/motd") catch "")
    while sh.running {
        let line = sh.ed.read(sh.prompt())
        sh.run(line) catch e { println("${kernel.ESC}[31merror:${kernel.ESC}[0m ${e}") }
    }
}
