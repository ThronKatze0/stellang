// proc: processes. Programs compiled inside StellaOS (cc.st) run as RISC-V machine code in user
// mode, each with its own page table, so a program can only ever touch its own memory: the kernel,
// the devices and other programs are simply not in its address space. A timer interrupt takes the
// CPU back every millisecond, so an endless loop can't freeze the desktop, and a crash (a bad
// pointer, a stack overflow, an illegal instruction) ends that program and nothing else.
//
// Everything a program wants from the outside goes through a system call (ecall), and the kernel
// checks every address and length it is handed against the program's own memory first.
//
// Memory of a process (virtual addresses from BASE, 8 MiB):
//     code + read-only data (read, execute) | globals (read, write) | heap ... | guard | stack
// The guard page is not mapped: a stack that grows into it faults instead of eating the heap.

import kernel
import gfx

const BASE = 0x20_0000_0000      // where processes live (the kernel's own memory is not mapped for them)
const MEM = 8 << 20
const STACK = 1 << 20
const PAGES = MEM / 4096

// page table entry bits
const V = 1
const R = 2
const W = 4
const X = 8
const U = 16
const AD = 0xc0                  // accessed + dirty, set up front

// system calls (a7 = number, a0.. = arguments, a0 = result)
const SYS_EXIT = 0
const SYS_WRITE = 1
const SYS_READ_LINE = 2
const SYS_NOW = 3
const SYS_SLEEP = 4
const SYS_RANDOM = 5
const SYS_WINDOW = 6
const SYS_FILL = 7
const SYS_CIRCLE = 8
const SYS_LINE = 9
const SYS_TEXT = 10
const SYS_SHOW = 11
const SYS_KEY = 12
const SYS_MOUSE = 13
const SYS_BEEP = 14
const SYS_FILE_SIZE = 15
const SYS_READ_FILE = 16
const SYS_WRITE_FILE = 17
const SYS_PID = 18
const SYS_USER = 19
const SYS_TEXT_WIDTH = 20

extern fn st_k_user_run(frame: int, ms: int) -> int
extern fn st_k_read_text(src: int, n: int) -> str

// memory for one process, kept and reused once it ends
struct Slot {
    mem: int,                // physical address of the 8 MiB
    root: int,               // the page tables
    l1: int,
    l0: int,                 // PAGES / 512 tables, one after the other
    frame: int,              // the saved registers
    busy: bool = false,
}

// what the rest of the system does for processes (the desktop, the terminal, the files)
struct Sys {
    write: fn(Proc, str) = (p: Proc, s: str) => print(s),
    window: fn(Proc) = (p: Proc) => {},          // the program opened its window: show p.canvas
    show: fn(Proc) = (p: Proc) => {},            // a new frame is ready in p.canvas
    beep: fn(int, int) = (hz: int, ms: int) => {},
    read: fn(Proc, str) -> str? = (p: Proc, path: str) => none,
    save: fn(Proc, str, str) -> str = (p: Proc, path: str, text: str) => "no files",
    exited: fn(Proc) = (p: Proc) => {},
    random: fn() -> int = () => kernel.uptime(),
}

struct Proc {
    pid: int,
    name: str,
    user: str,
    slot: Slot,
    sys: Sys,
    state: str = "ready",        // ready, sleeping, input, done
    wake: int = 0,
    code: int = 0,               // exit code
    why: str = "",               // how it ended, when it didn't exit by itself
    heap: int = 0,               // the first heap address (for `ps`)
    started: int = 0,
    cpu: int = 0,                // milliseconds on the CPU
    syscalls: int = 0,
    input_buf: int = 0,          // where read_line should put the line
    input_max: int = 0,
    canvas: gfx.Surface? = none,
    title: str = "",
    keys: [str] = [],
    mx: int = 0,
    my: int = 0,
    buttons: int = 0,
    file: str = "",              // the last file read, between file_size and read_file

    fn reg(self, n: int) -> int { return kernel.peek64(self.slot.frame + 8 * n) }
    fn set_reg(self, n: int, v: int) { kernel.poke64(self.slot.frame + 8 * n, v) }
    fn pc(self) -> int { return kernel.peek64(self.slot.frame) }
    fn arg(self, i: int) -> int { return self.reg(10 + i) }
    fn done(self) -> bool { return self.state == "done" }

    // The physical address of `n` bytes the program pointed at, or -1 if any of them is not its own.
    fn mem(self, va: int, n: int) -> int {
        if n < 0 || n > MEM || va < BASE || va + n > BASE + MEM { return -1 }
        return self.slot.mem + (va - BASE)
    }

    // the program's (pointer, length) as text
    fn text(self, va: int, n: int) -> str? {
        let p = self.mem(va, n)
        if p < 0 { return none }
        return some(st_k_read_text(p, n))
    }

    // copy text into the program's buffer (at most max bytes); the bytes copied, or -1
    fn put(self, va: int, max: int, s: str) -> int {
        let n = min(s.len(), max)
        let p = self.mem(va, n)
        if p < 0 { return -1 }
        kernel.write_str(p, s.slice(0, n))
        return n
    }

    // a line for a program waiting in read_line
    fn give_line(self, line: str) {
        if self.state != "input" { return }
        self.set_reg(10, self.put(self.input_buf, self.input_max, line))
        self.state = "ready"
    }

    fn kill(self, why: str) {
        if self.done() { return }
        self.why = why
        self.code = -1
        self.finish()
    }

    fn finish(self) {
        self.state = "done"
        self.slot.busy = false
        self.sys.exited(self)
    }
}

struct Procs {
    all: [Proc] = [],
    slots: [Slot] = [],
    next_pid: int = 1,
    timer: int = -1,

    fn running(self) -> [Proc] { return self.all.filter(p => !p.done()) }

    fn slot(self) -> Slot? {
        for s in self.slots {
            if !s.busy {
                s.busy = true
                return some(s)
            }
        }
        if self.slots.len() >= 8 { return none }
        let free = kernel.memory().free
        if free < MEM + (8 << 20) { return none }
        let s = Slot {
            mem: kernel.alloc_pages(PAGES),
            root: kernel.alloc_pages(1),
            l1: kernel.alloc_pages(1),
            l0: kernel.alloc_pages(PAGES / 512),
            frame: kernel.alloc_pages(1),
            busy: true,
        }
        self.slots.push(s)
        return some(s)
    }

    // Start a program: `image` is its code and read-only data, `data_at` where its globals start
    // (a page boundary) and `data_size` how many bytes of them.
    fn spawn(self, name: str, user: str, image: [int], data_at: int, data_size: int, sys: Sys) -> Proc! {
        let heap = (data_at + data_size + 4095) / 4096 * 4096
        if image.len() > data_at || heap > MEM - STACK - 65536 { return err("${name}: the program is too big") }
        let found = self.slot()
        if found == none { return err("no memory for another program (${self.running().len()} running)") }
        let s = found.unwrap()
        // fresh memory: nothing of the last program that used it may show through
        kernel.fill32(s.mem, MEM / 4, 0)
        kernel.fill32(s.frame, 1024, 0)
        for k, b in image { kernel.poke8(s.mem + k, b) }
        // the page tables: the kernel's memory (identity, supervisor only) so traps work, and the
        // program's pages (user)
        kernel.fill32(s.root, 1024, 0)
        kernel.fill32(s.l1, 1024, 0)
        kernel.fill32(s.l0, PAGES / 512 * 1024, 0)
        let gigs = (0x8000_0000 + kernel.memory().ram + (1 << 30) - 1) >> 30
        for g in 0..gigs { kernel.poke64(s.root + 8 * g, (g << 30) >> 12 << 10 | V | R | W | X | AD) }
        kernel.poke64(s.root + 8 * (BASE >> 30), s.l1 >> 12 << 10 | V)
        for t in 0..PAGES / 512 { kernel.poke64(s.l1 + 8 * t, (s.l0 + 4096 * t) >> 12 << 10 | V) }
        let guard = (MEM - STACK) / 4096 - 1
        let code_pages = (image.len() + 4095) / 4096
        for pg in 0..PAGES {
            if pg == guard { continue }
            let perm = if pg < code_pages { R | X } else { R | W }
            kernel.poke64(s.l0 + 8 * pg, (s.mem + 4096 * pg) >> 12 << 10 | V | U | AD | perm)
        }
        // registers: start at the image's first byte, the stack at the top, the heap in a0..a1
        kernel.poke64(s.frame, BASE)
        kernel.poke64(s.frame + 8 * 2, BASE + MEM)
        kernel.poke64(s.frame + 8 * 10, BASE + heap)
        kernel.poke64(s.frame + 8 * 11, BASE + guard * 4096)
        kernel.poke64(s.frame + 520, 8 << 60 | s.root >> 12)
        let p = Proc { pid: self.next_pid, name, user, slot: s, sys, heap: BASE + heap, started: kernel.uptime() }
        self.next_pid += 1
        self.all.push(p)
        self.all = self.all.filter(q => !q.done() || q.pid == p.pid || kernel.uptime() - q.started < 60000)
        if self.timer < 0 { self.timer = kernel.every(4, () => self.tick(3)) }
        return p
    }

    fn find(self, pid: int) -> Proc? { return self.all.find(p => p.pid == pid && !p.done()) }

    // Give the programs that can run up to `budget` ms of CPU, round robin.
    fn tick(self, budget: int) {
        let start = kernel.uptime()
        let now = start
        for p in self.all {
            if p.state == "sleeping" && now >= p.wake { p.state = "ready" }
        }
        let ready = self.all.filter(p => p.state == "ready")
        if ready.is_empty() { return }
        let share = max(1, budget / ready.len())
        for p in ready { self.run(p, share) }
    }

    fn run(self, p: Proc, ms: int) {
        let until = kernel.uptime() + ms
        while p.state == "ready" {
            let left = until - kernel.uptime()
            if left <= 0 { return }
            let t0 = kernel.uptime()
            let cause = st_k_user_run(p.slot.frame, left)
            p.cpu += kernel.uptime() - t0
            if cause < 0 { return }            // its time is up, or a device wants attention
            if cause == 8 {
                p.syscalls += 1
                p.set_reg(0, p.pc() + 4)
                self.syscall(p)
            } else {
                self.fault(p, cause)
            }
        }
    }

    fn fault(self, p: Proc, cause: int) {
        let addr = kernel.peek64(p.slot.frame + 536)
        let pc = p.pc()
        let guard = BASE + MEM - STACK - 4096
        let what = if (cause == 13 || cause == 15) && addr >= guard - 4096 * 16 && addr < guard + 4096 {
            "stack overflow (too deep recursion?)"
        } else if cause == 12 || cause == 13 || cause == 15 || cause == 1 || cause == 5 || cause == 7 {
            "segmentation fault: it touched memory that isn't its own (address ${hex(addr)})"
        } else if cause == 2 {
            "illegal instruction"
        } else if cause == 0 || cause == 4 || cause == 6 {
            "misaligned access at ${hex(addr)}"
        } else {
            "exception ${cause}"
        }
        p.kill("${what}, at pc ${hex(pc)}")
    }

    fn syscall(self, p: Proc) {
        let n = p.reg(17)
        let a = p.arg(0)
        let b = p.arg(1)
        let c = p.arg(2)
        let d = p.arg(3)
        let e = p.arg(4)
        var r = 0
        if n == SYS_EXIT {
            p.code = a
            p.finish()
            return
        } else if n == SYS_WRITE {
            if b > 0 {
                if let s = p.text(a, b) {
                    p.sys.write(p, s)
                } else {
                    p.kill("bad pointer passed to write")
                    return
                }
            }
            r = b
        } else if n == SYS_READ_LINE {
            if p.mem(a, b) < 0 {
                p.kill("bad pointer passed to read_line")
                return
            }
            p.input_buf = a
            p.input_max = b
            p.state = "input"
            return
        } else if n == SYS_NOW {
            r = kernel.uptime()
        } else if n == SYS_SLEEP {
            p.wake = kernel.uptime() + max(0, min(a, 3_600_000))
            p.state = "sleeping"
        } else if n == SYS_RANDOM {
            r = p.sys.random()
        } else if n == SYS_WINDOW {
            let w = max(16, min(a, 1000))
            let h = max(16, min(b, 700))
            if let t = p.text(c, d) { p.title = t.slice(0, min(t.len(), 60)) }
            if p.canvas == none {
                let cv = gfx.surface(w, h)
                cv.clear(0)
                p.canvas = some(cv)
                p.sys.window(p)
            }
        } else if n == SYS_FILL {
            if let cv = p.canvas { cv.rect(a, b, c, d, e & 0xffffff) }
        } else if n == SYS_CIRCLE {
            if let cv = p.canvas { cv.circle(a, b, min(c, 2000), d & 0xffffff) }
        } else if n == SYS_LINE {
            if let cv = p.canvas { cv.thick_line(a, b, c, d, 1, e & 0xffffff) }
        } else if n == SYS_TEXT {
            let face = p.arg(5)
            if let cv = p.canvas {
                if let s = p.text(c, d) {
                    r = cv.text(a, b, s, e & 0xffffff, if face == 1 { gfx.BIG } else if face == 2 { gfx.MONO } else { gfx.TEXT })
                } else {
                    p.kill("bad pointer passed to text")
                    return
                }
            }
        } else if n == SYS_TEXT_WIDTH {
            if let s = p.text(a, b) {
                r = gfx.text_width(s, if c == 1 { gfx.BIG } else if c == 2 { gfx.MONO } else { gfx.TEXT })
            }
        } else if n == SYS_SHOW {
            p.sys.show(p)
            // one frame: wait for the next 1/60 s
            p.wake = kernel.uptime() + 16
            p.state = "sleeping"
        } else if n == SYS_KEY {
            if !p.keys.is_empty() {
                let k = p.keys.remove(0)
                r = p.put(a, b, k)
            }
        } else if n == SYS_MOUSE {
            r = if a == 0 { p.mx } else if a == 1 { p.my } else { p.buttons }
        } else if n == SYS_BEEP {
            p.sys.beep(max(20, min(a, 20000)), max(1, min(b, 10000)))
        } else if n == SYS_FILE_SIZE {
            r = -1
            if let path = p.text(a, b) {
                if let t = p.sys.read(p, path) {
                    p.file = t
                    r = t.len()
                }
            }
        } else if n == SYS_READ_FILE {
            r = p.put(a, b, p.file)
            p.file = ""
        } else if n == SYS_WRITE_FILE {
            r = -1
            if let path = p.text(a, b) {
                if let t = p.text(c, d) {
                    let e2 = p.sys.save(p, path, t)
                    if e2 == "" { r = 0 } else { p.sys.write(p, "write_file ${path}: ${e2}\n") }
                }
            }
        } else if n == SYS_PID {
            r = p.pid
        } else if n == SYS_USER {
            r = p.put(a, b, p.user)
        } else {
            p.kill("unknown system call ${n}")
            return
        }
        p.set_reg(10, r)
    }
}

fn hex(n: int) -> str {
    let digits = "0123456789abcdef"
    var s = ""
    var v = n
    if v == 0 { return "0x0" }
    while v != 0 && s.len() < 16 {
        s = digits[v & 15] + s
        v = v >> 4 & 0x0fff_ffff_ffff_ffff
    }
    return "0x" + s
}
