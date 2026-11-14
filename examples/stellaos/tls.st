// TLS 1.3 (RFC 8446), the client side: HTTPS. Written from scratch in stellang on top of tcp.st.
//
// - key exchange: X25519 (x25519.st), with a fresh secret per connection from the ChaCha20 RNG
// - ciphers: ChaCha20-Poly1305 or AES-128-GCM (aead.st), keys from the TLS 1.3 key schedule (HKDF)
// - the server proves who it is: its certificate chain must lead to a root we trust (x509.st:
//   Mozilla's roots, plus PEM files in /etc/ca), name the host, and be in date; its
//   CertificateVerify signature (RSA-PSS or ECDSA) must check out over the whole handshake; its
//   Finished MAC must match. Any failure ends the connection before a byte of HTTP is sent.
// - only TLS 1.3: no older versions to be downgraded to, no renegotiation, no compression.
//
// Records are at most 16 KiB; a record that fails authentication ends the connection.

import kernel
import bytes
import tcp
import sha2
import aead
import x25519
import x509
import rsa
import ecc
import roots

const MAX_RECORD = 16384 + 256

// what we trust: Mozilla's roots, plus extra PEM certificates (parsed once, when first needed)
struct Trust {
    store: x509.Store = x509.Store {},
    loaded: bool = false,
    extra: fn() -> str = () => "",
    extra_seen: str = "",

    fn get(self) -> x509.Store {
        let extra = self.extra()
        if !self.loaded || extra != self.extra_seen {
            self.loaded = true
            self.extra_seen = extra
            self.store = x509.Store {}
            for h in roots.ROOTS { self.store.roots.push(x509.parse(sha2.unhex(h))) }
            for der in x509.pem(extra) { self.store.roots.push(x509.parse(der)) }
        }
        return self.store
    }

    fn reload(self) {
        self.loaded = false
        self.store = x509.Store {}
    }
}


struct Keys {
    aead: aead.Aead,
    iv: [int],
    seq: int = 0,
    secret: [int],
}

fn expand_label(secret: [int], label: str, ctx: [int], len: int) -> [int] {
    let full = sha2.bytes_of("tls13 " + label)
    var info = [(len >> 8) & 255, len & 255, full.len()]
    for b in full { info.push(b) }
    info.push(ctx.len())
    for b in ctx { info.push(b) }
    return sha2.hkdf_expand(secret, info, len)
}

fn derive(secret: [int], label: str, transcript: [int]) -> [int] {
    return expand_label(secret, label, sha2.sha256(transcript), 32)
}

fn zeros(n: int) -> [int] {
    var o: [int] = []
    for i in 0..n { o.push(0) }
    return o
}

struct Session {
    conn: tcp.Conn,
    host: str,
    trust: Trust,
    state: str = "hello",     // hello, handshake, open, closed
    error: str = "",
    inbox: bytes.Buffer = bytes.Buffer {},
    eof: bool = false,
    watchers: [fn()] = [],
    suite: str = "",
    secret: [int] = [],
    transcript: [int] = [],
    hs: [int] = [],           // handshake bytes not yet a whole message
    rd: Keys? = none,
    wr: Keys? = none,
    hs_secret: [int] = [],
    c_hs: [int] = [],
    s_hs: [int] = [],
    chain: [x509.Cert] = [],
    verified: bool = false,
    pending: [str] = [],      // HTTP written before the handshake finished
    issuer: str = "",

    fn connected(self) -> bool { return self.state == "open" }
    fn done(self) -> bool { return self.state == "closed" }

    fn notify(self) {
        for f in self.watchers { f() }
    }

    fn fail(self, e: str) {
        if self.state == "closed" { return }
        if self.error == "" { self.error = e }
        self.state = "closed"
        self.conn.abort()
        self.notify()
    }

    fn write(self, s: str) {
        if self.state == "closed" { return }
        if self.state != "open" {
            self.pending.push(s)
            return
        }
        let data = sha2.bytes_of(s)
        var off = 0
        while off < data.len() {
            let n = min(16384, data.len() - off)
            self.send_record(23, data.slice(off, off + n))
            off += n
        }
    }

    fn close(self) {
        if self.state == "open" { self.send_record(21, [1, 0]) }   // close_notify
        self.conn.close()
    }

    fn abort(self) {
        self.state = "closed"
        self.conn.abort()
    }

    // ---- records ----

    fn send_plain(self, kind: int, body: [int]) {
        var rec = [kind, 3, 3, (body.len() >> 8) & 255, body.len() & 255]
        for b in body { rec.push(b) }
        self.conn.send(rec)
    }

    fn send_record(self, kind: int, body: [int]) {
        if let k = self.wr {
            var inner: [int] = []
            for b in body { inner.push(b) }
            inner.push(kind)
            let len = inner.len() + 16
            let aad = [23, 3, 3, (len >> 8) & 255, len & 255]
            let ct = k.aead.seal(nonce(k), aad, inner)
            k.seq += 1
            var rec = aad
            for b in ct { rec.push(b) }
            self.conn.send(rec)
        } else {
            self.send_plain(kind, body)
        }
    }

    // the connection has news: read whole records from it
    fn progress(self) {
        if self.state == "closed" { return }
        if self.state == "hello" && self.conn.connected() {
            self.hello()
            self.state = "handshake"
        }
        let c = self.conn
        while self.state != "closed" {
            let v = c.inbox.view()
            if v.len < 5 { break }
            let kind = v.u8(0)
            let len = v.u16(3)
            if len > MAX_RECORD || v.u8(1) != 3 {
                self.fail("the server's TLS records are malformed")
                return
            }
            if v.len < 5 + len { break }
            let body = v.sub(5, len).list()
            c.inbox.consume(5 + len)
            self.record(kind, body)
        }
        if self.state != "closed" && (c.eof || c.done()) {
            if self.state != "open" {
                self.fail(if c.error != "" { c.error } else { "the server closed the connection during the TLS handshake" })
                return
            }
            self.eof = true
        }
        self.notify()
    }

    fn record(self, kind: int, body: [int]) {
        if kind == 20 { return }                  // change_cipher_spec: ignored (compatibility)
        if let k = self.rd {
            if kind != 23 {
                self.fail("the server sent an unencrypted record after the handshake began")
                return
            }
            let aad = [23, 3, 3, (body.len() >> 8) & 255, body.len() & 255]
            if let plain = k.aead.open(nonce(k), aad, body) {
                k.seq += 1
                // inner type: the last non-zero byte
                var end = plain.len() - 1
                while end >= 0 && plain[end] == 0 { end -= 1 }
                if end < 0 {
                    self.fail("an empty TLS record")
                    return
                }
                let inner = plain[end]
                let data = plain.slice(0, end)
                if inner == 22 {
                    self.handshake(data)
                } else if inner == 23 {
                    if self.state != "open" {
                        self.fail("application data before the handshake finished")
                        return
                    }
                    if !self.inbox.add_list(data) { self.fail("too much data") }
                } else if inner == 21 {
                    self.alert(data)
                }
            } else {
                self.fail("a TLS record failed authentication (tampered with?)")
            }
            return
        }
        if kind == 21 {
            self.alert(body)
            return
        }
        if kind != 22 {
            self.fail("unexpected TLS record before encryption started")
            return
        }
        self.handshake(body)
    }

    fn alert(self, a: [int]) {
        if a.len() >= 2 && a[1] == 0 {
            self.eof = true                       // close_notify
            return
        }
        let code = if a.len() >= 2 { a[1] } else { -1 }
        self.fail("the server ended TLS: ${alert_name(code)}")
    }

    // ---- the handshake ----

    fn hello(self) {
        let r = self.conn.stack.net.rand
        self.secret = []
        for i in 0..32 { self.secret.push(r.u32() & 255) }
        let pub = x25519.public_key(self.secret)
        var b: [int] = [3, 3]
        for i in 0..32 { b.push(r.u32() & 255) }
        b.push(32)
        for i in 0..32 { b.push(r.u32() & 255) }  // a session id: makes middleboxes treat this as TLS 1.2 resumption
        b = cat(b, [0, 4, 0x13, 0x03, 0x13, 0x01, 1, 0])
        var ext: [int] = []
        if !is_ip(self.host) {
            let name = sha2.bytes_of(self.host)
            ext = cat(ext, cat([0, 0], u16len(u16len(cat([0], u16len(name))))))
        }
        ext = cat(ext, [0, 10, 0, 4, 0, 2, 0, 0x1d])
        ext = cat(ext, cat([0, 13], u16len(u16len([4, 3, 5, 3, 8, 4, 8, 5, 8, 6, 4, 1, 5, 1, 6, 1]))))
        ext = cat(ext, [0, 43, 0, 3, 2, 3, 4])
        ext = cat(ext, cat([0, 51], u16len(u16len(cat([0, 0x1d, 0, 32], pub)))))
        ext = cat(ext, [0, 45, 0, 2, 1, 1])
        ext = cat(ext, cat([0, 16], u16len(u16len(cat([8], sha2.bytes_of("http/1.1"))))))
        b = cat(b, u16len(ext))
        let msg = cat([1], u24len(b))
        self.transcript = cat(self.transcript, msg)
        var rec = [22, 3, 1, (msg.len() >> 8) & 255, msg.len() & 255]
        for x in msg { rec.push(x) }
        self.conn.send(rec)
    }

    fn handshake(self, data: [int]) {
        self.hs = cat(self.hs, data)
        while self.hs.len() >= 4 && self.state != "closed" {
            let len = (self.hs[1] << 16) | (self.hs[2] << 8) | self.hs[3]
            if len > 65536 {
                self.fail("a TLS handshake message is too big")
                return
            }
            if self.hs.len() < 4 + len { return }
            let msg = self.hs.slice(0, 4 + len)
            self.hs = self.hs.slice(4 + len, self.hs.len())
            self.message(msg[0], msg.slice(4, msg.len()), msg)
        }
    }

    fn message(self, kind: int, m: [int], whole: [int]) {
        if self.state == "open" {
            if kind == 4 { return }               // NewSessionTicket: we don't resume sessions
            if kind == 24 {
                self.key_update(m)
                return
            }
            self.fail("unexpected handshake message after the handshake")
            return
        }
        if kind == 2 {
            if self.rd.is_some() {
                self.fail("a second ServerHello")
                return
            }
            self.server_hello(m)
            self.transcript = cat(self.transcript, whole)
            if self.state != "closed" { self.handshake_keys() }
            return
        }
        if self.rd.is_none() {
            self.fail("unexpected TLS message before ServerHello")
            return
        }
        if kind == 8 {
            self.transcript = cat(self.transcript, whole)
        } else if kind == 11 {
            self.certificates(m)
            self.transcript = cat(self.transcript, whole)
        } else if kind == 15 {
            self.cert_verify(m)
            self.transcript = cat(self.transcript, whole)
        } else if kind == 20 {
            self.finished(m, whole)
        } else if kind == 13 {
            self.fail("the server asks for a client certificate, which we don't have")
        } else {
            self.fail("unexpected TLS handshake message ${kind}")
        }
    }

    fn server_hello(self, m: [int]) {
        if m.len() < 38 {
            self.fail("malformed ServerHello")
            return
        }
        // HelloRetryRequest has this special "random"
        if sha2.hex(m.slice(2, 34)) == "cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c" {
            self.fail("the server wants a key exchange we don't offer (only X25519)")
            return
        }
        var p = 34
        let sid = m[p]
        p += 1 + sid
        if p + 3 > m.len() {
            self.fail("malformed ServerHello")
            return
        }
        let suite = (m[p] << 8) | m[p + 1]
        p += 3
        if suite == 0x1301 { self.suite = "aes" } else if suite == 0x1303 { self.suite = "chacha" } else {
            self.fail("the server chose a cipher we don't offer")
            return
        }
        var version = 0
        var share: [int] = []
        if p + 2 > m.len() {
            self.fail("this server only speaks TLS 1.2 or older (we need TLS 1.3)")
            return
        }
        let ext_end = min(p + 2 + ((m[p] << 8) | m[p + 1]), m.len())
        p += 2
        while p + 4 <= ext_end {
            let t = (m[p] << 8) | m[p + 1]
            let l = (m[p + 2] << 8) | m[p + 3]
            let d = p + 4
            if d + l > ext_end { break }
            if t == 43 && l == 2 { version = (m[d] << 8) | m[d + 1] }
            if t == 51 && l >= 4 {
                let group = (m[d] << 8) | m[d + 1]
                let kl = (m[d + 2] << 8) | m[d + 3]
                if group == 0x1d && kl == 32 && d + 4 + 32 <= ext_end { share = m.slice(d + 4, d + 36) }
            }
            p = d + l
        }
        if version != 0x0304 {
            self.fail("this server only speaks TLS 1.2 or older (we need TLS 1.3)")
            return
        }
        if share.len() != 32 {
            self.fail("the server's key share is missing or not X25519")
            return
        }
        let shared = x25519.scalarmult(self.secret, share)
        var any = 0
        for x in shared { any = any | x }
        if any == 0 {
            self.fail("the server's key share is invalid")
            return
        }
        self.secret = shared
    }

    fn handshake_keys(self) {
        let early = sha2.hkdf_extract(zeros(32), zeros(32))
        self.hs_secret = sha2.hkdf_extract(derive(early, "derived", []), self.secret)
        self.secret = []
        self.c_hs = derive(self.hs_secret, "c hs traffic", self.transcript)
        self.s_hs = derive(self.hs_secret, "s hs traffic", self.transcript)
        self.rd = some(self.keys(self.s_hs))
        self.wr = some(self.keys(self.c_hs))
    }

    fn keys(self, secret: [int]) -> Keys {
        let n = if self.suite == "aes" { 16 } else { 32 }
        return Keys { aead: aead.aead(self.suite, expand_label(secret, "key", [], n)), iv: expand_label(secret, "iv", [], 12), secret }
    }

    fn certificates(self, m: [int]) {
        if m.len() < 4 {
            self.fail("malformed Certificate message")
            return
        }
        var p = 1 + m[0]
        let end = min(p + 3 + ((m[p] << 16) | (m[p + 1] << 8) | m[p + 2]), m.len())
        p += 3
        while p + 3 <= end && self.chain.len() < 10 {
            let l = (m[p] << 16) | (m[p + 1] << 8) | m[p + 2]
            if p + 3 + l > end { break }
            self.chain.push(x509.parse(m.slice(p + 3, p + 3 + l)))
            p += 3 + l
            if p + 2 > end { break }
            p += 2 + ((m[p] << 8) | m[p + 1])     // the entry's extensions
        }
        let why = x509.check(self.chain, self.host, self.trust.get())
        if why != "" {
            self.fail("the certificate can't be trusted: ${why}")
            return
        }
        if self.chain.len() > 1 { self.issuer = if self.chain[1].org != "" { self.chain[1].org } else { self.chain[1].cn } } else { self.issuer = self.chain[0].org }
    }

    fn cert_verify(self, m: [int]) {
        if self.chain.is_empty() || m.len() < 4 {
            self.fail("CertificateVerify without a certificate")
            return
        }
        let alg = (m[0] << 8) | m[1]
        let sl = (m[2] << 8) | m[3]
        if 4 + sl > m.len() {
            self.fail("malformed CertificateVerify")
            return
        }
        let sig = m.slice(4, 4 + sl)
        // what was signed: 64 spaces, a label, a zero, the transcript hash (through Certificate)
        var content: [int] = []
        for i in 0..64 { content.push(0x20) }
        content = cat(content, sha2.bytes_of("TLS 1.3, server CertificateVerify"))
        content.push(0)
        content = cat(content, sha2.sha256(self.transcript))
        let leaf = self.chain[0]
        var good = false
        if alg == 0x0804 || alg == 0x0805 || alg == 0x0806 {
            let h = if alg == 0x0804 { "sha256" } else if alg == 0x0805 { "sha384" } else { "sha512" }
            good = leaf.key_alg == "rsa" && rsa.verify_pss(leaf.rsa_n, leaf.rsa_e, h, sha2.hash(h, content), sig)
        } else if alg == 0x0403 || alg == 0x0503 {
            let h = if alg == 0x0403 { "sha256" } else { "sha384" }
            let want = if alg == 0x0403 { "P-256" } else { "P-384" }
            good = leaf.key_alg == want && x509.ecdsa_ok(leaf, sha2.hash(h, content), sig)
        }
        if !good {
            self.fail("the server couldn't prove it holds its certificate's key")
            return
        }
        self.verified = true
    }

    fn finished(self, m: [int], whole: [int]) {
        if !self.verified {
            self.fail("the server finished without proving who it is")
            return
        }
        let key = expand_label(self.s_hs, "finished", [], 32)
        let want = sha2.hmac256(key, sha2.sha256(self.transcript))
        var diff = if m.len() == 32 { 0 } else { 1 }
        for i in 0..min(32, m.len()) { diff = diff | (m[i] ^ want[i]) }
        if diff != 0 {
            self.fail("the server's Finished message doesn't match (tampered handshake?)")
            return
        }
        self.transcript = cat(self.transcript, whole)
        // application keys, from the transcript through the server's Finished
        let master = sha2.hkdf_extract(derive(self.hs_secret, "derived", []), zeros(32))
        let c_ap = derive(master, "c ap traffic", self.transcript)
        let s_ap = derive(master, "s ap traffic", self.transcript)
        // our Finished
        self.send_plain(20, [1])                  // change_cipher_spec (compatibility)
        let ckey = expand_label(self.c_hs, "finished", [], 32)
        let verify = sha2.hmac256(ckey, sha2.sha256(self.transcript))
        self.send_record(22, cat([20], u24len(verify)))
        self.rd = some(self.keys(s_ap))
        self.wr = some(self.keys(c_ap))
        self.hs_secret = []
        self.transcript = []
        self.state = "open"
        for s in self.pending { self.write(s) }
        self.pending = []
    }

    fn key_update(self, m: [int]) {
        if let k = self.rd {
            let next = expand_label(k.secret, "traffic upd", [], 32)
            self.rd = some(self.keys(next))
        }
        if m.len() >= 1 && m[0] == 1 {
            self.send_record(22, [24, 0, 0, 1, 0])
            if let k = self.wr { self.wr = some(self.keys(expand_label(k.secret, "traffic upd", [], 32))) }
        }
    }

    fn cipher_name(self) -> str {
        return if self.suite == "aes" { "AES-128-GCM" } else { "ChaCha20-Poly1305" }
    }
}

fn nonce(k: Keys) -> [int] {
    var n: [int] = []
    for b in k.iv { n.push(b) }
    for i in 0..8 { n[11 - i] = n[11 - i] ^ ((k.seq >> (8 * i)) & 255) }
    return n
}

fn cat(a: [int], b: [int]) -> [int] {
    var o: [int] = []
    for x in a { o.push(x) }
    for x in b { o.push(x) }
    return o
}

fn u16len(b: [int]) -> [int] { return cat([(b.len() >> 8) & 255, b.len() & 255], b) }
fn u24len(b: [int]) -> [int] { return cat([(b.len() >> 16) & 255, (b.len() >> 8) & 255, b.len() & 255], b) }

fn is_ip(h: str) -> bool {
    for c in h.chars() {
        if !"0123456789.".contains(c) { return false }
    }
    return true
}

fn alert_name(code: int) -> str {
    if code == 40 { return "handshake failure" }
    if code == 42 || code == 43 || code == 44 || code == 45 || code == 46 { return "certificate problem (${code})" }
    if code == 47 { return "illegal parameter" }
    if code == 50 { return "decode error" }
    if code == 51 { return "decrypt error" }
    if code == 70 { return "protocol version (it doesn't speak TLS 1.3)" }
    if code == 112 { return "unrecognized name" }
    return "alert ${code}"
}

// Start TLS on a TCP connection (the handshake runs as data arrives).
fn start(conn: tcp.Conn, host: str, trust: Trust) -> Session {
    let s = Session { conn, host, trust }
    conn.watchers.push(() => s.progress())
    if conn.connected() { s.progress() }
    return s
}
