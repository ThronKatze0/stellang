// ECDSA signature checks on the NIST curves P-256 and P-384 (what most web certificates and
// servers sign with). Points use Jacobian coordinates with Montgomery-form field elements.

import bn
import sha2

struct Curve {
    name: str,
    bytes: int,               // field size
    f: bn.Mont,               // arithmetic mod p
    q: bn.Mont,               // arithmetic mod n (the group order)
    b: [int],                 // the curve's b (Montgomery form); a is -3
    gx: [int],
    gy: [int],
}

struct Point {
    x: [int],
    y: [int],
    z: [int],
    inf: bool = false,
}

fn curve(name: str) -> Curve {
    if name == "P-384" {
        return make("P-384", 48,
            "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000ffffffff",
            "ffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973",
            "b3312fa7e23ee7e4988e056be3f82d19181d9c6efe8141120314088f5013875ac656398d8a2ed19d2a85c8edd3ec2aef",
            "aa87ca22be8b05378eb1c71ef320ad746e1d3b628ba79b9859f741e082542a385502f25dbf55296c3a545e3872760ab7",
            "3617de4a96262c6f5d9e98bf9292dc29f8f41dbd289a147ce9da3113b5f0b8c00a60b1ce1d7e819d7a431d7c90ea0e5f")
    }
    return make("P-256", 32,
        "ffffffff00000001000000000000000000000000ffffffffffffffffffffffff",
        "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551",
        "5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b",
        "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296",
        "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5")
}

fn make(name: str, bytes: int, p: str, n: str, b: str, gx: str, gy: str) -> Curve {
    let k = bn.limbs_for(bytes)
    let f = bn.mont(bn.from_bytes(sha2.unhex(p), k))
    let q = bn.mont(bn.from_bytes(sha2.unhex(n), k))
    return Curve { name, bytes, f, q, b: f.to(bn.from_bytes(sha2.unhex(b), k)),
        gx: f.to(bn.from_bytes(sha2.unhex(gx), k)), gy: f.to(bn.from_bytes(sha2.unhex(gy), k)) }
}

fn double(c: Curve, p: Point) -> Point {
    if p.inf || bn.is_zero(p.y) { return Point { x: p.x, y: p.y, z: p.z, inf: true } }
    let f = c.f
    let delta = f.mul(p.z, p.z)
    let gamma = f.mul(p.y, p.y)
    let beta = f.mul(p.x, gamma)
    let t = f.mul(f.sub(p.x, delta), f.add(p.x, delta))
    let alpha = f.add(f.add(t, t), t)
    let beta2 = f.add(beta, beta)
    let beta4 = f.add(beta2, beta2)
    let beta8 = f.add(beta4, beta4)
    let x3 = f.sub(f.mul(alpha, alpha), beta8)
    let yz = f.add(p.y, p.z)
    let z3 = f.sub(f.sub(f.mul(yz, yz), gamma), delta)
    let g2 = f.mul(gamma, gamma)
    let g4 = f.add(g2, g2)
    let g8 = f.add(f.add(g4, g4), f.add(g4, g4))
    let y3 = f.sub(f.mul(alpha, f.sub(beta4, x3)), g8)
    return Point { x: x3, y: y3, z: z3 }
}

fn add(c: Curve, p: Point, q: Point) -> Point {
    if p.inf { return q }
    if q.inf { return p }
    let f = c.f
    let z1z1 = f.mul(p.z, p.z)
    let z2z2 = f.mul(q.z, q.z)
    let u1 = f.mul(p.x, z2z2)
    let u2 = f.mul(q.x, z1z1)
    let s1 = f.mul(f.mul(p.y, q.z), z2z2)
    let s2 = f.mul(f.mul(q.y, p.z), z1z1)
    let h = f.sub(u2, u1)
    let rr = f.sub(s2, s1)
    if bn.is_zero(h) {
        if bn.is_zero(rr) { return double(c, p) }
        return Point { x: p.x, y: p.y, z: p.z, inf: true }
    }
    let r = f.add(rr, rr)
    let h2 = f.add(h, h)
    let i = f.mul(h2, h2)
    let j = f.mul(h, i)
    let v = f.mul(u1, i)
    let x3 = f.sub(f.sub(f.mul(r, r), j), f.add(v, v))
    let s1j = f.mul(s1, j)
    let y3 = f.sub(f.mul(r, f.sub(v, x3)), f.add(s1j, s1j))
    let zz = f.add(p.z, q.z)
    let z3 = f.mul(f.sub(f.sub(f.mul(zz, zz), z1z1), z2z2), h)
    return Point { x: x3, y: y3, z: z3 }
}

// u1*G + u2*Q (scalars as big-endian bytes), Shamir's trick
fn twin(c: Curve, u1: [int], g: Point, u2: [int], q: Point) -> Point {
    let gq = add(c, g, q)
    var r = Point { x: g.x, y: g.y, z: g.z, inf: true }
    for i in 0..u1.len() {
        var bit = 7
        while bit >= 0 {
            r = double(c, r)
            let a = (u1[i] >> bit) & 1
            let b = (u2[i] >> bit) & 1
            if a == 1 && b == 1 {
                r = add(c, r, gq)
            } else if a == 1 {
                r = add(c, r, g)
            } else if b == 1 {
                r = add(c, r, q)
            }
            bit -= 1
        }
    }
    return r
}

// Is `sig` (r and s, big-endian) a signature by `key` (an uncompressed point: 04 || X || Y) of
// `digest`?
fn verify(c: Curve, key: [int], digest: [int], r_bytes: [int], s_bytes: [int]) -> bool {
    let n = c.bytes
    if key.len() != 1 + 2 * n || key[0] != 4 { return false }
    let k = c.f.k
    let x = bn.from_bytes(key.slice(1, 1 + n), k)
    let y = bn.from_bytes(key.slice(1 + n, 1 + 2 * n), k)
    let r = bn.from_bytes(r_bytes, k)
    let s = bn.from_bytes(s_bytes, k)
    if x.is_empty() || y.is_empty() || r.is_empty() || s.is_empty() { return false }
    if bn.cmp(x, c.f.n) >= 0 || bn.cmp(y, c.f.n) >= 0 { return false }
    if bn.is_zero(r) || bn.is_zero(s) || bn.cmp(r, c.q.n) >= 0 || bn.cmp(s, c.q.n) >= 0 { return false }
    let f = c.f
    let qx = f.to(x)
    let qy = f.to(y)
    // the key must be on the curve: y^2 = x^3 - 3x + b
    let x3 = f.mul(f.mul(qx, qx), qx)
    let three_x = f.add(f.add(qx, qx), qx)
    if bn.cmp(f.mul(qy, qy), f.add(f.sub(x3, three_x), c.b)) != 0 { return false }
    // e: the digest's leftmost bits
    var e = bn.from_bytes(digest.slice(0, min(digest.len(), n)), k)
    if bn.cmp(e, c.q.n) >= 0 { e = bn.sub(e, c.q.n) }
    let q = c.q
    let w = q.inv(q.to(s))
    let u1 = q.back(q.mul(q.to(e), w))
    let u2 = q.back(q.mul(q.to(r), w))
    let one = f.one
    let p = twin(c, bn.to_bytes(u1, n), Point { x: c.gx, y: c.gy, z: one }, bn.to_bytes(u2, n), Point { x: qx, y: qy, z: one })
    if p.inf { return false }
    // x = X / Z^2, mod n
    let zi = f.inv(p.z)
    var ax = f.back(f.mul(p.x, f.mul(zi, zi)))
    if bn.cmp(ax, c.q.n) >= 0 { ax = bn.sub(ax, c.q.n) }
    return bn.cmp(ax, r) == 0
}
