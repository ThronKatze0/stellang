// The page, as scripts see it: document, elements, events, timers, storage, location. It binds
// js.st (the engine) to the browser's element tree (ui.El, from html.st).
//
// What a page's scripts can reach is only this: their own page's elements, their own timers, their
// own storage (in memory, per site), console, and the page's own address. Not the network (fetch and
// XMLHttpRequest refuse), not files, not the browser's controls (the DOM ends at the page's root),
// not other pages. Every run is on a step budget, and a page that keeps the CPU busy has its scripts
// stopped. Navigation by script goes through the browser's usual checks, a few times per page at most.

import kernel
import ui
import html
import js
import jsstd
import jsparse

const RUN_BUDGET = 1_000_000      // steps for one script, handler or timer (about 2 seconds at most)
const PAGE_BUDGET = 15_000_000    // steps for everything a page runs
const MAX_TIMERS = 200

struct Listener {
    kind: str,
    f: js.Val,
    once: bool = false,
}

struct Dom {
    it: js.Interp,
    root: ui.El,
    url: str,
    origin: str,
    nodes: {int: ui.El} = {},
    wrappers: {int: js.Val} = {},
    listeners: {int: [Listener]} = {},
    next_uid: int = 1,
    timers: {int: int} = {},          // script timer id -> kernel timer id
    next_timer: int = 1,
    natives: {str: js.Val} = {},
    used: int = 0,                    // steps so far, all runs
    dead: bool = false,
    errors: int = 0,
    ran: int = 0,
    last_error: str = "",
    navigations: int = 0,
    storage: {str: str} = {},
    changed: fn() = () => {},
    navigate: fn(str) = (u: str) => {},
    notice: fn(str) = (s: str) => {},
    retitle: fn(str) = (s: str) => {},
    field_get: fn(ui.El) -> str = (e: ui.El) => "",
    field_set: fn(ui.El, str) = (e: ui.El, v: str) => {},
    log: [str] = [],
    title: str = "",

    // ---- nodes and their wrappers ----

    fn uid(self, e: ui.El) -> int {
        if e.uid == 0 {
            e.uid = self.next_uid
            self.next_uid += 1
        }
        self.nodes[e.uid] = e
        return e.uid
    }

    fn wrap(self, e: ui.El) -> js.Val {
        let id = self.uid(e)
        if let w = self.wrappers.get(id) { return w }
        let o = self.it.new_obj("Object")
        o.host = id
        o.host_kind = "el"
        let w = js.object(o)
        self.wrappers[id] = w
        return w
    }

    fn wrap_opt(self, e: ui.El?) -> js.Val {
        if let x = e { return self.wrap(x) }
        return js.null_v()
    }

    fn el_of(self, v: js.Val) -> ui.El? {
        if let o = v.o {
            if o.host > 0 && o.host_kind == "el" { return self.nodes.get(o.host) }
        }
        return none
    }

    fn special(self, kind: str, id: int) -> js.Val {
        let k2 = "${kind}:${id}"
        if let w = self.natives.get("obj:" + k2) { return w }
        let o = self.it.new_obj("Object")
        o.host = if id > 0 { id } else { -1 }
        o.host_kind = kind
        let w = js.object(o)
        self.natives["obj:" + k2] = w
        return w
    }

    fn fn_val(self, name: str) -> js.Val {
        if let f = self.natives.get(name) { return f }
        let f = self.it.native("dom." + name, 1)
        self.natives[name] = f
        return f
    }

    // ---- the tree, as the page sees it (anonymous wrapper blocks are invisible) ----

    fn kids_of(self, e: ui.El) -> [ui.El] {
        var out: [ui.El] = []
        for k in e.kids {
            if k.attr("data-anon") != "" { for x in self.kids_of(k) { out.push(x) } } else { out.push(k) }
        }
        return out
    }

    fn elements_of(self, e: ui.El) -> [ui.El] { return self.kids_of(e).filter(k => k.tag != "") }

    fn parent_of(self, e: ui.El) -> ui.El? {
        if e.uid != 0 && e.uid == self.root.uid { return none }
        var cur = e.parent
        while true {
            if let p = cur {
                if p.attr("data-anon") != "" {
                    cur = p.parent
                    continue
                }
                if p.has("data-slot") || p.attr("data-tag") == "" && p.tag == "body" && !self.inside(p) { return none }
                return some(p)
            }
            return none
        }
        return none
    }

    // is e part of this page?
    fn inside(self, e: ui.El) -> bool {
        var cur: ui.El? = some(e)
        while true {
            if let c = cur {
                if c.uid != 0 && c.uid == self.root.uid { return true }
                if c.path == self.root.path { return true }
                cur = c.parent
            } else {
                return false
            }
        }
        return false
    }

    fn sibling(self, e: ui.El, delta: int, elements_only: bool) -> ui.El? {
        if let p = self.parent_of(e) {
            let ks = if elements_only { self.elements_of(p) } else { self.kids_of(p) }
            for i, k in ks {
                if k.uid == e.uid && e.uid != 0 || k.path == e.path {
                    let j = i + delta
                    return if j >= 0 && j < ks.len() { some(ks[j]) } else { none }
                }
            }
        }
        return none
    }

    fn all_elements(self, e: ui.El, out: [ui.El]) {
        for k in self.kids_of(e) {
            if k.tag != "" {
                out.push(k)
                if out.len() < 50000 { self.all_elements(k, out) }
            }
        }
    }

    // querySelectorAll, under `scope`
    fn query(self, scope: ui.El, selector: str, first: bool) -> [ui.El] {
        var rules: [ui.Rule] = []
        for part in ui.split_top(selector) {
            if let r = ui.parse_selector(part.trim()) { rules.push(r) } else {
                self.it.throw_err("SyntaxError", "'${selector}' isn't a selector this browser understands")
                return []
            }
        }
        var all: [ui.El] = []
        self.all_elements(scope, all)
        var out: [ui.El] = []
        for e in all {
            for r in rules {
                if ui.matches_at(e, r, r.sels.len() - 1, true) {
                    out.push(e)
                    break
                }
            }
            if first && !out.is_empty() { return out }
        }
        return out
    }

    fn list(self, els: [ui.El]) -> js.Val {
        return self.it.array(els.map(e => self.wrap(e)))
    }

    // ---- changing the tree ----

    fn detach(self, e: ui.El) {
        if let p = e.parent {
            var i = 0
            while i < p.kids.len() {
                if p.kids[i].path == e.path && (p.kids[i].uid == e.uid) {
                    p.kids.remove(i)
                    break
                }
                i += 1
            }
        }
        e.parent = none
    }

    fn insert(self, parent: ui.El, child: ui.El, before: ui.El?) {
        // no cycles: a node can't go inside itself
        var cur: ui.El? = some(parent)
        while true {
            if let c = cur {
                if c.uid != 0 && c.uid == child.uid {
                    self.it.throw_err("HierarchyRequestError", "a node can't be put inside itself")
                    return
                }
                cur = c.parent
            } else {
                break
            }
        }
        // a fragment: its children
        if child.attr("data-tag") == "#fragment" {
            let ks = child.kids.slice(0, child.kids.len())
            for k in ks { self.insert(parent, k, before) }
            child.kids = []
            return
        }
        self.detach(child)
        if let b = before {
            if let bp = b.parent {
                var i = 0
                while i < bp.kids.len() {
                    if bp.kids[i].uid == b.uid && b.uid != 0 {
                        child.parent = some(bp)
                        bp.kids.insert(i, child)
                        self.touched()
                        return
                    }
                    i += 1
                }
            }
        }
        child.parent = some(parent)
        parent.kids.push(child)
        if parent.kids.len() > 50000 {
            self.it.throw_err("RangeError", "too many children")
            return
        }
        self.touched()
    }

    fn touched(self) {
        self.changed()
    }

    fn text_node(self, s: str) -> ui.El {
        return ui.El { tag: "", text: s }
    }

    fn make_element(self, tag: str) -> ui.El {
        let t = tag.lower()
        let d = html.Doc { root: ui.El { tag: "div" } }
        let e = html.make(t, {}, d)
        return e
    }

    fn text_of(self, e: ui.El) -> str {
        if e.tag == "" { return e.text }
        return e.kids.map(k => self.text_of(k)).join("")
    }

    fn set_text(self, e: ui.El, s: str) {
        for k in e.kids { k.parent = none }
        e.kids = []
        if s != "" {
            let t = self.text_node(s)
            t.parent = some(e)
            e.kids.push(t)
        }
        self.touched()
    }

    fn set_html(self, e: ui.El, markup: str) {
        let d = html.parse(markup)
        for k in e.kids { k.parent = none }
        e.kids = []
        for k in d.root.kids {
            k.parent = some(e)
            e.kids.push(k)
        }
        self.touched()
    }

    fn serialize(self, e: ui.El) -> str {
        if e.tag == "" { return escape(e.text) }
        if e.attr("data-anon") != "" { return e.kids.map(k => self.serialize(k)).join("") }
        let tag = tag_name(e).lower()
        var attrs: [str] = []
        for k in e.attrs.keys() {
            if html.reserved(k) || k == "data-tag" { continue }
            attrs.push(" ${k}=\"${escape(e.attrs.get(k) ?? "")}\"")
        }
        let inner = e.kids.map(k => self.serialize(k)).join("")
        if html.VOID.contains(tag) { return "<${tag}${attrs.join("")}>" }
        return "<${tag}${attrs.join("")}>${inner}</${tag}>"
    }

    fn set_attr(self, e: ui.El, name: str, value: str) {
        let n = name.lower()
        if html.reserved(n) {
            self.it.throw_err("SecurityError", "the attribute '${name}' is reserved")
            return
        }
        if n.starts_with("on") {
            e.attrs["js-" + n] = value
            return
        }
        if (n == "href" || n == "src" || n == "action") && value.trim().lower().starts_with("javascript:") { return }
        if n == "style" && (value.lower().contains("url(") || value.lower().contains("expression")) { return }
        e.attrs[n] = value
        self.touched()
    }

    // ---- events ----

    fn listen(self, id: int, kind: str, f: js.Val, once: bool) {
        if !self.it.is_fn(f) { return }
        if let l = self.listeners.get(id) {
            for x in l {
                if x.kind == kind && js.strict_eq(x.f, f) { return }
            }
            if l.len() < 500 { l.push(Listener { kind, f, once }) }
        } else {
            self.listeners[id] = [Listener { kind, f, once }]
        }
    }

    fn unlisten(self, id: int, kind: str, f: js.Val) {
        if let l = self.listeners.get(id) {
            self.listeners[id] = l.filter(x => !(x.kind == kind && js.strict_eq(x.f, f)))
        }
    }

    fn event(self, kind: str, target: js.Val, key: str) -> js.Val {
        let ev = self.it.plain()
        ev.props["type"] = js.string(kind)
        ev.props["target"] = target
        ev.props["srcElement"] = target
        ev.props["currentTarget"] = target
        ev.props["defaultPrevented"] = js.boolean(false)
        ev.props["bubbles"] = js.boolean(true)
        ev.props["cancelable"] = js.boolean(true)
        ev.props["isTrusted"] = js.boolean(true)
        ev.props["timeStamp"] = js.num(float(kernel.uptime()))
        if key != "" {
            ev.props["key"] = js.string(key)
            ev.props["code"] = js.string(if key.len() == 1 { "Key" + key.upper() } else { key })
            ev.props["keyCode"] = js.int_v(key_code(key))
            ev.props["which"] = js.int_v(key_code(key))
        }
        for m in ["preventDefault", "stopPropagation", "stopImmediatePropagation"] { ev.props[m] = self.fn_val("ev." + m) }
        ev.props["composedPath"] = self.fn_val("ev.composedPath")
        for k in ev.props.keys() { ev.hidden.add(k) }
        return js.object(ev)
    }

    // Send an event from `target` up to the document and window. Returns whether it was cancelled.
    fn dispatch(self, target: ui.El, kind: str, key: str) -> bool {
        if self.dead { return false }
        let tv = self.wrap(target)
        let ev = self.event(kind, tv, key)
        var chain: [js.Val] = []
        var cur: ui.El? = some(target)
        while true {
            if let c = cur {
                chain.push(self.wrap(c))
                cur = self.parent_of(c)
            } else {
                break
            }
        }
        chain.push(self.special("document", 0))
        chain.push(js.object(self.it.global))
        self.deliver(chain, ev, kind)
        return self.it.truthy(self.it.get(ev, "defaultPrevented"))
    }

    fn deliver(self, chain: [js.Val], ev: js.Val, kind: str) {
        for node in chain {
            let o = js.obj_of(node)
            let id = if o.id == self.it.global.id { -2 } else if o.host_kind == "document" { -1 } else { o.host }
            js.obj_of(ev).props["currentTarget"] = node
            // an inline handler (onclick="...") or a property (el.onclick = f)
            var handler = js.undef()
            if let p = o.props.get("on" + kind) { handler = p }
            if handler.t == js.UNDEFINED && id > 0 {
                if let e = self.nodes.get(id) {
                    let code = e.attr("js-on" + kind)
                    if code != "" { handler = self.compile_handler(e, kind, code) }
                }
            }
            if self.it.is_fn(handler) {
                let r = self.run(handler, node, [ev])
                if r.t == js.BOOL && r.n == 0.0 { js.obj_of(ev).props["defaultPrevented"] = js.boolean(true) }
            }
            if let l = self.listeners.get(id) {
                for x in l.slice(0, l.len()) {
                    if x.kind == kind {
                        if x.once { self.unlisten(id, kind, x.f) }
                        self.run(x.f, node, [ev])
                    }
                }
            }
            if self.it.truthy(self.it.get(ev, "__stop")) { break }
        }
    }

    fn compile_handler(self, e: ui.El, kind: str, code: str) -> js.Val {
        let cache_key = "handler:${e.uid}:${kind}:${code.len()}"
        if let f = self.natives.get(cache_key) { return f }
        let parsed = jsparse.parse("(function (event) {\n" + code + "\n})")
        if parsed.error != "" || parsed.body.is_empty() {
            self.report("SyntaxError in on${kind}: ${parsed.error}")
            return js.undef()
        }
        self.it.ctl = 0
        self.it.steps = 0
        self.it.budget = RUN_BUDGET
        let f = self.it.eval(parsed.body[0].kids[0], self.it.genv)
        self.it.ctl = 0
        self.natives[cache_key] = f
        return f
    }

    // ---- running code ----

    fn run(self, f: js.Val, this: js.Val, argv: [js.Val]) -> js.Val {
        if self.dead { return js.undef() }
        if self.used > PAGE_BUDGET {
            self.stop("the page's scripts used too much time and were stopped")
            return js.undef()
        }
        self.it.ctl = 0
        self.it.steps = 0
        self.it.budget = RUN_BUDGET
        self.it.depth = 0
        let r = self.it.call(f, this, argv)
        let problem = self.it.finish()
        self.used += self.it.steps
        if problem != "" { self.errors += 1 }
        return r
    }

    fn run_script(self, code: str, name: str) {
        if self.dead { return }
        let parsed = jsparse.parse(code)
        if parsed.error != "" {
            self.report("SyntaxError in ${name}: ${parsed.error}")
            self.errors += 1
            return
        }
        let problem = self.it.run_parsed(parsed.body, RUN_BUDGET)
        self.used += self.it.steps
        self.ran += 1
        if problem != "" { self.errors += 1 }
        if self.used > PAGE_BUDGET { self.stop("the page's scripts used too much time and were stopped") }
    }

    fn stop(self, why: str) {
        if self.dead { return }
        self.report(why)
        self.shutdown()
    }

    fn report(self, text: str) {
        self.last_error = text
        println("[page ${self.origin}] ${text.slice(0, min(text.len(), 300))}")
        self.log.push(text)
        if self.log.len() > 200 { self.log.remove(0) }
    }

    // the page is going away: no more timers or events
    fn shutdown(self) {
        self.dead = true
        for id in self.timers.keys() { kernel.cancel(self.timers.get(id) ?? -1) }
        self.timers = {}
    }

    fn timer(self, f: js.Val, ms: int, repeat: bool, argv: [js.Val]) -> int {
        if self.dead || self.timers.len() >= MAX_TIMERS { return 0 }
        let id = self.next_timer
        self.next_timer += 1
        let wait = max(ms, if repeat { 10 } else { 1 })
        let k = if repeat {
            kernel.every(wait, () => self.fire_timer(id, f, argv, true))
        } else {
            kernel.after(wait, () => self.fire_timer(id, f, argv, false))
        }
        self.timers[id] = k
        return id
    }

    fn fire_timer(self, id: int, f: js.Val, argv: [js.Val], repeat: bool) {
        if self.dead || !self.timers.contains(id) { return }
        if !repeat { self.timers.remove(id) }
        self.run(f, js.undef(), argv)
    }

    fn clear(self, id: int) {
        if let k = self.timers.get(id) {
            kernel.cancel(k)
            self.timers.remove(id)
        }
    }

    // ---- properties ----

    fn get(self, o: js.Obj, key: str) -> js.Val? {
        let it = self.it
        let kind = o.host_kind
        if kind == "document" { return self.doc_get(key) }
        if kind == "location" { return self.location_get(key) }
        if kind == "storage" { return self.storage_get(o, key) }
        if kind == "style" || kind == "classList" || kind == "dataset" {
            if let e = self.nodes.get(o.host) { return self.part_get(kind, e, key) }
            return none
        }
        if kind != "el" { return none }
        let e = self.nodes.get(o.host) ?? ui.El { tag: "" }
        let is_text = e.tag == ""
        if o.props.contains(key) { return none }
        if key == "nodeType" { return some(js.int_v(if is_text { 3 } else { 1 })) }
        if key == "nodeName" || key == "tagName" { return some(if is_text && key == "tagName" { js.undef() } else { js.string(if is_text { "#text" } else { tag_name(e) }) }) }
        if key == "localName" { return some(js.string(tag_name(e).lower())) }
        if key == "textContent" || key == "innerText" || key == "nodeValue" || key == "data" {
            if key == "nodeValue" && !is_text { return some(js.null_v()) }
            return some(js.string(self.text_of(e)))
        }
        if key == "parentNode" || key == "parentElement" {
            if let p = self.parent_of(e) { return some(self.wrap(p)) }
            if e.uid == self.root.uid && key == "parentNode" { return some(self.special("document", 0)) }
            return some(js.null_v())
        }
        if key == "isConnected" { return some(js.boolean(self.inside(e))) }
        if key == "ownerDocument" { return some(self.special("document", 0)) }
        if key == "childNodes" { return some(self.list(self.kids_of(e))) }
        if key == "children" { return some(self.list(self.elements_of(e))) }
        if key == "childElementCount" { return some(js.int_v(self.elements_of(e).len())) }
        if key == "firstChild" { return some(self.wrap_opt(self.kids_of(e).first())) }
        if key == "lastChild" { return some(self.wrap_opt(self.kids_of(e).last())) }
        if key == "firstElementChild" { return some(self.wrap_opt(self.elements_of(e).first())) }
        if key == "lastElementChild" { return some(self.wrap_opt(self.elements_of(e).last())) }
        if key == "nextSibling" { return some(self.wrap_opt(self.sibling(e, 1, false))) }
        if key == "previousSibling" { return some(self.wrap_opt(self.sibling(e, -1, false))) }
        if key == "nextElementSibling" { return some(self.wrap_opt(self.sibling(e, 1, true))) }
        if key == "previousElementSibling" { return some(self.wrap_opt(self.sibling(e, -1, true))) }
        if is_text { return if key == "length" { some(js.int_v(js.str_len(e.text))) } else { self.method(key) } }
        if key == "id" || key == "title" || key == "name" || key == "type" || key == "placeholder" || key == "alt" || key == "lang" || key == "rel" || key == "target" || key == "action" || key == "method" {
            return some(js.string(e.attr(key)))
        }
        if key == "className" { return some(js.string(e.attr("class"))) }
        if key == "href" || key == "src" { return some(js.string(e.attr(key))) }
        if key == "value" { return some(js.string(self.field_get(e))) }
        if key == "checked" || key == "disabled" || key == "hidden" || key == "selected" || key == "required" || key == "readOnly" {
            return some(js.boolean(e.has(key.lower()) || (key == "hidden" && e.attr("style").contains("display: none"))))
        }
        if key == "innerHTML" { return some(js.string(e.kids.map(k => self.serialize(k)).join(""))) }
        if key == "outerHTML" { return some(js.string(self.serialize(e))) }
        if key == "style" { return some(self.special("style", e.uid)) }
        if key == "classList" { return some(self.special("classList", e.uid)) }
        if key == "dataset" { return some(self.special("dataset", e.uid)) }
        if key == "offsetWidth" || key == "clientWidth" || key == "scrollWidth" { return some(js.int_v(e.w)) }
        if key == "offsetHeight" || key == "clientHeight" || key == "scrollHeight" { return some(js.int_v(if key == "scrollHeight" { max(e.inner_h, e.h) } else { e.h })) }
        if key == "offsetTop" { return some(js.int_v(e.y)) }
        if key == "offsetLeft" { return some(js.int_v(e.x)) }
        if key == "scrollTop" || key == "scrollLeft" { return some(js.int_v(0)) }
        if key == "offsetParent" { return some(self.wrap_opt(self.parent_of(e))) }
        if key == "options" { return some(self.list(self.query(e, "option", false))) }
        if key == "form" {
            var cur = self.parent_of(e)
            while true {
                if let c = cur {
                    if tag_name(c) == "FORM" { return some(self.wrap(c)) }
                    cur = self.parent_of(c)
                } else {
                    break
                }
            }
            return some(js.null_v())
        }
        if key == "elements" { return some(self.list(self.query(e, "input, textarea, select, button", false))) }
        if key.starts_with("on") && key.len() > 2 { return some(js.null_v()) }
        return self.method(key)
    }

    fn method(self, key: str) -> js.Val? {
        if ELEMENT_METHODS.contains(key) { return some(self.fn_val(key)) }
        return none
    }

    fn set(self, o: js.Obj, key: str, v: js.Val) -> bool {
        let it = self.it
        let kind = o.host_kind
        if kind == "document" {
            if key == "title" {
                self.title = it.to_str(v)
                self.retitle(self.title)
                return true
            }
            if key == "cookie" { return true }
            return false
        }
        if kind == "location" {
            if key == "href" || key == "hash" || key == "search" || key == "pathname" {
                if key == "hash" { return true }
                self.go(it.to_str(v))
                return true
            }
            return true
        }
        if kind == "storage" {
            self.storage_set(key, it.to_str(v))
            return true
        }
        if kind == "style" || kind == "dataset" {
            if let e = self.nodes.get(o.host) {
                if kind == "style" { self.style_set(e, key, it.to_str(v)) } else { self.set_attr(e, "data-" + kebab(key), it.to_str(v)) }
            }
            return true
        }
        if kind != "el" { return false }
        let e = self.nodes.get(o.host) ?? ui.El { tag: "" }
        if key == "textContent" || key == "innerText" || key == "nodeValue" || key == "data" {
            if e.tag == "" {
                e.text = it.to_str(v)
                self.touched()
            } else {
                self.set_text(e, if v.t == js.NULL || v.t == js.UNDEFINED { "" } else { it.to_str(v) })
            }
            return true
        }
        if key == "innerHTML" {
            self.set_html(e, it.to_str(v))
            return true
        }
        if key == "className" {
            self.set_attr(e, "class", it.to_str(v))
            return true
        }
        if key == "id" || key == "title" || key == "name" || key == "type" || key == "placeholder" || key == "alt" || key == "href" || key == "src" || key == "lang" || key == "action" || key == "method" || key == "target" {
            self.set_attr(e, key, it.to_str(v))
            return true
        }
        if key == "value" {
            self.field_set(e, it.to_str(v))
            self.touched()
            return true
        }
        if key == "checked" || key == "disabled" || key == "hidden" || key == "selected" || key == "required" {
            if key == "hidden" {
                let st = e.attr("style").replace("display: none;", "")
                if it.truthy(v) { e.attrs["style"] = st + "display: none;" } else { e.attrs["style"] = st }
            } else if it.truthy(v) {
                e.attrs[key] = ""
            } else {
                e.attrs.remove(key)
            }
            self.touched()
            return true
        }
        if key == "style" {
            self.set_attr(e, "style", it.to_str(v))
            return true
        }
        if key.starts_with("on") { return false }    // kept as a property: dispatch looks there
        return false
    }

    fn part_get(self, kind: str, e: ui.El, key: str) -> js.Val? {
        if kind == "classList" {
            let classes = e.attr("class").split(" ").filter(c => c != "")
            if key == "length" { return some(js.int_v(classes.len())) }
            if key == "value" { return some(js.string(e.attr("class"))) }
            let i = js.index_of_key(key)
            if i >= 0 { return some(if i < classes.len() { js.string(classes[i]) } else { js.undef() }) }
            if ["add", "remove", "toggle", "contains", "replace", "item", "forEach"].contains(key) { return some(self.fn_val("cl." + key)) }
            return none
        }
        if kind == "dataset" {
            let a = "data-" + kebab(key)
            if html.reserved(a) { return some(js.undef()) }
            if e.has(a) { return some(js.string(e.attr(a))) }
            return some(js.undef())
        }
        // style
        if key == "cssText" { return some(js.string(e.attr("style"))) }
        if ["setProperty", "removeProperty", "getPropertyValue"].contains(key) { return some(self.fn_val("st." + key)) }
        let prop = kebab(key)
        for d in ui.parse_decls(e.attr("style")) {
            if d.name == prop { return some(js.string(d.value)) }
        }
        return some(js.string(""))
    }

    fn style_set(self, e: ui.El, key: str, value: str) {
        if key == "cssText" {
            self.set_attr(e, "style", value)
            return
        }
        let prop = kebab(key)
        var parts: [str] = []
        for d in ui.parse_decls(e.attr("style")) {
            if d.name != prop { parts.push("${d.name}: ${d.value}") }
        }
        if value != "" { parts.push("${prop}: ${value}") }
        self.set_attr(e, "style", parts.join("; "))
    }

    // ---- document, location, storage ----

    fn doc_get(self, key: str) -> js.Val? {
        if key == "body" || key == "documentElement" || key == "scrollingElement" { return some(self.wrap(self.root)) }
        if key == "head" { return some(self.wrap(self.head())) }
        if key == "title" { return some(js.string(self.title)) }
        if key == "readyState" { return some(js.string("complete")) }
        if key == "cookie" || key == "referrer" { return some(js.string("")) }
        if key == "location" { return some(self.special("location", 0)) }
        if key == "defaultView" { return some(js.object(self.it.global)) }
        if key == "activeElement" { return some(self.wrap(self.root)) }
        if key == "hidden" { return some(js.boolean(false)) }
        if key == "visibilityState" { return some(js.string("visible")) }
        if key == "nodeType" { return some(js.int_v(9)) }
        if key == "URL" || key == "documentURI" { return some(js.string(self.url)) }
        if key == "characterSet" { return some(js.string("UTF-8")) }
        if key == "forms" { return some(self.list(self.query(self.root, "form", false))) }
        if key == "links" { return some(self.list(self.query(self.root, "a", false))) }
        if key == "images" { return some(self.list(self.query(self.root, "img", false))) }
        if DOC_METHODS.contains(key) { return some(self.fn_val("doc." + key)) }
        return none
    }

    fn head(self) -> ui.El {
        if let h = self.natives.get("head") {
            if let e = self.el_of(h) { return e }
        }
        let h = ui.El { tag: "div" }
        h.attrs["data-tag"] = "head"
        self.natives["head"] = self.wrap(h)
        return h
    }

    fn location_get(self, key: str) -> js.Val? {
        let u = self.url
        let scheme_end = u.find("://")
        let rest = if scheme_end >= 0 { u.slice(scheme_end + 3, u.len()) } else { u }
        let slash = rest.find("/")
        let host = if slash >= 0 { rest.slice(0, slash) } else { rest }
        var path = if slash >= 0 { rest.slice(slash, rest.len()) } else { "/" }
        var search = ""
        let q = path.find("?")
        if q >= 0 {
            search = path.slice(q, path.len())
            path = path.slice(0, q)
        }
        let protocol = if scheme_end >= 0 { u.slice(0, scheme_end) + ":" } else { "" }
        if key == "href" { return some(js.string(u)) }
        if key == "host" || key == "hostname" { return some(js.string(if key == "hostname" { host.split(":")[0] } else { host })) }
        if key == "pathname" { return some(js.string(path)) }
        if key == "search" { return some(js.string(search)) }
        if key == "hash" { return some(js.string("")) }
        if key == "protocol" { return some(js.string(protocol)) }
        if key == "origin" { return some(js.string(self.origin)) }
        if key == "port" { return some(js.string(if host.contains(":") { host.split(":")[1] } else { "" })) }
        if key == "reload" || key == "assign" || key == "replace" || key == "toString" { return some(self.fn_val("loc." + key)) }
        return none
    }

    fn go(self, url: str) {
        self.navigations += 1
        if self.navigations > 3 {
            self.report("the page tried to navigate too often; stopped")
            return
        }
        self.navigate(url)
    }

    fn storage_get(self, o: js.Obj, key: str) -> js.Val? {
        if key == "getItem" || key == "setItem" || key == "removeItem" || key == "clear" || key == "key" { return some(self.fn_val("ls." + key)) }
        if key == "length" { return some(js.int_v(self.storage.len())) }
        if let v = self.storage.get(key) { return some(js.string(v)) }
        return none
    }

    fn storage_set(self, key: str, value: str) {
        var total = 0
        for k in self.storage.keys() { total += k.len() + (self.storage.get(k) ?? "").len() }
        if total + key.len() + value.len() > 1 << 20 {
            self.it.throw_err("QuotaExceededError", "storage is full (1 MiB per site)")
            return
        }
        self.storage[key] = value
    }

    // ---- the native functions ----

    fn call(self, name: str, this: js.Val, a: [js.Val]) -> js.Val {
        let it = self.it
        let m = name.slice(4, name.len())      // without "dom."
        let x = jsstd.arg(a, 0)
        if m.starts_with("ev.") {
            if let ev = this.o {
                if m == "ev.preventDefault" { ev.props["defaultPrevented"] = js.boolean(true) }
                if m == "ev.stopPropagation" || m == "ev.stopImmediatePropagation" { ev.props["__stop"] = js.boolean(true) }
                if m == "ev.composedPath" { return it.array([]) }
            }
            return js.undef()
        }
        if m.starts_with("ls.") {
            if m == "ls.getItem" {
                if let v = self.storage.get(it.to_str(x)) { return js.string(v) }
                return js.null_v()
            }
            if m == "ls.setItem" { self.storage_set(it.to_str(x), it.to_str(jsstd.arg(a, 1))) }
            if m == "ls.removeItem" { self.storage.remove(it.to_str(x)) }
            if m == "ls.clear" { self.storage = {} }
            if m == "ls.key" {
                let ks = self.storage.keys()
                let i = int(it.to_num(x))
                return if i >= 0 && i < ks.len() { js.string(ks[i]) } else { js.null_v() }
            }
            return js.undef()
        }
        if m.starts_with("loc.") {
            if m == "loc.toString" { return js.string(self.url) }
            self.go(if m == "loc.reload" { self.url } else { it.to_str(x) })
            return js.undef()
        }
        if m.starts_with("win.") { return self.window_call(m.slice(4, m.len()), a) }
        if m.starts_with("doc.") { return self.doc_call(m.slice(4, m.len()), a) }
        let o = this.o ?? js.Obj { id: 0 }
        let e = self.nodes.get(o.host) ?? ui.El { tag: "" }
        if m.starts_with("cl.") {
            var classes = e.attr("class").split(" ").filter(c => c != "")
            let c = it.to_str(x)
            if m == "cl.contains" { return js.boolean(classes.contains(c)) }
            if m == "cl.item" {
                let i = int(it.to_num(x))
                return if i >= 0 && i < classes.len() { js.string(classes[i]) } else { js.null_v() }
            }
            if m == "cl.forEach" {
                for i, k in classes { it.call(x, js.undef(), [js.string(k), js.int_v(i)]) }
                return js.undef()
            }
            var result = true
            if m == "cl.add" {
                for v in a {
                    let s = it.to_str(v)
                    if !classes.contains(s) { classes.push(s) }
                }
            } else if m == "cl.remove" {
                for v in a {
                    let s = it.to_str(v)
                    classes = classes.filter(k => k != s)
                }
            } else if m == "cl.toggle" {
                let force = jsstd.arg(a, 1)
                let want = if force.t == js.UNDEFINED { !classes.contains(c) } else { it.truthy(force) }
                classes = classes.filter(k => k != c)
                if want { classes.push(c) }
                result = want
            } else if m == "cl.replace" {
                let to = it.to_str(jsstd.arg(a, 1))
                result = classes.contains(c)
                classes = classes.map(k => if k == c { to } else { k })
            }
            self.set_attr(e, "class", classes.join(" "))
            return js.boolean(result)
        }
        if m.starts_with("st.") {
            if m == "st.setProperty" { self.style_set(e, it.to_str(x), it.to_str(jsstd.arg(a, 1))) }
            if m == "st.removeProperty" { self.style_set(e, it.to_str(x), "") }
            if m == "st.getPropertyValue" { return (self.part_get("style", e, it.to_str(x)) ?? js.string("")) }
            return js.undef()
        }
        // element methods
        if m == "addEventListener" || m == "removeEventListener" {
            let id = if o.id == it.global.id { -2 } else if o.host_kind == "document" { -1 } else { o.host }
            var once = false
            if let opts = jsstd.arg(a, 2).o { once = it.truthy(it.get(jsstd.arg(a, 2), "once")) }
            if m == "addEventListener" { self.listen(id, it.to_str(x), jsstd.arg(a, 1), once) } else { self.unlisten(id, it.to_str(x), jsstd.arg(a, 1)) }
            return js.undef()
        }
        if m == "dispatchEvent" {
            let kind = it.to_str(it.get(x, "type"))
            if o.host_kind == "el" {
                var chain: [js.Val] = []
                var cur: ui.El? = some(e)
                while true {
                    if let c = cur {
                        chain.push(self.wrap(c))
                        cur = self.parent_of(c)
                    } else {
                        break
                    }
                }
                chain.push(self.special("document", 0))
                chain.push(js.object(it.global))
                it.set(x, "target", this)
                self.deliver(chain, x, kind)
            } else {
                self.deliver([this], x, kind)
            }
            return js.boolean(!it.truthy(it.get(x, "defaultPrevented")))
        }
        if o.host_kind == "document" { return self.doc_call(m, a) }
        if m == "getAttribute" {
            let k = it.to_str(x).lower()
            if html.reserved(k) && !k.starts_with("js-") { return js.null_v() }
            if k.starts_with("on") { if e.has("js-" + k) { return js.string(e.attr("js-" + k)) } }
            if k == "class" || e.has(k) { return if e.has(k) { js.string(e.attr(k)) } else { js.null_v() } }
            return js.null_v()
        }
        if m == "setAttribute" {
            self.set_attr(e, it.to_str(x), it.to_str(jsstd.arg(a, 1)))
            return js.undef()
        }
        if m == "removeAttribute" {
            let k = it.to_str(x).lower()
            if !html.reserved(k) {
                e.attrs.remove(k)
                self.touched()
            }
            return js.undef()
        }
        if m == "hasAttribute" { return js.boolean(e.has(it.to_str(x).lower())) }
        if m == "toggleAttribute" {
            let k = it.to_str(x).lower()
            if e.has(k) { e.attrs.remove(k) } else { self.set_attr(e, k, "") }
            self.touched()
            return js.boolean(e.has(k))
        }
        if m == "appendChild" || m == "append" || m == "prepend" {
            var first = true
            for v in a {
                let child = if v.t == js.OBJ { self.el_of(v) ?? self.text_node("") } else { self.text_node(it.to_str(v)) }
                if m == "prepend" {
                    let ks = self.kids_of(e)
                    self.insert(e, child, if ks.is_empty() { none } else { some(ks[0]) })
                } else {
                    self.insert(e, child, none)
                }
                if it.ctl != 0 { return js.undef() }
                if m == "appendChild" { return v }
            }
            return js.undef()
        }
        if m == "insertBefore" {
            if let child = self.el_of(x) {
                self.insert(e, child, self.el_of(jsstd.arg(a, 1)))
            }
            return x
        }
        if m == "removeChild" {
            if let child = self.el_of(x) {
                self.detach(child)
                self.touched()
            }
            return x
        }
        if m == "replaceChild" {
            if let old = self.el_of(jsstd.arg(a, 1)) {
                if let nw = self.el_of(x) {
                    self.insert(e, nw, some(old))
                    self.detach(old)
                    self.touched()
                }
            }
            return jsstd.arg(a, 1)
        }
        if m == "remove" {
            self.detach(e)
            self.touched()
            return js.undef()
        }
        if m == "replaceWith" || m == "before" || m == "after" {
            if let p = e.parent {
                for v in a {
                    let child = if v.t == js.OBJ { self.el_of(v) ?? self.text_node("") } else { self.text_node(it.to_str(v)) }
                    if m == "after" {
                        let next = self.sibling(e, 1, false)
                        self.insert(p, child, next)
                    } else {
                        self.insert(p, child, some(e))
                    }
                }
                if m == "replaceWith" {
                    self.detach(e)
                    self.touched()
                }
            }
            return js.undef()
        }
        if m == "insertAdjacentHTML" || m == "insertAdjacentText" || m == "insertAdjacentElement" {
            let pos = it.to_str(x).lower()
            var nodes: [ui.El] = []
            if m == "insertAdjacentHTML" {
                for k in html.parse(it.to_str(jsstd.arg(a, 1))).root.kids { nodes.push(k) }
            } else if m == "insertAdjacentText" {
                nodes.push(self.text_node(it.to_str(jsstd.arg(a, 1))))
            } else if let n = self.el_of(jsstd.arg(a, 1)) {
                nodes.push(n)
            }
            for n in nodes {
                if pos == "beforeend" {
                    self.insert(e, n, none)
                } else if pos == "afterbegin" {
                    let ks = self.kids_of(e)
                    self.insert(e, n, if ks.is_empty() { none } else { some(ks[0]) })
                } else if let p = e.parent {
                    if pos == "beforebegin" { self.insert(p, n, some(e)) } else { self.insert(p, n, self.sibling(e, 1, false)) }
                }
            }
            return js.undef()
        }
        if m == "cloneNode" { return self.wrap(clone(e, it.truthy(x))) }
        if m == "contains" {
            if let other = self.el_of(x) {
                var cur: ui.El? = some(other)
                while true {
                    if let c = cur {
                        if c.uid == e.uid && e.uid != 0 { return js.boolean(true) }
                        cur = c.parent
                    } else {
                        break
                    }
                }
            }
            return js.boolean(false)
        }
        if m == "matches" || m == "closest" {
            var rules: [ui.Rule] = []
            for part in ui.split_top(it.to_str(x)) {
                if let r = ui.parse_selector(part.trim()) { rules.push(r) }
            }
            var cur: ui.El? = some(e)
            while true {
                if let c = cur {
                    for r in rules {
                        if c.tag != "" && ui.matches_at(c, r, r.sels.len() - 1, true) { return if m == "matches" { js.boolean(true) } else { self.wrap(c) } }
                    }
                    if m == "matches" { return js.boolean(false) }
                    cur = self.parent_of(c)
                } else {
                    break
                }
            }
            return if m == "matches" { js.boolean(false) } else { js.null_v() }
        }
        if m == "querySelector" {
            let r = self.query(e, it.to_str(x), true)
            return if r.is_empty() { js.null_v() } else { self.wrap(r[0]) }
        }
        if m == "querySelectorAll" { return self.list(self.query(e, it.to_str(x), false)) }
        if m == "getElementsByTagName" {
            let t = it.to_str(x)
            return self.list(if t == "*" { self.query(e, "*", false) } else { self.query(e, t.lower(), false) })
        }
        if m == "getElementsByClassName" { return self.list(self.query(e, it.to_str(x).split(" ").filter(c => c != "").map(c => "." + c).join(""), false)) }
        if m == "click" {
            self.dispatch(e, "click", "")
            return js.undef()
        }
        if m == "focus" || m == "blur" || m == "scrollIntoView" || m == "scrollTo" || m == "scrollBy" || m == "select" || m == "normalize" { return js.undef() }
        if m == "getBoundingClientRect" {
            let r = it.plain()
            r.props["x"] = js.int_v(e.x)
            r.props["y"] = js.int_v(e.y)
            r.props["left"] = js.int_v(e.x)
            r.props["top"] = js.int_v(e.y)
            r.props["width"] = js.int_v(e.w)
            r.props["height"] = js.int_v(e.h)
            r.props["right"] = js.int_v(e.x + e.w)
            r.props["bottom"] = js.int_v(e.y + e.h)
            return js.object(r)
        }
        if m == "hasChildNodes" { return js.boolean(!e.kids.is_empty()) }
        if m == "getRootNode" { return self.special("document", 0) }
        if m == "submit" || m == "requestSubmit" {
            self.dispatch(e, "submit", "")
            return js.undef()
        }
        if m == "reset" { return js.undef() }
        return it.throw_err("TypeError", "${m} isn't supported on elements here")
    }

    fn doc_call(self, m: str, a: [js.Val]) -> js.Val {
        let it = self.it
        let x = jsstd.arg(a, 0)
        if m == "getElementById" {
            let id = it.to_str(x)
            var all: [ui.El] = []
            self.all_elements(self.root, all)
            for e in all {
                if e.attr("id") == id { return self.wrap(e) }
            }
            return js.null_v()
        }
        if m == "createElement" {
            let t = it.to_str(x).lower()
            if t == "" || t.len() > 40 { return it.throw_err("InvalidCharacterError", "invalid tag name") }
            return self.wrap(self.make_element(t))
        }
        if m == "createTextNode" { return self.wrap(self.text_node(it.to_str(x))) }
        if m == "createComment" { return self.wrap(self.text_node("")) }
        if m == "createDocumentFragment" {
            let f = ui.El { tag: "div" }
            f.attrs["data-tag"] = "#fragment"
            return self.wrap(f)
        }
        if m == "createEvent" { return self.event("", js.null_v(), "") }
        if m == "write" || m == "writeln" || m == "open" || m == "close" {
            if m.starts_with("write") {
                // appended at the end of the page (not where the script was)
                for k in html.parse(a.map(v => it.to_str(v)).join("")).root.kids { self.insert(self.root, k, none) }
            }
            return js.undef()
        }
        if m == "hasFocus" { return js.boolean(true) }
        if m == "getElementsByName" { return self.list(self.query(self.root, "[name=\"${it.to_str(x)}\"]", false)) }
        // the rest are element methods on the whole page
        return self.call("dom." + m, self.wrap(self.root), a)
    }

    fn window_call(self, m: str, a: [js.Val]) -> js.Val {
        let it = self.it
        let x = jsstd.arg(a, 0)
        if m == "alert" {
            self.notice("the page says: " + it.to_str(x))
            return js.undef()
        }
        if m == "confirm" {
            self.notice("the page asked: " + it.to_str(x) + " (answered no)")
            return js.boolean(false)
        }
        if m == "prompt" { return js.null_v() }
        if m == "fetch" { return it.promise_rejected(it.error("TypeError", "network access from scripts isn't allowed in this browser")) }
        if m == "XMLHttpRequest" || m == "WebSocket" || m == "EventSource" || m == "Worker" {
            return it.throw_err("SecurityError", "${m} isn't allowed in this browser (scripts get no network access)")
        }
        if m == "open" { return js.null_v() }
        if m == "getComputedStyle" {
            if let e = self.el_of(x) { return self.special("style", self.uid(e)) }
            return js.object(it.plain())
        }
        if m == "matchMedia" {
            let q = it.plain()
            q.props["matches"] = js.boolean(false)
            q.props["media"] = js.string(it.to_str(x))
            for f in ["addListener", "removeListener", "addEventListener", "removeEventListener"] { q.props[f] = self.fn_val("win.noop") }
            return js.object(q)
        }
        if m == "atob" || m == "btoa" {
            let s = it.to_str(x)
            if m == "btoa" {
                let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".chars()
                var out: [str] = []
                let b = s.chars().map(c => st_ord(c) & 255)
                var i = 0
                while i < b.len() {
                    let n = (b[i] << 16) | ((if i + 1 < b.len() { b[i + 1] } else { 0 }) << 8) | (if i + 2 < b.len() { b[i + 2] } else { 0 })
                    out.push(alphabet[(n >> 18) & 63])
                    out.push(alphabet[(n >> 12) & 63])
                    out.push(if i + 1 < b.len() { alphabet[(n >> 6) & 63] } else { "=" })
                    out.push(if i + 2 < b.len() { alphabet[n & 63] } else { "=" })
                    i += 3
                }
                return js.string(out.join(""))
            }
            let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
            var acc = 0
            var bits = 0
            var out: [str] = []
            for ch in s.chars() {
                if ch == "=" { break }
                let v = alphabet.find(ch)
                if v < 0 { continue }
                acc = (acc << 6) | v
                bits += 6
                if bits >= 8 {
                    bits -= 8
                    out.push(st_chr((acc >> bits) & 255))
                }
                acc = acc & 0xffff
            }
            return js.string(out.join(""))
        }
        if m == "Image" { return self.wrap(self.make_element("img")) }
        if m == "Event" || m == "CustomEvent" {
            let ev = self.event(it.to_str(x), js.null_v(), "")
            let init = jsstd.arg(a, 1)
            if init.t == js.OBJ { js.obj_of(ev).props["detail"] = it.get(init, "detail") }
            return ev
        }
        if m == "now" { return js.num(float(kernel.uptime())) }
        if m == "empty_list" { return it.array([]) }
        return js.undef()
    }
}

extern fn st_ord(s: str) -> int
extern fn st_chr(code: int) -> str

const ELEMENT_METHODS = ["addEventListener", "removeEventListener", "dispatchEvent", "getAttribute", "setAttribute", "removeAttribute",
    "hasAttribute", "toggleAttribute", "appendChild", "append", "prepend", "insertBefore", "removeChild", "replaceChild", "remove",
    "replaceWith", "before", "after", "insertAdjacentHTML", "insertAdjacentText", "insertAdjacentElement", "cloneNode", "contains",
    "matches", "closest", "querySelector", "querySelectorAll", "getElementsByTagName", "getElementsByClassName", "click", "focus",
    "blur", "scrollIntoView", "scrollTo", "scrollBy", "select", "getBoundingClientRect", "hasChildNodes", "getRootNode", "submit",
    "requestSubmit", "reset", "normalize"]

const DOC_METHODS = ["getElementById", "querySelector", "querySelectorAll", "getElementsByTagName", "getElementsByClassName",
    "getElementsByName", "createElement", "createTextNode", "createComment", "createDocumentFragment", "createEvent", "addEventListener",
    "removeEventListener", "dispatchEvent", "write", "writeln", "open", "close", "hasFocus"]

fn tag_name(e: ui.El) -> str {
    let t = e.attr("data-tag")
    return (if t != "" { t } else { e.tag }).upper()
}

fn kebab(name: str) -> str {
    var out: [str] = []
    for c in name.chars() {
        if c != c.lower() {
            out.push("-")
            out.push(c.lower())
        } else {
            out.push(c)
        }
    }
    return out.join("")
}

fn escape(s: str) -> str {
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
}

fn key_code(k: str) -> int {
    if k == "Enter" { return 13 }
    if k == "Escape" { return 27 }
    if k == "Backspace" { return 8 }
    if k == "Tab" { return 9 }
    if k == " " { return 32 }
    if k == "ArrowLeft" { return 37 }
    if k == "ArrowUp" { return 38 }
    if k == "ArrowRight" { return 39 }
    if k == "ArrowDown" { return 40 }
    if k == "Delete" { return 46 }
    if k.len() == 1 { return st_ord(k.upper()) }
    return 0
}

fn clone(e: ui.El, deep: bool) -> ui.El {
    let c = ui.El { tag: e.tag, text: e.text }
    for k in e.attrs.keys() { c.attrs[k] = e.attrs.get(k) ?? "" }
    if deep {
        for k in e.kids {
            let kc = clone(k, true)
            kc.parent = some(c)
            c.kids.push(kc)
        }
    }
    return c
}

// A page's script world: an interpreter with a window, a document and this page's tree.
fn open(root: ui.El, url: str, title: str, storage: {str: str}, seed: int) -> Dom {
    var it_ref: [js.Interp] = []
    var dom_ref: [Dom] = []
    let host = js.Host {
        get: (o: js.Obj, k: str) => dom_ref[0].get(o, k),
        set: (o: js.Obj, k: str, v: js.Val) => dom_ref[0].set(o, k, v),
        call: (name: str, t: js.Val, a: [js.Val]) => dom_ref[0].call(name, t, a),
        timer: (f: js.Val, ms: int, repeat: bool, a: [js.Val]) => dom_ref[0].timer(f, ms, repeat, a),
        clear: (id: int) => dom_ref[0].clear(id),
        log: (level: str, text: str) => {
            let d = dom_ref[0]
            d.log.push((if level == "log" { "" } else { level + ": " }) + text)
            if d.log.len() > 200 { d.log.remove(0) }
            if level == "error" {
                d.last_error = text
                println("[page ${d.origin}] ${text.slice(0, min(text.len(), 300))}")
            }
        },
    }
    let it = jsstd.setup(host)
    it.rand = seed | 1
    let scheme_end = url.find("://")
    var origin = url
    if scheme_end >= 0 {
        let rest = url.slice(scheme_end + 3, url.len())
        let slash = rest.find("/")
        origin = url.slice(0, scheme_end + 3) + (if slash >= 0 { rest.slice(0, slash) } else { rest })
    }
    let d = Dom { it, root, url, origin, storage }
    d.title = title
    dom_ref.push(d)
    d.uid(root)
    let g = it.global
    g.props["document"] = d.special("document", 0)
    g.props["location"] = d.special("location", 0)
    g.props["localStorage"] = d.special("storage", 0)
    g.props["sessionStorage"] = d.special("storage", 0)
    for m in ["alert", "confirm", "prompt", "fetch", "XMLHttpRequest", "WebSocket", "EventSource", "Worker", "open", "getComputedStyle",
        "matchMedia", "atob", "btoa", "Image", "Event", "CustomEvent", "noop"] {
        g.props[m] = it.native("dom.win." + m, 1)
        g.hidden.add(m)
    }
    g.props["addEventListener"] = it.native("dom.addEventListener", 2)
    g.props["removeEventListener"] = it.native("dom.removeEventListener", 2)
    g.props["dispatchEvent"] = it.native("dom.dispatchEvent", 1)
    for m in ["scrollTo", "scrollBy", "scroll", "focus", "blur", "print", "postMessage"] { g.props[m] = it.native("dom.win.noop", 0) }
    let nav = it.plain()
    nav.props["userAgent"] = js.string("Mozilla/5.0 (StellaOS; riscv64) StellaBrowser/0.3")
    nav.props["language"] = js.string("en")
    nav.props["languages"] = it.array([js.string("en")])
    nav.props["onLine"] = js.boolean(true)
    nav.props["cookieEnabled"] = js.boolean(false)
    nav.props["platform"] = js.string("StellaOS")
    g.props["navigator"] = js.object(nav)
    let history = it.plain()
    for m in ["pushState", "replaceState", "back", "forward", "go"] { history.props[m] = it.native("dom.win.noop", 0) }
    history.props["length"] = js.int_v(1)
    g.props["history"] = js.object(history)
    let perf = it.plain()
    perf.props["now"] = it.native("dom.win.now", 0)
    let timing = it.plain()
    let t0 = js.num(float(kernel.time_ms()))
    for k in ["navigationStart", "fetchStart", "domLoading", "domInteractive", "domContentLoadedEventStart", "loadEventStart", "responseStart", "responseEnd", "requestStart"] { timing.props[k] = t0 }
    perf.props["timing"] = js.object(timing)
    perf.props["getEntriesByType"] = it.native("dom.win.empty_list", 1)
    perf.props["getEntriesByName"] = it.native("dom.win.empty_list", 1)
    perf.props["mark"] = it.native("dom.win.noop", 1)
    perf.props["measure"] = it.native("dom.win.noop", 1)
    g.props["performance"] = js.object(perf)
    g.props["innerWidth"] = js.int_v(700)
    g.props["innerHeight"] = js.int_v(440)
    g.props["devicePixelRatio"] = js.int_v(1)
    g.props["scrollX"] = js.int_v(0)
    g.props["scrollY"] = js.int_v(0)
    g.props["pageYOffset"] = js.int_v(0)
    let screen = it.plain()
    screen.props["width"] = js.int_v(1024)
    screen.props["height"] = js.int_v(768)
    g.props["screen"] = js.object(screen)
    for k in ["document", "location", "localStorage", "sessionStorage", "navigator", "history", "performance", "innerWidth", "innerHeight",
        "devicePixelRatio", "scrollX", "scrollY", "pageYOffset", "screen", "addEventListener", "removeEventListener", "dispatchEvent",
        "scrollTo", "scrollBy", "scroll", "focus", "blur", "print", "postMessage"] {
        g.hidden.add(k)
    }
    return d
}
