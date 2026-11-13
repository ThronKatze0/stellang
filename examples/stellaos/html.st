// Reading web pages: real-world HTML (unclosed tags, comments, odd quoting, entities) into the UI
// toolkit's element tree, made safe on the way in.
//
// Safe means:
// - no scripts, ever: <script> is dropped, so are on* attributes and javascript: links; nothing on a
//   page runs code
// - a page can't reach the browser's own buttons: only a short list of harmless attributes survives,
//   so a page can't plant the toolkit's event attributes (data-on-click=...) on its elements
// - embedded content (iframes, objects, embeds, SVG) is dropped; images show their alt text
// - limits: 8,000 elements, nesting 40 deep (deeper content is flattened, so a hostile page can't
//   exhaust the kernel's stack), 64 KiB of CSS; inline styles can't load anything (url() is dropped)

import ui

extern fn st_k_byte(s: str, i: int) -> int
extern fn st_k_find_at(s: str, sub: str, from: int) -> int
extern fn st_k_substr(s: str, from: int, to: int) -> str
extern fn st_chr(code: int) -> str

const MAX_ELEMENTS = 8000
const MAX_DEPTH = 40
const MAX_CSS = 65536

const VOID = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr", "keygen"]
// dropped with everything inside
const DROP = ["script", "iframe", "object", "embed", "svg", "math", "template", "canvas", "video", "audio", "frameset", "frame", "applet", "dialog"]
// kept as they are (the toolkit knows them)
const KNOWN = ["div", "p", "span", "a", "b", "strong", "i", "em", "code", "pre", "kbd", "small", "u", "s", "mark", "sub", "sup", "abbr",
    "h1", "h2", "h3", "h4", "ul", "ol", "li", "hr", "br", "button", "input", "textarea", "label", "form", "tr", "td", "th", "progress"]
// shown as blocks (div)
const BLOCKS = ["section", "article", "nav", "header", "footer", "main", "aside", "figure", "figcaption", "address", "details", "summary",
    "dl", "dt", "dd", "blockquote", "center", "table", "thead", "tbody", "tfoot", "caption", "fieldset", "legend", "hgroup", "body", "html",
    "menu", "noscript", "search", "h5", "h6", "picture", "output", "optgroup"]
// harmless attributes (everything else is dropped)
const ATTRS = ["href", "class", "id", "style", "title", "alt", "name", "value", "type", "placeholder", "action", "method", "checked",
    "disabled", "width", "height", "colspan", "align", "bgcolor", "color", "lang", "selected", "src"]
// tags that end an open <p>
const CLOSES_P = ["p", "div", "ul", "ol", "table", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "form", "section", "article", "nav", "header",
    "footer", "main", "aside", "blockquote", "hr", "dl", "figure", "address", "fieldset", "details", "center", "menu"]

// The page text, with its length known (scanning it stays linear).
struct Src {
    s: str,
    low: str,                 // lowercased, for finding tags
    n: int,

    fn at(self, i: int) -> int {
        if i < 0 || i >= self.n { return 0 }
        return st_k_byte(self.s, i)
    }
    fn find(self, sub: str, from: int) -> int {
        if from >= self.n || from < 0 { return -1 }
        return st_k_find_at(self.low, sub, from)
    }
    fn cut(self, from: int, to: int) -> str {
        let a = min(max(from, 0), self.n)
        let b = min(max(to, a), self.n)
        return st_k_substr(self.s, a, b)
    }
    fn cut_low(self, from: int, to: int) -> str {
        let a = min(max(from, 0), self.n)
        let b = min(max(to, a), self.n)
        return st_k_substr(self.low, a, b)
    }
}

struct Doc {
    root: ui.El,
    title: str = "",
    css: str = "",
    elements: int = 0,
    truncated: bool = false,
    removed: {str: int} = {},     // what was dropped: "script" -> 3, "on* attributes" -> 12, ...

    fn drop(self, what: str) {
        self.removed[what] = (self.removed.get(what) ?? 0) + 1
    }
}

struct Parser {
    src: Src,
    doc: Doc,
    stack: [ui.El],
    flat: int = 0,                // elements not opened because the nesting got too deep

    fn cur(self) -> ui.El { return self.stack[self.stack.len() - 1] }

    fn text(self, raw: str) {
        if raw == "" { return }
        let t = decode(raw)
        let parent = self.cur()
        // merge with a text node just before
        if !parent.kids.is_empty() {
            let last = parent.kids[parent.kids.len() - 1]
            if last.tag == "" {
                last.text = last.text + t
                return
            }
        }
        let k = ui.El { tag: "", text: t, parent: some(parent), path: "${parent.path}.${parent.kids.len()}" }
        parent.kids.push(k)
    }

    fn open(self, tag: str, attrs: {str: str}) {
        if self.doc.elements >= MAX_ELEMENTS {
            self.doc.truncated = true
            return
        }
        // implied ends: a new block ends an open <p>; <li> ends the open <li>, cells end cells...
        if CLOSES_P.contains(tag) { self.close_if_open("p", ["div", "td", "th", "li", "blockquote", "section", "article", "body"]) }
        if tag == "li" { self.close_if_open("li", ["ul", "ol", "menu"]) }
        if tag == "dt" || tag == "dd" {
            self.close_if_open("dt", ["dl"])
            self.close_if_open("dd", ["dl"])
        }
        if tag == "td" || tag == "th" {
            self.close_if_open("td", ["tr", "table"])
            self.close_if_open("th", ["tr", "table"])
        }
        if tag == "tr" {
            self.close_if_open("td", ["table"])
            self.close_if_open("th", ["table"])
            self.close_if_open("tr", ["table"])
        }
        if tag == "option" { self.close_if_open("option", ["select"]) }
        let el = make(tag, attrs, self.doc)
        let parent = self.cur()
        el.parent = some(parent)
        el.path = "${parent.path}.${parent.kids.len()}"
        parent.kids.push(el)
        self.doc.elements += 1
        if VOID.contains(tag) { return }
        if self.stack.len() >= MAX_DEPTH {
            self.flat += 1
            return
        }
        self.stack.push(el)
    }

    // close an open `tag` if it's open below the nearest of `scope`
    fn close_if_open(self, tag: str, scope: [str]) {
        var i = self.stack.len() - 1
        while i > 0 {
            let t = self.stack[i].attrs.get("data-tag") ?? ""
            if t == tag {
                while self.stack.len() > i { self.stack.pop() }
                return
            }
            if scope.contains(t) { return }
            i -= 1
        }
    }

    fn close(self, tag: str) {
        if self.flat > 0 && !VOID.contains(tag) {
            self.flat -= 1
            return
        }
        // pop to the nearest open element with this tag, if there is one (a stray end tag does nothing)
        var i = self.stack.len() - 1
        while i > 0 {
            if (self.stack[i].attrs.get("data-tag") ?? "") == tag {
                while self.stack.len() > i { self.stack.pop() }
                return
            }
            i -= 1
        }
    }

    // skip a raw-text element's contents (script, style, ...): to its end tag
    fn raw_end(self, tag: str, from: int) -> int {
        let end = self.src.find("</" + tag, from)
        return if end < 0 { self.src.n } else { end }
    }

    fn run(self) {
        let src = self.src
        var i = 0
        var text_from = 0
        while i < src.n {
            if src.at(i) != 60 {          // '<'
                i += 1
                continue
            }
            let next = src.at(i + 1)
            let is_tag = letter(next) || next == 47 || next == 33 || next == 63   // a-z, '/', '!', '?'
            if !is_tag {
                i += 1
                continue
            }
            self.text(src.cut(text_from, i))
            if self.doc.truncated { return }
            if next == 33 {
                // <!-- comment --> or <!DOCTYPE ...>
                if src.cut(i, i + 4) == "<!--" {
                    let end = src.find("-->", i + 4)
                    i = if end < 0 { src.n } else { end + 3 }
                } else {
                    let end = src.find(">", i)
                    i = if end < 0 { src.n } else { end + 1 }
                }
                text_from = i
                continue
            }
            if next == 63 {
                let end = src.find(">", i)
                i = if end < 0 { src.n } else { end + 1 }
                text_from = i
                continue
            }
            if next == 47 {
                // an end tag
                var j = i + 2
                while j < src.n && name_char(src.at(j)) { j += 1 }
                let name = src.cut_low(i + 2, j)
                let end = src.find(">", j)
                i = if end < 0 { src.n } else { end + 1 }
                text_from = i
                if name != "" { self.close(name) }
                continue
            }
            // a start tag: name, then attributes
            var j = i + 1
            while j < src.n && name_char(src.at(j)) { j += 1 }
            let name = src.cut_low(i + 1, j)
            var attrs: {str: str} = {}
            var self_closing = false
            while j < src.n {
                let c = src.at(j)
                if c == 62 {              // '>'
                    j += 1
                    break
                }
                if c == 47 && src.at(j + 1) == 62 {
                    self_closing = true
                    j += 2
                    break
                }
                if space(c) || c == 47 {
                    j += 1
                    continue
                }
                // a name
                let a0 = j
                while j < src.n && !space(src.at(j)) && src.at(j) != 61 && src.at(j) != 62 && !(src.at(j) == 47 && src.at(j + 1) == 62) { j += 1 }
                let an = src.cut_low(a0, j)
                while j < src.n && space(src.at(j)) { j += 1 }
                var av = ""
                if src.at(j) == 61 {      // '='
                    j += 1
                    while j < src.n && space(src.at(j)) { j += 1 }
                    let q = src.at(j)
                    if q == 34 || q == 39 {
                        let close = src.find(if q == 34 { "\"" } else { "'" }, j + 1)
                        let e = if close < 0 { src.n } else { close }
                        av = src.cut(j + 1, e)
                        j = e + 1
                    } else {
                        let v0 = j
                        while j < src.n && !space(src.at(j)) && src.at(j) != 62 { j += 1 }
                        av = src.cut(v0, j)
                    }
                }
                if an != "" && attrs.len() < 32 { attrs[an] = decode(av) }
            }
            i = j
            text_from = i
            // raw text elements
            if name == "script" || name == "style" || name == "title" || name == "textarea" || name == "xmp" || name == "noembed" || name == "noframes" {
                let end = self.raw_end(name, i)
                let content = src.cut(i, end)
                if name == "script" {
                    self.doc.drop("scripts")
                } else if name == "style" {
                    if self.doc.css.len() + content.len() <= MAX_CSS {
                        self.doc.css = self.doc.css + "\n" + content
                    } else {
                        self.doc.drop("stylesheets over 64 KiB")
                    }
                } else if name == "title" {
                    if self.doc.title == "" { self.doc.title = collapse(decode(content)).slice(0, min(collapse(decode(content)).len(), 200)) }
                } else if name == "textarea" {
                    self.open("textarea", attrs)
                    self.text(content)
                    self.close("textarea")
                } else {
                    self.text(content)
                }
                let gt = src.find(">", end)
                i = if gt < 0 { src.n } else { gt + 1 }
                text_from = i
                continue
            }
            if DROP.contains(name) {
                self.doc.drop(name)
                if !VOID.contains(name) && !self_closing {
                    // skip to its end tag (nested ones of the same kind too)
                    var depth = 1
                    var k = i
                    while depth > 0 && k < src.n {
                        let a = src.find("<" + name, k)
                        let b = src.find("</" + name, k)
                        if b < 0 {
                            k = src.n
                            break
                        }
                        if a >= 0 && a < b {
                            depth += 1
                            k = a + 1
                        } else {
                            depth -= 1
                            k = b + 1
                        }
                    }
                    let gt = src.find(">", k)
                    i = if gt < 0 { src.n } else { gt + 1 }
                    text_from = i
                }
                continue
            }
            if name == "head" || name == "html" || name == "body" || name == "meta" || name == "link" || name == "base" { continue }
            self.open(name, attrs)
            if self_closing && !VOID.contains(name) { self.close(name) }
        }
        self.text(src.cut(text_from, src.n))
    }
}

// An element for `tag`, with only harmless attributes. Unknown tags become div or span.
fn make(tag: str, attrs: {str: str}, doc: Doc) -> ui.El {
    var t = tag
    var style = ""
    if !KNOWN.contains(tag) {
        t = if BLOCKS.contains(tag) { "div" } else { "span" }
    }
    if tag == "h5" || tag == "h6" { t = "h4" }
    if tag == "center" { style = "text-align: center;" }
    if tag == "blockquote" { style = "margin: 6px 0 10px 0; padding: 0 0 0 14px; border-left: 3px solid #d8d6e2; color: #555;" }
    if tag == "dd" { style = "padding: 0 0 0 24px;" }
    if tag == "table" { style = "margin: 0 0 10px 0;" }
    if tag == "th" { style = "font-weight: bold;" }
    if tag == "caption" || tag == "figcaption" { style = "color: #666; font-size: 12px;" }
    if tag == "summary" { style = "font-weight: bold;" }
    let el = ui.El { tag: t }
    el.attrs["data-tag"] = tag
    for k in attrs.keys() {
        let v = attrs.get(k) ?? ""
        if k.starts_with("on") {
            doc.drop("on* attributes (scripts)")
            continue
        }
        if !ATTRS.contains(k) {
            if k.starts_with("data-") { doc.drop("data-* attributes") }
            continue
        }
        if k == "style" {
            let low = v.lower()
            if low.contains("url(") || low.contains("expression") || low.contains("@import") {
                doc.drop("styles that load things")
                continue
            }
            style = style + v + ";"
            continue
        }
        if k == "bgcolor" {
            style = style + "background: ${v};"
            continue
        }
        if k == "color" && tag == "font" {
            style = style + "color: ${v};"
            continue
        }
        if k == "align" && (v == "center" || v == "right") {
            style = style + "text-align: ${v};"
            continue
        }
        if k == "href" || k == "src" || k == "action" {
            let low = v.trim().lower()
            if low.starts_with("javascript:") || low.starts_with("vbscript:") || low.starts_with("data:") {
                doc.drop("script links")
                continue
            }
        }
        el.attrs[k] = v
    }
    if tag == "img" {
        // no image decoding (yet): show the alt text in a box
        el.tag = "span"
        el.attrs["data-tag"] = "img"
        let alt = (attrs.get("alt") ?? "").trim()
        if alt != "" {
            el.kids.push(ui.El { tag: "", text: "[${alt.slice(0, min(alt.len(), 80))}]", parent: some(el), path: "x" })
            style = style + "color: #8a879a; font-size: 12px;"
        }
        el.attrs.remove("width")
        el.attrs.remove("height")
    }
    if tag == "input" {
        let ty = (attrs.get("type") ?? "text").lower()
        if ty == "hidden" { style = style + "display: none;" }
        if ty == "submit" || ty == "button" || ty == "reset" {
            el.tag = "button"
            el.attrs["type"] = if ty == "submit" { "submit" } else { "button" }
            let label = attrs.get("value") ?? (if ty == "submit" { "Submit" } else { "Button" })
            el.kids.push(ui.El { tag: "", text: label, parent: some(el), path: "x" })
        }
        if ty == "image" || ty == "file" { style = style + "display: none;" }
    }
    if tag == "select" {
        style = style + "border: 1px solid #cbc8d6; padding: 2px 6px;"
    }
    if tag == "option" && !attrs.contains("selected") { style = style + "display: none;" }
    if style != "" { el.attrs["style"] = style }
    return el
}

// Read a page. `limit_css`: whether to keep its stylesheets.
fn parse(page: str) -> Doc {
    let root = ui.El { tag: "body", path: "p" }
    root.attrs["data-tag"] = "body"
    let doc = Doc { root }
    let p = Parser { src: Src { s: page, low: page.lower(), n: page.len() }, doc, stack: [root] }
    p.run()
    return doc
}

fn letter(c: int) -> bool { return (c >= 97 && c <= 122) || (c >= 65 && c <= 90) }
fn name_char(c: int) -> bool { return letter(c) || (c >= 48 && c <= 57) || c == 45 || c == 58 || c == 95 }
fn space(c: int) -> bool { return c == 32 || c == 10 || c == 13 || c == 9 || c == 12 }

fn collapse(s: str) -> str {
    return s.replace("\n", " ").replace("\t", " ").split(" ").filter(w => w != "").join(" ")
}

const ENTITIES = {
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "copy": "©", "reg": "®", "trade": "™",
    "mdash": "—", "ndash": "–", "hellip": "…", "laquo": "«", "raquo": "»", "middot": "·", "bull": "•", "lsquo": "‘",
    "rsquo": "’", "ldquo": "“", "rdquo": "”", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "times": "×",
    "divide": "÷", "deg": "°", "plusmn": "±", "sect": "§", "para": "¶", "larr": "←", "rarr": "→", "uarr": "↑",
    "darr": "↓", "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß",
    "eacute": "é", "egrave": "è", "aacute": "á", "agrave": "à", "ccedil": "ç", "ntilde": "ñ", "iexcl": "¡", "iquest": "¿",
    "shy": "", "zwj": "", "zwnj": "", "thinsp": " ", "ensp": " ", "emsp": " ", "check": "✓", "hearts": "♥",
}

// Character references: &amp; &#233; &#xE9; and the common named ones. Unknown ones stay as they are.
fn decode(s: str) -> str {
    if !s.contains("&") { return s }
    let src = Src { s, low: s, n: s.len() }
    var parts: [str] = []
    var from = 0
    var i = src.find("&", 0)
    while i >= 0 {
        let semi = src.find(";", i)
        if semi < 0 || semi - i > 12 {
            i = src.find("&", i + 1)
            continue
        }
        let name = src.cut(i + 1, semi)
        var rep = ""
        var known = false
        if name.starts_with("#") {
            let hex = name.starts_with("#x") || name.starts_with("#X")
            let digits = name.slice(if hex { 2 } else { 1 }, name.len())
            var code = 0
            var good = digits != ""
            for ch in digits.lower().chars() {
                let d = (if hex { "0123456789abcdef" } else { "0123456789" }).find(ch)
                if d < 0 || ch.len() != 1 { good = false } else { code = code * (if hex { 16 } else { 10 }) + d }
                if code > 0x10ffff { good = false }
            }
            if good {
                known = true
                if code == 0 || (code >= 0xd800 && code <= 0xdfff) || code > 0x10ffff { rep = "�" } else { rep = st_chr(code) }
            }
        } else if let e = ENTITIES.get(name) {
            known = true
            rep = e
        }
        if known {
            parts.push(src.cut(from, i))
            parts.push(rep)
            from = semi + 1
            i = src.find("&", from)
        } else {
            i = src.find("&", i + 1)
        }
    }
    parts.push(src.cut(from, src.n))
    return parts.join("")
}
