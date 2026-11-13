// The JavaScript standard library for js.st: the global object, the built-in prototypes, and every
// built-in function, dispatched by name.

import kernel
import js
import jsparse
import jsre

const U = 0

// a[i..] (empty if there's nothing there)
fn rest_of(a: [js.Val], i: int) -> [js.Val] {
    var out: [js.Val] = []
    var k = i
    while k < a.len() {
        out.push(a[k])
        k += 1
    }
    return out
}

fn arg(a: [js.Val], i: int) -> js.Val { return if i < a.len() { a[i] } else { js.undef() } }

// ---- setting up a global object ----

fn setup(host: js.Host) -> js.Interp {
    let objp = js.Obj { id: 1 }
    let global = js.Obj { id: 2 }
    let genv = js.Env { obj: some(global) }
    let it = js.Interp { global, genv, host, next_id: 3 }
    it.protos["Object"] = objp
    global.proto = some(objp)
    it.natives = (f: js.Obj, t: js.Val, a: [js.Val], n: bool) => native(it, f, t, a, n)
    for name in ["Function", "Array", "String", "Number", "Boolean", "Error", "RegExp", "Date", "Map", "Set", "Promise", "Symbol"] {
        let p = js.Obj { id: it.next_id, proto: some(objp) }
        it.next_id += 1
        it.protos[name] = p
    }
    obj_get(it, "Array").cls = "Array"
    obj_get(it, "Function").cls = "Function"
    obj_get(it, "Function").native = "Function.prototype"
    for name in ["TypeError", "RangeError", "SyntaxError", "ReferenceError", "EvalError", "URIError", "AggregateError"] {
        let p = js.Obj { id: it.next_id, proto: it.protos.get("Error") }
        it.next_id += 1
        it.protos[name] = p
    }
    // constructors and their prototypes
    let ctors = ["Object", "Function", "Array", "String", "Number", "Boolean", "Error", "TypeError", "RangeError", "SyntaxError",
        "ReferenceError", "EvalError", "URIError", "AggregateError", "RegExp", "Date", "Map", "Set", "Promise", "Symbol"]
    for name in ctors {
        let c = it.native(name, 1)
        let co = js.obj_of(c)
        let p = obj_get(it, name)
        co.props["prototype"] = js.object(p)
        co.hidden.add("prototype")
        p.props["constructor"] = c
        p.hidden.add("constructor")
        global.props[name] = c
        global.hidden.add(name)
        if p.proto.is_some() && name.ends_with("Error") && name != "Error" {
            co.proto = some(js.obj_of(global.props.get("Error") ?? js.undef()))
            p.props["name"] = js.string(name)
            p.hidden.add("name")
        }
    }
    let errp = obj_get(it, "Error")
    errp.props["name"] = js.string("Error")
    errp.props["message"] = js.string("")
    errp.hidden.add("name")
    errp.hidden.add("message")
    let statics = {
        "Object": ["keys", "values", "entries", "assign", "freeze", "isFrozen", "seal", "preventExtensions", "create", "getPrototypeOf", "setPrototypeOf",
            "defineProperty", "defineProperties", "getOwnPropertyNames", "fromEntries", "is", "getOwnPropertyDescriptor"],
        "Array": ["isArray", "from", "of"],
        "String": ["fromCharCode", "fromCodePoint"],
        "Number": ["isInteger", "isNaN", "isFinite", "isSafeInteger", "parseFloat", "parseInt"],
        "Promise": ["resolve", "reject", "all", "race", "allSettled", "any"],
        "Date": ["now", "parse", "UTC"],
        "Symbol": ["for"],
    }
    for cname in statics.keys() {
        let co = js.obj_of(global.props.get(cname) ?? js.undef())
        for m in statics.get(cname) ?? [] { it.method(co, m, "${cname}.${m}", 1) }
    }
    let methods = {
        "Object": ["hasOwnProperty", "toString", "valueOf", "isPrototypeOf", "propertyIsEnumerable", "toLocaleString"],
        "Function": ["call", "apply", "bind", "toString"],
        "Array": ["push", "pop", "shift", "unshift", "slice", "splice", "concat", "join", "reverse", "indexOf", "lastIndexOf", "includes",
            "find", "findIndex", "findLast", "findLastIndex", "filter", "map", "forEach", "reduce", "reduceRight", "some", "every", "sort",
            "flat", "flatMap", "fill", "keys", "values", "entries", "at", "toString", "copyWithin", "toReversed", "toSorted", "with"],
        "String": ["charAt", "charCodeAt", "codePointAt", "indexOf", "lastIndexOf", "includes", "startsWith", "endsWith", "slice",
            "substring", "substr", "toUpperCase", "toLowerCase", "toLocaleUpperCase", "toLocaleLowerCase", "trim", "trimStart", "trimEnd", "trimLeft", "trimRight", "split",
            "replace", "replaceAll", "match", "matchAll", "search", "padStart", "padEnd", "repeat", "concat", "at", "toString", "valueOf",
            "localeCompare", "normalize"],
        "Number": ["toFixed", "toString", "toPrecision", "valueOf", "toLocaleString"],
        "Boolean": ["toString", "valueOf"],
        "Error": ["toString"],
        "RegExp": ["test", "exec", "toString"],
        "Date": ["getTime", "valueOf", "getFullYear", "getMonth", "getDate", "getDay", "getHours", "getMinutes", "getSeconds",
            "getMilliseconds", "getUTCFullYear", "getUTCMonth", "getUTCDate", "getUTCDay", "getUTCHours", "getUTCMinutes", "getUTCSeconds",
            "toISOString", "toJSON", "toString", "toDateString", "toTimeString", "toLocaleDateString", "toLocaleTimeString", "toLocaleString",
            "getTimezoneOffset", "setTime", "toGMTString", "toUTCString", "setFullYear", "setMonth", "setDate", "setHours", "setMinutes", "setSeconds", "setMilliseconds"],
        "Map": ["get", "set", "has", "delete", "clear", "forEach", "keys", "values", "entries"],
        "Set": ["add", "has", "delete", "clear", "forEach", "values", "keys", "entries"],
        "Promise": ["then", "catch", "finally"],
        "Symbol": ["toString"],
    }
    for cname in methods.keys() {
        let p = obj_get(it, cname)
        for m in methods.get(cname) ?? [] { it.method(p, m, "${cname}.prototype.${m}", 1) }
    }
    for cname in ["Map", "Set"] { obj_get(it, cname).getters["size"] = it.native("${cname}.prototype.size", 0) }
    obj_get(it, "Array").props["@@iterator"] = it.native("Array.prototype.values", 0)
    obj_get(it, "Array").hidden.add("@@iterator")
    let sym = js.obj_of(global.props.get("Symbol") ?? js.undef())
    sym.props["iterator"] = js.string("@@iterator")
    sym.props["asyncIterator"] = js.string("@@asyncIterator")
    sym.props["toPrimitive"] = js.string("@@toPrimitive")
    sym.props["hasInstance"] = js.string("@@hasInstance")
    sym.props["toStringTag"] = js.string("@@toStringTag")
    // Number's constants
    let numc = js.obj_of(global.props.get("Number") ?? js.undef())
    numc.props["MAX_SAFE_INTEGER"] = js.num(9007199254740991.0)
    numc.props["MIN_SAFE_INTEGER"] = js.num(-9007199254740991.0)
    numc.props["EPSILON"] = js.num(2.220446049250313e-16)
    numc.props["MAX_VALUE"] = js.num(1.7976931348623157e308)
    numc.props["MIN_VALUE"] = js.num(5e-324)
    numc.props["POSITIVE_INFINITY"] = js.num(1.0 / 0.0)
    numc.props["NEGATIVE_INFINITY"] = js.num(-1.0 / 0.0)
    numc.props["NaN"] = js.num(js.nan())
    // Math, JSON, console, Reflect-lite
    let math = it.plain()
    for m in ["abs", "floor", "ceil", "round", "trunc", "sign", "max", "min", "pow", "sqrt", "cbrt", "random", "log", "log2", "log10", "log1p",
        "exp", "expm1", "sin", "cos", "tan", "atan", "atan2", "asin", "acos", "hypot", "fround", "imul", "clz32", "sinh", "cosh", "tanh"] {
        it.method(math, m, "Math.${m}", 1)
    }
    math.props["PI"] = js.num(js.PI)
    math.props["E"] = js.num(2.718281828459045)
    math.props["LN2"] = js.num(0.6931471805599453)
    math.props["LN10"] = js.num(2.302585092994046)
    math.props["LOG2E"] = js.num(1.4426950408889634)
    math.props["LOG10E"] = js.num(0.4342944819032518)
    math.props["SQRT2"] = js.num(1.4142135623730951)
    math.props["SQRT1_2"] = js.num(0.7071067811865476)
    global.props["Math"] = js.object(math)
    let json = it.plain()
    it.method(json, "parse", "JSON.parse", 2)
    it.method(json, "stringify", "JSON.stringify", 3)
    global.props["JSON"] = js.object(json)
    let console = it.plain()
    for m in ["log", "info", "warn", "error", "debug", "table", "dir", "trace", "group", "groupEnd", "groupCollapsed", "time", "timeEnd", "assert", "count"] {
        it.method(console, m, "console.${m}", 1)
    }
    global.props["console"] = js.object(console)
    for f in ["parseInt", "parseFloat", "isNaN", "isFinite", "encodeURIComponent", "decodeURIComponent", "encodeURI", "decodeURI",
        "setTimeout", "setInterval", "clearTimeout", "clearInterval", "queueMicrotask", "requestAnimationFrame", "cancelAnimationFrame",
        "structuredClone", "eval"] {
        global.props[f] = it.native(f, 1)
        global.hidden.add(f)
    }
    global.props["globalThis"] = js.object(global)
    global.props["window"] = js.object(global)
    global.props["self"] = js.object(global)
    for k in ["globalThis", "window", "self", "Math", "JSON", "console"] { global.hidden.add(k) }
    return it
}

fn obj_get(it: js.Interp, name: str) -> js.Obj { return it.protos.get(name) ?? js.Obj { id: 0 } }

// ---- the built-ins ----

fn native(it: js.Interp, f: js.Obj, this: js.Val, a: [js.Val], is_new: bool) -> js.Val {
    let name = f.native
    if name.starts_with("dom.") { return it.host.call(name, this, a) }
    if name.starts_with("Promise.") { return promise_native(it, f, name, this, a) }
    if name.starts_with("Array.prototype.") { return array_method(it, name.slice(16, name.len()), this, a) }
    if name.starts_with("String.prototype.") { return string_method(it, name.slice(17, name.len()), this, a) }
    if name.starts_with("Math.") { return math(it, name.slice(5, name.len()), a) }
    if name.starts_with("Object.") { return object_fn(it, name, this, a) }
    if name.starts_with("Date") { return date_fn(it, name, this, a, is_new) }
    if name.starts_with("Map.") || name.starts_with("Set.") { return collection(it, name, this, a) }
    if name.starts_with("console.") {
        let level = name.slice(8, name.len())
        if level == "groupEnd" || level == "time" || level == "group" && a.is_empty() { return js.undef() }
        if level == "assert" {
            if it.truthy(arg(a, 0)) { return js.undef() }
            it.host.log("error", "Assertion failed: " + a.slice(1, a.len()).map(x => show(it, x, 0)).join(" "))
            return js.undef()
        }
        it.host.log(if level == "warn" || level == "error" { level } else { "log" }, a.map(x => show(it, x, 0)).join(" "))
        return js.undef()
    }
    // constructors
    if name == "Object" {
        let v = arg(a, 0)
        if v.t == js.OBJ { return v }
        return js.object(it.plain())
    }
    if name == "Array" {
        if a.len() == 1 && a[0].t == js.NUM {
            let n = int(a[0].n)
            if n < 0 || n > 10_000_000 || float(n) != a[0].n { return it.throw_err("RangeError", "invalid array length") }
            var items: [js.Val] = []
            for i in 0..n { items.push(js.undef()) }
            return it.array(items)
        }
        return it.array(a)
    }
    if name == "String" {
        let v = arg(a, 0)
        if a.is_empty() { return js.string("") }
        return js.string(it.to_str(v))
    }
    if name == "Number" { return js.num(if a.is_empty() { 0.0 } else { it.to_num(a[0]) }) }
    if name == "Boolean" { return js.boolean(it.truthy(arg(a, 0))) }
    if name == "Symbol" {
        it.next_id += 1
        return js.string("@@symbol:${it.next_id}:${if a.is_empty() { "" } else { it.to_str(a[0]) }}")
    }
    if name == "Symbol.for" { return js.string("@@symbol:" + it.to_str(arg(a, 0))) }
    if name == "Function" { return it.throw_err("EvalError", "new Function() isn't allowed") }
    if name == "eval" { return it.throw_err("EvalError", "eval() isn't allowed") }
    if name.ends_with("Error") && !name.contains(".") {
        // a constructor call, or super(message) from a subclass
        var e = it.error(name, if a.is_empty() { "" } else { it.to_str(a[0]) })
        if this.t == js.OBJ && !is_new {
            let o = js.obj_of(this)
            if o.cls == "Object" {
                o.cls = "Error"
                o.props["message"] = js.string(if a.is_empty() { "" } else { it.to_str(a[0]) })
                o.hidden.add("message")
                o.props["stack"] = js.string("")
                o.hidden.add("stack")
                return this
            }
        }
        if a.is_empty() { js.obj_of(e).props.remove("message") }
        return e
    }
    if name == "RegExp" {
        let p = arg(a, 0)
        if let po = p.o {
            if po.cls == "RegExp" { return it.make_regexp((po.prim ?? js.undef()).s, if a.len() > 1 { it.to_str(a[1]) } else { po.flags }) }
        }
        return it.make_regexp(it.to_str(p), if a.len() > 1 { it.to_str(a[1]) } else { "" })
    }
    if name == "Map" || name == "Set" {
        let o = it.new_obj(name)
        o.cls = name
        let init = arg(a, 0)
        if init.t != js.UNDEFINED && init.t != js.NULL {
            for x in it.iterate(init) {
                if name == "Map" { map_set(it, o, it.get(x, "0"), it.get(x, "1")) } else { map_set(it, o, x, x) }
            }
        }
        return js.object(o)
    }
    if name == "Promise" {
        let exec = arg(a, 0)
        if !it.is_fn(exec) { return it.throw_err("TypeError", "Promise resolver is not a function") }
        let p = it.new_promise()
        let res = it.native("Promise.resolver", 1)
        js.obj_of(res).prim = some(js.object(p))
        let rej = it.native("Promise.rejecter", 1)
        js.obj_of(rej).prim = some(js.object(p))
        it.call(exec, js.undef(), [res, rej])
        if it.ctl == 4 {
            let r = it.cval
            it.ctl = 0
            it.settle(p, "rejected", r)
        }
        return js.object(p)
    }
    // Function.prototype
    if name == "Function.prototype" { return js.undef() }
    if name == "Function.prototype.call" { return it.call(this, arg(a, 0), rest_of(a, 1)) }
    if name == "Function.prototype.apply" {
        var argv: [js.Val] = []
        let l = arg(a, 1)
        if l.t == js.OBJ { argv = it.iterate(l) }
        return it.call(this, arg(a, 0), argv)
    }
    if name == "Function.prototype.bind" {
        if !it.is_fn(this) { return it.throw_err("TypeError", "bind must be called on a function") }
        let b = it.new_obj("Function")
        b.cls = "Function"
        b.bound = some(this)
        b.this_val = some(arg(a, 0))
        b.bound_args = rest_of(a, 1)
        b.props["name"] = js.string("bound " + it.to_str(it.get(this, "name")))
        b.hidden.add("name")
        return js.object(b)
    }
    if name == "Function.prototype.toString" { return js.string("function ${it.to_str(it.get(this, "name"))}() { [code] }") }
    // Number, Boolean
    if name.starts_with("Number.prototype.") || name.starts_with("Boolean.prototype.") { return number_method(it, name, this, a) }
    if name.starts_with("Number.") {
        let m = name.slice(7, name.len())
        let v = arg(a, 0)
        if m == "parseFloat" || m == "parseInt" { return global_fn(it, m, a) }
        if v.t != js.NUM { return js.boolean(false) }
        if m == "isNaN" { return js.boolean(v.n != v.n) }
        let finite = v.n == v.n && v.n != 1.0 / 0.0 && v.n != -1.0 / 0.0
        if m == "isFinite" { return js.boolean(finite) }
        if m == "isInteger" { return js.boolean(finite && v.n == v.n.floor()) }
        if m == "isSafeInteger" { return js.boolean(finite && v.n == v.n.floor() && v.n <= 9007199254740991.0 && v.n >= -9007199254740991.0) }
    }
    if name == "Error.prototype.toString" {
        let n = it.to_str(it.get(this, "name"))
        let m = it.to_str(it.get(this, "message"))
        return js.string(if m == "" { n } else { "${n}: ${m}" })
    }
    if name == "Symbol.prototype.toString" { return js.string("Symbol()") }
    if name.starts_with("RegExp.prototype.") { return regexp_method(it, name.slice(17, name.len()), this, a) }
    if name.starts_with("String.") {
        var out: [str] = []
        for x in a {
            let c = int(it.to_num(x))
            out.push(if c > 0 && c <= 0x10ffff { st_chr(c) } else { "" })
        }
        return js.string(out.join(""))
    }
    if name.starts_with("Array.") {
        let m = name.slice(6, name.len())
        if m == "isArray" {
            if let o = arg(a, 0).o { return js.boolean(o.cls == "Array") }
            return js.boolean(false)
        }
        if m == "of" { return it.array(a) }
        if m == "from" {
            let src = arg(a, 0)
            var items: [js.Val] = []
            if src.t == js.STR || is_iterable(it, src) {
                items = it.iterate(src)
            } else if src.t == js.OBJ {
                let n = int(it.to_num(it.get(src, "length")))
                if n > 0 && n < 10_000_000 { for i in 0..n { items.push(it.get(src, str(i))) } }
            }
            let mapf = arg(a, 1)
            if it.is_fn(mapf) {
                var mapped: [js.Val] = []
                for i, x in items {
                    mapped.push(it.call(mapf, js.undef(), [x, js.int_v(i)]))
                    if it.ctl != 0 { return js.undef() }
                }
                items = mapped
            }
            return it.array(items)
        }
    }
    if name.starts_with("JSON.") {
        if name == "JSON.stringify" {
            var indent = ""
            let sp = arg(a, 2)
            if sp.t == js.NUM { indent = " ".repeat(min(max(int(sp.n), 0), 10)) }
            if sp.t == js.STR { indent = sp.s.slice(0, min(sp.s.len(), 10)) }
            var stack: [int] = []
            let out = stringify(it, arg(a, 0), indent, "", stack, arg(a, 1))
            if it.ctl != 0 { return js.undef() }
            if out == "@@omit@@" { return js.undef() }
            return it.make_string(out)
        }
        let p = JsonParser { it, s: it.to_str(arg(a, 0)) }
        let v = p.value()
        p.space()
        if p.error == "" && p.i < p.s.len() { p.error = "unexpected text after JSON" }
        if p.error != "" { return it.throw_err("SyntaxError", "JSON.parse: ${p.error}") }
        return v
    }
    return global_fn(it, name, a)
}

fn is_iterable(it: js.Interp, v: js.Val) -> bool {
    if let o = v.o {
        if o.cls == "Array" || o.cls == "Map" || o.cls == "Set" || o.cls == "Arguments" { return true }
        if it.is_fn(it.get(v, "@@iterator")) { return true }
        if o.host != 0 { return true }
    }
    return false
}

extern fn st_chr(code: int) -> str
extern fn st_ord(s: str) -> int

fn global_fn(it: js.Interp, name: str, a: [js.Val]) -> js.Val {
    if name == "parseFloat" {
        let s = it.to_str(arg(a, 0)).trim()
        var end = 0
        let cs = s.chars()
        var seen_dot = false
        var seen_e = false
        while end < cs.len() {
            let c = cs[end]
            if "0123456789".contains(c) {
                end += 1
            } else if (c == "-" || c == "+") && (end == 0 || cs[end - 1] == "e" || cs[end - 1] == "E") {
                end += 1
            } else if c == "." && !seen_dot && !seen_e {
                seen_dot = true
                end += 1
            } else if (c == "e" || c == "E") && !seen_e && end > 0 {
                seen_e = true
                end += 1
            } else {
                break
            }
        }
        if s.starts_with("Infinity") || s.starts_with("+Infinity") { return js.num(1.0 / 0.0) }
        if s.starts_with("-Infinity") { return js.num(-1.0 / 0.0) }
        // back off a trailing e/sign
        while end > 0 && "eE+-".contains(cs[end - 1]) { end -= 1 }
        if end == 0 { return js.num(js.nan()) }
        return js.num(float(cs.slice(0, end).join("")) catch js.nan())
    }
    if name == "parseInt" {
        var s = it.to_str(arg(a, 0)).trim().lower()
        var radix = if a.len() > 1 { int(it.to_num(a[1])) } else { 0 }
        var neg = false
        if s.starts_with("-") || s.starts_with("+") {
            neg = s.starts_with("-")
            s = s.slice(1, s.len())
        }
        if (radix == 0 || radix == 16) && s.starts_with("0x") {
            radix = 16
            s = s.slice(2, s.len())
        }
        if radix == 0 { radix = 10 }
        if radix < 2 || radix > 36 { return js.num(js.nan()) }
        var v = 0.0
        var any = false
        for c in s.chars() {
            let d = "0123456789abcdefghijklmnopqrstuvwxyz".find(c)
            if d < 0 || d >= radix { break }
            v = v * float(radix) + float(d)
            any = true
        }
        if !any { return js.num(js.nan()) }
        return js.num(if neg { 0.0 - v } else { v })
    }
    if name == "isNaN" {
        let n = it.to_num(arg(a, 0))
        return js.boolean(n != n)
    }
    if name == "isFinite" {
        let n = it.to_num(arg(a, 0))
        return js.boolean(n == n && n != 1.0 / 0.0 && n != -1.0 / 0.0)
    }
    if name == "encodeURIComponent" || name == "encodeURI" {
        let s = it.to_str(arg(a, 0))
        let keep = if name == "encodeURI" { "-_.!~*'();/?:@&=+$,#" } else { "-_.!~*'()" }
        var out: [str] = []
        for b in utf8_bytes(s) {
            let c = st_chr(b)
            if (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b < 128 && keep.contains(c)) {
                out.push(c)
            } else {
                out.push("%" + hex2(b))
            }
        }
        return js.string(out.join(""))
    }
    if name == "decodeURIComponent" || name == "decodeURI" {
        let s = it.to_str(arg(a, 0))
        var bytes: [int] = []
        let raw = utf8_bytes(s)
        var i = 0
        while i < raw.len() {
            if raw[i] == 37 && i + 2 < raw.len() {
                let h = jsre.hexd(raw[i + 1]) * 16 + jsre.hexd(raw[i + 2])
                if jsre.hexd(raw[i + 1]) < 0 || jsre.hexd(raw[i + 2]) < 0 { return it.throw_err("URIError", "URI malformed") }
                bytes.push(h)
                i += 3
            } else {
                bytes.push(raw[i])
                i += 1
            }
        }
        return js.string(from_bytes(bytes))
    }
    if name == "setTimeout" || name == "setInterval" || name == "requestAnimationFrame" {
        let f = arg(a, 0)
        if !it.is_fn(f) { return js.int_v(0) }
        let ms = if name == "requestAnimationFrame" { 16 } else { int(it.to_num(arg(a, 1))) }
        let extra = if name != "requestAnimationFrame" { rest_of(a, 2) } else { rest_of(a, 99) }
        return js.int_v(it.host.timer(f, max(if ms != ms { 0 } else { ms }, 0), name == "setInterval", if name == "requestAnimationFrame" { [js.num(float(kernel.uptime()))] } else { extra }))
    }
    if name == "clearTimeout" || name == "clearInterval" || name == "cancelAnimationFrame" {
        it.host.clear(int(it.to_num(arg(a, 0))))
        return js.undef()
    }
    if name == "queueMicrotask" {
        it.jobs.push(js.Job { f: arg(a, 0), argv: [] })
        return js.undef()
    }
    if name == "structuredClone" {
        var stack: [int] = []
        let text = stringify(it, arg(a, 0), "", "", stack, js.undef())
        let p = JsonParser { it, s: text }
        return p.value()
    }
    return it.throw_err("TypeError", "${name} is not available here")
}

fn hex2(b: int) -> str {
    let d = "0123456789ABCDEF".chars()
    return d[(b >> 4) & 15] + d[b & 15]
}

fn utf8_bytes(s: str) -> [int] {
    var out: [int] = []
    for c in s.chars() {
        let cp = st_ord(c)
        if cp < 0x80 {
            out.push(cp)
        } else if cp < 0x800 {
            out.push(0xc0 | (cp >> 6))
            out.push(0x80 | (cp & 63))
        } else if cp < 0x10000 {
            out.push(0xe0 | (cp >> 12))
            out.push(0x80 | ((cp >> 6) & 63))
            out.push(0x80 | (cp & 63))
        } else {
            out.push(0xf0 | (cp >> 18))
            out.push(0x80 | ((cp >> 12) & 63))
            out.push(0x80 | ((cp >> 6) & 63))
            out.push(0x80 | (cp & 63))
        }
    }
    return out
}

fn from_bytes(b: [int]) -> str {
    if b.is_empty() { return "" }
    let mem = kernel.alloc(b.len())
    for i, x in b { kernel.poke8(mem + i, if x == 0 { 32 } else { x }) }
    return kernel.read_str(mem, b.len())
}

// ---- Object ----

fn object_fn(it: js.Interp, name: str, this: js.Val, a: [js.Val]) -> js.Val {
    let v = arg(a, 0)
    if name == "Object.prototype.hasOwnProperty" {
        let k = it.key_of(v)
        if let o = this.o {
            if o.cls == "Array" {
                let i = js.index_of_key(k)
                if i >= 0 { return js.boolean(i < o.arr.len()) }
            }
            return js.boolean(o.props.contains(k) || o.getters.contains(k))
        }
        if this.t == js.STR { return js.boolean(js.index_of_key(k) >= 0 && js.index_of_key(k) < js.str_len(this.s)) }
        return js.boolean(false)
    }
    if name == "Object.prototype.toString" {
        if this.t == js.UNDEFINED { return js.string("[object Undefined]") }
        if this.t == js.NULL { return js.string("[object Null]") }
        if let o = this.o {
            if o.cls == "Array" { return js.string(join(it, o.arr, ",")) }
            if o.cls == "Function" { return js.string("[object Function]") }
            if o.cls == "Error" { return native(it, js.Obj { id: 0, native: "Error.prototype.toString" }, this, [], false) }
        }
        return js.string("[object Object]")
    }
    if name == "Object.prototype.toLocaleString" { return js.string(it.to_str(this)) }
    if name == "Object.prototype.valueOf" { return this }
    if name == "Object.prototype.isPrototypeOf" {
        if let p = this.o {
            var cur = it.proto_of(v)
            while true {
                if let c = cur {
                    if c.id == p.id { return js.boolean(true) }
                    cur = c.proto
                } else {
                    break
                }
            }
        }
        return js.boolean(false)
    }
    if name == "Object.prototype.propertyIsEnumerable" {
        if let o = this.o { return js.boolean(it.keys(o).contains(it.key_of(v))) }
        return js.boolean(false)
    }
    if name == "Object.is" {
        let b = arg(a, 1)
        if v.t == js.NUM && b.t == js.NUM {
            if v.n != v.n && b.n != b.n { return js.boolean(true) }
            if v.n == 0.0 && b.n == 0.0 { return js.boolean((1.0 / v.n > 0.0) == (1.0 / b.n > 0.0)) }
        }
        return js.boolean(js.strict_eq(v, b))
    }
    if name == "Object.create" {
        let o = it.plain()
        o.proto = v.o
        let props = arg(a, 1)
        if props.t == js.OBJ { define_props(it, o, props) }
        return js.object(o)
    }
    if name == "Object.getPrototypeOf" {
        if let p = it.proto_of(v) { return js.object(p) }
        return js.null_v()
    }
    if name == "Object.setPrototypeOf" {
        if let o = v.o { o.proto = arg(a, 1).o }
        return v
    }
    if v.t == js.UNDEFINED || v.t == js.NULL {
        if name == "Object.freeze" || name == "Object.isFrozen" { return v }
        return it.throw_err("TypeError", "cannot convert undefined or null to object")
    }
    let o = v.o ?? js.Obj { id: 0 }
    if name == "Object.keys" || name == "Object.values" || name == "Object.entries" || name == "Object.getOwnPropertyNames" {
        var ks: [str] = []
        if v.t == js.STR {
            for i in 0..js.str_len(v.s) { ks.push(str(i)) }
        } else {
            ks = it.keys(o)
            if name == "Object.getOwnPropertyNames" {
                for k in o.props.keys() { if !ks.contains(k) { ks.push(k) } }
                if o.cls == "Array" { ks.push("length") }
            }
        }
        if name == "Object.keys" || name == "Object.getOwnPropertyNames" { return it.array(ks.map(k => js.string(k))) }
        if name == "Object.values" { return it.array(ks.map(k => it.get(v, k))) }
        return it.array(ks.map(k => it.array([js.string(k), it.get(v, k)])))
    }
    if name == "Object.assign" {
        for i in 1..a.len() {
            let src = a[i]
            if let so = src.o {
                for k in it.keys(so) { it.set(v, k, it.get(src, k)) }
            }
        }
        return v
    }
    if name == "Object.freeze" || name == "Object.seal" || name == "Object.preventExtensions" {
        o.frozen = name == "Object.freeze"
        return v
    }
    if name == "Object.isFrozen" { return js.boolean(o.frozen) }
    if name == "Object.defineProperty" {
        define_prop(it, o, it.key_of(arg(a, 1)), arg(a, 2))
        return v
    }
    if name == "Object.defineProperties" {
        define_props(it, o, arg(a, 1))
        return v
    }
    if name == "Object.getOwnPropertyDescriptor" {
        let k = it.key_of(arg(a, 1))
        if !o.props.contains(k) && !o.getters.contains(k) { return js.undef() }
        let d = it.plain()
        if let g = o.getters.get(k) {
            d.props["get"] = g
            if let s = o.setters.get(k) { d.props["set"] = s }
        } else {
            d.props["value"] = it.get(v, k)
            d.props["writable"] = js.boolean(!o.frozen)
        }
        d.props["enumerable"] = js.boolean(!o.hidden.contains(k))
        d.props["configurable"] = js.boolean(true)
        return js.object(d)
    }
    if name == "Object.fromEntries" {
        let r = it.plain()
        for e in it.iterate(v) { r.props[it.key_of(it.get(e, "0"))] = it.get(e, "1") }
        return js.object(r)
    }
    return js.undef()
}

fn define_props(it: js.Interp, o: js.Obj, props: js.Val) {
    if let po = props.o {
        for k in it.keys(po) { define_prop(it, o, k, it.get(props, k)) }
    }
}

fn define_prop(it: js.Interp, o: js.Obj, key: str, desc: js.Val) {
    let g = it.get(desc, "get")
    let s = it.get(desc, "set")
    if it.is_fn(g) || it.is_fn(s) {
        if it.is_fn(g) { o.getters[key] = g }
        if it.is_fn(s) { o.setters[key] = s }
        o.props.remove(key)
    } else if let dobj = desc.o {
        if dobj.props.contains("value") || dobj.getters.contains("value") {
            if o.cls == "Array" && js.index_of_key(key) >= 0 {
                it.set(js.object(o), key, it.get(desc, "value"))
            } else {
                o.props[key] = it.get(desc, "value")
            }
        }
    }
    if !it.truthy(it.get(desc, "enumerable")) { o.hidden.add(key) } else { o.hidden.remove(key) }
}

// ---- arrays ----

fn join(it: js.Interp, items: [js.Val], sep: str) -> str {
    var parts: [str] = []
    for x in items {
        parts.push(if x.t == js.UNDEFINED || x.t == js.NULL { "" } else { it.to_str(x) })
        if it.ctl != 0 { return "" }
    }
    return parts.join(sep)
}

fn rel_index(n: float, len: int) -> int {
    if n != n { return 0 }
    if n < 0.0 { return max(len + int(max(n, -1.0e15)), 0) }
    return min(int(min(n, 1.0e15)), len)
}

fn array_method(it: js.Interp, m: str, this: js.Val, a: [js.Val]) -> js.Val {
    // array-likes (strings, arguments, NodeLists) borrow these: work on a copy of their items
    var o = this.o ?? js.Obj { id: 0 }
    if o.cls != "Array" {
        if m == "toString" || m == "join" || m == "indexOf" || m == "includes" || m == "slice" || m == "map" || m == "forEach" || m == "filter" ||
            m == "some" || m == "every" || m == "reduce" || m == "find" || m == "findIndex" || m == "values" || m == "keys" || m == "entries" {
            var items: [js.Val] = []
            if this.t == js.STR || is_iterable(it, this) {
                items = it.iterate(this)
            } else if this.t == js.OBJ {
                let n = int(it.to_num(it.get(this, "length")))
                if n > 0 && n < 10_000_000 { for i in 0..n { items.push(it.get(this, str(i))) } }
            }
            o = js.Obj { id: 0, cls: "Array", arr: items }
        } else {
            return it.throw_err("TypeError", "Array.prototype.${m} called on a non-array")
        }
    }
    let arr = o.arr
    let f = arg(a, 0)
    let callback = m == "find" || m == "findIndex" || m == "findLast" || m == "findLastIndex" || m == "filter" || m == "map" || m == "forEach" ||
        m == "some" || m == "every" || m == "flatMap"
    if callback && !it.is_fn(f) { return it.throw_err("TypeError", "${it.to_str(f)} is not a function") }
    let ta = arg(a, 1)
    if m == "push" {
        if o.frozen { return it.throw_err("TypeError", "cannot add to a frozen array") }
        for x in a { arr.push(x) }
        if arr.len() > 10_000_000 { return it.throw_err("RangeError", "array too long") }
        return js.int_v(arr.len())
    }
    if m == "pop" {
        if arr.is_empty() || o.frozen { return js.undef() }
        return arr.pop()
    }
    if m == "shift" {
        if arr.is_empty() || o.frozen { return js.undef() }
        let x = arr[0]
        arr.remove(0)
        return x
    }
    if m == "unshift" {
        var i = a.len() - 1
        while i >= 0 {
            arr.insert(0, a[i])
            i -= 1
        }
        return js.int_v(arr.len())
    }
    if m == "slice" {
        let s = if a.is_empty() { 0 } else { rel_index(it.to_num(a[0]), arr.len()) }
        let e = if a.len() < 2 || a[1].t == js.UNDEFINED { arr.len() } else { rel_index(it.to_num(a[1]), arr.len()) }
        return it.array(if s < e { arr.slice(s, e) } else { rest_of(arr, arr.len()) })
    }
    if m == "splice" {
        let s = if a.is_empty() { arr.len() } else { rel_index(it.to_num(a[0]), arr.len()) }
        let count = if a.len() < 2 { arr.len() - s } else { min(max(int(it.to_num(a[1])), 0), arr.len() - s) }
        var removed: [js.Val] = []
        for i in 0..count {
            removed.push(arr[s])
            arr.remove(s)
        }
        var k = a.len() - 1
        while k >= 2 {
            arr.insert(s, a[k])
            k -= 1
        }
        return it.array(removed)
    }
    if m == "concat" {
        var out: [js.Val] = []
        for x in arr { out.push(x) }
        for x in a {
            if let xo = x.o {
                if xo.cls == "Array" {
                    for y in xo.arr { out.push(y) }
                    continue
                }
            }
            out.push(x)
        }
        return it.array(out)
    }
    if m == "join" || m == "toString" {
        let sep = if m == "toString" || a.is_empty() || a[0].t == js.UNDEFINED { "," } else { it.to_str(a[0]) }
        return it.make_string(join(it, arr, sep))
    }
    if m == "reverse" {
        var i = 0
        var j = arr.len() - 1
        while i < j {
            let t = arr[i]
            arr[i] = arr[j]
            arr[j] = t
            i += 1
            j -= 1
        }
        return this
    }
    if m == "toReversed" {
        var out: [js.Val] = []
        var i = arr.len() - 1
        while i >= 0 {
            out.push(arr[i])
            i -= 1
        }
        return it.array(out)
    }
    if m == "indexOf" || m == "lastIndexOf" || m == "includes" {
        let x = arg(a, 0)
        if m == "lastIndexOf" {
            var i = arr.len() - 1
            while i >= 0 {
                if js.strict_eq(arr[i], x) { return js.int_v(i) }
                i -= 1
            }
            return js.int_v(-1)
        }
        let from = if a.len() > 1 { rel_index(it.to_num(a[1]), arr.len()) } else { 0 }
        for i in from..arr.len() {
            if (m == "includes" && js.same_value_zero(arr[i], x)) || (m == "indexOf" && js.strict_eq(arr[i], x)) {
                return if m == "includes" { js.boolean(true) } else { js.int_v(i) }
            }
        }
        return if m == "includes" { js.boolean(false) } else { js.int_v(-1) }
    }
    if m == "at" {
        var i = int(it.to_num(arg(a, 0)))
        if i < 0 { i += arr.len() }
        return if i >= 0 && i < arr.len() { arr[i] } else { js.undef() }
    }
    if m == "fill" {
        let s = if a.len() > 1 { rel_index(it.to_num(a[1]), arr.len()) } else { 0 }
        let e = if a.len() > 2 && a[2].t != js.UNDEFINED { rel_index(it.to_num(a[2]), arr.len()) } else { arr.len() }
        for i in s..e { arr[i] = arg(a, 0) }
        return this
    }
    if m == "keys" {
        var ks: [js.Val] = []
        for i in 0..arr.len() { ks.push(js.int_v(i)) }
        return it.array(ks)
    }
    if m == "values" { return it.array(arr.slice(0, arr.len())) }
    if m == "entries" {
        var out: [js.Val] = []
        for i, x in arr { out.push(it.array([js.int_v(i), x])) }
        return it.array(out)
    }
    if m == "flat" {
        let depth = if a.is_empty() || a[0].t == js.UNDEFINED { 1 } else { int(it.to_num(a[0])) }
        var out: [js.Val] = []
        flatten(arr, depth, out)
        return it.array(out)
    }
    if m == "sort" || m == "toSorted" {
        var items: [js.Val] = []
        for x in arr { items.push(x) }
        let sorted = merge_sort(it, items, arg(a, 0))
        if it.ctl != 0 { return js.undef() }
        if m == "toSorted" { return it.array(sorted) }
        for i, x in sorted { arr[i] = x }
        return this
    }
    if m == "with" {
        var out: [js.Val] = []
        for x in arr { out.push(x) }
        var i = int(it.to_num(arg(a, 0)))
        if i < 0 { i += out.len() }
        if i < 0 || i >= out.len() { return it.throw_err("RangeError", "invalid index") }
        out[i] = arg(a, 1)
        return it.array(out)
    }
    if m == "copyWithin" { return this }
    if m == "reduce" || m == "reduceRight" {
        if !it.is_fn(f) { return it.throw_err("TypeError", "reduce needs a function") }
        let n = arr.len()
        var acc = js.undef()
        var have = a.len() > 1
        if have { acc = a[1] }
        for step in 0..n {
            let i = if m == "reduce" { step } else { n - 1 - step }
            if i >= arr.len() { continue }
            if !have {
                acc = arr[i]
                have = true
                continue
            }
            acc = it.call(f, js.undef(), [acc, arr[i], js.int_v(i), this])
            if it.ctl != 0 { return js.undef() }
        }
        if !have { return it.throw_err("TypeError", "reduce of an empty array with no initial value") }
        return acc
    }
    // the callback methods
    var out: [js.Val] = []
    let n = arr.len()
    var i = 0
    while i < n {
        let idx = if m == "findLast" || m == "findLastIndex" { n - 1 - i } else { i }
        if idx >= arr.len() { break }
        let x = arr[idx]
        let r = it.call(f, ta, [x, js.int_v(idx), this])
        if it.ctl != 0 { return js.undef() }
        let t = it.truthy(r)
        if (m == "find" || m == "findLast") && t { return x }
        if (m == "findIndex" || m == "findLastIndex") && t { return js.int_v(idx) }
        if m == "filter" && t { out.push(x) }
        if m == "map" { out.push(r) }
        if m == "flatMap" {
            if let ro = r.o {
                if ro.cls == "Array" { for y in ro.arr { out.push(y) } } else { out.push(r) }
            } else {
                out.push(r)
            }
        }
        if m == "some" && t { return js.boolean(true) }
        if m == "every" && !t { return js.boolean(false) }
        i += 1
    }
    if m == "find" || m == "findLast" { return js.undef() }
    if m == "findIndex" || m == "findLastIndex" { return js.int_v(-1) }
    if m == "some" { return js.boolean(false) }
    if m == "every" { return js.boolean(true) }
    if m == "forEach" { return js.undef() }
    return it.array(out)
}

fn flatten(items: [js.Val], depth: int, out: [js.Val]) {
    for x in items {
        if let o = x.o {
            if o.cls == "Array" && depth > 0 {
                flatten(o.arr, depth - 1, out)
                continue
            }
        }
        out.push(x)
    }
}

// a stable merge sort; undefined last; without a comparator, by string
fn merge_sort(it: js.Interp, items: [js.Val], cmp: js.Val) -> [js.Val] {
    if items.len() <= 1 { return items }
    let mid = items.len() / 2
    let left = merge_sort(it, items.slice(0, mid), cmp)
    let right = merge_sort(it, items.slice(mid, items.len()), cmp)
    var out: [js.Val] = []
    var i = 0
    var j = 0
    while i < left.len() && j < right.len() {
        if it.ctl != 0 { return items }
        var take_right = false
        let x = left[i]
        let y = right[j]
        if x.t == js.UNDEFINED {
            take_right = y.t != js.UNDEFINED
        } else if y.t == js.UNDEFINED {
            take_right = false
        } else if it.is_fn(cmp) {
            take_right = it.to_num(it.call(cmp, js.undef(), [x, y])) > 0.0
        } else {
            take_right = it.to_str(x) > it.to_str(y)
        }
        if take_right {
            out.push(y)
            j += 1
        } else {
            out.push(x)
            i += 1
        }
    }
    while i < left.len() {
        out.push(left[i])
        i += 1
    }
    while j < right.len() {
        out.push(right[j])
        j += 1
    }
    return out
}

// ---- strings ----

fn is_ascii(s: str) -> bool { return js.str_len(s) == s.len() }

// a part of s by character positions
fn sub(s: str, a: int, b: int) -> str {
    if a >= b { return "" }
    if is_ascii(s) { return s.slice(max(a, 0), min(b, s.len())) }
    let cs = s.chars()
    return cs.slice(max(a, 0), min(b, cs.len())).join("")
}

// character position of a byte position
fn char_pos(s: str, byte: int) -> int {
    if byte < 0 { return byte }
    return js.str_len(s.slice(0, byte))
}

fn index_from(s: str, needle: str, from: int) -> int {
    if from <= 0 { return char_pos(s, s.find(needle)) }
    let rest = sub(s, from, js.str_len(s))
    let i = rest.find(needle)
    if i < 0 { return -1 }
    return from + char_pos(rest, i)
}

fn string_method(it: js.Interp, m: str, this: js.Val, a: [js.Val]) -> js.Val {
    if this.t == js.UNDEFINED || this.t == js.NULL { return it.throw_err("TypeError", "String.prototype.${m} called on ${it.to_str(this)}") }
    let s = it.to_str(this)
    let n = js.str_len(s)
    let x = arg(a, 0)
    if m == "toString" || m == "valueOf" { return js.string(s) }
    if m == "charAt" || m == "at" {
        var i = int(it.to_num(x))
        if m == "at" && i < 0 { i += n }
        let c = js.char_at(s, i)
        if m == "at" && c == "" { return js.undef() }
        return js.string(c)
    }
    if m == "charCodeAt" || m == "codePointAt" {
        let c = js.char_at(s, if a.is_empty() { 0 } else { int(it.to_num(x)) })
        if c == "" { return if m == "charCodeAt" { js.num(js.nan()) } else { js.undef() } }
        return js.int_v(st_ord(c))
    }
    if m == "indexOf" { return js.int_v(index_from(s, it.to_str(x), if a.len() > 1 { int(it.to_num(a[1])) } else { 0 })) }
    if m == "lastIndexOf" {
        let needle = it.to_str(x)
        var last = -1
        var from = 0
        while true {
            let i = index_from(s, needle, from)
            if i < 0 { break }
            last = i
            from = i + 1
            if from > n { break }
        }
        return js.int_v(last)
    }
    if m == "includes" {
        if let xo = x.o { if xo.cls == "RegExp" { return it.throw_err("TypeError", "the argument to includes can't be a RegExp") } }
        return js.boolean(index_from(s, it.to_str(x), if a.len() > 1 { int(it.to_num(a[1])) } else { 0 }) >= 0)
    }
    if m == "startsWith" {
        let p = if a.len() > 1 { int(it.to_num(a[1])) } else { 0 }
        return js.boolean(sub(s, p, n).starts_with(it.to_str(x)))
    }
    if m == "endsWith" {
        let e = if a.len() > 1 && a[1].t != js.UNDEFINED { min(int(it.to_num(a[1])), n) } else { n }
        return js.boolean(sub(s, 0, e).ends_with(it.to_str(x)))
    }
    if m == "slice" {
        let b = if a.is_empty() { 0 } else { rel_index(it.to_num(a[0]), n) }
        let e = if a.len() < 2 || a[1].t == js.UNDEFINED { n } else { rel_index(it.to_num(a[1]), n) }
        return js.string(sub(s, b, e))
    }
    if m == "substring" {
        var b = if a.is_empty() { 0 } else { min(max(int(it.to_num(a[0])), 0), n) }
        var e = if a.len() < 2 || a[1].t == js.UNDEFINED { n } else { min(max(int(it.to_num(a[1])), 0), n) }
        if b > e {
            let t = b
            b = e
            e = t
        }
        return js.string(sub(s, b, e))
    }
    if m == "substr" {
        let b = if a.is_empty() { 0 } else { rel_index(it.to_num(a[0]), n) }
        let len = if a.len() < 2 || a[1].t == js.UNDEFINED { n - b } else { max(int(it.to_num(a[1])), 0) }
        return js.string(sub(s, b, min(b + len, n)))
    }
    if m == "toUpperCase" || m == "toLocaleUpperCase" { return js.string(s.upper()) }
    if m == "toLowerCase" || m == "toLocaleLowerCase" { return js.string(s.lower()) }
    if m == "trim" { return js.string(s.trim()) }
    if m == "trimStart" || m == "trimLeft" { return js.string(s.trim_start()) }
    if m == "trimEnd" || m == "trimRight" { return js.string(s.trim_end()) }
    if m == "padStart" || m == "padEnd" {
        let target = int(it.to_num(x))
        let fill = if a.len() > 1 && a[1].t != js.UNDEFINED { it.to_str(a[1]) } else { " " }
        if target <= n || fill == "" || target > 100_000 { return js.string(s) }
        var pad = ""
        while js.str_len(pad) < target - n { pad = pad + fill }
        pad = sub(pad, 0, target - n)
        return js.string(if m == "padStart" { pad + s } else { s + pad })
    }
    if m == "repeat" {
        let c = int(it.to_num(x))
        if c < 0 { return it.throw_err("RangeError", "invalid count value") }
        if c * s.len() > js.MAX_STRING { return it.throw_err("RangeError", "string too long") }
        return js.string(s.repeat(c))
    }
    if m == "concat" {
        var out = s
        for y in a { out = out + it.to_str(y) }
        return it.make_string(out)
    }
    if m == "localeCompare" {
        let t = it.to_str(x)
        return js.int_v(if s < t { -1 } else if s > t { 1 } else { 0 })
    }
    if m == "normalize" { return js.string(s) }
    if m == "split" {
        let limit = if a.len() > 1 && a[1].t != js.UNDEFINED { int(it.to_num(a[1])) } else { 1 << 30 }
        if x.t == js.UNDEFINED { return it.array([js.string(s)]) }
        var parts: [js.Val] = []
        if let re = it.regex_of(x) {
            let cps = jsre.code_points(s)
            var last = 0
            var from = 0
            while from <= cps.len() && parts.len() < limit {
                let r = jsre.exec(re, cps, from)
                if r.is_empty() { break }
                if r[1] == r[0] {
                    if r[0] >= cps.len() { break }
                    if r[0] == last {
                        from = r[0] + 1
                        continue
                    }
                }
                parts.push(js.string(cp_sub(s, cps, last, r[0])))
                for g in 1..re.groups {
                    if r[2 * g] >= 0 { parts.push(js.string(cp_sub(s, cps, r[2 * g], r[2 * g + 1]))) } else { parts.push(js.undef()) }
                }
                last = r[1]
                from = if r[1] > r[0] { r[1] } else { r[1] + 1 }
            }
            if parts.len() < limit { parts.push(js.string(cp_sub(s, cps, last, cps.len()))) }
            return it.array(parts)
        }
        let sep = it.to_str(x)
        if sep == "" {
            for c in s.chars() {
                if parts.len() >= limit { break }
                parts.push(js.string(c))
            }
            return it.array(parts)
        }
        for p in s.split(sep) {
            if parts.len() >= limit { break }
            parts.push(js.string(p))
        }
        return it.array(parts)
    }
    if m == "replace" || m == "replaceAll" {
        let rep = arg(a, 1)
        if let re = it.regex_of(x) {
            let global = js.obj_of(x).flags.contains("g")
            if m == "replaceAll" && !global { return it.throw_err("TypeError", "replaceAll needs a global RegExp") }
            let cps = jsre.code_points(s)
            var out: [str] = []
            var last = 0
            var from = 0
            while from <= cps.len() {
                let r = jsre.exec(re, cps, from)
                if r.is_empty() { break }
                out.push(cp_sub(s, cps, last, r[0]))
                out.push(replacement(it, rep, s, cps, r, re))
                if it.ctl != 0 { return js.undef() }
                last = r[1]
                if !global { break }
                from = if r[1] > r[0] { r[1] } else { r[1] + 1 }
                if r[1] == r[0] && r[0] < cps.len() { out.push(cp_sub(s, cps, r[0], r[0] + 1)) }
                if r[1] == r[0] { last = min(r[0] + 1, cps.len()) }
            }
            out.push(cp_sub(s, cps, last, cps.len()))
            return it.make_string(out.join(""))
        }
        let needle = it.to_str(x)
        let cps = jsre.code_points(s)
        let ncp = jsre.code_points(needle)
        var out: [str] = []
        var last = 0
        var from = 0
        while true {
            let i = index_from(s, needle, from)
            if i < 0 { break }
            out.push(cp_sub(s, cps, last, i))
            out.push(replacement(it, rep, s, cps, [i, i + ncp.len()], jsre.Re {}))
            if it.ctl != 0 { return js.undef() }
            last = i + ncp.len()
            if m == "replace" { break }
            from = if ncp.is_empty() { i + 1 } else { last }
            if from > cps.len() { break }
        }
        out.push(cp_sub(s, cps, last, cps.len()))
        return it.make_string(out.join(""))
    }
    if m == "match" || m == "matchAll" || m == "search" {
        let rv = if x.t == js.OBJ { x } else { it.make_regexp(if x.t == js.UNDEFINED { "" } else { escape_re(it.to_str(x)) }, if m == "matchAll" { "g" } else { "" }) }
        if it.ctl != 0 { return js.undef() }
        if let re = it.regex_of(rv) {
            let cps = jsre.code_points(s)
            if m == "search" {
                let r = jsre.exec(re, cps, 0)
                return js.int_v(if r.is_empty() { -1 } else { r[0] })
            }
            let global = js.obj_of(rv).flags.contains("g")
            if m == "match" && !global {
                let r = jsre.exec(re, cps, 0)
                if r.is_empty() { return js.null_v() }
                return match_array(it, s, cps, r, re)
            }
            var all: [js.Val] = []
            var from = 0
            while from <= cps.len() {
                let r = jsre.exec(re, cps, from)
                if r.is_empty() { break }
                all.push(if m == "matchAll" { match_array(it, s, cps, r, re) } else { js.string(cp_sub(s, cps, r[0], r[1])) })
                from = if r[1] > r[0] { r[1] } else { r[1] + 1 }
            }
            if m == "match" && all.is_empty() { return js.null_v() }
            return it.array(all)
        }
    }
    return it.throw_err("TypeError", "String.prototype.${m} isn't supported")
}

fn escape_re(s: str) -> str {
    var out: [str] = []
    for c in s.chars() {
        if "\\^$.*+?()[]{}|/".contains(c) { out.push("\\") }
        out.push(c)
    }
    return out.join("")
}

fn cp_sub(s: str, cps: [int], a: int, b: int) -> str {
    if a >= b { return "" }
    if cps.len() == s.len() { return s.slice(a, b) }
    var out: [str] = []
    for i in a..b { out.push(st_chr(cps[i])) }
    return out.join("")
}

// what a match is replaced by: a function's result, or a string with $1 $& $<name> $$
fn replacement(it: js.Interp, rep: js.Val, s: str, cps: [int], r: [int], re: jsre.Re) -> str {
    let whole = cp_sub(s, cps, r[0], r[1])
    if it.is_fn(rep) {
        var argv = [js.string(whole)]
        for g in 1..re.groups { argv.push(if r[2 * g] >= 0 { js.string(cp_sub(s, cps, r[2 * g], r[2 * g + 1])) } else { js.undef() }) }
        argv.push(js.int_v(r[0]))
        argv.push(js.string(s))
        return it.to_str(it.call(rep, js.undef(), argv))
    }
    let t = it.to_str(rep)
    if !t.contains("$") { return t }
    var out: [str] = []
    let cs = t.chars()
    var i = 0
    while i < cs.len() {
        let c = cs[i]
        if c == "$" && i + 1 < cs.len() {
            let d = cs[i + 1]
            if d == "$" {
                out.push("$")
                i += 2
                continue
            }
            if d == "&" {
                out.push(whole)
                i += 2
                continue
            }
            if d == "`" {
                out.push(cp_sub(s, cps, 0, r[0]))
                i += 2
                continue
            }
            if d == "'" {
                out.push(cp_sub(s, cps, r[1], cps.len()))
                i += 2
                continue
            }
            if "0123456789".contains(d) {
                var g = int(d) catch 0
                var used = 2
                if i + 2 < cs.len() && "0123456789".contains(cs[i + 2]) {
                    let g2 = g * 10 + (int(cs[i + 2]) catch 0)
                    if g2 < re.groups {
                        g = g2
                        used = 3
                    }
                }
                if g >= 1 && g < re.groups {
                    if r[2 * g] >= 0 { out.push(cp_sub(s, cps, r[2 * g], r[2 * g + 1])) }
                    i += used
                    continue
                }
            }
            if d == "<" {
                let close = index_in(cs, ">", i)
                if close > 0 {
                    let nm = cs.slice(i + 2, close).join("")
                    if let g = re.names.get(nm) { if r[2 * g] >= 0 { out.push(cp_sub(s, cps, r[2 * g], r[2 * g + 1])) } }
                    i = close + 1
                    continue
                }
            }
        }
        out.push(c)
        i += 1
    }
    return out.join("")
}

fn index_in(cs: [str], what: str, from: int) -> int {
    var i = from
    while i < cs.len() {
        if cs[i] == what { return i }
        i += 1
    }
    return -1
}

fn match_array(it: js.Interp, s: str, cps: [int], r: [int], re: jsre.Re) -> js.Val {
    var items: [js.Val] = []
    for g in 0..re.groups {
        items.push(if r[2 * g] >= 0 { js.string(cp_sub(s, cps, r[2 * g], r[2 * g + 1])) } else { js.undef() })
    }
    let arr = it.array(items)
    let o = js.obj_of(arr)
    o.props["index"] = js.int_v(r[0])
    o.props["input"] = js.string(s)
    if !re.names.is_empty() {
        let groups = it.plain()
        for nm in re.names.keys() {
            let g = re.names.get(nm) ?? 0
            groups.props[nm] = if r[2 * g] >= 0 { js.string(cp_sub(s, cps, r[2 * g], r[2 * g + 1])) } else { js.undef() }
        }
        o.props["groups"] = js.object(groups)
    } else {
        o.props["groups"] = js.undef()
    }
    return arr
}

fn regexp_method(it: js.Interp, m: str, this: js.Val, a: [js.Val]) -> js.Val {
    let o = this.o ?? js.Obj { id: 0 }
    if o.cls != "RegExp" { return it.throw_err("TypeError", "RegExp.prototype.${m} called on a non-RegExp") }
    if m == "toString" { return js.string("/${(o.prim ?? js.undef()).s}/${o.flags}") }
    if let re = it.regex_of(this) {
        let s = it.to_str(arg(a, 0))
        let cps = jsre.code_points(s)
        let sticky = o.flags.contains("g") || o.flags.contains("y")
        let from = if sticky { int(it.to_num(it.get(this, "lastIndex"))) } else { 0 }
        if from > cps.len() {
            it.set(this, "lastIndex", js.int_v(0))
            return if m == "test" { js.boolean(false) } else { js.null_v() }
        }
        let r = jsre.exec(re, cps, from)
        if r.is_empty() {
            if sticky { it.set(this, "lastIndex", js.int_v(0)) }
            return if m == "test" { js.boolean(false) } else { js.null_v() }
        }
        if sticky { it.set(this, "lastIndex", js.int_v(if r[1] > r[0] { r[1] } else { r[1] + 1 })) }
        if m == "test" { return js.boolean(true) }
        return match_array(it, s, cps, r, re)
    }
    return js.undef()
}

// ---- numbers ----

fn number_method(it: js.Interp, name: str, this: js.Val, a: [js.Val]) -> js.Val {
    let m = name.slice(name.find("prototype.") + 10, name.len())
    var v = this
    if let o = this.o { v = o.prim ?? this }
    if name.starts_with("Boolean") { return if m == "valueOf" { v } else { js.string(it.to_str(v)) } }
    let n = it.to_num(v)
    if m == "valueOf" { return js.num(n) }
    if m == "toString" {
        let radix = if a.is_empty() || a[0].t == js.UNDEFINED { 10 } else { int(it.to_num(a[0])) }
        if radix == 10 || n != n || n == 1.0 / 0.0 || n == -1.0 / 0.0 { return js.string(jsparse.num_text(n)) }
        if radix < 2 || radix > 36 { return it.throw_err("RangeError", "toString() radix must be between 2 and 36") }
        var x = if n < 0.0 { 0.0 - n } else { n }
        var whole = x.floor()
        var frac = x - whole
        var digits: [str] = []
        let d = "0123456789abcdefghijklmnopqrstuvwxyz".chars()
        if whole == 0.0 { digits.push("0") }
        while whole >= 1.0 && digits.len() < 1100 {
            let q = (whole / float(radix)).floor()
            let r = int(whole - q * float(radix))
            digits.insert(0, d[r])
            whole = q
        }
        var out = digits.join("")
        if frac > 0.0 {
            var fd: [str] = []
            while frac > 0.0 && fd.len() < 20 {
                frac = frac * float(radix)
                let dig = int(frac.floor())
                fd.push(d[dig])
                frac = frac - float(dig)
            }
            out = out + "." + fd.join("")
        }
        return js.string(if n < 0.0 { "-" + out } else { out })
    }
    if m == "toFixed" {
        let digits = min(max(if a.is_empty() { 0 } else { int(it.to_num(a[0])) }, 0), 20)
        return js.string(fixed(n, digits))
    }
    if m == "toPrecision" {
        if a.is_empty() || a[0].t == js.UNDEFINED { return js.string(jsparse.num_text(n)) }
        let p = min(max(int(it.to_num(a[0])), 1), 21)
        if n == 0.0 { return js.string(fixed(0.0, p - 1)) }
        var mag = 0
        var x = if n < 0.0 { 0.0 - n } else { n }
        while x >= 10.0 {
            x = x / 10.0
            mag += 1
        }
        while x < 1.0 {
            x = x * 10.0
            mag -= 1
        }
        return js.string(fixed(n, max(p - 1 - mag, 0)))
    }
    if m == "toLocaleString" {
        // 1234567.891 -> 1,234,567.891
        let t = jsparse.num_text(n)
        let neg = t.starts_with("-")
        let body = if neg { t.slice(1, t.len()) } else { t }
        let dot = body.find(".")
        let ip = if dot >= 0 { body.slice(0, dot) } else { body }
        var groups: [str] = []
        var rest = ip
        while rest.len() > 3 {
            groups.insert(0, rest.slice(rest.len() - 3, rest.len()))
            rest = rest.slice(0, rest.len() - 3)
        }
        groups.insert(0, rest)
        var frac = if dot >= 0 { body.slice(dot, min(body.len(), dot + 4)) } else { "" }
        return js.string((if neg { "-" } else { "" }) + groups.join(",") + frac)
    }
    return js.undef()
}

fn fixed(n: float, digits: int) -> str {
    if n != n { return "NaN" }
    if n >= 1.0e21 || n <= -1.0e21 { return jsparse.num_text(n) }
    let neg = n < 0.0
    var x = if neg { 0.0 - n } else { n }
    var scale = 1.0
    for i in 0..digits { scale = scale * 10.0 }
    let scaled = (x * scale + 0.5).floor()
    let whole = (scaled / scale).floor()
    var frac = int(scaled - whole * scale)
    var out = jsparse.num_text(whole)
    if digits > 0 {
        var fs = str(frac)
        while fs.len() < digits { fs = "0" + fs }
        out = out + "." + fs
    }
    return if neg && scaled != 0.0 { "-" + out } else { out }
}

fn math(it: js.Interp, m: str, a: [js.Val]) -> js.Val {
    if m == "random" {
        // xorshift, seeded by the host (the RNG): fine for games, not for secrets
        var x = it.rand
        x = x ^ (x << 13)
        x = x ^ ((x >> 7) & 0x01ff_ffff_ffff_ffff)
        x = x ^ (x << 17)
        it.rand = x
        return js.num(float((x >> 11) & 0x1f_ffff_ffff_ffff) / 9007199254740992.0)
    }
    if m == "max" || m == "min" {
        var r = if m == "max" { -1.0 / 0.0 } else { 1.0 / 0.0 }
        for v in a {
            let x = it.to_num(v)
            if x != x { return js.num(js.nan()) }
            if (m == "max" && x > r) || (m == "min" && x < r) { r = x }
        }
        return js.num(r)
    }
    if m == "hypot" {
        var sum = 0.0
        for v in a {
            let x = it.to_num(v)
            sum = sum + x * x
        }
        return js.num(sum.sqrt())
    }
    let x = it.to_num(arg(a, 0))
    let y = it.to_num(arg(a, 1))
    if m == "abs" { return js.num(if x < 0.0 { 0.0 - x } else { x }) }
    if m == "floor" { return js.num(if x != x || x == 1.0 / 0.0 || x == -1.0 / 0.0 { x } else { x.floor() }) }
    if m == "ceil" { return js.num(if x != x || x == 1.0 / 0.0 || x == -1.0 / 0.0 { x } else { (0.0 - x).floor() * -1.0 + 0.0 }) }
    if m == "round" { return js.num(if x != x || x == 1.0 / 0.0 || x == -1.0 / 0.0 { x } else { (x + 0.5).floor() }) }
    if m == "trunc" { return js.num(if x != x || x == 1.0 / 0.0 || x == -1.0 / 0.0 { x } else if x < 0.0 { (0.0 - x).floor() * -1.0 } else { x.floor() }) }
    if m == "sign" { return js.num(if x > 0.0 { 1.0 } else if x < 0.0 { -1.0 } else { x }) }
    if m == "sqrt" { return js.num(if x < 0.0 { js.nan() } else { x.sqrt() }) }
    if m == "cbrt" { return js.num(if x < 0.0 { 0.0 - js.pow(0.0 - x, 1.0 / 3.0) } else { js.pow(x, 1.0 / 3.0) }) }
    if m == "pow" { return js.num(js.pow(x, y)) }
    if m == "log" { return js.num(js.ln(x)) }
    if m == "log2" { return js.num(js.ln(x) / 0.6931471805599453) }
    if m == "log10" { return js.num(js.ln(x) / 2.302585092994046) }
    if m == "log1p" { return js.num(js.ln(1.0 + x)) }
    if m == "exp" { return js.num(js.exp(x)) }
    if m == "expm1" { return js.num(js.exp(x) - 1.0) }
    if m == "sin" { return js.num(js.sin(x)) }
    if m == "cos" { return js.num(js.cos(x)) }
    if m == "tan" { return js.num(js.sin(x) / js.cos(x)) }
    if m == "atan" { return js.num(js.atan(x)) }
    if m == "atan2" { return js.num(js.atan2(x, y)) }
    if m == "asin" { return js.num(js.atan2(x, (1.0 - x * x).sqrt())) }
    if m == "acos" { return js.num(js.atan2((1.0 - x * x).sqrt(), x)) }
    if m == "sinh" { return js.num((js.exp(x) - js.exp(0.0 - x)) / 2.0) }
    if m == "cosh" { return js.num((js.exp(x) + js.exp(0.0 - x)) / 2.0) }
    if m == "tanh" {
        let e2 = js.exp(2.0 * x)
        return js.num((e2 - 1.0) / (e2 + 1.0))
    }
    if m == "fround" { return js.num(x) }
    if m == "imul" { return js.int_v(js.to_int32(float(js.to_int32(x) * js.to_int32(y)))) }
    if m == "clz32" {
        var v = js.to_int32(x) & 0xffff_ffff
        var c = 32
        while v != 0 {
            v = v >> 1
            c -= 1
        }
        return js.int_v(c)
    }
    return js.num(js.nan())
}

// ---- Map and Set ----

fn map_key(it: js.Interp, k: js.Val) -> str {
    if k.t == js.OBJ { return "o:${js.obj_of(k).id}" }
    if k.t == js.NUM {
        if k.n != k.n { return "n:NaN" }
        return "n:" + jsparse.num_text(k.n)
    }
    if k.t == js.STR { return "s:" + k.s }
    if k.t == js.BOOL { return "b:${k.n}" }
    return "u:${k.t}"
}

fn map_set(it: js.Interp, o: js.Obj, k: js.Val, v: js.Val) {
    let key = map_key(it, k)
    o.map[key] = v
    o.mkeys[key] = k
}

fn collection(it: js.Interp, name: str, this: js.Val, a: [js.Val]) -> js.Val {
    let o = this.o ?? js.Obj { id: 0 }
    let m = name.slice(name.find("prototype.") + 10, name.len())
    if o.cls != "Map" && o.cls != "Set" { return it.throw_err("TypeError", "${name} called on the wrong kind of object") }
    let k = arg(a, 0)
    if m == "size" { return js.int_v(o.map.len()) }
    if m == "get" { return o.map.get(map_key(it, k)) ?? js.undef() }
    if m == "set" {
        map_set(it, o, k, arg(a, 1))
        return this
    }
    if m == "add" {
        map_set(it, o, k, k)
        return this
    }
    if m == "has" { return js.boolean(o.map.contains(map_key(it, k))) }
    if m == "delete" {
        let key = map_key(it, k)
        let had = o.map.contains(key)
        o.map.remove(key)
        o.mkeys.remove(key)
        return js.boolean(had)
    }
    if m == "clear" {
        o.map = {}
        o.mkeys = {}
        return js.undef()
    }
    if m == "forEach" {
        for key in o.map.keys() {
            let v = o.map.get(key) ?? js.undef()
            it.call(k, arg(a, 1), [v, o.mkeys.get(key) ?? js.undef(), this])
            if it.ctl != 0 { return js.undef() }
        }
        return js.undef()
    }
    var out: [js.Val] = []
    for key in o.map.keys() {
        let kv = o.mkeys.get(key) ?? js.undef()
        let vv = o.map.get(key) ?? js.undef()
        if m == "keys" { out.push(kv) }
        if m == "values" { out.push(vv) }
        if m == "entries" { out.push(it.array([kv, vv])) }
    }
    return it.array(out)
}

// ---- promises ----

fn promise_native(it: js.Interp, f: js.Obj, name: str, this: js.Val, a: [js.Val]) -> js.Val {
    if name == "Promise.resolver" || name == "Promise.rejecter" {
        if let pv = f.prim {
            let p = js.obj_of(pv)
            if name == "Promise.resolver" { it.resolve_with(p, arg(a, 0)) } else { it.settle(p, "rejected", arg(a, 0)) }
        }
        return js.undef()
    }
    if name == "Promise.reaction" {
        // [handler, state, value]: run the handler, settle the child promise with its result
        let child = js.obj_of(f.prim ?? js.undef())
        let handler = f.bound_args[0]
        let state = f.bound_args[1].s
        let value = f.bound_args[2]
        if !it.is_fn(handler) {
            if state == "fulfilled" { it.resolve_with(child, value) } else { it.settle(child, "rejected", value) }
            return js.undef()
        }
        let r = it.call(handler, js.undef(), [value])
        if it.ctl == 4 {
            let error_val = it.cval
            it.ctl = 0
            it.settle(child, "rejected", error_val)
        } else {
            it.resolve_with(child, r)
        }
        return js.undef()
    }
    if name == "Promise.prototype.then" || name == "Promise.prototype.catch" || name == "Promise.prototype.finally" {
        let p = this.o ?? js.Obj { id: 0 }
        if p.cls != "Promise" { return it.throw_err("TypeError", "${name} called on a non-promise") }
        if name.ends_with("then") { return it.then(p, arg(a, 0), arg(a, 1)) }
        if name.ends_with("catch") { return it.then(p, js.undef(), arg(a, 0)) }
        let fin = arg(a, 0)
        // finally: run the callback, pass the result through
        let wrap = it.native("Promise.finally_wrap", 1)
        js.obj_of(wrap).prim = some(fin)
        let wrapr = it.native("Promise.finally_wrap_reject", 1)
        js.obj_of(wrapr).prim = some(fin)
        return it.then(p, wrap, wrapr)
    }
    if name == "Promise.finally_wrap" || name == "Promise.finally_wrap_reject" {
        let fin = f.prim ?? js.undef()
        if it.is_fn(fin) { it.call(fin, js.undef(), []) }
        if it.ctl != 0 { return js.undef() }
        if name == "Promise.finally_wrap_reject" { return it.throw_val(arg(a, 0)) }
        return arg(a, 0)
    }
    if name == "Promise.resolve" { return it.promise_resolved(arg(a, 0)) }
    if name == "Promise.reject" { return it.promise_rejected(arg(a, 0)) }
    if name == "Promise.all" || name == "Promise.allSettled" || name == "Promise.race" || name == "Promise.any" {
        let items = it.iterate(arg(a, 0))
        if it.ctl != 0 { return js.undef() }
        let result = it.new_promise()
        let values: [js.Val] = []
        for x in items { values.push(js.undef()) }
        let counter = [items.len()]
        if items.is_empty() && name != "Promise.race" {
            if name == "Promise.any" { it.settle(result, "rejected", it.error("AggregateError", "all promises were rejected")) } else { it.settle(result, "fulfilled", it.array([])) }
            return js.object(result)
        }
        // one results array and one countdown, shared by every element's callbacks
        let st = js.obj_of(it.array(values))
        let left = it.array([js.int_v(items.len())])
        for i, x in items {
            let p = js.obj_of(it.promise_resolved(x))
            let on_ok = it.native("Promise.combine", 1)
            let bad = it.native("Promise.combine", 1)
            js.obj_of(on_ok).prim = some(js.object(result))
            js.obj_of(on_ok).bound_args = [js.string(name), js.string("ok"), js.int_v(i), js.object(st), left]
            js.obj_of(bad).prim = some(js.object(result))
            js.obj_of(bad).bound_args = [js.string(name), js.string("bad"), js.int_v(i), js.object(st), left]
            it.then(p, on_ok, bad)
        }
        return js.object(result)
    }
    if name == "Promise.combine" {
        let result = js.obj_of(f.prim ?? js.undef())
        let kind = f.bound_args[0].s
        let which = f.bound_args[1].s
        let i = int(f.bound_args[2].n)
        let vals = js.obj_of(f.bound_args[3])
        let left = js.obj_of(f.bound_args[4])
        let v = arg(a, 0)
        if result.state != "pending" { return js.undef() }
        if kind == "Promise.race" {
            if which == "ok" { it.resolve_with(result, v) } else { it.settle(result, "rejected", v) }
            return js.undef()
        }
        if kind == "Promise.all" && which == "bad" {
            it.settle(result, "rejected", v)
            return js.undef()
        }
        if kind == "Promise.any" && which == "ok" {
            it.resolve_with(result, v)
            return js.undef()
        }
        if kind == "Promise.allSettled" {
            let rec = it.plain()
            rec.props["status"] = js.string(if which == "ok" { "fulfilled" } else { "rejected" })
            rec.props[if which == "ok" { "value" } else { "reason" }] = v
            vals.arr[i] = js.object(rec)
        } else {
            vals.arr[i] = v
        }
        let n = left.arr[0].n - 1.0
        left.arr[0] = js.num(n)
        if n == 0.0 {
            if kind == "Promise.any" { it.settle(result, "rejected", it.error("AggregateError", "all promises were rejected")) } else { it.settle(result, "fulfilled", js.object(vals)) }
        }
        return js.undef()
    }
    return js.undef()
}

// ---- dates ----

struct Civil {
    y: int,
    m: int,
    d: int,
}

fn civil(days: int) -> Civil {
    let z = days + 719468
    let era = (if z >= 0 { z } else { z - 146096 }) / 146097
    let doe = z - era * 146097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = if mp < 10 { mp + 3 } else { mp - 9 }
    return Civil { y: if m <= 2 { y + 1 } else { y }, m, d }
}

fn days_from(y0: int, m: int, d: int) -> int {
    let y = if m <= 2 { y0 - 1 } else { y0 }
    let era = (if y >= 0 { y } else { y - 399 }) / 400
    let yoe = y - era * 400
    let mp = (m + 9) % 12
    let doy = (153 * mp + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

fn two(n: int) -> str { return if n < 10 { "0${n}" } else { str(n) } }

// "2024-03-05", "2024-03-05T10:20:30Z" (and with milliseconds): ms since 1970, or NaN
fn parse_date(s: str) -> float {
    let t = s.trim()
    if t.len() < 10 || t.slice(4, 5) != "-" || t.slice(7, 8) != "-" { return js.nan() }
    let y = int(t.slice(0, 4)) catch -1
    let mo = int(t.slice(5, 7)) catch -1
    let d = int(t.slice(8, 10)) catch -1
    if y < 0 || mo < 1 || mo > 12 || d < 1 || d > 31 { return js.nan() }
    var ms = float(days_from(y, mo, d)) * 86400000.0
    if t.len() >= 16 && (t.slice(10, 11) == "T" || t.slice(10, 11) == " ") {
        let hh = int(t.slice(11, 13)) catch 0
        let mm = int(t.slice(14, 16)) catch 0
        var ss = 0
        if t.len() >= 19 { ss = int(t.slice(17, 19)) catch 0 }
        ms = ms + float(hh * 3600 + mm * 60 + ss) * 1000.0
        if t.len() >= 23 && t.slice(19, 20) == "." { ms = ms + float(int(t.slice(20, 23)) catch 0) }
    }
    return ms
}

fn date_fn(it: js.Interp, name: str, this: js.Val, a: [js.Val], is_new: bool) -> js.Val {
    if name == "Date.now" { return js.num(float(kernel.time_ms())) }
    if name == "Date.parse" { return js.num(parse_date(it.to_str(arg(a, 0)))) }
    if name == "Date.UTC" {
        let y = int(it.to_num(arg(a, 0)))
        let mo = if a.len() > 1 { int(it.to_num(a[1])) } else { 0 }
        let d = if a.len() > 2 { int(it.to_num(a[2])) } else { 1 }
        let hh = if a.len() > 3 { int(it.to_num(a[3])) } else { 0 }
        let mm = if a.len() > 4 { int(it.to_num(a[4])) } else { 0 }
        let ss = if a.len() > 5 { int(it.to_num(a[5])) } else { 0 }
        return js.num(float(days_from(y, mo + 1, d)) * 86400000.0 + float(hh * 3600 + mm * 60 + ss) * 1000.0)
    }
    if name == "Date" {
        var t = float(kernel.time_ms())
        if a.len() == 1 {
            if a[0].t == js.STR { t = parse_date(a[0].s) } else if let ao = a[0].o { t = (ao.prim ?? js.num(0.0)).n } else { t = it.to_num(a[0]) }
        } else if a.len() >= 2 {
            t = date_fn(it, "Date.UTC", js.undef(), a, false).n
        }
        if !is_new { return js.string(date_text(t)) }
        let d = it.new_obj("Date")
        d.cls = "Date"
        d.prim = some(js.num(t))
        return js.object(d)
    }
    let o = this.o ?? js.Obj { id: 0 }
    if o.cls != "Date" { return it.throw_err("TypeError", "this is not a Date object") }
    let m = name.slice(name.find("prototype.") + 10, name.len())
    let t = (o.prim ?? js.num(0.0)).n
    if m == "setTime" {
        o.prim = some(js.num(it.to_num(arg(a, 0))))
        return o.prim ?? js.undef()
    }
    if m == "getTime" || m == "valueOf" { return js.num(t) }
    if t != t {
        if m.starts_with("get") { return js.num(js.nan()) }
        return js.string("Invalid Date")
    }
    let ms = int(t)
    let days = (if ms >= 0 { ms } else { ms - 86399999 }) / 86400000
    let in_day = ms - days * 86400000
    let c = civil(days)
    if m == "getFullYear" || m == "getUTCFullYear" { return js.int_v(c.y) }
    if m == "getMonth" || m == "getUTCMonth" { return js.int_v(c.m - 1) }
    if m == "getDate" || m == "getUTCDate" { return js.int_v(c.d) }
    if m == "getDay" || m == "getUTCDay" { return js.int_v(((days % 7) + 11) % 7) }
    if m == "getHours" || m == "getUTCHours" { return js.int_v(in_day / 3600000) }
    if m == "getMinutes" || m == "getUTCMinutes" { return js.int_v(in_day / 60000 % 60) }
    if m == "getSeconds" || m == "getUTCSeconds" { return js.int_v(in_day / 1000 % 60) }
    if m == "getMilliseconds" { return js.int_v(in_day % 1000) }
    if m == "getTimezoneOffset" { return js.int_v(0) }
    if m == "toISOString" || m == "toJSON" {
        return js.string("${c.y}-${two(c.m)}-${two(c.d)}T${two(in_day / 3600000)}:${two(in_day / 60000 % 60)}:${two(in_day / 1000 % 60)}.${str(in_day % 1000 + 1000).slice(1, 4)}Z")
    }
    if m == "toGMTString" || m == "toUTCString" {
        let wd = ((days % 7) + 11) % 7
        return js.string("${DAYS[wd]}, ${two(c.d)} ${MONTHS[c.m - 1]} ${c.y} ${two(in_day / 3600000)}:${two(in_day / 60000 % 60)}:${two(in_day / 1000 % 60)} GMT")
    }
    if m.starts_with("set") {
        // set one field: rebuild the time from the parts
        var y = c.y
        var mo = c.m
        var d = c.d
        var hh = in_day / 3600000
        var mi = in_day / 60000 % 60
        var ss = in_day / 1000 % 60
        var mss = in_day % 1000
        let v = int(it.to_num(arg(a, 0)))
        if m == "setFullYear" { y = v }
        if m == "setMonth" { mo = v + 1 }
        if m == "setDate" { d = v }
        if m == "setHours" { hh = v }
        if m == "setMinutes" { mi = v }
        if m == "setSeconds" { ss = v }
        if m == "setMilliseconds" { mss = v }
        let nt = float(days_from(y, mo, 1) + d - 1) * 86400000.0 + float(hh * 3600 + mi * 60 + ss) * 1000.0 + float(mss)
        o.prim = some(js.num(nt))
        return js.num(nt)
    }
    if m == "toLocaleDateString" || m == "toDateString" { return js.string("${c.d} ${MONTHS[c.m - 1]} ${c.y}") }
    if m == "toLocaleTimeString" || m == "toTimeString" { return js.string("${two(in_day / 3600000)}:${two(in_day / 60000 % 60)}:${two(in_day / 1000 % 60)}") }
    return js.string(date_text(t))
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
const DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

fn date_text(t: float) -> str {
    if t != t { return "Invalid Date" }
    let ms = int(t)
    let days = (if ms >= 0 { ms } else { ms - 86399999 }) / 86400000
    let in_day = ms - days * 86400000
    let c = civil(days)
    let wd = ((days % 7) + 11) % 7
    return "${DAYS[wd]} ${MONTHS[c.m - 1]} ${two(c.d)} ${c.y} ${two(in_day / 3600000)}:${two(in_day / 60000 % 60)}:${two(in_day / 1000 % 60)}"
}

// ---- JSON ----

fn quote(s: str) -> str {
    var out: [str] = ["\""]
    for c in s.chars() {
        if c == "\"" {
            out.push("\\\"")
        } else if c == "\\" {
            out.push("\\\\")
        } else if c == "\n" {
            out.push("\\n")
        } else if c == "\r" {
            out.push("\\r")
        } else if c == "\t" {
            out.push("\\t")
        } else if st_ord(c) < 32 {
            out.push("\\u00" + hex2(st_ord(c)).lower())
        } else {
            out.push(c)
        }
    }
    out.push("\"")
    return out.join("")
}

// JSON text for v ("@@omit@@" for "leave it out": undefined, functions)
fn stringify(it: js.Interp, v0: js.Val, indent: str, cur: str, stack: [int], replacer: js.Val) -> str {
    var v = v0
    if let o = v.o {
        let tj = it.get(v, "toJSON")
        if it.is_fn(tj) { v = it.call(tj, v, []) }
        if let bo = v.o { if bo.prim.is_some() && bo.cls != "Date" && bo.cls != "RegExp" { v = bo.prim ?? v } }
    }
    if it.ctl != 0 { return "" }
    if v.t == js.UNDEFINED || it.is_fn(v) { return "@@omit@@" }
    if v.t == js.NULL { return "null" }
    if v.t == js.BOOL { return if v.n != 0.0 { "true" } else { "false" } }
    if v.t == js.NUM { return if v.n != v.n || v.n == 1.0 / 0.0 || v.n == -1.0 / 0.0 { "null" } else { jsparse.num_text(v.n) } }
    if v.t == js.STR { return quote(v.s) }
    let o = js.obj_of(v)
    if stack.contains(o.id) {
        it.throw_err("TypeError", "converting circular structure to JSON")
        return ""
    }
    if stack.len() > 100 {
        it.throw_err("RangeError", "JSON nesting too deep")
        return ""
    }
    stack.push(o.id)
    let inner = cur + indent
    let nl = if indent == "" { "" } else { "\n" }
    var parts: [str] = []
    var out = ""
    if o.cls == "Array" {
        for x in o.arr {
            let s = stringify(it, x, indent, inner, stack, replacer)
            if it.ctl != 0 { return "" }
            parts.push(if s == "@@omit@@" { "null" } else { s })
        }
        out = if parts.is_empty() { "[]" } else { "[" + nl + parts.map(p => inner + p).join("," + nl) + nl + cur + "]" }
    } else {
        for k in it.keys(o) {
            var x = it.get(v, k)
            if it.is_fn(replacer) { x = it.call(replacer, v, [js.string(k), x]) }
            let s = stringify(it, x, indent, inner, stack, replacer)
            if it.ctl != 0 { return "" }
            if s != "@@omit@@" { parts.push(quote(k) + (if indent == "" { ":" } else { ": " }) + s) }
        }
        out = if parts.is_empty() { "{}" } else { "{" + nl + parts.map(p => inner + p).join("," + nl) + nl + cur + "}" }
    }
    stack.pop()
    return out
}

struct JsonParser {
    it: js.Interp,
    s: str,
    i: int = 0,
    error: str = "",
    depth: int = 0,

    fn c(self) -> str { return if self.i < self.s.len() { self.s.slice(self.i, self.i + 1) } else { "" } }

    fn space(self) {
        while self.i < self.s.len() && " \t\n\r".contains(self.c()) { self.i += 1 }
    }

    fn value(self) -> js.Val {
        self.space()
        let c = self.c()
        if self.error != "" { return js.undef() }
        self.depth += 1
        if self.depth > 500 {
            self.error = "nested too deeply"
            return js.undef()
        }
        var v = js.undef()
        if c == "{" {
            self.i += 1
            let o = self.it.plain()
            self.space()
            if self.c() == "}" {
                self.i += 1
            } else {
                while self.error == "" {
                    self.space()
                    if self.c() != "\"" {
                        self.error = "expected a string key at ${self.i}"
                        break
                    }
                    let k = self.string()
                    self.space()
                    if self.c() != ":" {
                        self.error = "expected ':' at ${self.i}"
                        break
                    }
                    self.i += 1
                    o.props[k] = self.value()
                    self.space()
                    if self.c() == "," {
                        self.i += 1
                        continue
                    }
                    if self.c() == "}" {
                        self.i += 1
                        break
                    }
                    self.error = "expected ',' or '}' at ${self.i}"
                }
            }
            v = js.object(o)
        } else if c == "[" {
            self.i += 1
            var items: [js.Val] = []
            self.space()
            if self.c() == "]" {
                self.i += 1
            } else {
                while self.error == "" {
                    items.push(self.value())
                    self.space()
                    if self.c() == "," {
                        self.i += 1
                        continue
                    }
                    if self.c() == "]" {
                        self.i += 1
                        break
                    }
                    self.error = "expected ',' or ']' at ${self.i}"
                }
            }
            v = self.it.array(items)
        } else if c == "\"" {
            v = js.string(self.string())
        } else if self.s.slice(self.i, min(self.i + 4, self.s.len())) == "true" {
            self.i += 4
            v = js.boolean(true)
        } else if self.s.slice(self.i, min(self.i + 5, self.s.len())) == "false" {
            self.i += 5
            v = js.boolean(false)
        } else if self.s.slice(self.i, min(self.i + 4, self.s.len())) == "null" {
            self.i += 4
            v = js.null_v()
        } else if c == "-" || "0123456789".contains(c) && c != "" {
            let start = self.i
            self.i += 1
            while self.i < self.s.len() && "0123456789.eE+-".contains(self.c()) { self.i += 1 }
            v = js.num(float(self.s.slice(start, self.i)) catch js.nan())
        } else {
            self.error = if c == "" { "unexpected end of JSON" } else { "unexpected '${c}' at ${self.i}" }
        }
        self.depth -= 1
        return v
    }

    fn string(self) -> str {
        self.i += 1
        var parts: [str] = []
        var from = self.i
        while self.i < self.s.len() {
            let c = self.c()
            if c == "\"" {
                parts.push(self.s.slice(from, self.i))
                self.i += 1
                return parts.join("")
            }
            if c == "\\" {
                parts.push(self.s.slice(from, self.i))
                let e = self.s.slice(self.i + 1, min(self.i + 2, self.s.len()))
                self.i += 2
                if e == "n" { parts.push("\n") } else if e == "t" { parts.push("\t") } else if e == "r" { parts.push("\r") } else if e == "b" { parts.push(st_chr(8)) } else if e == "f" { parts.push(st_chr(12)) } else if e == "u" {
                    var v = jsparse.hexnum(self.s.slice(self.i, min(self.i + 4, self.s.len())))
                    self.i += 4
                    if v >= 0xd800 && v <= 0xdbff && self.s.slice(self.i, min(self.i + 2, self.s.len())) == "\\u" {
                        let lo = jsparse.hexnum(self.s.slice(self.i + 2, min(self.i + 6, self.s.len())))
                        if lo >= 0xdc00 && lo <= 0xdfff {
                            v = 0x10000 + ((v - 0xd800) << 10) + (lo - 0xdc00)
                            self.i += 6
                        }
                    }
                    parts.push(jsparse.code_point(v))
                } else {
                    parts.push(e)
                }
                from = self.i
                continue
            }
            self.i += 1
        }
        self.error = "unterminated string"
        return ""
    }
}

// console output: values the way devtools shows them, briefly
fn show(it: js.Interp, v: js.Val, depth: int) -> str {
    if v.t == js.STR { return if depth == 0 { v.s } else { quote(v.s) } }
    if v.t != js.OBJ { return it.to_str(v) }
    let o = js.obj_of(v)
    if o.cls == "Function" { return "ƒ ${it.to_str(it.get(v, "name"))}()" }
    if o.cls == "Error" { return it.to_str(v) }
    if depth > 2 { return if o.cls == "Array" { "[...]" } else { "{...}" } }
    if o.cls == "Array" { return "[" + o.arr.slice(0, min(o.arr.len(), 50)).map(x => show(it, x, depth + 1)).join(", ") + (if o.arr.len() > 50 { ", ..." } else { "" }) + "]" }
    if o.host != 0 { return "<${it.to_str(it.get(v, "tagName")).lower()}>" }
    let ks = it.keys(o)
    return "{" + ks.slice(0, min(ks.len(), 20)).map(k => k + ": " + show(it, it.get(v, k), depth + 1)).join(", ") + "}"
}
