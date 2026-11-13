// The web browser: an address bar, back/forward/reload, links and (GET) forms, pages laid out by the
// UI toolkit. The browser's own controls are a JSX app; the page goes into its `data-slot` area.
//
// Safe by design: pages never run code (there is no script engine, and html.st strips scripts,
// event handlers and javascript: links), can't touch the browser's controls or the files on this
// machine, and can only load http: pages. The status bar says what was blocked. Plain http isn't
// private (anyone on the path can read and change it), and the address bar says so.

import web
import ui
import wm
import inet
import tcp
import www
import html

const CSS = """
    .browser { display: flex; flex-direction: column; height: 100%; background: #f6f5fa }
    .bar { display: flex; gap: 6px; align-items: center; padding: 7px 8px; background: #ecebf3; border-bottom: 1px solid #dad8e4 }
    .bar button { padding: 4px 10px; background: white; border: 1px solid #d3d1dd; border-radius: 7px }
    .bar input { flex: 1; width: 100px; border-radius: 14px; padding: 5px 12px }
    .badge { padding: 3px 8px; border-radius: 10px; font-size: 12px; background: #fde7e7; color: #b33939 }
    .badge.local { background: #e9e6fb; color: #5a48d6 }
    .page { flex: 1; overflow: auto; background: white; padding: 14px 18px; height: 100px }
    .status { padding: 3px 10px; font-size: 12px; color: #6f6c80; background: #ecebf3; border-top: 1px solid #dad8e4 }
"""

const HOME = """
<div style="max-width: 640px">
<h1>✦ Welcome to the web</h1>
<p>This browser is part of StellaOS and written in stellang, down to the network card driver,
TCP/IP and HTTP.</p>
<h3>Try</h3>
<ul>
<li><a href="http://example.com/">example.com</a></li>
<li><a href="http://info.cern.ch/hypertext/WWW/TheProject.html">The first web page</a> (CERN, 1991)</li>
<li><a href="http://frogfind.com/">FrogFind</a>: a search engine that serves plain http pages</li>
<li><a href="http://neverssl.com/">NeverSSL</a></li>
</ul>
<h3>Safe by design</h3>
<ul>
<li>No scripts run, ever: they're removed before a page is shown, with event handlers and javascript: links.</li>
<li>Pages can't reach this browser's controls, your files or anything else on this machine.</li>
<li>Only http: pages load. That isn't private: the address bar says <b>Not secure</b>.</li>
<li>Pages are limited to 4 MiB, 8,000 elements and 20 seconds.</li>
</ul>
<p style="color: #8a879a">HTTPS needs TLS, which isn't built yet; sites that only offer HTTPS won't open.</p>
</div>
"""

struct Browser {
    stack: tcp.Tcp,
    u: ui.Ui? = none,
    win: wm.Window? = none,
    desk: wm.Desktop? = none,
    address: str = "about:home",
    typed: str = "",              // what's in the address bar
    shown: str = "about:home",    // the URL of the page on screen
    base: www.Url = www.Url {},
    back: [str] = [],
    forward: [str] = [],
    status: str = "",
    loading: www.Request? = none,
    version: int = 0,
    tick: fn() = () => {},

    fn changed(self) {
        self.version += 1
        self.tick()
    }

    fn go(self, url: str) {
        if url == self.shown && self.loading.is_none() { return }
        if self.shown != "" {
            self.back.push(self.shown)
            if self.back.len() > 50 { self.back.remove(0) }
        }
        self.forward = []
        self.load(url)
    }

    fn load(self, target: str) {
        if let r = self.loading { r.cancel() }
        self.loading = none
        let url = target.trim()
        self.address = url
        self.typed = url
        if url == "" || url == "about:home" || url == "about:blank" {
            self.show_html(HOME, "about:home", "Home")
            self.status = "StellaOS browser"
            self.changed()
            return
        }
        let u = www.parse_url(url) catch e {
            self.show_error(url, "Can't open this address", "${e}")
            return
        }
        self.address = u.text()
        self.typed = self.address
        self.status = "Loading ${u.host}…"
        self.changed()
        self.loading = some(www.get(self.stack, u, (r: www.Response) => self.arrived(r)))
    }

    fn arrived(self, r: www.Response) {
        self.loading = none
        let where = r.url.text()
        if r.error != "" {
            self.show_error(where, "Couldn't load ${r.url.host}", r.error)
            return
        }
        self.address = where
        self.typed = where
        self.base = r.url
        let kind = r.header("content-type").lower()
        var blocked = ""
        if kind == "" || kind.contains("html") {
            let doc = html.parse(r.body)
            self.show_doc(doc, where, if doc.title != "" { doc.title } else { r.url.host })
            var parts: [str] = []
            for k in doc.removed.keys() { parts.push("${doc.removed.get(k) ?? 0} ${k}") }
            if !parts.is_empty() { blocked = " · blocked: " + parts.join(", ") }
            if doc.truncated { blocked = blocked + " · page cut short (too many elements)" }
        } else if kind.starts_with("text/") || kind.contains("json") || kind.contains("xml") {
            let doc = html.parse("<pre>" + escape(r.body) + "</pre>")
            self.show_doc(doc, where, r.url.host)
        } else {
            self.show_error(where, "Can't show this", "It's ${kind}, and this browser shows web pages and text. (`fetch ${where} -o file` saves it.)")
            return
        }
        self.status = "HTTP ${r.status} · ${size(r.bytes)} in ${r.ms} ms${blocked}"
        self.changed()
    }

    fn show_html(self, page: str, url: str, title: str) {
        self.show_doc(html.parse(page), url, title)
    }

    fn show_doc(self, doc: html.Doc, url: str, title: str) {
        self.shown = url
        if let u = self.u {
            var rules = ui.parse_sheet(doc.css)
            if rules.len() > 400 { rules = rules.slice(0, 400) }
            u.page_sheet = rules
            u.scrolls = {}
            u.set_slot("page", normalize(doc.root))
        }
        if let w = self.win {
            w.title = "${title.slice(0, min(title.len(), 60))} — Browser"
            if let d = self.desk {
                d.hurt_window(w.id)
                d.hurt_taskbar()
            }
        }
    }

    fn show_error(self, url: str, heading: str, detail: str) {
        self.address = url
        self.show_html("<div style=\"max-width: 560px; margin: 30px 0 0 0\"><h2>${escape(heading)}</h2><p>${escape(detail)}</p></div>", url, "Error")
        self.status = detail
        self.changed()
    }

    fn link(self, a: ui.El) {
        let href = a.attr("href")
        if self.shown == "about:home" {
            self.go(href)
            return
        }
        let to = www.resolve(self.base, href) catch e {
            self.status = "${e}"
            self.changed()
            return
        }
        if to.fragment != "" && to.path == self.base.path && to.host == self.base.host {
            return            // a jump within the page
        }
        self.go(to.text())
    }

    fn submit(self, form: ui.El, query: str) {
        if form.attr("method").lower() == "post" {
            self.status = "this page wants to send a form with POST, which isn't supported"
            self.changed()
            return
        }
        let action = if form.attr("action") != "" { form.attr("action") } else { self.base.path }
        let to = www.resolve(self.base, action) catch e {
            self.status = "${e}"
            self.changed()
            return
        }
        let path = to.path.split("?")[0]
        to.path = path + "?" + query
        self.go(to.text())
    }

    fn back_one(self) {
        if self.back.is_empty() { return }
        self.forward.push(self.shown)
        self.load(self.back.pop())
    }

    fn forward_one(self) {
        if self.forward.is_empty() { return }
        self.back.push(self.shown)
        self.load(self.forward.pop())
    }
}

fn Chrome(b: Browser) -> Node {
    let version = signal(0)
    b.tick = () => version.set(b.version)
    let local = b.shown.starts_with("about:")
    return <div class="browser">
        <div class="bar">
            <button onclick={() => b.back_one()} disabled={b.back.is_empty()}>"◀"</button>
            <button onclick={() => b.forward_one()} disabled={b.forward.is_empty()}>"▶"</button>
            <button onclick={() => b.load(b.shown)}>"↻"</button>
            <span class={if local { "badge local" } else { "badge" }}>{if local { "StellaOS" } else { "Not secure" }}</span>
            <input value={b.address} oninput={v => { b.typed = v }} onkeydown={k => if k == "Enter" { b.go(b.typed) }} />
            <button onclick={() => b.go("about:home")}>"⌂"</button>
        </div>
        <div class="page" data-slot="page"></div>
        <div class="status">{if b.loading.is_some() { "Loading…  ${b.status}" } else { b.status }}</div>
    </div>
}

// Anonymous blocks: an element with both blocks and text inside gets its runs of text (and inline
// elements) wrapped in their own blocks, so the blocks stack instead of flowing with the words.
const INLINE_TAGS = ["", "span", "a", "b", "strong", "i", "em", "code", "kbd", "small", "u", "s", "mark", "sub", "sup", "abbr", "br", "label", "button", "input", "progress"]

fn normalize(e: ui.El) -> ui.El {
    if e.tag == "" { return e }
    for k in e.kids { normalize(k) }
    if e.tag == "tr" || e.tag == "pre" || INLINE_TAGS.contains(e.tag) { return e }
    var blocks = false
    var inlines = false
    for k in e.kids {
        if INLINE_TAGS.contains(k.tag) {
            if k.tag != "" || k.text.trim() != "" { inlines = true }
        } else {
            blocks = true
        }
    }
    if !(blocks && inlines) { return e }
    var kids: [ui.El] = []
    var run: [ui.El] = []
    for k in e.kids {
        if INLINE_TAGS.contains(k.tag) {
            run.push(k)
        } else {
            if !run.is_empty() {
                kids.push(wrap(e, run))
                run = []
            }
            kids.push(k)
        }
    }
    if !run.is_empty() { kids.push(wrap(e, run)) }
    e.kids = kids
    return e
}

fn wrap(parent: ui.El, run: [ui.El]) -> ui.El {
    let d = ui.El { tag: "div", parent: some(parent) }
    var any = false
    for k in run {
        if k.tag != "" || k.text.trim() != "" { any = true }
        k.parent = some(d)
        d.kids.push(k)
    }
    if !any { d.attrs["style"] = "display: none" }
    return d
}

fn escape(s: str) -> str {
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
}

fn size(n: int) -> str {
    if n >= 1 << 20 { return "${n / (1 << 20)}.${n % (1 << 20) * 10 / (1 << 20)} MiB" }
    if n >= 1 << 10 { return "${n / (1 << 10)}.${n % (1 << 10) * 10 / (1 << 10)} KB" }
    return "${n} bytes"
}

fn open(d: wm.Desktop, stack: tcp.Tcp, url: str) -> Browser {
    let b = Browser { stack, desk: some(d) }
    let u = ui.make(() => <Chrome b={b} />, CSS)
    b.u = some(u)
    u.links.push((a: ui.El) => b.link(a))
    u.forms.push((f: ui.El, q: str) => b.submit(f, q))
    let w = d.open("Browser", "◎", 0x0984e3, 720, 520, ui.window_app(u))
    b.win = some(w)
    if url == "" { b.load("about:home") } else { b.go(url) }
    return b
}
