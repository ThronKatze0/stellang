// Big numbers for public-key crypto (RSA, elliptic curves): little-endian lists of 24-bit limbs,
// so a limb product (48 bits) plus carries fits a 64-bit int. Arithmetic modulo n is Montgomery
// multiplication. These only verify signatures (public data), so they don't need to be
// constant-time; the secret-key math (x25519.st) is.

const W = 24
const MASK = 0xff_ffff

fn zeros(k: int) -> [int] {
    var o: [int] = []
    for i in 0..k { o.push(0) }
    return o
}

// big-endian bytes -> k limbs (none if it doesn't fit)
fn from_bytes(b: [int], k: int) -> [int] {
    let o = zeros(k)
    var bit = 0
    var i = b.len() - 1
    while i >= 0 {
        let limb = bit / W
        let sh = bit % W
        if b[i] != 0 && limb >= k { return [] }
        if limb < k {
            o[limb] = o[limb] | ((b[i] << sh) & MASK)
            if sh > W - 8 && limb + 1 < k { o[limb + 1] = o[limb + 1] | (b[i] >> (W - sh)) }
            if sh > W - 8 && limb + 1 >= k && (b[i] >> (W - sh)) != 0 { return [] }
        }
        bit += 8
        i -= 1
    }
    return o
}

fn to_bytes(a: [int], len: int) -> [int] {
    var out: [int] = []
    for i in 0..len {
        let bit = 8 * (len - 1 - i)
        let limb = bit / W
        let sh = bit % W
        var v = 0
        if limb < a.len() { v = a[limb] >> sh }
        if sh > W - 8 && limb + 1 < a.len() { v = v | (a[limb + 1] << (W - sh)) }
        out.push(v & 255)
    }
    return out
}

fn limbs_for(bytes: int) -> int { return (bytes * 8 + W - 1) / W }

// -1, 0, 1
fn cmp(a: [int], b: [int]) -> int {
    var i = max(a.len(), b.len()) - 1
    while i >= 0 {
        let x = if i < a.len() { a[i] } else { 0 }
        let y = if i < b.len() { b[i] } else { 0 }
        if x != y { return if x < y { -1 } else { 1 } }
        i -= 1
    }
    return 0
}

fn is_zero(a: [int]) -> bool {
    for x in a {
        if x != 0 { return false }
    }
    return true
}

// a - b (a >= b), same length as a
fn sub(a: [int], b: [int]) -> [int] {
    var o: [int] = []
    var borrow = 0
    for i in 0..a.len() {
        var v = a[i] - (if i < b.len() { b[i] } else { 0 }) - borrow
        if v < 0 {
            v += 1 << W
            borrow = 1
        } else {
            borrow = 0
        }
        o.push(v)
    }
    return o
}

fn add(a: [int], b: [int]) -> [int] {
    var o: [int] = []
    var c = 0
    for i in 0..max(a.len(), b.len()) {
        let v = (if i < a.len() { a[i] } else { 0 }) + (if i < b.len() { b[i] } else { 0 }) + c
        o.push(v & MASK)
        c = v >> W
    }
    if c != 0 { o.push(c) }
    return o
}

fn trim(a: [int], k: int) -> [int] {
    var o: [int] = []
    for i in 0..k { o.push(if i < a.len() { a[i] } else { 0 }) }
    return o
}

// arithmetic modulo an odd n
struct Mont {
    n: [int],
    k: int,
    ninv: int,                // -n^-1 mod 2^24
    r2: [int],                // R^2 mod n, R = 2^(24k)
    one: [int],               // 1 in Montgomery form (R mod n)

    fn mul(self, a: [int], b: [int]) -> [int] {
        let k = self.k
        let n = self.n
        let t = zeros(k + 2)
        for i in 0..k {
            let ai = a[i]
            var c = 0
            for j in 0..k {
                let s = t[j] + ai * b[j] + c
                t[j] = s & MASK
                c = s >> W
            }
            var s = t[k] + c
            t[k] = s & MASK
            t[k + 1] = s >> W
            let m = (t[0] * self.ninv) & MASK
            s = t[0] + m * n[0]
            c = s >> W
            for j in 1..k {
                s = t[j] + m * n[j] + c
                t[j - 1] = s & MASK
                c = s >> W
            }
            s = t[k] + c
            t[k - 1] = s & MASK
            t[k] = t[k + 1] + (s >> W)
            t[k + 1] = 0
        }
        var r = t.slice(0, k + 1)
        if cmp(r, n) >= 0 { r = sub(r, n) }
        return r.slice(0, k)
    }

    fn to(self, a: [int]) -> [int] { return self.mul(trim(a, self.k), self.r2) }
    fn back(self, a: [int]) -> [int] {
        let one = zeros(self.k)
        one[0] = 1
        return self.mul(a, one)
    }

    fn add(self, a: [int], b: [int]) -> [int] {
        var r = add(a, b)
        if cmp(r, self.n) >= 0 { r = sub(r, self.n) }
        return trim(r, self.k)
    }

    fn sub(self, a: [int], b: [int]) -> [int] {
        if cmp(a, b) >= 0 { return trim(sub(a, b), self.k) }
        return trim(sub(add(a, self.n), b), self.k)
    }

    // a^e (a in Montgomery form; e as big-endian bytes)
    fn pow(self, a: [int], e: [int]) -> [int] {
        var r = self.one
        for byte in e {
            var bit = 7
            while bit >= 0 {
                r = self.mul(r, r)
                if (byte >> bit) & 1 != 0 { r = self.mul(r, a) }
                bit -= 1
            }
        }
        return r
    }

    // a^-1 for a prime n (Fermat: a^(n-2))
    fn inv(self, a: [int]) -> [int] {
        let two = zeros(self.k)
        two[0] = 2
        let e = sub(self.n, two)
        return self.pow(a, to_bytes(e, self.k * 3))
    }
}

fn mont(n: [int]) -> Mont {
    let k = n.len()
    // n0^-1 mod 2^24 by Newton's iteration
    var x = 1
    for i in 0..5 { x = (x * (2 - n[0] * x)) & MASK }
    let ninv = (0 - x) & MASK
    // 2^(24k) and 2^(48k) mod n, by doubling
    var r = zeros(k + 1)
    r[0] = 1
    var one: [int] = []
    for i in 0..2 * W * k {
        r = trim(add(r, r), k + 1)
        if cmp(r, n) >= 0 { r = sub(r, n) }
        if i == W * k - 1 { one = trim(r, k) }
    }
    return Mont { n, k, ninv, r2: trim(r, k), one }
}
