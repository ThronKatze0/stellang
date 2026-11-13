// StellaOS: an operating system written in stellang. A desktop with windows, apps and games, a
// shell, a RAM file system and background jobs, all running on bare metal.
//
//     stellang boot --gui examples/stellaos/os.st    (the desktop in a window, the shell here too)
//     stellang boot examples/stellaos/os.st          (just the shell; Ctrl-A X force-quits)
//
// The C underneath (src/runtime_kernel.c) only boots the machine, fields interrupts, hands out
// memory and draws pixels fast; everything else is stellang: the drivers (display.st, input.st,
// virtio.st), the window manager (wm.st), the UI toolkit that runs JSX apps (ui.st), the apps.

import kernel
import ramfs
import calc
import wm
import web
import ui
import input
import term
import files
import notes
import calculator
import monitor
import snake
import breakout
import mines
import paint
import disk
import rng
import inet
import netcmd
import tcp
import browser

const VERSION = "0.3"

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
    gui: wm.Desktop? = none,
    disk: disk.Disk? = none,
    saved: int = 0,           // fs.changes when it was last saved
    terminal: int = 0,        // the terminal window's id
    net: inet.Net? = none,
    tcp: tcp.Tcp? = none,

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
        let argv = words.slice(1, words.len())
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
                let dir = self.path(argv.get(0) ?? ".")
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
                let dir = self.path(argv.get(0) ?? "/")
                if !self.fs.is_dir(dir) { return err("no such directory: ${dir}") }
                self.cwd = dir
            },
            "mkdir" => self.fs.mkdir(self.path(need(argv, 0, "mkdir <dir>")?))?,
            "cat" => print(self.fs.read(self.path(need(argv, 0, "cat <file>")?))?),
            "write" | "append" => {
                let file = self.path(need(argv, 0, "${cmd} <file> <text>")?)
                let text = rest.slice(argv[0].len(), rest.len()).trim() + "\n"
                let old = if cmd == "append" { self.fs.read(file) catch "" } else { "" }
                self.fs.write(file, old + text)?
            },
            "edit" => self.edit(self.path(need(argv, 0, "edit <file>")?))?,
            "rm" => self.fs.remove(self.path(need(argv, 0, "rm <path>")?))?,
            "wc" => {
                let text = self.fs.read(self.path(need(argv, 0, "wc <file>")?))?
                let words = text.split(" ").map(w => w.trim()).filter(w => w != "").len()
                println("${text.lines().len()} lines, ${words} words, ${text.len()} bytes")
            },
            "calc" => {
                let n = calc.eval(rest)?
                println("${n}  (${calc.hex(n)})")
            },
            "every" => self.every(argv, rest)?,
            "jobs" => {
                if self.jobs.is_empty() { println("no jobs") }
                for j in self.jobs { println("[${j.id}] ${j.what}") }
            },
            "kill" => {
                let id = int(need(argv, 0, "kill <job>")?)?
                let found = self.jobs.find(j => j.id == id)
                if let j = found { kernel.cancel(j.timer) } else { return err("no job ${id}") }
                self.jobs = self.jobs.filter(x => x.id != id)
            },
            "sleep" => sleep(int(need(argv, 0, "sleep <ms>")?)?),
            "history" => {
                for i, h in self.ed.history { println("${i + 1}  ${h}") }
            },
            "peek" => {
                let addr = calc.eval(need(argv, 0, "peek <address>")?)?
                let v = kernel.peek32(addr)
                println("${calc.hex(addr)}: ${calc.hex(v)}")
            },
            "shutdown" | "exit" | "poweroff" => {
                self.sync()
                println("bye!")
                self.running = false
            },
            "sync" => {
                if self.disk == none { return err("no disk (files live in RAM only)") }
                self.sync()
                println("saved to disk")
            },
            "df" => {
                if let d = self.disk {
                    println("disk     ${size(d.size())}, ${size(self.fs.used())} in ${self.fs.files.len()} files")
                } else {
                    println("no disk: files live in RAM only (`stellang boot` attaches one)")
                }
            },
            "windows" => {
                let d = self.desktop()?
                for w in d.windows {
                    println("${w.id}  ${w.title}  ${w.w}x${w.h} at ${w.x},${w.y}${if w.id == d.focus { "  (focused)" } else { "" }}")
                }
            },
            "desktop" => {
                if let d = self.gui {
                    println("the desktop is already on the display")
                } else {
                    self.start_desktop()?
                    println("the desktop is on the display (the shell keeps running here)")
                }
            },
            "open" => {
                let name = need(argv, 0, "open <app>  (see `apps`)")?
                let d = self.desktop()?
                if let l = d.launchers.find(l => l.name.lower() == name.lower()) {
                    l.open()
                } else {
                    return err("no app called ${name} (see `apps`)")
                }
            },
            "apps" => {
                let d = self.desktop()?
                println(d.launchers.map(l => l.name.lower()).join("  "))
            },
            "date" => {
                let t = kernel.date(kernel.time_ms())
                println("${kernel.WEEKDAYS[t.weekday]} ${t.day} ${kernel.MONTHS[t.month - 1]} ${t.year}, ${kernel.two(t.hour)}:${kernel.two(t.minute)}:${kernel.two(t.second)}")
            },
            "keyboard" => {
                let d = self.desktop()?
                let layout = need(argv, 0, "keyboard us|de")?
                if layout != "us" && layout != "de" { return err("layouts: us, de") }
                d.inp.layout = layout
                println("keyboard layout: ${layout}")
            },
            "reboot" => {
                self.sync()
                kernel.reboot()
            },
            "ifconfig" | "ip" => netcmd.ifconfig(self.network()?, argv)?,
            "ping" => netcmd.ping(self.network()?, argv)?,
            "host" | "nslookup" => netcmd.host(self.network()?, argv)?,
            "arp" => netcmd.arp(self.network()?),
            "firewall" => netcmd.firewall(self.network()?, argv)?,
            "dns" => netcmd.dns(self.network()?, argv)?,
            "browse" => {
                self.desktop()?
                self.sockets()?
                self.browse(argv.get(0) ?? "")
            },
            "netstat" => netcmd.netstat(self.sockets()?),
            "fetch" | "curl" | "wget" => netcmd.fetch(self.sockets()?, self.fs, self.cwd, argv)?,
            "panic" => panic("you asked for it"),
            _ => return err("unknown command: ${cmd} (try `help`)"),
        }
    }

    // `every <ms> <command>`: run a command in the background, on a timer
    fn every(self, argv: [str], rest: str) -> void! {
        let ms = int(need(argv, 0, "every <ms> <command>")?)?
        let cmd = rest.slice(argv[0].len(), rest.len()).trim()
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

    fn network(self) -> inet.Net! {
        if let n = self.net { return n }
        return err("no network card (`stellang boot` adds one unless --no-net)")
    }

    fn sockets(self) -> tcp.Tcp! {
        if let t = self.tcp { return t }
        return err("no network card (`stellang boot` adds one unless --no-net)")
    }

    fn desktop(self) -> wm.Desktop! {
        if let d = self.gui { return d }
        return err("no desktop (boot with `stellang boot --gui`)")
    }

    // Save the files if something changed since last time.
    fn sync(self) {
        if let d = self.disk {
            if self.fs.changes == self.saved { return }
            self.fs.save(d) catch e {
                println("disk: ${e}")
                return
            }
            self.saved = self.fs.changes
        }
    }

    // Take over the display, keyboard and mouse, and put the apps on the desktop.
    fn start_desktop(self) -> void! {
        let d = wm.start(1024, 768)?
        self.gui = some(d)
        let fs = self.fs
        let edit = (path: str) => notes.open(d, fs, path)
        d.launchers = [
            wm.Launcher { name: "Terminal", icon: ">_", color: 0x2d3436, open: () => self.open_terminal(d) },
            wm.Launcher { name: "Files", icon: "▤", color: 0x0984e3, open: () => files.open(d, fs, edit) },
            wm.Launcher { name: "Notes", icon: "✎", color: 0xf0932b, open: () => notes.open(d, fs, "") },
            wm.Launcher { name: "Calculator", icon: "=", color: 0x6c5ce7, open: () => calculator.open(d) },
            wm.Launcher { name: "Browser", icon: "◎", color: 0x0984e3, open: () => self.browse("") },
            wm.Launcher { name: "Monitor", icon: "◉", color: 0x00b894, open: () => monitor.open(d) },
            wm.Launcher { name: "Snake", icon: "S", color: 0x10ac84, open: () => snake.open(d) },
            wm.Launcher { name: "Bricks", icon: "B", color: 0xff9f43, open: () => breakout.open(d) },
            wm.Launcher { name: "Mines", icon: "✹", color: 0x576574, open: () => mines.open(d) },
            wm.Launcher { name: "Paint", icon: "✎", color: 0xe84393, open: () => paint.open(d) },
        ]
        d.on_shutdown = () => {
            self.sync()
            println("bye!")
            kernel.shutdown(0)
        }
        d.hurt_all()
        kernel.every(16, () => d.frame())
    }

    fn browse(self, url: str) {
        if let d = self.gui {
            if let t = self.tcp {
                browser.open(d, t, url)
            } else {
                let w = d.open("Browser", "◎", 0x0984e3, 360, 120, ui.app(() => <p style="padding: 20px">"No network card (boot without --no-net)."</p>))
            }
        }
    }

    fn open_terminal(self, d: wm.Desktop) {
        if let w = d.find(self.terminal) {
            d.focus_window(w.id)
            return
        }
        let w = d.open("Terminal", ">_", 0x2d3436, 660, 400, term.app())
        self.terminal = w.id
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

fn need(argv: [str], i: int, usage: str) -> str! {
    if let a = argv.get(i) { return a }
    return err("usage: ${usage}")
}

fn help() {
    println("files     ls [dir]  cd <dir>  pwd  mkdir <dir>  cat <file>  rm <path>  wc <file>")
    println("          write <file> <text>  append <file> <text>  edit <file>")
    println("system    mem  gc  df  sync  uptime  uname  history  clear  shutdown  reboot")
    println("jobs      every <ms> <command>  jobs  kill <job>  sleep <ms>")
    println("tools     echo <text>  calc <expr>  peek <address>  date  panic")
    println("network   ifconfig [set <ip>/<bits> [gw] | dhcp]  ping [-c n] <host>  host <name>  arp  firewall [ping on|off|log]")
    println("          fetch [-i] <url> [-o file]  browse [url]  netstat  dns [server]")
    println("desktop   desktop  apps  open <app>  windows  keyboard us|de")
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
    sh.fs.write("/etc/motd", "Welcome to StellaOS. Your files are kept on the disk (when there is one: `df`).\n")?
    sh.fs.write("/home/hello.st", "fn main() {\n    println(\"hello from StellaOS\")\n}\n")?
    sh.fs.write("/home/todo.txt", "- try the games (Snake, Bricks, Mines)\n- paint something\n- write a note and save it\n")?
    sh.fs.mkdir("/home/pictures")?
}

fn main() {
    let sh = Shell {}
    // the files: from the disk if it has them, else a fresh set
    sh.disk = disk.open()
    var loaded = false
    if let d = sh.disk {
        loaded = sh.fs.load(d) catch e {
            println("disk: ${e}")
            false
        }
    }
    if !loaded { setup(sh) catch e { println("setup: ${e}") } }
    sh.saved = if loaded { sh.fs.changes } else { -1 }
    sh.sync()
    // save a moment after changes
    kernel.every(2000, () => sh.sync())
    sh.cwd = "/home"
    sh.net = inet.open(rng.open())
    if let n = sh.net { sh.tcp = some(tcp.start(n)) }
    banner()
    print(sh.fs.read("/etc/motd") catch "")
    // a display: the desktop comes up by itself, with a terminal on it
    sh.start_desktop() catch e { println("${kernel.ESC}[2m(no display: just this shell. `stellang boot --gui` for the desktop)${kernel.ESC}[0m") }
    if let d = sh.gui {
        sh.open_terminal(d)
        println("${kernel.ESC}[2mthe desktop is up on the display; this shell is also in its Terminal${kernel.ESC}[0m")
    }
    while sh.running {
        let line = sh.ed.read(sh.prompt())
        sh.run(line) catch e { println("${kernel.ESC}[31merror:${kernel.ESC}[0m ${e}") }
    }
}
