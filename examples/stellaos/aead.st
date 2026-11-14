// The two ciphers TLS 1.3 records use: ChaCha20-Poly1305 (RFC 8439) and AES-128-GCM (NIST SP
// 800-38D). Both encrypt and authenticate: a record that was changed on the way fails to open.
// Bytes are lists of ints 0..255.

const M32 = 0xffff_ffff

// ---- ChaCha20 ----

fn le32(b: [int], i: int) -> int {
    return b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)
}

fn rotl(x: int, n: int) -> int { return ((x << n) | (x >> (32 - n))) & M32 }

fn qr(x: [int], a: int, b: int, c: int, d: int) {
    x[a] = (x[a] + x[b]) & M32
    x[d] = rotl(x[d] ^ x[a], 16)
    x[c] = (x[c] + x[d]) & M32
    x[b] = rotl(x[b] ^ x[c], 12)
    x[a] = (x[a] + x[b]) & M32
    x[d] = rotl(x[d] ^ x[a], 8)
    x[c] = (x[c] + x[d]) & M32
    x[b] = rotl(x[b] ^ x[c], 7)
}

// 64 bytes of keystream
fn chacha_block(key: [int], counter: int, nonce: [int]) -> [int] {
    var s = [0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574]
    for i in 0..8 { s.push(le32(key, 4 * i)) }
    s.push(counter & M32)
    for i in 0..3 { s.push(le32(nonce, 4 * i)) }
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
    var out: [int] = []
    for i in 0..16 {
        let v = (x[i] + s[i]) & M32
        out.push(v & 255)
        out.push((v >> 8) & 255)
        out.push((v >> 16) & 255)
        out.push((v >> 24) & 255)
    }
    return out
}

fn chacha_xor(key: [int], counter: int, nonce: [int], data: [int]) -> [int] {
    var out: [int] = []
    var ctr = counter
    var i = 0
    while i < data.len() {
        let ks = chacha_block(key, ctr, nonce)
        ctr += 1
        var j = 0
        while j < 64 && i < data.len() {
            out.push(data[i] ^ ks[j])
            i += 1
            j += 1
        }
    }
    return out
}

// ---- Poly1305 (26-bit limbs) ----

fn poly1305(key: [int], msg: [int]) -> [int] {
    let r0 = le32(key, 0) & 0x3ffffff
    let r1 = (le32(key, 3) >> 2) & 0x3ffff03
    let r2 = (le32(key, 6) >> 4) & 0x3ffc0ff
    let r3 = (le32(key, 9) >> 6) & 0x3f03fff
    let r4 = (le32(key, 12) >> 8) & 0x00fffff
    let s1 = r1 * 5
    let s2 = r2 * 5
    let s3 = r3 * 5
    let s4 = r4 * 5
    var h0 = 0
    var h1 = 0
    var h2 = 0
    var h3 = 0
    var h4 = 0
    var off = 0
    while off < msg.len() {
        // a 16-byte block (the last one padded with a 1 byte, then zeros)
        var blk: [int] = []
        let n = min(16, msg.len() - off)
        for i in 0..n { blk.push(msg[off + i]) }
        var hibit = 1 << 24
        if n < 16 {
            blk.push(1)
            while blk.len() < 17 { blk.push(0) }
            hibit = 0
        } else {
            blk.push(0)
        }
        h0 += le32(blk, 0) & 0x3ffffff
        h1 += (le32(blk, 3) >> 2) & 0x3ffffff
        h2 += (le32(blk, 6) >> 4) & 0x3ffffff
        h3 += (le32(blk, 9) >> 6) & 0x3ffffff
        h4 += (le32(blk, 12) >> 8) | hibit
        let d0 = h0 * r0 + h1 * s4 + h2 * s3 + h3 * s2 + h4 * s1
        var d1 = h0 * r1 + h1 * r0 + h2 * s4 + h3 * s3 + h4 * s2
        var d2 = h0 * r2 + h1 * r1 + h2 * r0 + h3 * s4 + h4 * s3
        var d3 = h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * s4
        var d4 = h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0
        var c = d0 >> 26
        h0 = d0 & 0x3ffffff
        d1 += c
        c = d1 >> 26
        h1 = d1 & 0x3ffffff
        d2 += c
        c = d2 >> 26
        h2 = d2 & 0x3ffffff
        d3 += c
        c = d3 >> 26
        h3 = d3 & 0x3ffffff
        d4 += c
        c = d4 >> 26
        h4 = d4 & 0x3ffffff
        h0 += c * 5
        c = h0 >> 26
        h0 = h0 & 0x3ffffff
        h1 += c
        off += 16
    }
    // fully carry, then h - p if h >= p
    var c = h1 >> 26
    h1 = h1 & 0x3ffffff
    h2 += c
    c = h2 >> 26
    h2 = h2 & 0x3ffffff
    h3 += c
    c = h3 >> 26
    h3 = h3 & 0x3ffffff
    h4 += c
    c = h4 >> 26
    h4 = h4 & 0x3ffffff
    h0 += c * 5
    c = h0 >> 26
    h0 = h0 & 0x3ffffff
    h1 += c
    var g0 = h0 + 5
    c = g0 >> 26
    g0 = g0 & 0x3ffffff
    var g1 = h1 + c
    c = g1 >> 26
    g1 = g1 & 0x3ffffff
    var g2 = h2 + c
    c = g2 >> 26
    g2 = g2 & 0x3ffffff
    var g3 = h3 + c
    c = g3 >> 26
    g3 = g3 & 0x3ffffff
    let g4 = h4 + c - (1 << 26)
    if g4 >= 0 {
        h0 = g0
        h1 = g1
        h2 = g2
        h3 = g3
        h4 = g4
    }
    // h as 128 bits, plus s
    let w0 = (h0 | (h1 << 26)) & M32
    let w1 = ((h1 >> 6) | (h2 << 20)) & M32
    let w2 = ((h2 >> 12) | (h3 << 14)) & M32
    let w3 = ((h3 >> 18) | (h4 << 8)) & M32
    var f = w0 + le32(key, 16)
    let o0 = f & M32
    f = w1 + le32(key, 20) + (f >> 32)
    let o1 = f & M32
    f = w2 + le32(key, 24) + (f >> 32)
    let o2 = f & M32
    f = w3 + le32(key, 28) + (f >> 32)
    let o3 = f & M32
    var out: [int] = []
    for w in [o0, o1, o2, o3] {
        out.push(w & 255)
        out.push((w >> 8) & 255)
        out.push((w >> 16) & 255)
        out.push((w >> 24) & 255)
    }
    return out
}

fn pad16(m: [int]) {
    while m.len() % 16 != 0 { m.push(0) }
}

fn le64(m: [int], v: int) {
    for i in 0..8 { m.push((v >> (8 * i)) & 255) }
}

fn chacha_tag(key: [int], nonce: [int], aad: [int], ct: [int]) -> [int] {
    let otk = chacha_block(key, 0, nonce).slice(0, 32)
    var m: [int] = []
    for b in aad { m.push(b) }
    pad16(m)
    for b in ct { m.push(b) }
    pad16(m)
    le64(m, aad.len())
    le64(m, ct.len())
    return poly1305(otk, m)
}

// ---- AES-128 ----

const SBOX = [
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
]

fn xtime(b: int) -> int { return ((b << 1) ^ (if b & 0x80 != 0 { 0x1b } else { 0 })) & 0xff }

// the 11 round keys, 16 bytes each, one after another
fn aes_expand(key: [int]) -> [int] {
    var w: [int] = []
    for b in key { w.push(b) }
    var rcon = 1
    var i = 16
    while i < 176 {
        var t = [w[i - 4], w[i - 3], w[i - 2], w[i - 1]]
        if i % 16 == 0 {
            t = [SBOX[t[1]] ^ rcon, SBOX[t[2]], SBOX[t[3]], SBOX[t[0]]]
            rcon = xtime(rcon)
        }
        for k in 0..4 { w.push(w[i - 16 + k] ^ t[k]) }
        i += 4
    }
    return w
}

fn aes_block(rk: [int], input: [int]) -> [int] {
    var s: [int] = []
    for i in 0..16 { s.push(input[i] ^ rk[i]) }
    for round in 1..11 {
        // SubBytes + ShiftRows
        var t: [int] = []
        for c in 0..4 {
            for r in 0..4 { t.push(SBOX[s[((c + r) % 4) * 4 + r]]) }
        }
        // MixColumns (not in the last round)
        if round < 10 {
            for c in 0..4 {
                let a0 = t[4 * c]
                let a1 = t[4 * c + 1]
                let a2 = t[4 * c + 2]
                let a3 = t[4 * c + 3]
                let x = a0 ^ a1 ^ a2 ^ a3
                t[4 * c] = a0 ^ x ^ xtime(a0 ^ a1)
                t[4 * c + 1] = a1 ^ x ^ xtime(a1 ^ a2)
                t[4 * c + 2] = a2 ^ x ^ xtime(a2 ^ a3)
                t[4 * c + 3] = a3 ^ x ^ xtime(a3 ^ a0)
            }
        }
        for i in 0..16 { t[i] = t[i] ^ rk[16 * round + i] }
        s = t
    }
    return s
}

// ---- GCM ----

fn shr1(x: int) -> int { return (x >> 1) & 0x7fff_ffff_ffff_ffff }

// GHASH key: H as two 64-bit halves
struct Gcm {
    rk: [int],
    hh: int,
    hl: int,

    // x * H in GF(2^128)
    fn mul(self, xh: int, xl: int) -> [int] {
        var zh = 0
        var zl = 0
        var vh = self.hh
        var vl = self.hl
        for i in 0..128 {
            let bit = if i < 64 { (xh >> (63 - i)) & 1 } else { (xl >> (127 - i)) & 1 }
            if bit != 0 {
                zh = zh ^ vh
                zl = zl ^ vl
            }
            let lsb = vl & 1
            vl = shr1(vl) | ((vh & 1) << 63)
            vh = shr1(vh)
            if lsb != 0 { vh = vh ^ (0xe1 << 56) }
        }
        return [zh, zl]
    }

    fn ghash(self, aad: [int], ct: [int]) -> [int] {
        var m: [int] = []
        for b in aad { m.push(b) }
        pad16(m)
        for b in ct { m.push(b) }
        pad16(m)
        for b in be64(aad.len() * 8) { m.push(b) }
        for b in be64(ct.len() * 8) { m.push(b) }
        var yh = 0
        var yl = 0
        var off = 0
        while off < m.len() {
            var bh = 0
            var bl = 0
            for k in 0..8 {
                bh = (bh << 8) | m[off + k]
                bl = (bl << 8) | m[off + 8 + k]
            }
            let z = self.mul(yh ^ bh, yl ^ bl)
            yh = z[0]
            yl = z[1]
            off += 16
        }
        var out = be64(yh)
        for b in be64(yl) { out.push(b) }
        return out
    }

    // counter mode from counter block `ctr` (12-byte IV + 32-bit counter)
    fn ctr(self, iv: [int], start: int, data: [int]) -> [int] {
        var out: [int] = []
        var n = start
        var i = 0
        while i < data.len() {
            var blk: [int] = []
            for b in iv { blk.push(b) }
            blk.push((n >> 24) & 255)
            blk.push((n >> 16) & 255)
            blk.push((n >> 8) & 255)
            blk.push(n & 255)
            let ks = aes_block(self.rk, blk)
            n += 1
            var j = 0
            while j < 16 && i < data.len() {
                out.push(data[i] ^ ks[j])
                i += 1
                j += 1
            }
        }
        return out
    }

    fn tag(self, iv: [int], aad: [int], ct: [int]) -> [int] {
        let s = self.ghash(aad, ct)
        return self.ctr(iv, 1, s)
    }
}

fn be64(v: int) -> [int] {
    var out: [int] = []
    var s = 56
    while s >= 0 {
        out.push((v >> s) & 255)
        s -= 8
    }
    return out
}

fn gcm(key: [int]) -> Gcm {
    let rk = aes_expand(key)
    let h = aes_block(rk, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    var hh = 0
    var hl = 0
    for k in 0..8 {
        hh = (hh << 8) | h[k]
        hl = (hl << 8) | h[8 + k]
    }
    return Gcm { rk, hh, hl }
}

// ---- the AEAD interface TLS uses ----

struct Aead {
    kind: str,                // "chacha" or "aes"
    key: [int],
    g: Gcm? = none,

    fn seal(self, nonce: [int], aad: [int], plain: [int]) -> [int] {
        var ct: [int] = []
        var tag: [int] = []
        if self.kind == "chacha" {
            ct = chacha_xor(self.key, 1, nonce, plain)
            tag = chacha_tag(self.key, nonce, aad, ct)
        } else if let g = self.g {
            ct = g.ctr(nonce, 2, plain)
            tag = g.tag(nonce, aad, ct)
        }
        for b in tag { ct.push(b) }
        return ct
    }

    // the plaintext, or none if the data or its tag was tampered with
    fn open(self, nonce: [int], aad: [int], data: [int]) -> [int]? {
        if data.len() < 16 { return none }
        let ct = data.slice(0, data.len() - 16)
        let tag = data.slice(data.len() - 16, data.len())
        var want: [int] = []
        if self.kind == "chacha" {
            want = chacha_tag(self.key, nonce, aad, ct)
        } else if let g = self.g {
            want = g.tag(nonce, aad, ct)
        }
        // compare without stopping early
        var diff = 0
        for i in 0..16 { diff = diff | (want[i] ^ tag[i]) }
        if diff != 0 { return none }
        if self.kind == "chacha" { return some(chacha_xor(self.key, 1, nonce, ct)) }
        if let g = self.g { return some(g.ctr(nonce, 2, ct)) }
        return none
    }
}

fn aead(kind: str, key: [int]) -> Aead {
    if kind == "aes" { return Aead { kind, key, g: some(gcm(key)) } }
    return Aead { kind, key }
}
