// The network card: a driver for virtio-net (QEMU's virtio-net-device), written in stellang.
// It moves Ethernet frames: the device fills receive buffers we lend it, and sends the buffers we
// offer on the transmit queue. Each buffer starts with a 12-byte virtio header (all zeros: no
// checksum offloading, no segmentation; the stack does all of that itself).

import kernel
import virtio
import bytes

const HEADER = 12
const FRAME = 1514            // the biggest Ethernet frame without its checksum
const BUF = 2048
const RX = 32                 // receive buffers lent to the device
const TX = 32                 // transmit buffers
const F_MAC = 1 << 5

struct Nic {
    dev: virtio.Device,
    rx: virtio.Queue,
    tx: virtio.Queue,
    mac: [int],
    spare: [int] = [],        // transmit buffers not in use
    received: int = 0,
    sent: int = 0,
    dropped: int = 0,         // couldn't send: no buffer free

    // A buffer to build a frame in (call `send` or `release` with it after), if one is free.
    fn buffer(self) -> bytes.Out? {
        self.reclaim()
        if self.spare.is_empty() {
            self.dropped += 1
            return none
        }
        let b = self.spare.pop()
        return some(bytes.Out { addr: b + HEADER, cap: FRAME })
    }

    fn send(self, o: bytes.Out) {
        let b = o.addr - HEADER
        if o.full || o.len < 14 {
            self.release(o)
            return
        }
        kernel.fill32(b, HEADER / 4, 0)
        // Ethernet's minimum is 60 bytes; pad short frames with zeros (not old memory)
        var len = o.len
        while len < 60 {
            kernel.poke8(o.addr + len, 0)
            len += 1
        }
        if self.tx.offer([virtio.Buf { addr: b, len: HEADER + len, writable: false }]) < 0 {
            self.spare.push(b)
            self.dropped += 1
            return
        }
        self.tx.notify()
        self.sent += 1
    }

    fn release(self, o: bytes.Out) {
        self.spare.push(o.addr - HEADER)
    }

    // transmit buffers the device is done with
    fn reclaim(self) {
        while true {
            if let u = self.tx.take() {
                self.spare.push(self.tx.addr_of(u.head))
            } else {
                break
            }
        }
    }

    // Hand each frame that arrived to `f` (only during the call: the buffer goes back to the device
    // right after), at most `most` of them.
    fn poll(self, most: int, f: fn(bytes.View)) -> int {
        var n = 0
        while n < most {
            if let u = self.rx.take() {
                let b = self.rx.addr_of(u.head)
                if u.len > HEADER && u.len <= BUF {
                    self.received += 1
                    f(bytes.View { addr: b + HEADER, len: u.len - HEADER })
                }
                self.lend(b)
                n += 1
            } else {
                break
            }
        }
        if n > 0 { self.rx.notify() }
        return n
    }

    fn lend(self, b: int) {
        self.rx.offer([virtio.Buf { addr: b, len: BUF, writable: true }])
    }
}

// The first network card QEMU has, if any.
fn open() -> Nic? {
    for d in virtio.find(virtio.NET) {
        if !d.start(F_MAC) { continue }
        let rx = d.queue(0, RX) catch e { continue }
        let tx = d.queue(1, TX) catch e { continue }
        var mac: [int] = []
        for i in 0..6 { mac.push(d.config8(i)) }
        let n = Nic { dev: d, rx, tx, mac }
        let rxmem = kernel.alloc_pages(RX * BUF / 4096)
        for i in 0..RX { n.lend(rxmem + i * BUF) }
        let txmem = kernel.alloc_pages(TX * BUF / 4096)
        for i in 0..TX { n.spare.push(txmem + i * BUF) }
        d.go()
        n.rx.notify()
        return some(n)
    }
    return none
}
