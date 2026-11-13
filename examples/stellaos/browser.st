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
import x509

const CSS = """
    .browser { display: flex; flex-direction: column; height: 100%; background: #f6f5fa }
    .bar { display: flex; gap: 6px; align-items: center; padding: 7px 8px; background: #ecebf3; border-bottom: 1px solid #dad8e4 }
    .bar button { padding: 4px 10px; background: white; border: 1px solid #d3d1dd; border-radius: 7px }
    .bar button.on { background: #e9e6fb; color: #5a48d6; border: 1px solid #c9c2f3 }
    .bar input { flex: 1; width: 100px; border-radius: 14px; padding: 5px 12px }
    .badge { padding: 3px 8px; border-radius: 10px; font-size: 12px; background: #fde7e7; color: #b33939 }
    .badge.local { background: #e9e6fb; color: #5a48d6 }
    .badge.secure { background: #e3f6ea; color: #1e7b45 }
    .page { flex: 1; overflow: auto; background: white; padding: 14px 18px; height: 100px }
    .status { padding: 3px 10px; font-size: 12px; color: #6f6c80; background: #ecebf3; border-top: 1px solid #dad8e4 }
"""

const HOME = """
<div style="max-width: 640px">
<h1>✦ Welcome to the web</h1>
<form action="https://www.bing.com/search">
<input name="q" placeholder="Search the web (Bing)" style="width: 380px"> <button type="submit">Search</button>
</form>
<p>Or type an address, or words to search for, in the bar above.</p>
<h3>Try</h3>
<ul>
<li><a href="https://en.wikipedia.org/wiki/Operating_system">Wikipedia</a></li>
<li><a href="https://news.ycombinator.com/">Hacker News</a></li>
<li><a href="https://lite.duckduckgo.com/lite/?q=stellang">DuckDuckGo Lite</a></li>
<li><a href="https://example.com/">example.com</a></li>
<li><a href="http://info.cern.ch/hypertext/WWW/TheProject.html">The first web page</a> (CERN, 1991)</li>
</ul>
<h3>Safe by design</h3>
<ul>
<li>HTTPS is TLS 1.3 written in stellang: certificates are checked against Mozilla's root list, signature by signature, and must name the site. If anything doesn't check out, the page doesn't load.</li>
<li>No scripts run, ever: they're removed before a page is shown, with event handlers and javascript: links.</li>
<li>Pages can't reach this browser's controls, your files or anything else on this machine.</li>
<li>Plain http pages are marked <b>Not secure</b>, and https pages never redirect down to http.</li>
<li>Search result links go straight to the site, not through the search engine's click tracking.</li>
<li>Pages are limited to 4 MiB, 20,000 elements and 20 seconds.</li>
</ul>
<p style="color: #8a879a">Pages show without their external stylesheets, images and scripts: think reader mode.</p>
</div>
"""

struct Browser {
    client: www.Client,
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
    secure: bool = false,
    page_gen: int = 0,
    reader: bool = true,          // show just the page's main part, when it marks one
    has_main: bool = false,
    doc: html.Doc? = none,
    doc_url: str = "",
    doc_title: str = "",
    tick: fn() = () => {},

    fn changed(self) {
        self.version += 1
        self.tick()
    }

    fn go(self, typed: str) {
        let url = address_or_search(typed)
        if url == self.shown && self.loading.is_none() { return }
        if self.shown != "" {
            self.back.push(self.shown)
            if self.back.len() > 50 { self.back.remove(0) }
        }
        self.forward = []
        self.load(url)
    }

    fn load(self, target: str) {
        self.load_form(target, "")
    }

    // load a page; with `form`, by POSTing it
    fn load_form(self, target: str, form: str) {
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
        let done = (r: www.Response) => self.arrived(r)
        self.loading = some(if form != "" { www.post(self.client, u, form, done) } else { www.get(self.client, u, done) })
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
            self.load_sheets(doc, r.url)
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
        self.secure = r.url.scheme == "https"
        let how = if r.secure != "" { r.secure + " · " } else { "" }
        self.status = "${how}HTTP ${r.status} · ${size(r.bytes)} in ${r.ms} ms${blocked}"
        self.changed()
    }

    fn show_html(self, page: str, url: str, title: str) {
        self.secure = false
        self.show_doc(html.parse(page), url, title)
    }

    // Fetch the page's stylesheets (at most 4). Pages get their full CSS; in reader view, only the
    // rules that hide things (menus, dropdowns and the like that a page shows only on demand).
    fn load_sheets(self, doc: html.Doc, base: www.Url) {
        self.page_gen += 1
        let gen = self.page_gen
        for href in doc.sheets {
            let u = www.resolve(base, href) catch e { continue }
            www.get(self.client, u, (r: www.Response) => {
                if gen != self.page_gen || r.error != "" || r.status != 200 { return }
                let flat = html.flatten_css(r.body)
                doc.extra_css = doc.extra_css + "\n" + flat
                doc.extra_hide = doc.extra_hide + "\n" + html.hiding_rules(flat)
                if let d = self.doc {
                    if d.root.path == doc.root.path && self.doc_url == base.text() { self.show_doc(doc, self.doc_url, self.doc_title) }
                }
            })
        }
    }

    fn show_doc(self, doc: html.Doc, url: str, title: str) {
        self.shown = url
        self.doc = some(doc)
        self.doc_url = url
        self.doc_title = title
        var root = doc.root
        self.has_main = false
        if let m = doc.main {
            // reader view: when the marked main part holds a good share (30%) of the text
            if html.text_size(m) * 10 > html.text_size(doc.root) * 3 {
                self.has_main = true
                if self.reader {
                    let wrap = ui.El { tag: "body" }
                    wrap.attrs["data-tag"] = "body"
                    m.parent = some(wrap)
                    wrap.kids = [m]
                    root = wrap
                }
            }
        }
        if let u = self.u {
            // the page's CSS: its <style> blocks, then its linked stylesheets (in reader view, only
            // their rules that hide things)
            let sheet = ui.Sheet {}
            sheet.add_css(html.flatten_css(doc.css), 20000)
            sheet.add_css(if self.reader && self.has_main { doc.extra_hide } else { doc.extra_css }, 20000)
            u.page_sheet = sheet
            u.scrolls = {}
            u.set_slot("page", normalize(root))
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
        let href = untrack(a.attr("href"))
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
        let action = if form.attr("action") != "" { form.attr("action") } else { self.base.path }
        let to = www.resolve(self.base, action) catch e {
            self.status = "${e}"
            self.changed()
            return
        }
        if form.attr("method").lower() == "post" {
            if self.shown != "" { self.back.push(self.shown) }
            self.forward = []
            self.load_form(to.text(), query)
            return
        }
        let path = to.path.split("?")[0]
        to.path = path + "?" + query
        self.go(to.text())
    }

    fn toggle_reader(self) {
        self.reader = !self.reader
        if let d = self.doc { self.show_doc(d, self.doc_url, self.doc_title) }
        self.changed()
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
            <span class={if local { "badge local" } else if b.secure { "badge secure" } else { "badge" }}>{if local { "StellaOS" } else if b.secure { "✓ Secure" } else { "Not secure" }}</span>
            <input value={b.address} oninput={v => { b.typed = v }} onkeydown={k => if k == "Enter" { b.go(b.typed) }} />
            <button class={if b.reader && b.has_main { "on" } else { "" }} onclick={() => b.toggle_reader()} disabled={!b.has_main}>"≡ Reader"</button>
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

// Search engines wrap result links in redirects through themselves (Bing's need JavaScript, and all
// of them track the click); go straight to the destination instead.
fn untrack(href: str) -> str {
    let h = href.replace("&amp;", "&")
    if h.contains("bing.com/ck/a?") {
        let u = param(h, "u")
        if u.starts_with("a1") {
            let decoded = text_of(x509.base64(u.slice(2, u.len()).replace("-", "+").replace("_", "/")))
            if decoded.starts_with("http://") || decoded.starts_with("https://") { return decoded }
        }
    }
    if h.contains("duckduckgo.com/l/?") {
        let u = url_decode(param(h, "uddg"))
        if u.starts_with("http://") || u.starts_with("https://") { return u }
    }
    if h.contains("google.") && h.contains("/url?") {
        let u = url_decode(param(h, "q"))
        if u.starts_with("http://") || u.starts_with("https://") { return u }
    }
    return href
}

fn param(url: str, name: str) -> str {
    let q = url.find("?")
    if q < 0 { return "" }
    for part in url.slice(q + 1, url.len()).split("&") {
        if part.starts_with(name + "=") { return part.slice(name.len() + 1, part.len()) }
    }
    return ""
}

fn text_of(b: [int]) -> str {
    var cs: [str] = []
    for v in b {
        if v < 32 || v > 126 { return "" }     // URLs here are ASCII
        cs.push(st_chr(v))
    }
    return cs.join("")
}

extern fn st_chr(code: int) -> str

// what the address bar means: an address, or words to search for
fn address_or_search(typed: str) -> str {
    let t = typed.trim()
    if t == "" || t.starts_with("about:") || t.contains("://") { return t }
    if t.contains(" ") || !t.contains(".") {
        return "https://www.bing.com/search?q=" + ui.encode(t)
    }
    return t
}

fn escape(s: str) -> str {
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
}

fn size(n: int) -> str {
    if n >= 1 << 20 { return "${n / (1 << 20)}.${n % (1 << 20) * 10 / (1 << 20)} MiB" }
    if n >= 1 << 10 { return "${n / (1 << 10)}.${n % (1 << 10) * 10 / (1 << 10)} KB" }
    return "${n} bytes"
}

fn open(d: wm.Desktop, client: www.Client, url: str) -> Browser {
    let b = Browser { client, desk: some(d) }
    let u = ui.make(() => <Chrome b={b} />, CSS)
    b.u = some(u)
    u.links.push((a: ui.El) => b.link(a))
    u.forms.push((f: ui.El, q: str) => b.submit(f, q))
    let w = d.open("Browser", "◎", 0x0984e3, 720, 520, ui.window_app(u))
    b.win = some(w)
    if url == "" || url == "about:home" { b.load("about:home") } else { b.go(url) }
    return b
}
