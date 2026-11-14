// i2c: the I²C controllers in Intel laptops (Synopsys DesignWare cores, inside Intel's "LPSS"),
// written in stellang. Touchpads hang off them (touchpad.st). Polled: no interrupts.
//
// A transfer is a list of commands in the controller's TX FIFO: bytes to write, then read requests
// (the first after a repeated START, the last with STOP); what's read comes back in the RX FIFO.

import kernel
import pci

const CON = 0x00
const TAR = 0x04
const DATA_CMD = 0x10
const SS_HCNT = 0x14
const SS_LCNT = 0x18
const FS_HCNT = 0x1c
const FS_LCNT = 0x20
const INTR_MASK = 0x30
const RAW_INTR = 0x34
const RX_TL = 0x38
const TX_TL = 0x3c
const CLR_INTR = 0x40
const CLR_TX_ABRT = 0x54
const CLR_STOP = 0x60
const ENABLE = 0x6c
const STATUS = 0x70
const TXFLR = 0x74
const RXFLR = 0x78
const ABRT_SOURCE = 0x80
const ENABLE_STATUS = 0x9c
const COMP_PARAM = 0xf4
const COMP_TYPE = 0xfc
const DESIGNWARE = 0x4457_0140

const READ = 0x100
const STOP = 0x200
const RESTART = 0x400

struct Bus {
    f: pci.Function,
    base: int,
    tx_depth: int,
    rx_depth: int,
    target: int = -1,
    fast: bool = true,
    errors: int = 0,
    last_error: str = "",

    fn r(self, off: int) -> int { return kernel.peek32(self.base + off) }
    fn w(self, off: int, v: int) { kernel.poke32(self.base + off, v) }

    fn disable(self) {
        self.w(ENABLE, 0)
        let until = now_ms() + 50
        while now_ms() < until && self.r(ENABLE_STATUS) & 1 != 0 {}
    }

    // Talk to the device at `addr` (7-bit) from now on; fast mode (400 kHz) or standard (100 kHz).
    fn select(self, addr: int, fast: bool) {
        if self.target == addr && self.fast == fast { return }
        self.disable()
        // master, the speed, repeated START allowed, not a slave
        self.w(CON, 1 | (if fast { 2 } else { 1 }) << 1 | 0x20 | 0x40)
        self.w(TAR, addr & 0x7f)
        self.w(INTR_MASK, 0)
        self.w(RX_TL, 0)
        self.w(TX_TL, 0)
        self.w(ENABLE, 1)
        self.target = addr
        self.fast = fast
    }

    // Write `out`, then read `n` bytes (either may be empty). None if the device didn't answer
    // (no acknowledge, or it took too long).
    fn xfer(self, addr: int, out: [int], n: int, fast: bool) -> [int]? {
        self.select(addr, fast)
        self.r(CLR_INTR)
        var cmds: [int] = []
        for k, b in out { cmds.push((b & 0xff) | (if k == out.len() - 1 && n == 0 { STOP } else { 0 })) }
        for k in 0..n {
            var c = READ
            if k == 0 && !out.is_empty() { c = c | RESTART }
            if k == n - 1 { c = c | STOP }
            cmds.push(c)
        }
        var got: [int] = []
        var sent = 0
        var reads_sent = 0
        let until = now_ms() + 20 + n / 4
        while now_ms() < until {
            // stop on an abort (nobody answered the address, or a byte wasn't acknowledged)
            if self.r(RAW_INTR) & 0x40 != 0 {
                let why = self.r(ABRT_SOURCE)
                self.r(CLR_TX_ABRT)
                self.errors += 1
                self.last_error = "abort 0x${hex(why)} at 0x${hex(addr)}"
                return none
            }
            // queue commands while there's room (and the RX FIFO won't overflow)
            while sent < cmds.len() && self.r(TXFLR) < self.tx_depth {
                let c = cmds[sent]
                if c & READ != 0 && reads_sent - got.len() >= self.rx_depth - 1 { break }
                self.w(DATA_CMD, c)
                if c & READ != 0 { reads_sent += 1 }
                sent += 1
            }
            while self.r(RXFLR) > 0 && got.len() < n { got.push(self.r(DATA_CMD) & 0xff) }
            if sent == cmds.len() && got.len() == n && (self.r(RAW_INTR) & 0x200 != 0 || self.r(STATUS) & 0x20 == 0) {
                self.r(CLR_STOP)
                return some(got)
            }
        }
        self.errors += 1
        self.last_error = "timeout at 0x${hex(addr)}"
        // a stuck transfer: start over clean
        self.target = -1
        self.disable()
        return none
    }
}

fn hex(v: int) -> str {
    let d = "0123456789abcdef"
    var s = ""
    var x = v & 0xffff_ffff
    if x == 0 { return "0" }
    while x > 0 {
        s = d[x & 15] + s
        x = x >> 4
    }
    return s
}

// Where Intel puts its I²C controllers (PCI device numbers on bus 0: I2C0-3, I2C4-5, I2C6-7). Only
// these are ever touched: the same PCI class also holds the SPI controller for the firmware's flash
// (device 0x1f), which must be left alone.
const SLOTS = [0x15, 0x19, 0x10]

fn allowed(f: pci.Function) -> bool { return f.bus == 0 && SLOTS.contains(f.dev) && f.vendor == 0x8086 }

// Start a controller: wake it, take it out of reset, check it's a DesignWare core, set the clock.
fn open(f: pci.Function) -> Bus? {
    if !allowed(f) { return none }
    f.wake()
    f.enable()
    let base = f.bar(0)
    if base == 0 { return none }
    // Intel's LPSS wrapper keeps the core in reset until told otherwise
    if kernel.peek32(base + COMP_TYPE) != DESIGNWARE {
        kernel.poke32(base + 0x204, 7)
        sleep(1)
    }
    if kernel.peek32(base + COMP_TYPE) != DESIGNWARE { return none }
    let param = kernel.peek32(base + COMP_PARAM)
    let b = Bus { f, base, tx_depth: max(((param >> 16) & 0xff) + 1, 2), rx_depth: max(((param >> 8) & 0xff) + 1, 2) }
    b.disable()
    // SCL timing in input clock cycles, for the fastest clock these cores get (216 MHz): with a
    // slower clock the bus just runs slower (still in spec)
    b.w(SS_HCNT, 900)
    b.w(SS_LCNT, 1060)
    b.w(FS_HCNT, 200)
    b.w(FS_LCNT, 360)
    return some(b)
}

// Intel's I²C controllers on the PCI bus (serial bus controllers, "other" kind, from Intel).
fn controllers() -> [pci.Function] {
    return pci.all().filter(f => allowed(f) && f.class == 0x0c && f.subclass == 0x80)
}
