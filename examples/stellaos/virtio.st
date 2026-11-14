// virtio: how QEMU's devices (disks, network cards, keyboards, tablets, ...) talk to a kernel.
// This is the transport ("virtio-mmio", version 2) and the shared queues; the device drivers
// (input.st, ...) sit on top. Everything here is registers (kernel.peek/poke) and memory the device
// reads and writes itself (kernel.alloc_pages).
//
// A queue is three arrays in memory: descriptors (buffers: address, length, flags), the "available"
// ring where the driver offers descriptors to the device, and the "used" ring where the device gives
// them back, filled in.

import kernel

const MMIO = 0x1000_1000      // the first of QEMU virt's 8 virtio-mmio slots; each is 0x1000 apart
const SLOTS = 8

// device kinds
const NET = 1
const BLOCK = 2
const CONSOLE = 3
const RNG = 4
const GPU = 16
const INPUT = 18

// registers (offsets in a slot)
const MAGIC = 0x000
const VERSION = 0x004
const DEVICE_ID = 0x008
const DEVICE_FEATURES = 0x010
const DEVICE_FEATURES_SEL = 0x014
const DRIVER_FEATURES = 0x020
const DRIVER_FEATURES_SEL = 0x024
const QUEUE_SEL = 0x030
const QUEUE_NUM_MAX = 0x034
const QUEUE_NUM = 0x038
const QUEUE_READY = 0x044
const QUEUE_NOTIFY = 0x050
const STATUS = 0x070
const QUEUE_DESC = 0x080
const QUEUE_DRIVER = 0x090
const QUEUE_DEVICE = 0x0a0
const CONFIG = 0x100

// status bits
const ACKNOWLEDGE = 1
const DRIVER = 2
const DRIVER_OK = 4
const FEATURES_OK = 8

// descriptor flags
const NEXT = 1
const WRITE = 2               // the device writes this buffer (else it reads it)

struct Device {
    base: int,                // its registers
    irq: int,                 // its interrupt line (PLIC source)
    kind: int,

    fn reg(self, off: int) -> int { return kernel.peek32(self.base + off) }
    fn set(self, off: int, v: int) { kernel.poke32(self.base + off, v) }

    // Reset the device and agree on features: the ones it offers out of `wanted` (bits 0..63; the
    // VERSION_1 bit, 32, is always asked for). Returns false if the device won't go along.
    fn start(self, wanted: int) -> bool {
        self.set(STATUS, 0)
        self.set(STATUS, ACKNOWLEDGE)
        self.set(STATUS, ACKNOWLEDGE | DRIVER)
        self.set(DEVICE_FEATURES_SEL, 0)
        let lo = self.reg(DEVICE_FEATURES) & wanted & 0xffff_ffff
        self.set(DEVICE_FEATURES_SEL, 1)
        let hi = self.reg(DEVICE_FEATURES) & ((wanted >> 32) | 1)
        self.set(DRIVER_FEATURES_SEL, 0)
        self.set(DRIVER_FEATURES, lo)
        self.set(DRIVER_FEATURES_SEL, 1)
        self.set(DRIVER_FEATURES, hi)
        self.set(STATUS, ACKNOWLEDGE | DRIVER | FEATURES_OK)
        return self.reg(STATUS) & FEATURES_OK != 0
    }

    // Set up queue `index` with (at most) `size` buffers.
    fn queue(self, index: int, size: int) -> Queue! {
        self.set(QUEUE_SEL, index)
        let most = self.reg(QUEUE_NUM_MAX)
        if most == 0 { return err("virtio: the device has no queue ${index}") }
        let n = min(size, most)
        // descriptors and the available ring in one page, the used ring in the next
        let mem = kernel.alloc_pages(2)
        let q = Queue { dev: self, index, size: n, desc: mem, avail: mem + 16 * n, used: mem + 4096 }
        for i in 0..n { q.free.push(i) }
        self.set(QUEUE_NUM, n)
        self.set64(QUEUE_DESC, q.desc)
        self.set64(QUEUE_DRIVER, q.avail)
        self.set64(QUEUE_DEVICE, q.used)
        self.set(QUEUE_READY, 1)
        return q
    }

    fn set64(self, off: int, v: int) {
        self.set(off, v & 0xffff_ffff)
        self.set(off + 4, v >> 32)
    }

    // Done setting up: the device may start working (and interrupting).
    fn go(self) {
        self.set(STATUS, self.reg(STATUS) | DRIVER_OK)
        kernel.irq_enable(self.irq)
    }

    // device-specific configuration space
    fn config8(self, off: int) -> int { return kernel.peek8(self.base + CONFIG + off) }
    fn config32(self, off: int) -> int { return kernel.peek32(self.base + CONFIG + off) }
    fn set_config8(self, off: int, v: int) { kernel.poke8(self.base + CONFIG + off, v) }
}

// A buffer handed to the device: `len` bytes at `addr`; `writable` if the device fills it.
struct Buf {
    addr: int,
    len: int,
    writable: bool,
}

// What the device gave back: the first descriptor of a chain, and how many bytes it wrote.
struct Used {
    head: int,
    len: int,
}

struct Queue {
    dev: Device,
    index: int,
    size: int,
    desc: int,
    avail: int,
    used: int,
    seen: int = 0,            // used-ring entries already taken
    free: [int] = [],         // descriptors not in use

    // Offer a chain of buffers to the device (call `notify` after). Returns its head descriptor, or
    // -1 when the queue is full.
    fn offer(self, bufs: [Buf]) -> int {
        if self.free.len() < bufs.len() || bufs.is_empty() { return -1 }
        var ids: [int] = []
        for b in bufs { ids.push(self.free.pop()) }
        for i, b in bufs {
            let d = self.desc + 16 * ids[i]
            kernel.poke64(d, b.addr)
            kernel.poke32(d + 8, b.len)
            var flags = if b.writable { WRITE } else { 0 }
            if i + 1 < bufs.len() { flags = flags | NEXT }
            kernel.poke16(d + 12, flags)
            kernel.poke16(d + 14, if i + 1 < bufs.len() { ids[i + 1] } else { 0 })
        }
        let idx = kernel.peek16(self.avail + 2)
        kernel.poke16(self.avail + 4 + 2 * (idx % self.size), ids[0])
        kernel.poke16(self.avail + 2, (idx + 1) & 0xffff)   // the device may look now
        return ids[0]
    }

    fn notify(self) {
        self.dev.set(QUEUE_NOTIFY, self.index)
    }

    // The next chain the device is done with, if any. Its descriptors become free again.
    fn take(self) -> Used? {
        let idx = kernel.peek16(self.used + 2)
        if idx == self.seen { return none }
        let e = self.used + 4 + 8 * (self.seen % self.size)
        let u = Used { head: kernel.peek32(e), len: kernel.peek32(e + 4) }
        self.seen = (self.seen + 1) & 0xffff
        var d = u.head
        while true {
            self.free.push(d)
            let flags = kernel.peek16(self.desc + 16 * d + 12)
            if flags & NEXT == 0 { break }
            d = kernel.peek16(self.desc + 16 * d + 14)
        }
        return some(u)
    }

    // the address a descriptor points at
    fn addr_of(self, d: int) -> int {
        return kernel.peek64(self.desc + 16 * d)
    }
}

// Every device of a kind (INPUT, BLOCK, ...) QEMU plugged in.
fn find(kind: int) -> [Device] {
    var out: [Device] = []
    if kernel.arch() != "riscv64" { return out }      // virtio-mmio is QEMU virt's
    for slot in 0..SLOTS {
        let base = MMIO + slot * 0x1000
        if kernel.peek32(base + MAGIC) != 0x7472_6976 { continue }   // "virt"
        if kernel.peek32(base + VERSION) != 2 { continue }           // legacy devices: not supported
        if kernel.peek32(base + DEVICE_ID) == kind {
            out.push(Device { base, irq: slot + 1, kind })
        }
    }
    return out
}
