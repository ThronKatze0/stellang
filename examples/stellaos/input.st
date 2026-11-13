// Keyboard and mouse: a driver for virtio-input devices (QEMU's virtio-keyboard-device and
// virtio-tablet-device), written in stellang.
//
// Each device sends Linux-style input events (type, code, value: 8 bytes) into buffers we lend it
// on its event queue. We turn them into `Event`s: keys with names like the browser's (`"a"`, `"A"`,
// `"Enter"`, `"ArrowUp"`), the pointer's position on the screen, buttons and the wheel.

import kernel
import virtio

// Linux event types and codes
const EV_SYN = 0
const EV_KEY = 1
const EV_REL = 2
const EV_ABS = 3
const BTN_LEFT = 0x110
const REL_WHEEL = 8

struct Event {
    kind: str,                // "key", "move", "button", "wheel"
    key: str = "",            // key: its name ("a", "A", "Enter", "ArrowLeft", "Shift", "F5", ...)
    text: str = "",           // key: the character it types, if any
    down: bool = false,       // key/button: pressed (true, also when held and repeating) or released
    repeat: bool = false,
    x: int = 0,               // move: where the pointer is, in screen pixels
    y: int = 0,
    button: int = 0,          // button: 0 left, 1 right, 2 middle
    delta: int = 0,           // wheel: +1 / -1 notches (+ is towards the user: scroll down)
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
}

struct Input {
    devices: [virtio.Device] = [],
    queues: [virtio.Queue] = [],
    max_x: [int] = [],        // each device's pointer range (tablets: absolute positions)
    max_y: [int] = [],
    screen_w: int = 1024,
    screen_h: int = 768,
    x: int = 0,
    y: int = 0,
    moved: bool = false,
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    altgr: bool = false,
    caps: bool = false,
    layout: str = "us",       // "us" or "de"
    pending: [Event] = [],

    // Everything that happened since the last call.
    fn poll(self) -> [Event] {
        for i, q in self.queues {
            while true {
                let used = q.take()
                if let u = used {
                    let a = q.addr_of(u.head)
                    let ty = kernel.peek16(a)
                    let code = kernel.peek16(a + 2)
                    var value = kernel.peek32(a + 4)
                    if value >= 1 << 31 { value -= 1 << 32 }     // signed
                    self.event(i, ty, code, value)
                    q.offer([virtio.Buf { addr: a, len: 8, writable: true }])   // lend it again
                } else {
                    break
                }
            }
            q.notify()
        }
        if self.moved {
            self.pending.push(Event { kind: "move", x: self.x, y: self.y })
            self.moved = false
        }
        let out = self.pending
        self.pending = []
        return out
    }

    fn event(self, dev: int, ty: int, code: int, value: int) {
        if ty == EV_ABS {
            if code == 0 { self.x = value * (self.screen_w - 1) / max(self.max_x[dev], 1) }
            if code == 1 { self.y = value * (self.screen_h - 1) / max(self.max_y[dev], 1) }
            self.moved = true
        } else if ty == EV_REL {
            if code == 0 { self.x = min(max(self.x + value, 0), self.screen_w - 1) }
            if code == 1 { self.y = min(max(self.y + value, 0), self.screen_h - 1) }
            if code == 0 || code == 1 { self.moved = true }
            if code == REL_WHEEL { self.pending.push(Event { kind: "wheel", delta: -value, x: self.x, y: self.y }) }
        } else if ty == EV_KEY {
            if code >= BTN_LEFT && code < BTN_LEFT + 3 {
                if self.moved {
                    self.pending.push(Event { kind: "move", x: self.x, y: self.y })
                    self.moved = false
                }
                let b = [0, 1, 2][code - BTN_LEFT]
                self.pending.push(Event { kind: "button", button: b, down: value != 0, x: self.x, y: self.y,
                    ctrl: self.ctrl, shift: self.shift, alt: self.alt })
            } else {
                self.key(code, value)
            }
        }
    }

    fn key(self, code: int, value: int) {
        let down = value != 0
        if code == 42 || code == 54 { self.shift = down }
        if code == 29 || code == 97 { self.ctrl = down }
        if code == 56 { self.alt = down }
        if code == 100 { self.altgr = down }
        if code == 58 && value == 1 { self.caps = !self.caps }
        let name = key_name(code)
        var text = ""
        if !self.ctrl && !self.alt {
            text = typed(self.layout, code, self.shift, self.altgr, self.caps)
        }
        let key = if text != "" { text } else if name != "" { name } else { "Key${code}" }
        // Ctrl+letter: name the letter
        let k = if self.ctrl && key.len() > 1 { letter(self.layout, code) ?? key } else { key }
        self.pending.push(Event { kind: "key", key: k, text, down, repeat: value == 2,
            ctrl: self.ctrl, shift: self.shift, alt: self.alt })
    }
}

// Find the keyboards and pointers and start them. The pointer's coordinates are scaled to a
// screen of `w` x `h` pixels.
fn open(w: int, h: int) -> Input {
    let inp = Input { screen_w: w, screen_h: h, x: w / 2, y: h / 2 }
    for d in virtio.find(virtio.INPUT) {
        if !d.start(0) { continue }
        let q = d.queue(0, 64) catch e {
            println("input: ${e}")
            continue
        }
        // lend the device buffers for its events, 8 bytes each
        let mem = kernel.alloc_pages(1)
        for i in 0..q.size {
            q.offer([virtio.Buf { addr: mem + 8 * i, len: 8, writable: true }])
        }
        inp.max_x.push(abs_max(d, 0))
        inp.max_y.push(abs_max(d, 1))
        d.go()
        q.notify()
        inp.devices.push(d)
        inp.queues.push(q)
    }
    return inp
}

// the largest value of an absolute axis (0 = x, 1 = y), from the device's configuration
fn abs_max(d: virtio.Device, axis: int) -> int {
    d.set_config8(0, 0x12)          // select: ABS_INFO
    d.set_config8(1, axis)
    if d.config8(2) == 0 { return 32767 }
    return d.config32(8 + 4)        // struct { min, max, fuzz, flat, res }
}

fn key_name(code: int) -> str {
    return match code {
        1 => "Escape",
        14 => "Backspace",
        15 => "Tab",
        28 => "Enter",
        96 => "Enter",
        29 => "Control",
        97 => "Control",
        42 => "Shift",
        54 => "Shift",
        56 => "Alt",
        100 => "AltGraph",
        57 => " ",
        58 => "CapsLock",
        102 => "Home",
        103 => "ArrowUp",
        104 => "PageUp",
        105 => "ArrowLeft",
        106 => "ArrowRight",
        107 => "End",
        108 => "ArrowDown",
        109 => "PageDown",
        110 => "Insert",
        111 => "Delete",
        125 => "Meta",
        _ => {
            if code >= 59 && code <= 68 { return "F${code - 58}" }
            if code == 87 { return "F11" }
            if code == 88 { return "F12" }
            return ""
        },
    }
}

// The keys of the main block, by Linux key code, from 2 ("1") to 53 ("/"): unshifted and shifted
// (· for keys that type nothing: Backspace, Tab, Enter, Ctrl, Shift).
const US_LOWER = "1234567890-=··qwertyuiop[]··asdfghjkl;'`·\\zxcvbnm,./"
const US_UPPER = "!@#$%^&*()_+··QWERTYUIOP{}··ASDFGHJKL:\"~·|ZXCVBNM<>?"
const DE_LOWER = "1234567890ß´··qwertzuiopü+··asdfghjklöä^·#yxcvbnm,.-"
const DE_UPPER = "!\"§$%&/()=?`··QWERTZUIOPÜ*··ASDFGHJKLÖÄ°·'YXCVBNM;:_"

// What a key types (or "" if it types nothing).
fn typed(layout: str, code: int, shift: bool, altgr: bool, caps: bool) -> str {
    if code == 57 { return " " }
    if layout == "de" {
        if altgr {
            return match code {
                16 => "@",
                18 => "€",
                8 => "{",
                9 => "[",
                10 => "]",
                11 => "}",
                12 => "\\",
                27 => "~",
                86 => "|",
                50 => "µ",
                3 => "²",
                4 => "³",
                _ => "",
            }
        }
        if code == 86 { return if shift { ">" } else { "<" } }
    }
    if code < 2 || code > 53 { return "" }
    let lower = if layout == "de" { DE_LOWER } else { US_LOWER }
    let upper = if layout == "de" { DE_UPPER } else { US_UPPER }
    let lc = lower.chars()[code - 2]
    var up = shift
    // Caps Lock: letters only
    if caps && lc.upper() != lc { up = !up }
    let c = if up { upper.chars()[code - 2] } else { lc }
    if c == "·" { return "" }
    return c
}

// The letter on a key (for Ctrl+letter), if it's a letter.
fn letter(layout: str, code: int) -> str? {
    let c = typed(layout, code, false, false, false)
    if c != "" && c.upper() != c { return some(c) }
    return none
}
