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
// Hubs work too (external ones, and the internal hubs many laptops put their USB ports and built-in
// keyboard behind): a hub is set up like any device, then its ports are powered and checked every
// second; what's behind them gets a route string (the hub ports on the way) and, for slow devices
// behind a fast hub, the hub that translates for them.
//
// Not here: USB storage or anything else. Nothing is ever written to a USB device except its standard
// setup requests (address, configuration, protocol) and, for hubs, their port requests.

import kernel
import pci
import bytes

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
    where: str,               // root port, then hub ports: "2", "2.1"
    dci: int,                 // device context index: endpoint number * 2 + 1 for IN
    kind: str,
    ring: Ring,
    buf: int,
    size: int,
    last: [int] = [],
    errors: int = 0,
}

// Where a device is: its root port, the route through hubs, and who translates its full/low speed
// for a high-speed hub on the way.
struct Loc {
    root: int,
    route: int = 0,           // 4 bits per hub level: the hub port at each
    depth: int = 0,           // hubs on the way
    speed: int,
    tt_slot: int = 0,
    tt_port: int = 0,
    parent: int = 0,          // the hub's slot (0: a root port)
    parent_port: int = 0,
    where: str,
}

// A device we gave a slot to.
struct Dev {
    slot: int,
    loc: Loc,
}

// A USB network device: an Ethernet adapter (CDC-ECM) or a phone sharing its connection (RNDIS).
// Frames go out on a bulk OUT endpoint and come in on a bulk IN endpoint; RNDIS wraps each in a
// 44-byte header (and may put several in one transfer coming in).
struct NetLink {
    kind: str,
    mac: [int],
    slot: int,
    where: str,
    in_dci: int,
    out_dci: int,
    in_ring: Ring,
    out_ring: Ring,
    out_mps: int,
    rndis: bool,
    rx_by_trb: {int: int} = {},       // receive buffers waiting, by their TRB
    ready: [[int]] = [],              // transfers in: [buffer, length]
    tx_free: [int] = [],
    tx_by_trb: {int: int} = {},
    alive: bool = true,

    fn header(self) -> int { return if self.rndis { 44 } else { 0 } }

    fn buffer(self) -> bytes.Out? {
        if self.tx_free.is_empty() || !self.alive { return none }
        let b = self.tx_free.pop()
        return some(bytes.Out { addr: b + self.header(), cap: 1514 })
    }

    fn release(self, o: bytes.Out) { self.tx_free.push(o.addr - self.header()) }
}

const NET_RX = 8
const NET_RX_SIZE = 16384
const NET_TX = 16

// A hub and its ports.
struct Hub {
    slot: int,
    ep0: Ring,
    loc: Loc,
    ports: int,
    usb3: bool,
    attached: [int] = [],
    buf: int,
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
    devs: [Dev] = [],
    hubs: [Hub] = [],
    links: [NetLink] = [],
    port_changed: bool = false,
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

    // the slot context's first three words for a device at `l`
    fn slot_ctx(self, at: int, l: Loc, entries: int, hub: bool, ports: int, ttt: int) {
        kernel.poke32(at, (entries << 27) | (if hub { 1 << 26 } else { 0 }) | (l.speed << 20) | (l.route & 0xf_ffff))
        kernel.poke32(at + 4, (ports << 24) | (l.root << 16))
        kernel.poke32(at + 8, (ttt << 16) | (l.tt_port << 8) | l.tt_slot)
    }

    // Set up the device at `l`: give it an address, read what it is, and if it has a boot-protocol
    // keyboard or mouse interface, start listening to it; if it's a hub, set up its ports.
    fn attach(self, l: Loc) {
        let speed = l.speed                // 1 full, 2 low, 3 high, 4+ super speed
        let port = l.where
        let done = self.command(0, 0, ENABLE_SLOT << 10)
        if done == none { return }
        let slot = done.unwrap().slot
        if slot < 1 || slot > self.slots { return }
        self.devs.push(Dev { slot, loc: l })
        let out = kernel.alloc_pages(2)
        kernel.poke64(self.dcbaa + 8 * slot, out)
        let input = kernel.alloc_pages(2)
        let ep0 = ring()
        let mps = if speed >= 4 { 512 } else if speed == 3 { 64 } else { 8 }
        kernel.poke32(input + 4, 3)                                            // add: slot, endpoint 0
        let s = self.icx(input, 1)
        self.slot_ctx(s, l, 1, false, 0, 0)
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
        if kernel.peek8(buf + 4) == 9 {
            self.setup_hub(slot, ep0, l, input, buf)
            return
        }
        if self.try_net(slot, ep0, l, input) { return }
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
            pipes.push(Pipe { slot, where: port, dci, kind: if f[1] == 1 { "keyboard" } else { "mouse" }, ring: r, buf: kernel.alloc_pages(1), size })
        }
        kernel.poke32(input + 4, add)
        let s2 = self.icx(input, 1)
        self.slot_ctx(s2, l, last_dci, false, 0, 0)
        if self.command(input, 0, (CONFIGURE_EP << 10) | (slot << 24)) == none { return }
        for p in pipes {
            self.listen(p)
            self.pipes.push(p)
            self.note("port ${port}: USB ${p.kind}")
        }
    }

    // ---- network devices ----

    // Look through the device's configurations for a network function we speak; set it up if so.
    fn try_net(self, slot: int, ep0: Ring, l: Loc, input: int) -> bool {
        let buf = kernel.alloc_pages(1)
        if !self.control(slot, ep0, 0x80, 6, 0x100, 0, 18, buf) { return false }
        let configs = min(max(kernel.peek8(buf + 17), 1), 4)
        // a device may offer several ways (QEMU's usb-net: RNDIS and CDC-ECM): take ECM if it's
        // there, the standard one (phones offer only RNDIS)
        var best: [int] = []
        for ci in 0..configs {
            if !self.control(slot, ep0, 0x80, 6, 0x200 | ci, 0, 9, buf) { continue }
            let total = min(kernel.peek16(buf + 2), 4096)
            if !self.control(slot, ep0, 0x80, 6, 0x200 | ci, 0, total, buf) { continue }
            let f = net_function(buf, total)
            if f.is_empty() { continue }
            if best.is_empty() || (f[0] == 1 && best[0] != 1) { best = f }
        }
        if best.is_empty() { return false }
        return self.setup_net(slot, ep0, l, input, buf, best)
    }

    // f: [kind (1 ECM, 2 RNDIS), configuration, comm interface, data interface, data alt setting,
    //     bulk IN address, its max packet, bulk OUT address, its max packet, MAC string index]
    fn setup_net(self, slot: int, ep0: Ring, l: Loc, input: int, buf: int, f: [int]) -> bool {
        let rndis = f[0] == 2
        let what = if rndis { "phone or RNDIS device" } else { "USB Ethernet (CDC-ECM)" }
        if !self.control(slot, ep0, 0x00, 9, f[1], 0, 0, 0) {
            self.note("port ${l.where}: ${what}: configuration refused")
            return true
        }
        // the two bulk endpoints
        let in_dci = (f[5] & 15) * 2 + 1
        let out_dci = (f[7] & 15) * 2
        let in_ring = ring()
        let out_ring = ring()
        kernel.fill32(input, (self.ctx * 33) / 4, 0)
        kernel.poke32(input + 4, 1 | (1 << in_dci) | (1 << out_dci))
        self.slot_ctx(self.icx(input, 1), l, max(in_dci, out_dci), false, 0, 0)
        for e in [[in_dci, f[6], 6, in_ring.base], [out_dci, f[8], 2, out_ring.base]] {
            let ep = self.icx(input, e[0] + 1)
            kernel.poke32(ep + 4, (e[1] << 16) | (e[2] << 3) | (3 << 1))
            kernel.poke64(ep + 8, e[3] | 1)
            kernel.poke32(ep + 16, 2048)
        }
        if self.command(input, 0, (CONFIGURE_EP << 10) | (slot << 24)) == none {
            self.note("port ${l.where}: ${what}: the controller wouldn't take its endpoints")
            return true
        }
        var mac: [int] = []
        if rndis {
            mac = self.rndis_start(slot, ep0, f[2], buf)
            if mac.is_empty() {
                self.note("port ${l.where}: ${what}: it didn't start (RNDIS)")
                return true
            }
        } else {
            // the data interface's setting with the endpoints, the MAC address (a string), what to receive
            if f[4] != 0 { self.control(slot, ep0, 0x01, 11, f[4], f[3], 0, 0) }
            mac = self.mac_string(slot, ep0, f[9], buf)
            self.control(slot, ep0, 0x21, 0x43, 0x0e, f[2], 0, 0)       // directed, broadcast, all multicast
        }
        let link = NetLink { kind: if rndis { "USB tethering (RNDIS)" } else { "USB Ethernet (CDC-ECM)" }, mac, slot, where: l.where,
            in_dci, out_dci, in_ring, out_ring, out_mps: max(f[8], 8), rndis }
        let txmem = kernel.alloc_pages(NET_TX * 2048 / 4096)
        for i in 0..NET_TX { link.tx_free.push(txmem + 2048 * i) }
        let rxmem = kernel.alloc_pages(NET_RX * NET_RX_SIZE / 4096)
        for i in 0..NET_RX { self.net_listen(link, rxmem + NET_RX_SIZE * i) }
        self.links.push(link)
        self.note("port ${l.where}: ${link.kind}")
        return true
    }

    fn net_listen(self, link: NetLink, b: int) {
        let trb = link.in_ring.push(b, NET_RX_SIZE, (NORMAL << 10) | 32 | 4)
        link.rx_by_trb[trb] = b
        kernel.poke32(self.db + 4 * link.slot, link.in_dci)
    }

    // the MAC address from the string descriptor (12 hex digits); a made-up local one if there is none
    fn mac_string(self, slot: int, ep0: Ring, index: int, buf: int) -> [int] {
        var mac: [int] = []
        if index > 0 && self.control(slot, ep0, 0x80, 6, 0x300 | index, 0x0409, 26, buf) && kernel.peek8(buf) >= 26 {
            var hexs = ""
            for k in 0..12 { hexs += st_chr_x(kernel.peek8(buf + 2 + 2 * k)) }
            for k in 0..6 {
                let v = hex_val(hexs.slice(2 * k, 2 * k + 2))
                if v < 0 {
                    mac = []
                    break
                }
                mac.push(v)
            }
        }
        if mac.len() != 6 { mac = [0x02, 0x53, 0x54, 0x4c, 0x00, slot & 255] }
        return mac
    }

    // RNDIS: initialize, ask the MAC address, set what to receive. [] if it doesn't answer.
    fn rndis_start(self, slot: int, ep0: Ring, comm: int, buf: int) -> [int] {
        // INITIALIZE (we take transfers of up to 16 KiB)
        if self.rndis_call(slot, ep0, comm, buf, [2, 24, 1, 1, 0, NET_RX_SIZE], 0x8000_0002).is_empty() { return [] }
        // QUERY the permanent address (OID_802_3_PERMANENT_ADDRESS)
        let r = self.rndis_call(slot, ep0, comm, buf, [4, 28, 2, 0x0101_0101, 0, 0, 0], 0x8000_0004)
        if r.is_empty() { return [] }
        var mac: [int] = []
        let off = 8 + kernel.peek32(buf + 20)
        if kernel.peek32(buf + 16) >= 6 && off + 6 < 1024 {
            for k in 0..6 { mac.push(kernel.peek8(buf + off + k)) }
        }
        if mac.len() != 6 { return [] }
        // SET the packet filter (OID_GEN_CURRENT_PACKET_FILTER): directed, multicast, broadcast
        self.rndis_call(slot, ep0, comm, buf, [5, 32, 3, 0x0001_010e, 4, 20, 0, 0x0b], 0x8000_0005)
        return mac
    }

    // send an RNDIS message (32-bit words), wait for the reply of type `want`: its words, or [] (the
    // reply's bytes stay in buf)
    fn rndis_call(self, slot: int, ep0: Ring, comm: int, buf: int, words: [int], want: int) -> [int] {
        for k, w in words { kernel.poke32(buf + 4 * k, w) }
        if !self.control(slot, ep0, 0x21, 0x00, 0, comm, 4 * words.len(), buf) { return [] }
        for tries in 0..20 {
            sleep(5)
            if self.control(slot, ep0, 0xa1, 0x01, 0, comm, 1024, buf) && kernel.peek32(buf) == want {
                if kernel.peek32(buf + 12) != 0 { return [] }       // a status other than success
                return [kernel.peek32(buf), kernel.peek32(buf + 4)]
            }
        }
        return []
    }

    // Is this transfer event a network device's? Then take care of it.
    fn route(self, e: Event) -> bool {
        for link in self.links {
            if link.slot != e.slot { continue }
            if e.ep == link.in_dci {
                if let b = link.rx_by_trb.get(e.param) {
                    link.rx_by_trb.remove(e.param)
                    if e.code == SUCCESS || e.code == SHORT_PACKET {
                        link.ready.push([b, NET_RX_SIZE - e.left])
                    } else {
                        self.reset_ep(link.slot, link.in_dci, link.in_ring)
                        self.net_listen(link, b)
                    }
                }
                return true
            }
            if e.ep == link.out_dci {
                if let b = link.tx_by_trb.get(e.param) {
                    link.tx_by_trb.remove(e.param)
                    link.tx_free.push(b)
                }
                if e.code != SUCCESS && e.code != SHORT_PACKET { self.reset_ep(link.slot, link.out_dci, link.out_ring) }
                return true
            }
        }
        return false
    }

    // events now (network transfers taken care of, the rest kept for poll)
    fn pump(self) {
        while true {
            if let e = self.next_event() {
                if e.kind == TRANSFER_EVENT && !self.route(e) { self.stash.push(e) }
                if e.kind == PORT_CHANGE { self.port_changed = true }
            } else {
                break
            }
        }
    }

    fn net_send(self, link: NetLink, o: bytes.Out) -> bool {
        let b = o.addr - link.header()
        if o.full || o.len < 14 {
            link.tx_free.push(b)
            return false
        }
        var len = o.len
        if link.rndis {
            // REMOTE_NDIS_PACKET_MSG: type, length, data offset (from byte 8), data length
            kernel.fill32(b, 11, 0)
            kernel.poke32(b, 1)
            kernel.poke32(b + 4, 44 + len)
            kernel.poke32(b + 8, 36)
            kernel.poke32(b + 12, len)
            len += 44
        }
        // a transfer that's a whole number of packets ends with an empty one (CDC-ECM)
        let zlp = !link.rndis && len % link.out_mps == 0
        let first = link.out_ring.push(b, len, (NORMAL << 10) | (if zlp { 0 } else { 32 }))
        var last = first
        if zlp { last = link.out_ring.push(0, 0, (NORMAL << 10) | 32) }
        link.tx_by_trb[last] = b
        kernel.poke32(self.db + 4 * link.slot, link.out_dci)
        return true
    }

    // frames that came in, each to f; their buffers go back to the device after
    fn net_poll(self, link: NetLink, most: int, f: fn(bytes.View)) -> int {
        self.pump()
        var n = 0
        while !link.ready.is_empty() && n < most {
            let t = link.ready.remove(0)
            let b = t[0]
            let len = t[1]
            if link.rndis {
                var at = 0
                while at + 44 <= len {
                    let mtype = kernel.peek32(b + at)
                    let mlen = kernel.peek32(b + at + 4)
                    if mtype != 1 || mlen < 44 || at + mlen > len { break }
                    let doff = kernel.peek32(b + at + 8)
                    let dlen = kernel.peek32(b + at + 12)
                    if dlen >= 14 && dlen <= 1514 && 8 + doff + dlen <= mlen {
                        f(bytes.View { addr: b + at + 8 + doff, len: dlen })
                        n += 1
                    }
                    at += mlen
                }
            } else if len >= 14 && len <= 1514 {
                f(bytes.View { addr: b, len })
                n += 1
            }
            self.net_listen(link, b)
        }
        return n
    }

    // ---- hubs ----

    // A hub: its configuration, its hub descriptor (how many ports), tell the controller it's a hub,
    // then power its ports and look at them.
    fn setup_hub(self, slot: int, ep0: Ring, l: Loc, input: int, buf: int) {
        let usb3 = l.speed >= 4
        if l.depth >= 5 {
            self.note("hub ${l.where}: too deep (5 hubs in a row is USB's limit)")
            return
        }
        if !self.control(slot, ep0, 0x80, 6, 0x200, 0, 9, buf) { return }
        let config = kernel.peek8(buf + 5)
        if !self.control(slot, ep0, 0x00, 9, config, 0, 0, 0) {
            self.note("hub ${l.where}: configuration refused")
            return
        }
        // the hub descriptor (class request; USB 3 hubs have their own kind)
        if !self.control(slot, ep0, 0xa0, 6, (if usb3 { 0x2a } else { 0x29 }) << 8, 0, 12, buf) {
            self.note("hub ${l.where}: no hub descriptor")
            return
        }
        let ports = min(kernel.peek8(buf + 2), 15)
        let chars = kernel.peek16(buf + 3)
        let good_ms = kernel.peek8(buf + 5) * 2
        // a USB 3 hub needs to know how deep it is (for the route strings of what's behind it)
        if usb3 { self.control(slot, ep0, 0x20, 12, l.depth, 0, 0, 0) }
        // the slot context, now as a hub: its ports, and how long its translator thinks (high speed)
        kernel.fill32(input, (self.ctx * 33) / 4, 0)
        kernel.poke32(input + 4, 1)
        self.slot_ctx(self.icx(input, 1), l, 1, true, ports, if l.speed == 3 { (chars >> 5) & 3 } else { 0 })
        if self.command(input, 0, (CONFIGURE_EP << 10) | (slot << 24)) == none {
            self.note("hub ${l.where}: the controller wouldn't take it as a hub")
            return
        }
        for p in 1..ports + 1 { self.control(slot, ep0, 0x23, 3, 8, p, 0, 0) }     // SET_FEATURE PORT_POWER
        sleep(max(min(good_ms, 500), 20))
        let h = Hub { slot, ep0, loc: l, ports, usb3, buf: kernel.alloc_pages(1) }
        self.hubs.push(h)
        self.note("port ${l.where}: USB${if usb3 { " 3" } else { "" }} hub with ${ports} ports")
        self.scan_hub(h)
    }

    // A hub's ports: devices plugged in get set up, ones pulled out go.
    fn scan_hub(self, h: Hub) {
        for port in 1..h.ports + 1 {
            if !self.control(h.slot, h.ep0, 0xa3, 0, 0, port, 4, h.buf) { continue }   // GET_STATUS
            let status = kernel.peek16(h.buf)
            let change = kernel.peek16(h.buf + 2)
            if change & 1 != 0 { self.control(h.slot, h.ep0, 0x23, 1, 16, port, 0, 0) }  // clear C_PORT_CONNECTION
            let connected = status & 1 != 0
            if !connected {
                if h.attached.contains(port) {
                    h.attached = h.attached.filter(p => p != port)
                    self.detach_behind(h.slot, port)
                    self.note("port ${h.loc.where}.${port}: unplugged")
                }
                continue
            }
            if h.attached.contains(port) { continue }
            // reset the port; when it's done the port is enabled and says the device's speed
            self.control(h.slot, h.ep0, 0x23, 3, 4, port, 0, 0)                          // SET_FEATURE PORT_RESET
            let until = now_ms() + 500
            var st = 0
            while now_ms() < until {
                sleep(10)
                if !self.control(h.slot, h.ep0, 0xa3, 0, 0, port, 4, h.buf) { break }
                st = kernel.peek16(h.buf)
                if st & 0x10 == 0 && st & 2 != 0 { break }
            }
            self.control(h.slot, h.ep0, 0x23, 1, 20, port, 0, 0)                         // clear C_PORT_RESET
            if h.usb3 { self.control(h.slot, h.ep0, 0x23, 1, 29, port, 0, 0) }          // and C_BH_PORT_RESET
            if st & 2 == 0 { continue }                                                  // not enabled: next time
            sleep(10)
            let speed = if h.usb3 { 4 } else if st & 0x200 != 0 { 2 } else if st & 0x400 != 0 { 3 } else { 1 }
            // full/low speed behind a high-speed hub: that hub's translator does the talking
            var tt_slot = h.loc.tt_slot
            var tt_port = h.loc.tt_port
            if speed < 3 && h.loc.speed == 3 {
                tt_slot = h.slot
                tt_port = port
            }
            h.attached.push(port)
            self.attach(Loc { root: h.loc.root, route: h.loc.route | (min(port, 15) << (4 * h.loc.depth)), depth: h.loc.depth + 1,
                speed, tt_slot, tt_port, parent: h.slot, parent_port: port, where: "${h.loc.where}.${port}" })
        }
    }

    // Give back a device's slot, and everything behind it if it's a hub.
    fn detach(self, slot: int) {
        for h in self.hubs.filter(h => h.slot == slot) {
            for port in h.attached { self.detach_behind(slot, port) }
        }
        self.hubs = self.hubs.filter(h => h.slot != slot)
        self.pipes = self.pipes.filter(p => p.slot != slot)
        for k in self.links.filter(k => k.slot == slot) { k.alive = false }
        self.links = self.links.filter(k => k.slot != slot)
        self.devs = self.devs.filter(d => d.slot != slot)
        self.command(0, 0, (10 << 10) | (slot << 24))                                      // Disable Slot
        kernel.poke64(self.dcbaa + 8 * slot, 0)
    }

    fn detach_behind(self, hub: int, port: int) {
        for d in self.devs.filter(d => d.loc.parent == hub && d.loc.parent_port == port) { self.detach(d.slot) }
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
                    // its slot (and a hub's devices') go back to the controller
                    for d in self.devs.filter(d => d.loc.root == port && d.loc.parent == 0) { self.detach(d.slot) }
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
            self.attach(Loc { root: port, speed: (self.portsc(port) >> 10) & 15, where: "${port}" })
        }
        // and the hubs' ports
        for h in self.hubs.slice(0, self.hubs.len()) {
            if self.hubs.any(x => x.slot == h.slot) { self.scan_hub(h) }
        }
    }

    // Reports from keyboards and mice since the last call (and plugging in a device: noticed here).
    fn poll(self) -> [Report] {
        var out: [Report] = []
        self.pump()
        var evs = self.stash
        self.stash = []
        let port_changed = self.port_changed
        self.port_changed = false
        for e in evs {
            if self.route(e) { continue }
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

    // the first network device on any controller
    fn net(self) -> NetLink? {
        for c in self.controllers {
            for l in c.links {
                if l.alive { return some(l) }
            }
        }
        return none
    }

    fn owner(self, link: NetLink) -> Controller? {
        for c in self.controllers {
            if c.links.any(k => k.slot == link.slot && k.in_dci == link.in_dci) { return some(c) }
        }
        return none
    }

    fn net_send(self, link: NetLink, o: bytes.Out) -> bool {
        if let c = self.owner(link) { return c.net_send(link, o) }
        link.release(o)
        return false
    }

    fn net_poll(self, link: NetLink, most: int, f: fn(bytes.View)) -> int {
        if let c = self.owner(link) { return c.net_poll(link, most, f) }
        return 0
    }

    fn devices(self) -> [str] {
        var out: [str] = []
        for c in self.controllers {
            for p in c.pipes { out.push(p.kind) }
            for l in c.links { out.push(l.kind) }
            for h in c.hubs { out.push("hub (${h.ports} ports)") }
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

// The network function in a configuration descriptor (buf, total bytes), as setup_net wants it, or [].
fn net_function(buf: int, total: int) -> [int] {
    let config = kernel.peek8(buf + 5)
    var kind = 0
    var comm = -1
    var data = -1
    var data_alt = 0
    var mac_index = 0
    var in_ep = [0, 0]
    var out_ep = [0, 0]
    var iface = -1
    var alt = 0
    var cls = 0
    var at = 0
    while at + 2 <= total {
        let len = kernel.peek8(buf + at)
        let t = kernel.peek8(buf + at + 1)
        if len < 2 { break }
        if t == 4 && len >= 9 {
            iface = kernel.peek8(buf + at + 2)
            alt = kernel.peek8(buf + at + 3)
            cls = kernel.peek8(buf + at + 5)
            let sub = kernel.peek8(buf + at + 6)
            let proto = kernel.peek8(buf + at + 7)
            if kind == 0 && cls == 2 && sub == 6 {
                kind = 1
                comm = iface
            } else if kind == 0 && ((cls == 0xe0 && sub == 1 && proto == 3) || (cls == 2 && sub == 2 && proto == 0xff)) {
                kind = 2
                comm = iface
            }
        } else if t == 0x24 && len >= 4 && iface == comm && kind == 1 && kernel.peek8(buf + at + 2) == 0x0f {
            mac_index = kernel.peek8(buf + at + 3)        // the Ethernet functional descriptor
        } else if t == 5 && len >= 7 && kind != 0 && cls == 0x0a {
            let addr = kernel.peek8(buf + at + 2)
            if kernel.peek8(buf + at + 3) & 3 == 2 {      // bulk
                let mps = kernel.peek16(buf + at + 4) & 0x7ff
                if addr & 0x80 != 0 { in_ep = [addr, mps] } else { out_ep = [addr, mps] }
                data = iface
                data_alt = alt
            }
        }
        at += len
    }
    if kind == 0 || data < 0 || in_ep[0] == 0 || out_ep[0] == 0 { return [] }
    return [kind, config, comm, data, data_alt, in_ep[0], in_ep[1], out_ep[0], out_ep[1], mac_index]
}

extern fn st_chr(code: int) -> str
fn st_chr_x(c: int) -> str { return st_chr(c) }

fn hex_val(s: str) -> int {
    var v = 0
    for c in s.lower().chars() {
        let d = "0123456789abcdef".find(c)
        if d < 0 { return -1 }
        v = v * 16 + d
    }
    return v
}
