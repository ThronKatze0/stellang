// kernel: programs that ARE the operating system. Build with `stellang --kernel os.st` (makes os.elf,
// a RISC-V 64 kernel), run with `stellang boot os.st` (builds, then boots it in QEMU).
//
//     import kernel
//
//     fn main() {
//         println("hello from bare metal")
//         let ed = kernel.LineEditor {}
//         while true {
//             let line = ed.read("> ")
//             if line == "exit" { kernel.shutdown(0) }
//             println("you typed ${line}")
//         }
//     }
//
// print/println go to the serial console. The heap is garbage-collected like everywhere else.
// Timers (`after`, `every`) run from the main loop: whenever the program waits (`key`,
// `prompt`, the builtin `sleep`, `idle`). Interrupts are handled in the C runtime (src/runtime_kernel.c) and
// never run stellang code, so a driver written here polls `irq_count` from the loop instead.
// Returning from main powers the machine off (QEMU exits with main's code; a panic exits with 101).

extern fn st_k_wait_byte() -> int
extern fn st_k_read_byte() -> int
extern fn st_k_idle()
extern fn st_k_timer(f: fn(), ms: int, repeat: int) -> int
extern fn st_k_cancel(id: int)
extern fn st_k_timers() -> int
extern fn st_k_ticks() -> int
extern fn st_k_shutdown(code: int)
extern fn st_k_reboot()
extern fn st_k_peek(addr: int, size: int) -> int
extern fn st_k_poke(addr: int, size: int, value: int)
extern fn st_k_irq_enable(irq: int)
extern fn st_k_irq_count(irq: int) -> int
extern fn st_k_irqs(cause: int) -> int
extern fn st_k_heap_live() -> int
extern fn st_k_heap_mapped() -> int
extern fn st_k_heap_free() -> int
extern fn st_k_ram_size() -> int
extern fn st_k_kernel_size() -> int
extern fn st_k_gc_runs() -> int
extern fn st_k_gc()
extern fn st_k_alloc_pages(n: int) -> int
extern fn st_k_alloc(bytes: int) -> int
extern fn st_k_pages_out() -> int
extern fn st_k_copy(dst: int, src: int, n: int)
extern fn st_k_fill32(dst: int, count: int, value: int)
extern fn st_k_write_str(dst: int, s: str)
extern fn st_k_read_str(src: int, n: int) -> str
extern fn st_chr(code: int) -> str

// ---- time ----

// Milliseconds since boot (the builtin `now_ms()` is the same clock, and `sleep(ms)` waits on it
// while timers keep running).
fn uptime() -> int {
    return now_ms()
}

// Run `f` once, `ms` from now. Returns an id for `cancel`.
fn after(ms: int, f: fn()) -> int {
    return st_k_timer(f, ms, 0)
}

// Run `f` every `ms` milliseconds. Returns an id for `cancel`.
fn every(ms: int, f: fn()) -> int {
    return st_k_timer(f, ms, 1)
}

fn cancel(id: int) {
    st_k_cancel(id)
}

// How many timers are waiting.
fn timers() -> int {
    return st_k_timers()
}

// One turn of the event loop: run the timers that are due, or sleep until the next interrupt.
fn idle() {
    st_k_idle()
}

// The event loop, forever (for kernels that only react to timers).
fn run() {
    while true { st_k_idle() }
}

// ---- the console ----

// The escape character, for terminal control sequences ("${kernel.ESC}[2J" clears the screen).
const ESC = st_chr(27)

fn clear_screen() {
    print("${ESC}[2J${ESC}[H")
}

// The next key pressed: a character ("a", "ß", " "), or one of "Enter", "Backspace", "Tab",
// "Escape", "Delete", "Up", "Down", "Left", "Right", "Home", "End", "Ctrl-A".."Ctrl-Z".
fn key() -> str {
    let b = st_k_wait_byte()
    if b == 13 || b == 10 { return "Enter" }
    if b == 127 || b == 8 { return "Backspace" }
    if b == 9 { return "Tab" }
    if b == 27 { return escape() }
    if b < 32 { return "Ctrl-${st_chr(b + 64)}" }
    if b < 128 { return st_chr(b) }
    // UTF-8: the lead byte says how many continuation bytes follow
    var more = 0
    var code = 0
    if b >> 5 == 6 {
        more = 1
        code = b & 31
    } else if b >> 4 == 14 {
        more = 2
        code = b & 15
    } else {
        more = 3
        code = b & 7
    }
    for i in 0..more {
        code = (code << 6) | (st_k_wait_byte() & 63)
    }
    return st_chr(code)
}

// after ESC: an arrow key or friends (`ESC [ A`), or just Escape if nothing follows quickly
fn escape() -> str {
    let until = now_ms() + 30
    var b = st_k_read_byte()
    while b < 0 && now_ms() < until {
        st_k_idle()
        b = st_k_read_byte()
    }
    if b != 91 && b != 79 { return "Escape" }   // `[` or `O`
    let c = st_k_wait_byte()
    if c == 65 { return "Up" }
    if c == 66 { return "Down" }
    if c == 67 { return "Right" }
    if c == 68 { return "Left" }
    if c == 72 { return "Home" }
    if c == 70 { return "End" }
    if c >= 48 && c <= 57 {
        // ESC [ 3 ~ and the like
        var n = c - 48
        var d = st_k_wait_byte()
        while d >= 48 && d <= 57 {
            n = n * 10 + d - 48
            d = st_k_wait_byte()
        }
        if n == 3 { return "Delete" }
        if n == 1 || n == 7 { return "Home" }
        if n == 4 || n == 8 { return "End" }
    }
    return "Escape"
}

// A line typed at the console, with editing (arrows, Backspace, Delete, Home/End, Ctrl-U to
// clear) and history (Up/Down). Ctrl-C gives back "" and Ctrl-D "exit" on an empty line.
struct LineEditor {
    history: [str] = [],

    fn read(self, prompt: str) -> str {
        print(prompt)
        var line: [str] = []
        var at = 0
        var back = self.history.len()
        while true {
            let k = key()
            if k == "Enter" {
                println("")
                let text = line.join("")
                if text.trim() != "" && self.history.last() != some(text) {
                    self.history.push(text)
                }
                return text
            }
            if k == "Ctrl-C" {
                println("^C")
                return ""
            }
            if k == "Ctrl-D" && line.is_empty() {
                println("")
                return "exit"
            }
            var changed = false
            if k == "Backspace" && at > 0 {
                at -= 1
                line.remove(at)
                changed = true
            } else if k == "Delete" && at < line.len() {
                line.remove(at)
                changed = true
            } else if k == "Left" && at > 0 {
                at -= 1
                changed = true
            } else if k == "Right" && at < line.len() {
                at += 1
                changed = true
            } else if k == "Home" || k == "Ctrl-A" {
                at = 0
                changed = true
            } else if k == "End" || k == "Ctrl-E" {
                at = line.len()
                changed = true
            } else if k == "Ctrl-U" {
                line = []
                at = 0
                changed = true
            } else if (k == "Up" && back > 0) || (k == "Down" && back < self.history.len()) {
                back += if k == "Up" { -1 } else { 1 }
                line = if back < self.history.len() { self.history[back].chars() } else { [] }
                at = line.len()
                changed = true
            } else if k.len() == 1 || (k.chars().len() == 1 && k.len() <= 4) {
                if k.chars().len() == 1 && k != "Tab" {
                    line.insert(at, k)
                    at += 1
                    if at == line.len() {
                        print(k)   // typing at the end: just echo it (no redraw over a slow serial line)
                    } else {
                        changed = true
                    }
                }
            }
            if changed {
                // redraw: back to the start of the line, the prompt and text, clear the rest, place the cursor
                print("\r${prompt}${line.join("")}${ESC}[K")
                let left = line.len() - at
                if left > 0 { print("${ESC}[${left}D") }
            }
        }
        return ""
    }
}

// A line from the console, without history.
fn prompt(text: str) -> str {
    return LineEditor {}.read(text)
}

// ---- the machine ----

// Power off. QEMU exits with `code`.
fn shutdown(code: int) {
    st_k_shutdown(code)
}

fn reboot() {
    st_k_reboot()
}

struct Memory {
    ram: int,          // bytes of RAM
    kernel: int,       // the kernel image, its stack and globals
    heap: int,         // bytes the heap has taken from RAM so far
    live: int,         // bytes in use after the last garbage collection
    pages: int,        // bytes of device pages (alloc_pages)
    free: int,         // RAM nothing has touched yet
    collections: int,  // garbage collections so far
}

fn memory() -> Memory {
    return Memory {
        ram: st_k_ram_size(),
        kernel: st_k_kernel_size(),
        heap: st_k_heap_mapped(),
        live: st_k_heap_live(),
        pages: st_k_pages_out(),
        free: st_k_heap_free(),
        collections: st_k_gc_runs(),
    }
}

// Collect garbage now (memory().live is then up to date).
fn gc() {
    st_k_gc()
}

// Timer interrupts so far (1000 a second).
fn ticks() -> int {
    return st_k_ticks()
}

// ---- devices: memory-mapped registers, for drivers written in stellang ----

fn peek8(addr: int) -> int { return st_k_peek(addr, 1) }
fn peek16(addr: int) -> int { return st_k_peek(addr, 2) }
fn peek32(addr: int) -> int { return st_k_peek(addr, 4) }
fn peek64(addr: int) -> int { return st_k_peek(addr, 8) }
fn poke8(addr: int, v: int) { st_k_poke(addr, 1, v) }
fn poke16(addr: int, v: int) { st_k_poke(addr, 2, v) }
fn poke32(addr: int, v: int) { st_k_poke(addr, 4, v) }
fn poke64(addr: int, v: int) { st_k_poke(addr, 8, v) }

// Memory outside the garbage collector, for buffers a device reads or writes itself (virtio
// queues, DMA, a framebuffer): `n` zeroed 4 KiB pages at a fixed physical address, never freed.
fn alloc_pages(n: int) -> int { return st_k_alloc_pages(n) }

// Memory from the garbage-collected heap (zeroed), for buffers of bytes: freed once no int holds
// its address any more (the collector also treats ints that look like addresses as references).
fn alloc(bytes: int) -> int { return st_k_alloc(bytes) }

// Bulk memory: copy bytes, fill with a 32-bit value (pixels), and strings to and from memory.
fn copy(dst: int, src: int, n: int) { st_k_copy(dst, src, n) }
fn fill32(dst: int, count: int, value: int) { st_k_fill32(dst, count, value) }
fn write_str(dst: int, s: str) { st_k_write_str(dst, s) }
fn read_str(src: int, n: int) -> str { return st_k_read_str(src, n) }

// Device interrupts (PLIC sources: on QEMU virt, virtio devices are 1..8, the UART 10).
// The handler counts and acknowledges them; a driver notices the count go up from its loop.
fn irq_enable(irq: int) {
    st_k_irq_enable(irq)
}

fn irq_count(irq: int) -> int {
    return st_k_irq_count(irq)
}

// ---- the real time ----

// Milliseconds since 1970-01-01, from the machine's real-time clock (QEMU's: UTC, or local time when
// booted with `-rtc base=localtime`, as `stellang boot` does).
fn time_ms() -> int {
    let lo = st_k_peek(0x10_1000, 4)       // reading the low half latches the high half
    let hi = st_k_peek(0x10_1004, 4)
    return ((hi << 32) | lo) / 1_000_000
}

struct Date {
    year: int,
    month: int,       // 1..12
    day: int,         // 1..31
    hour: int,
    minute: int,
    second: int,
    weekday: int,     // 0 = Monday .. 6 = Sunday
}

// The calendar date and time of `ms` since 1970.
fn date(ms: int) -> Date {
    let secs = ms / 1000
    let days = secs / 86400
    let rem = secs % 86400
    // days -> civil date (Howard Hinnant's algorithm)
    let z = days + 719468
    let era = z / 146097
    let doe = z - era * 146097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = if mp < 10 { mp + 3 } else { mp - 9 }
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 }
    return Date { year: y, month: m, day: d, hour: rem / 3600, minute: rem % 3600 / 60, second: rem % 60, weekday: (days + 3) % 7 }
}

const WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

fn two(n: int) -> str {
    return if n < 10 { "0${n}" } else { "${n}" }
}
