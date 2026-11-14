// xhci: USB on a PC, through its xHCI controller, written in stellang: enough to use USB keyboards
// and mice (including wireless ones with a receiver) in the HID "boot protocol", the simple fixed
// report format every keyboard and mouse supports for BIOS setup screens. input.st turns the reports
// into events.
//
// The controller works from rings in memory: we put commands on the command ring and transfers on
// each endpoint's transfer ring (16-byte TRBs), ring a doorbell, and it posts what happened to the
// event ring, which we poll (no interrupts). Each device gets a slot with a device context: what the
// controller knows about the device and its endpoints.
//
// Not here: hubs (plug the mouse into the computer itself), USB storage or anything else. Nothing is
// ever written to a USB device except its standard setup requests (address, configuration, protocol).

import kernel
import pci

// TRB types
const NORMAL = 1
const SETUP = 2
const DATA = 3
const STATUS = 4
const LINK = 6
const ENABLE_SLOT = 9
const ADDRESS_DEVICE = 11
const CONFIGURE_EP = 12
const EVALUATE_CTX = 13
const TRANSFER_EVENT = 32
const COMMAND_DONE = 33
const PORT_CHANGE = 34

// completion codes
const SUCCESS = 1
const SHORT_PACKET = 13

const RING_TRBS = 256         // one page of TRBs per ring; the last is the link back to the start

// A ring of TRBs we produce into (commands, transfers).
struct Ring {
    base: int,
    index: int = 0,
    cycle: int = 1,

    // Put a TRB on the ring; returns its address. The control word (with the cycle bit that hands it
    // to the controller) is written last.
    fn push(self, param: int, status: int, control: int) -> int {
        let at = self.base + 16 * self.index
        kernel.poke64(at, param)
        kernel.poke32(at + 8, status)
        kernel.poke32(at + 12, (control & ~1) | self.cycle)
        self.index += 1
        if self.index == RING_TRBS - 1 {
            // the link TRB: back to the start, and the cycle bit flips (toggle cycle)
            let link = self.base + 16 * self.index
            kernel.poke64(link, self.base)
            kernel.poke32(link + 8, 0)
            kernel.poke32(link + 12, (LINK << 10) | 2 | self.cycle)
            self.index = 0
            self.cycle = 1 - self.cycle
        }
        return at
    }
}

fn ring() -> Ring {
    return Ring { base: kernel.alloc_pages(1) }
}

// What the controller posted on the event ring.
struct Event {
    kind: int,                // a TRB type: TRANSFER_EVENT, COMMAND_DONE, PORT_CHANGE
    param: int,               // the TRB it is about (commands, transfers), or the port (bits 24..31)
    code: int,                // completion code
    left: int,                // transfers: bytes not transferred
    slot: int,
    ep: int,                  // transfers: the endpoint (device context index)
}

// A keyboard or mouse report: the raw bytes of the boot protocol (keyboard: modifiers, 0, 6 keys;
// mouse: buttons, x, y, wheel), and the device's previous report.
struct Report {
    kind: str,                // "keyboard" or "mouse"
    data: [int],
    last: [int],
}

// An interrupt endpoint that sends reports.
struct Pipe {
    slot: int,
    port: int,
    dci: int,                 // device context index: endpoint number * 2 + 1 for IN
    kind: str,
    ring: Ring,
    buf: int,
    size: int,
    last: [int] = [],
    errors: int = 0,
}

struct Controller {
    pci: pci.Function,
    base: int,
    op: int,                  // operational registers
    rt: int,                  // runtime registers
    db: int,                  // doorbells
    ports: int,
    slots: int,
    ctx: int,                 // bytes per context (32 or 64)
    dcbaa: int,
    cmd: Ring,
    events: int,              // the event ring
    ev_index: int = 0,
    ev_cycle: int = 1,
    pipes: [Pipe] = [],
    stash: [Event] = [],      // transfer events that came while waiting for something else
    attached: [int] = [],     // ports with a device we set up (or gave up on)
    next_scan: int = 0,
    log: [str] = [],

    fn op32(self, off: int) -> int { return kernel.peek32(self.op + off) }
    fn set_op32(self, off: int, v: int) { kernel.poke32(self.op + off, v) }
    fn set64(self, addr: int, v: int) {
        kernel.poke32(addr, v & 0xffff_ffff)
        kernel.poke32(addr + 4, v >> 32)
    }

    fn portsc(self, port: int) -> int { return self.op32(0x400 + 0x10 * (port - 1)) }

    // Write a port's register without disturbing it: the bits that clear when written as 1 (the
    // changes, and "enabled") go in as 0, unless `extra` sets them.
    fn set_portsc(self, port: int, extra: int) {
        let keep = self.portsc(port) & 0x4e00_ffe9
        self.set_op32(0x400 + 0x10 * (port - 1), keep | extra)
    }

    // ---- the event ring ----

    fn next_event(self) -> Event? {
        let at = self.events + 16 * self.ev_index
        let control = kernel.peek32(at + 12)
        if control & 1 != self.ev_cycle { return none }
        let status = kernel.peek32(at + 8)
        let e = Event { kind: (control >> 10) & 63, param: kernel.peek64(at), code: status >> 24, left: status & 0xff_ffff,
            slot: control >> 24, ep: (control >> 16) & 31 }
        self.ev_index += 1
        if self.ev_index == RING_TRBS {
            self.ev_index = 0
            self.ev_cycle = 1 - self.ev_cycle
        }
        // tell the controller how far we got (bit 3 clears "event handler busy")
        self.set64(self.rt + 0x38, (self.events + 16 * self.ev_index) | 8)
        return some(e)
    }

    // Wait (up to `ms`) for the event about the TRB at `trb`; transfer events for others are kept.
    fn wait_for(self, trb: int, ms: int) -> Event? {
        let until = now_ms() + ms
        while now_ms() < until {
            if let e = self.next_event() {
                if e.param == trb && (e.kind == COMMAND_DONE || e.kind == TRANSFER_EVENT) { return some(e) }
                if e.kind == TRANSFER_EVENT { self.stash.push(e) }
            }
        }
        return none
    }

    // Run a command; the completion event if it succeeded.
    fn command(self, param: int, status: int, control: int) -> Event? {
        let trb = self.cmd.push(param, status, control)
        kernel.poke32(self.db, 0)
        if let e = self.wait_for(trb, 500) {
            if e.code == SUCCESS { return some(e) }
            self.note("command ${(control >> 10) & 63} failed: code ${e.code}")
        } else {
            self.note("command ${(control >> 10) & 63}: no answer")
        }
        return none
    }

    fn note(self, s: str) {
        self.log.push(s)
        if self.log.len() > 40 { self.log.remove(0) }
    }

    // ---- control transfers on endpoint 0 ----

    // A setup request; `len` bytes of data go to `buf` (IN, when `type_ & 0x80`) or come from it.
    // True if the device answered. A device may refuse (stall) a request it doesn't know: then
    // endpoint 0 is reset, so the next request still goes through.
    fn control(self, slot: int, ep0: Ring, type_: int, request: int, value: int, index: int, len: int, buf: int) -> bool {
        let setup = type_ | (request << 8) | (value << 16) | (index << 32) | (len << 48)
        let into = type_ & 0x80 != 0
        let trt = if len == 0 { 0 } else if into { 3 } else { 2 }
        var trbs: [int] = []
        trbs.push(ep0.push(setup, 8, (SETUP << 10) | 64 | (trt << 16)))   // 64: the data is in the TRB itself
        if len > 0 { trbs.push(ep0.push(buf, len, (DATA << 10) | (if into { 1 << 16 } else { 0 }))) }
        // the status stage goes the other way (IN when there was no data); 32: tell us when done
        let st = ep0.push(0, 0, (STATUS << 10) | 32 | (if len > 0 && into { 0 } else { 1 << 16 }))
        trbs.push(st)
        kernel.poke32(self.db + 4 * slot, 1)
        let until = now_ms() + 500
        while now_ms() < until {
            if let e = self.next_event() {
                if e.kind == TRANSFER_EVENT && e.slot == slot && e.ep == 1 && trbs.contains(e.param) {
                    if e.code == SUCCESS || e.code == SHORT_PACKET {
                        if e.param == st { return true }
                        continue        // a short data stage: the status stage still reports
                    }
                    self.recover(slot, ep0)
                    return false
                }
                if e.kind == TRANSFER_EVENT { self.stash.push(e) }
            }
        }
        self.recover(slot, ep0)
        return false
    }

    // endpoint 0 halted (or stuck): reset it and continue after what's on its ring
    fn recover(self, slot: int, ep0: Ring) {
        self.reset_ep(slot, 1, ep0)
    }

    fn reset_ep(self, slot: int, dci: int, r: Ring) {
        self.command(0, 0, (14 << 10) | (dci << 16) | (slot << 24))                        // Reset Endpoint
        let at = r.base + 16 * r.index
        self.command(at | r.cycle, 0, (16 << 10) | (dci << 16) | (slot << 24))             // Set TR Dequeue Pointer
    }

    // ---- devices ----

    // input context: control context, then slot, then endpoints (each `ctx` bytes)
    fn icx(self, input: int, i: int) -> int { return input + self.ctx * i }

    // Set up the device on `port`: give it an address, read what it is, and if it has a boot-
    // protocol keyboard or mouse interface, start listening to it.
    fn attach(self, port: int) {
        let sc = self.portsc(port)
        let speed = (sc >> 10) & 15        // 1 full, 2 low, 3 high, 4+ super speed
        let done = self.command(0, 0, ENABLE_SLOT << 10)
        if done == none { return }
        let slot = done.unwrap().slot
        if slot < 1 || slot > self.slots { return }
        let out = kernel.alloc_pages(2)
        kernel.poke64(self.dcbaa + 8 * slot, out)
        let input = kernel.alloc_pages(2)
        let ep0 = ring()
        let mps = if speed >= 4 { 512 } else if speed == 3 { 64 } else { 8 }
        kernel.poke32(input + 4, 3)                                            // add: slot, endpoint 0
        let s = self.icx(input, 1)
        kernel.poke32(s, (1 << 27) | (speed << 20))                            // 1 context entry
        kernel.poke32(s + 4, port << 16)                                       // its root hub port
        let e0 = self.icx(input, 2)
        kernel.poke32(e0 + 4, (mps << 16) | (4 << 3) | (3 << 1))               // control, 3 retries
        kernel.poke64(e0 + 8, ep0.base | 1)
        kernel.poke32(e0 + 16, 8)
        if self.command(input, 0, (ADDRESS_DEVICE << 10) | (slot << 24)) == none { return }
        let buf = kernel.alloc_pages(1)
        // the device descriptor: the first 8 bytes say how big endpoint 0's packets really are
        if !self.control(slot, ep0, 0x80, 6, 0x100, 0, 8, buf) {
            self.note("port ${port}: no device descriptor")
            return
        }
        let real = kernel.peek8(buf + 7)
        if speed < 3 && real != mps && real >= 8 {
            kernel.poke32(input, 0)
            kernel.poke32(input + 4, 2)                                        // evaluate endpoint 0
            kernel.poke32(e0 + 4, (real << 16) | (4 << 3) | (3 << 1))
            self.command(input, 0, (EVALUATE_CTX << 10) | (slot << 24))
        }
        // the configuration descriptor: first its length, then all of it
        if !self.control(slot, ep0, 0x80, 6, 0x200, 0, 9, buf) { return }
        let total = min(kernel.peek16(buf + 2), 4096)
        if !self.control(slot, ep0, 0x80, 6, 0x200, 0, total, buf) { return }
        let config = kernel.peek8(buf + 5)
        // walk the descriptors: interfaces (class 3 HID, subclass 1 boot, protocol 1 keyboard /
        // 2 mouse) and their first interrupt IN endpoint
        var found: [[int]] = []        // [interface, protocol, endpoint address, max packet, interval]
        var at = 0
        var iface = -1
        var proto = 0
        var want = false
        while at + 2 <= total {
            let len = kernel.peek8(buf + at)
            let kind = kernel.peek8(buf + at + 1)
            if len < 2 { break }
            if kind == 4 && len >= 9 {
                iface = kernel.peek8(buf + at + 2)
                proto = kernel.peek8(buf + at + 7)
                want = kernel.peek8(buf + at + 5) == 3 && kernel.peek8(buf + at + 6) == 1 && (proto == 1 || proto == 2)
            } else if kind == 5 && len >= 7 && want {
                let addr = kernel.peek8(buf + at + 2)
                if addr & 0x80 != 0 && kernel.peek8(buf + at + 3) & 3 == 3 {
                    found.push([iface, proto, addr, kernel.peek16(buf + at + 4) & 0x7ff, kernel.peek8(buf + at + 6)])
                    want = false
                }
            }
            at += len
        }
        if found.is_empty() {
            self.note("port ${port}: not a keyboard or mouse")
            return
        }
        if !self.control(slot, ep0, 0x00, 9, config, 0, 0, 0) {                // SET_CONFIGURATION
            self.note("port ${port}: configuration refused")
            return
        }
        // the endpoints, all in one Configure Endpoint command
        kernel.fill32(input, (self.ctx * 33) / 4, 0)
        var add = 1
        var last_dci = 1
        var pipes: [Pipe] = []
        for f in found {
            self.control(slot, ep0, 0x21, 0x0b, 0, f[0], 0, 0)                 // SET_PROTOCOL: boot
            self.control(slot, ep0, 0x21, 0x0a, 0, f[0], 0, 0)                 // SET_IDLE: only changes
            let dci = (f[2] & 15) * 2 + 1
            let size = max(min(f[3], 64), 8)
            // how often to ask, as 2^n x 125 us: high/super speed say n+1, full/low speed milliseconds
            var interval = if speed >= 3 { max(f[4], 1) - 1 } else { 3 }
            if speed < 3 {
                while (1 << (interval + 1)) <= f[4] * 8 && interval < 10 { interval += 1 }
            }
            let r = ring()
            let ep = self.icx(input, dci + 1)
            kernel.poke32(ep, interval << 16)
            kernel.poke32(ep + 4, (size << 16) | (7 << 3) | (3 << 1))          // interrupt IN, 3 retries
            kernel.poke64(ep + 8, r.base | 1)
            kernel.poke32(ep + 16, (size << 16) | size)
            add = add | (1 << dci)
            last_dci = max(last_dci, dci)
            pipes.push(Pipe { slot, port, dci, kind: if f[1] == 1 { "keyboard" } else { "mouse" }, ring: r, buf: kernel.alloc_pages(1), size })
        }
        kernel.poke32(input + 4, add)
        let s2 = self.icx(input, 1)
        kernel.poke32(s2, (last_dci << 27) | (speed << 20))
        kernel.poke32(s2 + 4, port << 16)
        if self.command(input, 0, (CONFIGURE_EP << 10) | (slot << 24)) == none { return }
        for p in pipes {
            self.listen(p)
            self.pipes.push(p)
            self.note("port ${port}: USB ${p.kind}")
        }
    }

    // ask the endpoint for its next report
    fn listen(self, p: Pipe) {
        p.ring.push(p.buf, p.size, (NORMAL << 10) | 32 | 4)    // tell us when done, also when short
        kernel.poke32(self.db + 4 * p.slot, p.dci)
    }

    // ---- ports ----

    // Set up devices on ports that have one and haven't been looked at (and forget ports that were
    // unplugged). USB 3 ports enable themselves; USB 2 ports need a reset first.
    fn scan(self) {
        for port in 1..self.ports + 1 {
            let sc = self.portsc(port)
            if sc & 0x7e_0000 != 0 { self.set_portsc(port, sc & 0x7e_0000) }    // clear the change bits
            if sc & 1 == 0 {
                if self.attached.contains(port) {
                    self.attached = self.attached.filter(p => p != port)
                    // its slot goes back to the controller (Disable Slot)
                    for p in self.pipes.filter(p => p.port == port) {
                        if !self.pipes.filter(q => q.slot == p.slot && q.port != port).is_empty() { continue }
                        self.command(0, 0, (10 << 10) | (p.slot << 24))
                        kernel.poke64(self.dcbaa + 8 * p.slot, 0)
                        break
                    }
                    self.pipes = self.pipes.filter(p => p.port != port)
                    self.note("port ${port}: unplugged")
                }
                continue
            }
            if self.attached.contains(port) { continue }
            if sc & 2 == 0 {
                self.set_portsc(port, 16)                            // reset
                let until = now_ms() + 300
                while now_ms() < until && self.portsc(port) & (1 << 21) == 0 {}
                self.set_portsc(port, 1 << 21)
                sleep(20)
                if self.portsc(port) & 2 == 0 { continue }           // try again on the next scan
            }
            self.attached.push(port)
            self.attach(port)
        }
    }

    // Reports from keyboards and mice since the last call (and plugging in a device: noticed here).
    fn poll(self) -> [Report] {
        var out: [Report] = []
        var evs = self.stash
        self.stash = []
        var port_changed = false
        while true {
            if let e = self.next_event() {
                if e.kind == TRANSFER_EVENT { evs.push(e) }
                if e.kind == PORT_CHANGE { port_changed = true }
            } else {
                break
            }
        }
        for e in evs {
            for p in self.pipes {
                if p.slot == e.slot && p.dci == e.ep {
                    if e.code == SUCCESS || e.code == SHORT_PACKET {
                        let n = max(p.size - e.left, 0)
                        var data: [int] = []
                        for i in 0..n { data.push(kernel.peek8(p.buf + i)) }
                        out.push(Report { kind: p.kind, data, last: p.last })
                        p.last = data
                        p.errors = 0
                    } else {
                        // a stall or a transmission error halts the endpoint: reset it (a few times;
                        // a device that keeps failing, or was pulled out, is left alone)
                        p.errors += 1
                        if p.errors > 5 { continue }
                        self.reset_ep(p.slot, p.dci, p.ring)
                    }
                    self.listen(p)
                }
            }
        }
        if port_changed || now_ms() >= self.next_scan {
            self.next_scan = now_ms() + 1000
            self.scan()
        }
        return out
    }
}

// Start one controller; none if it doesn't come up.
fn start(f: pci.Function) -> Controller? {
    f.wake()
    f.enable()
    let base = f.bar(0)
    if base == 0 { return none }
    let caplen = kernel.peek8(base)
    if caplen == 0xff || caplen == 0 { return none }
    let p1 = kernel.peek32(base + 4)
    let p2 = kernel.peek32(base + 8)
    let c1 = kernel.peek32(base + 0x10)
    let op = base + caplen
    // take it over from the firmware (USB legacy support: the "BIOS owned" / "OS owned" bits)
    var xp = (c1 >> 16) * 4
    var hops = 0
    while xp != 0 && hops < 64 {
        let cap = kernel.peek32(base + xp)
        if cap & 0xff == 1 {
            kernel.poke32(base + xp, cap | (1 << 24))
            let until = now_ms() + 1000
            while now_ms() < until && kernel.peek32(base + xp) & (1 << 16) != 0 {}
            // a firmware that never lets go: take it anyway
            if kernel.peek32(base + xp) & (1 << 16) != 0 { kernel.poke32(base + xp, (kernel.peek32(base + xp) & ~(1 << 16)) | (1 << 24)) }
            // and no more system management interrupts for USB (the status bits clear when written as 1)
            let ctl = kernel.peek32(base + xp + 4)
            kernel.poke32(base + xp + 4, (ctl & 0x000e_1fee) | 0xe000_0000)
        }
        let next = (cap >> 8) & 0xff
        if next == 0 { break }
        xp += next * 4
        hops += 1
    }
    // stop, then reset
    kernel.poke32(op, kernel.peek32(op) & ~1)
    var until = now_ms() + 100
    while now_ms() < until && kernel.peek32(op + 4) & 1 == 0 {}
    kernel.poke32(op, 2)
    sleep(2)
    until = now_ms() + 1000
    while now_ms() < until && (kernel.peek32(op) & 2 != 0 || kernel.peek32(op + 4) & (1 << 11) != 0) {}
    if kernel.peek32(op) & 2 != 0 { return none }
    let ctx = if c1 & 4 != 0 { 64 } else { 32 }
    let slots = min(p1 & 0xff, 64)
    // 64-bit addresses: the controller must take them if our memory is above 4 GiB
    let probe = kernel.alloc_pages(1)
    if c1 & 1 == 0 && probe >= 1 << 32 { return none }
    let dcbaa = probe
    // scratchpad pages the controller keeps its own state in (real ones ask for them, QEMU doesn't)
    let scratch = (((p2 >> 21) & 31) << 5) | ((p2 >> 27) & 31)
    if scratch > 0 {
        let arr = kernel.alloc_pages(1)
        for i in 0..min(scratch, 512) { kernel.poke64(arr + 8 * i, kernel.alloc_pages(1)) }
        kernel.poke64(dcbaa, arr)
    }
    let c = Controller {
        pci: f, base, op, rt: base + (kernel.peek32(base + 0x18) & ~31), db: base + (kernel.peek32(base + 0x14) & ~3),
        ports: (p1 >> 24) & 0xff, slots, ctx, dcbaa, cmd: ring(), events: kernel.alloc_pages(1),
    }
    kernel.poke32(op + 0x38, slots)                     // CONFIG: slots enabled
    c.set64(op + 0x30, dcbaa)
    c.set64(op + 0x18, c.cmd.base | 1)                  // command ring, cycle 1
    // one event ring segment, on interrupter 0 (polled: interrupts stay off)
    let erst = kernel.alloc_pages(1)
    kernel.poke64(erst, c.events)
    kernel.poke32(erst + 8, RING_TRBS)
    kernel.poke32(c.rt + 0x28, 1)
    c.set64(c.rt + 0x38, c.events)
    c.set64(c.rt + 0x30, erst)
    kernel.poke32(op, 1)                                // run
    until = now_ms() + 100
    while now_ms() < until && kernel.peek32(op + 4) & 1 != 0 {}
    // ports that need power (if the controller switches it per port)
    if c1 & 8 != 0 {
        for port in 1..c.ports + 1 {
            if c.portsc(port) & (1 << 9) == 0 { c.set_portsc(port, 1 << 9) }
        }
    }
    sleep(100)                                          // let the devices connect
    c.scan()
    c.next_scan = now_ms() + 1000
    return some(c)
}

// The USB controllers (xHCI) and the keyboards and mice on them.
struct Usb {
    controllers: [Controller] = [],

    fn poll(self) -> [Report] {
        var out: [Report] = []
        for c in self.controllers {
            for r in c.poll() { out.push(r) }
        }
        return out
    }

    fn devices(self) -> [str] {
        var out: [str] = []
        for c in self.controllers {
            for p in c.pipes { out.push(p.kind) }
        }
        return out
    }
}

// Find the PC's xHCI controllers and start them.
fn open() -> Usb {
    let u = Usb {}
    for f in pci.find(0x0c, 0x03, 0x30) {
        if let c = start(f) { u.controllers.push(c) }
    }
    return u
}
