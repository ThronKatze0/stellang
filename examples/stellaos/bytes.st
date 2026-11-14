// Bytes from the outside world, read safely. Everything the network hands us is read through a
// View: every read checks its range first, so a packet that lies about its own lengths (the classic
// way into a network stack) reads zeros and gets flagged `bad` instead of reading past its buffer.
// Out is the same for writing: it never writes past its capacity.
//
// Numbers on the wire are big-endian ("network byte order").

import kernel

extern fn st_k_csum(addr: int, n: int, sum: int) -> int
extern fn st_k_read_text(src: int, n: int) -> str

struct View {
    addr: int,
    len: int,
    bad: bool = false,        // a read was out of range

    fn fits(self, off: int, n: int) -> bool {
        if off < 0 || n < 0 || off + n > self.len {
            self.bad = true
            return false
        }
        return true
    }

    fn u8(self, off: int) -> int {
        if !self.fits(off, 1) { return 0 }
        return kernel.peek8(self.addr + off)
    }

    fn u16(self, off: int) -> int {
        if !self.fits(off, 2) { return 0 }
        return (kernel.peek8(self.addr + off) << 8) | kernel.peek8(self.addr + off + 1)
    }

    fn u32(self, off: int) -> int {
        if !self.fits(off, 4) { return 0 }
        return (self.u16(off) << 16) | self.u16(off + 2)
    }

    // a part of this view (empty, and `bad`, if it doesn't fit)
    fn sub(self, off: int, n: int) -> View {
        if !self.fits(off, n) { return View { addr: self.addr, len: 0, bad: true } }
        return View { addr: self.addr + off, len: n }
    }

    fn from(self, off: int) -> View {
        return self.sub(off, self.len - off)
    }

    // bytes as text (NUL bytes become spaces)
    fn text(self, off: int, n: int) -> str {
        if !self.fits(off, n) { return "" }
        return st_k_read_text(self.addr + off, n)
    }

    fn all_text(self) -> str {
        return self.text(0, self.len)
    }

    fn list(self) -> [int] {
        var out: [int] = []
        for i in 0..self.len { out.push(kernel.peek8(self.addr + i)) }
        return out
    }

    // the Internet checksum's running sum over the whole view
    fn sum(self, start: int) -> int {
        return st_k_csum(self.addr, self.len, start)
    }
}

struct Out {
    addr: int,
    cap: int,
    len: int = 0,
    full: bool = false,       // something didn't fit (the packet must not be sent)

    fn room(self, n: int) -> bool {
        if self.len + n > self.cap {
            self.full = true
            return false
        }
        return true
    }

    fn u8(self, v: int) {
        if !self.room(1) { return }
        kernel.poke8(self.addr + self.len, v & 0xff)
        self.len += 1
    }

    fn u16(self, v: int) {
        self.u8(v >> 8)
        self.u8(v)
    }

    fn u32(self, v: int) {
        self.u16(v >> 16)
        self.u16(v)
    }

    fn bytes(self, b: [int]) {
        if !self.room(b.len()) { return }
        for v in b { self.u8(v) }
    }

    fn zeros(self, n: int) {
        if !self.room(n) { return }
        for i in 0..n { kernel.poke8(self.addr + self.len + i, 0) }
        self.len += n
    }

    // a string's bytes (UTF-8, no terminator)
    fn text(self, s: str) {
        let n = s.len()
        if !self.room(n) { return }
        kernel.write_str(self.addr + self.len, s)
        self.len += n
    }

    // copy a view's bytes
    fn view(self, v: View) {
        if !self.room(v.len) { return }
        kernel.copy(self.addr + self.len, v.addr, v.len)
        self.len += v.len
    }

    // overwrite a 16-bit number written earlier (lengths and checksums filled in last)
    fn set16(self, at: int, v: int) {
        if at < 0 || at + 2 > self.len { return }
        kernel.poke8(self.addr + at, (v >> 8) & 0xff)
        kernel.poke8(self.addr + at + 1, v & 0xff)
    }

    fn view_of(self, off: int, n: int) -> View {
        if off < 0 || n < 0 || off + n > self.len { return View { addr: self.addr, len: 0, bad: true } }
        return View { addr: self.addr + off, len: n }
    }
}

// Fold a checksum sum and take its complement: what goes in the header.
fn checksum(sum: int) -> int {
    var s = sum
    while s >> 16 != 0 { s = (s & 0xffff) + (s >> 16) }
    let c = (~s) & 0xffff
    return c
}

// A growing byte buffer (received data). It refuses to grow past `limit`.
struct Buffer {
    addr: int = 0,
    cap: int = 0,
    len: int = 0,
    limit: int = 1 << 22,

    // append; false (and nothing added) if it would pass the limit
    fn add(self, v: View) -> bool {
        if self.len + v.len > self.limit { return false }
        if self.len + v.len > self.cap {
            var cap = max(self.cap * 2, 4096)
            while cap < self.len + v.len { cap = cap * 2 }
            let mem = kernel.alloc(cap)
            if self.len > 0 { kernel.copy(mem, self.addr, self.len) }
            self.addr = mem
            self.cap = cap
        }
        kernel.copy(self.addr + self.len, v.addr, v.len)
        self.len += v.len
        return true
    }

    // append bytes given as a list
    fn add_list(self, b: [int]) -> bool {
        if b.is_empty() { return true }
        let mem = kernel.alloc(b.len())
        for i, v in b { kernel.poke8(mem + i, v) }
        return self.add(View { addr: mem, len: b.len() })
    }

    fn view(self) -> View {
        return View { addr: self.addr, len: self.len }
    }

    // drop the first `n` bytes
    fn consume(self, n: int) {
        let k = min(max(n, 0), self.len)
        if k == 0 { return }
        if k < self.len { kernel.copy(self.addr, self.addr + k, self.len - k) }
        self.len -= k
    }
}
