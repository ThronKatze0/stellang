// The network card the stack (inet.st) uses: one of
//   virtio-net    QEMU's virtual card (below)
//   e1000         Intel's Ethernet, built into many PCs (e1000.st)
//   USB           USB Ethernet adapters (CDC-ECM) and phones sharing their connection over USB
//                 (Android's USB tethering: RNDIS), through the xHCI controller (xhci.st)
// Each moves Ethernet frames; the stack does everything above that.
//
// virtio-net: the device fills receive buffers we lend it, and sends the buffers we offer on the
// transmit queue. Each buffer starts with a 12-byte virtio header (all zeros: no checksum
// offloading, no segmentation).

import kernel
import virtio
import bytes
import e1000
import xhci

const HEADER = 12
const FRAME = 1514            // the biggest Ethernet frame without its checksum
const BUF = 2048
const RX = 32                 // receive buffers lent to the device
const TX = 32                 // transmit buffers
const F_MAC = 1 << 5

struct Nic {
    kind: str,                // "virtio-net", the e1000's model, "USB Ethernet (CDC-ECM)", ...
    mac: [int],
    virt: Virtio? = none,
    e1k: e1000.Card? = none,
    usb: xhci.NetLink? = none,
    usb_host: xhci.Usb? = none,
    received: int = 0,
    sent: int = 0,
    dropped: int = 0,

    fn buffer(self) -> bytes.Out? {
        var o: bytes.Out? = none
        if let v = self.virt { o = v.buffer() }
        if let c = self.e1k { o = c.buffer() }
        if let u = self.usb { o = u.buffer() }
        if o.is_none() { self.dropped += 1 }
        return o
    }

    fn send(self, o: bytes.Out) {
        var sent_ok = false
        if let v = self.virt { sent_ok = v.send(o) }
        if let c = self.e1k { sent_ok = c.send(o) }
        if let u = self.usb {
            if let h = self.usb_host { sent_ok = h.net_send(u, o) }
        }
        if sent_ok { self.sent += 1 } else { self.dropped += 1 }
    }

    fn release(self, o: bytes.Out) {
        if let v = self.virt { v.release(o) }
        if let u = self.usb { u.release(o) }
    }

    fn poll(self, most: int, f: fn(bytes.View)) -> int {
        var n = 0
        if let v = self.virt { n = v.poll(most, f) }
        if let c = self.e1k { n = c.poll(most, f) }
        if let u = self.usb {
            if let h = self.usb_host { n = h.net_poll(u, most, f) }
        }
        self.received += n
        return n
    }

    fn link(self) -> bool {
        if let c = self.e1k { return c.link() }
        return true
    }
}

struct Virtio {
    dev: virtio.Device,
    rx: virtio.Queue,
    tx: virtio.Queue,
    mac: [int],
    spare: [int] = [],        // transmit buffers not in use

    // A buffer to build a frame in (call `send` or `release` with it after), if one is free.
    fn buffer(self) -> bytes.Out? {
        self.reclaim()
        if self.spare.is_empty() { return none }
        let b = self.spare.pop()
        return some(bytes.Out { addr: b + HEADER, cap: FRAME })
    }

    fn send(self, o: bytes.Out) -> bool {
        let b = o.addr - HEADER
        if o.full || o.len < 14 {
            self.release(o)
            return false
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
            return false
        }
        self.tx.notify()
        return true
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

// The first virtio network card QEMU has, if any.
fn open_virtio() -> Virtio? {
    for d in virtio.find(virtio.NET) {
        if !d.start(F_MAC) { continue }
        let rx = d.queue(0, RX) catch e { continue }
        let tx = d.queue(1, TX) catch e { continue }
        var mac: [int] = []
        for i in 0..6 { mac.push(d.config8(i)) }
        let n = Virtio { dev: d, rx, tx, mac }
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

// The network card: virtio (QEMU), else Intel Ethernet, else a USB network device (`usb`: the USB
// controllers the input side already started). `cards`: look for the first two too (PCI cards don't
// come and go; USB devices do, so a later look only checks USB).
fn open(usb: xhci.Usb?, cards: bool) -> Nic? {
    if cards {
        if let v = open_virtio() { return some(Nic { kind: "virtio-net", mac: v.mac, virt: some(v) }) }
        if kernel.arch() == "x86_64" {
            if let c = e1000.open() { return some(Nic { kind: "Intel Ethernet ${c.model}", mac: c.mac, e1k: some(c) }) }
        }
    }
    if let u = usb {
        if let l = u.net() { return some(Nic { kind: l.kind, mac: l.mac, usb: some(l), usb_host: some(u) }) }
    }
    return none
}
