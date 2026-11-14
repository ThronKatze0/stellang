// The UI toolkit: apps written like stellang web apps (components, JSX, signals, onclick/oninput)
// running natively in a StellaOS window. No browser: the HTML a render produces is read into a tree,
// styled (inline `style="..."` with a subset of CSS, on top of built-in defaults), laid out (blocks,
// inline text that wraps, flexbox, simple grids), painted with gfx, and the window's mouse and keys
// become the same events the browser would send.
//
//     import web
//     import ui
//
//     fn Counter() -> Node {
//         let n = signal(0)
//         return <button onclick={() => n.set(n.get() + 1)}>"clicked ${n.get()} times"</button>
//     }
//
//     desktop.open("Counter", "+", 0x0984e3, 300, 200, ui.app(() => <Counter />))
//
// CSS that works: display (block, flex, inline-flex, grid, none, inline, inline-block),
// flex-direction, flex/flex-grow, flex-wrap, gap, align-items, justify-content, grid-template-columns
// (repeat(n, 1fr)), width/height/min-/max- (px, %, em), padding, margin (auto centers), background
// (colors, linear-gradient), color, border (+ -top/-bottom/-left/-right), border-radius, box-shadow,
// font-size, font-weight, font-family: monospace, text-align, white-space (pre, nowrap), overflow:
// auto/scroll. Elements with special looks: button, input (text, password, checkbox), textarea,
// progress, hr, ul/ol/li, a, code, h1-h3, table rows.

import kernel
import gfx
import input
import wm

extern fn st_k_ui_new() -> int
extern fn st_k_ui_render(ctx: int, app: fn() -> Node) -> str
extern fn st_k_ui_dispatch(ctx: int, id: int, value: str)

const ACCENT = 0x6c5ce7
const INK = 0x23212e
const MUTED = 0x8a879a
const VOID = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]
const INLINE = ["span", "a", "b", "strong", "i", "em", "code", "label", "small", "u", "s", "mark", "kbd", "sub", "sup", "abbr"]
const ATOMIC = ["button", "input", "select", "img", "progress", "canvas"]

struct Style {
    display: str = "block",   // block, inline, inline-block, flex, grid, none
    row: bool = true,         // flex-direction: row (the default) or column
    wrap: bool = false,       // flex-wrap
    columns: int = 0,         // grid columns
    gap: int = 0,
    pad: [int] = [0, 0, 0, 0],      // top right bottom left
    margin: [int] = [0, 0, 0, 0],
    center: bool = false,     // margin: auto
    width: int = -1,
    height: int = -1,
    width_pct: int = -1,
    height_pct: int = -1,
    min_width: int = -1,
    min_height: int = -1,
    max_width: int = -1,
    grow: int = 0,
    align: str = "stretch",   // align-items
    justify: str = "start",
    bg: int = -1,
    bg2: int = -1,            // a gradient's bottom color
    color: int = INK,
    borders: [int] = [0, 0, 0, 0],
    border_color: int = 0xd8d6e2,
    radius: int = 0,
    shadow: bool = false,
    size: int = 13,           // font-size
    bold: bool = false,
    mono: bool = false,
    text_align: str = "left",
    pre: bool = false,
    nowrap: bool = false,
    scroll: bool = false,
    underline: bool = false,
    vars: {str: str} = {},    // CSS custom properties (--x) in effect
    upper: str = "",          // text-transform: "uppercase" or "lowercase"
    hidden: bool = false,     // visibility: hidden (takes room, isn't drawn)
    no_marker: bool = false,  // list-style: none

    fn face(self) -> int {
        if self.mono { return if self.bold { gfx.MONO_BOLD } else { gfx.MONO } }
        if self.size >= 28 { return gfx.BIG }
        if self.size >= 19 { return gfx.TITLE }
        if self.size >= 15 { return if self.bold { gfx.TEXT_BOLD } else { gfx.TEXT } }
        return if self.bold { gfx.UI_BOLD } else { gfx.UI }
    }

    fn inline(self) -> bool { return self.display == "inline" }
    fn atomic(self) -> bool { return self.display == "inline-block" || self.display == "inline-flex" }
    fn flex(self) -> bool { return self.display == "flex" || self.display == "inline-flex" }
}

// a word (or an atomic box) placed on a line
struct Word {
    text: str,
    x: int = 0,
    y: int = 0,
    w: int = 0,
    h: int = 0,
    face: int = 0,
    color: int = INK,
    bg: int = -1,
    underline: bool = false,
    el: El,                   // the element it belongs to (for clicks)
    box: bool = false,        // an atomic element (`el` itself), not text
    space: int = 0,           // width of the space after it
    brk: bool = false,        // a forced line break
}

struct El {
    tag: str,                 // "" for text
    text: str = "",
    attrs: {str: str} = {},
    kids: [El] = [],
    parent: El? = none,
    st: Style = Style {},
    path: str = "",
    x: int = 0,               // its box (border box), in content coordinates (before scrolling)
    y: int = 0,
    w: int = 0,
    h: int = 0,
    inner_h: int = 0,         // a scrolling element's content height
    avail_h: int = -1,        // its content height when that's decided from outside (for height: N%)
    words: [Word] = [],       // inline content
    pref: int = -1,           // max-content width, cached during a layout
    uid: int = 0,             // an identity for scripts (jsdom.st), given when first needed

    fn attr(self, name: str) -> str { return self.attrs.get(name) ?? "" }
    fn has(self, name: str) -> bool { return self.attrs.contains(name) }
    fn handler(self, event: str) -> int {
        if let id = self.attrs.get("data-on-${event}") { return int(id) catch -1 }
        return -1
    }
    fn is_field(self) -> bool {
        return (self.tag == "input" && self.attr("type") != "checkbox" && self.attr("type") != "radio") || self.tag == "textarea"
    }
    fn is_check(self) -> bool { return self.tag == "input" && (self.attr("type") == "checkbox" || self.attr("type") == "radio") }
    fn focusable(self) -> bool {
        return self.is_field() || self.is_check() || self.tag == "button" || self.has("tabindex") || self.handler("keydown") >= 0
    }
}

// a text field's state, which outlives renders (like the browser's DOM keeps what's typed)
struct Field {
    text: str = "",
    caret: int = 0,           // in characters
    seen: str = "",           // the value attribute it was last given
    checked: bool = false,
    seen_checked: bool = false,
}

// ---- stylesheets: rules, selectors, the cascade ----

// a compound selector: tag, #id, .classes, [attributes], :pseudo-classes (div.note[title]:first-child)
struct Sel {
    tag: str = "",
    id: str = "",
    classes: [str] = [],
    attrs: [[str]] = [],      // [name, op, value]; op: "" (present), "=", "~=", "^=", "$=", "*=", "|="
    pseudos: [str] = [],      // first-child, last-child, only-child, empty, root, link, nth-child(...)
    nots: [Sel] = [],         // :not(...)
}

struct Decl {
    name: str,
    value: str,
    important: bool = false,
}

// `a > b.c, d { ... }` gives a rule per selector
struct Rule {
    sels: [Sel],              // left to right
    combs: [str],             // between sels[i] and sels[i+1]: " " (descendant), ">", "+", "~"
    decls: [Decl],
    spec: int,
    order: int,
}

// rules, indexed by what their rightmost part needs (an id, a class, a tag), so an element only
// tries the rules that could match it
struct Sheet {
    rules: [Rule] = [],
    by_id: {str: [int]} = {},
    by_class: {str: [int]} = {},
    by_tag: {str: [int]} = {},
    any: [int] = [],

    fn add(self, r: Rule) {
        let i = self.rules.len()
        self.rules.push(r)
        let last = r.sels[r.sels.len() - 1]
        if last.id != "" {
            push_at(self.by_id, last.id, i)
        } else if !last.classes.is_empty() {
            push_at(self.by_class, last.classes[0], i)
        } else if last.tag != "" {
            push_at(self.by_tag, last.tag, i)
        } else {
            self.any.push(i)
        }
    }

    // add a stylesheet's rules after the ones already here
    fn add_css(self, css: str, limit: int) {
        for r in parse_rules(css, self.rules.len()) {
            if self.rules.len() >= limit { return }
            self.add(r)
        }
    }

    // the rules matching `e`, in cascade order (specificity, then order in the sheet)
    fn matching(self, e: El, stop: bool) -> [Rule] {
        if self.rules.is_empty() { return [] }
        var cand: [int] = []
        let id = e.attr("id")
        if id != "" { if let l = self.by_id.get(id) { for i in l { cand.push(i) } } }
        var seen: [str] = []
        for c in e.attr("class").split(" ") {
            if c == "" || seen.contains(c) { continue }
            seen.push(c)
            if let l = self.by_class.get(c) { for i in l { cand.push(i) } }
        }
        if let l = self.by_tag.get(tag_of(e)) { for i in l { cand.push(i) } }
        for i in self.any { cand.push(i) }
        var keys: [int] = []
        var by_key: {int: int} = {}
        for i in cand {
            let r = self.rules[i]
            if matches_at(e, r, r.sels.len() - 1, stop) {
                let k = r.spec * 1_000_000 + r.order
                keys.push(k)
                by_key[k] = i
            }
        }
        keys.sort()
        return keys.map(k => self.rules[by_key[k]])
    }
}

fn push_at(m: {str: [int]}, k: str, i: int) {
    if let l = m.get(k) { l.push(i) } else { m[k] = [i] }
}

// an element's tag as pages name it (the browser keeps the original in data-tag)
fn tag_of(e: El) -> str {
    if let t = e.attrs.get("data-tag") { return t }
    return e.tag
}

struct Ui {
    ctx: int,
    view: fn() -> Node,
    sheet: Sheet = Sheet {},
    html: str = "",
    root: El = El { tag: "body" },
    width: int = 0,
    height: int = 0,
    fields: {str: Field} = {},
    scrolls: {str: int} = {},
    focus: str = "",          // paths of elements
    hover: str = "",
    active: str = "",
    render: bool = true,
    restyle: bool = true,
    relayout: bool = true,
    repaint: bool = true,
    last_click: int = 0,
    last_click_path: str = "",
    mx: int = -1,
    my: int = -1,
    blink: int = 0,
    // pages shown inside the app (the browser): element trees put into `data-slot` elements, styled
    // only by their own sheet, with links and forms handed to the app
    slots: {str: El} = {},
    page_sheet: Sheet = Sheet {},
    links: [fn(El)] = [],
    page_hooks: [fn(El, str, str) -> bool] = [],   // events on page elements, for the page's scripts
    forms: [fn(El, str)] = [],

    fn tick(self, t: wm.Tick) -> bool {
        if t.signals { self.render = true }
        if t.focused && self.focused_field() {
            // the caret blinks
            let on = (t.now / 530) % 2
            if on != self.blink {
                self.blink = on
                self.repaint = true
            }
        }
        return self.render || self.relayout || self.repaint
    }

    fn focused_field(self) -> bool {
        if let e = self.find(self.focus) { return e.is_field() }
        return false
    }

    fn paint(self, s: gfx.Surface) {
        if self.render {
            self.render = false
            let html = st_k_ui_render(self.ctx, self.view)
            if html != self.html {
                self.html = html
                self.root = parse(html)
                self.fill_slots(self.root)
                self.sync_fields(self.root)
                self.restyle = true
                self.relayout = true
            }
        }
        if s.width != self.width || s.height != self.height {
            self.width = s.width
            self.height = s.height
            self.relayout = true
        }
        if self.relayout {
            self.relayout = false
            if self.restyle {
                // styles depend only on the tree: worked out again only when it changes
                self.restyle = false
                style_tree(self.root, Style {}, self, false)
                self.root.st.scroll = true
            }
            clear_pref(self.root)
            layout(self.root, 0, 0, self.width, self.height, self)
            self.root.h = self.height
            self.clamp_scrolls(self.root)
        }
        self.repaint = false
        s.unclip()
        s.clear(if self.root.st.bg >= 0 { self.root.st.bg } else { 0xffffff })
        let p = Painter { s, ui: self }
        p.el(self.root, 0, 0, [0, 0, s.width, s.height])
    }

    // Show `page` in the element with data-slot="name".
    fn set_slot(self, name: str, page: El) {
        self.slots[name] = page
        self.html = ""            // re-read the app's HTML, which puts the page in
        self.render = true
    }

    fn fill_slots(self, e: El) {
        if let name = e.attrs.get("data-slot") {
            if let page = self.slots.get(name) {
                page.parent = some(e)
                e.kids = [page]
                repath(page, "${e.path}.0")
                return
            }
        }
        for k in e.kids { self.fill_slots(k) }
    }

    // fields keep what's typed, unless the app gives them a new value
    fn sync_fields(self, e: El) {
        if e.is_field() || e.is_check() {
            if let f = self.fields.get(e.path) {
                let v = if e.tag == "textarea" { text_of(e) } else { e.attr("value") }
                if v != f.seen {
                    f.seen = v
                    f.text = v
                    f.caret = min(f.caret, v.chars().len())
                }
                let c = e.has("checked")
                if c != f.seen_checked {
                    f.seen_checked = c
                    f.checked = c
                }
            }
        }
        for k in e.kids { self.sync_fields(k) }
    }

    fn clamp_scrolls(self, e: El) {
        if e.st.scroll {
            let most = max(e.inner_h - e.h, 0)
            let now = self.scrolls.get(e.path) ?? 0
            if now > most { self.scrolls[e.path] = most }
        }
        for k in e.kids { self.clamp_scrolls(k) }
    }

    // ---- events ----

    // Call the nearest handler for `event` from `e` up. Returns whether there was one.
    fn fire(self, e: El, event: str, value: str) -> bool {
        // a page's own scripts first (they may cancel the default action)
        for h in self.page_hooks {
            if h(e, event, value) { return true }
        }
        var cur: El? = some(e)
        while true {
            if let c = cur {
                if c.has("disabled") { return true }
                let id = c.handler(event)
                if id >= 0 {
                    st_k_ui_dispatch(self.ctx, id, value)
                    self.render = true
                    return true
                }
                cur = c.parent
            } else {
                break
            }
        }
        return false
    }

    fn key(self, ev: input.Event) {
        let event = if ev.down { "keydown" } else { "keyup" }
        let target = self.find(self.focus)
        if !ev.down {
            if let t = target { self.fire(t, event, ev.key) } else { self.fire_anywhere(event, ev.key) }
            return
        }
        if ev.key == "Tab" {
            self.focus_next(if ev.shift { -1 } else { 1 })
            return
        }
        if let t = target {
            if t.is_field() && self.edit(t, ev) { return }
            if (ev.key == " " || ev.key == "Enter") && (t.tag == "button" || t.is_check()) {
                self.click(t)
                return
            }
            if !self.fire(t, event, ev.key) { self.fire_anywhere(event, ev.key) }
        } else {
            self.fire_anywhere(event, ev.key)
        }
    }

    // a key handler somewhere in the app, for keys typed with nothing focused (games, shortcuts)
    fn fire_anywhere(self, event: str, value: str) {
        if let e = first_with(self.root, "data-on-${event}") { self.fire(e, event, value) }
    }

    // Typing into a text field. Returns whether the key was used.
    fn edit(self, e: El, ev: input.Event) -> bool {
        let f = self.field(e)
        var cs = f.text.chars()
        let multi = e.tag == "textarea"
        var changed = false
        let k = ev.key
        if ev.ctrl {
            if k == "a" { f.caret = cs.len() }
            if k == "u" {
                cs = []
                f.caret = 0
                changed = true
            }
            if !changed { return k == "a" }
        } else if k == "Backspace" {
            if f.caret > 0 {
                cs.remove(f.caret - 1)
                f.caret -= 1
                changed = true
            }
        } else if k == "Delete" {
            if f.caret < cs.len() {
                cs.remove(f.caret)
                changed = true
            }
        } else if k == "ArrowLeft" {
            f.caret = max(f.caret - 1, 0)
        } else if k == "ArrowRight" {
            f.caret = min(f.caret + 1, cs.len())
        } else if k == "Home" {
            f.caret = if multi { line_start(cs, f.caret) } else { 0 }
        } else if k == "End" {
            f.caret = if multi { line_end(cs, f.caret) } else { cs.len() }
        } else if multi && (k == "ArrowUp" || k == "ArrowDown") {
            f.caret = vertical(cs, f.caret, if k == "ArrowUp" { -1 } else { 1 })
        } else if k == "Enter" {
            if multi {
                cs.insert(f.caret, "\n")
                f.caret += 1
                changed = true
            } else {
                if !self.fire(e, "keydown", k) { self.submit_from(e) }
                self.repaint = true
                return true
            }
        } else if ev.text != "" {
            cs.insert(f.caret, ev.text)
            f.caret += 1
            changed = true
        } else {
            return false
        }
        self.blink = 0
        self.repaint = true
        if changed {
            f.text = cs.join("")
            if multi { self.relayout = true }   // a one-line field keeps its size: no new layout
            self.fire(e, "input", f.text)
        }
        return true
    }

    fn field(self, e: El) -> Field {
        if let f = self.fields.get(e.path) { return f }
        let v = if e.tag == "textarea" { text_of(e) } else { e.attr("value") }
        let f = Field { text: v, caret: v.chars().len(), seen: v, checked: e.has("checked"), seen_checked: e.has("checked") }
        self.fields[e.path] = f
        return f
    }

    fn mouse(self, ev: input.Event) {
        if ev.kind == "leave" {
            self.mx = -1
            if self.hover != "" {
                self.hover = ""
                self.repaint = true
            }
            return
        }
        self.mx = ev.x
        self.my = ev.y
        let hit = self.hit(ev.x, ev.y)
        let path = if let h = hit { h.path } else { "" }
        if ev.kind == "move" {
            if path != self.hover {
                self.hover = path
                self.repaint = true
            }
            return
        }
        if ev.kind == "wheel" {
            if let h = hit {
                if let s = scroller(h) {
                    let now = self.scrolls.get(s.path) ?? 0
                    self.scrolls[s.path] = min(max(now + ev.delta * 48, 0), max(s.inner_h - s.h, 0))
                    self.repaint = true
                }
            }
            return
        }
        // buttons
        if let h = hit {
            if ev.down {
                self.active = h.path
                self.repaint = true
                let target = focus_target(h)
                let was = self.focus
                self.focus = if let t = target { t.path } else { "" }
                if was != self.focus {
                    if let old = self.find(was) { self.fire(old, "blur", "") }
                    if let t = target { self.fire(t, "focus", "") }
                }
                if let t = target {
                    if t.is_field() { self.place_caret(t, ev.x, ev.y) }
                }
                self.fire(h, "pointerdown", "")
                if ev.button == 1 { self.fire(h, "contextmenu", "") }
            } else {
                let was = self.active
                self.active = ""
                self.repaint = true
                self.fire(h, "pointerup", "")
                if ev.button == 0 && was != "" && (h.path.starts_with(was) || was.starts_with(h.path)) {
                    if let a = self.find(was) {
                        self.click(a)
                        let now = kernel.uptime()
                        if now - self.last_click < 400 && self.last_click_path == a.path {
                            self.fire(a, "dblclick", "")
                            self.last_click = 0
                        } else {
                            self.last_click = now
                            self.last_click_path = a.path
                        }
                    }
                }
            }
        } else if !ev.down {
            self.active = ""
        }
    }

    fn click(self, e: El) {
        if e.tag == "label" {
            // a label works its input
            if let f = first_input(e) {
                if f.is_check() {
                    self.click(f)
                    return
                }
                self.focus = f.path
                self.repaint = true
            }
        }
        if e.is_check() {
            let f = self.field(e)
            if e.attr("type") == "radio" { f.checked = true } else { f.checked = !f.checked }
            let v = if f.checked { "true" } else { "false" }
            self.fire(e, "input", v)
            self.fire(e, "change", v)
            self.repaint = true
        }
        if !self.fire(e, "click", "") {
            if e.tag == "button" && e.attr("type") != "button" { self.submit_from(e) }
            // a link in a page
            var cur: El? = some(e)
            while true {
                if let c = cur {
                    if c.tag == "a" && c.has("href") {
                        for f in self.links { f(c) }
                        break
                    }
                    cur = c.parent
                } else {
                    break
                }
            }
        } else if e.tag == "button" && e.attr("type") == "submit" {
            self.submit_from(e)
        }
    }

    // the form around `e` submits: its fields as `name=value&...`
    fn submit_from(self, e: El) {
        var cur: El? = some(e)
        while true {
            if let c = cur {
                if c.tag == "form" {
                    var parts: [str] = []
                    self.form_fields(c, parts)
                    if !self.fire(c, "submit", parts.join("&")) {
                        for f in self.forms { f(c, parts.join("&")) }
                    }
                    return
                }
                cur = c.parent
            } else {
                return
            }
        }
    }

    fn form_fields(self, e: El, out: [str]) {
        let name = e.attr("name")
        if name != "" && (e.is_field() || e.is_check()) {
            let f = self.field(e)
            if e.is_check() {
                if f.checked { out.push("${encode(name)}=${encode(if e.has("value") { e.attr("value") } else { "on" })}") }
            } else {
                out.push("${encode(name)}=${encode(f.text)}")
            }
        }
        for k in e.kids { self.form_fields(k, out) }
    }

    fn focus_next(self, dir: int) {
        var all: [El] = []
        collect_focusable(self.root, all)
        if all.is_empty() { return }
        var i = -1
        for k, e in all {
            if e.path == self.focus { i = k }
        }
        var next = (i + dir + all.len()) % all.len()
        if i < 0 { next = if dir > 0 { 0 } else { all.len() - 1 } }
        self.focus = all[next].path
        let f = self.field(all[next])
        f.caret = f.text.chars().len()
        self.repaint = true
    }

    fn place_caret(self, e: El, x: int, y: int) {
        let f = self.field(e)
        let face = e.st.face()
        let cs = f.text.chars()
        let lh = gfx.line_height(face)
        let scroll = self.scroll_above(e)
        var line = 0
        if e.tag == "textarea" { line = max((y + scroll - e.y - e.st.pad[0] - e.st.borders[0] + (self.scrolls.get(e.path) ?? 0)) / lh, 0) }
        // walk to the line, then along it
        var i = 0
        var l = 0
        while i < cs.len() && l < line {
            if cs[i] == "\n" { l += 1 }
            i += 1
        }
        var px = e.x + e.st.pad[3] + e.st.borders[3]
        while i < cs.len() && cs[i] != "\n" {
            let w = gfx.text_width(if e.attr("type") == "password" { "•" } else { cs[i] }, face)
            if px + w / 2 > x { break }
            px += w
            i += 1
        }
        f.caret = i
        self.blink = 0
    }

    // how far the scrolling elements around `e` have moved it
    fn scroll_above(self, e: El) -> int {
        var total = 0
        var cur = e.parent
        while true {
            if let c = cur {
                if c.st.scroll { total += self.scrolls.get(c.path) ?? 0 }
                cur = c.parent
            } else {
                break
            }
        }
        return total
    }

    // the deepest element at a point
    fn hit(self, x: int, y: int) -> El? {
        return hit_in(self.root, x, y, self)
    }

    fn find(self, path: str) -> El? {
        if path == "" { return none }
        return find_path(self.root, path)
    }
}

// ---- the app ----

// A window program that shows `view` and keeps it up to date.
fn app(view: fn() -> Node) -> wm.App {
    return styled(view, "")
}

// The same, with a stylesheet for its classes: "button.on { background: #6c5ce7 } .muted { color: gray }".
// Selectors: tags, .classes, #ids, combined (button.on) and nested (nav .item); later rules win.
fn styled(view: fn() -> Node, css: str) -> wm.App {
    return window_app(make(view, css))
}

// The Ui itself (for apps that reach into it, like the browser putting pages into slots).
fn make(view: fn() -> Node, css: str) -> Ui {
    return Ui { ctx: st_k_ui_new(), view, sheet: parse_sheet(css) }
}

fn window_app(u: Ui) -> wm.App {
    return wm.App {
        tick: (t: wm.Tick) => u.tick(t),
        paint: (s: gfx.Surface) => u.paint(s),
        key: (e: input.Event) => u.key(e),
        mouse: (e: input.Event) => u.mouse(e),
    }
}

// ---- stylesheets ----

fn parse_sheet(css: str) -> Sheet {
    let sh = Sheet {}
    sh.add_css(css, 1_000_000)
    return sh
}

// `selectors { declarations }` blocks, flat (no @media: see html.flatten_css); `first` numbers them
fn parse_rules(css: str, first: int) -> [Rule] {
    var rules: [Rule] = []
    var text = css
    while text.contains("/*") {
        let a = text.find("/*")
        let rest = text.slice(a + 2, text.len())
        let b = rest.find("*/")
        text = text.slice(0, a) + if b >= 0 { rest.slice(b + 2, rest.len()) } else { "" }
    }
    for block in text.split("}") {
        let open = block.find("{")
        if open < 0 { continue }
        let decls = parse_decls(block.slice(open + 1, block.len()))
        if decls.is_empty() { continue }
        for sel in split_top(block.slice(0, open)) {
            if let r = parse_selector(sel.trim()) {
                r.decls = decls
                r.order = first + rules.len()
                rules.push(r)
            }
        }
    }
    return rules
}

fn parse_decls(body: str) -> [Decl] {
    var out: [Decl] = []
    for part in split_semis(body) {
        let at = part.find(":")
        if at <= 0 { continue }
        let name = part.slice(0, at).trim().lower()
        var v = part.slice(at + 1, part.len()).trim()
        var imp = false
        let bang = v.find("!")
        if bang >= 0 && v.slice(bang + 1, v.len()).trim().lower() == "important" {
            imp = true
            v = v.slice(0, bang).trim()
        }
        if name != "" && v != "" { out.push(Decl { name, value: v, important: imp }) }
    }
    return out
}

// split on ";" outside parentheses (url(data:...;...))
fn split_semis(s: str) -> [str] {
    if !s.contains("(") { return s.split(";") }
    var out: [str] = []
    var cur: [str] = []
    var depth = 0
    for c in s.chars() {
        if c == "(" { depth += 1 }
        if c == ")" { depth = max(depth - 1, 0) }
        if c == ";" && depth == 0 {
            out.push(cur.join(""))
            cur = []
        } else {
            cur.push(c)
        }
    }
    out.push(cur.join(""))
    return out
}

// One selector ("nav > a.on:first-child"). none if it uses what we can't match (:hover, ::before...).
fn parse_selector(s: str) -> Rule? {
    if s == "" { return none }
    let cs = s.chars()
    var sels: [Sel] = []
    var combs: [str] = []
    var i = 0
    var pending = ""
    var spec = 0
    while i < cs.len() {
        let c = cs[i]
        if c == " " || c == "\n" || c == "\t" || c == "\r" {
            if !sels.is_empty() && pending == "" { pending = " " }
            i += 1
            continue
        }
        if c == ">" || c == "+" || c == "~" {
            if sels.is_empty() { return none }
            pending = c
            i += 1
            continue
        }
        // a compound
        if !sels.is_empty() {
            combs.push(if pending == "" { " " } else { pending })
        }
        pending = ""
        let sel = Sel {}
        let end = compound_at(cs, i, sel)
        if end < 0 { return none }
        spec += specificity(sel)
        sels.push(sel)
        i = end
    }
    if sels.is_empty() || combs.len() != sels.len() - 1 { return none }
    return some(Rule { sels, combs, decls: [], spec, order: 0 })
}

fn specificity(sel: Sel) -> int {
    var n = 0
    if sel.id != "" { n += 10000 }
    n += 100 * (sel.classes.len() + sel.attrs.len() + sel.pseudos.len())
    if sel.tag != "" { n += 1 }
    for x in sel.nots { n += specificity(x) }
    return n
}

fn name_char(c: str) -> bool {
    return "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_".contains(c) || st_ord(c) > 127
}

// read a compound selector from cs[i..]; returns where it ends (-1: unsupported)
fn compound_at(cs: [str], start: int, sel: Sel) -> int {
    var i = start
    // the tag
    var t: [str] = []
    if i < cs.len() && cs[i] == "*" {
        i += 1
    } else {
        while i < cs.len() && name_char(cs[i]) {
            t.push(cs[i])
            i += 1
        }
    }
    sel.tag = t.join("").lower()
    while i < cs.len() {
        let c = cs[i]
        if c == "#" || c == "." {
            var n: [str] = []
            i += 1
            while i < cs.len() && name_char(cs[i]) {
                n.push(cs[i])
                i += 1
            }
            if n.is_empty() { return -1 }
            if c == "#" { sel.id = n.join("") } else { sel.classes.push(n.join("")) }
        } else if c == "[" {
            let close = index_from(cs, "]", i)
            if close < 0 { return -1 }
            let inner = cs.slice(i + 1, close).join("").trim()
            i = close + 1
            var op = ""
            var at = -1
            for o in ["~=", "^=", "$=", "*=", "|="] {
                let k = inner.find(o)
                if k > 0 && (at < 0 || k < at) {
                    at = k
                    op = o
                }
            }
            let eq = inner.find("=")
            if at < 0 && eq > 0 {
                at = eq
                op = "="
            }
            if op == "" {
                sel.attrs.push([inner.lower(), "", ""])
            } else {
                var v = inner.slice(at + op.len(), inner.len()).trim()
                if v.ends_with(" i") || v.ends_with(" s") { v = v.slice(0, v.len() - 2).trim() }
                if (v.starts_with("\"") && v.ends_with("\"")) || (v.starts_with("'") && v.ends_with("'")) { v = v.slice(1, v.len() - 1) }
                sel.attrs.push([inner.slice(0, at).trim().lower(), op, v])
            }
        } else if c == ":" {
            if i + 1 < cs.len() && cs[i + 1] == ":" { return -1 }     // ::before and friends
            var n: [str] = []
            i += 1
            while i < cs.len() && name_char(cs[i]) {
                n.push(cs[i])
                i += 1
            }
            let name = n.join("").lower()
            var arg = ""
            if i < cs.len() && cs[i] == "(" {
                let close = index_from(cs, ")", i)
                if close < 0 { return -1 }
                arg = cs.slice(i + 1, close).join("").trim()
                i = close + 1
            }
            if name == "not" {
                let inner = Sel {}
                let ics = arg.chars()
                if compound_at(ics, 0, inner) != ics.len() { return -1 }
                sel.nots.push(inner)
            } else if name == "first-child" || name == "last-child" || name == "only-child" || name == "empty" || name == "root" || name == "link" || name == "any-link" {
                sel.pseudos.push(name)
            } else if name == "nth-child" || name == "nth-of-type" {
                sel.pseudos.push("nth:" + arg.lower().replace(" ", ""))
            } else {
                return -1        // :hover, :focus, :checked, ... : state we don't track
            }
        } else {
            break
        }
    }
    if sel.tag == "" && sel.id == "" && sel.classes.is_empty() && sel.attrs.is_empty() && sel.pseudos.is_empty() && sel.nots.is_empty() && !(start < cs.len() && cs[start] == "*") { return -1 }
    return i
}

fn index_from(cs: [str], what: str, from: int) -> int {
    var i = from
    while i < cs.len() {
        if cs[i] == what { return i }
        i += 1
    }
    return -1
}

// the element children of e's parent, and e's position among them
fn siblings(e: El) -> [El] {
    if let p = e.parent { return p.kids.filter(k => k.tag != "") }
    return [e]
}

fn sel_matches(e: El, s: Sel) -> bool {
    if e.tag == "" { return false }
    if s.tag != "" {
        let t = tag_of(e)
        if s.tag != t && !(s.tag == "html" && t == "body" && is_page_root(e)) { return false }
    }
    if s.id != "" && e.attr("id") != s.id { return false }
    if !s.classes.is_empty() {
        let mine = e.attr("class").split(" ")
        for k in s.classes {
            if !mine.contains(k) { return false }
        }
    }
    for a in s.attrs {
        if a[0] == "data-tag" || a[0].starts_with("data-on") { return false }
        if !e.has(a[0]) { return false }
        let v = e.attr(a[0])
        let want = a[2]
        let op = a[1]
        if op == "=" && v != want { return false }
        if op == "~=" && !v.split(" ").contains(want) { return false }
        if op == "^=" && !v.starts_with(want) { return false }
        if op == "$=" && !v.ends_with(want) { return false }
        if op == "*=" && !v.contains(want) { return false }
        if op == "|=" && v != want && !v.starts_with(want + "-") { return false }
    }
    if !s.pseudos.is_empty() {
        let sib = siblings(e)
        var pos = 0
        for k, x in sib {
            if x.path == e.path { pos = k }
        }
        for p in s.pseudos {
            if p == "first-child" && pos != 0 { return false }
            if p == "last-child" && pos != sib.len() - 1 { return false }
            if p == "only-child" && sib.len() != 1 { return false }
            if p == "empty" && !e.kids.is_empty() { return false }
            if p == "root" && !is_page_root(e) { return false }
            if (p == "link" || p == "any-link") && !(tag_of(e) == "a" && e.has("href")) { return false }
            if p.starts_with("nth:") && !nth(p.slice(4, p.len()), pos + 1) { return false }
        }
    }
    for n in s.nots {
        if sel_matches(e, n) { return false }
    }
    return true
}

fn is_page_root(e: El) -> bool {
    if let p = e.parent { return p.has("data-slot") || e.attr("data-tag") == "body" }
    return true
}

// :nth-child(an+b) with odd, even, 3, 2n+1, -n+3
fn nth(arg: str, k: int) -> bool {
    if arg == "odd" { return k % 2 == 1 }
    if arg == "even" { return k % 2 == 0 }
    let n = arg.find("n")
    if n < 0 { return k == (int(arg) catch -1) }
    let a_s = arg.slice(0, n)
    let a = if a_s == "" || a_s == "+" { 1 } else if a_s == "-" { -1 } else { int(a_s) catch 0 }
    let rest = arg.slice(n + 1, arg.len())
    let b = if rest == "" { 0 } else { int(rest.replace("+", "")) catch 0 }
    if a == 0 { return k == b }
    let d = k - b
    return d % a == 0 && d / a >= 0
}

// Does `e` match the rule's selectors 0..=i, with sels[i] on e itself? `stop`: don't look above the
// page (an element with data-slot) for ancestors.
fn matches_at(e: El, r: Rule, i: int, stop: bool) -> bool {
    if !sel_matches(e, r.sels[i]) { return false }
    if i == 0 { return true }
    let comb = r.combs[i - 1]
    if comb == ">" {
        if let p = e.parent {
            if stop && p.has("data-slot") { return false }
            return matches_at(p, r, i - 1, stop)
        }
        return false
    }
    if comb == " " {
        var cur = e.parent
        while true {
            if let p = cur {
                if stop && p.has("data-slot") { return false }
                if matches_at(p, r, i - 1, stop) { return true }
                cur = p.parent
            } else {
                return false
            }
        }
        return false
    }
    // + and ~: earlier siblings
    let sib = siblings(e)
    var pos = -1
    for k, x in sib {
        if x.path == e.path { pos = k }
    }
    if pos <= 0 { return false }
    if comb == "+" { return matches_at(sib[pos - 1], r, i - 1, stop) }
    var j = pos - 1
    while j >= 0 {
        if matches_at(sib[j], r, i - 1, stop) { return true }
        j -= 1
    }
    return false
}

// ---- reading HTML ----

fn parse(html: str) -> El {
    let root = El { tag: "body", path: "0" }
    let cs = html.chars()
    var i = 0
    var cur = root
    var text: [str] = []
    while i < cs.len() {
        let c = cs[i]
        if c == "<" {
            if !text.is_empty() {
                add_text(cur, decode(text.join("")))
                text = []
            }
            if i + 1 < cs.len() && cs[i + 1] == "/" {
                // a closing tag: back to the parent
                while i < cs.len() && cs[i] != ">" { i += 1 }
                i += 1
                if let p = cur.parent { cur = p }
                continue
            }
            i += 1
            var name: [str] = []
            while i < cs.len() && cs[i] != " " && cs[i] != ">" && cs[i] != "/" {
                name.push(cs[i])
                i += 1
            }
            let el = El { tag: name.join(""), parent: some(cur) }
            // attributes
            while i < cs.len() && cs[i] != ">" {
                if cs[i] == " " || cs[i] == "/" {
                    i += 1
                    continue
                }
                var an: [str] = []
                while i < cs.len() && cs[i] != "=" && cs[i] != " " && cs[i] != ">" {
                    an.push(cs[i])
                    i += 1
                }
                var av = ""
                if i < cs.len() && cs[i] == "=" {
                    i += 2       // ="
                    var v: [str] = []
                    while i < cs.len() && cs[i] != "\"" {
                        v.push(cs[i])
                        i += 1
                    }
                    i += 1
                    av = decode(v.join(""))
                }
                el.attrs[an.join("")] = av
            }
            i += 1
            el.path = "${cur.path}.${if let k = el.attrs.get("data-key") { "k" + k } else { str(cur.kids.len()) }}"
            cur.kids.push(el)
            if !VOID.contains(el.tag) { cur = el }
            continue
        }
        text.push(c)
        i += 1
    }
    if !text.is_empty() { add_text(cur, decode(text.join(""))) }
    return root
}

fn add_text(parent: El, s: str) {
    parent.kids.push(El { tag: "", text: s, parent: some(parent), path: "${parent.path}.${parent.kids.len()}" })
}

fn decode(s: str) -> str {
    if !s.contains("&") { return s }
    return s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&#39;", "'").replace("&nbsp;", " ").replace("&amp;", "&")
}

fn text_of(e: El) -> str {
    if e.tag == "" { return e.text }
    return e.kids.map(k => text_of(k)).join("")
}

fn encode(s: str) -> str {
    var out: [str] = []
    for c in s.chars() {
        if c == " " {
            out.push("+")
        } else if c == "&" || c == "=" || c == "+" || c == "%" || c == "#" || c == "?" {
            out.push("%" + hex2(st_ord(c)))
        } else {
            out.push(c)
        }
    }
    return out.join("")
}

extern fn st_ord(s: str) -> int

fn hex2(n: int) -> str {
    let d = "0123456789ABCDEF".chars()
    return d[n >> 4 & 15] + d[n & 15]
}

// ---- style ----

fn style_tree(e: El, parent: Style, u: Ui, page: bool) {
    let st = Style { color: parent.color, size: parent.size, bold: parent.bold, mono: parent.mono,
        text_align: parent.text_align, pre: parent.pre, nowrap: parent.nowrap, underline: parent.underline && e.tag == "",
        vars: parent.vars, upper: parent.upper, hidden: parent.hidden, no_marker: parent.no_marker }
    defaults(e, st)
    if e.tag != "" {
        // the cascade: matching rules by specificity and order, then the style attribute;
        // !important declarations after the rest
        var normal: [Decl] = []
        var imp: [Decl] = []
        let sheet = if page { u.page_sheet } else { u.sheet }
        for r in sheet.matching(e, page) {
            for d in r.decls {
                if d.important { imp.push(d) } else { normal.push(d) }
            }
        }
        if let css = e.attrs.get("style") {
            for d in parse_decls(css) {
                if d.important { imp.push(d) } else { normal.push(d) }
            }
        }
        if !normal.is_empty() || !imp.is_empty() {
            // custom properties (--x) first, so var(--x) can use them
            var own = false
            var all: [Decl] = []
            for d in normal { all.push(d) }
            for d in imp { all.push(d) }
            for d in all {
                if d.name.starts_with("--") {
                    if !own {
                        var copy: {str: str} = {}
                        for k in st.vars.keys() { copy[k] = st.vars.get(k) ?? "" }
                        st.vars = copy
                        own = true
                    }
                    st.vars[d.name] = d.value
                }
            }
            for d in normal { apply_decl(st, d.name, subst_vars(d.value, st.vars)) }
            for d in imp { apply_decl(st, d.name, subst_vars(d.value, st.vars)) }
        }
    }
    if e.has("disabled") {
        st.color = gfx.mix(st.color, 0xffffff, 1, 2)
        if st.bg >= 0 { st.bg = gfx.mix(st.bg, 0xffffff, 1, 3) }
    }
    e.st = st
    e.pref = -1
    let inside = page || e.has("data-slot")
    for k in e.kids { style_tree(k, st, u, inside) }
    // an inline element with blocks inside acts as a block (what browsers do, roughly, by splitting it)
    if st.inline() && e.tag != "" {
        for k in e.kids {
            if k.tag != "" && k.st.display != "none" && !k.st.inline() && !k.st.atomic() && k.tag != "br" {
                st.display = "block"
                break
            }
        }
    }
}

// var(--name) and var(--name, fallback), from the custom properties in effect
fn subst_vars(v: str, vars: {str: str}) -> str {
    var out = v
    var guard = 0
    while out.contains("var(") && guard < 8 {
        guard += 1
        let a = out.find("var(")
        // the matching ")"
        var depth = 0
        var end = -1
        let cs = out.slice(a + 4, out.len()).chars()
        var off = 0
        for c in cs {
            if c == "(" { depth += 1 }
            if c == ")" {
                if depth == 0 {
                    end = a + 4 + off
                    break
                }
                depth -= 1
            }
            off += c.len()
        }
        if end < 0 { return out }
        let inner = out.slice(a + 4, end)
        let comma = inner.find(",")
        let name = (if comma >= 0 { inner.slice(0, comma) } else { inner }).trim()
        let fallback = if comma >= 0 { inner.slice(comma + 1, inner.len()).trim() } else { "" }
        let value = vars.get(name) ?? fallback
        out = out.slice(0, a) + value + out.slice(end + 1, out.len())
    }
    return out
}

fn defaults(e: El, st: Style) {
    let t = e.tag
    if t == "" {
        st.display = "inline"
        return
    }
    if INLINE.contains(t) { st.display = "inline" }
    if ATOMIC.contains(t) { st.display = "inline-block" }
    match t {
        "h1" => {
            st.size = 26
            st.bold = true
            st.margin = [0, 0, 10, 0]
        },
        "h2" => {
            st.size = 19
            st.bold = true
            st.margin = [0, 0, 8, 0]
        },
        "h3" | "h4" => {
            st.size = 15
            st.bold = true
            st.margin = [0, 0, 6, 0]
        },
        "p" => { st.margin = [0, 0, 8, 0] },
        "b" | "strong" => { st.bold = true },
        "small" => { st.size = 12 },
        "code" | "pre" | "kbd" => {
            st.mono = true
            if t == "pre" {
                st.pre = true
                st.pad = [8, 10, 8, 10]
                st.bg = 0xf4f3f8
                st.radius = 6
            } else {
                st.bg = 0xefedf5
            }
        },
        "a" => {
            st.color = ACCENT
            st.underline = true
        },
        "button" => {
            st.pad = [6, 14, 6, 14]
            st.bg = 0xefeef4
            st.borders = [1, 1, 1, 1]
            st.border_color = 0xd3d1dd
            st.radius = 7
            st.text_align = "center"
            st.nowrap = true
        },
        "input" => {
            if e.is_check() {
                st.width = 16
                st.height = 16
                st.margin = [0, 6, 0, 0]
            } else {
                st.width = 190
                st.pad = [6, 9, 6, 9]
                st.bg = 0xffffff
                st.borders = [1, 1, 1, 1]
                st.border_color = 0xcbc8d6
                st.radius = 7
                st.nowrap = true
            }
        },
        "textarea" => {
            st.width_pct = 100
            st.height = 120
            st.pad = [7, 9, 7, 9]
            st.bg = 0xffffff
            st.borders = [1, 1, 1, 1]
            st.border_color = 0xcbc8d6
            st.radius = 7
            st.scroll = true
        },
        "progress" => {
            st.width = 160
            st.height = 8
            st.radius = 4
            st.bg = 0xe6e4ee
            st.margin = [4, 0, 4, 0]
        },
        "hr" => {
            st.height = 1
            st.bg = 0xe3e1ea
            st.margin = [10, 0, 10, 0]
        },
        "ul" | "ol" => {
            st.pad = [0, 0, 0, 20]
            st.margin = [0, 0, 8, 0]
        },
        "li" => { st.margin = [0, 0, 3, 0] },
        "tr" => {
            st.display = "flex"
            st.row = true
        },
        "td" | "th" => {
            st.bold = st.bold || t == "th"
            st.grow = 1
            st.pad = [4, 6, 4, 6]
        },
        "canvas" | "img" => {
            st.width = int(e.attr("width")) catch 100
            st.height = int(e.attr("height")) catch 100
            st.bg = 0xe6e4ee
        },
        "select" => {
            st.pad = [6, 9, 6, 9]
            st.borders = [1, 1, 1, 1]
            st.radius = 7
        },
        _ => {},
    }
}

fn apply_css(st: Style, css: str) {
    for d in parse_decls(css) { apply_decl(st, d.name, d.value) }
}

// one declaration; values we can't use (calc(), an unknown unit, a var() with no value) are skipped
fn apply_decl(st: Style, name: str, value: str) {
        let v = value.trim()
        let lv = v.lower()
        if lv.contains("calc(") || lv.contains("var(") || lv.contains("min(") || lv.contains("max(") || lv.contains("clamp(") { return }
        if lv == "inherit" || lv == "initial" || lv == "unset" || lv == "revert" { return }
        match name {
            "visibility" => { st.hidden = lv == "hidden" || lv == "collapse" },
            "opacity" => { st.hidden = number_x10(v) == 0 && !v.contains("%") },
            "text-transform" => { st.upper = if lv == "uppercase" || lv == "lowercase" { lv } else { "" } },
            "list-style" | "list-style-type" => { st.no_marker = lv.contains("none") },
            "row-gap" | "column-gap" => { if is_length(v) { if is_length(v) { st.gap = length(v, st.size) } } },
            "display" => { st.display = v },
            "flex-direction" => { st.row = !v.starts_with("column") },
            "flex-wrap" => { st.wrap = v == "wrap" },
            "flex" | "flex-grow" => { st.grow = number(v.split(" ")[0]) },
            "gap" | "grid-gap" => { st.gap = length(v.split(" ")[0], st.size) },
            "grid-template-columns" => { st.columns = grid_columns(v) },
            "align-items" => { st.align = v.replace("flex-", "") },
            "justify-content" => { st.justify = v.replace("flex-", "") },
            "padding" => { if v.split(" ").all(x => x == "" || is_length(x)) { st.pad = sides(v, st.size) } },
            "padding-top" => { if is_length(v) { if is_length(v) { st.pad[0] = length(v, st.size) } } },
            "padding-right" => { if is_length(v) { if is_length(v) { st.pad[1] = length(v, st.size) } } },
            "padding-bottom" => { if is_length(v) { if is_length(v) { st.pad[2] = length(v, st.size) } } },
            "padding-left" => { if is_length(v) { if is_length(v) { st.pad[3] = length(v, st.size) } } },
            "margin" => {
                st.center = v.contains("auto")
                st.margin = sides(v, st.size)
            },
            "margin-top" => { if is_length(v) { st.margin[0] = length(v, st.size) } },
            "margin-right" => { if is_length(v) { st.margin[1] = length(v, st.size) } },
            "margin-bottom" => { if is_length(v) { st.margin[2] = length(v, st.size) } },
            "margin-left" => { if is_length(v) { st.margin[3] = length(v, st.size) } },
            "width" => size_of(v, st, true),
            "height" => size_of(v, st, false),
            "min-width" => { if is_length(v) { st.min_width = length(v, st.size) } },
            "min-height" => { if is_length(v) { st.min_height = length(v, st.size) } },
            "max-width" => { if is_length(v) { st.max_width = length(v, st.size) } },
            "background" | "background-color" => background(st, v),
            "color" => { st.color = color(v) ?? st.color },
            "border" => border(st, v, [0, 1, 2, 3]),
            "border-top" => border(st, v, [0]),
            "border-right" => border(st, v, [1]),
            "border-bottom" => border(st, v, [2]),
            "border-left" => border(st, v, [3]),
            "border-color" => { st.border_color = color(v) ?? st.border_color },
            "border-radius" => { st.radius = length(v.split(" ")[0], st.size) },
            "box-shadow" => { st.shadow = v != "none" },
            "font-size" => {
                let kw = {"xx-small": 9, "x-small": 10, "small": 12, "medium": 13, "large": 16, "x-large": 20, "xx-large": 26, "smaller": st.size - 2, "larger": st.size + 3}
                if let k = kw.get(lv) {
                    st.size = k
                } else if v.ends_with("%") {
                    st.size = st.size * number(v.slice(0, v.len() - 1)) / 100
                } else if is_length(v) {
                    st.size = length(v, st.size)
                }
                st.size = min(max(st.size, 8), 64)
            },
            "font-weight" => { st.bold = v == "bold" || v == "600" || v == "700" || v == "800" || v == "900" || v == "bolder" },
            "font-family" => { st.mono = v.contains("mono") || v.contains("courier") },
            "font" => {
                for part in v.split(" ") {
                    if part == "bold" || part == "600" || part == "700" { st.bold = true }
                    if part.ends_with("px") { st.size = length(part, st.size) }
                    if part.contains("mono") { st.mono = true }
                }
            },
            "text-align" => { st.text_align = v },
            "text-decoration" => { st.underline = v.contains("underline") },
            "white-space" => {
                st.pre = v.starts_with("pre")
                st.nowrap = v == "nowrap"
            },
            "overflow" | "overflow-y" | "overflow-x" => { st.scroll = v == "auto" || v == "scroll" },
            _ => {},
        }
}

fn size_of(v: str, st: Style, horizontal: bool) {
    if !is_length(v) { return }
    if v.ends_with("%") {
        let p = number(v.slice(0, v.len() - 1))
        if horizontal { st.width_pct = p } else { st.height_pct = p }
    } else if v != "auto" {
        if horizontal { st.width = length(v, st.size) } else { st.height = length(v, st.size) }
    }
}

// hsl(h, s%, l%) as 0xRRGGBB
fn hsl(h0: int, s: int, l: int) -> int {
    let h = ((h0 % 360) + 360) % 360
    let c = (100 - abs(2 * l - 100)) * s / 100           // chroma, 0..100
    let hp = h * 100 / 60                                // 0..600
    let x = c * (100 - abs(hp % 200 - 100)) / 100
    let m = l - c / 2
    var r = 0
    var g = 0
    var b = 0
    if hp < 100 {
        r = c
        g = x
    } else if hp < 200 {
        r = x
        g = c
    } else if hp < 300 {
        g = c
        b = x
    } else if hp < 400 {
        g = x
        b = c
    } else if hp < 500 {
        r = x
        b = c
    } else {
        r = c
        b = x
    }
    return gfx.rgb(min(max((r + m) * 255 / 100, 0), 255), min(max((g + m) * 255 / 100, 0), 255), min(max((b + m) * 255 / 100, 0), 255))
}

fn background(st: Style, v: str) {
    if v.starts_with("linear-gradient") {
        var colors: [int] = []
        for part in split_top(v.slice(v.find("(") + 1, v.len() - 1)) {
            if let c = color(part) { colors.push(c) }
        }
        if colors.len() >= 2 {
            st.bg = colors[0]
            st.bg2 = colors[colors.len() - 1]
        }
        return
    }
    if let c = color(v) {
        st.bg = c
        return
    }
    if v == "transparent" || v == "none" {
        st.bg = -1
        return
    }
    // the shorthand: "#fff url(...) no-repeat" -- its color part
    for part in split_top(v.replace(",", " ")) {
        for word in part.split(" ") {
            if let c = color(word) {
                st.bg = c
                return
            }
        }
    }
}

fn border(st: Style, v: str, which: [int]) {
    if v == "none" || v == "0" {
        for i in which { st.borders[i] = 0 }
        return
    }
    var w = 1
    for part in v.split(" ") {
        if part.ends_with("px") { w = length(part, st.size) }
        if let c = color(part) { st.border_color = c }
    }
    for i in which { st.borders[i] = w }
}

fn grid_columns(v: str) -> int {
    if v.starts_with("repeat(") { return max(number(v.slice(7, v.len()).split(",")[0].trim()), 1) }
    return max(v.split(" ").filter(x => x.trim() != "").len(), 1)
}

// "8px", "1.5em", "12" -> pixels
// a number with a unit we know (px, em, rem, pt, %, vw, vh) or a bare 0
fn is_length(v: str) -> bool {
    let t = v.trim().lower()
    if t == "0" { return true }
    var num = t
    for unit in ["px", "rem", "em", "pt", "%", "vw", "vh"] {
        if t.ends_with(unit) {
            num = t.slice(0, t.len() - unit.len())
            if num == "" { return false }
            for c in num.chars() {
                if !"0123456789.-+".contains(c) { return false }
            }
            return true
        }
    }
    return false
}

fn length(v: str, font: int) -> int {
    let t = v.trim().lower()
    if t.ends_with("pt") { return number_x10(t.slice(0, t.len() - 2)) * 4 / 30 }
    if t.ends_with("vw") { return number_x10(t.slice(0, t.len() - 2)) * 10 / 10 * 7 / 10 }   // a window about 700px wide
    if t.ends_with("vh") { return number_x10(t.slice(0, t.len() - 2)) * 5 / 10 }
    if t.ends_with("em") {
        return number_x10(t.slice(0, t.len() - (if t.ends_with("rem") { 3 } else { 2 }))) * (if t.ends_with("rem") { 16 } else { font }) / 10
    }
    return number(t.replace("px", ""))
}

fn number(s: str) -> int {
    return number_x10(s) / 10
}

// a decimal number times 10 ("1.5" -> 15)
fn number_x10(s: str) -> int {
    let t = s.trim()
    let neg = t.starts_with("-")
    let body = if neg { t.slice(1, t.len()) } else { t }
    let dot = body.find(".")
    let whole = int(if dot >= 0 { body.slice(0, dot) } else { body }) catch 0
    var tenth = 0
    if dot >= 0 && dot + 1 < body.len() { tenth = int(body.slice(dot + 1, dot + 2)) catch 0 }
    let v = whole * 10 + tenth
    return if neg { -v } else { v }
}

fn sides(v: str, font: int) -> [int] {
    let p = v.split(" ").filter(x => x.trim() != "").map(x => if x == "auto" { 0 } else { length(x, font) })
    if p.len() == 1 { return [p[0], p[0], p[0], p[0]] }
    if p.len() == 2 { return [p[0], p[1], p[0], p[1]] }
    if p.len() == 3 { return [p[0], p[1], p[2], p[1]] }
    if p.len() >= 4 { return [p[0], p[1], p[2], p[3]] }
    return [0, 0, 0, 0]
}

const NAMED = {
    "white": 0xffffff, "black": 0x000000, "red": 0xe74c3c, "green": 0x27ae60, "blue": 0x2f6fed,
    "gray": 0x888888, "grey": 0x888888, "orange": 0xf39c12, "yellow": 0xf1c40f, "purple": 0x8e44ad,
    "pink": 0xff79c6, "teal": 0x16a085, "navy": 0x1b2a4a, "silver": 0xc0c0c0, "gold": 0xffd700,
    "crimson": 0xdc143c, "tomato": 0xff6347, "salmon": 0xfa8072, "skyblue": 0x87ceeb, "lime": 0x32cd32,
    "darkgray": 0x555555, "lightgray": 0xd3d3d3, "whitesmoke": 0xf5f5f5, "slategray": 0x708090,
    "maroon": 0x800000, "olive": 0x808000, "aqua": 0x00ffff, "cyan": 0x00ffff, "fuchsia": 0xff00ff,
    "magenta": 0xff00ff, "brown": 0xa52a2a, "beige": 0xf5f5dc, "ivory": 0xfffff0, "khaki": 0xf0e68c,
    "lavender": 0xe6e6fa, "linen": 0xfaf0e6, "darkblue": 0x00008b, "darkgreen": 0x006400, "darkred": 0x8b0000,
    "lightblue": 0xadd8e6, "lightgreen": 0x90ee90, "lightyellow": 0xffffe0, "dimgray": 0x696969,
    "gainsboro": 0xdcdcdc, "indigo": 0x4b0082, "violet": 0xee82ee, "coral": 0xff7f50, "chocolate": 0xd2691e,
    "steelblue": 0x4682b4, "royalblue": 0x4169e1, "seagreen": 0x2e8b57, "forestgreen": 0x228b22,
    "firebrick": 0xb22222, "darkorange": 0xff8c00, "aliceblue": 0xf0f8ff, "ghostwhite": 0xf8f8ff,
    "snow": 0xfffafa, "mintcream": 0xf5fffa, "honeydew": 0xf0fff0, "azure": 0xf0ffff, "wheat": 0xf5deb3,
    "tan": 0xd2b48c, "plum": 0xdda0dd, "orchid": 0xda70d6, "turquoise": 0x40e0d0, "darkslategray": 0x2f4f4f,
}

fn color(v: str) -> int? {
    let t = v.trim().lower()
    if t.starts_with("#") {
        let h = t.slice(1, t.len())
        if h.len() == 3 {
            let cs = h.chars()
            return some(hexval(cs[0] + cs[0] + cs[1] + cs[1] + cs[2] + cs[2]))
        }
        if h.len() >= 6 { return some(hexval(h.slice(0, 6))) }
        return none
    }
    if t.starts_with("rgb") && t.contains("(") {
        let inner = t.slice(t.find("(") + 1, t.len() - 1)
        let p = inner.replace("/", " ").replace(",", " ").split(" ").filter(x => x != "").map(x => if x.ends_with("%") { number(x.slice(0, x.len() - 1)) * 255 / 100 } else { number(x) })
        if p.len() >= 3 { return some(gfx.rgb(min(max(p[0], 0), 255), min(max(p[1], 0), 255), min(max(p[2], 0), 255))) }
        return none
    }
    if t.starts_with("hsl") && t.contains("(") {
        let inner = t.slice(t.find("(") + 1, t.len() - 1)
        let p = inner.replace("/", " ").replace(",", " ").replace("deg", "").replace("%", "").split(" ").filter(x => x != "").map(x => number(x))
        if p.len() >= 3 { return some(hsl(p[0], p[1], p[2])) }
        return none
    }
    return NAMED.get(t)
}

fn hexval(h: str) -> int {
    var v = 0
    for c in h.chars() {
        let d = "0123456789abcdef".find(c)
        v = v * 16 + max(d, 0)
    }
    return v
}

// ---- layout ----

fn clear_pref(e: El) {
    e.pref = -1
    for k in e.kids { clear_pref(k) }
}

// horizontal margins + borders + padding
fn hextra(st: Style) -> int { return st.pad[1] + st.pad[3] + st.borders[1] + st.borders[3] }
fn vextra(st: Style) -> int { return st.pad[0] + st.pad[2] + st.borders[0] + st.borders[2] }

// The width an element would like (its content on one line), border box.
fn pref(e: El, u: Ui) -> int {
    if e.pref >= 0 { return e.pref }
    let st = e.st
    var w = 0
    if st.display == "none" {
        w = 0
    } else if st.width >= 0 {
        w = st.width
    } else if e.tag == "" {
        w = gfx.text_width(collapse(e.text, st.pre), st.face())
    } else if e.is_field() {
        w = 190
    } else if st.columns > 0 {
        var most = 0
        for k in elements(e) { most = max(most, pref(k, u) + k.st.margin[1] + k.st.margin[3]) }
        w = most * st.columns + st.gap * (st.columns - 1) + hextra(st)
    } else if st.flex() && st.row {
        var sum = 0
        var n = 0
        for k in elements(e) {
            sum += pref(k, u) + k.st.margin[1] + k.st.margin[3]
            n += 1
        }
        w = sum + st.gap * max(n - 1, 0) + hextra(st)
    } else if has_inline(e) && !st.flex() {
        // the inline content on one line (blocks among it on their own)
        var line = 0
        var most = 0
        for k in e.kids {
            if k.st.display == "none" { continue }
            if k.st.inline() || k.st.atomic() {
                line += pref(k, u) + if k.tag == "" { 0 } else { k.st.margin[1] + k.st.margin[3] }
                if k.tag == "" { line += gfx.text_width(" ", st.face()) }
            } else if k.tag == "br" {
                most = max(most, line)
                line = 0
            } else {
                most = max(max(most, line), pref(k, u) + k.st.margin[1] + k.st.margin[3])
                line = 0
            }
        }
        w = max(most, line) + hextra(st)
    } else {
        var most = 0
        for k in elements(e) { most = max(most, pref(k, u) + k.st.margin[1] + k.st.margin[3]) }
        w = most + hextra(st)
    }
    if st.min_width >= 0 { w = max(w, st.min_width) }
    if st.max_width >= 0 { w = min(w, st.max_width) }
    e.pref = w
    return w
}

fn elements(e: El) -> [El] {
    return e.kids.filter(k => k.st.display != "none" && !(k.tag == "" && k.text.trim() == ""))
}

fn has_inline(e: El) -> bool {
    for k in e.kids {
        if k.st.display != "none" && (k.st.inline() || k.st.atomic() || k.tag == "br") {
            if k.tag != "" || k.text.trim() != "" || e.st.pre { return true }
        }
    }
    return false
}

// Lay `e` out with its border box at (x, y), `w` wide; `h` is its height if the parent decides
// (stretching), or -1.
fn layout(e: El, x: int, y: int, w: int, h: int, u: Ui) {
    let st = e.st
    e.x = x
    e.y = y
    e.w = w
    e.words = []
    let cx = x + st.pad[3] + st.borders[3]
    let cy = y + st.pad[0] + st.borders[0]
    let cw = max(w - hextra(st), 0)
    var fixed_h = if h >= 0 { h } else if st.height >= 0 { st.height } else { -1 }   // the parent's say (flex-grow, stretch) wins
    if fixed_h < 0 && st.height_pct >= 0 {
        if let p = e.parent { if p.avail_h >= 0 { fixed_h = p.avail_h * st.height_pct / 100 } }
    }
    e.avail_h = if fixed_h >= 0 { fixed_h - vextra(st) } else { -1 }
    var content = 0
    if e.is_field() || e.is_check() || e.tag == "progress" || e.tag == "hr" || e.tag == "canvas" || e.tag == "img" {
        content = if e.tag == "textarea" { field_lines(e, u) * gfx.line_height(st.face()) } else if e.is_field() { gfx.line_height(st.face()) } else { 0 }
    } else if st.columns > 0 {
        content = layout_grid(e, cx, cy, cw, u)
    } else if e.attr("data-tag") == "table" && !st.flex() {
        content = layout_table(e, cx, cy, cw, u)
    } else if st.flex() {
        let inner_h = if fixed_h >= 0 { fixed_h - vextra(st) } else { -1 }
        content = if st.row { layout_row(e, cx, cy, cw, inner_h, u) } else { layout_column(e, cx, cy, cw, inner_h, u) }
    } else if has_inline(e) {
        content = layout_inline(e, cx, cy, cw, u)
    } else {
        content = layout_blocks(e, cx, cy, cw, u)
    }
    e.inner_h = content + vextra(st)
    var height = if fixed_h >= 0 { fixed_h } else { content + vextra(st) }
    if st.min_height >= 0 { height = max(height, st.min_height) }
    e.h = height
}

fn field_lines(e: El, u: Ui) -> int {
    let f = u.field(e)
    return max(f.text.split("\n").len(), 1)
}

// the width a child gets in a block of width `cw`
fn block_width(k: El, cw: int, u: Ui) -> int {
    let st = k.st
    let room = cw - st.margin[1] - st.margin[3]
    var w = room
    if st.width >= 0 {
        w = st.width
    } else if st.width_pct >= 0 {
        w = room * st.width_pct / 100
    } else if st.atomic() {
        w = min(pref(k, u), room)
    }
    if st.max_width >= 0 { w = min(w, st.max_width) }
    if st.min_width >= 0 { w = max(w, st.min_width) }
    return max(w, 0)
}

fn layout_blocks(e: El, cx: int, cy: int, cw: int, u: Ui) -> int {
    var y = cy
    var prev_margin = 0
    for k in e.kids {
        if k.st.display == "none" || (k.tag == "" && k.text.trim() == "") { continue }
        let m = k.st.margin
        let collapsed = max(prev_margin, m[0])      // margins between blocks overlap
        y += collapsed - prev_margin
        let kw = block_width(k, cw, u)
        let kx = if k.st.center { cx + (cw - kw) / 2 } else { cx + m[3] }
        layout(k, kx, y, kw, -1, u)
        y += k.h + m[2]
        prev_margin = m[2]
    }
    return y - cy
}

fn layout_column(e: El, cx: int, cy: int, cw: int, ch: int, u: Ui) -> int {
    let st = e.st
    let kids = elements(e)
    // first pass: natural heights
    var total = 0
    var grow = 0
    for k in kids {
        let sized = k.st.width >= 0 || k.st.width_pct >= 0
        let kw = if sized { block_width(k, cw, u) } else if st.align == "stretch" { cw - k.st.margin[1] - k.st.margin[3] } else { min(block_width(k, cw, u), pref(k, u)) }
        layout(k, cx, cy, max(kw, 0), -1, u)
        total += k.h + k.st.margin[0] + k.st.margin[2]
        grow += k.st.grow
    }
    total += st.gap * max(kids.len() - 1, 0)
    let free = if ch >= 0 { ch - total } else { 0 }
    var y = cy
    if free > 0 && grow == 0 {
        if st.justify == "center" { y += free / 2 }
        if st.justify == "end" { y += free }
    }
    let between = if free > 0 && grow == 0 && st.justify == "space-between" && kids.len() > 1 { free / (kids.len() - 1) } else { 0 }
    for k in kids {
        var kh = k.h
        if free > 0 && grow > 0 && k.st.grow > 0 { kh += free * k.st.grow / grow }
        let kw = k.w
        var kx = cx + k.st.margin[3]
        if st.align == "center" { kx = cx + (cw - kw) / 2 }
        if st.align == "end" { kx = cx + cw - kw - k.st.margin[1] }
        y += k.st.margin[0]
        layout(k, kx, y, kw, if kh != k.h { kh } else { -1 }, u)
        y += k.h + k.st.margin[2] + st.gap + between
    }
    return max(y - cy - st.gap - between, 0)
}

fn layout_row(e: El, cx: int, cy: int, cw: int, ch: int, u: Ui) -> int {
    let st = e.st
    let kids = elements(e)
    if kids.is_empty() { return 0 }
    // split into lines (one, unless flex-wrap)
    var lines: [[El]] = []
    var line: [El] = []
    var used = 0
    for k in kids {
        let b = basis(k, cw, u) + k.st.margin[1] + k.st.margin[3]
        if st.wrap && !line.is_empty() && used + st.gap + b > cw {
            lines.push(line)
            line = []
            used = 0
        }
        used += (if line.is_empty() { 0 } else { st.gap }) + b
        line.push(k)
    }
    lines.push(line)
    var y = cy
    for li, ks in lines {
        var sum = 0
        var grow = 0
        var widths: [int] = []
        for k in ks {
            let b = basis(k, cw, u)
            widths.push(b)
            sum += b + k.st.margin[1] + k.st.margin[3]
            grow += k.st.grow
        }
        sum += st.gap * (ks.len() - 1)
        var free = cw - sum
        if free > 0 && grow > 0 {
            for i, k in ks {
                if k.st.grow > 0 { widths[i] += free * k.st.grow / grow }
            }
            free = 0
        } else if free < 0 {
            // too wide: shrink, the wide ones most
            var total = 0
            for wd in widths { total += wd }
            for i in 0..widths.len() {
                if total > 0 { widths[i] = max(widths[i] + free * widths[i] / total, 0) }
            }
            free = 0
        }
        var x = cx
        var between = 0
        if free > 0 {
            if st.justify == "center" { x += free / 2 }
            if st.justify == "end" { x += free }
            if st.justify == "space-between" && ks.len() > 1 { between = free / (ks.len() - 1) }
            if st.justify == "space-around" {
                between = free / ks.len()
                x += between / 2
            }
        }
        // heights: lay out each, then line them up
        var tallest = 0
        for i, k in ks {
            layout(k, x, y, widths[i], -1, u)
            tallest = max(tallest, k.h + k.st.margin[0] + k.st.margin[2])
        }
        if ch >= 0 && lines.len() == 1 { tallest = max(tallest, ch) }
        for i, k in ks {
            x += k.st.margin[3]
            var ky = y + k.st.margin[0]
            var kh = -1
            let room = tallest - k.st.margin[0] - k.st.margin[2]
            if st.align == "stretch" && k.st.height < 0 { kh = room }
            if st.align == "center" { ky = y + (tallest - k.h) / 2 }
            if st.align == "end" { ky = y + tallest - k.h - k.st.margin[2] }
            layout(k, x, ky, widths[i], kh, u)
            x += widths[i] + k.st.margin[1] + st.gap + between
        }
        y += tallest + if li + 1 < lines.len() { st.gap } else { 0 }
    }
    return y - cy
}

// ---- tables (web pages: the browser marks them with data-tag="table") ----

fn table_rows(e: El, out: [El]) {
    for k in elements(e) {
        let t = k.attr("data-tag")
        if k.tag == "tr" { out.push(k) } else if t == "thead" || t == "tbody" || t == "tfoot" { table_rows(k, out) }
    }
}

fn span(k: El) -> int {
    return min(max(int(k.attr("colspan")) catch 1, 1), 20)
}

// Column widths from the cells' content, across all rows; then each row's cells side by side.
fn layout_table(e: El, cx: int, cy: int, cw: int, u: Ui) -> int {
    var rows: [El] = []
    table_rows(e, rows)
    var ncol = 0
    for r in rows {
        var n = 0
        for c in elements(r) { n += span(c) }
        ncol = max(ncol, n)
    }
    if ncol == 0 { return layout_blocks(e, cx, cy, cw, u) }
    var prefs: [int] = []
    for i in 0..ncol { prefs.push(0) }
    for r in rows {
        var col = 0
        for c in elements(r) {
            let s = span(c)
            let w = if c.st.width >= 0 { c.st.width } else { pref(c, u) }
            if s == 1 { prefs[col] = max(prefs[col], w) }
            col += s
        }
    }
    var total = 0
    for p in prefs { total += p }
    // the table's width: as asked (width="85%"), else its content's, at most what there is
    var target = min(total, cw)
    let wa = e.attr("width")
    if wa.ends_with("%") {
        target = cw * min(number(wa.slice(0, wa.len() - 1)), 100) / 100
    } else if e.st.width_pct >= 0 {
        target = cw * min(e.st.width_pct, 100) / 100
    } else if wa != "" {
        target = min(number(wa), cw)
    }
    var widths: [int] = []
    if total <= target {
        // room to spare: share it out like the content
        for p in prefs { widths.push(if total > 0 { p + (target - total) * p / total } else { target / ncol }) }
    } else {
        // too wide: narrow columns keep their width, the wide ones share the rest
        let fair = target / ncol
        var fixed = 0
        var wide = 0
        for p in prefs {
            if p <= fair { fixed += p } else { wide += p }
        }
        let room = max(target - fixed, ncol * 20)
        for p in prefs { widths.push(if p <= fair { p } else { max(p * room / max(wide, 1), 20) }) }
    }
    // centered by <center> / align="center" (the table itself; its text starts at the left)
    var tx = cx
    if let p = e.parent {
        if p.st.text_align == "center" || e.attr("align") == "center" || e.st.center { tx = cx + max(cw - target, 0) / 2 }
    }
    var y = cy
    for r in rows {
        let cells = elements(r)
        var tallest = 0
        for pass in 0..2 {
            var x = tx
            var col = 0
            for c in cells {
                let s = span(c)
                var w = 0
                for i in col..min(col + s, ncol) { w += widths[i] }
                layout(c, x, y, w, if pass == 0 { -1 } else { tallest }, u)
                tallest = max(tallest, c.h)
                x += w
                col += s
            }
        }
        r.x = tx
        r.y = y
        r.w = target
        r.h = tallest
        r.inner_h = tallest
        r.words = []
        y += tallest
    }
    // row groups (tbody, ...) cover their rows
    for g in elements(e) {
        if g.tag == "tr" { continue }
        var gr: [El] = []
        table_rows(g, gr)
        if gr.is_empty() { continue }
        g.x = tx
        g.y = gr[0].y
        g.w = target
        g.h = gr[gr.len() - 1].y + gr[gr.len() - 1].h - g.y
        g.inner_h = g.h
        g.words = []
    }
    return y - cy
}

fn basis(k: El, cw: int, u: Ui) -> int {
    if k.st.width >= 0 { return k.st.width }
    if k.st.width_pct >= 0 { return cw * k.st.width_pct / 100 }
    if k.st.grow > 0 { return 0 }
    return min(pref(k, u), cw)
}

fn layout_grid(e: El, cx: int, cy: int, cw: int, u: Ui) -> int {
    let st = e.st
    let n = st.columns
    let colw = (cw - st.gap * (n - 1)) / n
    let kids = elements(e)
    var y = cy
    var i = 0
    while i < kids.len() {
        var tallest = 0
        for c in 0..n {
            if i + c >= kids.len() { break }
            let k = kids[i + c]
            layout(k, cx + c * (colw + st.gap) + k.st.margin[3], y + k.st.margin[0], colw - k.st.margin[1] - k.st.margin[3], -1, u)
            tallest = max(tallest, k.h + k.st.margin[0] + k.st.margin[2])
        }
        for c in 0..n {
            if i + c >= kids.len() { break }
            let k = kids[i + c]
            if k.st.height < 0 { layout(k, k.x, k.y, k.w, tallest - k.st.margin[0] - k.st.margin[2], u) }
        }
        y += tallest + st.gap
        i += n
    }
    return max(y - cy - st.gap, 0)
}

// Words and inline boxes, wrapped into lines.
fn layout_inline(e: El, cx: int, cy: int, cw: int, u: Ui) -> int {
    var items: [Word] = []
    gather(e, e.st, items, u)
    var y = cy
    var line: [Word] = []
    var x = 0
    let wrap = !e.st.nowrap && !e.st.pre
    for it in items {
        if it.brk {
            y = finish_line(e, line, cx, y, cw, gfx.line_height(e.st.face()), u)
            line = []
            x = 0
            continue
        }
        if it.box && !it.el.st.inline() && !it.el.st.atomic() {
            // a block-level box (block, flex, grid, table, ...) among inline content: its own line(s)
            if !line.is_empty() {
                y = finish_line(e, line, cx, y, cw, 0, u)
                line = []
                x = 0
            }
            let k = it.el
            y += k.st.margin[0]
            let kw = block_width(k, cw, u)
            layout(k, if k.st.center { cx + (cw - kw) / 2 } else { cx + k.st.margin[3] }, y, kw, -1, u)
            y += k.h + k.st.margin[2]
            continue
        }
        if it.box {
            layout(it.el, 0, 0, min(pref(it.el, u), cw), -1, u)
            it.w = it.el.w + it.el.st.margin[1] + it.el.st.margin[3]
            it.h = it.el.h + it.el.st.margin[0] + it.el.st.margin[2]
        }
        if wrap && !line.is_empty() && x + it.w > cw {
            y = finish_line(e, line, cx, y, cw, 0, u)
            line = []
            x = 0
        }
        it.x = x
        line.push(it)
        x += it.w + it.space
    }
    if !line.is_empty() { y = finish_line(e, line, cx, y, cw, 0, u) }
    return y - cy
}

// place a line's items (centered vertically on the line), returns the next line's y
fn finish_line(e: El, line: [Word], cx: int, y: int, cw: int, min_h: int, u: Ui) -> int {
    var lh = min_h
    var width = 0
    for it in line {
        lh = max(lh, it.h)
        width = it.x + it.w
    }
    var shift = 0
    if e.st.text_align == "center" { shift = (cw - width) / 2 }
    if e.st.text_align == "right" { shift = cw - width }
    for it in line {
        it.x = cx + it.x + shift
        it.y = y + (lh - it.h) / 2
        if it.box {
            let k = it.el
            layout(k, it.x + k.st.margin[3], it.y + k.st.margin[0], k.w, -1, u)
            it.el.x = it.x + k.st.margin[3]
            it.el.y = it.y + k.st.margin[0]
        } else {
            e.words.push(it)
        }
    }
    return y + lh
}

fn gather(e: El, st: Style, out: [Word], u: Ui) {
    for k in e.kids {
        if k.st.display == "none" { continue }
        if k.tag == "br" {
            out.push(Word { text: "", el: k, brk: true })
        } else if k.tag == "" {
            let face = k.st.face()
            let lh = gfx.line_height(face)
            let space = gfx.text_width(" ", face)
            let owner = k.parent ?? e
            if k.st.pre {
                for i, l in k.text.split("\n") {
                    if i > 0 { out.push(Word { text: "", el: owner, brk: true }) }
                    out.push(Word { text: l, w: gfx.text_width(l, face), h: lh, face, color: k.st.color, el: owner, bg: inline_bg(owner, e) })
                }
            } else {
                var text = k.text.replace("\n", " ").replace("\t", " ").replace("\r", " ")
                if k.st.upper == "uppercase" { text = text.upper() } else if k.st.upper == "lowercase" { text = text.lower() }
                let lead = text.starts_with(" ")
                if lead && !out.is_empty() { out[out.len() - 1].space = max(out[out.len() - 1].space, space) }
                let words = text.split(" ").filter(w => w != "")
                for i, wd in words {
                    let last = i + 1 == words.len()
                    let trail = !last || text.ends_with(" ")
                    out.push(Word { text: wd, w: gfx.text_width(wd, face), h: lh, face, color: k.st.color, el: owner,
                        space: if trail { space } else { 0 }, underline: k.st.underline || owner.st.underline, bg: inline_bg(owner, e) })
                }
            }
        } else if k.st.inline() {
            gather(k, k.st, out, u)
        } else {
            out.push(Word { text: "", el: k, box: true })
        }
    }
}

// an inline element's own background (code, mark), not the block's
// the background showing through a transparent element
fn backdrop(e: El) -> int {
    var cur = e.parent
    while true {
        if let c = cur {
            if c.st.bg >= 0 { return c.st.bg }
            cur = c.parent
        } else {
            break
        }
    }
    return 0xffffff
}

fn inline_bg(owner: El, block: El) -> int {
    if owner.path == block.path { return -1 }
    return owner.st.bg
}

// ---- painting ----

struct Painter {
    s: gfx.Surface,
    ui: Ui,

    // clip: the visible rectangle [x, y, w, h] in surface coordinates; (ox, oy) shifts content
    fn el(self, e: El, ox: int, oy: int, clip: [int]) {
        let st = e.st
        if st.display == "none" || e.tag == "" || st.hidden { return }
        let s = self.s
        let x = e.x - ox
        let y = e.y - oy
        if y > clip[1] + clip[3] || y + e.h < clip[1] || x > clip[0] + clip[2] || x + e.w < clip[0] { return }
        s.clip(clip[0], clip[1], clip[2], clip[3])
        let hover = self.ui.hover != "" && self.ui.hover.starts_with(e.path)
        let active = self.ui.active != "" && self.ui.active.starts_with(e.path)
        let focused = self.ui.focus == e.path
        var bg = st.bg
        if e.tag == "button" && bg >= 0 {
            if active { bg = gfx.tint(bg, -26) } else if hover { bg = gfx.tint(bg, if luminance(bg) > 128 { -10 } else { 22 }) }
        }
        if st.shadow {
            for i in 0..5 { s.round_shade(x - i, y - i + 3, e.w + 2 * i, e.h + 2 * i, st.radius + i, 0x1b1530, 9) }
        }
        let bw = st.borders
        let any_border = bw[0] + bw[1] + bw[2] + bw[3] > 0
        var bc = st.border_color
        if focused && (e.is_field() || e.tag == "button") { bc = ACCENT }
        if any_border && st.radius > 0 && bw[0] == bw[1] && bw[1] == bw[2] && bw[2] == bw[3] {
            let k = bw[0]
            s.round(x, y, e.w, e.h, st.radius, bc)
            // the inside: its background, or (transparent) what's behind it
            s.round(x + k, y + k, e.w - 2 * k, e.h - 2 * k, max(st.radius - k, 0), if bg >= 0 { bg } else { backdrop(e) })
            if focused && e.is_field() {
                s.round_shade(x - 2, y - 2, e.w + 4, e.h + 4, st.radius + 2, ACCENT, 50)
                s.round(x + 1, y + 1, e.w - 2, e.h - 2, max(st.radius - 1, 0), bg)
            }
        } else {
            if bg >= 0 {
                if st.bg2 >= 0 {
                    s.gradient(x, y, e.w, e.h, bg, st.bg2)
                } else if st.radius > 0 {
                    s.round(x, y, e.w, e.h, st.radius, bg)
                } else {
                    s.rect(x, y, e.w, e.h, bg)
                }
            }
            if any_border {
                s.rect(x, y, e.w, bw[0], bc)
                s.rect(x, y + e.h - bw[2], e.w, bw[2], bc)
                s.rect(x, y, bw[3], e.h, bc)
                s.rect(x + e.w - bw[1], y, bw[1], e.h, bc)
            }
        }
        // what's special about some elements
        if e.tag == "li" && !st.no_marker {
            if let p = e.parent {
                let face = st.face()
                let mark = if p.tag == "ol" { "${index_in(p, e) + 1}." } else { "•" }
                s.text(x - 4 - gfx.text_width(mark, face), y, mark, st.color, face)
            }
        }
        if e.tag == "progress" {
            let most = max(number_x10(e.attr("max")), 1)
            let v = min(max(number_x10(e.attr("value")), 0), most)
            if e.attr("max") == "" {
                s.round(x, y, e.w * v / 10, e.h, st.radius, ACCENT)
            } else {
                s.round(x, y, e.w * v / most, e.h, st.radius, ACCENT)
            }
        }
        if e.is_check() {
            let on = self.ui.field(e).checked
            let radio = e.attr("type") == "radio"
            let r = if radio { 8 } else { 4 }
            s.round(x, y, 16, 16, r, if on { ACCENT } else if hover { 0x9a96ab } else { 0xb3b0c2 })
            if !on { s.round(x + 1, y + 1, 14, 14, r - 1, 0xffffff) }
            if on && radio { s.circle(x + 8, y + 8, 3, 0xffffff) }
            if on && !radio { s.text_in(x, y, 16, 16, "✓", 0xffffff, gfx.UI_BOLD) }
        }
        if e.is_field() { self.field(e, x, y) }
        // inline content and children, inside the padding box
        let inner = [x + bw[3], y + bw[0], e.w - bw[1] - bw[3], e.h - bw[0] - bw[2]]
        let c = if st.scroll || e.tag == "button" || e.is_field() { intersect(clip, inner) } else { clip }
        let sy = if st.scroll { self.ui.scrolls.get(e.path) ?? 0 } else { 0 }
        s.clip(c[0], c[1], c[2], c[3])
        for w in e.words {
            let wx = w.x - ox
            let wy = w.y - oy - sy
            if wy > c[1] + c[3] || wy + w.h < c[1] { continue }
            if w.bg >= 0 { s.round(wx - 2, wy, w.w + 4, w.h, 3, w.bg) }
            var color = w.color
            if w.el.tag == "a" && self.ui.hover.starts_with(w.el.path) && self.ui.hover != "" { color = gfx.tint(color, -40) }
            s.text(wx, wy, w.text, color, w.face)
            if w.underline { s.rect(wx, wy + gfx.ascent(w.face) + 2, w.w, 1, color) }
        }
        if !e.is_field() {
            for k in e.kids { self.el(k, ox, oy + sy, c) }
        }
        if st.scroll && e.inner_h > e.h && e.h > 0 {
            // the scrollbar
            let track = e.h - 8
            let thumb = max(track * e.h / e.inner_h, 24)
            let at = (track - thumb) * sy / max(e.inner_h - e.h, 1)
            s.clip(clip[0], clip[1], clip[2], clip[3])
            s.round_shade(x + e.w - 8, y + 4 + at, 5, thumb, 3, 0x000000, if hover { 90 } else { 50 })
        }
        s.clip(clip[0], clip[1], clip[2], clip[3])
    }

    fn field(self, e: El, x: int, y: int) {
        let s = self.s
        let st = e.st
        let f = self.ui.field(e)
        let face = st.face()
        let lh = gfx.line_height(face)
        let tx = x + st.pad[3] + st.borders[3]
        let ty = y + st.pad[0] + st.borders[0]
        let inner = [x + st.borders[3], y + st.borders[0], e.w - st.borders[1] - st.borders[3], e.h - st.borders[0] - st.borders[2]]
        s.clip(inner[0], inner[1], inner[2], inner[3])
        let shown = if e.attr("type") == "password" { "•".repeat(f.text.chars().len()) } else { f.text }
        let focused = self.ui.focus == e.path
        if shown == "" && e.attr("placeholder") != "" {
            s.text(tx, ty, e.attr("placeholder"), 0xa9a6b7, face)
        }
        let cs = shown.chars()
        if e.tag == "textarea" {
            let sy = self.ui.scrolls.get(e.path) ?? 0
            for i, l in shown.split("\n") { s.text(tx, ty + i * lh - sy, l, st.color, face) }
            if focused && self.ui.blink == 0 {
                var line = 0
                var start = 0
                for i in 0..f.caret {
                    if cs[i] == "\n" {
                        line += 1
                        start = i + 1
                    }
                }
                let cx = tx + gfx.text_width(cs.slice(start, f.caret).join(""), face)
                s.rect(cx, ty + line * lh - sy, 1, lh, INK)
            }
        } else {
            let before = gfx.text_width(cs.slice(0, min(f.caret, cs.len())).join(""), face)
            let room = inner[2] - st.pad[1] - st.pad[3] - 2
            let shift = max(before - room, 0)        // keep the caret in view
            s.text(tx - shift, ty, shown, st.color, face)
            if focused && self.ui.blink == 0 { s.rect(tx + before - shift, ty, 1, lh, INK) }
        }
    }
}

// split at the commas that aren't inside parentheses: "rgb(1,2,3), #fff" -> ["rgb(1,2,3)", "#fff"]
fn split_top(s: str) -> [str] {
    var out: [str] = []
    var cur: [str] = []
    var depth = 0
    for c in s.chars() {
        if c == "(" { depth += 1 }
        if c == ")" { depth -= 1 }
        if c == "," && depth == 0 {
            out.push(cur.join("").trim())
            cur = []
        } else {
            cur.push(c)
        }
    }
    out.push(cur.join("").trim())
    return out
}

fn intersect(a: [int], b: [int]) -> [int] {
    let x0 = max(a[0], b[0])
    let y0 = max(a[1], b[1])
    let x1 = min(a[0] + a[2], b[0] + b[2])
    let y1 = min(a[1] + a[3], b[1] + b[3])
    return [x0, y0, max(x1 - x0, 0), max(y1 - y0, 0)]
}

fn luminance(c: int) -> int {
    return ((c >> 16 & 255) * 3 + (c >> 8 & 255) * 6 + (c & 255)) / 10
}

fn index_in(p: El, e: El) -> int {
    var n = 0
    for k in p.kids {
        if k.path == e.path { return n }
        if k.tag == "li" { n += 1 }
    }
    return n
}

// ---- finding elements ----

fn hit_in(e: El, x: int, y: int, u: Ui) -> El? {
    if e.st.display == "none" || e.tag == "" { return none }
    if x < e.x || y < e.y || x >= e.x + e.w || y >= e.y + e.h { return none }
    let sy = if e.st.scroll { u.scrolls.get(e.path) ?? 0 } else { 0 }
    var i = e.kids.len() - 1
    while i >= 0 {
        if let h = hit_in(e.kids[i], x, y + sy, u) { return some(h) }
        i -= 1
    }
    for w in e.words {
        if x >= w.x && x < w.x + w.w + w.space && y + sy >= w.y && y + sy < w.y + w.h { return some(w.el) }
    }
    return some(e)
}

fn repath(e: El, path: str) {
    e.path = path
    for i, k in e.kids {
        k.parent = some(e)
        repath(k, "${path}.${i}")
    }
}

fn find_path(e: El, path: str) -> El? {
    if e.path == path { return some(e) }
    if !path.starts_with(e.path + ".") { return none }
    for k in e.kids {
        if let f = find_path(k, path) { return some(f) }
    }
    return none
}

fn first_with(e: El, attr: str) -> El? {
    if e.has(attr) { return some(e) }
    for k in e.kids {
        if let f = first_with(k, attr) { return some(f) }
    }
    return none
}

fn first_input(e: El) -> El? {
    if e.is_field() || e.is_check() { return some(e) }
    for k in e.kids {
        if let f = first_input(k) { return some(f) }
    }
    return none
}

fn scroller(e: El) -> El? {
    var cur: El? = some(e)
    while true {
        if let c = cur {
            if c.st.scroll && c.inner_h > c.h { return some(c) }
            cur = c.parent
        } else {
            return none
        }
    }
    return none
}

fn focus_target(e: El) -> El? {
    var cur: El? = some(e)
    while true {
        if let c = cur {
            if c.focusable() { return some(c) }
            cur = c.parent
        } else {
            return none
        }
    }
    return none
}

fn collect_focusable(e: El, out: [El]) {
    if e.st.display == "none" { return }
    if e.is_field() || e.is_check() || e.tag == "button" || e.has("tabindex") { out.push(e) }
    for k in e.kids { collect_focusable(k, out) }
}

fn collapse(s: str, pre: bool) -> str {
    if pre { return s }
    return s.replace("\n", " ").split(" ").filter(w => w != "").join(" ")
}

// ---- text editing helpers (characters, by index) ----

fn line_start(cs: [str], at: int) -> int {
    var i = at
    while i > 0 && cs[i - 1] != "\n" { i -= 1 }
    return i
}

fn line_end(cs: [str], at: int) -> int {
    var i = at
    while i < cs.len() && cs[i] != "\n" { i += 1 }
    return i
}

fn vertical(cs: [str], at: int, dir: int) -> int {
    let start = line_start(cs, at)
    let col = at - start
    if dir < 0 {
        if start == 0 { return 0 }
        let prev = line_start(cs, start - 1)
        return min(prev + col, start - 1)
    }
    let end = line_end(cs, at)
    if end >= cs.len() { return cs.len() }
    let next_end = line_end(cs, end + 1)
    return min(end + 1 + col, next_end)
}
