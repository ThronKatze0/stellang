// TCP: reliable byte streams over IP, for outgoing connections (HTTP, ...).
//
// Hardened against the usual attacks on TCP:
// - initial sequence numbers and local ports are random (rng.st), so an attacker who can't see our
//   traffic can't guess them to inject data or reset the connection
// - a reset counts only if its sequence number is exactly the next one we expect; one that is merely
//   inside the window gets a "challenge ACK" instead (RFC 5961), and so does a SYN on an open
//   connection
// - acknowledgements must be for data we actually sent; data is taken only in order (anything else is
//   dropped and the peer is reminded where we are), and each connection buffers at most 4 MiB
// - nothing listens: a connection attempt from outside gets no answer at all (logged)
// - connections give up after timeouts (connect: 10 s, retransmits: 8 tries)

import kernel
import bytes
import inet

const MASK = 0xffff_ffff
const FIN = 1
const SYN = 2
const RST = 4
const PSH = 8
const ACK = 16
const MSS = 1460
const WINDOW = 65535
const MAX_CONNS = 64

// seq a - seq b, as a signed number (sequence numbers wrap around at 2^32)
fn diff(a: int, b: int) -> int {
    let d = (a - b) & MASK
    return if d >= 0x8000_0000 { d - 0x1_0000_0000 } else { d }
}

struct Conn {
    stack: Tcp,
    port: int,                // ours
    ip: int,                  // theirs
    rport: int,
    state: str = "syn-sent",  // syn-sent, open, fin-wait, closing, time-wait, closed
    iss: int = 0,
    una: int = 0,             // oldest byte not yet acknowledged
    nxt: int = 0,             // next sequence number to send
    wnd: int = 0,             // the peer's window
    rcv: int = 0,             // the next sequence number we expect
    mss: int = 536,
    out: bytes.Buffer = bytes.Buffer {},  // bytes from `una` on: sent but unacknowledged, then unsent
    inbox: bytes.Buffer = bytes.Buffer {},
    eof: bool = false,        // the peer finished sending
    closing: bool = false,    // we want to finish (a FIN goes out after the data)
    fin_sent: bool = false,
    error: str = "",
    rto: int = 1000,
    tries: int = 0,
    sent_at: int = 0,         // when the oldest unacknowledged segment went out
    opened: int = 0,
    last: int = 0,            // last time we heard from the peer
    ack_due: bool = false,
    watchers: [fn()] = [],
    received: int = 0,

    fn connected(self) -> bool { return self.state == "open" || self.state == "fin-wait" || self.state == "closing" }
    fn done(self) -> bool { return self.state == "closed" || self.state == "time-wait" }

    // Queue text to send.
    fn write(self, s: str) {
        if self.closing || self.done() { return }
        let mem = kernel.alloc(max(s.len(), 1))
        kernel.write_str(mem, s)
        self.out.add(bytes.View { addr: mem, len: s.len() })
        self.push()
    }

    // Queue bytes to send (binary data: TLS records).
    fn send(self, data: [int]) {
        if self.closing || self.done() || data.is_empty() { return }
        self.out.add_list(data)
        self.push()
    }

    // Finish sending (the peer may keep sending until it's done too).
    fn close(self) {
        if self.done() { return }
        if self.state == "syn-sent" {
            self.finish("")
            return
        }
        self.closing = true
        self.push()
    }

    // Drop the connection now (tells the peer with a reset).
    fn abort(self) {
        if self.connected() { self.segment(RST | ACK, self.nxt, 0, 0) }
        self.finish("")
    }

    fn finish(self, error: str) {
        if self.state == "closed" { return }
        if error != "" && self.error == "" { self.error = error }
        self.state = "closed"
        self.stack.forget(self)
        self.notify()
    }

    fn notify(self) {
        for f in self.watchers { f() }
    }

    // bytes in flight (sent, not yet acknowledged)
    fn flight(self) -> int {
        return diff(self.nxt, self.una) - (if self.fin_sent { 1 } else { 0 })
    }

    // Send what the window allows; then the FIN if we're closing and everything is out.
    fn push(self) {
        if !self.connected() { return }
        var sent_any = false
        while true {
            let inflight = self.flight()
            let waiting = self.out.len - inflight
            let room = self.wnd - inflight
            if waiting <= 0 || room <= 0 || self.fin_sent { break }
            let n = min(min(waiting, room), self.mss)
            self.segment(ACK | PSH, self.nxt, inflight, n)
            if self.flight() == 0 { self.sent_at = kernel.uptime() }
            self.nxt = (self.nxt + n) & MASK
            sent_any = true
        }
        if self.closing && !self.fin_sent && self.flight() == self.out.len {
            if self.flight() == 0 { self.sent_at = kernel.uptime() }
            self.segment(FIN | ACK, self.nxt, 0, 0)
            self.nxt = (self.nxt + 1) & MASK
            self.fin_sent = true
            if self.state == "open" { self.state = "fin-wait" }
            sent_any = true
        }
        if sent_any { self.ack_due = false }
    }

    // a segment: `n` bytes of `out` from offset `off`
    fn segment(self, flags: int, seq: int, off: int, n: int) {
        let net = self.stack.net
        if let o = net.ip_begin(self.ip, inet.TCP) {
            let start = o.len
            o.u16(self.port)
            o.u16(self.rport)
            o.u32(seq)
            o.u32(if flags & ACK != 0 { self.rcv } else { 0 })
            let syn = flags & SYN != 0
            o.u8(if syn { 0x60 } else { 0x50 })
            o.u8(flags)
            o.u16(max(min(WINDOW, self.inbox.limit - self.inbox.len), 0))
            o.u16(0)
            o.u16(0)
            if syn {
                o.bytes([2, 4])
                o.u16(MSS)
            }
            if n > 0 { o.view(self.out.view().sub(off, n)) }
            let len = o.len - start
            o.set16(start + 16, bytes.checksum(o.view_of(start, len).sum(net.pseudo(net.ip, self.ip, inet.TCP, len))))
            net.ip_send(o)
        }
    }

    fn ack_now(self) {
        self.segment(ACK, self.nxt, 0, 0)
        self.ack_due = false
    }

    // a segment for this connection arrived
    fn input(self, seg: bytes.View, hl: int) {
        let seq = seg.u32(4)
        let ack = seg.u32(8)
        let flags = seg.u8(13)
        let win = seg.u16(14)
        let data = seg.from(hl)
        self.last = kernel.uptime()

        if self.state == "syn-sent" {
            if flags & ACK != 0 && ack != ((self.iss + 1) & MASK) {
                self.stack.net.note("TCP spoof", "dropped a TCP answer with the wrong acknowledgement from ${inet.fmt_ip(self.ip)}:${self.rport}")
                return
            }
            if flags & RST != 0 {
                if flags & ACK != 0 { self.finish("connection refused by ${inet.fmt_ip(self.ip)}:${self.rport}") }
                return
            }
            if flags & SYN != 0 && flags & ACK != 0 {
                self.rcv = (seq + 1) & MASK
                self.una = ack
                self.wnd = win
                self.mss = peer_mss(seg, hl)
                self.state = "open"
                self.tries = 0
                self.rto = 1000
                self.ack_now()
                self.push()
                self.notify()
            }
            return
        }

        // synchronized states: is the segment where we expect it?
        if flags & RST != 0 {
            if seq == self.rcv {
                self.finish(if self.eof && self.out.len == 0 { "" } else { "connection reset by ${inet.fmt_ip(self.ip)}" })
            } else if diff(seq, self.rcv) > 0 && diff(seq, self.rcv) < WINDOW {
                self.stack.net.note("TCP reset", "a TCP reset from ${inet.fmt_ip(self.ip)} with an inexact sequence number: challenged, not obeyed")
                self.ack_now()
            } else {
                self.stack.net.count("TCP resets outside the window")
            }
            return
        }
        if flags & SYN != 0 {
            // a SYN on an open connection: challenge it (it's an old duplicate or an attack)
            self.ack_now()
            return
        }
        if flags & ACK == 0 { return }
        // the acknowledgement
        let acked = diff(ack, self.una)
        if diff(ack, self.nxt) > 0 {
            self.ack_now()            // acknowledges data we never sent
            return
        }
        if acked > 0 {
            let data_acked = min(acked, self.out.len)
            self.out.consume(data_acked)
            self.una = ack
            self.tries = 0
            self.rto = 1000
            self.sent_at = kernel.uptime()
            if self.fin_sent && ack == self.nxt {
                // our FIN is acknowledged
                if self.eof { self.time_wait() } else { self.state = "closing" }
            }
        }
        if acked >= 0 { self.wnd = win }
        // data, in order only
        var off = 0
        var n = data.len
        let d = diff(seq, self.rcv)
        if d < 0 {
            off = min(-d, n)          // already have the start of it
            n -= off
        } else if d > 0 {
            self.ack_now()            // a gap: remind them where we are
            return
        }
        if n > 0 && !self.eof {
            if !self.inbox.add(data.sub(off, n)) {
                self.stack.net.note("TCP limit", "a TCP connection from ${inet.fmt_ip(self.ip)} sent more than 4 MiB: dropped")
                self.abort()
                return
            }
            self.received += n
            self.rcv = (self.rcv + n) & MASK
            self.ack_due = true
        }
        if flags & FIN != 0 && diff(seq + data.len, self.rcv) == 0 && !self.eof {
            self.rcv = (self.rcv + 1) & MASK
            self.eof = true
            self.ack_now()
            if self.fin_sent && self.una == self.nxt { self.time_wait() }
        }
        self.push()
        self.notify()
    }

    fn time_wait(self) {
        self.state = "time-wait"
        self.last = kernel.uptime()
        self.notify()
    }

    fn tick(self, now: int) {
        if self.state == "time-wait" {
            if now - self.last > 5000 { self.stack.forget(self) }
            return
        }
        if self.state == "syn-sent" {
            if now - self.opened > 10_000 {
                self.finish("couldn't connect to ${inet.fmt_ip(self.ip)}:${self.rport} (timed out)")
                return
            }
        } else if now - self.last > 300_000 {
            self.finish("the connection went quiet for 5 minutes")
            return
        }
        // retransmit what's unacknowledged
        let pending = self.state == "syn-sent" || self.flight() > 0 || self.fin_sent && self.una != self.nxt
        if pending && now - self.sent_at > self.rto {
            self.tries += 1
            if self.tries > 8 {
                self.finish("connection to ${inet.fmt_ip(self.ip)} timed out")
                return
            }
            self.rto = min(self.rto * 2, 30_000)
            self.sent_at = now
            if self.state == "syn-sent" {
                self.segment(SYN, self.iss, 0, 0)
            } else {
                // go back to the oldest unacknowledged byte
                let had_fin = self.fin_sent && self.una != self.nxt
                self.nxt = self.una
                self.fin_sent = false
                if had_fin && self.state == "fin-wait" { self.state = "open" }
                if self.wnd == 0 { self.wnd = 1 }   // probe a closed window with one byte
                self.push()
            }
        } else if self.wnd == 0 && self.out.len > self.flight() && now - self.sent_at > self.rto {
            self.wnd = 1
            self.push()
        }
    }
}

// the MSS option in a SYN-ACK (bounds-checked; 536 if absent)
fn peer_mss(seg: bytes.View, hl: int) -> int {
    var i = 20
    while i < hl {
        let kind = seg.u8(i)
        if kind == 0 { break }
        if kind == 1 {
            i += 1
            continue
        }
        let len = seg.u8(i + 1)
        if len < 2 || seg.bad { break }
        if kind == 2 && len == 4 { return min(max(seg.u16(i + 2), 536), MSS) }
        i += len
    }
    return 536
}

struct Tcp {
    net: inet.Net,
    conns: {int: Conn} = {},

    // Open a connection to ip:port (it connects in the background: watch `connected()` / `error`).
    fn connect(self, ip: int, port: int) -> Conn! {
        if !self.net.up() { return err("the network isn't up yet") }
        if self.conns.len() >= MAX_CONNS { return err("too many connections") }
        if !inet.usable(ip) { return err("can't connect to ${inet.fmt_ip(ip)}") }
        let now = kernel.uptime()
        let c = Conn { stack: self, port: self.net.port(), ip, rport: port, opened: now, last: now, sent_at: now }
        c.iss = self.net.rand.u32()
        c.una = c.iss
        c.nxt = (c.iss + 1) & MASK
        self.conns[c.port] = c
        c.segment(SYN, c.iss, 0, 0)
        return c
    }

    fn forget(self, c: Conn) {
        if c.state != "time-wait" { c.state = "closed" }
        if let have = self.conns.get(c.port) {
            if have.ip == c.ip && have.rport == c.rport && c.state == "closed" {
                self.conns.remove(c.port)
                self.net.free_port(c.port)
            }
        }
        if c.state == "time-wait" {
            // time-wait over (called from tick): let the port go
            c.state = "closed"
            self.conns.remove(c.port)
            self.net.free_port(c.port)
        }
    }

    fn input(self, src: int, dst: int, seg: bytes.View) {
        if seg.len < 20 {
            self.net.count("bad TCP")
            return
        }
        let hl = (seg.u8(12) >> 4) * 4
        if hl < 20 || hl > seg.len {
            self.net.note("bad TCP", "dropped a malformed TCP segment from ${inet.fmt_ip(src)}")
            return
        }
        if bytes.checksum(seg.sum(self.net.pseudo(src, dst, inet.TCP, seg.len))) != 0 {
            self.net.count("bad TCP checksums")
            return
        }
        let sport = seg.u16(0)
        let dport = seg.u16(2)
        let flags = seg.u8(13)
        if let c = self.conns.get(dport) {
            if c.ip == src && c.rport == sport && c.state != "closed" {
                c.input(seg, hl)
                return
            }
        }
        if flags & SYN != 0 && flags & ACK == 0 {
            self.net.note("TCP in", "refused a connection from ${inet.fmt_ip(src)} to port ${dport} (nothing listens)")
        } else if flags & RST == 0 {
            self.net.note("TCP stray", "dropped a TCP segment for no connection (from ${inet.fmt_ip(src)}:${sport} to port ${dport})")
        }
    }

    fn tick(self) {
        let now = kernel.uptime()
        for port in self.conns.keys() {
            if let c = self.conns.get(port) { c.tick(now) }
        }
    }

    fn flush(self) {
        for port in self.conns.keys() {
            if let c = self.conns.get(port) {
                if c.ack_due { c.ack_now() }
            }
        }
    }
}

fn start(net: inet.Net) -> Tcp {
    let t = Tcp { net }
    net.tcp_in.push((src: int, dst: int, seg: bytes.View) => t.input(src, dst, seg))
    net.tickers.push(() => t.tick())
    net.flushers.push(() => t.flush())
    return t
}
