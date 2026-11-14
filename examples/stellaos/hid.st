// hid: USB/I²C HID report descriptors, and turning a touchpad's reports into mouse movement.
//
// A HID device describes its reports in a little bytecode (the report descriptor): which values
// (usages: X, Y, buttons, "tip switch", ...) sit at which bits of which report. `parse` turns that into
// a list of fields; `Pad` then reads a touchpad's reports. Touchpads come in two modes:
//   - mouse mode: a plain mouse collection (buttons, relative X/Y, maybe a wheel); what they all do
//     after power-on, so a computer without a touchpad driver still has a pointer
//   - touchpad mode (Windows "precision touchpads"): finger positions (absolute), contact count,
//     button; we do the pointer motion, two-finger scrolling and tap-to-click ourselves
// Everything here is plain computation on bytes (tests feed it recorded descriptors).

// usage pages and usages
const DESKTOP = 0x01
const BUTTONS = 0x09
const DIGITIZER = 0x0d
const MOUSE = 0x02          // desktop
const POINTER = 0x01        // desktop
const X = 0x30
const Y = 0x31
const WHEEL = 0x38
const TOUCHPAD = 0x05       // digitizer
const FINGER = 0x22         // digitizer: a contact's logical collection
const TIP = 0x42
const CONTACT_COUNT = 0x54

struct Field {
    page: int,
    usage: int,
    report: int,              // report id (0: the device has none)
    bit: int,                 // where in the report (after the id byte)
    size: int,                // bits
    min: int,                 // logical range: negative min means the value is signed
    max: int,
    relative: bool,
    app: int,                 // the application collection: page << 16 | usage
    finger: int,              // which contact collection (-1: none)
}

// What a report descriptor says about input reports.
fn parse(d: [int]) -> [Field] {
    var out: [Field] = []
    var page = 0
    var lmin = 0
    var lmax = 0
    var size = 0
    var count = 0
    var report = 0
    var usages: [int] = []
    var umin = -1
    var umax = -1
    var stack: [[int]] = []           // Push/Pop: [page, lmin, lmax, size, count, report]
    var app = 0
    var depth = 0
    var app_depth = -1
    var fingers = -1
    var finger = -1
    var finger_depth = -1
    var bits: {int: int} = {}         // bits used so far, per report id
    var i = 0
    while i < d.len() {
        let prefix = d[i]
        if prefix == 0xfe {           // a long item: skip it
            if i + 1 >= d.len() { break }
            i += 3 + d[i + 1]
            continue
        }
        let n = [0, 1, 2, 4][prefix & 3]
        if i + n >= d.len() { break }
        var v = 0
        for k in 0..n { v = v | (d[i + 1 + k] << (8 * k)) }
        // signed value (for logical minimum/maximum)
        var sv = v
        if n > 0 && (v >> (8 * n - 1)) & 1 == 1 { sv = v - (1 << (8 * n)) }
        let tag = prefix & 0xfc
        i += 1 + n
        if tag == 0x04 { page = v }                           // Usage Page
        else if tag == 0x14 { lmin = sv }                     // Logical Minimum
        else if tag == 0x24 { lmax = if lmin >= 0 && sv < 0 { v } else { sv } }   // Logical Maximum
        else if tag == 0x74 { size = v }                      // Report Size
        else if tag == 0x84 { report = v }                    // Report ID
        else if tag == 0x94 { count = v }                     // Report Count
        else if tag == 0xa4 { stack.push([page, lmin, lmax, size, count, report]) } else if tag == 0xb4 {
            if !stack.is_empty() {
                let s = stack.pop()
                page = s[0]
                lmin = s[1]
                lmax = s[2]
                size = s[3]
                count = s[4]
                report = s[5]
            }
        } else if tag == 0x08 { usages.push(if n == 4 { v } else { page << 16 | v }) }   // Usage
        else if tag == 0x18 { umin = if n == 4 { v } else { page << 16 | v } }        // Usage Minimum
        else if tag == 0x28 { umax = if n == 4 { v } else { page << 16 | v } }        // Usage Maximum
        else if tag == 0xa0 {                                 // Collection
            let kind = v
            var u = 0
            if !usages.is_empty() { u = usages[0] } else if umin >= 0 { u = umin }
            if kind == 1 && app_depth < 0 {                   // application
                app = u
                app_depth = depth
            }
            if kind == 2 && u == (DIGITIZER << 16 | FINGER) {  // logical: a finger
                fingers += 1
                finger = fingers
                finger_depth = depth
            }
            depth += 1
            usages = []
            umin = -1
            umax = -1
        } else if tag == 0xc0 {                                 // End Collection
            depth -= 1
            if depth == finger_depth {
                finger = -1
                finger_depth = -1
            }
            if depth == app_depth {
                app = 0
                app_depth = -1
                fingers = -1
            }
        } else if tag == 0x80 || tag == 0x90 || tag == 0xb0 {   // Input, Output, Feature
            let at = bits.get(report * 4 + (tag >> 4), 0)
            if tag == 0x80 && v & 1 == 0 {                    // not constant (padding)
                for k in 0..count {
                    var u = -1
                    if k < usages.len() { u = usages[k] } else if umin >= 0 && umin + k <= umax { u = umin + k } else if !usages.is_empty() { u = usages[usages.len() - 1] }
                    if u >= 0 {
                        out.push(Field { page: u >> 16, usage: u & 0xffff, report, bit: at + k * size, size, min: lmin, max: lmax,
                            relative: v & 4 != 0, app, finger })
                    }
                }
            }
            bits[report * 4 + (tag >> 4)] = at + count * size
            usages = []
            umin = -1
            umax = -1
        }
    }
    return out
}

// a field's value in a report (the bytes after the report id)
fn value(f: Field, data: [int]) -> int {
    var v = 0
    for k in 0..f.size {
        let b = f.bit + k
        if b / 8 < data.len() && (data[b / 8] >> (b % 8)) & 1 == 1 { v = v | (1 << k) }
    }
    if f.min < 0 && f.size > 0 && f.size < 64 && (v >> (f.size - 1)) & 1 == 1 { v = v - (1 << f.size) }
    return v
}

fn has_ids(fs: [Field]) -> bool { return fs.any(f => f.report != 0) }

// ---- the touchpad ----

struct Contact {
    x: Field?,
    y: Field?,
    tip: Field?,
}

struct Pad {
    fields: [Field],
    mode: str = "none",       // "mouse", "touchpad" or "none"
    ids: bool = false,
    mouse_report: int = 0,
    pad_report: int = 0,
    contacts: [Contact] = [],
    count: Field? = none,
    buttons: [Field] = [],
    range: int = 1000,        // the X axis's logical range
    // finger tracking
    down: bool = false,
    lx: int = 0,
    ly: int = 0,
    fx: int = 0,              // fractional pixels carried over (x 1000)
    fy: int = 0,
    scroll: int = 0,
    down_at: int = 0,
    moved: int = 0,
    fingers_max: int = 0,
    held: int = 0,            // buttons we report as held

    // Mouse reports [buttons, dx, dy, wheel] (each -127..127) for one input report (with its id).
    fn feed(self, report: [int], now: int) -> [[int]] {
        var out: [[int]] = []
        if report.is_empty() { return out }
        let id = if self.ids { report[0] } else { 0 }
        let data = if self.ids { report.slice(1, report.len()) } else { report }
        if self.mode == "mouse" && id == self.mouse_report {
            var b = 0
            var dx = 0
            var dy = 0
            var wheel = 0
            for f in self.fields {
                if f.report != id || f.app != (DESKTOP << 16 | MOUSE) { continue }
                if f.page == BUTTONS && f.usage >= 1 && f.usage <= 3 && value(f, data) != 0 { b = b | (1 << (f.usage - 1)) }
                if f.page == DESKTOP && f.usage == X { dx = value(f, data) }
                if f.page == DESKTOP && f.usage == Y { dy = value(f, data) }
                if f.page == DESKTOP && f.usage == WHEEL { wheel = value(f, data) }
            }
            return motion(b, dx, dy, wheel)
        }
        if self.mode != "touchpad" || id != self.pad_report { return out }
        // touchpad mode: the first finger that touches moves the pointer; two scroll
        var n = 0
        if let c = self.count { n = value(c, data) }
        var touching: [Contact] = []
        for c in self.contacts {
            if let t = c.tip {
                if value(t, data) != 0 { touching.push(c) }
            }
        }
        if n == 0 { n = touching.len() }
        var click = 0
        for f in self.buttons {
            if value(f, data) != 0 { click = click | (1 << (f.usage - 1)) }
        }
        if touching.is_empty() {
            // a finger lifted: was it a tap?
            if self.down && now - self.down_at < 200 && self.moved < 30 && self.held == 0 && click == 0 {
                let b = if self.fingers_max >= 2 { 2 } else { 1 }
                out.push([b, 0, 0, 0])
                out.push([0, 0, 0, 0])
            }
            self.down = false
            self.fingers_max = 0
            if click != self.held {
                self.held = click
                out.push([click, 0, 0, 0])
            }
            return out
        }
        let c = touching[0]
        var x = 0
        var y = 0
        if let f = c.x { x = value(f, data) }
        if let f = c.y { y = value(f, data) }
        self.fingers_max = max(self.fingers_max, n)
        if !self.down {
            self.down = true
            self.down_at = now
            self.moved = 0
            self.lx = x
            self.ly = y
            self.scroll = 0
            if click != self.held {
                self.held = click
                out.push([click, 0, 0, 0])
            }
            return out
        }
        // the pad's whole width is about 1.5 screen widths of pointer travel (1600 pixels)
        let ddx = (x - self.lx) * 1600 * 1000 / max(self.range, 1) + self.fx
        let ddy = (y - self.ly) * 1600 * 1000 / max(self.range, 1) + self.fy
        self.lx = x
        self.ly = y
        let px = ddx / 1000
        let py = ddy / 1000
        self.fx = ddx - px * 1000
        self.fy = ddy - py * 1000
        self.moved += abs(px) + abs(py)
        self.held = click
        if n >= 2 {
            // two fingers: scroll, a notch every 40 pixels
            self.scroll += py
            var notches = 0
            while self.scroll >= 40 {
                self.scroll -= 40
                notches -= 1
            }
            while self.scroll <= -40 {
                self.scroll += 40
                notches += 1
            }
            if notches != 0 { out.push([click, 0, 0, notches]) }
            return out
        }
        for m in motion(click, px, py, 0) { out.push(m) }
        return out
    }
}

// motion in steps the boot-protocol format can carry
fn motion(b: int, dx: int, dy: int, wheel: int) -> [[int]] {
    var out: [[int]] = []
    var x = dx
    var y = dy
    var first = true
    while first || x != 0 || y != 0 {
        let sx = max(-127, min(127, x))
        let sy = max(-127, min(127, y))
        out.push([b, sx, sy, if first { max(-127, min(127, wheel)) } else { 0 }])
        x -= sx
        y -= sy
        first = false
    }
    return out
}

// What kind of pointing device a descriptor describes, and where its values are.
fn pad(d: [int]) -> Pad {
    let fs = parse(d)
    let p = Pad { fields: fs, ids: has_ids(fs) }
    let touch = fs.filter(f => f.app == (DIGITIZER << 16 | TOUCHPAD))
    let mouse = fs.filter(f => f.app == (DESKTOP << 16 | MOUSE) && f.page == DESKTOP && (f.usage == X || f.usage == Y) && f.relative)
    if !mouse.is_empty() {
        // mouse mode: what touchpads do until told otherwise (we don't tell them)
        p.mode = "mouse"
        p.mouse_report = mouse[0].report
    } else if !touch.is_empty() {
        p.mode = "touchpad"
        p.pad_report = touch[0].report
        var k = 0
        while true {
            let fk = touch.filter(f => f.finger == k && f.report == p.pad_report)
            if fk.is_empty() { break }
            p.contacts.push(Contact {
                x: fk.find(f => f.page == DESKTOP && f.usage == X),
                y: fk.find(f => f.page == DESKTOP && f.usage == Y),
                tip: fk.find(f => f.page == DIGITIZER && f.usage == TIP),
            })
            k += 1
        }
        p.count = touch.find(f => f.page == DIGITIZER && f.usage == CONTACT_COUNT && f.report == p.pad_report)
        p.buttons = touch.filter(f => f.page == BUTTONS && f.usage >= 1 && f.usage <= 3 && f.report == p.pad_report)
        if let c = p.contacts.first() {
            if let fx = c.x { p.range = max(fx.max - fx.min, 1) }
        }
        if p.contacts.is_empty() { p.mode = "none" }
    }
    return p
}
