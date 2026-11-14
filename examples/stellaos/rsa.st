// RSA signature checks (RFC 8017): PKCS #1 v1.5 (certificates) and PSS (TLS 1.3 handshakes).

import bn
import sha2

const PREFIX = {
    "sha256": "3031300d060960864801650304020105000420",
    "sha384": "3041300d060960864801650304020205000430",
    "sha512": "3051300d060960864801650304020305000440",
}

// sig^e mod n, as many bytes as n has (empty if the signature is out of range)
fn apply(n: [int], e: [int], sig: [int]) -> [int] {
    var nb = n
    while !nb.is_empty() && nb[0] == 0 { nb = nb.slice(1, nb.len()) }
    if nb.len() < 128 || nb.len() > 1024 || sig.len() != nb.len() || nb[nb.len() - 1] & 1 == 0 { return [] }
    let k = bn.limbs_for(nb.len())
    let nl = bn.from_bytes(nb, k)
    let s = bn.from_bytes(sig, k)
    if s.is_empty() || bn.cmp(s, nl) >= 0 { return [] }
    let m = bn.mont(nl)
    return bn.to_bytes(m.back(m.pow(m.to(s), e)), nb.len())
}

fn verify_pkcs1(n: [int], e: [int], hash: str, digest: [int], sig: [int]) -> bool {
    let em = apply(n, e, sig)
    if em.is_empty() { return false }
    let prefix = PREFIX.get(hash) ?? ""
    if prefix == "" { return false }
    var t = sha2.unhex(prefix)
    for b in digest { t.push(b) }
    // 00 01 FF..FF 00 T
    if em.len() < t.len() + 11 { return false }
    var want = [0, 1]
    while want.len() < em.len() - t.len() - 1 { want.push(0xff) }
    want.push(0)
    for b in t { want.push(b) }
    var diff = 0
    for i in 0..em.len() { diff = diff | (em[i] ^ want[i]) }
    return diff == 0
}

fn mgf1(hash: str, seed: [int], len: int) -> [int] {
    var out: [int] = []
    var c = 0
    while out.len() < len {
        var m: [int] = []
        for b in seed { m.push(b) }
        m.push((c >> 24) & 255)
        m.push((c >> 16) & 255)
        m.push((c >> 8) & 255)
        m.push(c & 255)
        for b in sha2.hash(hash, m) { out.push(b) }
        c += 1
    }
    return out.slice(0, len)
}

// RSASSA-PSS with MGF1 and a salt as long as the hash (what TLS 1.3 uses)
fn verify_pss(n: [int], e: [int], hash: str, digest: [int], sig: [int]) -> bool {
    let full = apply(n, e, sig)
    if full.is_empty() { return false }
    // the modulus' bit length
    var nb = n
    while !nb.is_empty() && nb[0] == 0 { nb = nb.slice(1, nb.len()) }
    var top = nb[0]
    var bits = 8 * (nb.len() - 1)
    while top > 0 {
        bits += 1
        top = top >> 1
    }
    let em_bits = bits - 1
    let em_len = (em_bits + 7) / 8
    var em = full
    if em_len < full.len() {
        if full[0] != 0 { return false }
        em = full.slice(full.len() - em_len, full.len())
    }
    let hl = digest.len()
    if em_len < 2 * hl + 2 || em[em_len - 1] != 0xbc { return false }
    let masked = em.slice(0, em_len - hl - 1)
    let h = em.slice(em_len - hl - 1, em_len - 1)
    let zero_bits = 8 * em_len - em_bits
    if zero_bits > 0 && (masked[0] >> (8 - zero_bits)) != 0 { return false }
    let mask = mgf1(hash, h, masked.len())
    var db: [int] = []
    for i in 0..masked.len() { db.push(masked[i] ^ mask[i]) }
    if zero_bits > 0 { db[0] = db[0] & (0xff >> zero_bits) }
    let ps = db.len() - hl - 1
    for i in 0..ps {
        if db[i] != 0 { return false }
    }
    if db[ps] != 1 { return false }
    var m = [0, 0, 0, 0, 0, 0, 0, 0]
    for b in digest { m.push(b) }
    for b in db.slice(ps + 1, db.len()) { m.push(b) }
    let h2 = sha2.hash(hash, m)
    var diff = 0
    for i in 0..hl { diff = diff | (h[i] ^ h2[i]) }
    return diff == 0
}
