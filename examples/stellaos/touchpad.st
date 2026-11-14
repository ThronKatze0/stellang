// touchpad: laptop touchpads (HID over I²C), written in stellang. ACPI says where the touchpad is
// (acpi.st), the I²C controller carries the bytes (i2c.st), and HID's report descriptor says what
// the reports mean (hid.st). Reports come out as boot-protocol mouse reports, like a USB mouse's.
//
// HID over I²C: a 30-byte HID descriptor at a register the firmware names (its _DSM); it says where
// the report descriptor is, the input register (we read reports there), the command register (reset,
// power). The device normally raises an interrupt line when a report is waiting; we poll instead
// (a read with nothing waiting gives a length of 0).

import kernel
import acpi
import i2c
import hid

// touchpads' usual I²C addresses (Elan, Synaptics, Goodix, Alps, ...), for firmware that only
// fills the address in at run time
const COMMON = [0x15, 0x2c, 0x20, 0x10, 0x2a, 0x38, 0x5d, 0x0a, 0x2d, 0x24, 0x40, 0x1a, 0x34]

struct Device {
    bus: i2c.Bus,
    addr: int,
    fast: bool,
    name: str,
    where: str,
    input_reg: int,
    max_input: int,
    command_reg: int,
    pad: hid.Pad,
}

struct Touch {
    devices: [Device] = [],
    log: [str] = [],

    fn note(self, s: str) {
        self.log.push(s)
        if self.log.len() > 30 { self.log.remove(0) }
    }

    // Mouse reports since the last call.
    fn poll(self) -> [[int]] {
        var out: [[int]] = []
        for d in self.devices {
            // a few reports per call at most (each read is a transfer)
            for k in 0..4 {
                let r = d.bus.xfer(d.addr, [], d.max_input, d.fast) ?? []
                if r.len() < 2 { break }
                let len = r[0] | r[1] << 8
                if len <= 2 || len > r.len() { break }
                for m in d.pad.feed(r.slice(2, len), now_ms()) { out.push(m) }
            }
        }
        return out
    }

    fn describe(self) -> [str] {
        return self.devices.map(d => "${d.name} at ${d.where}: ${d.pad.mode} mode")
    }
}

// The 30-byte HID descriptor at `reg`, if that's what's there.
fn hid_descriptor(bus: i2c.Bus, addr: int, reg: int, fast: bool) -> [int]? {
    if let d = bus.xfer(addr, [reg & 0xff, reg >> 8], 30, fast) {
        let len = d[0] | d[1] << 8
        let version = d[2] | d[3] << 8
        if len == 30 && version == 0x0100 { return some(d) }
    }
    return none
}

// Set up the touchpad at `addr` on `bus`, if there is one.
fn start(t: Touch, bus: i2c.Bus, addr: int, fast: bool, regs: [int], name: str, where: str) -> bool {
    var cands = regs.slice(0, regs.len())
    for r in [0x20, 0x01, 0x30, 0x00] {
        if !cands.contains(r) { cands.push(r) }
    }
    for reg in cands {
        if let d = hid_descriptor(bus, addr, reg, fast) {
            let w = (k: int) => d[k] | d[k + 1] << 8
            let rd_len = w(4)
            let rd_reg = w(6)
            let in_reg = w(8)
            let max_in = max(min(w(10), 256), 4)
            let cmd = w(16)
            // power on, then reset (it answers the reset with an empty report, which we read away)
            bus.xfer(addr, [cmd & 0xff, cmd >> 8, 0x00, 0x08], 0, fast)
            sleep(2)
            bus.xfer(addr, [cmd & 0xff, cmd >> 8, 0x00, 0x01], 0, fast)
            sleep(100)
            bus.xfer(addr, [], max_in, fast)
            let desc = bus.xfer(addr, [rd_reg & 0xff, rd_reg >> 8], min(rd_len, 4096), fast) ?? []
            if desc.is_empty() {
                t.note("${where} 0x${i2c.hex(addr)}: no report descriptor")
                return false
            }
            let p = hid.pad(desc)
            if p.mode == "none" {
                t.note("${where} 0x${i2c.hex(addr)}: a HID device, but not a pointing device")
                return false
            }
            t.devices.push(Device { bus, addr, fast, name, where: "${where} 0x${i2c.hex(addr)}", input_reg: in_reg, max_input: max_in, command_reg: cmd, pad: p })
            t.note("${name}: touchpad at ${where} 0x${i2c.hex(addr)}, ${p.mode} mode (HID descriptor at 0x${i2c.hex(reg)})")
            return true
        }
    }
    return false
}

// Find and start the touchpads ACPI describes.
fn open() -> Touch {
    let t = Touch {}
    if kernel.arch() != "x86_64" { return t }
    let tables = acpi.aml()
    if tables.is_empty() {
        t.note("no ACPI tables")
        return t
    }
    let devs = acpi.hid_i2c(tables)
    if devs.is_empty() {
        t.note("ACPI lists no HID-over-I²C device")
        return t
    }
    let ctrls = i2c.controllers()
    var buses: {int: i2c.Bus} = {}
    for d in devs {
        if t.devices.any(x => x.name == d.name) { continue }
        t.note("ACPI: ${d.name} (${d.hid}) on ${d.controller}, address 0x${i2c.hex(d.address)}, ${d.speed / 1000} kHz")
        // its controller: by the _ADR ACPI gives it, else every Intel I²C controller
        var cands = ctrls
        if d.adr >= 0 { cands = ctrls.filter(f => f.dev == d.adr >> 16 && f.func == (d.adr & 0xffff)) }
        if cands.is_empty() { cands = ctrls }
        let fast = d.speed >= 400000
        var found = false
        for f in cands {
            let key = f.dev * 8 + f.func
            if !buses.contains(key) {
                if let b = i2c.open(f) { buses[key] = b } else { continue }
            }
            let bus = buses[key]
            let where = "${d.controller} (PCI 00:${i2c.hex(f.dev)}.${f.func})"
            let addrs = if d.address != 0 { [d.address] } else { COMMON }
            for a in addrs {
                if start(t, bus, a, fast, d.registers, d.hid, where) {
                    found = true
                    break
                }
            }
            if found { break }
        }
        if !found { t.note("${d.name}: no answer on its I²C bus") }
    }
    return t
}
