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
import tls
import www
import browser
import proc
import cc
import code
import progwin
import userland
import rv
import sound
import users
import login

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
    web: www.Client? = none,
    procs: proc.Procs = proc.Procs {},
    user: str = "",               // who is logged in ("" nobody)
    home: str = "/home",
    accounts: users.Users? = none,
    lock: login.Screen? = none,
    sudo_until: int = 0,          // a recent sudo: no password again until then
    random: rng.Rng? = none,
    snd: sound.Card? = none,

    fn prompt(self) -> str {
        let e = kernel.ESC
        let color = if self.user == "root" { "1;31" } else { "1;35" }
        let mark = if self.user == "root" { "#" } else { "$" }
        let here = if self.cwd == self.home { "~" } else if self.cwd.starts_with(self.home + "/") { "~" + self.cwd.slice(self.home.len(), self.cwd.len()) } else { self.cwd }
        return "${e}[${color}m${self.user}@stella${e}[0m:${e}[1;34m${here}${e}[0m${mark} "
    }

    fn path(self, p: str) -> str {
        if p == "~" { return self.home }
        if p.starts_with("~/") { return self.fs.resolve(self.home, p.slice(2, p.len())) }
        return self.fs.resolve(self.cwd, p)
    }

    fn run(self, line: str) -> void! {
        let words = line.trim().split(" ").filter(w => w != "")
        if words.is_empty() { return }
        if self.user == "" { return err("log in first") }
        let cmd = words[0]
        let argv = words.slice(1, words.len())
        let rest = line.trim().slice(cmd.len(), line.trim().len()).trim()
        // commands that change the machine for everyone, or look inside the kernel: root only
        let system = ["peek", "panic"].contains(cmd) || (["ifconfig", "ip", "dns"].contains(cmd) && !argv.is_empty()) ||
            (cmd == "firewall" && !argv.is_empty() && argv[0] != "log")
        if system && self.user != "root" { return err("`${cmd}` needs an administrator: sudo ${line.trim()}") }
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
                let long = argv.contains("-l")
                let args2 = argv.filter(a => a != "-l")
                let dir = self.path(args2.get(0) ?? ".")
                if !self.fs.is_dir(dir) { return err("no such directory: ${dir}") }
                if !self.fs.can_read(self.user, dir) { return err(self.fs.denied(dir)) }
                for name in self.fs.list(dir) {
                    let full = self.fs.resolve(dir, name)
                    let meta = if long { "${self.fs.mode_text(full)}  ${self.fs.owner(full)}${" ".repeat(max(1, 10 - self.fs.owner(full).len()))}" } else { "" }
                    if name.ends_with("/") {
                        println("${meta}${kernel.ESC}[1;34m${name}${kernel.ESC}[0m")
                    } else {
                        let bytes = self.fs.files[full].len()
                        println("${meta}${name}  (${size(bytes)})")
                    }
                }
            },
            "cd" => {
                let dir = self.path(argv.get(0) ?? self.home)
                if !self.fs.is_dir(dir) { return err("no such directory: ${dir}") }
                if !self.fs.can_read(self.user, dir) || !self.fs.may(self.user, dir, 1) { return err(self.fs.denied(dir)) }
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
                let id = int(need(argv, 0, "kill <job | pid>")?)?
                if let p = self.procs.find(id) {
                    p.kill("killed")
                    println("killed process ${id} (${p.name})")
                    return
                }
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
            "fetch" | "curl" | "wget" => netcmd.fetch(self.client()?, self.fs, self.cwd, argv)?,
            "whoami" => println(self.user),
            "users" => {
                for a in self.users_db()?.people() { println("${a.name}${if a.admin { "  (administrator)" } else { "" }}  ${a.home}") }
            },
            "adduser" => self.adduser(argv)?,
            "passwd" => self.passwd()?,
            "sudo" => self.sudo(rest)?,
            "logout" => self.end_session(false),
            "chmod" => {
                let m = need(argv, 0, "chmod <mode, like 644 or 700> <path>")?
                let path = self.path(need(argv, 1, "chmod <mode> <path>")?)
                self.fs.chmod(path, octal(m)?)?
            },
            "chown" => {
                let u = need(argv, 0, "chown <user> <path>")?
                if self.users_db()?.find(u) == none { return err("no user called ${u}") }
                self.fs.chown(self.path(need(argv, 1, "chown <user> <path>")?), u)?
            },
            "cc" => self.compile_cmd(argv)?,
            "run" => self.run_program(need(argv, 0, "run <file.st | program>")?)?,
            "ps" => self.ps(),
            "beep" => {
                let hz = if argv.len() > 0 { int(argv[0])? } else { 880 }
                let ms = if argv.len() > 1 { int(argv[1])? } else { 200 }
                if self.snd == none { return err("no sound card (`stellang boot` adds one unless --no-sound)") }
                self.beep(max(20, min(hz, 20000)), max(1, min(ms, 10000)))
            },
            "sound" => {
                if let c = self.snd {
                    println("virtio sound card: stream ${c.stream}, ${c.rate} Hz, ${c.channels} channel${if c.channels == 1 { "" } else { "s" }}, 16-bit; ${c.played} periods played")
                } else {
                    println("no sound card (`stellang boot` adds one unless --no-sound)")
                }
            },
            "code" => {
                let d = self.desktop()?
                let path = if argv.is_empty() { "" } else { self.path(argv[0]) }
                self.open_code(d, path)
            },
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

    // ---- programs ----

    // what a process's system calls reach: its output, its window, sound, files
    fn sys(self) -> proc.Sys {
        let sys = proc.Sys {}
        sys.random = () => {
            if let r = self.random { return r.u32() << 31 ^ r.u32() }
            return kernel.uptime()
        }
        sys.window = (p: proc.Proc) => {}
        sys.beep = (hz: int, ms: int) => self.beep(hz, ms)
        if let d = self.gui {
            sys.window = (p: proc.Proc) => { progwin.open(d, p) }
        }
        // files: as the program's user, relative to their home
        let home = self.home
        sys.read = (p: proc.Proc, path: str) => {
            let full = self.fs.resolve(home, path)
            if !self.fs.is_file(full) || !self.fs.can_read(p.user, full) { return none }
            return some(self.fs.read_as(p.user, full) catch "")
        }
        sys.save = (p: proc.Proc, path: str, text: str) => {
            let full = self.fs.resolve(home, path)
            self.fs.write_as(p.user, full, text) catch e { return "${e}" }
            return ""
        }
        return sys
    }

    fn beep(self, hz: int, ms: int) {
        if let c = self.snd { c.beep(hz, ms) }
    }

    fn code_env(self) -> code.Env {
        return code.Env {
            fs: self.fs,
            procs: self.procs,
            home: () => self.home,
            user: () => self.user,
            sys: () => self.sys(),
            can_write: (p: str) => self.fs.can_write(self.user, p),
        }
    }

    fn open_code(self, d: wm.Desktop, path: str) {
        code.open(d, self.code_env(), path)
    }

    // cc <file.st> [-o <program>]: compile to a program file
    fn compile_cmd(self, argv: [str]) -> void! {
        let src = self.path(need(argv, 0, "cc <file.st> [-o <program>]")?)
        var out = if src.ends_with(".st") { src.slice(0, src.len() - 3) } else { src + ".out" }
        if argv.len() >= 3 && argv[1] == "-o" { out = self.path(argv[2]) }
        let text = self.fs.read(src)?
        let res = cc.compile(text, () => kernel.uptime())
        if !res.errors.is_empty() {
            let e = res.errors[0]
            return err("${src}:${e.line}:${e.col}: ${e.msg}")
        }
        self.fs.write(out, cc.exe_text(res.image))?
        println("${out}: ${size(res.image.bytes.len())} of RISC-V machine code (${res.functions} functions, compiled in ${res.ms} ms)")
    }

    // run a program in the foreground: a .st source (compiled first) or a compiled program file
    fn run_program(self, file: str) -> void! {
        let path = self.path(file)
        let text = self.fs.read(path)?
        var img = rv_image_none()
        if cc.is_exe(text) {
            if let i = cc.exe_parse(text) { img = i } else { return err("${path}: a damaged program file") }
        } else {
            let res = cc.compile(text, () => kernel.uptime())
            if !res.errors.is_empty() {
                let e = res.errors[0]
                return err("${path}:${e.line}:${e.col}: ${e.msg}")
            }
            img = res.image
        }
        let sys = self.sys()
        sys.write = (p: proc.Proc, s: str) => print(s)
        let p = self.procs.spawn(self.fs.name(path), self.user, img.bytes, img.data_at, img.data_size, sys)?
        // in the foreground: the program has the terminal until it ends (Ctrl-C ends it)
        while !p.done() {
            if p.state == "input" {
                let line = self.ed.read("")
                p.give_line(line)
                continue
            }
            let c = kernel_read_byte()
            if c == 3 {
                p.kill("interrupted (Ctrl-C)")
                println("^C")
            }
            kernel.idle()
        }
        if p.why != "" { return err("${p.name}: ${p.why}") }
        if p.code != 0 { println("${kernel.ESC}[2m(exit code ${p.code})${kernel.ESC}[0m") }
    }

    fn ps(self) {
        let ps = self.procs.running()
        if ps.is_empty() {
            println("no programs running")
            return
        }
        println("  PID  USER      STATE     CPU     NAME")
        for p in ps {
            println("${pad(p.pid, 5)}  ${p.user.slice(0, min(8, p.user.len()))}${" ".repeat(max(0, 10 - p.user.len()))}${p.state}${" ".repeat(max(0, 10 - p.state.len()))}${pad(p.cpu, 5)}ms  ${p.name}")
        }
    }

    // ---- users and sessions ----

    fn users_db(self) -> users.Users! {
        if let u = self.accounts { return u }
        return err("no user database")
    }

    fn admin(self) -> bool {
        if self.user == "root" { return true }
        if let u = self.accounts {
            if let a = u.find(self.user) { return a.admin }
        }
        return false
    }

    // someone logged in (on the console or the login screen)
    fn begin_session(self, name: str) {
        let u = self.accounts.unwrap()
        let a = u.find(name).unwrap()
        self.user = name
        self.home = a.home
        self.cwd = a.home
        self.fs.who = name
        self.ed.history = []
        if let d = self.gui {
            d.session = name
            d.cover(none)
            self.open_terminal(d)
        }
        if let c = self.snd {
            c.beep(523, 90)
            kernel.after(100, () => c.beep(659, 90))
            kernel.after(200, () => c.beep(784, 160))
        }
        println("")
        println("${kernel.ESC}[1mHello, ${name}!${kernel.ESC}[0m${kernel.ESC}[2m  (your files: ${a.home}; `help` for commands)${kernel.ESC}[0m")
    }

    fn end_session(self, wake_console: bool) {
        if self.user == "" { return }
        let who = self.user
        for p in self.procs.running() {
            if p.user == who { p.kill("its user logged out") }
        }
        self.sync()
        self.user = ""
        self.sudo_until = 0
        self.fs.who = "nobody"
        self.home = "/"
        self.cwd = "/"
        if let d = self.gui {
            for w in d.windows.slice(0, d.windows.len()) { d.close(w.id) }
            d.session = ""
            self.show_login(d, who)
        }
        println("logged out")
        if wake_console { st_k_inject(3) }     // the console's line editor is waiting: back to `login:`
    }

    fn show_login(self, d: wm.Desktop, name: str) {
        let u = self.accounts.unwrap()
        let setup = u.people().is_empty()
        let sc = login.screen(d, setup, name, (n: str, pw: str) => self.try_login(n, pw), (n: str, pw: str) => self.try_create(n, pw))
        self.lock = some(sc)
        d.cover(some(login.app(sc)))
    }

    fn try_login(self, name: str, pw: str) -> str {
        let u = self.accounts.unwrap()
        let problem = u.check(name, pw)
        if problem != "" { return problem }
        self.begin_session(name)
        return ""
    }

    // the first account: an administrator
    fn try_create(self, name: str, pw: str) -> str {
        let u = self.accounts.unwrap()
        if !u.people().is_empty() { return "there already are accounts: log in" }
        u.create(name, pw, true) catch e { return "${e}" }
        self.welcome_home(name)
        self.sync()
        self.begin_session(name)
        return ""
    }

    // a new home's first files
    fn welcome_home(self, name: str) {
        let home = "/home/${name}"
        let was = self.fs.who
        self.fs.who = name
        self.fs.write(home + "/todo.txt", "- try the games (Snake, Bricks, Mines)\n- write a program in Code (the examples are in /home/examples)\n- paint something\n") catch e {}
        self.fs.mkdir(home + "/pictures") catch e {}
        self.fs.who = was
    }

    // The console's login: on a fresh system it makes the first account. Returns when someone is
    // logged in (here or on the login screen).
    fn console_login(self) {
        let u = self.accounts.unwrap()
        if u.people().is_empty() {
            println("")
            println("This computer has no accounts yet: make yours (you'll be its administrator).")
            let name = self.ask("new user name: ", true) ?? ""
            if self.user != "" { return }
            let problem = u.valid_name(name)
            if problem != "" {
                println(problem)
                return
            }
            let pw = self.ask("password: ", false) ?? ""
            if self.user != "" { return }
            let again = self.ask("password again: ", false) ?? ""
            if self.user != "" { return }
            if pw != again {
                println("the passwords aren't the same")
                return
            }
            let p2 = self.try_create(name, pw)
            if p2 != "" { println(p2) }
            return
        }
        let name = self.ask("login: ", true) ?? ""
        if self.user != "" || name == "" { return }
        let pw = self.ask("password: ", false) ?? ""
        if self.user != "" { return }
        let problem = self.try_login(name, pw)
        if problem != "" { println(problem) }
    }

    // a line from the console (echoed, or not for passwords); none if someone logs in meanwhile
    fn ask(self, prompt: str, echo: bool) -> str? {
        print(prompt)
        let logged_out = self.user == ""
        var line = ""
        var esc = 0
        while true {
            if logged_out && self.user != "" { return none }
            let c = kernel_read_byte()
            if c < 0 {
                kernel.idle()
                continue
            }
            if esc > 0 {
                esc = if esc == 1 && c == 91 { 2 } else if c >= 64 && c <= 126 { 0 } else { esc }
                continue
            }
            if c == 27 {
                esc = 1
            } else if c == 13 || c == 10 {
                println("")
                return some(line)
            } else if c == 127 || c == 8 {
                if line.len() > 0 {
                    let cs = line.chars()
                    cs.pop()
                    line = cs.join("")
                    if echo { print(st_chr(8) + " " + st_chr(8)) }
                }
            } else if c == 3 {
                println("^C")
                return some("")
            } else if c >= 32 {
                let ch = st_chr_byte(c)
                line += ch
                if echo { print(ch) }
            }
        }
        return none
    }

    // adduser <name> [--admin]
    fn adduser(self, argv: [str]) -> void! {
        if !self.admin() { return err("only an administrator can add users (try `sudo adduser ...`)") }
        let name = need(argv, 0, "adduser <name> [--admin]")?
        let u = self.users_db()?
        let problem = u.valid_name(name)
        if problem != "" { return err(problem) }
        if u.find(name) != none { return err("there already is a user called ${name}") }
        let pw = self.ask("password for ${name}: ", false) ?? ""
        let again = self.ask("again: ", false) ?? ""
        if pw != again { return err("the passwords aren't the same") }
        u.create(name, pw, argv.contains("--admin"))?
        self.welcome_home(name)
        println("added ${name}${if argv.contains("--admin") { " (an administrator)" } else { "" }}, home ${"/home/" + name}")
    }

    fn passwd(self) -> void! {
        let u = self.users_db()?
        let old = self.ask("current password: ", false) ?? ""
        let problem = u.check(self.user, old)
        if problem != "" { return err(problem) }
        let pw = self.ask("new password: ", false) ?? ""
        let again = self.ask("again: ", false) ?? ""
        if pw != again { return err("the passwords aren't the same") }
        u.set_password(self.user, pw)?
        println("password changed")
    }

    // sudo <command>: run one command as root, after your password
    fn sudo(self, cmd: str) -> void! {
        if cmd == "" { return err("usage: sudo <command>") }
        if self.user == "root" {
            self.run(cmd)?
            return
        }
        if !self.admin() { return err("${self.user} isn't an administrator") }
        let u = self.users_db()?
        if kernel.uptime() > self.sudo_until {
            let pw = self.ask("[sudo] password for ${self.user}: ", false) ?? ""
            let problem = u.check(self.user, pw)
            if problem != "" { return err(problem) }
        }
        self.sudo_until = kernel.uptime() + 300000
        let me = self.user
        self.user = "root"
        self.fs.who = "root"
        let result = self.run(cmd)
        self.user = me
        self.fs.who = me
        result?
    }

    fn network(self) -> inet.Net! {
        if let n = self.net { return n }
        return err("no network card (`stellang boot` adds one unless --no-net)")
    }

    fn sockets(self) -> tcp.Tcp! {
        if let t = self.tcp { return t }
        return err("no network card (`stellang boot` adds one unless --no-net)")
    }

    fn client(self) -> www.Client! {
        if let w = self.web { return w }
        return err("no network card (`stellang boot` adds one unless --no-net)")
    }

    // extra trusted root certificates: PEM files in /etc/ca
    fn extra_roots(self) -> str {
        var all: [str] = []
        if self.fs.is_dir("/etc/ca") {
            for name in self.fs.list("/etc/ca") {
                if !name.ends_with("/") { all.push(self.fs.read("/etc/ca/" + name) catch "") }
            }
        }
        return all.join("\n")
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
        let edit = (path: str) => {
            if path.ends_with(".st") { self.open_code(d, path) } else { notes.open(d, fs, path) }
        }
        d.launchers = [
            wm.Launcher { name: "Terminal", icon: ">_", color: 0x2d3436, open: () => self.open_terminal(d) },
            wm.Launcher { name: "Code", icon: "{}", color: 0x6c5ce7, open: () => self.open_code(d, "") },
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
            if let t = self.web {
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

extern fn st_k_read_byte() -> int
extern fn st_k_inject(b: int)
extern fn st_chr(code: int) -> str
fn st_chr_byte(c: int) -> str { return st_chr(c) }

// "644" -> 0o644
fn octal(s: str) -> int! {
    var v = 0
    for c in s.chars() {
        if c < "0" || c > "7" { return err("a mode is octal digits, like 644 or 700") }
        v = v * 8 + (int(c)?)
    }
    if v > 511 || s.len() > 4 { return err("a mode is at most 777") }
    return v
}
fn kernel_read_byte() -> int { return st_k_read_byte() }
fn rv_image_none() -> rv.Image { return rv.Image {} }

fn pad(n: int, w: int) -> str {
    let s = "${n}"
    return " ".repeat(max(0, w - s.len())) + s
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
    println("tools     echo <text>  calc <expr>  peek <address>  date  beep [hz] [ms]  sound  panic")
    println("network   ifconfig [set <ip>/<bits> [gw] | dhcp]  ping [-c n] <host>  host <name>  arp  firewall [ping on|off|log]")
    println("          fetch [-i] <url> [-o file]  browse [url]  netstat  dns [server]")
    println("programs  code [file]  run <file>  cc <file.st> [-o prog]  ps  kill <pid>")
    println("users     whoami  users  adduser <name> [--admin]  passwd  sudo <command>  logout")
    println("          ls -l  chmod <mode> <path>  chown <user> <path>")
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
    sh.fs.who = "root"
    sh.fs.mkdir("/home")?
    sh.fs.mkdir("/etc")?
    sh.fs.write("/etc/motd", "Welcome to StellaOS. Your files are kept on the disk (when there is one: `df`).\n")?
    sh.fs.write("/etc/passwd", "root:0:/root:admin\n")?
    sh.fs.write("/etc/shadow", "")?
    sh.fs.chmod("/etc/shadow", 384)?
    sh.fs.mkdir("/root")?
    sh.fs.chmod("/root", 448)?
    examples(sh)?
}

// the example programs (userland/*.st), in /home/examples
fn examples(sh: Shell) -> void! {
    let was = sh.fs.who
    sh.fs.who = "root"
    if !sh.fs.is_dir("/etc") { sh.fs.mkdir("/etc")? }
    if !sh.fs.is_file("/etc/passwd") { sh.fs.write("/etc/passwd", "root:0:/root:admin\n")? }
    if !sh.fs.is_file("/etc/shadow") {
        sh.fs.write("/etc/shadow", "")?
        sh.fs.chmod("/etc/shadow", 384)?
    }
    if !sh.fs.is_dir("/home") { sh.fs.mkdir("/home")? }
    if !sh.fs.is_dir("/home/examples") { sh.fs.mkdir("/home/examples")? }
    for p in userland.programs() {
        let path = "/home/examples/" + p[0]
        if !sh.fs.is_file(path) { sh.fs.write(path, p[1])? }
    }
    sh.fs.who = was
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
    examples(sh) catch e { println("examples: ${e}") }
    sh.saved = if loaded { sh.fs.changes } else { -1 }
    sh.sync()
    // save a moment after changes
    kernel.every(2000, () => sh.sync())
    sh.fs.who = "nobody"
    sh.cwd = "/"
    sh.snd = sound.open()
    let r = rng.open()
    sh.random = some(r)
    sh.accounts = some(users.Users { fs: sh.fs, random: () => r.u32() })
    sh.net = inet.open(r)
    if let n = sh.net {
        let t = tcp.start(n)
        sh.tcp = some(t)
        sh.web = some(www.Client { stack: t, trust: tls.Trust { extra: () => sh.extra_roots() } })
    }
    banner()
    print(sh.fs.read("/etc/motd") catch "")
    // a display: the desktop comes up by itself, with a terminal on it
    sh.start_desktop() catch e { println("${kernel.ESC}[2m(no display: just this shell. `stellang boot --gui` for the desktop)${kernel.ESC}[0m") }
    if let d = sh.gui {
        d.on_logout = () => sh.end_session(true)
        sh.show_login(d, "")
        println("${kernel.ESC}[2mthe desktop is up on the display (log in there or here)${kernel.ESC}[0m")
    }
    while sh.running {
        if sh.user == "" {
            sh.console_login()
            continue
        }
        let line = sh.ed.read(sh.prompt())
        if sh.user == "" { continue }
        sh.run(line) catch e { println("${kernel.ESC}[31merror:${kernel.ESC}[0m ${e}") }
    }
}
