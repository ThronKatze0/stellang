// acpi: what a PC's firmware says about its hardware, read from the ACPI tables (the loader hands us
// where they are). We don't run ACPI's bytecode (AML); we only look through it for what a touchpad
// driver needs: the devices that speak HID over I²C ("PNP0C50"), their I²C address and speed, the
// controller they hang off, and that controller's place on the PCI bus.
//
// Firmware often computes some of this at run time (an address patched in from a setting): then the
// static answer is 0 and touchpad.st probes the usual touchpad addresses on that controller instead.

import kernel

extern fn st_k_acpi_rsdp() -> int

// A HID-over-I²C device the tables describe.
struct HidI2c {
    name: str,                // its ACPI name ("TPD0")
    hid: str,                 // its hardware id ("ELAN0D61", "SYNA2B5A", or the "PNP0C50" it's compatible with)
    address: int,             // on the I²C bus (0: computed at run time)
    speed: int,               // Hz
    controller: str,          // the I²C controller's ACPI name ("I2C1")
    adr: int,                 // the controller's PCI device << 16 | function, or -1
    registers: [int],         // where its _DSM says the HID descriptor is (candidates)
}

// ---- reading the tables ----

fn sig(at: int) -> str {
    var s = ""
    for i in 0..4 { s += st_chr(kernel.peek8(at + i)) }
    return s
}
extern fn st_chr(code: int) -> str

// The bytes of a table (header included), at most 4 MiB.
fn table_bytes(at: int) -> [int] {
    let n = min(kernel.peek32(at + 4), 4 << 20)
    var out: [int] = []
    for i in 0..n { out.push(kernel.peek8(at + i)) }
    return out
}

fn body(t: [int]) -> [int] { return if t.len() > 36 { t.slice(36, t.len()) } else { [] } }

// The AML of the DSDT and the SSDTs (each without its 36-byte header).
fn aml() -> [[int]] {
    var out: [[int]] = []
    let rsdp = st_k_acpi_rsdp()
    if rsdp == 0 { return out }
    var entries: [int] = []
    // XSDT (64-bit entries) when the RSDP is version 2, else RSDT (32-bit)
    let xsdt = if kernel.peek8(rsdp + 15) >= 2 { kernel.peek64(rsdp + 24) } else { 0 }
    if xsdt != 0 && sig(xsdt) == "XSDT" {
        let n = (kernel.peek32(xsdt + 4) - 36) / 8
        for i in 0..min(n, 256) { entries.push(kernel.peek64(xsdt + 36 + 8 * i)) }
    } else {
        let rsdt = kernel.peek32(rsdp + 16)
        if rsdt == 0 || sig(rsdt) != "RSDT" { return out }
        let n = (kernel.peek32(rsdt + 4) - 36) / 4
        for i in 0..min(n, 256) { entries.push(kernel.peek32(rsdt + 36 + 4 * i)) }
    }
    for t in entries {
        if t == 0 { continue }
        let s = sig(t)
        if s == "FACP" {
            // the DSDT: X_DSDT (64-bit) if the FADT is long enough, else DSDT
            let len = kernel.peek32(t + 4)
            var d = if len >= 148 { kernel.peek64(t + 140) } else { 0 }
            if d == 0 { d = kernel.peek32(t + 40) }
            if d != 0 && sig(d) == "DSDT" { out.insert(0, body(table_bytes(d))) }
        } else if s == "SSDT" {
            out.push(body(table_bytes(t)))
        }
    }
    return out
}

// ---- looking through AML ----

// A Device or Scope: its name (last segment) and the bytes it spans.
struct Span {
    name: str,
    start: int,
    end: int,
    device: bool,
}

fn is_name_char(c: int) -> bool { return c >= 65 && c <= 90 || c >= 48 && c <= 57 || c == 95 }

// A PkgLength at i: [its value, how many bytes it took]
fn pkg_length(b: [int], i: int) -> [int] {
    if i >= b.len() { return [0, 1] }
    let lead = b[i]
    let extra = lead >> 6
    if extra == 0 { return [lead & 63, 1] }
    var v = lead & 15
    for k in 0..extra {
        if i + 1 + k >= b.len() { return [0, 1] }
        v = v | (b[i + 1 + k] << (4 + 8 * k))
    }
    return [v, 1 + extra]
}

// the last NameSeg of the NameString at i ("" if it isn't one)
fn name_at(b: [int], i: int) -> str {
    var j = i
    while j < b.len() && (b[j] == 0x5c || b[j] == 0x5e) { j += 1 }      // \ and ^ prefixes
    var segs = 1
    if j < b.len() && b[j] == 0x2e {
        segs = 2
        j += 1
    } else if j < b.len() && b[j] == 0x2f {
        if j + 1 >= b.len() { return "" }
        segs = b[j + 1]
        j += 2
    }
    if segs < 1 || segs > 16 || j + 4 * segs > b.len() { return "" }
    let at = j + 4 * (segs - 1)
    var s = ""
    for k in 0..4 {
        let c = b[at + k]
        if !is_name_char(c) || (k == 0 && c >= 48 && c <= 57) { return "" }
        s += st_chr(c)
    }
    return s
}

// Every Device(...) and Scope(...) in the AML.
fn spans(b: [int]) -> [Span] {
    var out: [Span] = []
    var i = 0
    while i + 4 < b.len() {
        let device = b[i] == 0x5b && b[i + 1] == 0x82
        let scope = b[i] == 0x10
        if device || scope {
            let at = if device { i + 2 } else { i + 1 }
            let pl = pkg_length(b, at)
            let end = at + pl[0]
            let name = name_at(b, at + pl[1])
            if name != "" && pl[0] > 4 && end <= b.len() {
                out.push(Span { name, start: i, end, device })
            }
        }
        i += 1
    }
    return out
}

// the innermost span holding position p
fn inside(ss: [Span], p: int, devices_only: bool) -> Span? {
    var best: Span? = none
    for s in ss {
        if s.start <= p && p < s.end && (!devices_only || s.device) {
            if let b = best {
                if s.end - s.start < b.end - b.start { best = some(s) }
            } else {
                best = some(s)
            }
        }
    }
    return best
}

fn find_bytes(b: [int], pat: [int], from: int, to: int) -> int {
    var i = from
    while i + pat.len() <= min(to, b.len()) {
        var k = 0
        while k < pat.len() && b[i + k] == pat[k] { k += 1 }
        if k == pat.len() { return i }
        i += 1
    }
    return -1
}

fn ascii(s: str) -> [int] {
    var out: [int] = []
    for i in 0..s.len() { out.push(st_k_byte(s, i)) }
    return out
}
extern fn st_k_byte(s: str, i: int) -> int

// "PNP0C50" as an EISA id (what EISAID("PNP0C50") compiles to), with the DWord prefix
const PNP0C50_EISA = [0x0c, 0x41, 0xd0, 0x0c, 0x50]

// A string or EISA id right after `at` (a NameOp's name), as text.
fn id_after(b: [int], at: int) -> str {
    if at >= b.len() { return "" }
    if b[at] == 0x0d {
        var s = ""
        var j = at + 1
        while j < b.len() && b[j] != 0 && s.len() < 16 {
            s += st_chr(b[j])
            j += 1
        }
        return s
    }
    if b[at] == 0x0c && at + 4 < b.len() {
        // EISA id: three 5-bit letters, then four hex digits
        let v = b[at + 1] << 8 | b[at + 2]
        let hex = "0123456789ABCDEF"
        let letters = st_chr(64 + ((v >> 10) & 31)) + st_chr(64 + ((v >> 5) & 31)) + st_chr(64 + (v & 31))
        return letters + hex[b[at + 3] >> 4] + hex[b[at + 3] & 15] + hex[b[at + 4] >> 4] + hex[b[at + 4] & 15]
    }
    return ""
}

// a small integer constant at `at` (ZeroOp, OneOp, BytePrefix, WordPrefix, DWordPrefix), or -1
fn const_at(b: [int], at: int) -> int {
    if at >= b.len() { return -1 }
    let op = b[at]
    if op == 0x00 { return 0 }
    if op == 0x01 { return 1 }
    if op == 0x0a && at + 1 < b.len() { return b[at + 1] }
    if op == 0x0b && at + 2 < b.len() { return b[at + 1] | b[at + 2] << 8 }
    if op == 0x0c && at + 4 < b.len() { return b[at + 1] | b[at + 2] << 8 | b[at + 3] << 16 | b[at + 4] << 24 }
    return -1
}

// I2cSerialBus resource descriptors in [from, to): [address, speed, controller name]
fn i2c_resources(b: [int], from: int, to: int) -> [[str]] {
    var out: [[str]] = []
    var i = from
    while i + 18 < min(to, b.len()) {
        if b[i] == 0x8e && b[i + 5] == 1 {
            let len = b[i + 1] | b[i + 2] << 8
            let speed = b[i + 12] | b[i + 13] << 8 | b[i + 14] << 16 | b[i + 15] << 24
            let tdl = b[i + 10] | b[i + 11] << 8
            if len >= 15 && len < 256 && speed >= 10000 && speed <= 3400000 && tdl >= 6 && 12 + tdl <= 3 + len {
                let addr = b[i + 16] | b[i + 17] << 8
                // the resource source: an ASCII path after the type data, up to the end
                var src = ""
                var j = i + 12 + tdl
                while j < i + 3 + len && j < b.len() && b[j] != 0 {
                    src += st_chr(b[j])
                    j += 1
                }
                let segs = src.split(".")
                let ctrl = segs[segs.len() - 1].replace("\\", "")
                out.push(["${addr & 0x3ff}", "${speed}", ctrl])
                i += 3 + len
                continue
            }
        }
        i += 1
    }
    return out
}

// A controller's _ADR (PCI device << 16 | function): Name(_ADR, x) or Method(_ADR) { Return(x) }.
fn adr_of(blobs: [[int]], name: str) -> int {
    for b in blobs {
        for s in spans(b) {
            if s.name != name { continue }
            let at = find_bytes(b, ascii("_ADR"), s.start, s.end)
            if at < 0 { continue }
            if at > 0 && b[at - 1] == 0x08 {
                let v = const_at(b, at + 4)
                if v >= 0 { return v }
            }
            // a method: the first Return's value
            let r = find_bytes(b, [0xa4], at + 4, min(at + 24, s.end))
            if r >= 0 {
                let v2 = const_at(b, r + 1)
                if v2 >= 0 { return v2 }
            }
        }
    }
    return -1
}

// Every HID-over-I²C device in the tables.
fn hid_i2c(blobs: [[int]]) -> [HidI2c] {
    var out: [HidI2c] = []
    for b in blobs {
        let ss = spans(b)
        var hits: [int] = []
        var at = find_bytes(b, PNP0C50_EISA, 0, b.len())
        while at >= 0 {
            hits.push(at)
            at = find_bytes(b, PNP0C50_EISA, at + 1, b.len())
        }
        for word in ["PNP0C50", "ACPI0C50"] {
            var pat = [0x0d]
            for c in ascii(word) { pat.push(c) }
            var at2 = find_bytes(b, pat, 0, b.len())
            while at2 >= 0 {
                hits.push(at2)
                at2 = find_bytes(b, pat, at2 + 1, b.len())
            }
        }
        for h in hits {
            if let dev = inside(ss, h, true) {
                if out.any(d => d.name == dev.name) { continue }
                // its _HID (a vendor's id, else the compatible one)
                var hid = "PNP0C50"
                let hp = find_bytes(b, ascii("_HID"), dev.start, dev.end)
                if hp >= 0 {
                    let id = id_after(b, hp + 4)
                    if id != "" { hid = id }
                }
                // where its _DSM says the HID descriptor is: the small constants it returns
                var regs: [int] = []
                let dsm = find_bytes(b, ascii("_DSM"), dev.start, dev.end)
                if dsm >= 0 {
                    var r = find_bytes(b, [0xa4], dsm, dev.end)
                    var n = 0
                    while r >= 0 && n < 16 {
                        let v = const_at(b, r + 1)
                        if v > 0 && v < 0x10000 && !regs.contains(v) { regs.push(v) }
                        r = find_bytes(b, [0xa4], r + 1, dev.end)
                        n += 1
                    }
                }
                // its I²C connection(s); the controller from the resource, else from where it sits
                let res = i2c_resources(b, dev.start, dev.end)
                var parent = ""
                if let p = inside(ss.filter(s => s.start < dev.start && dev.end <= s.end && s.name != dev.name), dev.start, false) { parent = p.name }
                if res.is_empty() {
                    out.push(HidI2c { name: dev.name, hid, address: 0, speed: 400000, controller: parent, adr: -1, registers: regs })
                } else {
                    for r in res {
                        let ctrl = if r[2] != "" { r[2] } else { parent }
                        out.push(HidI2c { name: dev.name, hid, address: int(r[0]) catch 0, speed: int(r[1]) catch 400000, controller: ctrl, adr: -1, registers: regs })
                    }
                }
            }
        }
    }
    for d in out { d.adr = adr_of(blobs, d.controller) }
    return out
}
