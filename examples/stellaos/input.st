// Keyboard and mouse, written in stellang: virtio-input devices on QEMU's RISC-V machine (virtio-
// keyboard-device, virtio-tablet-device); on a PC, the PS/2 controller (a laptop's built-in keyboard,
// sometimes its touchpad) and USB keyboards and mice (xhci.st).
//
// Everything is turned into Linux-style key codes and pointer moves first (virtio-input sends those
// as they are: type, code, value, 8 bytes each; PS/2's scan code set 1 is almost the same numbers;
// USB HID usages go through a table), then into `Event`s: keys with names like the browser's
// (`"a"`, `"A"`, `"Enter"`, `"ArrowUp"`), the pointer's position on the screen, buttons and the wheel.

import kernel
import virtio
import xhci
import touchpad

extern fn st_k_ps2_read() -> int
extern fn st_k_ps2_mouse() -> int

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
    // PC: the PS/2 controller and USB
    ps2: bool = false,
    ps2_e0: bool = false,     // the next scan code is an extended one (E0 xx)
    ps2_skip: int = 0,        // bytes left of a Pause key's sequence
    ps2_size: int = 3,        // mouse packets: 3 bytes, 4 with a wheel
    ps2_pkt: [int] = [],
    held: [bool] = [],        // keys down by code (to tell a repeat from a press)
    buttons_down: int = 0,    // mouse buttons down (bit 0 left, 1 right, 2 middle)
    usb: xhci.Usb? = none,
    touch: touchpad.Touch? = none,

    // Everything that happened since the last call.
    fn poll(self) -> [Event] {
        if self.ps2 { self.poll_ps2() }
        if let c = self.usb {
            for r in c.poll() { self.usb_report(r) }
        }
        if let t = self.touch {
            for m in t.poll() { self.usb_report(xhci.Report { kind: "mouse", data: m.map(v => v & 0xff), last: [] }) }
        }
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

    // ---- the pointer, for drivers that see relative moves (PS/2, USB mice) ----

    fn rel(self, dx: int, dy: int) {
        if dx == 0 && dy == 0 { return }
        self.x = min(max(self.x + dx, 0), self.screen_w - 1)
        self.y = min(max(self.y + dy, 0), self.screen_h - 1)
        self.moved = true
    }

    // the buttons down now (bit 0 left, 1 right, 2 middle): presses and releases for what changed
    fn set_buttons(self, mask: int) {
        for b in 0..3 {
            let was = self.buttons_down >> b & 1
            let now = mask >> b & 1
            if was != now { self.event(0, EV_KEY, BTN_LEFT + b, now) }
        }
        self.buttons_down = mask & 7
    }

    // a key by Linux code, down or up; a press of a key already down is a repeat
    fn key_press(self, code: int, down: bool) {
        if self.held.is_empty() {
            for i in 0..256 { self.held.push(false) }
        }
        if code <= 0 || code >= 256 { return }
        let value = if !down { 0 } else if self.held[code] { 2 } else { 1 }
        self.held[code] = down
        self.key(code, value)
    }

    // ---- PS/2 ----

    fn poll_ps2(self) {
        while true {
            let v = st_k_ps2_read()
            if v < 0 { break }
            if v >= 0x100 { self.ps2_mouse_byte(v & 0xff) } else { self.ps2_key_byte(v) }
        }
    }

    // scan code set 1: a key's code on press, with 0x80 on release; E0 before the extended keys
    fn ps2_key_byte(self, b: int) {
        if self.ps2_skip > 0 {
            self.ps2_skip -= 1
            return
        }
        if b == 0xe1 {             // Pause: E1 1D 45 E1 9D C5, and no release
            self.ps2_skip = 5
            return
        }
        if b == 0xe0 {
            self.ps2_e0 = true
            return
        }
        if b == 0xfa || b == 0xfe || b == 0xee || b == 0 || b == 0xff { return }   // answers, errors
        let e0 = self.ps2_e0
        self.ps2_e0 = false
        let down = b < 0x80
        let sc = b & 0x7f
        if !e0 {
            self.key_press(sc, down)    // set 1's numbers are Linux's key codes (1 Escape .. 88 F12)
            return
        }
        let code = match sc {
            0x1c => 96,    // keypad Enter
            0x1d => 97,    // right Ctrl
            0x35 => 98,    // keypad /
            0x38 => 100,   // AltGr
            0x47 => 102,   // Home
            0x48 => 103,   // Up
            0x49 => 104,   // Page Up
            0x4b => 105,   // Left
            0x4d => 106,   // Right
            0x4f => 107,   // End
            0x50 => 108,   // Down
            0x51 => 109,   // Page Down
            0x52 => 110,   // Insert
            0x53 => 111,   // Delete
            0x5b => 125,   // Windows keys
            0x5c => 125,
            _ => 0,        // E0 2A (the fake Shift of Print Screen) and others: nothing
        }
        if code != 0 { self.key_press(code, down) }
    }

    // mouse packets: buttons and signs, x, y (up is +), the wheel
    fn ps2_mouse_byte(self, b: int) {
        if self.ps2_pkt.is_empty() && b & 8 == 0 { return }   // not the first byte of a packet: resync
        self.ps2_pkt.push(b)
        if self.ps2_pkt.len() < self.ps2_size { return }
        let p = self.ps2_pkt
        self.ps2_pkt = []
        if p[0] & 0xc0 == 0 {      // no overflow
            let dx = p[1] - ((p[0] << 4) & 0x100)
            let dy = p[2] - ((p[0] << 3) & 0x100)
            self.rel(dx, -dy)
        }
        self.set_buttons((p[0] & 1) | (p[0] >> 1 & 1) << 1 | (p[0] >> 2 & 1) << 2)
        if self.ps2_size == 4 {
            let z = signed8(p[3])   // + is towards the user
            if z != 0 { self.pending.push(Event { kind: "wheel", delta: z, x: self.x, y: self.y }) }
        }
    }

    // ---- USB (boot protocol reports from xhci.st) ----

    fn usb_report(self, r: xhci.Report) {
        let d = r.data
        if r.kind == "mouse" && d.len() >= 3 {
            self.rel(signed8(d[1]), signed8(d[2]))
            self.set_buttons(d[0])
            if d.len() >= 4 && d[3] != 0 { self.pending.push(Event { kind: "wheel", delta: -signed8(d[3]), x: self.x, y: self.y }) }
        } else if r.kind == "keyboard" && d.len() >= 8 {
            // modifiers (bit 0 left Ctrl .. 7 right GUI), then up to 6 keys held
            let mods = [29, 42, 56, 125, 97, 54, 100, 125]
            for i in 0..8 {
                let now = d[0] >> i & 1 == 1
                let was = r.last.len() >= 8 && r.last[0] >> i & 1 == 1
                if now != was { self.key_press(mods[i], now) }
            }
            if d[2] == 1 { return }   // too many keys at once: nothing to go by
            // released: in the last report, not in this one; pressed: the other way round
            if r.last.len() >= 8 {
                for k in 2..8 {
                    let u = r.last[k]
                    if u > 3 && !d.slice(2, 8).contains(u) { self.key_press(hid_key(u), false) }
                }
            }
            for k in 2..8 {
                let u = d[k]
                if u > 3 && (r.last.len() < 8 || !r.last.slice(2, 8).contains(u)) { self.key_press(hid_key(u), true) }
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
    if kernel.arch() == "x86_64" {
        inp.ps2 = true
        let m = st_k_ps2_mouse()
        if m > 0 { inp.ps2_size = m }
        inp.usb = some(xhci.open())
        inp.touch = some(touchpad.open())
        return inp
    }
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

fn signed8(b: int) -> int {
    return if b >= 128 { b - 256 } else { b }
}

// USB HID keyboard usages (page 7) as Linux key codes: 4 "a" .. 0x65 Menu; 0 for the others
const HID_KEYS = [0, 0, 0, 0, 30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25, 16, 19, 31, 20,
    22, 47, 17, 45, 21, 44, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 28, 1, 14, 15, 57, 12, 13, 26, 27, 43, 43, 39,
    40, 41, 51, 52, 53, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 87, 88, 99, 70, 119, 110, 102, 104,
    111, 107, 109, 106, 105, 108, 103, 69, 98, 55, 74, 78, 96, 79, 80, 81, 75, 76, 77, 71, 72, 73, 82, 83,
    86, 127]

fn hid_key(usage: int) -> int {
    return if usage < HID_KEYS.len() { HID_KEYS[usage] } else { 0 }
}
