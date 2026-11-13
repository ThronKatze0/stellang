// An HTTP/1.1 client, over TCP (http:) or TLS 1.3 (https:, tls.st): URLs, requests, responses
// (Content-Length, chunked, or until close), redirects.
//
// Careful with what comes back: headers are capped at 64 KiB and 100 lines, bodies at 4 MiB, chunk
// sizes are checked, at most 5 redirects are followed (and never from https: down to http:), and
// every request gives up after 20 seconds. URLs with a user name in them
// (https://bank.com@evil.example/) are refused: they're a phishing trick.

import kernel
import bytes
import inet
import tcp
import tls

// what requests need: TCP, and the roots HTTPS certificates are checked against
struct Client {
    stack: tcp.Tcp,
    trust: tls.Trust,
}

const MAX_HEADER = 65536
const MAX_BODY = 4 << 20
const TIMEOUT = 20_000
const AGENT = "StellaOS/0.3 (stellang; riscv64)"

struct Url {
    scheme: str = "http",
    host: str = "",
    port: int = 80,
    path: str = "/",          // with the query, without the #fragment
    fragment: str = "",

    fn text(self) -> str {
        let p = if self.port == default_port(self.scheme) { "" } else { ":${self.port}" }
        return "${self.scheme}://${self.host}${p}${self.path}"
    }
}

// Read a URL ("example.com" works too: http:// is assumed).
fn default_port(scheme: str) -> int { return if scheme == "https" { 443 } else { 80 } }

fn parse_url(s: str) -> Url! {
    var t = s.trim()
    if t.contains(" ") || t.contains("\n") || t.contains("\t") { return err("a URL can't have spaces in it") }
    let lower = t.lower()
    let u = Url {}
    if lower.starts_with("https://") {
        t = t.slice(8, t.len())
        u.scheme = "https"
        u.port = 443
    } else if lower.starts_with("http://") {
        t = t.slice(7, t.len())
    } else if t.contains("://") || lower.starts_with("javascript:") || lower.starts_with("data:") || lower.starts_with("file:") {
        return err("only http:// and https:// URLs can be opened")
    } else {
        // no scheme typed: HTTPS
        u.scheme = "https"
        u.port = 443
    }
    let hash = t.find("#")
    if hash >= 0 {
        u.fragment = t.slice(hash + 1, t.len())
        t = t.slice(0, hash)
    }
    var slash = t.find("/")
    let q = t.find("?")
    if q >= 0 && (slash < 0 || q < slash) { slash = q }
    var hostport = t
    if slash >= 0 {
        hostport = t.slice(0, slash)
        u.path = t.slice(slash, t.len())
        if u.path.starts_with("?") { u.path = "/" + u.path }
    }
    if hostport.contains("@") { return err("URLs with a user name in them aren't allowed (a phishing trick)") }
    let colon = hostport.find(":")
    if colon >= 0 {
        u.port = int(hostport.slice(colon + 1, hostport.len())) catch 0
        hostport = hostport.slice(0, colon)
        if u.port < 1 || u.port > 65535 { return err("bad port in URL") }
    }
    u.host = hostport.lower()
    if u.host == "" { return err("no host in URL") }
    if !inet.valid_name(u.host) { return err("not a valid host name: ${u.host}") }
    return u
}

// `link` (as found on the page at `base`) as a full URL
fn resolve(base: Url, link: str) -> Url! {
    let l = link.trim()
    let lower = l.lower()
    if lower.starts_with("http://") || lower.starts_with("https://") || l.contains("://") { return parse_url(l) }
    if lower.starts_with("javascript:") || lower.starts_with("data:") || lower.starts_with("file:") || lower.starts_with("mailto:") {
        return err("blocked link: ${l.slice(0, min(l.len(), 40))}")
    }
    if l.starts_with("//") { return parse_url(base.scheme + ":" + l) }
    let u = Url { scheme: base.scheme, host: base.host, port: base.port }
    if l.starts_with("#") {
        u.path = base.path
        u.fragment = l.slice(1, l.len())
        return u
    }
    var rest = l
    let hash = rest.find("#")
    if hash >= 0 {
        u.fragment = rest.slice(hash + 1, rest.len())
        rest = rest.slice(0, hash)
    }
    if rest.starts_with("/") {
        u.path = rest
    } else if rest.starts_with("?") {
        let bq = base.path.find("?")
        u.path = (if bq >= 0 { base.path.slice(0, bq) } else { base.path }) + rest
    } else {
        // relative to the base's directory
        var dir = base.path
        let bq = dir.find("?")
        if bq >= 0 { dir = dir.slice(0, bq) }
        var parts = dir.split("/")
        parts.pop()
        for p in rest.split("/") {
            if p == ".." {
                if parts.len() > 1 { parts.pop() }
            } else if p != "." {
                parts.push(p)
            }
        }
        u.path = parts.join("/")
        if !u.path.starts_with("/") { u.path = "/" + u.path }
    }
    if u.path.contains(" ") { u.path = u.path.replace(" ", "%20") }
    return u
}

struct Response {
    url: Url = Url {},
    status: int = 0,
    reason: str = "",
    headers: {str: str} = {},
    body: str = "",
    error: str = "",
    bytes: int = 0,
    ms: int = 0,
    secure: str = "",         // for https: the cipher and who vouched for the certificate

    fn header(self, name: str) -> str { return self.headers.get(name.lower()) ?? "" }
}

// A request in flight.
struct Request {
    client: Client,
    method: str = "GET",
    form: str = "",           // a POST's body (application/x-www-form-urlencoded)
    url: Url,
    done: fn(Response),
    redirects: int = 0,
    conn: tcp.Conn? = none,
    tls: tls.Session? = none,
    head: Response? = none,   // the status and headers, once they're in
    body_at: int = 0,         // where the body starts in the inbox
    started: int = 0,
    finished: bool = false,
    timer: int = -1,
    phase: str = "looking up",    // looking up, connecting, waiting, reading, done

    fn start(self) {
        self.started = kernel.uptime()
        if self.timer < 0 {
            self.timer = kernel.every(250, () => {
                if !self.finished && kernel.uptime() - self.started > TIMEOUT { self.fail("timed out after ${TIMEOUT / 1000} seconds") }
            })
        }
        self.phase = "looking up"
        let stack = self.client.stack
        stack.net.resolve(self.url.host, (ips: [int], e: str) => {
            if self.finished { return }
            if e != "" {
                self.fail(e)
                return
            }
            self.phase = "connecting"
            let c = stack.connect(ips[0], self.url.port) catch ce {
                self.fail("${ce}")
                return
            }
            self.conn = some(c)
            let host = if self.url.port == default_port(self.url.scheme) { self.url.host } else { "${self.url.host}:${self.url.port}" }
            var request = "${self.method} ${self.url.path} HTTP/1.1\r\nHost: ${host}\r\nUser-Agent: ${AGENT}\r\nAccept: text/html, text/plain;q=0.9, */*;q=0.5\r\nAccept-Language: en\r\nAccept-Encoding: identity\r\nConnection: close\r\n"
            if self.method == "POST" {
                request = request + "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: ${self.form.len()}\r\nOrigin: ${self.url.scheme}://${host}\r\n\r\n" + self.form
            } else {
                request = request + "\r\n"
            }
            var asked = false
            if self.url.scheme == "https" {
                let s = tls.start(c, self.url.host, self.client.trust)
                self.tls = some(s)
                s.watchers.push(() => {
                    if self.finished { return }
                    if s.state == "handshake" { self.phase = "securing" }
                    if s.connected() && !asked {
                        asked = true
                        self.phase = "waiting"
                        s.write(request)
                    }
                    self.progress()
                })
            } else {
                c.watchers.push(() => {
                    if self.finished { return }
                    if c.connected() && !asked {
                        asked = true
                        self.phase = "waiting"
                        c.write(request)
                    }
                    self.progress()
                })
            }
        })
    }

    fn fail(self, e: str) {
        if self.finished { return }
        self.finish(Response { url: self.url, error: e })
    }

    fn finish(self, r: Response) {
        if self.finished { return }
        self.finished = true
        self.phase = "done"
        if self.timer >= 0 { kernel.cancel(self.timer) }
        if let s = self.tls { s.close() } else if let c = self.conn { c.close() }
        if let s = self.tls { r.secure = "TLS 1.3 · ${s.cipher_name()} · certificate from ${s.issuer}" }
        r.ms = kernel.uptime() - self.started
        self.done(r)
    }

    fn cancel(self) {
        if self.finished { return }
        self.finished = true
        if self.timer >= 0 { kernel.cancel(self.timer) }
        if let s = self.tls { s.abort() }
        if let c = self.conn { c.abort() }
    }

    // what arrived (decrypted, for https), whether that's all, and why not if it went wrong
    fn data(self) -> bytes.View {
        if let s = self.tls { return s.inbox.view() }
        if let c = self.conn { return c.inbox.view() }
        return bytes.View { addr: 0, len: 0 }
    }

    fn ended(self) -> bool {
        if let s = self.tls { return s.eof || s.done() }
        if let c = self.conn { return c.eof || c.done() }
        return true
    }

    fn why(self) -> str {
        if let s = self.tls { if s.error != "" { return s.error } }
        if let c = self.conn { return c.error }
        return ""
    }

    // new data or a state change on the connection
    fn progress(self) {
        let v = self.data()
        let ended = self.ended()
        if self.head == none {
            let end = find(v, "\r\n\r\n", 0)
            if end < 0 {
                if v.len > MAX_HEADER {
                    self.fail("the server's headers are too big")
                } else if ended {
                    let e = self.why()
                    self.fail(if e != "" { e } else if v.len == 0 { "the server closed the connection without answering" } else { "the server's answer isn't HTTP" })
                }
                return
            }
            let r = parse_head(v.text(0, end)) catch e {
                self.fail("${e}")
                return
            }
            r.url = self.url
            self.head = some(r)
            self.body_at = end + 4
            self.phase = "reading"
            // a redirect?
            if r.status >= 300 && r.status < 400 && r.status != 304 && r.header("location") != "" {
                if self.redirects >= 5 {
                    self.fail("too many redirects")
                    return
                }
                let to = resolve(self.url, r.header("location")) catch e {
                    self.fail("redirected to a URL we won't follow: ${e}")
                    return
                }
                if self.url.scheme == "https" && to.scheme != "https" {
                    self.fail("the site redirects from https to plain http (${to.text()}); not following")
                    return
                }
                if let s = self.tls { s.abort() }
                if let old = self.conn { old.abort() }
                self.conn = none
                self.tls = none
                self.head = none
                self.redirects += 1
                self.url = to
                if r.status == 301 || r.status == 302 || r.status == 303 {
                    self.method = "GET"           // (what browsers do)
                    self.form = ""
                }
                self.start()
                return
            }
        }
        if let r = self.head {
            let body = v.from(self.body_at)
            if body.len > MAX_BODY {
                self.fail("the page is bigger than ${MAX_BODY >> 20} MiB")
                return
            }
            let te = r.header("transfer-encoding").lower()
            let cl = r.header("content-length")
            if te.contains("chunked") {
                // decode once it's all here (it ends with an empty chunk), not on every packet
                if !(ended || find(body, "0\r\n\r\n", max(body.len - 5, 0)) >= 0) { return }
                let d = dechunk(body)
                if d.error != "" {
                    self.fail(d.error)
                    return
                }
                if d.complete || ended {
                    r.body = d.text
                    r.bytes = d.text.len()
                    self.finish(r)
                }
            } else if cl != "" {
                let want = int(cl.trim()) catch -1
                if want < 0 || want > MAX_BODY {
                    self.fail("bad Content-Length: ${cl}")
                    return
                }
                if body.len >= want || ended {
                    r.body = body.text(0, min(want, body.len))
                    r.bytes = min(want, body.len)
                    self.finish(r)
                }
            } else if ended {
                r.body = body.all_text()
                r.bytes = body.len
                self.finish(r)
            }
        }
    }
}

fn parse_head(text: str) -> Response! {
    let lines = text.split("\r\n")
    let first = lines[0]
    if !first.starts_with("HTTP/1.") { return err("the server's answer isn't HTTP") }
    let parts = first.split(" ")
    if parts.len() < 2 { return err("bad status line") }
    let r = Response {}
    r.status = int(parts[1]) catch 0
    if r.status < 100 || r.status > 599 { return err("bad status: ${parts[1]}") }
    r.reason = parts.slice(2, parts.len()).join(" ")
    if lines.len() > 100 { return err("too many headers") }
    for i in 1..lines.len() {
        let l = lines[i]
        let colon = l.find(":")
        if colon <= 0 { continue }
        let name = l.slice(0, colon).trim().lower()
        let value = l.slice(colon + 1, l.len()).trim()
        if let old = r.headers.get(name) { r.headers[name] = old + ", " + value } else { r.headers[name] = value }
    }
    return r
}

struct Dechunked {
    text: str = "",
    complete: bool = false,
    error: str = "",
}

// Undo chunked transfer encoding: "<hex size>\r\n<data>\r\n" ... "0\r\n\r\n".
fn dechunk(v: bytes.View) -> Dechunked {
    var parts: [str] = []
    var at = 0
    while true {
        let eol = find(v, "\r\n", at)
        if eol < 0 || eol - at > 32 {
            if eol - at > 32 { return Dechunked { error: "bad chunk header" } }
            break
        }
        let sizeline = v.text(at, eol - at).split(";")[0].trim()
        var size = 0
        for ch in sizeline.lower().chars() {
            let d = "0123456789abcdef".find(ch)
            if d < 0 || ch.len() != 1 { return Dechunked { error: "bad chunk size: ${sizeline}" } }
            size = size * 16 + d
            if size > MAX_BODY { return Dechunked { error: "a chunk is too big" } }
        }
        if size == 0 { return Dechunked { text: parts.join(""), complete: true } }
        if eol + 2 + size > v.len { break }
        parts.push(v.text(eol + 2, size))
        at = eol + 2 + size + 2
    }
    return Dechunked { text: parts.join("") }
}

// where `needle` (ASCII) starts in the view, from `from`; -1 if it doesn't
fn find(v: bytes.View, needle: str, from: int) -> int {
    let n = needle.chars().map(c => st_ord(c))
    if n.is_empty() { return from }
    var i = max(from, 0)
    while i + n.len() <= v.len {
        if kernel.peek8(v.addr + i) == n[0] {
            var all = true
            for k in 1..n.len() {
                if kernel.peek8(v.addr + i + k) != n[k] {
                    all = false
                    break
                }
            }
            if all { return i }
        }
        i += 1
    }
    return -1
}

extern fn st_ord(s: str) -> int

// Fetch a URL in the background; `done` gets the response (check `error` first).
fn get(client: Client, url: Url, done: fn(Response)) -> Request {
    let r = Request { client, url, done }
    r.start()
    return r
}

// A form sent with POST.
fn post(client: Client, url: Url, form: str, done: fn(Response)) -> Request {
    let r = Request { client, url, done, method: "POST", form }
    r.start()
    return r
}

// The same, waiting for it (for the shell).
fn fetch(client: Client, url: str) -> Response! {
    let u = parse_url(url)?
    var result: Response? = none
    get(client, u, (r: Response) => { result = some(r) })
    client.stack.net.wait(TIMEOUT + 2000, () => result.is_some())
    if let r = result {
        if r.error != "" { return err(r.error) }
        return r
    }
    return err("timed out")
}
