// SHA-256, SHA-384 and SHA-512 (FIPS 180-4), HMAC and HKDF: the hashes TLS and certificates use.
// Data is a list of bytes (ints 0..255). Ints are 64-bit and wrap on overflow, which SHA-512's
// arithmetic wants; `>>` keeps the sign, so `shr` below masks to make it a logical shift.

const M32 = 0xffff_ffff

const K256 = [0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0xfc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x6ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]
const K512 = [4794697086780616226, 8158064640168781261, -5349999486874862801, -1606136188198331460, 4131703408338449720, 6480981068601479193, -7908458776815382629, -6116909921290321640, -2880145864133508542, 1334009975649890238, 2608012711638119052, 6128411473006802146, 8268148722764581231, -9160688886553864527, -7215885187991268811, -4495734319001033068, -1973867731355612462, -1171420211273849373, 1135362057144423861, 2597628984639134821, 3308224258029322869, 5365058923640841347, 6679025012923562964, 8573033837759648693, -7476448914759557205, -6327057829258317296, -5763719355590565569, -4658551843659510044, -4116276920077217854, -3051310485924567259, 489312712824947311, 1452737877330783856, 2861767655752347644, 3322285676063803686, 5560940570517711597, 5996557281743188959, 7280758554555802590, 8532644243296465576, -9096487096722542874, -7894198246740708037, -6719396339535248540, -6333637450476146687, -4446306890439682159, -4076793802049405392, -3345356375505022440, -2983346525034927856, -860691631967231958, 1182934255886127544, 1847814050463011016, 2177327727835720531, 2830643537854262169, 3796741975233480872, 4115178125766777443, 5681478168544905931, 6601373596472566643, 7507060721942968483, 8399075790359081724, 8693463985226723168, -8878714635349349518, -8302665154208450068, -8016688836872298968, -6606660893046293015, -4685533653050689259, -4147400797238176981, -3880063495543823972, -3348786107499101689, -1523767162380948706, -757361751448694408, 500013540394364858, 748580250866718886, 1242879168328830382, 1977374033974150939, 2944078676154940804, 3659926193048069267, 4368137639120453308, 4836135668995329356, 5532061633213252278, 6448918945643986474, 6902733635092675308, 7801388544844847127]
const H512 = [7640891576956012808, -4942790177534073029, 4354685564936845355, -6534734903238641935, 5840696475078001361, -7276294671716946913, 2270897969802886507, 6620516959819538809]
const H384 = [-3766243637369397544, 7105036623409894663, -7973340178411365097, 1526699215303891257, 7436329637833083697, -8163818279084223215, -2662702644619276377, 5167115440072839076]

fn rotr32(x: int, n: int) -> int { return ((x >> n) | (x << (32 - n))) & M32 }
fn shr(x: int, n: int) -> int { return (x >> n) & ((1 << (64 - n)) - 1) }
fn rotr64(x: int, n: int) -> int { return shr(x, n) | (x << (64 - n)) }

// the message padded to whole blocks: a 1 bit, zeros, and its length in bits
fn pad(data: [int], block: int) -> [int] {
    var m: [int] = []
    for b in data { m.push(b) }
    m.push(0x80)
    let lenfield = block / 8          // 8 bytes (SHA-256) or 16 (SHA-512)
    while m.len() % block != block - lenfield { m.push(0) }
    for i in 0..lenfield - 8 { m.push(0) }
    let bits = data.len() * 8
    var s = 56
    while s >= 0 {
        m.push((bits >> s) & 255)
        s -= 8
    }
    return m
}

fn sha256(data: [int]) -> [int] {
    var h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    let m = pad(data, 64)
    var w: [int] = []
    for i in 0..64 { w.push(0) }
    var off = 0
    while off < m.len() {
        for i in 0..16 {
            let j = off + 4 * i
            w[i] = (m[j] << 24) | (m[j + 1] << 16) | (m[j + 2] << 8) | m[j + 3]
        }
        for i in 16..64 {
            let a = w[i - 15]
            let b = w[i - 2]
            let s0 = rotr32(a, 7) ^ rotr32(a, 18) ^ (a >> 3)
            let s1 = rotr32(b, 17) ^ rotr32(b, 19) ^ (b >> 10)
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & M32
        }
        var a = h[0]
        var b = h[1]
        var c = h[2]
        var d = h[3]
        var e = h[4]
        var f = h[5]
        var g = h[6]
        var hh = h[7]
        for i in 0..64 {
            let s1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)
            let ch = (e & f) ^ ((~e) & M32 & g)
            let t1 = (hh + s1 + ch + K256[i] + w[i]) & M32
            let s0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = (s0 + maj) & M32
            hh = g
            g = f
            f = e
            e = (d + t1) & M32
            d = c
            c = b
            b = a
            a = (t1 + t2) & M32
        }
        h[0] = (h[0] + a) & M32
        h[1] = (h[1] + b) & M32
        h[2] = (h[2] + c) & M32
        h[3] = (h[3] + d) & M32
        h[4] = (h[4] + e) & M32
        h[5] = (h[5] + f) & M32
        h[6] = (h[6] + g) & M32
        h[7] = (h[7] + hh) & M32
        off += 64
    }
    var out: [int] = []
    for x in h {
        out.push((x >> 24) & 255)
        out.push((x >> 16) & 255)
        out.push((x >> 8) & 255)
        out.push(x & 255)
    }
    return out
}

fn sha512_core(data: [int], init: [int], outwords: int) -> [int] {
    var h: [int] = []
    for x in init { h.push(x) }
    let m = pad(data, 128)
    var w: [int] = []
    for i in 0..80 { w.push(0) }
    var off = 0
    while off < m.len() {
        for i in 0..16 {
            var v = 0
            for k in 0..8 { v = (v << 8) | m[off + 8 * i + k] }
            w[i] = v
        }
        for i in 16..80 {
            let a = w[i - 15]
            let b = w[i - 2]
            let s0 = rotr64(a, 1) ^ rotr64(a, 8) ^ shr(a, 7)
            let s1 = rotr64(b, 19) ^ rotr64(b, 61) ^ shr(b, 6)
            w[i] = w[i - 16] + s0 + w[i - 7] + s1
        }
        var a = h[0]
        var b = h[1]
        var c = h[2]
        var d = h[3]
        var e = h[4]
        var f = h[5]
        var g = h[6]
        var hh = h[7]
        for i in 0..80 {
            let s1 = rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41)
            let ch = (e & f) ^ ((~e) & g)
            let t1 = hh + s1 + ch + K512[i] + w[i]
            let s0 = rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 + maj
            hh = g
            g = f
            f = e
            e = d + t1
            d = c
            c = b
            b = a
            a = t1 + t2
        }
        h[0] = h[0] + a
        h[1] = h[1] + b
        h[2] = h[2] + c
        h[3] = h[3] + d
        h[4] = h[4] + e
        h[5] = h[5] + f
        h[6] = h[6] + g
        h[7] = h[7] + hh
        off += 128
    }
    var out: [int] = []
    for i in 0..outwords {
        var s = 56
        while s >= 0 {
            out.push((h[i] >> s) & 255)
            s -= 8
        }
    }
    return out
}

fn sha512(data: [int]) -> [int] { return sha512_core(data, H512, 8) }
fn sha384(data: [int]) -> [int] { return sha512_core(data, H384, 6) }

// by name: "sha256", "sha384", "sha512"
fn hash(name: str, data: [int]) -> [int] {
    if name == "sha384" { return sha384(data) }
    if name == "sha512" { return sha512(data) }
    return sha256(data)
}

fn hmac256(key: [int], data: [int]) -> [int] {
    var k = key
    if k.len() > 64 { k = sha256(k) }
    var inner: [int] = []
    var outer: [int] = []
    for i in 0..64 {
        let b = if i < k.len() { k[i] } else { 0 }
        inner.push(b ^ 0x36)
        outer.push(b ^ 0x5c)
    }
    for b in data { inner.push(b) }
    for b in sha256(inner) { outer.push(b) }
    return sha256(outer)
}

fn hkdf_extract(salt: [int], ikm: [int]) -> [int] {
    return hmac256(salt, ikm)
}

fn hkdf_expand(prk: [int], info: [int], len: int) -> [int] {
    var out: [int] = []
    var t: [int] = []
    var i = 1
    while out.len() < len {
        var msg: [int] = []
        for b in t { msg.push(b) }
        for b in info { msg.push(b) }
        msg.push(i)
        t = hmac256(prk, msg)
        for b in t { out.push(b) }
        i += 1
    }
    return out.slice(0, len)
}

// bytes <-> text helpers
fn bytes_of(s: str) -> [int] {
    var out: [int] = []
    for c in s.chars() {
        let code = st_ord(c)
        if code < 128 {
            out.push(code)
        } else {
            // UTF-8: take the encoded bytes
            for b in utf8(code) { out.push(b) }
        }
    }
    return out
}

fn utf8(c: int) -> [int] {
    if c < 0x800 { return [0xc0 | (c >> 6), 0x80 | (c & 63)] }
    if c < 0x10000 { return [0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63)] }
    return [0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63)]
}

extern fn st_ord(s: str) -> int

fn hex(b: [int]) -> str {
    let d = "0123456789abcdef".chars()
    return b.map(x => d[(x >> 4) & 15] + d[x & 15]).join("")
}

fn unhex(s: str) -> [int] {
    var out: [int] = []
    let cs = s.chars()
    var i = 0
    while i + 1 < cs.len() {
        let a = "0123456789abcdef".find(cs[i].lower())
        let b = "0123456789abcdef".find(cs[i + 1].lower())
        out.push(a * 16 + b)
        i += 2
    }
    return out
}
