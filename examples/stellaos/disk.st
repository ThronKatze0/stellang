// The disk: a driver for virtio-blk devices (QEMU's virtio-blk-device), written in stellang.
// A disk is a row of 512-byte sectors; we read and write them a few at a time.
//
// Each request is a chain of three buffers on the device's queue: a header (read or write, which
// sector), the data, and one status byte the device fills in (0 = done).

import kernel
import virtio

const SECTOR = 512
const CHUNK = 64              // sectors per request (32 KiB)

struct Disk {
    dev: virtio.Device,
    q: virtio.Queue,
    sectors: int,             // its size
    header: int,              // memory for the request header and status
    buf: int,                 // memory for the data

    // Copy `count` sectors from the disk, starting at `sector`, to memory at `dst`.
    fn read(self, sector: int, count: int, dst: int) -> void! {
        var done = 0
        while done < count {
            let n = min(count - done, CHUNK)
            self.request(0, sector + done, n)?
            kernel.copy(dst + done * SECTOR, self.buf, n * SECTOR)
            done += n
        }
    }

    // Copy `count` sectors from memory at `src` to the disk, starting at `sector`.
    fn write(self, sector: int, count: int, src: int) -> void! {
        var done = 0
        while done < count {
            let n = min(count - done, CHUNK)
            kernel.copy(self.buf, src + done * SECTOR, n * SECTOR)
            self.request(1, sector + done, n)?
            done += n
        }
    }

    // kind 0: read, 1: write
    fn request(self, kind: int, sector: int, count: int) -> void! {
        if sector + count > self.sectors { return err("disk: sector ${sector + count} is past the end (${self.sectors})") }
        kernel.poke32(self.header, kind)
        kernel.poke32(self.header + 4, 0)
        kernel.poke64(self.header + 8, sector)
        kernel.poke8(self.header + 16, 0xff)
        let head = self.q.offer([
            virtio.Buf { addr: self.header, len: 16, writable: false },
            virtio.Buf { addr: self.buf, len: count * SECTOR, writable: kind == 0 },
            virtio.Buf { addr: self.header + 16, len: 1, writable: true },
        ])
        if head < 0 { return err("disk: queue full") }
        self.q.notify()
        // wait for the device (it's quick: QEMU does the work right away)
        let until = kernel.uptime() + 5000
        while true {
            if let u = self.q.take() { break }
            if kernel.uptime() > until { return err("disk: no answer") }
        }
        let status = kernel.peek8(self.header + 16)
        if status != 0 { return err("disk: the device says ${if status == 1 { "I/O error" } else { "unsupported" }}") }
    }

    fn size(self) -> int {
        return self.sectors * SECTOR
    }
}

// The first disk QEMU has, if any.
fn open() -> Disk? {
    for d in virtio.find(virtio.BLOCK) {
        if !d.start(0) { continue }
        let q = d.queue(0, 16) catch e { continue }
        d.go()
        let sectors = d.config32(0) | (d.config32(4) << 32)
        return some(Disk { dev: d, q, sectors, header: kernel.alloc_pages(1), buf: kernel.alloc_pages(CHUNK * SECTOR / 4096) })
    }
    return none
}
