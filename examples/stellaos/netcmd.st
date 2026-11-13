// The shell's network commands: ifconfig, ping, host, arp, netstat, firewall, fetch.

import kernel
import inet
import tcp
import www
import ramfs


// `ifconfig`, `ifconfig set <ip>/<bits> [gateway]`, `ifconfig dhcp`
fn ifconfig(n: inet.Net, argv: [str]) -> void! {
    let what = argv.get(0) ?? ""
    if what == "set" {
        let spec = need(argv, 1, "ifconfig set <ip>/<bits> [gateway]")?.split("/")
        let ip = inet.parse_ip(spec[0]) ?? 0
        let bits = if spec.len() > 1 { int(spec[1]) catch -1 } else { 24 }
        if !inet.usable(ip) || bits < 8 || bits > 30 { return err("usage: ifconfig set <ip>/<bits> [gateway]") }
        n.dhcp.state = "off"
        n.ip = ip
        n.mask = (inet.ALL << (32 - bits)) & inet.ALL
        n.gateway = inet.parse_ip(argv.get(2) ?? "") ?? 0
        n.neighbors = {}
        show(n)
        return
    }
    if what == "dhcp" {
        n.ip = 0
        n.dhcp_start()
        println("asking for an address (DHCP)")
        return
    }
    show(n)
}

fn need(argv: [str], i: int, usage: str) -> str! {
    if let a = argv.get(i) { return a }
    return err("usage: ${usage}")
}

fn show(n: inet.Net) {
    let c = n.card
    println("${kernel.ESC}[1meth0${kernel.ESC}[0m  ${if n.up() { "up" } else { "waiting for an address (DHCP: ${n.dhcp.state})" }}")
    println("      hardware ${inet.fmt_mac(n.mac)}")
    if n.up() {
        println("      address  ${inet.fmt_ip(n.ip)}/${inet.mask_bits(n.mask)}  (netmask ${inet.fmt_ip(n.mask)})")
        println("      gateway  ${if n.gateway != 0 { inet.fmt_ip(n.gateway) } else { "none" }}")
        println("      dns      ${if n.dns != 0 { inet.fmt_ip(n.dns) } else { "none" }}${if n.dns_port != 53 { ":${n.dns_port}" } else { "" }}")
        let left = (n.dhcp.lease_end - kernel.uptime()) / 1000
        println("      lease    ${left / 60} min left")
    }
    println("      frames   ${c.received} in, ${c.sent} out${if c.dropped > 0 { ", ${c.dropped} dropped (no buffer)" } else { "" }}")
    println("      random   ${if n.rand.strong() { "ChaCha20, seeded by the host (virtio-rng)" } else { "ChaCha20, seeded by timer jitter only (no virtio-rng: weaker)" }}")
}

// `ping [-c n] [-s size] host`
fn ping(n: inet.Net, argv: [str]) -> void! {
    var count = 4
    var size = 56
    var host = ""
    var i = 0
    while i < argv.len() {
        let a = argv[i]
        if a == "-c" && i + 1 < argv.len() {
            count = min(max(int(argv[i + 1])?, 1), 100)
            i += 2
        } else if a == "-s" && i + 1 < argv.len() {
            size = min(max(int(argv[i + 1])?, 0), 1400)
            i += 2
        } else {
            host = a
            i += 1
        }
    }
    if host == "" { return err("usage: ping [-c count] [-s size] <host>") }
    if !n.up() { return err("the network isn't up yet (see `ifconfig`)") }
    let ips = n.lookup(host)?
    let target = ips[0]
    println("PING ${host} (${inet.fmt_ip(target)}): ${size} data bytes")
    let p = n.ping_open(target)
    var got = 0
    var times: [int] = []
    for seq in 1..count + 1 {
        let start = kernel.uptime()
        n.ping_send(p, seq, size)
        n.wait(1000, () => p.rtt.contains(seq) || p.error != "")
        if let us = p.rtt.get(seq) {
            got += 1
            times.push(us)
            println("${size + 8} bytes from ${inet.fmt_ip(target)}: seq=${seq} ttl=${p.ttl.get(seq) ?? 0} time=${micros(us)}")
        } else if p.error != "" {
            println("${p.error} (seq=${seq})")
            p.error = ""
        } else {
            println("no answer (seq=${seq})")
        }
        // one a second
        if seq < count { n.wait(max(1000 - (kernel.uptime() - start), 0), () => false) }
    }
    n.ping_close(p)
    let lost = (count - got) * 100 / count
    println("--- ${host} ---")
    print("${count} sent, ${got} received, ${lost}% lost")
    if !times.is_empty() {
        var lo = times[0]
        var hi = times[0]
        for t in times {
            lo = min(lo, t)
            hi = max(hi, t)
        }
        print(", round trip min/avg/max ${micros(lo)}/${micros(times.sum() / times.len())}/${micros(hi)}")
    }
    println("")
}

fn micros(us: int) -> str {
    if us < 1000 { return "0.${us / 100} ms" }
    return "${us / 1000}.${us % 1000 / 100} ms"
}

fn host(n: inet.Net, argv: [str]) -> void! {
    let name = argv.get(0) ?? ""
    if name == "" { return err("usage: host <name>") }
    let ips = n.lookup(name)?
    for ip in ips { println("${name} has address ${inet.fmt_ip(ip)}") }
}

fn arp(n: inet.Net) {
    if n.neighbors.is_empty() { println("no neighbors known yet") }
    let now = kernel.uptime()
    for ip in n.neighbors.keys() {
        if let e = n.neighbors.get(ip) {
            println("${inet.fmt_ip(ip)}  ${inet.fmt_mac(e.mac)}  (${(now - e.at) / 1000}s ago)")
        }
    }
}

fn counts(n: inet.Net) {
    let keys = n.counts.keys()
    keys.sort()
    if keys.is_empty() {
        println("nothing dropped")
        return
    }
    for k in keys { println("  ${n.counts.get(k) ?? 0}  ${k}") }
}

// `firewall`, `firewall ping on|off`, `firewall log`
fn firewall(n: inet.Net, argv: [str]) -> void! {
    let what = argv.get(0) ?? ""
    if what == "" {
        println("${kernel.ESC}[1mfirewall${kernel.ESC}[0m")
        println("  incoming connections   refused (nothing listens; scans see no answer)")
        println("  pings                  ${if n.answer_pings { "answered (at most 20 a second)" } else { "not answered" }}")
        println("  UDP                    only answers from the server we asked")
        println("  ARP                    only answers to our own questions")
        println("  IP fragments           refused")
        println("${kernel.ESC}[1mdropped so far${kernel.ESC}[0m")
        counts(n)
        println("(`firewall log` shows recent notes; `firewall ping on|off`)")
        return
    }
    if what == "log" {
        if n.log.is_empty() { println("the log is empty") }
        for l in n.log { println(l) }
        return
    }
    if what == "ping" {
        let v = argv.get(1) ?? ""
        if v != "on" && v != "off" { return err("usage: firewall ping on|off") }
        n.answer_pings = v == "on"
        println("pings will ${if n.answer_pings { "" } else { "not " }}be answered")
        return
    }
    return err("usage: firewall [ping on|off | log]")
}

// `dns <server>[:port]`: use another DNS server
fn dns(n: inet.Net, argv: [str]) -> void! {
    let s = argv.get(0) ?? ""
    if s == "" {
        println("dns server: ${inet.fmt_ip(n.dns)}:${n.dns_port}")
        return
    }
    let parts = s.split(":")
    let ip = inet.parse_ip(parts[0]) ?? 0
    if ip == 0 { return err("not an IPv4 address: ${parts[0]}") }
    n.dns = ip
    n.dns_port = if parts.len() > 1 { int(parts[1])? } else { 53 }
    n.cache = {}
    println("dns server: ${inet.fmt_ip(n.dns)}:${n.dns_port}")
}

fn netstat(t: tcp.Tcp) {
    let n = t.net
    if t.conns.is_empty() { println("no TCP connections") }
    for port in t.conns.keys() {
        if let c = t.conns.get(port) {
            println("tcp  ${inet.fmt_ip(n.ip)}:${c.port}  ->  ${inet.fmt_ip(c.ip)}:${c.rport}  ${c.state}  (${c.received} bytes in)")
        }
    }
    for port in n.udp.keys() {
        if let u = n.udp.get(port) {
            let peer = if u.peer_ip != 0 { "${inet.fmt_ip(u.peer_ip)}:${u.peer_port}" } else { "*" }
            println("udp  ${inet.fmt_ip(n.ip)}:${port}  <-  ${peer}")
        }
    }
    println("listening: nothing (no incoming connections are accepted)")
}

// `fetch [-i] <url> [-o file]`: an HTTP GET; prints the page (or saves it)
fn fetch(t: tcp.Tcp, fs: ramfs.RamFs, cwd: str, argv: [str]) -> void! {
    var url = ""
    var file = ""
    var head = false
    var i = 0
    while i < argv.len() {
        if argv[i] == "-o" && i + 1 < argv.len() {
            file = argv[i + 1]
            i += 2
        } else if argv[i] == "-i" {
            head = true
            i += 1
        } else {
            url = argv[i]
            i += 1
        }
    }
    if url == "" { return err("usage: fetch [-i] <url> [-o file]") }
    let r = www.fetch(t, url)?
    if head || file != "" {
        println("${kernel.ESC}[1mHTTP ${r.status} ${r.reason}${kernel.ESC}[0m  (${r.url.text()}, ${r.bytes} bytes in ${r.ms} ms)")
    }
    if head {
        for k in r.headers.keys() { println("${k}: ${r.headers.get(k) ?? ""}") }
        println("")
    }
    if file != "" {
        let path = fs.resolve(cwd, file)
        fs.write(path, r.body)?
        println("saved ${path}")
    } else {
        print(r.body)
        if !r.body.ends_with("\n") { println("") }
    }
}
