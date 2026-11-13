// inet: the network stack: Ethernet, ARP, IPv4, ICMP (ping), UDP, DHCP (getting an address) and DNS
// (names to addresses). TCP sits on top of this in tcp.st, HTTP on top of that in http.st.
//
// Built to be hard to attack:
// - every byte from the wire is read through bytes.View, which checks its range (a packet that lies
//   about its lengths reads zeros and is dropped, it can't make us read or write out of bounds);
//   checksums are checked; IP fragments (a favorite for attacks) are refused, not reassembled
// - nothing listens: a packet for a port nobody opened is dropped without an answer (a port scan sees
//   nothing at all), and UDP replies count only from the server we asked
// - pings are not answered unless `firewall ping on` (rate-limited then); broadcast pings never are
// - ARP: we learn addresses only from answers to questions we asked (no cache poisoning by
//   unsolicited replies), and a second, different answer is logged as a likely spoof
// - DNS: random query ids and random source ports, answers must match the question; DHCP: random
//   transaction ids; the random numbers come from rng.st (a ChaCha20 generator seeded by the host)
// - a security log (`firewall log`) keeps what was refused

import kernel
import bytes
import nic
import rng

const ETH_IP = 0x0800
const ETH_ARP = 0x0806
const ICMP = 1
const TCP = 6
const UDP = 17
const ALL = 0xffff_ffff       // the broadcast address 255.255.255.255
const BCAST_MAC = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff]

const ARP_TTL = 300_000       // ms an ARP answer stays good
const ARP_RETRY = 1000
const WAIT_ARP = 3000         // how long a frame waits for its next hop's address
const PING_RATE = 20          // answers per second, when ping answering is on

// A frame built and waiting for its next hop's hardware address.
struct Pending {
    hop: int,
    out: bytes.Out,
    at: int,
}

struct Neighbor {
    mac: [int],
    at: int,
}

// An open UDP port. `peer_ip` (if not 0) is the only sender it takes packets from.
struct Udp {
    port: int,
    peer_ip: int = 0,
    peer_port: int = 0,
    on: fn(int, int, bytes.View),     // source address, source port, data
}

// A ping in progress: our echo requests and the answers.
struct Ping {
    id: int,
    target: int,
    sent: {int: int} = {},    // sequence number -> when
    rtt: {int: int} = {},     // sequence number -> round trip in microseconds
    ttl: {int: int} = {},
    error: str = "",
}

struct Query {
    id: int,
    name: str,
    port: int,
    tries: int = 0,
    at: int = 0,
    done: fn([int], str),
}

struct Cached {
    ips: [int],
    until: int,
    error: str = "",
}

struct Dhcp {
    state: str = "off",       // off, discovering, requesting, bound, renewing
    xid: int = 0,
    offered: int = 0,
    server: int = 0,
    at: int = 0,
    tries: int = 0,
    lease_end: int = 0,
    renew_at: int = 0,
}

struct Net {
    card: nic.Nic,
    rand: rng.Rng,
    mac: [int],
    ip: int = 0,
    mask: int = 0,
    gateway: int = 0,
    dns: int = 0,
    dns_port: int = 53,
    dhcp: Dhcp = Dhcp {},
    neighbors: {int: Neighbor} = {},
    asked: {int: int} = {},   // ARP questions out: address -> when
    waiting: [Pending] = [],
    udp: {int: Udp} = {},
    ports: {int} = {},        // local ports in use (UDP and TCP)
    pings: {int: Ping} = {},
    queries: {int: Query} = {},
    cache: {str: Cached} = {},
    ip_id: int = 0,
    tcp_in: [fn(int, int, bytes.View)] = [],   // the TCP layer (tcp.st), when there is one
    tickers: [fn()] = [],
    flushers: [fn()] = [],    // run after each batch of frames (TCP sends its ACKs then)
    answer_pings: bool = false,
    ping_budget: int = PING_RATE,
    budget_at: int = 0,
    counts: {str: int} = {},
    log: [str] = [],
    log_at: {str: int} = {},

    // ---- bookkeeping ----

    fn count(self, what: str) {
        self.counts[what] = (self.counts.get(what) ?? 0) + 1
    }

    // a note for the security log (the same kind of note at most once a second)
    fn note(self, kind: str, text: str) {
        self.count(kind)
        let now = kernel.uptime()
        if now - (self.log_at.get(kind) ?? -10_000) < 1000 { return }
        self.log_at[kind] = now
        let d = kernel.date(kernel.time_ms())
        self.log.push("${kernel.two(d.hour)}:${kernel.two(d.minute)}:${kernel.two(d.second)}  ${text}")
        if self.log.len() > 50 { self.log.remove(0) }
    }

    fn up(self) -> bool {
        return self.ip != 0
    }

    // a free local port for an outgoing connection, picked at random (49152..65535)
    fn port(self) -> int {
        while true {
            let p = 49152 + self.rand.below(16384)
            if !self.ports.contains(p) {
                self.ports.add(p)
                return p
            }
        }
        return 0
    }

    fn free_port(self, p: int) {
        self.ports.remove(p)
        self.udp.remove(p)
    }

    // ---- the main loop's part: called from timers ----

    fn poll(self) {
        if self.card.poll(64, (v: bytes.View) => self.frame(v)) > 0 {
            for f in self.flushers { f() }
        }
    }

    fn tick(self) {
        let now = kernel.uptime()
        // frames waiting on ARP: ask again, or give up
        var keep: [Pending] = []
        for p in self.waiting {
            if now - p.at > WAIT_ARP {
                self.card.release(p.out)
                self.count("no route (no ARP answer)")
            } else {
                keep.push(p)
                if now - (self.asked.get(p.hop) ?? 0) > ARP_RETRY { self.arp_ask(p.hop) }
            }
        }
        self.waiting = keep
        for ip in self.asked.keys() {
            if now - (self.asked.get(ip) ?? 0) > 10_000 { self.asked.remove(ip) }
        }
        self.dhcp_tick(now)
        self.dns_tick(now)
        for f in self.tickers { f() }
    }

    // ---- Ethernet ----

    fn frame(self, v: bytes.View) {
        if v.len < 14 {
            self.count("runt frames")
            return
        }
        let to_us = same_mac(v, 0, self.mac)
        if !to_us && !same_mac(v, 0, BCAST_MAC) {
            self.count("frames for other machines")
            return
        }
        let kind = v.u16(12)
        let body = v.from(14)
        if kind == ETH_ARP {
            self.arp_in(body, v)
        } else if kind == ETH_IP {
            self.ip_in(body, to_us)
        } else {
            self.count("other protocols")
        }
    }

    // start a frame: Ethernet header (destination filled in when sending)
    fn begin_frame(self, kind: int) -> bytes.Out? {
        if let o = self.card.buffer() {
            o.zeros(6)
            o.bytes(self.mac)
            o.u16(kind)
            return some(o)
        }
        return none
    }

    fn send_to(self, o: bytes.Out, mac: [int]) {
        for i in 0..6 { kernel.poke8(o.addr + i, mac[i]) }
        self.card.send(o)
    }

    // ---- ARP: who has which IP address on the LAN ----

    fn arp_in(self, a: bytes.View, frame: bytes.View) {
        if a.len < 28 || a.u16(0) != 1 || a.u16(2) != ETH_IP || a.u8(4) != 6 || a.u8(5) != 4 {
            self.count("bad ARP")
            return
        }
        let op = a.u16(6)
        let sender_ip = a.u32(14)
        let target_ip = a.u32(24)
        var sender_mac: [int] = []
        for i in 8..14 { sender_mac.push(a.u8(i)) }
        if sender_mac[0] & 1 != 0 || sender_ip == 0 {
            self.note("bad ARP", "dropped an ARP packet with a broadcast sender (${fmt_ip(sender_ip)})")
            return
        }
        if op == 1 {
            // a question: answer it if it's about us (we don't learn from questions)
            if self.ip != 0 && target_ip == self.ip { self.arp_send(2, sender_mac, sender_ip) }
            return
        }
        if op != 2 { return }
        if target_ip != self.ip || !same_mac(a, 18, self.mac) {
            self.note("ARP spoof", "dropped an ARP answer not meant for us (${fmt_ip(sender_ip)} is at ${fmt_mac(sender_mac)})")
            return
        }
        if !self.asked.contains(sender_ip) {
            if let n = self.neighbors.get(sender_ip) {
                if fmt_mac(n.mac) != fmt_mac(sender_mac) {
                    self.note("ARP spoof", "ignored an unasked ARP answer: ${fmt_ip(sender_ip)} is at ${fmt_mac(sender_mac)}, we know ${fmt_mac(n.mac)} (spoofing?)")
                    return
                }
            }
            self.count("unasked ARP answers")
            return
        }
        self.asked.remove(sender_ip)
        self.neighbors[sender_ip] = Neighbor { mac: sender_mac, at: kernel.uptime() }
        // send what was waiting for this address
        var keep: [Pending] = []
        for p in self.waiting {
            if p.hop == sender_ip { self.send_to(p.out, sender_mac) } else { keep.push(p) }
        }
        self.waiting = keep
    }

    fn arp_ask(self, ip: int) {
        self.asked[ip] = kernel.uptime()
        self.arp_send(1, [0, 0, 0, 0, 0, 0], ip)
    }

    fn arp_send(self, op: int, to_mac: [int], to_ip: int) {
        if let o = self.begin_frame(ETH_ARP) {
            o.u16(1)
            o.u16(ETH_IP)
            o.u8(6)
            o.u8(4)
            o.u16(op)
            o.bytes(self.mac)
            o.u32(self.ip)
            o.bytes(to_mac)
            o.u32(to_ip)
            self.send_to(o, if op == 1 { BCAST_MAC } else { to_mac })
        }
    }

    // ---- IPv4 ----

    fn local(self, ip: int) -> bool {
        return self.mask != 0 && (ip & self.mask) == (self.ip & self.mask)
    }

    fn broadcast_addr(self) -> int {
        return (self.ip & self.mask) | (~self.mask & ALL)
    }

    fn ip_in(self, p: bytes.View, to_our_mac: bool) {
        if p.len < 20 || p.u8(0) >> 4 != 4 {
            self.count("bad IP")
            return
        }
        let hl = (p.u8(0) & 15) * 4
        let total = p.u16(2)
        if hl < 20 || total < hl || total > p.len {
            self.note("bad IP", "dropped a malformed IP packet (header ${hl}, length ${total}, frame ${p.len})")
            return
        }
        if bytes.checksum(p.sub(0, hl).sum(0)) != 0 {
            self.count("bad IP checksums")
            return
        }
        let frag = p.u16(6)
        let src = p.u32(12)
        let dst = p.u32(16)
        if frag & 0x2000 != 0 || frag & 0x1fff != 0 {
            self.note("fragments", "refused an IP fragment from ${fmt_ip(src)}")
            return
        }
        if src == 0 || src == ALL || src >> 28 == 14 || src >> 24 == 127 || (self.ip != 0 && src == self.ip) {
            self.note("martians", "dropped a packet with an impossible source address ${fmt_ip(src)}")
            return
        }
        let bcast = dst == ALL || (self.mask != 0 && dst == self.broadcast_addr())
        if !bcast && self.ip != 0 && dst != self.ip {
            self.count("packets for other addresses")
            return
        }
        let proto = p.u8(9)
        let body = p.sub(hl, total - hl)
        if bcast || self.ip == 0 {
            // only DHCP is welcome on broadcasts (or before we have an address)
            if proto == UDP { self.udp_in(body, src, dst, true) } else { self.count("broadcasts ignored") }
            return
        }
        if proto == ICMP {
            self.icmp_in(body, src, p.u8(8))
        } else if proto == UDP {
            self.udp_in(body, src, dst, false)
        } else if proto == TCP {
            for f in self.tcp_in { f(src, dst, body) }
        } else {
            self.count("other IP protocols")
        }
    }

    // Start an IP packet to `dst`; write the payload into the Out, then `ip_send` it.
    fn ip_begin(self, dst: int, proto: int) -> bytes.Out? {
        if let o = self.begin_frame(ETH_IP) {
            self.ip_id = (self.ip_id + 1) & 0xffff
            o.u8(0x45)
            o.u8(0)
            o.u16(0)                      // total length: later
            o.u16(self.ip_id)
            o.u16(0x4000)                 // don't fragment
            o.u8(64)                      // time to live
            o.u8(proto)
            o.u16(0)                      // checksum: later
            o.u32(self.ip)
            o.u32(dst)
            return some(o)
        }
        return none
    }

    fn ip_send(self, o: bytes.Out) {
        if o.full {
            self.card.release(o)
            return
        }
        o.set16(16, o.len - 14)
        o.set16(24, bytes.checksum(o.view_of(14, 20).sum(0)))
        let dst = o.view_of(30, 4).u32(0)
        if dst == ALL || (self.mask != 0 && dst == self.broadcast_addr()) {
            self.send_to(o, BCAST_MAC)
            return
        }
        if self.ip == 0 {
            self.card.release(o)
            return
        }
        let hop = if self.local(dst) { dst } else { self.gateway }
        if hop == 0 {
            self.card.release(o)
            self.count("no route")
            return
        }
        if let n = self.neighbors.get(hop) {
            if kernel.uptime() - n.at < ARP_TTL {
                self.send_to(o, n.mac)
                return
            }
        }
        if self.waiting.len() >= 16 {
            self.card.release(o)
            self.count("no route (too many waiting)")
            return
        }
        self.waiting.push(Pending { hop, out: o, at: kernel.uptime() })
        if kernel.uptime() - (self.asked.get(hop) ?? -10_000) > ARP_RETRY { self.arp_ask(hop) }
    }

    // the checksum sum of the "pseudo header" TCP and UDP checksums cover
    fn pseudo(self, src: int, dst: int, proto: int, len: int) -> int {
        return (src >> 16) + (src & 0xffff) + (dst >> 16) + (dst & 0xffff) + proto + len
    }

    // ---- ICMP ----

    fn icmp_in(self, m: bytes.View, src: int, ttl: int) {
        if m.len < 8 || bytes.checksum(m.sum(0)) != 0 {
            self.count("bad ICMP")
            return
        }
        let kind = m.u8(0)
        if kind == 0 {
            // an echo reply: one of our pings?
            if let p = self.pings.get(m.u16(4)) {
                let seq = m.u16(6)
                if p.target == src && p.sent.contains(seq) && !p.rtt.contains(seq) {
                    p.rtt[seq] = max((st_k_cycles() - (p.sent.get(seq) ?? 0)) / 10, 1)
                    p.ttl[seq] = ttl
                } else {
                    self.count("unexpected ping replies")
                }
            } else {
                self.note("ping replies", "ignored a ping reply we didn't ask for, from ${fmt_ip(src)}")
            }
            return
        }
        if kind == 8 {
            if !self.answer_pings {
                self.note("pings", "didn't answer a ping from ${fmt_ip(src)} (`firewall ping on` to answer)")
                return
            }
            let now = kernel.uptime()
            if now - self.budget_at >= 1000 {
                self.budget_at = now
                self.ping_budget = PING_RATE
            }
            if self.ping_budget <= 0 {
                self.note("ping flood", "too many pings from ${fmt_ip(src)}: not answering all of them")
                return
            }
            self.ping_budget -= 1
            if let o = self.ip_begin(src, ICMP) {
                let start = o.len
                o.u8(0)
                o.u8(0)
                o.u16(0)
                o.view(m.from(4))
                o.set16(start + 2, bytes.checksum(o.view_of(start, o.len - start).sum(0)))
                self.ip_send(o)
            }
            return
        }
        if kind == 3 || kind == 11 {
            // unreachable / time exceeded: it quotes our packet; tell the ping it was about
            let q = m.from(8)
            let qhl = (q.u8(0) & 15) * 4
            if q.u8(9) == ICMP && !q.bad {
                if let p = self.pings.get(q.u16(qhl + 4)) {
                    p.error = if kind == 3 { "${fmt_ip(src)}: destination unreachable" } else { "${fmt_ip(src)}: time to live exceeded" }
                }
            }
            return
        }
        self.count("other ICMP")
    }

    // Start pinging `target`: send with `ping_send`, answers land in the Ping.
    fn ping_open(self, target: int) -> Ping {
        var id = self.rand.u16()
        while self.pings.contains(id) { id = self.rand.u16() }
        let p = Ping { id, target }
        self.pings[id] = p
        return p
    }

    fn ping_send(self, p: Ping, seq: int, size: int) {
        if let o = self.ip_begin(p.target, ICMP) {
            let start = o.len
            o.u8(8)
            o.u8(0)
            o.u16(0)
            o.u16(p.id)
            o.u16(seq)
            for i in 0..min(max(size, 0), 1400) { o.u8(0x20 + i % 64) }
            o.set16(start + 2, bytes.checksum(o.view_of(start, o.len - start).sum(0)))
            p.sent[seq] = st_k_cycles()
            self.ip_send(o)
        }
    }

    fn ping_close(self, p: Ping) {
        self.pings.remove(p.id)
    }

    // ---- UDP ----

    fn udp_in(self, u: bytes.View, src: int, dst: int, bcast: bool) {
        if u.len < 8 {
            self.count("bad UDP")
            return
        }
        let len = u.u16(4)
        if len < 8 || len > u.len {
            self.note("bad UDP", "dropped a malformed UDP packet from ${fmt_ip(src)}")
            return
        }
        let d = u.sub(0, len)
        if u.u16(6) != 0 && bytes.checksum(d.sum(self.pseudo(src, dst, UDP, len))) != 0 {
            self.count("bad UDP checksums")
            return
        }
        let sport = u.u16(0)
        let dport = u.u16(2)
        if let s = self.udp.get(dport) {
            if bcast && dport != 68 {
                self.count("broadcasts ignored")
                return
            }
            if s.peer_ip != 0 && (src != s.peer_ip || sport != s.peer_port) {
                self.note("UDP spoof", "dropped a UDP packet for port ${dport} from ${fmt_ip(src)}:${sport}, not the server we asked")
                return
            }
            s.on(src, sport, d.from(8))
        } else {
            self.note("closed ports", "dropped a UDP packet from ${fmt_ip(src)}:${sport} for closed port ${dport}")
        }
    }

    fn udp_open(self, port: int, peer_ip: int, peer_port: int, on: fn(int, int, bytes.View)) -> Udp {
        let s = Udp { port, peer_ip, peer_port, on }
        self.udp[port] = s
        self.ports.add(port)
        return s
    }

    // Start a UDP packet; write the data, then `udp_send`.
    fn udp_begin(self, sport: int, dst: int, dport: int) -> bytes.Out? {
        if let o = self.ip_begin(dst, UDP) {
            o.u16(sport)
            o.u16(dport)
            o.u16(0)
            o.u16(0)
            return some(o)
        }
        return none
    }

    fn udp_send(self, o: bytes.Out) {
        let start = 34
        let len = o.len - start
        o.set16(start + 4, len)
        let src = o.view_of(26, 4).u32(0)
        let dst = o.view_of(30, 4).u32(0)
        var c = bytes.checksum(o.view_of(start, len).sum(self.pseudo(src, dst, UDP, len)))
        if c == 0 { c = 0xffff }
        o.set16(start + 6, c)
        self.ip_send(o)
    }

    // ---- DHCP: ask the network for an address ----

    fn dhcp_start(self) {
        if !self.udp.contains(68) { self.udp_open(68, 0, 0, (src: int, sport: int, v: bytes.View) => self.dhcp_in(src, sport, v)) }
        self.dhcp.state = "discovering"
        self.dhcp.tries = 0
        self.dhcp.xid = self.rand.u32()
        self.dhcp_send(1)
    }

    fn dhcp_send(self, kind: int) {
        self.dhcp.at = kernel.uptime()
        self.dhcp.tries += 1
        let renewing = self.dhcp.state == "renewing"
        if let o = self.udp_begin(68, ALL, 67) {
            o.u8(1)
            o.u8(1)
            o.u8(6)
            o.u8(0)
            o.u32(self.dhcp.xid)
            o.u16(0)
            o.u16(if renewing { 0 } else { 0x8000 })   // answer by broadcast: we have no address yet
            o.u32(if renewing { self.ip } else { 0 })
            o.zeros(12)
            o.bytes(self.mac)
            o.zeros(10 + 64 + 128)
            o.u32(0x6382_5363)
            o.bytes([53, 1, kind])
            if kind == 3 && !renewing {
                o.bytes([50, 4])
                o.u32(self.dhcp.offered)
                o.bytes([54, 4])
                o.u32(self.dhcp.server)
            }
            o.bytes([55, 4, 1, 3, 6, 51])
            o.u8(255)
            self.udp_send(o)
        }
    }

    fn dhcp_in(self, src: int, sport: int, m: bytes.View) {
        if sport != 67 || m.len < 240 || m.u8(0) != 2 || m.u32(4) != self.dhcp.xid || !same_mac(m, 28, self.mac) || m.u32(236) != 0x6382_5363 {
            self.note("DHCP", "dropped a DHCP answer that isn't for our request (from ${fmt_ip(src)})")
            return
        }
        // options: code, length, value; checked against the end of the packet
        var kind = 0
        var mask = 0
        var router = 0
        var dns = 0
        var lease = 3600
        var server = src
        var i = 240
        while i < m.len {
            let code = m.u8(i)
            if code == 255 { break }
            if code == 0 {
                i += 1
                continue
            }
            let n = m.u8(i + 1)
            let v = m.sub(i + 2, n)
            if v.bad { break }
            if code == 53 && n >= 1 { kind = v.u8(0) }
            if code == 1 && n >= 4 { mask = v.u32(0) }
            if code == 3 && n >= 4 { router = v.u32(0) }
            if code == 6 && n >= 4 { dns = v.u32(0) }
            if code == 51 && n >= 4 { lease = v.u32(0) }
            if code == 54 && n >= 4 { server = v.u32(0) }
            i += 2 + n
        }
        let yours = m.u32(16)
        if kind == 2 && self.dhcp.state == "discovering" {
            if !usable(yours) { return }
            self.dhcp.offered = yours
            self.dhcp.server = server
            self.dhcp.state = "requesting"
            self.dhcp.tries = 0
            self.dhcp_send(3)
        } else if kind == 5 && (self.dhcp.state == "requesting" || self.dhcp.state == "renewing") {
            if !usable(yours) || mask == 0 || (mask | (mask - 1)) & ALL != ALL { return }
            self.ip = yours
            self.mask = mask
            self.gateway = if router != 0 && (router & mask) == (yours & mask) { router } else { 0 }
            if dns != 0 { self.dns = dns }
            let secs = min(max(lease, 60), 86400 * 7)
            let now = kernel.uptime()
            self.dhcp.lease_end = now + secs * 1000
            self.dhcp.renew_at = now + secs * 500
            self.dhcp.state = "bound"
        } else if kind == 6 {
            self.note("DHCP", "the DHCP server took our address back")
            self.ip = 0
            self.dhcp_start()
        }
    }

    fn dhcp_tick(self, now: int) {
        let d = self.dhcp
        if d.state == "discovering" || d.state == "requesting" {
            if now - d.at > min(2000 * d.tries, 8000) {
                if d.state == "requesting" && d.tries >= 4 {
                    self.dhcp_start()
                } else {
                    self.dhcp_send(if d.state == "requesting" { 3 } else { 1 })
                }
            }
        } else if d.state == "bound" && now > d.renew_at {
            d.state = "renewing"
            d.xid = self.rand.u32()
            d.tries = 0
            self.dhcp_send(3)
        } else if d.state == "renewing" {
            if now > d.lease_end {
                self.note("DHCP", "our address lease ran out")
                self.ip = 0
                self.dhcp_start()
            } else if now - d.at > 5000 {
                self.dhcp_send(3)
            }
        }
    }

    // ---- DNS: names to addresses ----

    // Look up a host name's IPv4 addresses; `done` gets them, or an error message.
    fn resolve(self, name: str, done: fn([int], str)) {
        let host = name.lower().trim()
        if let ip = parse_ip(host) {
            done([ip], "")
            return
        }
        if !valid_name(host) {
            done([], "not a valid host name: ${name}")
            return
        }
        if let c = self.cache.get(host) {
            if kernel.uptime() < c.until {
                done(c.ips, c.error)
                return
            }
            self.cache.remove(host)
        }
        if self.dns == 0 {
            done([], "no DNS server (the network isn't set up yet)")
            return
        }
        var id = self.rand.u16()
        while self.queries.contains(id) { id = self.rand.u16() }
        let port = self.port()
        let q = Query { id, name: host, port, done }
        self.queries[id] = q
        self.udp_open(port, self.dns, self.dns_port, (src: int, sport: int, v: bytes.View) => self.dns_in(q, v))
        self.dns_send(q)
    }

    fn dns_send(self, q: Query) {
        q.tries += 1
        q.at = kernel.uptime()
        if let o = self.udp_begin(q.port, self.dns, self.dns_port) {
            o.u16(q.id)
            o.u16(0x0100)             // a standard query; recursion please
            o.u16(1)
            o.u16(0)
            o.u16(0)
            o.u16(0)
            for label in q.name.split(".") {
                o.u8(label.len())
                o.text(label)
            }
            o.u8(0)
            o.u16(1)                  // A
            o.u16(1)                  // IN
            self.udp_send(o)
        }
    }

    fn dns_finish(self, q: Query, ips: [int], error: str, ttl: int) {
        self.queries.remove(q.id)
        self.free_port(q.port)
        if self.cache.len() > 256 { self.cache = {} }
        self.cache[q.name] = Cached { ips, error, until: kernel.uptime() + min(max(ttl, 5), 3600) * 1000 }
        q.done(ips, error)
    }

    fn dns_in(self, q: Query, m: bytes.View) {
        if !self.queries.contains(q.id) { return }
        if m.len < 12 || m.u16(0) != q.id || m.u16(2) & 0x8000 == 0 || m.u16(4) != 1 {
            self.note("DNS spoof", "dropped a DNS answer that doesn't match our question about ${q.name}")
            return
        }
        // the question must be ours
        let qn = read_name(m, 12)
        if qn.bad || qn.name != q.name || m.u16(qn.next) != 1 || m.u16(qn.next + 2) != 1 {
            self.note("DNS spoof", "dropped a DNS answer for a different question (${qn.name}, we asked about ${q.name})")
            return
        }
        let rcode = m.u16(2) & 15
        if rcode == 3 {
            self.dns_finish(q, [], "no such host: ${q.name}", 30)
            return
        }
        if rcode != 0 {
            self.dns_finish(q, [], "the DNS server couldn't answer (code ${rcode})", 5)
            return
        }
        var names = [q.name]          // the name and its aliases (CNAMEs)
        var ips: [int] = []
        var ttl = 3600
        var at = qn.next + 4
        for i in 0..min(m.u16(6), 32) {
            let rn = read_name(m, at)
            if rn.bad { break }
            let kind = m.u16(rn.next)
            let rttl = m.u32(rn.next + 4)
            let rlen = m.u16(rn.next + 8)
            let data = rn.next + 10
            if m.sub(data, rlen).bad { break }
            if names.contains(rn.name) {
                if kind == 5 {
                    let alias = read_name(m, data)
                    if !alias.bad && names.len() < 8 { names.push(alias.name) }
                } else if kind == 1 && rlen == 4 {
                    let ip = m.u32(data)
                    if usable(ip) && !ips.contains(ip) { ips.push(ip) }
                    ttl = min(ttl, rttl)
                }
            }
            at = data + rlen
        }
        if ips.is_empty() {
            self.dns_finish(q, [], "${q.name} has no IPv4 address", 30)
        } else {
            self.dns_finish(q, ips, "", ttl)
        }
    }

    fn dns_tick(self, now: int) {
        for id in self.queries.keys() {
            if let q = self.queries.get(id) {
                if now - q.at > 1500 {
                    if q.tries >= 3 {
                        self.queries.remove(id)
                        self.free_port(q.port)
                        q.done([], "no answer from the DNS server (${fmt_ip(self.dns)})")
                    } else {
                        self.dns_send(q)
                    }
                }
            }
        }
    }

    // ---- waiting (for the shell; apps on the desktop use the callbacks) ----

    // Run the main loop until `done()` or `ms` pass. Returns done().
    fn wait(self, ms: int, done: fn() -> bool) -> bool {
        let until = kernel.uptime() + ms
        while !done() && kernel.uptime() < until { kernel.idle() }
        return done()
    }

    fn lookup(self, name: str) -> [int]! {
        var result: [int] = []
        var error = ""
        var finished = false
        self.resolve(name, (ips: [int], e: str) => {
            result = ips
            error = e
            finished = true
        })
        self.wait(6000, () => finished)
        if !finished { return err("DNS lookup timed out") }
        if error != "" { return err(error) }
        return result
    }
}

extern fn st_k_cycles() -> int

// a name as DNS reads it, and where the bytes after it start
struct Name {
    name: str,
    next: int,
    bad: bool = false,
}

// Read a (possibly compressed) DNS name. Pointers are followed at most 16 times and must point
// backwards, so a malicious answer can't make us loop.
fn read_name(m: bytes.View, start: int) -> Name {
    var labels: [str] = []
    var at = start
    var next = -1
    var jumps = 0
    var total = 0
    while true {
        let n = m.u8(at)
        if m.bad { return Name { name: "", next: 0, bad: true } }
        if n == 0 {
            if next < 0 { next = at + 1 }
            break
        }
        if n & 0xc0 == 0xc0 {
            let to = ((n & 0x3f) << 8) | m.u8(at + 1)
            jumps += 1
            if jumps > 16 || to >= at || m.bad { return Name { name: "", next: 0, bad: true } }
            if next < 0 { next = at + 2 }
            at = to
            continue
        }
        if n > 63 { return Name { name: "", next: 0, bad: true } }
        total += n + 1
        if total > 255 { return Name { name: "", next: 0, bad: true } }
        let label = m.text(at + 1, n)
        if m.bad { return Name { name: "", next: 0, bad: true } }
        labels.push(label.lower())
        at += 1 + n
    }
    return Name { name: labels.join("."), next }
}

fn valid_name(s: str) -> bool {
    if s == "" || s.len() > 253 { return false }
    for label in s.split(".") {
        if label == "" || label.len() > 63 { return false }
    }
    for c in s.chars() {
        if !("abcdefghijklmnopqrstuvwxyz0123456789-_.".contains(c)) { return false }
    }
    return true
}

// an address a host can have (not 0, broadcast, multicast or loopback)
fn usable(ip: int) -> bool {
    return ip != 0 && ip != ALL && ip >> 28 != 14 && ip >> 28 != 15 && ip >> 24 != 127 && ip >> 24 != 0
}

fn same_mac(v: bytes.View, off: int, mac: [int]) -> bool {
    for i in 0..6 {
        if v.u8(off + i) != mac[i] { return false }
    }
    return !v.bad
}

fn fmt_ip(ip: int) -> str {
    return "${(ip >> 24) & 255}.${(ip >> 16) & 255}.${(ip >> 8) & 255}.${ip & 255}"
}

fn fmt_mac(m: [int]) -> str {
    let d = "0123456789abcdef".chars()
    return m.map(b => d[(b >> 4) & 15] + d[b & 15]).join(":")
}

fn parse_ip(s: str) -> int? {
    let parts = s.split(".")
    if parts.len() != 4 { return none }
    var ip = 0
    for p in parts {
        if p == "" || p.len() > 3 { return none }
        for c in p.chars() {
            if !"0123456789".contains(c) { return none }
        }
        let n = int(p) catch 256
        if n > 255 { return none }
        ip = (ip << 8) | n
    }
    return some(ip)
}

fn mask_bits(mask: int) -> int {
    var n = 0
    var m = mask
    while m & 0x8000_0000 != 0 {
        n += 1
        m = (m << 1) & ALL
    }
    return n
}

// Bring up the network: the card, the random number generator, DHCP. none without a card.
fn open(r: rng.Rng) -> Net? {
    if let card = nic.open() {
        let n = Net { card, rand: r, mac: card.mac }
        n.ip_id = r.u16()
        kernel.every(1, () => n.poll())
        kernel.every(50, () => n.tick())
        n.dhcp_start()
        return some(n)
    }
    return none
}
