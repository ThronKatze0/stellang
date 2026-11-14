// X25519 (RFC 7748): the elliptic-curve Diffie-Hellman TLS 1.3 uses to agree on a secret.
// Field elements mod 2^255-19 are 16 limbs of 16 bits (the TweetNaCl layout), so products fit in
// 64-bit ints. The ladder is constant-time in shape: it does the same work whatever the key bits.

fn gf() -> [int] { return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] }

fn copy(a: [int]) -> [int] {
    var o: [int] = []
    for x in a { o.push(x) }
    return o
}

fn car(o: [int]) {
    for i in 0..16 {
        o[i] = o[i] + (1 << 16)
        let c = o[i] >> 16
        if i < 15 { o[i + 1] = o[i + 1] + c - 1 } else { o[0] = o[0] + 38 * (c - 1) }
        o[i] = o[i] - (c << 16)
    }
}

// swap p and q if b is 1, without branching on b
fn sel(p: [int], q: [int], b: int) {
    let c = ~(b - 1)
    for i in 0..16 {
        let t = c & (p[i] ^ q[i])
        p[i] = p[i] ^ t
        q[i] = q[i] ^ t
    }
}

fn add(a: [int], b: [int]) -> [int] {
    var o: [int] = []
    for i in 0..16 { o.push(a[i] + b[i]) }
    return o
}

fn sub(a: [int], b: [int]) -> [int] {
    var o: [int] = []
    for i in 0..16 { o.push(a[i] - b[i]) }
    return o
}

fn mul(a: [int], b: [int]) -> [int] {
    var t: [int] = []
    for i in 0..31 { t.push(0) }
    for i in 0..16 {
        let ai = a[i]
        for j in 0..16 { t[i + j] = t[i + j] + ai * b[j] }
    }
    for i in 0..15 { t[i] = t[i] + 38 * t[i + 16] }
    let o = t.slice(0, 16)
    car(o)
    car(o)
    return o
}

fn inv(i: [int]) -> [int] {
    var c = copy(i)
    var a = 253
    while a >= 0 {
        c = mul(c, c)
        if a != 2 && a != 4 { c = mul(c, i) }
        a -= 1
    }
    return c
}

fn pack(n: [int]) -> [int] {
    let t = copy(n)
    car(t)
    car(t)
    car(t)
    let m = gf()
    for j in 0..2 {
        m[0] = t[0] - 0xffed
        for i in 1..15 {
            m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1)
            m[i - 1] = m[i - 1] & 0xffff
        }
        m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1)
        let b = (m[15] >> 16) & 1
        m[14] = m[14] & 0xffff
        sel(t, m, 1 - b)
    }
    var o: [int] = []
    for i in 0..16 {
        o.push(t[i] & 0xff)
        o.push((t[i] >> 8) & 0xff)
    }
    return o
}

fn unpack(n: [int]) -> [int] {
    let o = gf()
    for i in 0..16 { o[i] = n[2 * i] + (n[2 * i + 1] << 8) }
    o[15] = o[15] & 0x7fff
    return o
}

// scalar * point (both 32 bytes, little-endian)
fn scalarmult(n: [int], p: [int]) -> [int] {
    let z = copy(n)
    z[31] = (n[31] & 127) | 64
    z[0] = z[0] & 248
    let x = unpack(p)
    var a = gf()
    var b = copy(x)
    var c = gf()
    var d = gf()
    a[0] = 1
    d[0] = 1
    let k121665 = [0xdb41, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    var i = 254
    while i >= 0 {
        let r = (z[i >> 3] >> (i & 7)) & 1
        sel(a, b, r)
        sel(c, d, r)
        var e = add(a, c)
        a = sub(a, c)
        c = add(b, d)
        b = sub(b, d)
        d = mul(e, e)
        let f = mul(a, a)
        a = mul(c, a)
        c = mul(b, e)
        e = add(a, c)
        a = sub(a, c)
        b = mul(a, a)
        c = sub(d, f)
        a = mul(c, k121665)
        a = add(a, d)
        c = mul(c, a)
        a = mul(d, f)
        d = mul(b, x)
        b = mul(e, e)
        sel(a, b, r)
        sel(c, d, r)
        i -= 1
    }
    return pack(mul(a, inv(c)))
}

const BASE = [9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

fn public_key(secret: [int]) -> [int] {
    return scalarmult(secret, BASE)
}
