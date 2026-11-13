// Random numbers good enough for security: TCP sequence numbers, port numbers, DNS query ids.
// Predictable ones are how connections get hijacked, so these come from a cryptographic generator
// (ChaCha20, the cipher, run as a keystream) keyed with entropy from the host: QEMU's virtio-rng
// device hands us bytes from the host's /dev/urandom. With no such device we fall back to timer
// jitter and say so (`rng.strong()` is false).
//
// "Fast key erasure": every 64-byte block refreshes the key from its own output first, so a later
// look at memory can't recover numbers already handed out. Fresh host entropy is mixed in every
// so often too.

import kernel
import virtio

const MASK = 0xffff_ffff

struct Source {
    dev: virtio.Device,
    q: virtio.Queue,
    buf: int,

    // `n` (<= 256) bytes from the host, as numbers 0..255
    fn bytes(self, n: int) -> [int] {
        var out: [int] = []
        let head = self.q.offer([virtio.Buf { addr: self.buf, len: n, writable: true }])
        if head < 0 { return out }
        self.q.notify()
        let until = kernel.uptime() + 500
        while true {
            if let u = self.q.take() {
                for i in 0..min(u.len, n) { out.push(kernel.peek8(self.buf + i)) }
                return out
            }
            if kernel.uptime() > until { return out }
        }
        return out
    }
}

struct Rng {
    key: [int] = [0, 0, 0, 0, 0, 0, 0, 0],   // 8 words
    counter: int = 0,
    out: [int] = [],                         // words not handed out yet
    source: Source? = none,
    used: int = 0,                           // words handed out since the last reseed

    // a random number 0 .. 2^32-1
    fn u32(self) -> int {
        if self.out.is_empty() { self.refill() }
        self.used += 1
        return self.out.pop()
    }

    // a random number 0 .. n-1 (no bias: draws again when the draw lands in the uneven tail)
    fn below(self, n: int) -> int {
        if n <= 1 { return 0 }
        let limit = (MASK + 1) - (MASK + 1) % n
        while true {
            let v = self.u32()
            if v < limit { return v % n }
        }
        return 0
    }

    fn u16(self) -> int { return self.u32() & 0xffff }

    // one ChaCha20 block: 16 words. The first 8 become the next key; we keep the other 8.
    fn refill(self) {
        if self.used > 4096 {
            self.reseed()
        }
        let b = block(self.key, self.counter)
        self.counter += 1
        for i in 0..8 { self.key[i] = b[i] }
        self.out = []
        for i in 8..16 { self.out.push(b[i]) }
    }

    // mix fresh host entropy (and the clock) into the key
    fn reseed(self) {
        self.used = 0
        var mix: [int] = []
        if let s = self.source {
            let b = s.bytes(32)
            var i = 0
            while i + 3 < b.len() {
                mix.push(b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24))
                i += 4
            }
        }
        mix.push(jitter())
        mix.push(kernel.time_ms() & MASK)
        for i, w in mix { self.key[i % 8] = self.key[i % 8] ^ w }
        // stir: run a block with the mixed key, keep its first half as the key
        let b = block(self.key, 0xffff_ffff)
        for i in 0..8 { self.key[i] = b[i] }
        self.out = []
    }

    fn strong(self) -> bool {
        return self.source.is_some()
    }
}

// the low bits of the CPU clock, sampled around work whose time varies: weak, but not nothing
fn jitter() -> int {
    var x = 0
    for i in 0..64 {
        let t = st_k_cycles()
        x = ((x << 5) ^ (x >> 27) ^ t) & MASK
    }
    return x
}

extern fn st_k_cycles() -> int

fn rotl(x: int, n: int) -> int {
    return ((x << n) | (x >> (32 - n))) & MASK
}

// The ChaCha20 block function (RFC 8439): key (8 words), a 64-bit counter, a zero nonce.
fn block(key: [int], counter: int) -> [int] {
    var s = [0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574]
    for k in key { s.push(k) }
    s.push(counter & MASK)
    s.push((counter >> 32) & MASK)
    s.push(0)
    s.push(0)
    var x: [int] = []
    for w in s { x.push(w) }
    for round in 0..10 {
        qr(x, 0, 4, 8, 12)
        qr(x, 1, 5, 9, 13)
        qr(x, 2, 6, 10, 14)
        qr(x, 3, 7, 11, 15)
        qr(x, 0, 5, 10, 15)
        qr(x, 1, 6, 11, 12)
        qr(x, 2, 7, 8, 13)
        qr(x, 3, 4, 9, 14)
    }
    for i in 0..16 { x[i] = (x[i] + s[i]) & MASK }
    return x
}

fn qr(x: [int], a: int, b: int, c: int, d: int) {
    x[a] = (x[a] + x[b]) & MASK
    x[d] = rotl(x[d] ^ x[a], 16)
    x[c] = (x[c] + x[d]) & MASK
    x[b] = rotl(x[b] ^ x[c], 12)
    x[a] = (x[a] + x[b]) & MASK
    x[d] = rotl(x[d] ^ x[a], 8)
    x[c] = (x[c] + x[d]) & MASK
    x[b] = rotl(x[b] ^ x[c], 7)
}

// Set up the generator: find the host's entropy device and seed from it.
fn open() -> Rng {
    let r = Rng {}
    for d in virtio.find(virtio.RNG) {
        if !d.start(0) { continue }
        let q = d.queue(0, 4) catch e { continue }
        d.go()
        r.source = some(Source { dev: d, q, buf: kernel.alloc_pages(1) })
        break
    }
    r.reseed()
    r.reseed()
    return r
}
