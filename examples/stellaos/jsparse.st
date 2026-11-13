// JavaScript, read: the tokenizer and parser of StellaOS's JavaScript engine (js.st runs the tree).
//
// It reads most of modern JavaScript: let/const, arrow functions, classes (extends, super, static,
// getters/setters), destructuring, spread and rest, default parameters, template literals, optional
// chaining (?.), ??, regular expression literals, for-of/for-in, labels, try/catch/finally,
// async/await (run synchronously). Not: generators, modules (import/export), tagged templates.
// Semicolons can be left out (automatic semicolon insertion).

import html

struct Tok {
    kind: str,                // num, str, name, punc, tmpl, regex, eof
    s: str = "",
    n: float = 0.0,
    nl: bool = false,         // a line break before it
    line: int = 0,
}

struct Ast {
    k: str,
    s: str = "",
    s2: str = "",
    n: float = 0.0,
    kids: [Ast] = [],
    params: [Ast] = [],
    flag: bool = false,
    flag2: bool = false,
    line: int = 0,
}

fn empty() -> Ast { return Ast { k: "empty" } }

const PUNCS = [">>>=", "...", "===", "!==", "**=", "<<=", ">>=", ">>>", "&&=", "||=", "??=",
    "=>", "==", "!=", "<=", ">=", "&&", "||", "??", "?.", "++", "--", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "**", "<<", ">>"]

// keywords after which a / starts a regular expression, not a division
const REGEX_AFTER = ["return", "typeof", "case", "in", "of", "new", "delete", "void", "throw", "instanceof", "else", "do", "yield", "await"]

fn ident_start(c: int) -> bool { return (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 36 || c == 95 || c >= 128 }
fn ident_char(c: int) -> bool { return ident_start(c) || (c >= 48 && c <= 57) }
fn digit(c: int) -> bool { return c >= 48 && c <= 57 }

extern fn st_chr(code: int) -> str

// Split source into tokens. An error is reported as a single "error" token.
fn lex(text: str) -> [Tok] {
    let src = html.Src { s: text, low: text, n: text.len() }
    var out: [Tok] = []
    var i = 0
    var line = 1
    var nl = false
    while i < src.n {
        let c = src.at(i)
        if c == 10 {
            line += 1
            nl = true
            i += 1
            continue
        }
        if c == 32 || c == 9 || c == 13 || c == 11 || c == 12 || c == 0xc2 && src.at(i + 1) == 0xa0 {
            i += if c == 0xc2 { 2 } else { 1 }
            continue
        }
        if c == 0xe2 && src.at(i + 1) == 0x80 && (src.at(i + 2) == 0xa8 || src.at(i + 2) == 0xa9) {
            nl = true                         // U+2028/2029 line separators
            i += 3
            continue
        }
        if c == 0xef && src.at(i + 1) == 0xbb && src.at(i + 2) == 0xbf {
            i += 3                            // a byte-order mark
            continue
        }
        // comments
        if c == 47 && src.at(i + 1) == 47 {
            while i < src.n && src.at(i) != 10 { i += 1 }
            continue
        }
        if c == 47 && src.at(i + 1) == 42 {
            let end = src.find("*/", i + 2)
            let stop = if end < 0 { src.n } else { end + 2 }
            for j in i..stop {
                if src.at(j) == 10 {
                    line += 1
                    nl = true
                }
            }
            i = stop
            continue
        }
        if c == 60 && src.cut(i, i + 4) == "<!--" {
            while i < src.n && src.at(i) != 10 { i += 1 }    // an HTML comment inside a script
            continue
        }
        let t = Tok { kind: "", nl, line }
        nl = false
        if ident_start(c) {
            var j = i
            while j < src.n && ident_char(src.at(j)) { j += 1 }
            t.kind = "name"
            t.s = src.cut(i, j)
            i = j
        } else if digit(c) || (c == 46 && digit(src.at(i + 1))) {
            var j = i
            if c == 48 && (src.at(i + 1) == 120 || src.at(i + 1) == 88 || src.at(i + 1) == 111 || src.at(i + 1) == 79 || src.at(i + 1) == 98 || src.at(i + 1) == 66) {
                let base = if src.at(i + 1) == 120 || src.at(i + 1) == 88 { 16 } else if src.at(i + 1) == 111 || src.at(i + 1) == 79 { 8 } else { 2 }
                j = i + 2
                var v = 0.0
                while j < src.n {
                    let d = src.at(j)
                    if d == 95 {
                        j += 1
                        continue
                    }
                    var dv = -1
                    if d >= 48 && d <= 57 { dv = d - 48 }
                    if d >= 97 && d <= 102 { dv = d - 87 }
                    if d >= 65 && d <= 70 { dv = d - 55 }
                    if dv < 0 || dv >= base { break }
                    v = v * float(base) + float(dv)
                    j += 1
                }
                t.n = v
            } else {
                while j < src.n && (digit(src.at(j)) || src.at(j) == 95) { j += 1 }
                if src.at(j) == 46 {
                    j += 1
                    while j < src.n && (digit(src.at(j)) || src.at(j) == 95) { j += 1 }
                }
                if src.at(j) == 101 || src.at(j) == 69 {
                    var k = j + 1
                    if src.at(k) == 43 || src.at(k) == 45 { k += 1 }
                    if digit(src.at(k)) {
                        j = k
                        while j < src.n && digit(src.at(j)) { j += 1 }
                    }
                }
                t.n = float(src.cut(i, j).replace("_", "")) catch 0.0
            }
            if src.at(j) == 110 { j += 1 }    // BigInt suffix: read as a number
            t.kind = "num"
            i = j
        } else if c == 34 || c == 39 {
            let r = read_string(src, i)
            if r.error != "" { return [Tok { kind: "error", s: r.error, line }] }
            t.kind = "str"
            t.s = r.text
            i = r.end
        } else if c == 96 {
            // a template: find its end (skipping ${ ... } with strings and nested templates in them)
            var j = i + 1
            var depth = 0
            while j < src.n {
                let d = src.at(j)
                if d == 92 {
                    j += 2
                    continue
                }
                if d == 10 { line += 1 }
                if depth == 0 && d == 96 { break }
                if d == 36 && src.at(j + 1) == 123 {
                    depth += 1
                    j += 2
                    continue
                }
                if depth > 0 {
                    if d == 123 { depth += 1 }
                    if d == 125 { depth -= 1 }
                    if d == 34 || d == 39 {
                        let r = read_string(src, j)
                        j = r.end
                        continue
                    }
                    if d == 96 {
                        // a nested template
                        j += 1
                        while j < src.n && src.at(j) != 96 {
                            if src.at(j) == 92 { j += 1 }
                            j += 1
                        }
                    }
                }
                j += 1
            }
            if j >= src.n { return [Tok { kind: "error", s: "unterminated template literal", line }] }
            t.kind = "tmpl"
            t.s = src.cut(i + 1, j)
            i = j + 1
        } else if c == 47 && regex_ok(out) {
            // a regular expression literal
            var j = i + 1
            var in_class = false
            while j < src.n {
                let d = src.at(j)
                if d == 10 { return [Tok { kind: "error", s: "unterminated regular expression", line }] }
                if d == 92 {
                    j += 2
                    continue
                }
                if d == 91 { in_class = true }
                if d == 93 { in_class = false }
                if d == 47 && !in_class { break }
                j += 1
            }
            if j >= src.n { return [Tok { kind: "error", s: "unterminated regular expression", line }] }
            var k = j + 1
            while k < src.n && ident_char(src.at(k)) { k += 1 }
            t.kind = "regex"
            t.s = src.cut(i + 1, j)
            t.n = 0.0
            out.push(t)
            out.push(Tok { kind: "flags", s: src.cut(j + 1, k), line })
            i = k
            continue
        } else {
            var p = ""
            for cand in PUNCS {
                if src.cut(i, i + cand.len()) == cand {
                    p = cand
                    break
                }
            }
            if p == "?." && digit(src.at(i + 2)) { p = "" }    // a ? .5 : b
            if p == "" {
                if !"{}()[];,<>+-*/%&|^!~?:=.@#".contains(st_chr(c)) {
                    return [Tok { kind: "error", s: "unexpected character '${st_chr(c)}'", line }]
                }
                p = st_chr(c)
            }
            t.kind = "punc"
            t.s = p
            i += p.len()
        }
        out.push(t)
    }
    out.push(Tok { kind: "eof", nl: true, line })
    return out
}

fn regex_ok(out: [Tok]) -> bool {
    if out.is_empty() { return true }
    let p = out[out.len() - 1]
    if p.kind == "num" || p.kind == "str" || p.kind == "tmpl" || p.kind == "regex" || p.kind == "flags" { return false }
    if p.kind == "name" { return REGEX_AFTER.contains(p.s) }
    if p.kind == "punc" { return p.s != ")" && p.s != "]" && p.s != "++" && p.s != "--" }
    return true
}

struct StrRead {
    text: str,
    end: int,
    error: str = "",
}

fn read_string(src: html.Src, start: int) -> StrRead {
    let q = src.at(start)
    var parts: [str] = []
    var i = start + 1
    var from = i
    while i < src.n {
        let c = src.at(i)
        if c == q {
            parts.push(src.cut(from, i))
            return StrRead { text: parts.join(""), end: i + 1 }
        }
        if c == 10 { return StrRead { text: "", end: i, error: "unterminated string" } }
        if c == 92 {
            parts.push(src.cut(from, i))
            let e = escape(src, i + 1)
            parts.push(e.text)
            i = e.end
            from = i
            continue
        }
        i += 1
    }
    return StrRead { text: "", end: i, error: "unterminated string" }
}

// one escape sequence after a backslash at `i`
fn escape(src: html.Src, i: int) -> StrRead {
    let c = src.at(i)
    if c == 110 { return StrRead { text: "\n", end: i + 1 } }
    if c == 116 { return StrRead { text: "\t", end: i + 1 } }
    if c == 114 { return StrRead { text: "\r", end: i + 1 } }
    if c == 98 { return StrRead { text: st_chr(8), end: i + 1 } }
    if c == 102 { return StrRead { text: st_chr(12), end: i + 1 } }
    if c == 118 { return StrRead { text: st_chr(11), end: i + 1 } }
    if c == 48 && !digit(src.at(i + 1)) { return StrRead { text: " ", end: i + 1 } }
    if c == 10 { return StrRead { text: "", end: i + 1 } }               // a line continuation
    if c == 13 { return StrRead { text: "", end: if src.at(i + 1) == 10 { i + 2 } else { i + 1 } } }
    if c == 120 {
        let v = hexnum(src.cut(i + 1, i + 3))
        return StrRead { text: code_point(v), end: i + 3 }
    }
    if c == 117 {
        if src.at(i + 1) == 123 {
            let close = src.find("}", i)
            if close < 0 { return StrRead { text: "", end: i + 1 } }
            return StrRead { text: code_point(hexnum(src.cut(i + 2, close))), end: close + 1 }
        }
        var v = hexnum(src.cut(i + 1, i + 5))
        var end = i + 5
        // a surrogate pair 😀
        if v >= 0xd800 && v <= 0xdbff && src.at(end) == 92 && src.at(end + 1) == 117 {
            let lo = hexnum(src.cut(end + 2, end + 6))
            if lo >= 0xdc00 && lo <= 0xdfff {
                v = 0x10000 + ((v - 0xd800) << 10) + (lo - 0xdc00)
                end += 6
            }
        }
        return StrRead { text: code_point(v), end }
    }
    // any other character stands for itself (\' \" \\ \/ ...)
    var j = i + 1
    while j < src.n && (src.at(j) & 0xc0) == 0x80 { j += 1 }
    return StrRead { text: src.cut(i, j), end: j }
}

fn hexnum(s: str) -> int {
    var v = 0
    for ch in s.lower().chars() {
        let d = "0123456789abcdef".find(ch)
        if d < 0 { return v }
        v = v * 16 + d
    }
    return v
}

fn code_point(v: int) -> str {
    if v <= 0 || (v >= 0xd800 && v <= 0xdfff) || v > 0x10ffff { return "�" }
    return st_chr(v)
}

// ---- the parser ----

struct Parser {
    toks: [Tok],
    i: int = 0,
    error: str = "",
    no_in: bool = false,      // `in` isn't an operator here (a for-in head)

    fn tok(self) -> Tok { return self.toks[min(self.i, self.toks.len() - 1)] }
    fn peek(self, k: int) -> Tok { return self.toks[min(self.i + k, self.toks.len() - 1)] }
    fn next(self) -> Tok {
        let t = self.tok()
        if self.i < self.toks.len() - 1 { self.i += 1 }
        return t
    }
    fn is(self, p: str) -> bool {
        let t = self.tok()
        return (t.kind == "punc" || t.kind == "name") && t.s == p
    }
    fn eat(self, p: str) -> bool {
        if self.is(p) {
            self.next()
            return true
        }
        return false
    }
    fn fail(self, msg: str) {
        if self.error == "" { self.error = "line ${self.tok().line}: ${msg}" }
        self.i = self.toks.len() - 1      // stop
    }
    fn expect(self, p: str) {
        if !self.eat(p) {
            let t = self.tok()
            self.fail("expected '${p}' but found ${if t.kind == "eof" { "the end" } else { "'" + t.s + "'" }}")
        }
    }
    // the end of a statement: ;, or a line break, }, or the end (automatic semicolons)
    fn semi(self) {
        if self.eat(";") { return }
        let t = self.tok()
        if t.nl || t.kind == "eof" || (t.kind == "punc" && t.s == "}") { return }
        self.fail("unexpected '${t.s}'")
    }
    fn good(self) -> bool { return self.error == "" }

    fn program(self) -> [Ast] {
        var out: [Ast] = []
        while self.tok().kind != "eof" && self.good() {
            out.push(self.statement())
        }
        return out
    }

    fn statement(self) -> Ast {
        let t = self.tok()
        let line = t.line
        if t.kind == "punc" {
            if t.s == "{" { return self.block() }
            if t.s == ";" {
                self.next()
                return empty()
            }
        }
        if t.kind == "name" {
            let w = t.s
            if (w == "var" || w == "const") || (w == "let" && (self.peek(1).kind == "name" || self.peek(1).s == "[" || self.peek(1).s == "{")) {
                let v = self.var_decl()
                self.semi()
                return v
            }
            if w == "function" || (w == "async" && self.peek(1).s == "function" && !self.peek(1).nl) {
                let f = self.function_expr()
                return Ast { k: "funcdecl", s: f.s, kids: [f], line }
            }
            if w == "class" {
                let c = self.class_expr()
                return Ast { k: "classdecl", s: c.s, kids: [c], line }
            }
            if w == "if" {
                self.next()
                self.expect("(")
                let test = self.expression()
                self.expect(")")
                let then = self.statement()
                var other = empty()
                if self.eat("else") { other = self.statement() }
                return Ast { k: "if", kids: [test, then, other], line }
            }
            if w == "for" { return self.for_statement() }
            if w == "while" {
                self.next()
                self.expect("(")
                let test = self.expression()
                self.expect(")")
                return Ast { k: "while", kids: [test, self.statement()], line }
            }
            if w == "do" {
                self.next()
                let body = self.statement()
                self.expect("while")
                self.expect("(")
                let test = self.expression()
                self.expect(")")
                self.eat(";")
                return Ast { k: "dowhile", kids: [body, test], line }
            }
            if w == "return" {
                self.next()
                var v = empty()
                let n = self.tok()
                if !n.nl && !(n.kind == "punc" && (n.s == ";" || n.s == "}")) && n.kind != "eof" { v = self.expression() }
                self.semi()
                return Ast { k: "return", kids: [v], line }
            }
            if w == "break" || w == "continue" {
                self.next()
                var label = ""
                if self.tok().kind == "name" && !self.tok().nl { label = self.next().s }
                self.semi()
                return Ast { k: w, s: label, line }
            }
            if w == "throw" {
                self.next()
                let v = self.expression()
                self.semi()
                return Ast { k: "throw", kids: [v], line }
            }
            if w == "try" {
                self.next()
                let body = self.block()
                var param = empty()
                var handler = empty()
                var fin = empty()
                if self.eat("catch") {
                    if self.eat("(") {
                        param = self.binding()
                        self.expect(")")
                    }
                    handler = self.block()
                }
                if self.eat("finally") { fin = self.block() }
                return Ast { k: "try", kids: [body, param, handler, fin], line }
            }
            if w == "switch" {
                self.next()
                self.expect("(")
                let disc = self.expression()
                self.expect(")")
                self.expect("{")
                var kids = [disc]
                while !self.is("}") && self.good() && self.tok().kind != "eof" {
                    var test = empty()
                    var dflt = false
                    if self.eat("default") {
                        dflt = true
                    } else {
                        self.expect("case")
                        test = self.expression()
                    }
                    self.expect(":")
                    let c = Ast { k: "case", kids: [test], flag: dflt }
                    while !self.is("case") && !self.is("default") && !self.is("}") && self.good() && self.tok().kind != "eof" {
                        c.kids.push(self.statement())
                    }
                    kids.push(c)
                }
                self.expect("}")
                return Ast { k: "switch", kids, line }
            }
            if w == "debugger" {
                self.next()
                self.semi()
                return empty()
            }
            if w == "import" && self.peek(1).s != "(" && self.peek(1).s != "." {
                self.fail("modules (import) aren't supported")
                return empty()
            }
            if w == "export" {
                self.fail("modules (export) aren't supported")
                return empty()
            }
            // a label
            if self.peek(1).kind == "punc" && self.peek(1).s == ":" && !["true", "false", "null", "this"].contains(w) {
                self.next()
                self.next()
                return Ast { k: "label", s: w, kids: [self.statement()], line }
            }
        }
        let e = self.expression()
        self.semi()
        return Ast { k: "expr", kids: [e], line }
    }

    fn block(self) -> Ast {
        let line = self.tok().line
        self.expect("{")
        var kids: [Ast] = []
        while !self.is("}") && self.good() && self.tok().kind != "eof" { kids.push(self.statement()) }
        self.expect("}")
        return Ast { k: "block", kids, line }
    }

    fn var_decl(self) -> Ast {
        let kind = self.next().s
        let v = Ast { k: "var", s: kind }
        while self.good() {
            let target = self.binding()
            var init = empty()
            if self.eat("=") { init = self.assign() }
            v.kids.push(Ast { k: "decl", kids: [target, init] })
            if !self.eat(",") { break }
        }
        return v
    }

    fn for_statement(self) -> Ast {
        let line = self.tok().line
        self.next()
        if self.is("await") { self.next() }
        self.expect("(")
        var init = empty()
        if !self.is(";") {
            self.no_in = true
            if self.is("var") || self.is("let") || self.is("const") {
                init = self.var_decl()
            } else {
                init = self.expression()
            }
            self.no_in = false
            if self.is("of") || self.is("in") {
                let kind = if self.next().s == "of" { "forof" } else { "forin" }
                let obj = if kind == "forof" { self.assign() } else { self.expression() }
                self.expect(")")
                let target = if init.k == "var" { init } else { to_pattern(init) }
                return Ast { k: kind, kids: [target, obj, self.statement()], line }
            }
        }
        self.expect(";")
        var test = empty()
        if !self.is(";") { test = self.expression() }
        self.expect(";")
        var update = empty()
        if !self.is(")") { update = self.expression() }
        self.expect(")")
        return Ast { k: "for", kids: [init, test, update, self.statement()], line }
    }

    // a binding target: a name, [array pattern] or {object pattern}
    fn binding(self) -> Ast {
        let t = self.tok()
        if t.kind == "name" {
            self.next()
            return Ast { k: "ident", s: t.s, line: t.line }
        }
        if self.is("[") {
            self.next()
            let p = Ast { k: "arrpat" }
            while !self.is("]") && self.good() {
                if self.is(",") {
                    self.next()
                    p.kids.push(Ast { k: "hole" })
                    continue
                }
                if self.eat("...") {
                    p.kids.push(Ast { k: "rest", kids: [self.binding()] })
                } else {
                    var target = self.binding()
                    if self.eat("=") { target = Ast { k: "default", kids: [target, self.assign()] } }
                    p.kids.push(target)
                }
                if !self.is("]") { self.expect(",") }
            }
            self.expect("]")
            return p
        }
        if self.is("{") {
            self.next()
            let p = Ast { k: "objpat" }
            while !self.is("}") && self.good() {
                if self.eat("...") {
                    p.kids.push(Ast { k: "rest", kids: [self.binding()] })
                } else {
                    let key = self.prop_key()
                    var target = Ast { k: "ident", s: key.s }
                    if self.eat(":") { target = self.binding() }
                    if self.eat("=") { target = Ast { k: "default", kids: [target, self.assign()] } }
                    p.kids.push(Ast { k: "patprop", kids: [key, target] })
                }
                if !self.is("}") { self.expect(",") }
            }
            self.expect("}")
            return p
        }
        self.fail("expected a name")
        return empty()
    }

    // ---- expressions ----

    fn expression(self) -> Ast {
        let e = self.assign()
        if self.is(",") {
            let s = Ast { k: "seq", kids: [e] }
            while self.eat(",") { s.kids.push(self.assign()) }
            return s
        }
        return e
    }

    fn assign(self) -> Ast {
        let line = self.tok().line
        // arrow functions: x => ..., (a, b) => ..., async x => ...
        if self.arrow_ahead() { return self.arrow() }
        if self.is("yield") {
            self.fail("generators (yield) aren't supported")
            return empty()
        }
        let left = self.conditional()
        let t = self.tok()
        if t.kind == "punc" && (t.s == "=" || t.s == "+=" || t.s == "-=" || t.s == "*=" || t.s == "/=" || t.s == "%=" || t.s == "**=" || t.s == "<<=" || t.s == ">>=" || t.s == ">>>=" || t.s == "&=" || t.s == "|=" || t.s == "^=" || t.s == "&&=" || t.s == "||=" || t.s == "??=") {
            self.next()
            let target = if t.s == "=" { to_pattern(left) } else { left }
            if target.k != "ident" && target.k != "member" && target.k != "index" && target.k != "arrpat" && target.k != "objpat" {
                self.fail("invalid assignment target")
            }
            return Ast { k: "assign", s: t.s, kids: [target, self.assign()], line }
        }
        return left
    }

    fn arrow_ahead(self) -> bool {
        var j = self.i
        if self.toks[j].kind == "name" && self.toks[j].s == "async" && !self.toks[min(j + 1, self.toks.len() - 1)].nl {
            let n = self.toks[min(j + 1, self.toks.len() - 1)]
            if n.kind == "name" || (n.kind == "punc" && n.s == "(") { j += 1 }
        }
        let t = self.toks[j]
        if t.kind == "name" && !["function", "class", "new", "typeof", "void", "delete", "await", "this", "null", "true", "false"].contains(t.s) {
            let n = self.toks[min(j + 1, self.toks.len() - 1)]
            return n.kind == "punc" && n.s == "=>"
        }
        if t.kind == "punc" && t.s == "(" {
            var depth = 0
            var k = j
            while k < self.toks.len() {
                let x = self.toks[k]
                if x.kind == "punc" && (x.s == "(" || x.s == "[" || x.s == "{") { depth += 1 }
                if x.kind == "punc" && (x.s == ")" || x.s == "]" || x.s == "}") {
                    depth -= 1
                    if depth == 0 { break }
                }
                if x.kind == "eof" { return false }
                k += 1
            }
            let n = self.toks[min(k + 1, self.toks.len() - 1)]
            return n.kind == "punc" && n.s == "=>" && !n.nl
        }
        return false
    }

    fn arrow(self) -> Ast {
        let line = self.tok().line
        let f = Ast { k: "func", flag2: true, line }
        if self.is("async") {
            self.next()
            f.s2 = "async"
        }
        if self.tok().kind == "name" {
            f.params.push(Ast { k: "ident", s: self.next().s })
        } else {
            f.params = self.params()
        }
        self.expect("=>")
        if self.is("{") {
            f.kids = [self.function_body()]
        } else {
            let saved = self.no_in
            self.no_in = false
            f.kids = [self.assign()]
            self.no_in = saved
            f.flag = true                     // an expression body
        }
        return f
    }

    fn params(self) -> [Ast] {
        var ps: [Ast] = []
        self.expect("(")
        while !self.is(")") && self.good() {
            if self.eat("...") {
                ps.push(Ast { k: "rest", kids: [self.binding()] })
            } else {
                var p = self.binding()
                if self.eat("=") { p = Ast { k: "default", kids: [p, self.assign()] } }
                ps.push(p)
            }
            if !self.is(")") { self.expect(",") }
        }
        self.expect(")")
        return ps
    }

    fn function_body(self) -> Ast {
        let saved = self.no_in
        self.no_in = false
        let b = self.block()
        self.no_in = saved
        return b
    }

    fn function_expr(self) -> Ast {
        let line = self.tok().line
        let f = Ast { k: "func", line }
        if self.eat("async") { f.s2 = "async" }
        self.expect("function")
        if self.eat("*") {
            self.fail("generators (function*) aren't supported")
            return f
        }
        if self.tok().kind == "name" { f.s = self.next().s }
        f.params = self.params()
        f.kids = [self.function_body()]
        return f
    }

    fn class_expr(self) -> Ast {
        let line = self.tok().line
        self.expect("class")
        let c = Ast { k: "class", line }
        if self.tok().kind == "name" && !self.is("extends") { c.s = self.next().s }
        var sup = empty()
        if self.eat("extends") { sup = self.unary_or_higher() }
        c.kids = [sup]
        self.expect("{")
        while !self.is("}") && self.good() && self.tok().kind != "eof" {
            if self.eat(";") { continue }
            var is_static = false
            if self.is("static") && !(self.peek(1).s == "(" || self.peek(1).s == "=") {
                self.next()
                is_static = true
                if self.is("{") {
                    // a static block
                    let b = self.block()
                    c.params.push(Ast { k: "staticblock", kids: [b] })
                    continue
                }
            }
            var kind = "method"
            if (self.is("get") || self.is("set")) && !(self.peek(1).s == "(" || self.peek(1).s == "=" || self.peek(1).s == ";" || self.peek(1).s == "}") {
                kind = self.next().s
            }
            var async_ = false
            if self.is("async") && !(self.peek(1).s == "(" || self.peek(1).s == "=") && !self.peek(1).nl {
                self.next()
                async_ = true
            }
            if self.eat("*") {
                self.fail("generators aren't supported")
                return c
            }
            if self.is("#") { self.next() }  // private names: kept as ordinary ones
            let key = self.prop_key()
            if self.is("(") {
                let f = Ast { k: "func", s: key.s, line: self.tok().line }
                if async_ { f.s2 = "async" }
                f.params = self.params()
                f.kids = [self.function_body()]
                c.params.push(Ast { k: "member", s: kind, flag: is_static, kids: [key, f] })
            } else {
                // a field: name = value
                var value = empty()
                if self.eat("=") { value = self.assign() }
                self.semi()
                c.params.push(Ast { k: "field", flag: is_static, kids: [key, value] })
            }
        }
        self.expect("}")
        return c
    }

    // a property name in an object literal or class: name, "string", 123, or [computed]
    fn prop_key(self) -> Ast {
        let t = self.next()
        if t.kind == "name" || t.kind == "str" { return Ast { k: "str", s: t.s } }
        if t.kind == "num" { return Ast { k: "str", s: num_text(t.n) } }
        if t.kind == "punc" && t.s == "[" {
            let e = self.assign()
            self.expect("]")
            return Ast { k: "computed", kids: [e] }
        }
        if t.kind == "punc" && t.s == "#" { return self.prop_key() }
        self.fail("unexpected '${t.s}' in a property name")
        return Ast { k: "str", s: "" }
    }

    fn conditional(self) -> Ast {
        let line = self.tok().line
        let test = self.binary(0)
        if self.is("?") {
            self.next()
            let saved = self.no_in
            self.no_in = false
            let a = self.assign()
            self.no_in = saved
            self.expect(":")
            let b = self.assign()
            return Ast { k: "cond", kids: [test, a, b], line }
        }
        return test
    }

    fn binary(self, min_prec: int) -> Ast {
        var left = self.unary_or_higher()
        while self.good() {
            let t = self.tok()
            let op = t.s
            if t.kind != "punc" && !(t.kind == "name" && (op == "instanceof" || (op == "in" && !self.no_in))) { break }
            let prec = precedence(op)
            if prec < 0 || prec < min_prec { break }
            self.next()
            // ** is right-associative
            let right = if op == "**" { self.binary(prec) } else { self.binary(prec + 1) }
            let kind = if op == "&&" || op == "||" || op == "??" { "logic" } else { "bin" }
            left = Ast { k: kind, s: op, kids: [left, right], line: t.line }
        }
        return left
    }

    fn unary_or_higher(self) -> Ast {
        let t = self.tok()
        let line = t.line
        if t.kind == "punc" && (t.s == "!" || t.s == "-" || t.s == "+" || t.s == "~") {
            self.next()
            let arg = self.unary_or_higher()
            if self.is("**") {
                self.fail("unary operand of ** needs parentheses")
            }
            return Ast { k: "unary", s: t.s, kids: [arg], line }
        }
        if t.kind == "punc" && (t.s == "++" || t.s == "--") {
            self.next()
            return Ast { k: "update", s: t.s, flag: true, kids: [self.unary_or_higher()], line }
        }
        if t.kind == "name" && (t.s == "typeof" || t.s == "void" || t.s == "delete") {
            self.next()
            return Ast { k: "unary", s: t.s, kids: [self.unary_or_higher()], line }
        }
        if t.kind == "name" && t.s == "await" {
            self.next()
            return Ast { k: "await", kids: [self.unary_or_higher()], line }
        }
        let e = self.postfix()
        let n = self.tok()
        if n.kind == "punc" && (n.s == "++" || n.s == "--") && !n.nl {
            self.next()
            return Ast { k: "update", s: n.s, flag: false, kids: [e], line }
        }
        return e
    }

    // calls, members, optional chains
    fn postfix(self) -> Ast {
        var e = self.primary()
        var chained = false
        while self.good() {
            let t = self.tok()
            if t.kind == "punc" && t.s == "." {
                self.next()
                let name = self.next()
                if name.kind != "name" && !(name.kind == "punc" && name.s == "#") { self.fail("expected a property name after '.'") }
                let nm = if name.s == "#" { self.next().s } else { name.s }
                e = Ast { k: "member", s: nm, kids: [e], line: t.line }
            } else if t.kind == "punc" && t.s == "?." {
                self.next()
                chained = true
                if self.is("(") {
                    e = Ast { k: "call", flag: true, kids: [e], line: t.line }
                    self.call_args(e)
                } else if self.eat("[") {
                    let ix = self.expression()
                    self.expect("]")
                    e = Ast { k: "index", flag: true, kids: [e, ix], line: t.line }
                } else {
                    let name = self.next()
                    e = Ast { k: "member", s: name.s, flag: true, kids: [e], line: t.line }
                }
            } else if t.kind == "punc" && t.s == "[" {
                self.next()
                let saved = self.no_in
                self.no_in = false
                let ix = self.expression()
                self.no_in = saved
                self.expect("]")
                e = Ast { k: "index", kids: [e, ix], line: t.line }
            } else if t.kind == "punc" && t.s == "(" {
                e = Ast { k: "call", kids: [e], line: t.line }
                self.call_args(e)
            } else if t.kind == "tmpl" {
                self.fail("tagged templates aren't supported")
            } else {
                break
            }
        }
        if chained { return Ast { k: "chain", kids: [e], line: e.line } }
        return e
    }

    fn call_args(self, call: Ast) {
        self.expect("(")
        let saved = self.no_in
        self.no_in = false
        while !self.is(")") && self.good() {
            if self.eat("...") { call.kids.push(Ast { k: "spread", kids: [self.assign()] }) } else { call.kids.push(self.assign()) }
            if !self.is(")") { self.expect(",") }
        }
        self.no_in = saved
        self.expect(")")
    }

    fn primary(self) -> Ast {
        let t = self.tok()
        let line = t.line
        if t.kind == "num" {
            self.next()
            return Ast { k: "num", n: t.n, line }
        }
        if t.kind == "str" {
            self.next()
            return Ast { k: "str", s: t.s, line }
        }
        if t.kind == "tmpl" {
            self.next()
            return template(t.s, line, self)
        }
        if t.kind == "regex" {
            self.next()
            let flags = self.next().s
            return Ast { k: "regex", s: t.s, s2: flags, line }
        }
        if t.kind == "error" {
            self.fail(t.s)
            return empty()
        }
        if t.kind == "name" {
            let w = t.s
            if w == "function" || (w == "async" && self.peek(1).s == "function") { return self.function_expr() }
            if w == "class" { return self.class_expr() }
            if w == "new" {
                self.next()
                if self.eat(".") {
                    self.next()                   // new.target
                    return Ast { k: "ident", s: "undefined", line }
                }
                // the constructor: a member expression without calls
                var callee = self.primary()
                while self.good() {
                    if self.eat(".") {
                        callee = Ast { k: "member", s: self.next().s, kids: [callee], line }
                    } else if self.is("[") {
                        self.next()
                        let ix = self.expression()
                        self.expect("]")
                        callee = Ast { k: "index", kids: [callee, ix], line }
                    } else {
                        break
                    }
                }
                let n = Ast { k: "new", kids: [callee], line }
                if self.is("(") { self.call_args(n) }
                return n
            }
            self.next()
            if w == "this" { return Ast { k: "this", line } }
            if w == "super" { return Ast { k: "super", line } }
            if w == "null" { return Ast { k: "null", line } }
            if w == "true" || w == "false" { return Ast { k: "bool", flag: w == "true", line } }
            if w == "import" {
                self.fail("modules (import) aren't supported")
                return empty()
            }
            return Ast { k: "ident", s: w, line }
        }
        if t.kind == "punc" {
            if t.s == "(" {
                self.next()
                let saved = self.no_in
                self.no_in = false
                let e = self.expression()
                self.no_in = saved
                self.expect(")")
                return e
            }
            if t.s == "[" {
                self.next()
                let a = Ast { k: "array", line }
                while !self.is("]") && self.good() {
                    if self.is(",") {
                        self.next()
                        a.kids.push(Ast { k: "hole" })
                        continue
                    }
                    if self.eat("...") { a.kids.push(Ast { k: "spread", kids: [self.assign()] }) } else { a.kids.push(self.assign()) }
                    if !self.is("]") { self.expect(",") }
                }
                self.expect("]")
                return a
            }
            if t.s == "{" {
                self.next()
                let o = Ast { k: "object", line }
                while !self.is("}") && self.good() {
                    if self.eat("...") {
                        o.kids.push(Ast { k: "prop", s: "spread", kids: [empty(), self.assign()] })
                    } else {
                        var kind = "init"
                        var async_ = false
                        if (self.is("get") || self.is("set")) && !(self.peek(1).s == ":" || self.peek(1).s == "(" || self.peek(1).s == "," || self.peek(1).s == "}") {
                            kind = self.next().s
                        } else if self.is("async") && !(self.peek(1).s == ":" || self.peek(1).s == "(" || self.peek(1).s == "," || self.peek(1).s == "}") {
                            self.next()
                            async_ = true
                        }
                        let name_tok = self.tok()
                        let key = self.prop_key()
                        if self.is("(") {
                            let f = Ast { k: "func", s: key.s, line: self.tok().line }
                            if async_ { f.s2 = "async" }
                            f.params = self.params()
                            f.kids = [self.function_body()]
                            o.kids.push(Ast { k: "prop", s: if kind == "init" { "init" } else { kind }, kids: [key, f] })
                        } else if self.eat(":") {
                            o.kids.push(Ast { k: "prop", s: "init", kids: [key, self.assign()] })
                        } else if name_tok.kind == "name" {
                            // shorthand {a} (or {a = 1} in a pattern)
                            var value = Ast { k: "ident", s: key.s, line }
                            if self.eat("=") { value = Ast { k: "default", kids: [value, self.assign()] } }
                            o.kids.push(Ast { k: "prop", s: "init", kids: [key, value], flag2: true })
                        } else {
                            self.fail("expected ':' in an object literal")
                        }
                    }
                    if !self.is("}") { self.expect(",") }
                }
                self.expect("}")
                return o
            }
        }
        self.fail(if t.kind == "eof" { "unexpected end of script" } else { "unexpected '${t.s}'" })
        return empty()
    }
}

// an expression read as an assignment target ([a, b] = ..., {x} = ..., arrow parameters)
fn to_pattern(e: Ast) -> Ast {
    if e.k == "array" {
        let p = Ast { k: "arrpat" }
        for x in e.kids {
            if x.k == "spread" {
                p.kids.push(Ast { k: "rest", kids: [to_pattern(x.kids[0])] })
            } else if x.k == "assign" && x.s == "=" {
                p.kids.push(Ast { k: "default", kids: [to_pattern(x.kids[0]), x.kids[1]] })
            } else {
                p.kids.push(to_pattern(x))
            }
        }
        return p
    }
    if e.k == "object" {
        let p = Ast { k: "objpat" }
        for prop in e.kids {
            if prop.s == "spread" {
                p.kids.push(Ast { k: "rest", kids: [to_pattern(prop.kids[1])] })
            } else {
                let v = prop.kids[1]
                var target = to_pattern(v)
                if v.k == "assign" && v.s == "=" { target = Ast { k: "default", kids: [to_pattern(v.kids[0]), v.kids[1]] } }
                if v.k == "default" { target = v }
                p.kids.push(Ast { k: "patprop", kids: [prop.kids[0], target] })
            }
        }
        return p
    }
    if e.k == "assign" && e.s == "=" { return Ast { k: "default", kids: [to_pattern(e.kids[0]), e.kids[1]] } }
    return e
}

fn precedence(op: str) -> int {
    if op == "??" { return 1 }
    if op == "||" { return 2 }
    if op == "&&" { return 3 }
    if op == "|" { return 4 }
    if op == "^" { return 5 }
    if op == "&" { return 6 }
    if op == "==" || op == "!=" || op == "===" || op == "!==" { return 7 }
    if op == "<" || op == ">" || op == "<=" || op == ">=" || op == "instanceof" || op == "in" { return 8 }
    if op == "<<" || op == ">>" || op == ">>>" { return 9 }
    if op == "+" || op == "-" { return 10 }
    if op == "*" || op == "/" || op == "%" { return 11 }
    if op == "**" { return 12 }
    return -1
}

// `text ${expr} more`: string pieces and expressions, alternating (cooked escapes)
fn template(raw: str, line: int, outer: Parser) -> Ast {
    let node = Ast { k: "tmpl", line }
    let src = html.Src { s: raw, low: raw, n: raw.len() }
    var parts: [str] = []
    var i = 0
    var from = 0
    while i < src.n {
        let c = src.at(i)
        if c == 92 {
            parts.push(src.cut(from, i))
            let e = escape(src, i + 1)
            parts.push(e.text)
            i = e.end
            from = i
            continue
        }
        if c == 36 && src.at(i + 1) == 123 {
            parts.push(src.cut(from, i))
            node.kids.push(Ast { k: "str", s: parts.join("") })
            parts = []
            // the expression: to the matching }
            var depth = 1
            var j = i + 2
            while j < src.n {
                let d = src.at(j)
                if d == 34 || d == 39 {
                    j = read_string(src, j).end
                    continue
                }
                if d == 96 {
                    j += 1
                    while j < src.n && src.at(j) != 96 {
                        if src.at(j) == 92 { j += 1 }
                        j += 1
                    }
                    j += 1
                    continue
                }
                if d == 123 { depth += 1 }
                if d == 125 {
                    depth -= 1
                    if depth == 0 { break }
                }
                j += 1
            }
            let p = Parser { toks: lex(src.cut(i + 2, j)) }
            let e = p.expression()
            if p.error != "" { outer.fail("in a template: ${p.error}") }
            node.kids.push(e)
            i = j + 1
            from = i
            continue
        }
        i += 1
    }
    parts.push(src.cut(from, src.n))
    node.kids.push(Ast { k: "str", s: parts.join("") })
    return node
}

// numbers as JavaScript prints them: 3, 0.5, 1e+21, NaN, Infinity
fn num_text(n: float) -> str {
    if n != n { return "NaN" }
    if n == 1.0 / 0.0 { return "Infinity" }
    if n == -1.0 / 0.0 { return "-Infinity" }
    if n == n.floor() && n < 1.0e21 && n > -1.0e21 {
        if n == 0.0 { return "0" }
        return str(int(n))
    }
    let s = str(n)
    if s.contains("e") {
        // 1e+21, 1.5e-7: as JavaScript writes them
        let parts = s.split("e")
        var m = parts[0]
        if m.ends_with(".0") { m = m.slice(0, m.len() - 2) }
        var ex = parts[1]
        if !ex.starts_with("-") && !ex.starts_with("+") { ex = "+" + ex }
        // drop leading zeros in the exponent
        let sign = ex.slice(0, 1)
        var digits = ex.slice(1, ex.len())
        while digits.len() > 1 && digits.starts_with("0") { digits = digits.slice(1, digits.len()) }
        return m + "e" + sign + digits
    }
    return s
}

// Parse a whole script: its statements, or an error message.
struct Parsed {
    body: [Ast],
    error: str,
}

fn parse(text: str) -> Parsed {
    let toks = lex(text)
    if !toks.is_empty() && toks[0].kind == "error" { return Parsed { body: [], error: "line ${toks[0].line}: ${toks[0].s}" } }
    let p = Parser { toks }
    let body = p.program()
    return Parsed { body, error: p.error }
}
