// StellaOS's JavaScript engine: a tree-walking interpreter for what jsparse.st reads, with the
// standard library pages use (Object, Array, String, Number, Math, JSON, RegExp, Date, Map, Set,
// Promise, errors, timers through the host).
//
// It runs page scripts, so it's a sandbox first:
// - scripts see only what the host (jsdom.st) hands them: the page's DOM, timers, console. No network,
//   no files, no other pages, nothing of the OS
// - every evaluation step is counted: a script that runs too long is stopped (`budget`), and so is
//   one that recurses too deep (a RangeError, like browsers) or builds strings past 8 MiB
// - it's memory-safe by construction: it's stellang, with bounds-checked lists and a GC

import kernel
import jsparse
import jsre

const UNDEFINED = 0
const NULL = 1
const BOOL = 2
const NUM = 3
const STR = 4
const OBJ = 5

const MAX_DEPTH = 150
const MAX_STRING = 8 << 20

struct Val {
    t: int,
    n: float = 0.0,
    s: str = "",
    o: Obj? = none,
}

fn undef() -> Val { return Val { t: UNDEFINED } }
fn null_v() -> Val { return Val { t: NULL } }
fn boolean(b: bool) -> Val { return Val { t: BOOL, n: if b { 1.0 } else { 0.0 } } }
fn num(n: float) -> Val { return Val { t: NUM, n } }
fn int_v(n: int) -> Val { return Val { t: NUM, n: float(n) } }
fn string(s: str) -> Val { return Val { t: STR, s } }
fn object(o: Obj) -> Val { return Val { t: OBJ, o: some(o) } }

struct Obj {
    id: int,
    cls: str = "Object",      // Object, Array, Function, Error, RegExp, Date, Map, Set, Promise, Arguments, ...
    props: {str: Val} = {},
    hidden: {str} = {},       // keys that for-in and Object.keys skip (methods on prototypes, ...)
    getters: {str: Val} = {},
    setters: {str: Val} = {},
    proto: Obj? = none,
    arr: [Val] = [],          // an array's elements
    frozen: bool = false,
    // functions
    fnode: jsparse.Ast? = none,
    scope: Env? = none,
    this_val: Val? = none,    // arrows keep their `this`; bound functions theirs
    bound: Val? = none,       // bind(): the target
    bound_args: [Val] = [],
    native: str = "",         // a built-in, by name
    home: Obj? = none,        // where `super` looks (a method's object)
    parent: Val? = none,      // a class's superclass
    fields: [jsparse.Ast] = [],   // a class's instance fields
    is_class: bool = false,
    // other built-ins
    prim: Val? = none,        // Date's time, a boxed primitive, a RegExp's source
    flags: str = "",          // RegExp flags
    last_index: int = 0,
    map: {str: Val} = {},     // Map and Set: encoded key -> value
    mkeys: {str: Val} = {},   // encoded key -> the key itself
    state: str = "",          // Promise: pending, fulfilled, rejected
    reactions: [Val] = [],    // Promise: [onFulfilled, onRejected, child promise] triples, flattened
    host: int = 0,            // a DOM node (jsdom.st)
    host_kind: str = "",

    fn callable(self) -> bool { return self.cls == "Function" }
}

struct Env {
    vars: {str: Val} = {},
    consts: {str} = {},
    parent: Env? = none,
    obj: Obj? = none,         // the global scope keeps its variables on the global object
    has_this: bool = false,
    this_val: Val = Val { t: 0 },
    func: Obj? = none,        // the function this scope belongs to (for super)
}

// what the page offers scripts (jsdom.st fills these in)
struct Host {
    get: fn(Obj, str) -> Val? = (o: Obj, k: str) => none,
    set: fn(Obj, str, Val) -> bool = (o: Obj, k: str, v: Val) => false,
    call: fn(str, Val, [Val]) -> Val = (name: str, t: Val, a: [Val]) => Val { t: 0 },
    timer: fn(Val, int, bool, [Val]) -> int = (f: Val, ms: int, repeat: bool, a: [Val]) => 0,
    clear: fn(int) = (id: int) => {},
    log: fn(str, str) = (level: str, text: str) => println(text),
}

struct Job {
    f: Val,
    argv: [Val],
}

struct Interp {
    global: Obj,
    genv: Env,
    protos: {str: Obj} = {},
    ctl: int = 0,             // 0 normal, 1 return, 2 break, 3 continue, 4 throw, 5 stopped
    cval: Val = Val { t: 0 },
    clabel: str = "",
    pending_label: str = "",
    steps: int = 0,
    budget: int = 0,          // steps allowed before stopping (0: none)
    depth: int = 0,
    next_id: int = 1,
    short: bool = false,      // an optional chain hit null/undefined
    host: Host = Host {},
    jobs: [Job] = [],         // microtasks (promise reactions)
    rand: int = 88172645463325252,
    stopped: str = "",
    // the built-ins (jsstd.st): called by name
    natives: fn(Obj, Val, [Val], bool) -> Val = (f: Obj, t: Val, a: [Val], n: bool) => Val { t: 0 },

    fn call_native(self, f: Obj, this: Val, argv: [Val], is_new: bool) -> Val {
        if self.depth >= MAX_DEPTH { return self.throw_err("RangeError", "maximum call stack size exceeded") }
        self.depth += 1
        let r = self.natives(f, this, argv, is_new)
        self.depth -= 1
        return r
    }

    // ---- objects ----

    fn new_obj(self, proto: str) -> Obj {
        let o = Obj { id: self.next_id }
        self.next_id += 1
        if proto != "" { o.proto = self.protos.get(proto) }
        return o
    }

    fn plain(self) -> Obj { return self.new_obj("Object") }

    fn array(self, items: [Val]) -> Val {
        let a = self.new_obj("Array")
        a.cls = "Array"
        a.arr = items
        return object(a)
    }

    fn native(self, name: str, length: int) -> Val {
        let f = self.new_obj("Function")
        f.cls = "Function"
        f.native = name
        let short = if name.contains(".") { name.slice(name.find(".") + 1, name.len()) } else { name }
        f.props["name"] = string(short)
        f.props["length"] = int_v(length)
        f.hidden.add("name")
        f.hidden.add("length")
        return object(f)
    }

    fn method(self, o: Obj, name: str, native: str, length: int) {
        o.props[name] = self.native(native, length)
        o.hidden.add(name)
    }

    // ---- errors ----

    fn error(self, kind: str, msg: str) -> Val {
        let e = self.new_obj(kind)
        e.cls = "Error"
        e.props["message"] = string(msg)
        e.hidden.add("message")
        e.props["stack"] = string("${kind}: ${msg}")
        e.hidden.add("stack")
        return object(e)
    }

    fn throw_val(self, v: Val) -> Val {
        if self.ctl != 5 {
            self.ctl = 4
            self.cval = v
        }
        return undef()
    }

    fn throw_err(self, kind: str, msg: str) -> Val {
        return self.throw_val(self.error(kind, msg))
    }

    fn step(self) -> bool {
        self.steps += 1
        if self.budget > 0 && self.steps > self.budget {
            if self.ctl != 5 {
                self.ctl = 5
                self.stopped = "the script ran too long and was stopped"
            }
            return false
        }
        return self.ctl != 5
    }

    // ---- conversions ----

    fn truthy(self, v: Val) -> bool {
        if v.t == UNDEFINED || v.t == NULL { return false }
        if v.t == BOOL { return v.n != 0.0 }
        if v.t == NUM { return v.n != 0.0 && v.n == v.n }
        if v.t == STR { return v.s != "" }
        return true
    }

    fn to_num(self, v: Val) -> float {
        if v.t == NUM || v.t == BOOL { return v.n }
        if v.t == UNDEFINED { return nan() }
        if v.t == NULL { return 0.0 }
        if v.t == STR { return str_to_num(v.s) }
        let p = self.to_prim(v, "number")
        if p.t == OBJ || self.ctl != 0 { return nan() }
        return self.to_num(p)
    }

    fn to_str(self, v: Val) -> str {
        if v.t == STR { return v.s }
        if v.t == NUM { return jsparse.num_text(v.n) }
        if v.t == BOOL { return if v.n != 0.0 { "true" } else { "false" } }
        if v.t == UNDEFINED { return "undefined" }
        if v.t == NULL { return "null" }
        let p = self.to_prim(v, "string")
        if p.t == OBJ || self.ctl != 0 { return "" }
        return self.to_str(p)
    }

    // an object as a primitive: valueOf/toString, as the hint asks
    fn to_prim(self, v: Val, hint: str) -> Val {
        if v.t != OBJ { return v }
        let o = obj_of(v)
        if o.cls == "Date" && hint != "number" {
            let s = self.get(v, "toString")
            if self.is_fn(s) { return self.call(s, v, []) }
        }
        let order = if hint == "string" { ["toString", "valueOf"] } else { ["valueOf", "toString"] }
        for name in order {
            let f = self.get(v, name)
            if self.ctl != 0 { return undef() }
            if self.is_fn(f) {
                let r = self.call(f, v, [])
                if self.ctl != 0 { return undef() }
                if r.t != OBJ { return r }
            }
        }
        self.throw_err("TypeError", "cannot convert an object to a primitive")
        return undef()
    }

    fn to_obj(self, v: Val) -> Obj? {
        if v.t == OBJ { return v.o }
        return none
    }

    fn is_fn(self, v: Val) -> bool {
        if let o = v.o { return o.cls == "Function" }
        return false
    }

    fn type_of(self, v: Val) -> str {
        if v.t == UNDEFINED { return "undefined" }
        if v.t == NULL { return "object" }
        if v.t == BOOL { return "boolean" }
        if v.t == NUM { return "number" }
        if v.t == STR { return "string" }
        if self.is_fn(v) { return "function" }
        return "object"
    }

    // ---- properties ----

    fn proto_of(self, v: Val) -> Obj? {
        if v.t == STR { return self.protos.get("String") }
        if v.t == NUM { return self.protos.get("Number") }
        if v.t == BOOL { return self.protos.get("Boolean") }
        if let o = v.o { return o.proto }
        return none
    }

    fn get(self, v: Val, key: str) -> Val {
        if v.t == UNDEFINED || v.t == NULL {
            return self.throw_err("TypeError", "cannot read properties of ${self.to_str(v)} (reading '${key}')")
        }
        if v.t == STR {
            if key == "length" { return int_v(str_len(v.s)) }
            let i = index_of_key(key)
            if i >= 0 {
                let c = char_at(v.s, i)
                return if c == "" { undef() } else { string(c) }
            }
        }
        if v.t == OBJ {
            let o = obj_of(v)
            return self.get_obj(o, key, v)
        }
        var cur = self.proto_of(v)
        while true {
            if let p = cur {
                if let x = p.props.get(key) { return x }
                if let g = p.getters.get(key) { return self.call(g, v, []) }
                cur = p.proto
            } else {
                return undef()
            }
        }
        return undef()
    }

    fn get_obj(self, o: Obj, key: str, receiver: Val) -> Val {
        if o.host != 0 {
            if let x = self.host.get(o, key) { return x }
        }
        if o.cls == "Array" || o.cls == "Arguments" {
            if key == "length" { return int_v(o.arr.len()) }
            let i = index_of_key(key)
            if i >= 0 {
                if i < o.arr.len() { return o.arr[i] }
                return undef()
            }
        }
        var cur: Obj? = some(o)
        var hops = 0
        while hops < 64 {
            if let p = cur {
                if let x = p.props.get(key) { return x }
                if let g = p.getters.get(key) { return self.call(g, receiver, []) }
                if p.host != 0 && hops > 0 {
                    if let x = self.host.get(p, key) { return x }
                }
                cur = p.proto
            } else {
                return undef()
            }
            hops += 1
        }
        return undef()
    }

    fn set(self, target: Val, key: str, value: Val) {
        if target.t == UNDEFINED || target.t == NULL {
            self.throw_err("TypeError", "cannot set properties of ${self.to_str(target)} (setting '${key}')")
            return
        }
        if target.t != OBJ { return }
        let o = obj_of(target)
        if o.frozen { return }
        if o.host != 0 {
            if self.host.set(o, key, value) { return }
        }
        if o.cls == "Array" || o.cls == "Arguments" {
            if key == "length" {
                let n = int(self.to_num(value))
                if n < 0 || n > 10_000_000 {
                    self.throw_err("RangeError", "invalid array length")
                    return
                }
                while o.arr.len() > n { o.arr.pop() }
                while o.arr.len() < n { o.arr.push(undef()) }
                return
            }
            let i = index_of_key(key)
            if i >= 0 {
                if i > o.arr.len() + 1_000_000 {
                    self.throw_err("RangeError", "array index too large")
                    return
                }
                while o.arr.len() <= i { o.arr.push(undef()) }
                o.arr[i] = value
                return
            }
        }
        // a setter on the object or its prototypes
        var cur: Obj? = some(o)
        while true {
            if let p = cur {
                if let s = p.setters.get(key) {
                    self.call(s, target, [value])
                    return
                }
                if p.props.contains(key) { break }
                cur = p.proto
            } else {
                break
            }
        }
        if o.props.len() > 100_000 && !o.props.contains(key) {
            self.throw_err("RangeError", "too many properties")
            return
        }
        o.props[key] = value
    }

    fn has(self, o: Obj, key: str) -> bool {
        if (o.cls == "Array" || o.cls == "Arguments") {
            let i = index_of_key(key)
            if i >= 0 { return i < o.arr.len() }
            if key == "length" { return true }
        }
        var cur: Obj? = some(o)
        while true {
            if let p = cur {
                if p.props.contains(key) || p.getters.contains(key) { return true }
                if p.host != 0 {
                    if let x = self.host.get(p, key) { return x.t != UNDEFINED }
                }
                cur = p.proto
            } else {
                return false
            }
        }
        return false
    }

    // own enumerable keys, in order (array indices first)
    fn keys(self, o: Obj) -> [str] {
        var out: [str] = []
        if o.cls == "Array" || o.cls == "Arguments" {
            for i in 0..o.arr.len() { out.push(str(i)) }
        }
        for k in o.props.keys() {
            if !o.hidden.contains(k) { out.push(k) }
        }
        for k in o.getters.keys() {
            if !o.hidden.contains(k) && !o.props.contains(k) { out.push(k) }
        }
        return out
    }

    fn key_of(self, v: Val) -> str {
        if v.t == STR { return v.s }
        if v.t == NUM { return jsparse.num_text(v.n) }
        return self.to_str(v)
    }

    // ---- calling ----

    fn call(self, f: Val, this: Val, argv: [Val]) -> Val {
        if self.ctl != 0 { return undef() }
        if !self.is_fn(f) { return self.throw_err("TypeError", "${self.type_of(f)} is not a function") }
        let fo = obj_of(f)
        if let b = fo.bound {
            var all: [Val] = []
            for a in fo.bound_args { all.push(a) }
            for a in argv { all.push(a) }
            return self.call(b, fo.this_val ?? undef(), all)
        }
        if fo.native != "" { return self.call_native(fo, this, argv, false) }
        if fo.is_class { return self.throw_err("TypeError", "a class constructor needs 'new'") }
        return self.call_user(fo, this, argv, false)
    }

    fn call_user(self, fo: Obj, this: Val, argv: [Val], is_new: bool) -> Val {
        if let node = fo.fnode {
            if self.depth >= MAX_DEPTH { return self.throw_err("RangeError", "maximum call stack size exceeded") }
            self.depth += 1
            let scope = Env { parent: fo.scope, func: some(fo) }
            if !node.flag2 {
                scope.has_this = true
                scope.this_val = if this.t == UNDEFINED && !is_new { object(self.global) } else { this }
                let ao = self.new_obj("Object")
                ao.cls = "Arguments"
                ao.arr = argv
                scope.vars["arguments"] = object(ao)
            }
            for i, p in node.params {
                if p.k == "rest" {
                    var rest: [Val] = []
                    for j in i..argv.len() { rest.push(argv[j]) }
                    self.bind(p.kids[0], self.array(rest), scope, "let")
                } else {
                    self.bind(p, if i < argv.len() { argv[i] } else { undef() }, scope, "let")
                }
                if self.ctl != 0 { break }
            }
            var result = undef()
            if self.ctl == 0 {
                let body = node.kids[0]
                if node.flag {
                    result = self.eval(body, scope)
                } else {
                    self.hoist(body.kids, scope, true)
                    self.exec_list(body.kids, scope)
                    if self.ctl == 1 {
                        result = self.cval
                        self.ctl = 0
                        self.cval = undef()
                    }
                }
            }
            self.depth -= 1
            if node.s2 == "async" {
                // an async function: its result as a promise
                if self.ctl == 4 {
                    let reason = self.cval
                    self.ctl = 0
                    return self.promise_rejected(reason)
                }
                return self.promise_resolved(result)
            }
            return result
        }
        return undef()
    }

    fn construct(self, f: Val, argv: [Val]) -> Val {
        if self.ctl != 0 { return undef() }
        if !self.is_fn(f) { return self.throw_err("TypeError", "${self.type_of(f)} is not a constructor") }
        let fo = obj_of(f)
        if let b = fo.bound {
            var all: [Val] = []
            for a in fo.bound_args { all.push(a) }
            for a in argv { all.push(a) }
            return self.construct(b, all)
        }
        if fo.native != "" { return self.call_native(fo, undef(), argv, true) }
        if fo.fnode.is_none() { return self.throw_err("TypeError", "not a constructor") }
        if let n = fo.fnode {
            if n.flag2 { return self.throw_err("TypeError", "an arrow function is not a constructor") }
        }
        let o = self.plain()
        let p = self.get(f, "prototype")
        if let po = p.o { o.proto = some(po) }
        let this = object(o)
        self.init_fields(fo, this)
        let r = self.call_user(fo, this, argv, true)
        if self.ctl != 0 { return undef() }
        if r.t == OBJ { return r }
        return this
    }

    // class fields, the superclass's first
    fn init_fields(self, fo: Obj, this: Val) {
        if let p = fo.parent {
            if let po = p.o { if po.native == "" { self.init_fields(po, this) } }
        }
        if fo.fields.is_empty() { return }
        let scope = Env { parent: fo.scope, has_this: true, this_val: this, func: some(fo) }
        for f in fo.fields {
            let key = self.prop_key(f.kids[0], scope)
            let v = if f.kids[1].k == "empty" { undef() } else { self.eval(f.kids[1], scope) }
            self.set(this, key, v)
        }
    }

    // ---- scopes ----

    fn lookup(self, scope: Env, name: str) -> Val {
        var cur: Env? = some(scope)
        while true {
            if let e = cur {
                if let v = e.vars.get(name) { return v }
                if let o = e.obj {
                    if o.props.contains(name) || o.getters.contains(name) { return self.get_obj(o, name, object(o)) }
                }
                cur = e.parent
            } else {
                break
            }
        }
        if name == "undefined" { return undef() }
        if name == "NaN" { return num(nan()) }
        if name == "Infinity" { return num(1.0 / 0.0) }
        return self.throw_err("ReferenceError", "${name} is not defined")
    }

    fn defined(self, scope: Env, name: str) -> bool {
        var cur: Env? = some(scope)
        while true {
            if let e = cur {
                if e.vars.contains(name) { return true }
                if let o = e.obj { if o.props.contains(name) || o.getters.contains(name) { return true } }
                cur = e.parent
            } else {
                return false
            }
        }
        return false
    }

    fn assign_var(self, scope: Env, name: str, v: Val) {
        var cur: Env? = some(scope)
        while true {
            if let e = cur {
                if e.vars.contains(name) {
                    if e.consts.contains(name) {
                        self.throw_err("TypeError", "assignment to constant variable '${name}'")
                        return
                    }
                    e.vars[name] = v
                    return
                }
                if let o = e.obj {
                    if o.props.contains(name) || e.parent.is_none() {
                        self.set(object(o), name, v)
                        return
                    }
                }
                cur = e.parent
            } else {
                return
            }
        }
    }

    fn declare(self, scope: Env, name: str, v: Val, kind: str) {
        if let o = scope.obj {
            if kind == "var" || kind == "function" {
                o.props[name] = v
                return
            }
        }
        scope.vars[name] = v
        if kind == "const" { scope.consts.add(name) }
    }

    fn this_of(self, scope: Env) -> Val {
        var cur: Env? = some(scope)
        while true {
            if let e = cur {
                if e.has_this { return e.this_val }
                cur = e.parent
            } else {
                break
            }
        }
        return object(self.global)
    }

    fn func_of(self, scope: Env) -> Obj? {
        var cur: Env? = some(scope)
        while true {
            if let e = cur {
                if let f = e.func {
                    if let n = f.fnode { if !n.flag2 { return some(f) } }
                }
                cur = e.parent
            } else {
                break
            }
        }
        return none
    }

    // var declarations and function declarations, before a body runs
    fn hoist(self, body: [jsparse.Ast], scope: Env, function_scope: bool) {
        for s in body {
            if s.k == "funcdecl" {
                self.declare(scope, s.s, self.make_fn(s.kids[0], scope), "function")
            } else if function_scope {
                self.hoist_vars(s, scope)
            }
        }
    }

    fn hoist_vars(self, s: jsparse.Ast, scope: Env) {
        if s.k == "var" && s.s == "var" {
            for d in s.kids { self.hoist_names(d.kids[0], scope) }
            return
        }
        if s.k == "func" || s.k == "funcdecl" || s.k == "class" || s.k == "classdecl" || s.k == "expr" { return }
        for k in s.kids {
            if k.k != "func" { self.hoist_vars(k, scope) }
        }
    }

    fn hoist_names(self, p: jsparse.Ast, scope: Env) {
        if p.k == "ident" {
            if !scope.vars.contains(p.s) {
                if let o = scope.obj { if !o.props.contains(p.s) { o.props[p.s] = undef() } } else { scope.vars[p.s] = undef() }
            }
            return
        }
        for k in p.kids {
            if k.k == "patprop" { self.hoist_names(k.kids[1], scope) } else { self.hoist_names(k, scope) }
        }
    }

    // ---- binding patterns ----

    // kind: var, let, const (declare) or assign (existing targets)
    fn bind(self, p: jsparse.Ast, v: Val, scope: Env, kind: str) {
        if self.ctl != 0 { return }
        if p.k == "ident" {
            if kind == "assign" {
                if !self.defined(scope, p.s) {
                    self.global.props[p.s] = v   // sloppy mode: an implicit global
                } else {
                    self.assign_var(scope, p.s, v)
                }
            } else if kind == "var" {
                if self.defined(scope, p.s) { self.assign_var(scope, p.s, v) } else { self.declare(scope, p.s, v, "var") }
            } else {
                self.declare(scope, p.s, v, kind)
            }
            return
        }
        if p.k == "default" {
            var value = v
            if v.t == UNDEFINED { value = self.eval(p.kids[1], scope) }
            self.bind(p.kids[0], value, scope, kind)
            return
        }
        if p.k == "member" || p.k == "index" {
            let o = self.eval(p.kids[0], scope)
            let key = if p.k == "member" { p.s } else { self.key_of(self.eval(p.kids[1], scope)) }
            if self.ctl == 0 { self.set(o, key, v) }
            return
        }
        if p.k == "arrpat" {
            let items = self.iterate(v)
            if self.ctl != 0 { return }
            for i, el in p.kids {
                if el.k == "hole" { continue }
                if el.k == "rest" {
                    var rest: [Val] = []
                    for j in i..items.len() { rest.push(items[j]) }
                    self.bind(el.kids[0], self.array(rest), scope, kind)
                } else {
                    self.bind(el, if i < items.len() { items[i] } else { undef() }, scope, kind)
                }
            }
            return
        }
        if p.k == "objpat" {
            if v.t == UNDEFINED || v.t == NULL {
                self.throw_err("TypeError", "cannot destructure ${self.to_str(v)}")
                return
            }
            var used: [str] = []
            for el in p.kids {
                if el.k == "rest" {
                    let r = self.plain()
                    if let o = v.o {
                        for k in self.keys(o) {
                            if !used.contains(k) { r.props[k] = self.get(v, k) }
                        }
                    }
                    self.bind(el.kids[0], object(r), scope, kind)
                } else {
                    let key = self.prop_key(el.kids[0], scope)
                    used.push(key)
                    self.bind(el.kids[1], self.get(v, key), scope, kind)
                }
                if self.ctl != 0 { return }
            }
            return
        }
        self.throw_err("SyntaxError", "invalid destructuring target")
    }

    fn prop_key(self, k: jsparse.Ast, scope: Env) -> str {
        if k.k == "computed" { return self.key_of(self.eval(k.kids[0], scope)) }
        return k.s
    }

    // the values a for-of loop (or spread) goes through
    fn iterate(self, v: Val) -> [Val] {
        if v.t == STR {
            var out: [Val] = []
            for c in v.s.chars() { out.push(string(c)) }
            return out
        }
        if let o = v.o {
            if o.cls == "Array" || o.cls == "Arguments" {
                var out: [Val] = []
                for x in o.arr { out.push(x) }
                return out
            }
            if o.cls == "Map" {
                var out: [Val] = []
                for k in o.map.keys() { out.push(self.array([o.mkeys.get(k) ?? undef(), o.map.get(k) ?? undef()])) }
                return out
            }
            if o.cls == "Set" {
                var out: [Val] = []
                for k in o.map.keys() { out.push(o.mkeys.get(k) ?? undef()) }
                return out
            }
            if o.host != 0 {
                let l = self.get(v, "length")
                if l.t == NUM {
                    var out: [Val] = []
                    for i in 0..int(l.n) { out.push(self.get(v, str(i))) }
                    return out
                }
            }
            // something with a [Symbol.iterator]() method
            let it = self.get(v, "@@iterator")
            if self.is_fn(it) {
                let iter = self.call(it, v, [])
                if self.ctl != 0 { return [] }
                if let io = iter.o { if io.cls == "Array" { return io.arr } }
                return self.iterate(iter)
            }
            // an iterator object (has next())
            let next = self.get(v, "next")
            if self.is_fn(next) {
                var out: [Val] = []
                var guard = 0
                while guard < 1_000_000 && self.ctl == 0 {
                    let r = self.call(next, v, [])
                    if self.ctl != 0 || self.truthy(self.get(r, "done")) { break }
                    out.push(self.get(r, "value"))
                    guard += 1
                }
                return out
            }
        }
        self.throw_err("TypeError", "${self.type_of(v)} is not iterable")
        return []
    }

    // ---- functions and classes ----

    fn make_fn(self, node: jsparse.Ast, scope: Env) -> Val {
        let f = self.new_obj("Function")
        f.cls = "Function"
        f.fnode = some(node)
        f.scope = some(scope)
        f.props["name"] = string(node.s)
        f.props["length"] = int_v(node.params.filter(p => p.k == "ident").len())
        f.hidden.add("name")
        f.hidden.add("length")
        if !node.flag2 {
            let proto = self.plain()
            proto.props["constructor"] = object(f)
            proto.hidden.add("constructor")
            f.props["prototype"] = object(proto)
            f.hidden.add("prototype")
        }
        return object(f)
    }

    fn make_class(self, node: jsparse.Ast, scope: Env) -> Val {
        var sup = undef()
        if node.kids[0].k != "empty" {
            sup = self.eval(node.kids[0], scope)
            if self.ctl != 0 { return undef() }
            if sup.t != NULL && !self.is_fn(sup) { return self.throw_err("TypeError", "class extends a value that isn't a constructor") }
        }
        let cenv = Env { parent: some(scope) }
        // the constructor
        var ctor_node = jsparse.Ast { k: "func", s: node.s, kids: [jsparse.Ast { k: "block" }] }
        if sup.t == OBJ {
            // default: constructor(...argv) { super(...argv) }
            ctor_node.params = [jsparse.Ast { k: "rest", kids: [jsparse.Ast { k: "ident", s: "argv" }] }]
            ctor_node.kids = [jsparse.Ast { k: "block", kids: [jsparse.Ast { k: "expr", kids: [jsparse.Ast { k: "call", kids: [jsparse.Ast { k: "super" }, jsparse.Ast { k: "spread", kids: [jsparse.Ast { k: "ident", s: "argv" }] }] }] }] }]
        }
        for m in node.params {
            if m.k == "member" && m.s == "method" && !m.flag && m.kids[0].k == "str" && m.kids[0].s == "constructor" {
                ctor_node = m.kids[1]
                ctor_node.s = node.s
            }
        }
        let fv = self.make_fn(ctor_node, cenv)
        let f = obj_of(fv)
        f.is_class = true
        if node.s != "" { cenv.vars[node.s] = fv }
        let proto = obj_of(self.get(fv, "prototype"))
        if sup.t == OBJ {
            f.parent = some(sup)
            f.proto = sup.o
            let sp = self.get(sup, "prototype")
            if let spo = sp.o { proto.proto = some(spo) }
        } else if sup.t == NULL {
            proto.proto = none
        }
        f.home = some(proto)
        cenv.func = some(f)
        for m in node.params {
            if m.k == "member" {
                if m.kids[0].k == "str" && m.kids[0].s == "constructor" && !m.flag && m.s == "method" { continue }
                let key = self.prop_key(m.kids[0], cenv)
                let target = if m.flag { f } else { proto }
                let mv = self.make_fn(m.kids[1], cenv)
                obj_of(mv).home = some(target)
                if m.s == "get" {
                    target.getters[key] = mv
                } else if m.s == "set" {
                    target.setters[key] = mv
                } else {
                    target.props[key] = mv
                }
                target.hidden.add(key)
            } else if m.k == "field" {
                if m.flag {
                    let senv = Env { parent: some(cenv), has_this: true, this_val: fv, func: some(f) }
                    let key = self.prop_key(m.kids[0], senv)
                    f.props[key] = if m.kids[1].k == "empty" { undef() } else { self.eval(m.kids[1], senv) }
                } else {
                    f.fields.push(m)
                }
            } else if m.k == "staticblock" {
                let senv = Env { parent: some(cenv), has_this: true, this_val: fv, func: some(f) }
                self.exec(m.kids[0], senv)
            }
        }
        return fv
    }

    // ---- statements ----

    fn exec_list(self, list: [jsparse.Ast], scope: Env) {
        for s in list {
            self.exec(s, scope)
            if self.ctl != 0 { return }
        }
    }

    fn take_label(self) -> str {
        let l = self.pending_label
        self.pending_label = ""
        return l
    }

    // after a loop body: true if the loop should stop
    fn loop_exit(self, label: str) -> bool {
        if self.ctl == 2 {
            if self.clabel == "" || self.clabel == label {
                self.ctl = 0
                self.clabel = ""
            }
            return true
        }
        if self.ctl == 3 {
            if self.clabel == "" || self.clabel == label {
                self.ctl = 0
                self.clabel = ""
                return false
            }
            return true
        }
        return self.ctl != 0
    }

    fn exec(self, s: jsparse.Ast, scope: Env) {
        if !self.step() { return }
        let k = s.k
        if k == "expr" {
            self.eval(s.kids[0], scope)
            return
        }
        if k == "var" {
            for d in s.kids {
                if d.kids[1].k == "empty" {
                    if s.s != "var" { self.bind(d.kids[0], undef(), scope, s.s) }
                } else {
                    let v = self.eval(d.kids[1], scope)
                    if self.ctl != 0 { return }
                    if d.kids[0].k == "ident" && (d.kids[1].k == "func" || d.kids[1].k == "class") {
                        if let fo = v.o { if (fo.props.get("name") ?? undef()).s == "" { fo.props["name"] = string(d.kids[0].s) } }
                    }
                    self.bind(d.kids[0], v, scope, s.s)
                }
                if self.ctl != 0 { return }
            }
            return
        }
        if k == "block" {
            let benv = Env { parent: some(scope) }
            self.hoist(s.kids, benv, false)
            self.exec_list(s.kids, benv)
            return
        }
        if k == "if" {
            let t = self.eval(s.kids[0], scope)
            if self.ctl != 0 { return }
            if self.truthy(t) { self.exec(s.kids[1], scope) } else if s.kids[2].k != "empty" { self.exec(s.kids[2], scope) }
            return
        }
        if k == "for" {
            let label = self.take_label()
            let fenv = Env { parent: some(scope) }
            if s.kids[0].k == "var" { self.exec(s.kids[0], fenv) } else if s.kids[0].k != "empty" { self.eval(s.kids[0], fenv) }
            let per_iter = s.kids[0].k == "var" && s.kids[0].s != "var"
            while self.ctl == 0 {
                if s.kids[1].k != "empty" {
                    let t = self.eval(s.kids[1], fenv)
                    if self.ctl != 0 || !self.truthy(t) { break }
                }
                // let bindings: a fresh copy each time round (closures see their own)
                let ienv = if per_iter { copy_env(fenv) } else { fenv }
                self.exec(s.kids[3], ienv)
                if self.loop_exit(label) { break }
                if per_iter {
                    for name in ienv.vars.keys() { fenv.vars[name] = ienv.vars.get(name) ?? undef() }
                }
                if s.kids[2].k != "empty" { self.eval(s.kids[2], fenv) }
                if !self.step() { break }
            }
            return
        }
        if k == "forof" || k == "forin" {
            let label = self.take_label()
            let obj = self.eval(s.kids[1], scope)
            if self.ctl != 0 { return }
            var items: [Val] = []
            if k == "forof" {
                items = self.iterate(obj)
            } else if let o = obj.o {
                // own and inherited enumerable keys
                var seen: {str} = {}
                var cur: Obj? = some(o)
                while true {
                    if let p = cur {
                        for key in self.keys(p) {
                            if !seen.contains(key) {
                                seen.add(key)
                                items.push(string(key))
                            }
                        }
                        cur = p.proto
                    } else {
                        break
                    }
                }
            } else if obj.t == STR {
                for i in 0..str_len(obj.s) { items.push(string(str(i))) }
            }
            if self.ctl != 0 { return }
            let target = s.kids[0]
            for item in items {
                let ienv = Env { parent: some(scope) }
                if target.k == "var" {
                    self.bind(target.kids[0].kids[0], item, ienv, target.s)
                } else {
                    self.bind(target, item, scope, "assign")
                }
                self.exec(s.kids[2], ienv)
                if self.loop_exit(label) { break }
                if !self.step() { break }
            }
            return
        }
        if k == "while" {
            let label = self.take_label()
            while self.ctl == 0 {
                let t = self.eval(s.kids[0], scope)
                if self.ctl != 0 || !self.truthy(t) { break }
                self.exec(s.kids[1], scope)
                if self.loop_exit(label) { break }
            }
            return
        }
        if k == "dowhile" {
            let label = self.take_label()
            while self.ctl == 0 {
                self.exec(s.kids[0], scope)
                if self.loop_exit(label) { break }
                let t = self.eval(s.kids[1], scope)
                if self.ctl != 0 || !self.truthy(t) { break }
            }
            return
        }
        if k == "return" {
            let v = if s.kids[0].k == "empty" { undef() } else { self.eval(s.kids[0], scope) }
            if self.ctl != 0 { return }
            self.ctl = 1
            self.cval = v
            return
        }
        if k == "break" || k == "continue" {
            self.ctl = if k == "break" { 2 } else { 3 }
            self.clabel = s.s
            return
        }
        if k == "throw" {
            let v = self.eval(s.kids[0], scope)
            if self.ctl != 0 { return }
            self.throw_val(v)
            return
        }
        if k == "try" {
            self.exec(s.kids[0], scope)
            if self.ctl == 4 && s.kids[2].k != "empty" {
                let exc = self.cval
                self.ctl = 0
                self.cval = undef()
                let cenv = Env { parent: some(scope) }
                if s.kids[1].k != "empty" { self.bind(s.kids[1], exc, cenv, "let") }
                self.exec(s.kids[2], cenv)
            }
            if s.kids[3].k != "empty" && self.ctl != 5 {
                let saved_ctl = self.ctl
                let saved_val = self.cval
                let saved_label = self.clabel
                self.ctl = 0
                self.exec(s.kids[3], scope)
                if self.ctl == 0 {
                    self.ctl = saved_ctl
                    self.cval = saved_val
                    self.clabel = saved_label
                }
            }
            return
        }
        if k == "switch" {
            let label = self.take_label()
            let d = self.eval(s.kids[0], scope)
            if self.ctl != 0 { return }
            let senv = Env { parent: some(scope) }
            var start = -1
            for i in 1..s.kids.len() {
                let c = s.kids[i]
                if c.flag { continue }
                let v = self.eval(c.kids[0], senv)
                if self.ctl != 0 { return }
                if strict_eq(d, v) {
                    start = i
                    break
                }
            }
            if start < 0 {
                for i in 1..s.kids.len() {
                    if s.kids[i].flag { start = i }
                }
            }
            if start < 0 { return }
            for i in start..s.kids.len() {
                let c = s.kids[i]
                self.exec_list(c.kids.slice(1, c.kids.len()), senv)
                if self.ctl != 0 { break }
            }
            if self.ctl == 2 && (self.clabel == "" || self.clabel == label) {
                self.ctl = 0
                self.clabel = ""
            }
            return
        }
        if k == "funcdecl" { return }             // hoisted
        if k == "classdecl" {
            let c = self.make_class(s.kids[0], scope)
            if self.ctl == 0 { self.declare(scope, s.s, c, "let") }
            return
        }
        if k == "label" {
            let inner = s.kids[0]
            if inner.k == "for" || inner.k == "while" || inner.k == "dowhile" || inner.k == "forof" || inner.k == "forin" || inner.k == "switch" {
                self.pending_label = s.s
                self.exec(inner, scope)
            } else {
                self.exec(inner, scope)
                if self.ctl == 2 && self.clabel == s.s {
                    self.ctl = 0
                    self.clabel = ""
                }
            }
            return
        }
        if k == "empty" { return }
        self.throw_err("SyntaxError", "unsupported statement ${k}")
    }

    // ---- expressions ----

    fn eval(self, e: jsparse.Ast, scope: Env) -> Val {
        if !self.step() { return undef() }
        let k = e.k
        if k == "num" { return num(e.n) }
        if k == "str" { return string(e.s) }
        if k == "ident" { return self.lookup(scope, e.s) }
        if k == "member" {
            let o = self.eval(e.kids[0], scope)
            if self.ctl != 0 || self.short { return undef() }
            if e.flag && (o.t == UNDEFINED || o.t == NULL) {
                self.short = true
                return undef()
            }
            if e.kids[0].k == "super" { return self.super_get(scope, e.s) }
            return self.get(o, e.s)
        }
        if k == "index" {
            let o = self.eval(e.kids[0], scope)
            if self.ctl != 0 || self.short { return undef() }
            if e.flag && (o.t == UNDEFINED || o.t == NULL) {
                self.short = true
                return undef()
            }
            let key = self.eval(e.kids[1], scope)
            if self.ctl != 0 { return undef() }
            if let ao = o.o {
                if ao.cls == "Array" && key.t == NUM && key.n >= 0.0 && key.n == key.n.floor() {
                    let i = int(key.n)
                    return if i < ao.arr.len() { ao.arr[i] } else { undef() }
                }
            }
            return self.get(o, self.key_of(key))
        }
        if k == "call" { return self.eval_call(e, scope) }
        if k == "assign" { return self.eval_assign(e, scope) }
        if k == "bin" {
            let a = self.eval(e.kids[0], scope)
            if self.ctl != 0 { return undef() }
            let b = self.eval(e.kids[1], scope)
            if self.ctl != 0 { return undef() }
            return self.binop(e.s, a, b)
        }
        if k == "logic" {
            let a = self.eval(e.kids[0], scope)
            if self.ctl != 0 { return undef() }
            if e.s == "&&" { return if self.truthy(a) { self.eval(e.kids[1], scope) } else { a } }
            if e.s == "||" { return if self.truthy(a) { a } else { self.eval(e.kids[1], scope) } }
            return if a.t == UNDEFINED || a.t == NULL { self.eval(e.kids[1], scope) } else { a }
        }
        if k == "this" { return self.this_of(scope) }
        if k == "str" { return string(e.s) }
        if k == "bool" { return boolean(e.flag) }
        if k == "null" { return null_v() }
        if k == "cond" {
            let t = self.eval(e.kids[0], scope)
            if self.ctl != 0 { return undef() }
            return if self.truthy(t) { self.eval(e.kids[1], scope) } else { self.eval(e.kids[2], scope) }
        }
        if k == "unary" { return self.eval_unary(e, scope) }
        if k == "update" {
            let old = self.to_num(self.eval(e.kids[0], scope))
            if self.ctl != 0 { return undef() }
            let nv = if e.s == "++" { old + 1.0 } else { old - 1.0 }
            self.store(e.kids[0], num(nv), scope)
            return num(if e.flag { nv } else { old })
        }
        if k == "tmpl" {
            var parts: [str] = []
            for i, x in e.kids {
                if i % 2 == 0 {
                    parts.push(x.s)
                } else {
                    let v = self.eval(x, scope)
                    if self.ctl != 0 { return undef() }
                    parts.push(self.to_str(v))
                }
            }
            return self.make_string(parts.join(""))
        }
        if k == "array" {
            var items: [Val] = []
            for x in e.kids {
                if x.k == "spread" {
                    let v = self.eval(x.kids[0], scope)
                    if self.ctl != 0 { return undef() }
                    for y in self.iterate(v) { items.push(y) }
                } else if x.k == "hole" {
                    items.push(undef())
                } else {
                    items.push(self.eval(x, scope))
                }
                if self.ctl != 0 { return undef() }
            }
            return self.array(items)
        }
        if k == "object" {
            let o = self.plain()
            let ov = object(o)
            for p in e.kids {
                if p.s == "spread" {
                    let v = self.eval(p.kids[1], scope)
                    if let src = v.o {
                        for key in self.keys(src) { o.props[key] = self.get(v, key) }
                    } else if v.t == STR {
                        for i, c in v.s.chars() { o.props[str(i)] = string(c) }
                    }
                } else {
                    let key = self.prop_key(p.kids[0], scope)
                    if self.ctl != 0 { return undef() }
                    let v = self.eval(p.kids[1], scope)
                    if self.ctl != 0 { return undef() }
                    if p.kids[1].k == "func" {
                        if let fo = v.o {
                            fo.home = some(o)
                            if (fo.props.get("name") ?? undef()).s == "" { fo.props["name"] = string(key) }
                        }
                    }
                    if p.s == "get" {
                        o.getters[key] = v
                    } else if p.s == "set" {
                        o.setters[key] = v
                    } else {
                        o.props[key] = v
                    }
                }
                if self.ctl != 0 { return undef() }
            }
            return ov
        }
        if k == "func" {
            let f = self.make_fn(e, scope)
            if e.flag2 {
                let fo = obj_of(f)
                fo.this_val = some(self.this_of(scope))
            }
            if e.s != "" && !e.flag2 {
                // a named function expression sees its own name
                let fenv = Env { parent: some(scope) }
                fenv.vars[e.s] = f
                obj_of(f).scope = some(fenv)
            }
            return f
        }
        if k == "class" { return self.make_class(e, scope) }
        if k == "new" {
            let f = self.eval(e.kids[0], scope)
            if self.ctl != 0 { return undef() }
            let argv = self.eval_args(e.kids.slice(1, e.kids.len()), scope)
            if self.ctl != 0 { return undef() }
            return self.construct(f, argv)
        }
        if k == "seq" {
            var v = undef()
            for x in e.kids {
                v = self.eval(x, scope)
                if self.ctl != 0 { return undef() }
            }
            return v
        }
        if k == "regex" { return self.make_regexp(e.s, e.s2) }
        if k == "chain" {
            let saved = self.short
            self.short = false
            let v = self.eval(e.kids[0], scope)
            let was_short = self.short
            self.short = saved
            return if was_short { undef() } else { v }
        }
        if k == "await" {
            let v = self.eval(e.kids[0], scope)
            if self.ctl != 0 { return undef() }
            return self.await_value(v)
        }
        if k == "spread" { return self.throw_err("SyntaxError", "unexpected spread") }
        if k == "super" { return self.throw_err("SyntaxError", "'super' keyword unexpected here") }
        if k == "empty" { return undef() }
        return self.throw_err("SyntaxError", "unsupported expression ${k}")
    }

    fn make_string(self, s: str) -> Val {
        if s.len() > MAX_STRING { return self.throw_err("RangeError", "string too long") }
        return string(s)
    }

    fn super_get(self, scope: Env, key: str) -> Val {
        if let f = self.func_of(scope) {
            if let h = f.home {
                if let p = h.proto { return self.get_obj(p, key, self.this_of(scope)) }
            }
        }
        return undef()
    }

    fn eval_args(self, list: [jsparse.Ast], scope: Env) -> [Val] {
        var out: [Val] = []
        for a in list {
            if a.k == "spread" {
                let v = self.eval(a.kids[0], scope)
                if self.ctl != 0 { return out }
                for x in self.iterate(v) { out.push(x) }
            } else {
                out.push(self.eval(a, scope))
            }
            if self.ctl != 0 { return out }
        }
        return out
    }

    fn eval_call(self, e: jsparse.Ast, scope: Env) -> Val {
        let callee = e.kids[0]
        var this = undef()
        var f = undef()
        if callee.k == "super" {
            // super(...): the parent constructor, on this object
            if let fo = self.func_of(scope) {
                var cls: Obj? = some(fo)
                // a class's constructor function is the class itself
                if let p = fo.parent {
                    let argv = self.eval_args(e.kids.slice(1, e.kids.len()), scope)
                    if self.ctl != 0 { return undef() }
                    let t = self.this_of(scope)
                    if let po = p.o {
                        if po.native != "" {
                            self.call_native(po, t, argv, false)
                        } else {
                            self.call_user(po, t, argv, true)
                        }
                    }
                    return undef()
                }
            }
            return undef()
        }
        if callee.k == "member" || callee.k == "index" {
            if callee.kids[0].k == "super" {
                this = self.this_of(scope)
                let key = if callee.k == "member" { callee.s } else { self.key_of(self.eval(callee.kids[1], scope)) }
                f = self.super_get(scope, key)
            } else {
                this = self.eval(callee.kids[0], scope)
                if self.ctl != 0 || self.short { return undef() }
                if callee.flag && (this.t == UNDEFINED || this.t == NULL) {
                    self.short = true
                    return undef()
                }
                let key = if callee.k == "member" { callee.s } else { self.key_of(self.eval(callee.kids[1], scope)) }
                if self.ctl != 0 { return undef() }
                f = self.get(this, key)
                if self.ctl != 0 { return undef() }
                if !self.is_fn(f) && !e.flag {
                    return self.throw_err("TypeError", "${describe(callee)} is not a function")
                }
            }
        } else {
            f = self.eval(callee, scope)
            if self.ctl != 0 || self.short { return undef() }
        }
        if e.flag && (f.t == UNDEFINED || f.t == NULL) {
            self.short = true
            return undef()
        }
        if !self.is_fn(f) { return self.throw_err("TypeError", "${describe(callee)} is not a function") }
        let argv = self.eval_args(e.kids.slice(1, e.kids.len()), scope)
        if self.ctl != 0 { return undef() }
        let fo = obj_of(f)
        if let tv = fo.this_val {
            if fo.bound.is_none() { this = tv }  // an arrow: its own this
        }
        return self.call(f, this, argv)
    }

    fn eval_unary(self, e: jsparse.Ast, scope: Env) -> Val {
        let op = e.s
        if op == "typeof" {
            if e.kids[0].k == "ident" && !self.defined(scope, e.kids[0].s) && e.kids[0].s != "undefined" { return string("undefined") }
            let v = self.eval(e.kids[0], scope)
            if self.ctl != 0 { return undef() }
            return string(self.type_of(v))
        }
        if op == "delete" {
            let t = e.kids[0]
            if t.k == "member" || t.k == "index" {
                let o = self.eval(t.kids[0], scope)
                let key = if t.k == "member" { t.s } else { self.key_of(self.eval(t.kids[1], scope)) }
                if let ob = o.o {
                    if ob.frozen { return boolean(false) }
                    ob.props.remove(key)
                    ob.getters.remove(key)
                    if ob.cls == "Array" {
                        let i = index_of_key(key)
                        if i >= 0 && i < ob.arr.len() { ob.arr[i] = undef() }
                    }
                }
            }
            return boolean(true)
        }
        let v = self.eval(e.kids[0], scope)
        if self.ctl != 0 { return undef() }
        if op == "!" { return boolean(!self.truthy(v)) }
        if op == "-" { return num(0.0 - self.to_num(v)) }
        if op == "+" { return num(self.to_num(v)) }
        if op == "~" { return int_v(to_int32(float(~to_int32(self.to_num(v))))) }
        if op == "void" { return undef() }
        return undef()
    }

    // write to an assignment target
    fn store(self, target: jsparse.Ast, v: Val, scope: Env) {
        if target.k == "ident" {
            if self.defined(scope, target.s) { self.assign_var(scope, target.s, v) } else { self.global.props[target.s] = v }
            return
        }
        self.bind(target, v, scope, "assign")
    }

    fn eval_assign(self, e: jsparse.Ast, scope: Env) -> Val {
        let target = e.kids[0]
        let op = e.s
        if op == "=" {
            // evaluate the object part of a member target first, like JavaScript
            if target.k == "member" || target.k == "index" {
                let o = self.eval(target.kids[0], scope)
                if self.ctl != 0 { return undef() }
                let key = if target.k == "member" { target.s } else { self.key_of(self.eval(target.kids[1], scope)) }
                if self.ctl != 0 { return undef() }
                let v = self.eval(e.kids[1], scope)
                if self.ctl != 0 { return undef() }
                self.set(o, key, v)
                return v
            }
            let v = self.eval(e.kids[1], scope)
            if self.ctl != 0 { return undef() }
            if target.k == "ident" && (e.kids[1].k == "func" || e.kids[1].k == "class") {
                if let fo = v.o { if (fo.props.get("name") ?? undef()).s == "" { fo.props["name"] = string(target.s) } }
            }
            self.store(target, v, scope)
            return v
        }
        // compound: a op= b
        var obj = undef()
        var key = ""
        var old = undef()
        if target.k == "member" || target.k == "index" {
            obj = self.eval(target.kids[0], scope)
            if self.ctl != 0 { return undef() }
            key = if target.k == "member" { target.s } else { self.key_of(self.eval(target.kids[1], scope)) }
            old = self.get(obj, key)
        } else {
            old = self.eval(target, scope)
        }
        if self.ctl != 0 { return undef() }
        var v = undef()
        if op == "&&=" || op == "||=" || op == "??=" {
            let keep = if op == "&&=" { !self.truthy(old) } else if op == "||=" { self.truthy(old) } else { old.t != UNDEFINED && old.t != NULL }
            if keep { return old }
            v = self.eval(e.kids[1], scope)
        } else {
            let rhs = self.eval(e.kids[1], scope)
            if self.ctl != 0 { return undef() }
            v = self.binop(op.slice(0, op.len() - 1), old, rhs)
        }
        if self.ctl != 0 { return undef() }
        if target.k == "member" || target.k == "index" { self.set(obj, key, v) } else { self.store(target, v, scope) }
        return v
    }

    fn binop(self, op: str, a: Val, b: Val) -> Val {
        if op == "+" {
            if a.t == NUM && b.t == NUM { return num(a.n + b.n) }
            if a.t == STR && b.t == STR { return self.make_string(a.s + b.s) }
            let pa = self.to_prim(a, "default")
            let pb = self.to_prim(b, "default")
            if self.ctl != 0 { return undef() }
            if pa.t == STR || pb.t == STR { return self.make_string(self.to_str(pa) + self.to_str(pb)) }
            return num(self.to_num(pa) + self.to_num(pb))
        }
        if op == "===" { return boolean(strict_eq(a, b)) }
        if op == "!==" { return boolean(!strict_eq(a, b)) }
        if op == "==" { return boolean(self.loose_eq(a, b)) }
        if op == "!=" { return boolean(!self.loose_eq(a, b)) }
        if op == "<" || op == ">" || op == "<=" || op == ">=" {
            let pa = self.to_prim(a, "number")
            let pb = self.to_prim(b, "number")
            if self.ctl != 0 { return undef() }
            if pa.t == STR && pb.t == STR {
                if op == "<" { return boolean(pa.s < pb.s) }
                if op == ">" { return boolean(pa.s > pb.s) }
                if op == "<=" { return boolean(!(pa.s > pb.s)) }
                return boolean(!(pa.s < pb.s))
            }
            let x = self.to_num(pa)
            let y = self.to_num(pb)
            if x != x || y != y { return boolean(false) }
            if op == "<" { return boolean(x < y) }
            if op == ">" { return boolean(x > y) }
            if op == "<=" { return boolean(x <= y) }
            return boolean(x >= y)
        }
        if op == "instanceof" {
            if !self.is_fn(b) { return self.throw_err("TypeError", "right-hand side of 'instanceof' is not callable") }
            let p = self.get(b, "prototype")
            if let po = p.o {
                var cur = self.proto_of(a)
                if a.t != OBJ { return boolean(false) }
                while true {
                    if let c = cur {
                        if c.id == po.id { return boolean(true) }
                        cur = c.proto
                    } else {
                        break
                    }
                }
            }
            return boolean(false)
        }
        if op == "in" {
            if let o = b.o { return boolean(self.has(o, self.key_of(a))) }
            return self.throw_err("TypeError", "cannot use 'in' to search for a key in ${self.to_str(b)}")
        }
        let x = self.to_num(a)
        let y = self.to_num(b)
        if self.ctl != 0 { return undef() }
        if op == "-" { return num(x - y) }
        if op == "*" { return num(x * y) }
        if op == "/" { return num(x / y) }
        if op == "%" {
            if y == 0.0 || x != x || y != y || x == 1.0 / 0.0 || x == -1.0 / 0.0 { return num(nan()) }
            if y == 1.0 / 0.0 || y == -1.0 / 0.0 { return num(x) }
            return num(x % y)
        }
        if op == "**" { return num(pow(x, y)) }
        let ia = to_int32(x)
        let ib = to_int32(y)
        if op == "&" { return int_v(ia & ib) }
        if op == "|" { return int_v(ia | ib) }
        if op == "^" { return int_v(ia ^ ib) }
        if op == "<<" { return int_v(to_int32(float((ia << (ib & 31)) & 0xffff_ffff))) }
        if op == ">>" { return int_v(ia >> (ib & 31)) }
        if op == ">>>" { return int_v(((ia & 0xffff_ffff) >> (ib & 31))) }
        return self.throw_err("SyntaxError", "unknown operator ${op}")
    }

    fn loose_eq(self, a: Val, b: Val) -> bool {
        if a.t == b.t { return strict_eq(a, b) }
        if (a.t == UNDEFINED || a.t == NULL) && (b.t == UNDEFINED || b.t == NULL) { return true }
        if a.t == UNDEFINED || a.t == NULL || b.t == UNDEFINED || b.t == NULL { return false }
        if a.t == OBJ { return self.loose_eq(self.to_prim(a, "default"), b) }
        if b.t == OBJ { return self.loose_eq(a, self.to_prim(b, "default")) }
        return self.to_num(a) == self.to_num(b)
    }

    // ---- regular expressions ----

    fn make_regexp(self, source: str, flags: str) -> Val {
        let r = self.new_obj("RegExp")
        r.cls = "RegExp"
        r.prim = some(string(source))
        r.flags = flags
        let compiled = jsre.compile(source, flags.contains("i"), flags.contains("m"), flags.contains("s"))
        if compiled.error != "" { return self.throw_err("SyntaxError", "invalid regular expression /${source}/: ${compiled.error}") }
        r.props["lastIndex"] = int_v(0)
        r.hidden.add("lastIndex")
        return object(r)
    }

    fn regex_of(self, v: Val) -> jsre.Re? {
        if let o = v.o {
            if o.cls == "RegExp" {
                let src = (o.prim ?? undef()).s
                return some(jsre.compile(src, o.flags.contains("i"), o.flags.contains("m"), o.flags.contains("s")))
            }
        }
        return none
    }

    // ---- promises ----

    fn new_promise(self) -> Obj {
        let p = self.new_obj("Promise")
        p.cls = "Promise"
        p.state = "pending"
        return p
    }

    fn promise_resolved(self, v: Val) -> Val {
        if let o = v.o { if o.cls == "Promise" { return v } }
        let p = self.new_promise()
        self.settle(p, "fulfilled", v)
        return object(p)
    }

    fn promise_rejected(self, v: Val) -> Val {
        let p = self.new_promise()
        self.settle(p, "rejected", v)
        return object(p)
    }

    // resolve with a value that may itself be a promise (or thenable)
    fn resolve_with(self, p: Obj, v: Val) {
        if p.state != "pending" { return }
        if let o = v.o {
            if o.id == p.id {
                self.settle(p, "rejected", self.error("TypeError", "a promise can't resolve to itself"))
                return
            }
            let then = self.get(v, "then")
            if self.ctl == 4 {
                let r = self.cval
                self.ctl = 0
                self.settle(p, "rejected", r)
                return
            }
            if self.is_fn(then) {
                let res = self.native("Promise.resolver", 1)
                obj_of(res).prim = some(object(p))
                let rej = self.native("Promise.rejecter", 1)
                obj_of(rej).prim = some(object(p))
                self.jobs.push(Job { f: then, argv: [v, res, rej] })
                return
            }
        }
        self.settle(p, "fulfilled", v)
    }

    fn settle(self, p: Obj, state: str, v: Val) {
        if p.state != "pending" { return }
        p.state = state
        p.prim = some(v)
        let rs = p.reactions
        p.reactions = []
        var i = 0
        while i + 2 < rs.len() {
            self.react(p, rs[i], rs[i + 1], rs[i + 2])
            i += 3
        }
    }

    // queue the reaction for a settled promise
    fn react(self, p: Obj, on_ok: Val, on_err: Val, child: Val) {
        let handler = if p.state == "fulfilled" { on_ok } else { on_err }
        let runner = self.native("Promise.reaction", 1)
        let ro = obj_of(runner)
        ro.prim = some(child)
        ro.bound_args = [handler, string(p.state), p.prim ?? undef()]
        self.jobs.push(Job { f: runner, argv: [] })
    }

    fn then(self, p: Obj, on_ok: Val, on_err: Val) -> Val {
        let child = object(self.new_promise())
        if p.state == "pending" {
            p.reactions.push(on_ok)
            p.reactions.push(on_err)
            p.reactions.push(child)
        } else {
            self.react(p, on_ok, on_err, child)
        }
        return child
    }

    // Run queued promise reactions (after each script, event and timer).
    fn run_jobs(self) {
        var n = 0
        while !self.jobs.is_empty() && n < 100_000 && self.ctl != 5 {
            let j = self.jobs[0]
            self.jobs.remove(0)
            self.call(j.f, undef(), j.argv)
            if self.ctl == 4 {
                self.report(self.cval)
                self.ctl = 0
            }
            n += 1
        }
    }

    // await: there's no real waiting here (scripts can't do I/O), so run what's queued until the
    // promise settles
    fn await_value(self, v: Val) -> Val {
        if let o = v.o {
            if o.cls == "Promise" {
                var guard = 0
                while o.state == "pending" && !self.jobs.is_empty() && guard < 100_000 && self.ctl == 0 {
                    let j = self.jobs[0]
                    self.jobs.remove(0)
                    self.call(j.f, undef(), j.argv)
                    if self.ctl == 4 {
                        self.report(self.cval)
                        self.ctl = 0
                    }
                    guard += 1
                }
                if o.state == "fulfilled" { return o.prim ?? undef() }
                if o.state == "rejected" { return self.throw_val(o.prim ?? undef()) }
                return undef()
            }
        }
        return v
    }

    // an uncaught exception: to the console
    fn report(self, exc: Val) {
        var text = self.to_str(exc)
        if self.ctl == 4 { self.ctl = 0 }
        if let o = exc.o {
            if o.cls == "Error" {
                let name = self.to_str(self.get(exc, "name"))
                let msg = self.to_str(self.get(exc, "message"))
                text = "${name}: ${msg}"
                self.ctl = 0
            }
        }
        self.host.log("error", "Uncaught ${text}")
    }

    // ---- running scripts ----

    // Run a script. Returns "" or the error that ended it.
    fn run(self, source: str, budget: int) -> str {
        let parsed = jsparse.parse(source)
        if parsed.error != "" {
            self.host.log("error", "SyntaxError: ${parsed.error}")
            return "SyntaxError: ${parsed.error}"
        }
        return self.run_parsed(parsed.body, budget)
    }

    fn run_parsed(self, body: [jsparse.Ast], budget: int) -> str {
        self.ctl = 0
        self.steps = 0
        self.budget = budget
        self.depth = 0
        self.short = false
        self.hoist(body, self.genv, true)
        self.exec_list(body, self.genv)
        return self.finish()
    }

    fn finish(self) -> str {
        var result = ""
        if self.ctl == 4 {
            let e = self.cval
            self.report(e)
            result = "uncaught exception"
        } else if self.ctl == 5 {
            self.host.log("error", self.stopped)
            result = self.stopped
        }
        if self.ctl != 5 {
            self.ctl = 0
            self.run_jobs()
        }
        let stopped = self.ctl == 5
        self.ctl = 0
        self.cval = undef()
        if stopped && result == "" { result = self.stopped }
        return result
    }

    // Call a function from outside (an event handler, a timer).
    fn invoke(self, f: Val, this: Val, argv: [Val], budget: int) -> str {
        self.ctl = 0
        self.steps = 0
        self.budget = budget
        self.depth = 0
        self.short = false
        self.call(f, this, argv)
        return self.finish()
    }
}

fn copy_env(e: Env) -> Env {
    let c = Env { parent: e.parent, obj: e.obj, has_this: e.has_this, this_val: e.this_val, func: e.func }
    for k in e.vars.keys() { c.vars[k] = e.vars.get(k) ?? Val { t: 0 } }
    for k in e.consts { c.consts.add(k) }
    return c
}

fn describe(e: jsparse.Ast) -> str {
    if e.k == "ident" { return e.s }
    if e.k == "member" { return describe(e.kids[0]) + "." + e.s }
    if e.k == "this" { return "this" }
    if e.k == "index" { return describe(e.kids[0]) + "[...]" }
    if e.k == "call" { return describe(e.kids[0]) + "(...)" }
    return "expression"
}

fn obj_of(v: Val) -> Obj {
    if let o = v.o { return o }
    return Obj { id: 0 }
}

fn strict_eq(a: Val, b: Val) -> bool {
    if a.t != b.t { return false }
    if a.t == UNDEFINED || a.t == NULL { return true }
    if a.t == NUM || a.t == BOOL { return a.n == b.n }
    if a.t == STR { return a.s == b.s }
    if let x = a.o { if let y = b.o { return x.id == y.id } }
    return false
}

fn same_value_zero(a: Val, b: Val) -> bool {
    if a.t == NUM && b.t == NUM && a.n != a.n && b.n != b.n { return true }
    return strict_eq(a, b)
}

fn nan() -> float { return 0.0 / 0.0 }

fn str_to_num(s: str) -> float {
    let t = s.trim()
    if t == "" { return 0.0 }
    let l = t.lower()
    if l.starts_with("0x") || l.starts_with("0o") || l.starts_with("0b") {
        let base = if l.starts_with("0x") { 16 } else if l.starts_with("0o") { 8 } else { 2 }
        var v = 0.0
        for c in l.slice(2, l.len()).chars() {
            let d = "0123456789abcdef".find(c)
            if d < 0 || d >= base { return nan() }
            v = v * float(base) + float(d)
        }
        return v
    }
    if t == "Infinity" || t == "+Infinity" { return 1.0 / 0.0 }
    if t == "-Infinity" { return -1.0 / 0.0 }
    for c in t.chars() {
        if !"0123456789.eE+-".contains(c) { return nan() }
    }
    return float(t) catch nan()
}

fn to_int32(n: float) -> int {
    if n != n || n == 1.0 / 0.0 || n == -1.0 / 0.0 { return 0 }
    var t = if n < 0.0 { (0.0 - n).floor() * -1.0 } else { n.floor() }
    let two32 = 4294967296.0
    t = t - (t / two32).floor() * two32
    var i = int(t)
    if i >= 2147483648 { i -= 4294967296 }
    return i
}

// "12" -> 12; anything that isn't a canonical array index -> -1
fn index_of_key(k: str) -> int {
    if k == "" || k.len() > 9 { return -1 }
    if k.len() > 1 && k.starts_with("0") { return -1 }
    for c in k.chars() {
        if !"0123456789".contains(c) { return -1 }
    }
    return int(k) catch -1
}

extern fn st_k_utf8_len(s: str) -> int

// string length and indexing in characters (JavaScript counts UTF-16 units; for text outside the
// Basic Multilingual Plane, this counts each character once)
fn str_len(s: str) -> int { return st_k_utf8_len(s) }

fn char_at(s: str, i: int) -> str {
    if i < 0 { return "" }
    if st_k_utf8_len(s) == s.len() {
        if i >= s.len() { return "" }
        return s.slice(i, i + 1)
    }
    let cs = s.chars()
    return if i < cs.len() { cs[i] } else { "" }
}

// x ** y
fn pow(x: float, y: float) -> float {
    if y == 0.0 { return 1.0 }
    if x != x || y != y { return nan() }
    if y == y.floor() && y > -1025.0 && y < 1025.0 {
        var r = 1.0
        var b = x
        var e = int(if y < 0.0 { 0.0 - y } else { y })
        while e > 0 {
            if e & 1 == 1 { r = r * b }
            b = b * b
            e = e >> 1
        }
        return if y < 0.0 { 1.0 / r } else { r }
    }
    if x < 0.0 { return nan() }
    return exp(y * ln(x))
}

fn exp(x: float) -> float {
    if x != x { return x }
    if x > 709.0 { return 1.0 / 0.0 }
    if x < -745.0 { return 0.0 }
    // e^x = 2^k * e^r with |r| <= ln2/2
    let ln2 = 0.6931471805599453
    let k = (x / ln2 + if x < 0.0 { -0.5 } else { 0.5 }).floor()
    let r = x - k * ln2
    var term = 1.0
    var sum = 1.0
    for i in 1..25 {
        term = term * r / float(i)
        sum = sum + term
    }
    return sum * pow(2.0, k)
}

fn ln(x: float) -> float {
    if x != x || x < 0.0 { return nan() }
    if x == 0.0 { return -1.0 / 0.0 }
    if x == 1.0 / 0.0 { return x }
    // x = m * 2^k, m in [1, 2)
    var m = x
    var k = 0
    while m >= 2.0 {
        m = m / 2.0
        k += 1
    }
    while m < 1.0 {
        m = m * 2.0
        k -= 1
    }
    // ln(m) = 2 atanh((m-1)/(m+1))
    let z = (m - 1.0) / (m + 1.0)
    let z2 = z * z
    var term = z
    var sum = 0.0
    var i = 1
    while i < 60 {
        sum = sum + term / float(i)
        term = term * z2
        i += 2
    }
    return 2.0 * sum + float(k) * 0.6931471805599453
}

const PI = 3.141592653589793

fn sin(x0: float) -> float {
    if x0 != x0 || x0 == 1.0 / 0.0 || x0 == -1.0 / 0.0 { return nan() }
    var x = x0 - (x0 / (2.0 * PI)).floor() * 2.0 * PI     // [0, 2pi)
    if x > PI { x = x - 2.0 * PI }
    var term = x
    var sum = x
    for i in 1..14 {
        term = 0.0 - term * x * x / float((2 * i) * (2 * i + 1))
        sum = sum + term
    }
    return sum
}

fn cos(x: float) -> float { return sin(x + PI / 2.0) }

fn atan(x: float) -> float {
    if x != x { return x }
    if x < 0.0 { return 0.0 - atan(0.0 - x) }
    if x > 1.0 { return PI / 2.0 - atan(1.0 / x) }
    // reduce: atan(x) = 2 atan(x / (1 + sqrt(1 + x^2)))
    let y = x / (1.0 + (1.0 + x * x).sqrt())
    var term = y
    var sum = 0.0
    let y2 = y * y
    var i = 1
    var sign = 1.0
    while i < 60 {
        sum = sum + sign * term / float(i)
        term = term * y2
        sign = 0.0 - sign
        i += 2
    }
    return 2.0 * sum
}

fn atan2(y: float, x: float) -> float {
    if x > 0.0 { return atan(y / x) }
    if x < 0.0 { return if y >= 0.0 { atan(y / x) + PI } else { atan(y / x) - PI } }
    if y > 0.0 { return PI / 2.0 }
    if y < 0.0 { return 0.0 - PI / 2.0 }
    return 0.0
}
