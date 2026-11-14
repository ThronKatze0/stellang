// e1000: Intel's Ethernet controllers, written in stellang: the classic e1000 descriptor rings,
// which Intel kept through the 82574 (QEMU's e1000e) to the I217/I219 that laptops and desktops have
// built in. Polled, like everything here.
//
// The card reads frames to send from a ring of transmit descriptors and writes frames it receives
// into buffers named by a ring of receive descriptors; head and tail registers say whose turn it is.

import kernel
import pci
import bytes

const CTRL = 0x0000
const STATUS = 0x0008
const IMC = 0x00d8
const RCTL = 0x0100
const TCTL = 0x0400
const TIPG = 0x0410
const RDBAL = 0x2800
const RDBAH = 0x2804
const RDLEN = 0x2808
const RDH = 0x2810
const RDT = 0x2818
const TDBAL = 0x3800
const TDBAH = 0x3804
const TDLEN = 0x3808
const TDH = 0x3810
const TDT = 0x3818
const MTA = 0x5200
const RAL = 0x5400
const RAH = 0x5404

const N = 32                  // descriptors per ring
const BUF = 2048

struct Card {
    f: pci.Function,
    base: int,
    rx: int,                  // the rings (16-byte descriptors)
    tx: int,
    rx_bufs: [int] = [],
    tx_bufs: [int] = [],
    rx_next: int = 0,
    tx_next: int = 0,
    tx_clean: int = 0,
    mac: [int] = [],
    model: str = "",

    fn r(self, off: int) -> int { return kernel.peek32(self.base + off) }
    fn w(self, off: int, v: int) { kernel.poke32(self.base + off, v) }

    fn link(self) -> bool { return self.r(STATUS) & 2 != 0 }

    // A buffer to build a frame in, if a transmit descriptor is free.
    fn buffer(self) -> bytes.Out? {
        // descriptors the card is done with (DD: descriptor done)
        while self.tx_clean != self.tx_next && kernel.peek8(self.tx + 16 * self.tx_clean + 12) & 1 != 0 {
            self.tx_clean = (self.tx_clean + 1) % N
        }
        if (self.tx_next + 1) % N == self.tx_clean { return none }
        return some(bytes.Out { addr: self.tx_bufs[self.tx_next], cap: 1514 })
    }

    fn send(self, o: bytes.Out) -> bool {
        if o.full || o.len < 14 { return false }
        var len = o.len
        while len < 60 {
            kernel.poke8(o.addr + len, 0)
            len += 1
        }
        let d = self.tx + 16 * self.tx_next
        kernel.poke64(d, o.addr)
        // length, then command: end of packet (1), insert the checksum (2), report status (8)
        kernel.poke64(d + 8, len | (0x0b << 24))
        self.tx_next = (self.tx_next + 1) % N
        self.w(TDT, self.tx_next)
        return true
    }

    // frames that arrived: f gets each (only during the call)
    fn poll(self, most: int, f: fn(bytes.View)) -> int {
        var n = 0
        while n < most {
            let d = self.rx + 16 * self.rx_next
            let status = kernel.peek8(d + 12)
            if status & 1 == 0 { break }
            let len = kernel.peek16(d + 8)
            let errors = kernel.peek8(d + 13)
            // a whole frame (EOP), without errors
            if status & 2 != 0 && errors == 0 && len >= 14 && len <= BUF { f(bytes.View { addr: self.rx_bufs[self.rx_next], len }) }
            kernel.poke64(d + 8, 0)
            self.w(RDT, self.rx_next)          // the descriptor is the card's again
            self.rx_next = (self.rx_next + 1) % N
            n += 1
        }
        return n
    }
}

// Intel's Ethernet controllers we know to speak the classic rings
fn known(f: pci.Function) -> str {
    if f.vendor != 0x8086 || f.class != 0x02 || f.subclass != 0x00 { return "" }
    let d = f.device
    if d == 0x100e || d == 0x100f || d == 0x10d3 { return if d == 0x10d3 { "82574 (e1000e)" } else { "8254x (e1000)" } }
    // I217, I218, I219 (the PCH's own Ethernet, at 00:1f.6)
    let i21x = [0x153a, 0x153b, 0x155a, 0x1559, 0x15a0, 0x15a1, 0x15a2, 0x15a3, 0x156f, 0x1570, 0x15b7, 0x15b8, 0x15b9,
        0x15bb, 0x15bc, 0x15bd, 0x15be, 0x15d6, 0x15d7, 0x15d8, 0x15e3, 0x15df, 0x15e0, 0x15e1, 0x15e2, 0x0d4e, 0x0d4f,
        0x0d4c, 0x0d4d, 0x0d53, 0x0d55, 0x15f9, 0x15fa, 0x15fb, 0x15fc, 0x1a1e, 0x1a1f, 0x1a1c, 0x1a1d, 0x0dc5, 0x0dc6,
        0x0dc7, 0x0dc8, 0x550a, 0x550b, 0x550c, 0x550d, 0x550e, 0x550f, 0x5510, 0x5511, 0x57a0, 0x57a1]
    if i21x.contains(d) { return "I21x (built-in)" }
    return ""
}

// Start a card: its MAC address (the firmware left it in the first receive address), the rings,
// receiving and sending on.
fn start(f: pci.Function) -> Card? {
    let model = known(f)
    if model == "" { return none }
    f.wake()
    f.enable()
    let base = f.bar(0)
    if base == 0 { return none }
    let c = Card { f, base, rx: kernel.alloc_pages(1), tx: kernel.alloc_pages(1), model }
    c.w(IMC, 0xffff_ffff)                          // no interrupts
    // the 8254x/82574 get a full reset; the PCH's own (I21x) keep their PHY setup from the firmware
    if !model.starts_with("I21x") {
        c.w(CTRL, c.r(CTRL) | (1 << 26))
        sleep(10)
        let until = now_ms() + 100
        while now_ms() < until && c.r(CTRL) & (1 << 26) != 0 {}
        c.w(IMC, 0xffff_ffff)
    }
    c.w(CTRL, (c.r(CTRL) | 0x60) & ~((1 << 3) | (1 << 31)))   // set link up, auto speed; no reset of the link or PHY
    let lo = c.r(RAL)
    let hi = c.r(RAH)
    c.mac = [lo & 255, (lo >> 8) & 255, (lo >> 16) & 255, (lo >> 24) & 255, hi & 255, (hi >> 8) & 255]
    if c.mac.all(b => b == 0) || c.mac.all(b => b == 255) { return none }
    c.w(RAH, hi | (1 << 31))                        // that address is valid
    for i in 0..128 { c.w(MTA + 4 * i, 0) }
    // receive ring
    let rxmem = kernel.alloc_pages(N * BUF / 4096)
    for i in 0..N {
        let b = rxmem + i * BUF
        c.rx_bufs.push(b)
        kernel.poke64(c.rx + 16 * i, b)
        kernel.poke64(c.rx + 16 * i + 8, 0)
    }
    c.w(RDBAL, c.rx & 0xffff_ffff)
    c.w(RDBAH, c.rx >> 32)
    c.w(RDLEN, N * 16)
    c.w(RDH, 0)
    c.w(RDT, N - 1)
    // receive on, broadcasts too, 2 KiB buffers, strip the Ethernet CRC
    c.w(RCTL, 2 | (1 << 15) | (1 << 26))
    // transmit ring
    let txmem = kernel.alloc_pages(N * BUF / 4096)
    for i in 0..N { c.tx_bufs.push(txmem + i * BUF) }
    c.w(TDBAL, c.tx & 0xffff_ffff)
    c.w(TDBAH, c.tx >> 32)
    c.w(TDLEN, N * 16)
    c.w(TDH, 0)
    c.w(TDT, 0)
    // transmit on, pad short frames, the usual collision settings and gaps
    c.w(TCTL, 2 | (1 << 3) | (0x0f << 4) | (0x40 << 12))
    c.w(TIPG, 0x0060_200a)
    return some(c)
}

fn open() -> Card? {
    for f in pci.all() {
        if known(f) != "" {
            if let c = start(f) { return some(c) }
        }
    }
    return none
}
