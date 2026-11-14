// Certificates (X.509, in DER): reading them, and checking a server's chain up to a root we trust.
//
// The checks: every signature in the chain (RSA PKCS #1 v1.5 or ECDSA P-256/P-384, SHA-256/384/512),
// every certificate's dates, CA certificates really being CAs (basicConstraints), at most 6 links,
// and the first certificate naming the host (subjectAltName, with *.wildcards for one label only).
// DER is read with bounds checks: a malformed certificate is an error, not a crash.

import kernel
import sha2
import rsa
import ecc

// a DER element: its tag, and where its contents are
struct Tlv {
    tag: int,
    start: int,
    end: int,
    bad: bool = false,
}

fn tlv(b: [int], off: int, limit: int) -> Tlv {
    if off + 2 > limit { return Tlv { tag: 0, start: 0, end: 0, bad: true } }
    let tag = b[off]
    var len = b[off + 1]
    var p = off + 2
    if len & 0x80 != 0 {
        let n = len & 0x7f
        if n == 0 || n > 3 || p + n > limit { return Tlv { tag, start: 0, end: 0, bad: true } }
        len = 0
        for i in 0..n { len = (len << 8) | b[p + i] }
        p += n
    }
    if p + len > limit { return Tlv { tag, start: 0, end: 0, bad: true } }
    return Tlv { tag, start: p, end: p + len }
}

// the elements inside a constructed element
fn kids(b: [int], t: Tlv) -> [Tlv] {
    var out: [Tlv] = []
    var p = t.start
    while p < t.end && out.len() < 64 {
        let k = tlv(b, p, t.end)
        if k.bad {
            out.push(k)
            return out
        }
        out.push(k)
        p = k.end
    }
    return out
}

fn bytes(b: [int], t: Tlv) -> [int] { return b.slice(t.start, t.end) }
fn hex_of(b: [int], t: Tlv) -> str { return sha2.hex(bytes(b, t)) }
fn whole(b: [int], off: int, t: Tlv) -> [int] { return b.slice(off, t.end) }

struct Cert {
    der: [int],
    tbs: [int] = [],
    sig_alg: str = "",        // OID, hex
    sig: [int] = [],
    issuer: str = "",         // the issuer's and subject's names, DER as hex (compared exactly)
    subject: str = "",
    cn: str = "",
    org: str = "",
    not_before: int = 0,      // seconds since 1970
    not_after: int = 0,
    key_alg: str = "",        // "rsa", "P-256", "P-384", or ""
    rsa_n: [int] = [],
    rsa_e: [int] = [],
    ec_point: [int] = [],
    names: [str] = [],        // subjectAltName dNSNames
    ips: [str] = [],
    ca: bool = false,
    error: str = "",
}

const RSA_KEY = "2a864886f70d010101"
const EC_KEY = "2a8648ce3d0201"
const P256 = "2a8648ce3d030107"
const P384 = "2b81040022"

fn parse(der: [int]) -> Cert {
    let c = Cert { der }
    let top = tlv(der, 0, der.len())
    if top.bad || top.tag != 0x30 {
        c.error = "not a certificate"
        return c
    }
    let parts = kids(der, top)
    if parts.len() != 3 || parts[0].bad || parts[2].tag != 0x03 {
        c.error = "malformed certificate"
        return c
    }
    // the signed part, exactly as it was signed (its header starts where the outer contents do)
    let tbs_t = parts[0]
    c.tbs = der.slice(top.start, tbs_t.end)
    let alg = kids(der, parts[1])
    if alg.is_empty() || alg[0].tag != 6 {
        c.error = "malformed signature algorithm"
        return c
    }
    c.sig_alg = hex_of(der, alg[0])
    let sigbits = bytes(der, parts[2])
    if sigbits.is_empty() || sigbits[0] != 0 {
        c.error = "malformed signature"
        return c
    }
    c.sig = sigbits.slice(1, sigbits.len())
    var f = kids(der, tbs_t)
    for k in f {
        if k.bad {
            c.error = "malformed certificate body"
            return c
        }
    }
    var i = 0
    if !f.is_empty() && f[0].tag == 0xa0 { i = 1 }     // version
    if f.len() < i + 6 {
        c.error = "malformed certificate body"
        return c
    }
    // serial, signature, issuer, validity, subject, key
    c.issuer = hex_of(der, f[i + 2])
    let validity = kids(der, f[i + 3])
    if validity.len() != 2 {
        c.error = "malformed validity"
        return c
    }
    c.not_before = time_of(der, validity[0])
    c.not_after = time_of(der, validity[1])
    c.subject = hex_of(der, f[i + 4])
    read_name(c, der, f[i + 4])
    read_key(c, der, f[i + 5])
    // extensions: [3] { SEQUENCE OF Extension }
    for k in f.slice(i + 6, f.len()) {
        if k.tag != 0xa3 { continue }
        let seq = kids(der, k)
        if seq.is_empty() { continue }
        for ext in kids(der, seq[0]) {
            let e = kids(der, ext)
            if e.len() < 2 || e[0].tag != 6 { continue }
            let oid = hex_of(der, e[0])
            let value = e[e.len() - 1]
            if value.tag != 4 { continue }
            let inner = tlv(der, value.start, value.end)
            if inner.bad { continue }
            if oid == "551d11" {
                for g in kids(der, inner) {
                    if g.tag == 0x82 && g.end - g.start <= 253 { c.names.push(text(der, g).lower()) }
                    if g.tag == 0x87 && g.end - g.start == 4 {
                        let ip = bytes(der, g)
                        c.ips.push("${ip[0]}.${ip[1]}.${ip[2]}.${ip[3]}")
                    }
                }
            }
            if oid == "551d13" {
                let bc = kids(der, inner)
                if !bc.is_empty() && bc[0].tag == 1 && bc[0].end > bc[0].start && der[bc[0].start] != 0 { c.ca = true }
            }
        }
    }
    return c
}

fn text(b: [int], t: Tlv) -> str {
    var cs: [str] = []
    for i in t.start..t.end {
        let v = b[i]
        cs.push(if v >= 32 && v < 127 { st_chr(v) } else { "?" })
    }
    return cs.join("")
}

extern fn st_chr(code: int) -> str

fn read_name(c: Cert, der: [int], name: Tlv) {
    for rdn in kids(der, name) {
        for atv in kids(der, rdn) {
            let p = kids(der, atv)
            if p.len() != 2 || p[0].tag != 6 { continue }
            let oid = hex_of(der, p[0])
            if oid == "550403" { c.cn = text(der, p[1]) }
            if oid == "55040a" { c.org = text(der, p[1]) }
        }
    }
}

fn read_key(c: Cert, der: [int], spki: Tlv) {
    let p = kids(der, spki)
    if p.len() != 2 || p[1].tag != 3 { return }
    let alg = kids(der, p[0])
    if alg.is_empty() { return }
    let kind = hex_of(der, alg[0])
    let bits = bytes(der, p[1])
    if bits.is_empty() || bits[0] != 0 { return }
    let key = bits.slice(1, bits.len())
    if kind == RSA_KEY {
        let seq = tlv(key, 0, key.len())
        if seq.bad { return }
        let ne = kids(key, seq)
        if ne.len() != 2 || ne[0].tag != 2 || ne[1].tag != 2 { return }
        c.key_alg = "rsa"
        c.rsa_n = strip(bytes(key, ne[0]))
        c.rsa_e = strip(bytes(key, ne[1]))
    } else if kind == EC_KEY && alg.len() == 2 {
        let curve = hex_of(der, alg[1])
        if curve == P256 { c.key_alg = "P-256" }
        if curve == P384 { c.key_alg = "P-384" }
        c.ec_point = key
    }
}

fn strip(b: [int]) -> [int] {
    var i = 0
    while i < b.len() - 1 && b[i] == 0 { i += 1 }
    return b.slice(i, b.len())
}

fn left_pad(b: [int], n: int) -> [int] {
    let s = strip(b)
    if s.len() > n { return [] }
    var out: [int] = []
    for i in 0..n - s.len() { out.push(0) }
    for x in s { out.push(x) }
    return out
}

// UTCTime (YYMMDDHHMMSSZ) or GeneralizedTime (YYYYMMDDHHMMSSZ), as seconds since 1970
fn time_of(b: [int], t: Tlv) -> int {
    let s = text(b, t)
    var y = 0
    var rest = ""
    if t.tag == 0x17 && s.len() >= 12 {
        y = int(s.slice(0, 2)) catch 0
        y += if y < 50 { 2000 } else { 1900 }
        rest = s.slice(2, s.len())
    } else if t.tag == 0x18 && s.len() >= 14 {
        y = int(s.slice(0, 4)) catch 0
        rest = s.slice(4, s.len())
    } else {
        return 0
    }
    let mo = int(rest.slice(0, 2)) catch 1
    let d = int(rest.slice(2, 4)) catch 1
    let hh = int(rest.slice(4, 6)) catch 0
    let mm = int(rest.slice(6, 8)) catch 0
    let ss = int(rest.slice(8, 10)) catch 0
    return days(y, mo, d) * 86400 + hh * 3600 + mm * 60 + ss
}

// days since 1970-01-01 (proleptic Gregorian)
fn days(y0: int, m: int, d: int) -> int {
    let y = if m <= 2 { y0 - 1 } else { y0 }
    let era = y / 400
    let yoe = y - era * 400
    let mp = (m + 9) % 12
    let doy = (153 * mp + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

// does `c` sign `data` with `sig` under algorithm `alg`?
fn signs(c: Cert, alg: str, data: [int], sig: [int]) -> bool {
    var hash = ""
    var ecdsa = false
    if alg == "2a864886f70d01010b" { hash = "sha256" }
    if alg == "2a864886f70d01010c" { hash = "sha384" }
    if alg == "2a864886f70d01010d" { hash = "sha512" }
    if alg == "2a8648ce3d040302" {
        hash = "sha256"
        ecdsa = true
    }
    if alg == "2a8648ce3d040303" {
        hash = "sha384"
        ecdsa = true
    }
    if alg == "2a8648ce3d040304" {
        hash = "sha512"
        ecdsa = true
    }
    if hash == "" { return false }
    let digest = sha2.hash(hash, data)
    if !ecdsa {
        return c.key_alg == "rsa" && rsa.verify_pkcs1(c.rsa_n, c.rsa_e, hash, digest, sig)
    }
    return ecdsa_ok(c, digest, sig)
}

// an ECDSA signature in DER (SEQUENCE { r, s })
fn ecdsa_ok(c: Cert, digest: [int], sig: [int]) -> bool {
    if c.key_alg != "P-256" && c.key_alg != "P-384" { return false }
    let n = if c.key_alg == "P-256" { 32 } else { 48 }
    let seq = tlv(sig, 0, sig.len())
    if seq.bad || seq.tag != 0x30 { return false }
    let rs = kids(sig, seq)
    if rs.len() != 2 || rs[0].tag != 2 || rs[1].tag != 2 || rs[0].bad || rs[1].bad { return false }
    let r = left_pad(bytes(sig, rs[0]), n)
    let s = left_pad(bytes(sig, rs[1]), n)
    if r.is_empty() || s.is_empty() { return false }
    return ecc.verify(ecc.curve(c.key_alg), c.ec_point, digest, r, s)
}

// does the certificate name `host`?
fn names_host(c: Cert, host: str) -> bool {
    let h = host.lower()
    if c.ips.contains(h) { return true }
    for n in c.names {
        if n == h { return true }
        if n.starts_with("*.") {
            let suffix = n.slice(1, n.len())        // ".example.com"
            if h.ends_with(suffix) {
                let label = h.slice(0, h.len() - suffix.len())
                if label != "" && !label.contains(".") { return true }
            }
        }
    }
    return false
}

// the trust store: Mozilla's roots (roots.st) plus any PEM files the user adds
struct Store {
    roots: [Cert] = [],
}

// Check a server's certificates (its own first) for `host`. "" if good, else what's wrong.
fn check(chain: [Cert], host: str, store: Store) -> str {
    if chain.is_empty() { return "the server sent no certificate" }
    for c in chain {
        if c.error != "" { return "bad certificate: ${c.error}" }
    }
    let leaf = chain[0]
    if !names_host(leaf, host) {
        let shown = if leaf.names.is_empty() { leaf.cn } else { leaf.names.slice(0, min(leaf.names.len(), 3)).join(", ") }
        return "the certificate is for ${shown}, not ${host}"
    }
    let now = kernel.time_ms() / 1000
    var cur = leaf
    for depth in 0..7 {
        // a day of slack: the clock is local time
        if now + 86400 < cur.not_before { return "a certificate isn't valid yet (${cur.cn})" }
        if now - 86400 > cur.not_after { return "a certificate has expired (${cur.cn})" }
        // signed by a root we trust?
        for r in store.roots {
            if r.subject == cur.issuer && signs(r, cur.sig_alg, cur.tbs, cur.sig) { return "" }
        }
        // else by the next certificate the server sent
        var next: Cert? = none
        for c in chain {
            if c.subject == cur.issuer && c.ca && c.der != cur.der && signs(c, cur.sig_alg, cur.tbs, cur.sig) {
                next = some(c)
                break
            }
        }
        if let n = next {
            cur = n
        } else {
            return "the certificate isn't signed by anyone we trust (issuer: ${issuer_name(cur, chain, store)})"
        }
    }
    return "the certificate chain is too long"
}

fn issuer_name(c: Cert, chain: [Cert], store: Store) -> str {
    // the issuer's CN, read from the issuer field itself
    let der = sha2.unhex(c.issuer)
    let t = tlv(der, 0, der.len())
    if t.bad { return "?" }
    let tmp = Cert { der: [] }
    read_name(tmp, der, t)
    if tmp.cn == "" && tmp.org == "" { return "unknown" }
    return if tmp.org != "" { "${tmp.cn} (${tmp.org})" } else { tmp.cn }
}

// PEM text -> DER certificates
fn pem(text: str) -> [[int]] {
    var out: [[int]] = []
    var cur: [str] = []
    var inside = false
    for line in text.lines() {
        let l = line.trim()
        if l.starts_with("-----BEGIN CERTIFICATE") {
            inside = true
            cur = []
        } else if l.starts_with("-----END CERTIFICATE") {
            inside = false
            out.push(base64(cur.join("")))
        } else if inside {
            cur.push(l)
        }
    }
    return out
}

fn base64(s: str) -> [int] {
    let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    var out: [int] = []
    var acc = 0
    var bits = 0
    for ch in s.chars() {
        if ch == "=" { break }
        let v = alphabet.find(ch)
        if v < 0 { continue }
        acc = (acc << 6) | v
        bits += 6
        if bits >= 8 {
            bits -= 8
            out.push((acc >> bits) & 255)
        }
        acc = acc & 0xffff
    }
    return out
}
