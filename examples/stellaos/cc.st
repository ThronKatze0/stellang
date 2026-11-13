// cc: a compiler that runs inside StellaOS. It turns stellang source (the parts of the language
// a one-file program needs: functions, structs with methods, int/bool/str, lists, loops, string
// interpolation) into RISC-V machine code that runs as a process in user mode (proc.st).
//
//     lexer -> parser (a tree) -> code generator (types checked as it goes) -> rv.st (link)
//
// The runtime the programs need (strings, lists, printing, the system calls) is itself written in
// this language (crt.st) and compiled along with every program. The generated code is simple: a
// stack machine on top of the CPU (the value at hand in a0, the rest on the stack), every list
// index checked, division by zero caught, all of it position-independent.

import rv
import userland

extern fn st_k_byte(s: str, i: int) -> int
extern fn st_k_substr(s: str, from: int, to: int) -> str
extern fn st_chr(code: int) -> str

// ---- tokens ----

struct Tok {
    k: str,              // id, int, str, op, nl, eof
    s: str = "",
    n: int = 0,
    line: int = 1,
    col: int = 1,
}

const OPS3 = ["..=", "<<=", ">>="]
const OPS2 = ["??", "..", "->", "=>", "==", "!=", "<=", ">=", "&&", "||", "+=", "-=", "*=", "/=", "%=", "<<", ">>", "&=", "|=", "^="]
const OPS1 = "+-*/%=<>!&|^~(){}[],:.;?"

struct Lexer {
    src: str,
    n: int = 0,
    i: int = 0,
    line: int = 1,
    lstart: int = 0,
    toks: [Tok] = [],
    nest: [str] = [],        // open brackets: line breaks inside ( and [ don't end statements, inside { they do
    err: str = "",
    err_line: int = 0,
    err_col: int = 0,

    fn c(self, k: int) -> int {
        let j = self.i + k
        if j >= self.n { return 0 }
        return st_k_byte(self.src, j)
    }

    fn fail(self, msg: str) {
        if self.err == "" {
            self.err = msg
            self.err_line = self.line
            self.err_col = self.i - self.lstart + 1
        }
        self.i = self.n
    }

    fn add(self, k: str, s: str, n: int, at: int) {
        self.toks.push(Tok { k, s, n, line: self.line, col: at - self.lstart + 1 })
    }

    fn run(self) {
        self.n = self.src.len()
        while self.i < self.n {
            let ch = self.c(0)
            let at = self.i
            if ch == 10 {
                self.i += 1
                let in_parens = !self.nest.is_empty() && self.nest[self.nest.len() - 1] != "{"
                if !in_parens && !self.continues() { self.add("nl", "", 0, at) }
                self.line += 1
                self.lstart = self.i
            } else if ch == 32 || ch == 9 || ch == 13 {
                self.i += 1
            } else if ch == 47 && self.c(1) == 47 {
                while self.i < self.n && self.c(0) != 10 { self.i += 1 }
            } else if ch == 47 && self.c(1) == 42 {
                self.i += 2
                while self.i < self.n && !(self.c(0) == 42 && self.c(1) == 47) {
                    if self.c(0) == 10 {
                        self.line += 1
                        self.lstart = self.i + 1
                    }
                    self.i += 1
                }
                self.i += 2
            } else if is_alpha(ch) {
                while self.i < self.n && (is_alpha(self.c(0)) || is_digit(self.c(0))) { self.i += 1 }
                self.add("id", st_k_substr(self.src, at, self.i), 0, at)
            } else if is_digit(ch) {
                self.number(at)
            } else if ch == 34 {
                self.string(at)
            } else {
                self.op(at)
            }
        }
        self.add("nl", "", 0, self.i)
        self.add("eof", "", 0, self.i)
    }

    // a line that starts with `.` (but not `..`) goes on with the one before it
    fn continues(self) -> bool {
        var j = self.i
        while j < self.n && (st_k_byte(self.src, j) == 32 || st_k_byte(self.src, j) == 9 || st_k_byte(self.src, j) == 13 || st_k_byte(self.src, j) == 10) { j += 1 }
        return j + 1 < self.n && st_k_byte(self.src, j) == 46 && st_k_byte(self.src, j + 1) != 46
    }

    fn number(self, at: int) {
        var v = 0
        if self.c(0) == 48 && (self.c(1) == 120 || self.c(1) == 98) {
            let base = if self.c(1) == 120 { 16 } else { 2 }
            self.i += 2
            var digits = 0
            while self.i < self.n {
                let d = digit_value(self.c(0))
                if self.c(0) == 95 {
                    self.i += 1
                    continue
                }
                if d < 0 || d >= base { break }
                v = v * base + d
                digits += 1
                self.i += 1
            }
            if digits == 0 {
                self.fail("a number needs digits after 0x / 0b")
                return
            }
        } else {
            while self.i < self.n && (is_digit(self.c(0)) || self.c(0) == 95) {
                if self.c(0) != 95 {
                    let d = self.c(0) - 48
                    if v > (9223372036854775807 - d) / 10 {
                        self.fail("this number is too big for an int")
                        return
                    }
                    v = v * 10 + d
                }
                self.i += 1
            }
            if self.c(0) == 46 && is_digit(self.c(1)) || ((self.c(0) == 101 || self.c(0) == 69) && (is_digit(self.c(1)) || ((self.c(1) == 45 || self.c(1) == 43) && is_digit(self.c(2))))) {
                // a float: digits . digits [e[+-]digits], kept as digits x 10^exp
                var exp = 0
                if self.c(0) == 46 {
                    self.i += 1
                    while self.i < self.n && (is_digit(self.c(0)) || self.c(0) == 95) {
                        if self.c(0) != 95 {
                            if v < 100_000_000_000_000_000 {
                                v = v * 10 + self.c(0) - 48
                                exp -= 1
                            }
                        }
                        self.i += 1
                    }
                }
                if self.c(0) == 101 || self.c(0) == 69 {
                    self.i += 1
                    var sign = 1
                    if self.c(0) == 45 || self.c(0) == 43 {
                        if self.c(0) == 45 { sign = -1 }
                        self.i += 1
                    }
                    var e = 0
                    while self.i < self.n && is_digit(self.c(0)) {
                        e = min(e * 10 + self.c(0) - 48, 10000)
                        self.i += 1
                    }
                    exp += sign * e
                }
                if is_alpha(self.c(0)) {
                    self.fail("a letter right after a number")
                    return
                }
                self.toks.push(Tok { k: "float", s: st_k_substr(self.src, at, self.i).replace("_", ""), n: v, line: self.line, col: at - self.lstart + 1 })
                return
            }
        }
        if is_alpha(self.c(0)) {
            self.fail("a letter right after a number")
            return
        }
        self.add("int", st_k_substr(self.src, at, self.i), v, at)
    }

    // the raw text between the quotes; escapes and ${...} are dealt with by the parser
    fn string(self, at: int) {
        self.i += 1
        let start = self.i
        var braces = 0
        while true {
            if self.i >= self.n {
                self.fail("this string never ends (a \" is missing)")
                return
            }
            let ch = self.c(0)
            if ch == 10 && braces == 0 {
                self.fail("this string never ends (a \" is missing)")
                return
            }
            if ch == 92 {
                self.i += 2
                continue
            }
            if braces == 0 && ch == 36 && self.c(1) == 123 {
                braces = 1
                self.i += 2
                continue
            }
            if braces > 0 {
                if ch == 123 { braces += 1 }
                if ch == 125 { braces -= 1 }
                if ch == 34 {
                    // a string inside ${...}: skip it whole
                    self.i += 1
                    while self.i < self.n && self.c(0) != 34 && self.c(0) != 10 {
                        if self.c(0) == 92 { self.i += 1 }
                        self.i += 1
                    }
                }
                self.i += 1
                continue
            }
            if ch == 34 { break }
            self.i += 1
        }
        self.add("str", st_k_substr(self.src, start, self.i), 0, at)
        self.i += 1
    }

    fn op(self, at: int) {
        let three = if self.i + 3 <= self.n { st_k_substr(self.src, self.i, self.i + 3) } else { "" }
        let two = if self.i + 2 <= self.n { st_k_substr(self.src, self.i, self.i + 2) } else { "" }
        var s = ""
        if OPS3.contains(three) {
            s = three
        } else if OPS2.contains(two) {
            s = two
        } else {
            let one = st_k_substr(self.src, self.i, self.i + 1)
            if !OPS1.contains(one) || one == "" {
                let ch = self.c(0)
                self.fail(if ch >= 128 { "unexpected character (letters outside A-Z can only go in strings and comments)" } else { "unexpected character `${one}`" })
                return
            }
            s = one
        }
        self.i += s.len()
        if s == "(" || s == "[" || s == "{" { self.nest.push(s) }
        if (s == ")" || s == "]" || s == "}") && !self.nest.is_empty() { self.nest.pop() }
        self.add("op", s, 0, at)
    }
}

fn is_alpha(c: int) -> bool { return c >= 97 && c <= 122 || c >= 65 && c <= 90 || c == 95 }
fn is_digit(c: int) -> bool { return c >= 48 && c <= 57 }
fn digit_value(c: int) -> int {
    if c >= 48 && c <= 57 { return c - 48 }
    if c >= 97 && c <= 102 { return c - 87 }
    if c >= 65 && c <= 70 { return c - 55 }
    return -1
}

// ---- the tree ----

struct Tree {
    k: str,
    s: str = "",
    s2: str = "",
    n: int = 0,
    kids: [Tree] = [],
    line: int = 0,
    col: int = 0,
}

struct Param {
    name: str,
    ty: str,
}

struct FnDecl {
    name: str,
    owner: str = "",         // the struct, for methods
    params: [Param] = [],
    ret: str = "void",
    body: Tree,
    line: int = 0,
    col: int = 0,
    crt: bool = false,       // part of the runtime: may use the intrinsics
    is_static: bool = false, // in a struct or enum, without self: Type.name(...)
}

struct Field {
    name: str,
    ty: str,
    def: Tree,
    has_def: bool = false,
}

struct StructDecl {
    name: str,
    fields: [Field] = [],
    methods: [FnDecl] = [],
    line: int = 0,
    col: int = 0,
}

struct GlobalDecl {
    name: str,
    ty: str = "",
    init: Tree,
    mutable: bool = false,
    constant: bool = false,
    crt: bool = false,
    line: int = 0,
    col: int = 0,
}

struct EnumDecl {
    name: str,
    variants: [str] = [],
    fields: [[Field]] = [],      // each variant's values (none for a plain name)
    braces: [bool] = [],         // written Variant { a: T } rather than Variant(T)
    data: bool = false,          // some variant carries values: every value is a pointer to [tag, values...]
    line: int = 0,
    col: int = 0,
}

struct Program {
    fns: [FnDecl] = [],
    structs: [StructDecl] = [],
    globals: [GlobalDecl] = [],
    enums: [EnumDecl] = [],
}

// ---- the parser ----

struct Parser {
    toks: [Tok],
    i: int = 0,
    err: str = "",
    err_line: int = 0,
    err_col: int = 0,
    crt: bool = false,
    no_struct: bool = false,     // in `if`/`while`/`for` heads, `Name {` starts the block, not a struct
    in_pattern: bool = false,    // a match pattern: `Red =>` is an arm, not a lambda
    line_base: int = 0,

    fn peek(self) -> Tok { return self.toks[self.i] }
    fn peek2(self) -> Tok { return self.toks[min(self.i + 1, self.toks.len() - 1)] }
    fn next(self) -> Tok {
        let t = self.toks[self.i]
        if self.i < self.toks.len() - 1 { self.i += 1 }
        return t
    }
    fn is(self, s: str) -> bool {
        let t = self.toks[self.i]
        return (t.k == "op" || t.k == "id") && t.s == s
    }
    fn accept(self, s: str) -> bool {
        if self.is(s) {
            self.next()
            return true
        }
        return false
    }
    fn fail_at(self, t: Tok, msg: str) {
        if self.err == "" {
            self.err = msg
            self.err_line = t.line
            self.err_col = t.col
        }
        self.i = self.toks.len() - 1   // straight to the end: everything stops
    }
    fn fail(self, msg: str) { self.fail_at(self.peek(), msg) }
    fn expect(self, s: str) {
        if !self.accept(s) { self.fail("expected `${s}` here, found ${describe(self.peek())}") }
    }
    fn skip_nl(self) {
        while self.peek().k == "nl" || self.is(";") { self.next() }
    }
    fn ident(self) -> str {
        let t = self.peek()
        if t.k != "id" || KEYWORDS.contains(t.s) {
            self.fail("expected a name here, found ${describe(t)}")
            return "?"
        }
        self.next()
        return t.s
    }
    fn node(self, k: str, t: Tok) -> Tree { return Tree { k, line: t.line, col: t.col } }

    fn program(self, p: Program) {
        while self.err == "" {
            self.skip_nl()
            let t = self.peek()
            if t.k == "eof" { return }
            if self.accept("fn") {
                p.fns.push(self.function(""))
            } else if self.accept("struct") {
                p.structs.push(self.structure(t))
            } else if self.is("const") || self.is("let") || self.is("var") {
                let kw = self.next().s
                let name = self.ident()
                var ty = ""
                if self.accept(":") { ty = self.typ() }
                self.expect("=")
                let init = self.expr()
                p.globals.push(GlobalDecl { name, ty, init, mutable: kw == "var", constant: kw == "const", crt: self.crt, line: t.line, col: t.col })
            } else if self.is("import") {
                self.fail("no imports: a program is one file, and the built-in functions are always there")
            } else if self.accept("enum") {
                self.enumeration(t, p)
            } else if self.is("trait") || self.is("impl") {
                self.fail("`${t.s}` isn't supported by this compiler yet")
            } else {
                self.fail("expected `fn`, `struct`, `const`, `let` or `var` at the top level, found ${describe(t)}")
            }
        }
    }

    fn typ(self) -> str {
        if self.accept("fn") {
            // fn(int, str) -> bool
            self.expect("(")
            var ps: [str] = []
            while !self.is(")") && self.err == "" {
                ps.push(self.typ())
                if !self.accept(",") { break }
            }
            self.expect(")")
            var r = "void"
            if self.accept("->") { r = self.typ() }
            return "fn(" + ps.join(",") + ")->" + r
        }
        if self.accept("[") {
            let inner = self.typ()
            self.expect("]")
            if self.accept("?") { return "[${inner}]?" }
            return "[${inner}]"
        }
        if self.accept("{") {
            let kt = self.typ()
            self.expect(":")
            let vt = self.typ()
            self.expect("}")
            return "{" + kt + ":" + vt + "}"
        }
        let t = self.peek()
        let name = self.ident()
        if self.accept("?") { return name + "?" }
        if self.is("!") { self.fail("result types (`T!`) aren't supported here yet") }
        return name
    }

    fn function(self, owner: str) -> FnDecl {
        let t = self.peek()
        let name = self.ident()
        let f = FnDecl { name, owner, body: Tree { k: "block" }, line: t.line, col: t.col, crt: self.crt }
        self.expect("(")
        var first = true
        while !self.is(")") && self.err == "" {
            self.skip_nl()
            if first && owner != "" && self.is("self") {
                self.next()
                f.params.push(Param { name: "self", ty: owner })
            } else {
                let pn = self.ident()
                self.expect(":")
                f.params.push(Param { name: pn, ty: self.typ() })
            }
            first = false
            self.skip_nl()
            if !self.accept(",") { break }
            self.skip_nl()
        }
        self.expect(")")
        if owner != "" && (f.params.is_empty() || f.params[0].name != "self") { f.is_static = true }
        if self.accept("->") { f.ret = self.typ() }
        f.body = self.block()
        return f
    }

    fn structure(self, t: Tok) -> StructDecl {
        let name = self.ident()
        let sd = StructDecl { name, line: t.line, col: t.col }
        if name != "?" && !is_upper(st_k_byte(name, 0)) { self.fail_at(t, "struct names start with a capital letter") }
        self.expect("{")
        while self.err == "" {
            self.skip_nl()
            if self.accept("}") { break }
            if self.accept("fn") {
                sd.methods.push(self.function(name))
                continue
            }
            let fname = self.ident()
            self.expect(":")
            let f = Field { name: fname, ty: self.typ(), def: Tree { k: "none" } }
            if self.accept("=") {
                f.def = self.expr()
                f.has_def = true
            }
            sd.fields.push(f)
            self.skip_nl()
            self.accept(",")
        }
        return sd
    }

    // enum Name { A, B, C, fn method(self) ... }: plain named values
    fn enumeration(self, t: Tok, p: Program) {
        let name = self.ident()
        let ed = EnumDecl { name, line: t.line, col: t.col }
        if name != "?" && !is_upper(st_k_byte(name, 0)) { self.fail_at(t, "enum names start with a capital letter") }
        self.expect("{")
        while self.err == "" {
            self.skip_nl()
            if self.accept("}") { break }
            if self.accept("fn") {
                let f = self.function(name)
                p.fns.push(f)
                continue
            }
            let vt = self.peek()
            let v = self.ident()
            var fs: [Field] = []
            var braces = false
            if self.accept("(") {
                // Circle(radius: float) or Pair(int, int)
                while !self.is(")") && self.err == "" {
                    if self.peek().k == "id" && self.peek2().k == "op" && self.peek2().s == ":" {
                        let fname = self.ident()
                        self.expect(":")
                        fs.push(Field { name: fname, ty: self.typ(), def: Tree { k: "none" } })
                    } else {
                        fs.push(Field { name: "_${fs.len()}", ty: self.typ(), def: Tree { k: "none" } })
                    }
                    if !self.accept(",") { break }
                }
                self.expect(")")
                ed.data = true
            } else if self.accept("{") {
                // Rect { w: float, h: float = 1.0 }
                braces = true
                while self.err == "" {
                    self.skip_nl()
                    if self.accept("}") { break }
                    let fname = self.ident()
                    self.expect(":")
                    let f = Field { name: fname, ty: self.typ(), def: Tree { k: "none" } }
                    if self.accept("=") {
                        f.def = self.expr()
                        f.has_def = true
                    }
                    fs.push(f)
                    self.skip_nl()
                    self.accept(",")
                }
                ed.data = true
            }
            ed.fields.push(fs)
            ed.braces.push(braces)
            if ed.variants.contains(v) { self.fail_at(vt, "${v} is in ${name} twice") }
            ed.variants.push(v)
            self.skip_nl()
            self.accept(",")
        }
        p.enums.push(ed)
    }

    fn block(self) -> Tree {
        let t = self.peek()
        self.expect("{")
        let b = self.node("block", t)
        while self.err == "" {
            self.skip_nl()
            if self.accept("}") { break }
            if self.peek().k == "eof" {
                self.fail_at(t, "this `{` is never closed")
                break
            }
            b.kids.push(self.statement())
        }
        return b
    }

    fn statement(self) -> Tree {
        let t = self.peek()
        if self.is("let") || self.is("var") {
            let kw = self.next().s
            let n = self.node("let", t)
            n.s = self.ident()
            n.n = if kw == "var" { 1 } else { 0 }
            if self.accept(":") { n.s2 = self.typ() }
            self.expect("=")
            n.kids.push(self.expr())
            self.end_statement()
            return n
        }
        if self.accept("if") { return self.if_statement(t) }
        if self.accept("while") {
            let n = self.node("while", t)
            n.kids.push(self.head())
            n.kids.push(self.block())
            return n
        }
        if self.accept("for") {
            let n = self.node("for", t)
            n.s = self.ident()
            if self.accept(",") { n.s2 = self.ident() }
            self.expect("in")
            let a = self.head()
            if self.accept("..") {
                n.k = "for_range"
                if n.s2 != "" { self.fail_at(t, "`for i in a..b` counts with one name") }
                n.kids.push(a)
                n.kids.push(self.head())
            } else {
                n.kids.push(a)
            }
            n.kids.push(self.block())
            return n
        }
        if self.accept("return") {
            let n = self.node("return", t)
            if self.peek().k != "nl" && !self.is("}") && !self.is(";") { n.kids.push(self.expr()) }
            self.end_statement()
            return n
        }
        if self.accept("break") {
            self.end_statement()
            return self.node("break", t)
        }
        if self.accept("continue") {
            self.end_statement()
            return self.node("continue", t)
        }
        if self.accept("match") { return self.match_statement(t) }
        let e = self.expr()
        let op = self.peek()
        if op.k == "op" && ["=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="].contains(op.s) {
            self.next()
            let n = self.node("assign", op)
            n.s = op.s
            n.kids.push(e)
            n.kids.push(self.expr())
            self.end_statement()
            return n
        }
        let n = self.node("expr", t)
        n.kids.push(e)
        self.end_statement()
        return n
    }

    fn end_statement(self) {
        if self.peek().k == "nl" || self.is(";") || self.is("}") || self.peek().k == "eof" { return }
        self.fail("expected the end of the line, found ${describe(self.peek())}")
    }

    // a condition: no struct literals at the top (so `if x == y {` opens the block)
    fn head(self) -> Tree {
        let old = self.no_struct
        self.no_struct = true
        let e = self.expr()
        self.no_struct = old
        return e
    }

    fn if_statement(self, t: Tok) -> Tree {
        let n = self.node("if", t)
        if self.accept("let") {
            // if let x = option { ... }: kids[0] is an "iflet" node
            let il = self.node("iflet", self.peek())
            il.s = self.ident()
            self.expect("=")
            il.kids.push(self.head())
            n.kids.push(il)
        } else {
            n.kids.push(self.head())
        }
        n.kids.push(self.block())
        if self.peek().k == "nl" && self.peek2().k == "id" && self.peek2().s == "else" { self.next() }
        if self.accept("else") {
            let t2 = self.peek()
            if self.accept("if") {
                let b = self.node("block", t2)
                b.kids.push(self.if_statement(t2))
                n.kids.push(b)
            } else {
                n.kids.push(self.block())
            }
        }
        return n
    }

    // match x { 1 => ..., 2 | 3 => { ... }, _ => ... }
    fn match_statement(self, t: Tok) -> Tree {
        let n = self.node("match", t)
        n.kids.push(self.head())
        self.expect("{")
        while self.err == "" {
            self.skip_nl()
            if self.accept("}") { break }
            let arm = self.node("arm", self.peek())
            if self.is("_") {
                self.next()
                arm.n = 1
            } else {
                self.in_pattern = true
                arm.kids.push(self.binary(5))          // above `|`: that separates alternatives
                while self.accept("|") { arm.kids.push(self.binary(5)) }
                self.in_pattern = false
            }
            self.expect("=>")
            if self.is("{") {
                arm.kids.push(self.block())
            } else if self.is("return") || self.is("break") || self.is("continue") {
                let rt = self.next()
                let b = self.node("block", rt)
                let st = self.node(rt.s, rt)
                if rt.s == "return" && !self.is(",") && !self.is("}") && self.peek().k != "nl" { st.kids.push(self.expr()) }
                b.kids.push(st)
                arm.kids.push(b)
            } else {
                let b = self.node("block", self.peek())
                let st = self.node("expr", self.peek())
                let e = self.expr()
                if self.is("=") || self.is("+=") || self.is("-=") {
                    let op = self.next()
                    let asg = self.node("assign", op)
                    asg.s = op.s
                    asg.kids.push(e)
                    asg.kids.push(self.expr())
                    b.kids.push(asg)
                } else {
                    st.kids.push(e)
                    b.kids.push(st)
                }
                arm.kids.push(b)
            }
            n.kids.push(arm)
            self.skip_nl()
            self.accept(",")
        }
        return n
    }

    fn expr(self) -> Tree { return self.binary(0) }

    fn binary(self, level: int) -> Tree {
        if level >= LEVELS.len() { return self.unary() }
        var left = self.binary(level + 1)
        while self.err == "" {
            let t = self.peek()
            if t.k != "op" || !LEVELS[level].contains(t.s) { break }
            self.next()
            self.skip_nl()
            let n = self.node("bin", t)
            n.s = t.s
            n.kids.push(left)
            n.kids.push(self.binary(level + 1))
            left = n
        }
        return left
    }

    fn unary(self) -> Tree {
        let t = self.peek()
        if t.k == "op" && (t.s == "-" || t.s == "!" || t.s == "~") {
            self.next()
            let operand = self.unary()
            if t.s == "-" && operand.k == "int" {
                operand.n = -operand.n
                return operand
            }
            if t.s == "-" && operand.k == "float" {
                operand.s = if operand.s.starts_with("-") { operand.s.slice(1, operand.s.len()) } else { "-" + operand.s }
                return operand
            }
            let n = self.node("un", t)
            n.s = t.s
            n.kids.push(operand)
            return n
        }
        return self.postfix(self.primary())
    }

    fn postfix(self, e: Tree) -> Tree {
        var x = e
        while self.err == "" {
            let t = self.peek()
            if self.accept(".") {
                let name = self.ident()
                if self.accept("(") {
                    let n = self.node("mcall", t)
                    n.s = name
                    n.kids.push(x)
                    self.call_args(n)
                    x = n
                } else if self.is("{") && !self.no_struct && x.k == "name" && is_upper(st_k_byte(x.s, 0)) && is_upper(st_k_byte(name, 0)) {
                    // Shape.Rect { w: 2.0 }
                    let n = self.node("variant", t)
                    n.s = name
                    n.s2 = x.s
                    self.variant_values(n)
                    x = n
                } else {
                    let n = self.node("field", t)
                    n.s = name
                    n.kids.push(x)
                    x = n
                }
            } else if self.accept("[") {
                let n = self.node("index", t)
                n.kids.push(x)
                n.kids.push(self.expr())
                self.expect("]")
                x = n
            } else if self.is("?") {
                self.fail("`?` isn't supported here yet")
            } else {
                break
            }
        }
        return x
    }

    fn call_args(self, n: Tree) {
        while !self.is(")") && self.err == "" {
            n.kids.push(self.expr())
            if !self.accept(",") { break }
        }
        self.expect(")")
    }

    fn primary(self) -> Tree {
        let t = self.peek()
        if t.k == "int" {
            self.next()
            let n = self.node("int", t)
            n.n = t.n
            return n
        }
        if t.k == "float" {
            self.next()
            let n = self.node("float", t)
            n.n = t.n
            n.s = t.s
            return n
        }
        if t.k == "str" {
            self.next()
            return self.string(t)
        }
        if self.lambda_ahead() { return self.lambda() }
        if self.accept("(") {
            let old = self.no_struct
            self.no_struct = false
            let e = self.expr()
            self.no_struct = old
            self.expect(")")
            return e
        }
        if self.accept("{") {
            let n = self.node("map", t)
            while self.err == "" {
                self.skip_nl()
                if self.accept("}") { break }
                n.kids.push(self.expr())
                self.expect(":")
                n.kids.push(self.expr())
                self.skip_nl()
                if !self.accept(",") {
                    self.skip_nl()
                    self.expect("}")
                    break
                }
            }
            return n
        }
        if self.accept("[") {
            let n = self.node("list", t)
            while !self.is("]") && self.err == "" {
                n.kids.push(self.expr())
                if !self.accept(",") { break }
            }
            self.expect("]")
            return n
        }
        if t.k == "op" && t.s == "." && self.peek2().k == "id" {
            self.next()
            let n = self.node("variant", t)
            n.s = self.ident()
            self.variant_values(n)
            return n
        }
        if self.accept("match") {
            let n = self.match_statement(t)
            n.k = "matchx"
            return n
        }
        if self.accept("if") {
            let n = self.node("ifx", t)
            n.kids.push(self.head())
            n.kids.push(self.block())
            self.expect("else")
            let t2 = self.peek()
            if self.accept("if") {
                // else if: an ifx inside a block
                let b = self.node("block", t2)
                let st = self.node("expr", t2)
                let inner = self.node("ifx", t2)
                inner.kids.push(self.head())
                inner.kids.push(self.block())
                self.expect("else")
                inner.kids.push(self.else_block())
                st.kids.push(inner)
                b.kids.push(st)
                n.kids.push(b)
            } else {
                n.kids.push(self.block())
            }
            return n
        }
        if t.k == "id" {
            if t.s == "true" || t.s == "false" {
                self.next()
                let n = self.node("bool", t)
                n.n = if t.s == "true" { 1 } else { 0 }
                return n
            }
            if t.s == "none" {
                self.next()
                return self.node("none", t)
            }
            if t.s == "fn" {
                self.fail("`${t.s}` can't go inside an expression here")
                return self.node("int", t)
            }
            let name = self.ident()
            if self.accept("(") {
                let n = self.node("call", t)
                n.s = name
                self.call_args(n)
                return n
            }
            if self.is("{") && !self.no_struct && is_upper(st_k_byte(name, 0)) {
                self.next()
                let n = self.node("new", t)
                n.s = name
                while self.err == "" {
                    self.skip_nl()
                    if self.accept("}") { break }
                    let ft = self.peek()
                    let fi = self.node("init", ft)
                    fi.s = self.ident()
                    if self.accept(":") {
                        fi.kids.push(self.expr())
                    } else {
                        let v = self.node("name", ft)
                        v.s = fi.s
                        fi.kids.push(v)
                    }
                    n.kids.push(fi)
                    self.skip_nl()
                    if !self.accept(",") {
                        self.skip_nl()
                        self.expect("}")
                        break
                    }
                }
                return n
            }
            let n = self.node("name", t)
            n.s = name
            return n
        }
        self.fail("expected a value here, found ${describe(t)}")
        return self.node("int", t)
    }

    // x => ..., (x, y: int) => ..., () => { ... }
    fn lambda_ahead(self) -> bool {
        if self.in_pattern { return false }
        let t = self.peek()
        if t.k == "id" && !KEYWORDS.contains(t.s) {
            let n = self.peek2()
            return n.k == "op" && n.s == "=>"
        }
        if t.k != "op" || t.s != "(" { return false }
        var depth = 0
        var j = self.i
        while j < self.toks.len() {
            let u = self.toks[j]
            if u.k == "op" && (u.s == "(" || u.s == "[") { depth += 1 }
            if u.k == "op" && (u.s == ")" || u.s == "]") {
                depth -= 1
                if depth == 0 {
                    let n = self.toks[min(j + 1, self.toks.len() - 1)]
                    return n.k == "op" && n.s == "=>"
                }
            }
            if u.k == "eof" { return false }
            j += 1
        }
        return false
    }

    fn lambda(self) -> Tree {
        let t = self.peek()
        let n = self.node("lambda", t)
        if self.accept("(") {
            while !self.is(")") && self.err == "" {
                let pt = self.peek()
                let prm = self.node("param", pt)
                prm.s = self.ident()
                if self.accept(":") { prm.s2 = self.typ() }
                n.kids.push(prm)
                if !self.accept(",") { break }
            }
            self.expect(")")
        } else {
            let prm = self.node("param", t)
            prm.s = self.ident()
            n.kids.push(prm)
        }
        self.expect("=>")
        if self.is("{") {
            n.kids.push(self.block())
        } else {
            n.kids.push(self.expr())
            n.n = 1
        }
        return n
    }

    // after a variant's name: (values) -> n = 1, kids the values; { name: value } -> n = 2, kids inits
    fn variant_values(self, n: Tree) {
        if self.accept("(") {
            n.n = 1
            self.call_args(n)
        } else if self.is("{") && !self.no_struct {
            self.next()
            n.n = 2
            while self.err == "" {
                self.skip_nl()
                if self.accept("}") { break }
                let ft = self.peek()
                let fi = self.node("init", ft)
                fi.s = self.ident()
                if self.accept(":") {
                    fi.kids.push(self.expr())
                } else {
                    let v = self.node("name", ft)
                    v.s = fi.s
                    fi.kids.push(v)
                }
                n.kids.push(fi)
                self.skip_nl()
                if !self.accept(",") {
                    self.skip_nl()
                    self.expect("}")
                    break
                }
            }
        }
    }

    fn else_block(self) -> Tree {
        let t = self.peek()
        if self.accept("if") {
            let b = self.node("block", t)
            let st = self.node("expr", t)
            let inner = self.node("ifx", t)
            inner.kids.push(self.head())
            inner.kids.push(self.block())
            self.expect("else")
            inner.kids.push(self.else_block())
            st.kids.push(inner)
            b.kids.push(st)
            return b
        }
        return self.block()
    }

    // "text ${expr} more": the parts, escapes decoded
    fn string(self, t: Tok) -> Tree {
        let raw = t.s
        let n = self.node("interp", t)
        var lit = ""
        var i = 0
        let len = raw.len()
        var start = 0
        while i < len {
            let ch = st_k_byte(raw, i)
            if ch == 92 && i + 1 < len {
                lit += st_k_substr(raw, start, i)
                let e = st_k_byte(raw, i + 1)
                if e == 110 { lit += "\n" } else if e == 116 { lit += "\t" } else if e == 114 { lit += "\r" } else if e == 48 { lit += " " } else if e == 34 { lit += "\"" } else if e == 92 { lit += "\\" } else if e == 36 { lit += "$" } else if e == 39 { lit += "'" } else {
                    self.fail_at(t, "unknown escape \\${st_k_substr(raw, i + 1, i + 2)} in a string")
                }
                i += 2
                start = i
                continue
            }
            if ch == 36 && i + 1 < len && st_k_byte(raw, i + 1) == 123 {
                lit += st_k_substr(raw, start, i)
                if lit != "" {
                    let p = self.node("str", t)
                    p.s = lit
                    n.kids.push(p)
                    lit = ""
                }
                // find the matching }
                var depth = 1
                var j = i + 2
                while j < len && depth > 0 {
                    let cj = st_k_byte(raw, j)
                    if cj == 123 { depth += 1 }
                    if cj == 125 { depth -= 1 }
                    if cj == 34 {
                        j += 1
                        while j < len && st_k_byte(raw, j) != 34 {
                            if st_k_byte(raw, j) == 92 { j += 1 }
                            j += 1
                        }
                    }
                    j += 1
                }
                let inner = st_k_substr(raw, i + 2, j - 1)
                let lx = Lexer { src: inner, line: t.line }
                lx.run()
                if lx.err != "" {
                    self.fail_at(t, "in \${...}: ${lx.err}")
                } else {
                    let sub = Parser { toks: lx.toks, crt: self.crt }
                    let e = sub.expr()
                    sub.skip_nl()
                    if sub.err == "" && sub.peek().k != "eof" { sub.fail("expected `}` to end \${...}") }
                    if sub.err != "" { self.fail_at(t, "in \${...}: ${sub.err}") }
                    n.kids.push(e)
                }
                i = j
                start = i
                continue
            }
            i += 1
        }
        lit += st_k_substr(raw, start, len)
        if lit != "" || n.kids.is_empty() {
            let p = self.node("str", t)
            p.s = lit
            n.kids.push(p)
        }
        if n.kids.len() == 1 && n.kids[0].k == "str" { return n.kids[0] }
        return n
    }
}

const KEYWORDS = ["fn", "struct", "enum", "trait", "const", "impl", "extern", "import", "let", "var", "if", "else", "while", "for", "in", "return", "break", "continue", "match", "catch", "true", "false"]
const LEVELS = [["??"], ["||"], ["&&"], ["==", "!=", "<", "<=", ">", ">="], ["|"], ["^"], ["&"], ["<<", ">>"], ["+", "-"], ["*", "/", "%"]]

fn is_upper(c: int) -> bool { return c >= 65 && c <= 90 }

fn describe(t: Tok) -> str {
    if t.k == "nl" { return "the end of the line" }
    if t.k == "eof" { return "the end of the file" }
    if t.k == "str" { return "a string" }
    return "`${t.s}`"
}

// ---- the code generator ----

struct Local {
    slot: int,
    ty: str,
    mutable: bool,
    boxed: bool = false,       // a `var` a closure captured: the slot holds a heap cell
}

struct GlobalInfo {
    off: int,
    ty: str,
    mutable: bool,
    value: Tree,             // a constant's literal (k "int"/"str"/"bool"), else k "none"
}

struct Loop {
    brk: int,
    cont: int,
}

struct Gen {
    a: rv.Asm = rv.Asm {},
    funcs: {str: FnDecl} = {},
    structs: {str: StructDecl} = {},
    enums: {str: EnumDecl} = {},
    globals: {str: GlobalInfo} = {},
    rodata: [int] = [],
    strs: {str: int} = {},
    data_size: int = 0,
    offsets: {str: int} = {},
    err: str = "",
    err_line: int = 0,
    err_col: int = 0,
    // the function being compiled
    scopes: [{str: Local}] = [],
    slots: int = 0,
    ret: str = "void",
    loops: [Loop] = [],
    exit_label: int = 0,
    crt: bool = false,
    captured: [str] = [],         // names closures in this function use (their `var`s get boxed)
    lambdas: int = 0,

    fn fail(self, e: Tree, msg: str) {
        if self.err == "" {
            self.err = msg
            self.err_line = e.line
            self.err_col = e.col
        }
    }

    // ---- data ----

    fn str_lit(self, s: str) -> int {
        if self.strs.contains(s) { return self.strs[s] }
        while self.rodata.len() % 8 != 0 { self.rodata.push(0) }
        let at = self.rodata.len()
        let n = s.len()
        for k in 0..8 { self.rodata.push(n >> (8 * k) & 255) }
        for k in 0..n { self.rodata.push(st_k_byte(s, k)) }
        self.rodata.push(0)
        self.strs[s] = at
        return at
    }

    // ---- locals ----

    fn scope_in(self) { self.scopes.push({}) }
    fn scope_out(self) { self.scopes.pop() }

    fn declare(self, e: Tree, name: str, ty: str, mutable: bool) -> int {
        let top = self.scopes[self.scopes.len() - 1]
        if top.contains(name) { self.fail(e, "`${name}` is already declared here") }
        let slot = self.slots
        self.slots += 1
        top[name] = Local { slot, ty, mutable }
        return slot
    }

    fn lookup(self, name: str) -> Local? {
        var k = self.scopes.len() - 1
        while k >= 0 {
            let s = self.scopes[k]
            if s.contains(name) { return some(s[name]) }
            k -= 1
        }
        return none
    }

    // a variable's value into rd, or rs into it (through its box when a closure shares it)
    fn read_var(self, l: Local, rd: int) {
        self.load_slot(rd, l.slot)
        if l.boxed { self.a.ld(rd, rd, 0) }
    }
    fn write_var(self, l: Local, rs: int) {
        if l.boxed {
            self.load_slot(rv.T1, l.slot)
            self.a.sd(rs, rv.T1, 0)
        } else {
            self.store_slot(rs, l.slot)
        }
    }

    // a new variable holding a0
    fn bind(self, e: Tree, name: str, ty: str, mutable: bool) {
        let slot = self.declare(e, name, ty, mutable)
        if mutable && self.captured.contains(name) {
            let top = self.scopes[self.scopes.len() - 1]
            top[name] = Local { slot, ty, mutable, boxed: true }
            let a = self.a
            a.push(rv.A0)
            a.li(rv.A0, 8)
            a.push(rv.A0)
            self.rt("__alloc", 1)
            a.pop(rv.T0)
            a.sd(rv.T0, rv.A0, 0)
        }
        self.store_slot(rv.A0, slot)
    }

    fn slot_off(self, slot: int) -> int { return -8 * (slot + 1) }
    fn load_slot(self, rd: int, slot: int) {
        let off = self.slot_off(slot)
        if rv.fits12(off) {
            self.a.ld(rd, rv.FP, off)
        } else {
            self.a.li(rv.T2, off)
            self.a.add(rv.T2, rv.FP, rv.T2)
            self.a.ld(rd, rv.T2, 0)
        }
    }
    fn store_slot(self, rs: int, slot: int) {
        let off = self.slot_off(slot)
        if rv.fits12(off) {
            self.a.sd(rs, rv.FP, off)
        } else {
            self.a.li(rv.T2, off)
            self.a.add(rv.T2, rv.FP, rv.T2)
            self.a.sd(rs, rv.T2, 0)
        }
    }

    // ---- calls ----

    // call a runtime function with `n` arguments already pushed
    fn rt(self, name: str, n: int) {
        self.a.call("f_" + name)
        if n > 0 { self.a.addi(rv.SP, rv.SP, 8 * n) }
    }

    // a runtime error at this line: a0 = message (a string), then __die
    fn die(self, e: Tree, msg: str) {
        self.a.addr_data(rv.A0, self.str_lit(msg))
        self.a.push(rv.A0)
        self.a.li(rv.A0, e.line)
        self.a.push(rv.A0)
        self.rt("__die", 2)
    }

    // ---- types ----

    fn same(self, a: str, b: str) -> bool { return a == b || a == "?" || b == "?" }

    fn check(self, e: Tree, got: str, want: str, what: str) {
        if !self.same(got, want) { self.fail(e, "${what}: expected ${want}, found ${got}") }
    }

    fn known_type(self, e: Tree, ty: str) {
        if ty == "int" || ty == "bool" || ty == "str" || ty == "float" || ty == "?" { return }
        if ty.ends_with("?") {
            self.known_type(e, ty.slice(0, ty.len() - 1))
            return
        }
        if ty.starts_with("{") {
            let kv = map_types(ty)
            if kv[0] != "int" && kv[0] != "str" { self.fail(e, "map keys are int or str, not ${kv[0]}") }
            self.known_type(e, kv[1])
            return
        }
        if ty.starts_with("fn(") {
            for p in fn_params(ty) { self.known_type(e, p) }
            let r = fn_ret(ty)
            if r != "void" { self.known_type(e, r) }
            return
        }
        if ty.starts_with("[") {
            self.known_type(e, elem(ty))
            return
        }
        if !self.structs.contains(ty) && !self.enums.contains(ty) { self.fail(e, "unknown type ${ty}") }
    }

    // the number of a variant of enum `ty`, or -1
    fn variant(self, ty: str, name: str) -> int {
        if !self.enums.contains(ty) { return -1 }
        return self.enums[ty].variants.index_of(name)
    }

    // ---- the program ----

    fn program(self, p: Program) {
        for s in p.structs {
            if self.structs.contains(s.name) { self.fail(Tree { k: "", line: s.line, col: s.col }, "struct ${s.name} is declared twice") }
            self.structs[s.name] = s
        }
        for en in p.enums {
            if self.structs.contains(en.name) || self.enums.contains(en.name) { self.fail(Tree { k: "", line: en.line, col: en.col }, "${en.name} is declared twice") }
            self.enums[en.name] = en
        }
        for f in p.fns {
            if f.owner != "" {
                self.funcs["${f.owner}.${f.name}"] = f
                continue
            }
            if self.funcs.contains(f.name) && self.err == "" {
                let what = if self.funcs[f.name].crt { "a built-in function" } else { "already declared" }
                self.fail(Tree { k: "", line: f.line, col: f.col }, "fn ${f.name}: ${what}")
            }
            self.funcs[f.name] = f
        }
        for s in p.structs {
            for f in s.fields { self.known_type(Tree { k: "", line: s.line, col: s.col }, f.ty) }
            for m in s.methods {
                self.funcs["${s.name}.${m.name}"] = m
            }
        }
        for f in self.funcs.values() {
            let at = Tree { k: "", line: f.line, col: f.col }
            for prm in f.params { self.known_type(at, prm.ty) }
            if f.ret != "void" { self.known_type(at, f.ret) }
        }
        if !self.funcs.contains("main") {
            self.fail(Tree { k: "", line: 1, col: 1 }, "the program needs a `fn main()` to start from")
        } else if !self.funcs["main"].params.is_empty() {
            let m = self.funcs["main"]
            self.fail(Tree { k: "", line: m.line, col: m.col }, "main takes no parameters")
        }
        // the entry: the heap's bounds from the kernel (in the first two data words), the
        // globals, main, exit(0)
        let a = self.a
        self.offsets["_start"] = 0
        self.data_size = 24
        a.mv(rv.FP, rv.SP)
        a.addr_var(rv.T0, 0)
        a.sd(rv.A0, rv.T0, 0)
        a.addr_var(rv.T0, 8)
        a.sd(rv.A1, rv.T0, 0)
        a.addr_var(rv.T0, 16)
        a.sd(rv.SP, rv.T0, 0)
        a.call("g_init")
        a.call("f_main")
        a.li(rv.A0, 0)
        a.li(rv.A7, 0)
        a.ecall()
        // the globals' initializers, in order (the runtime's first)
        self.offsets["g_init"] = a.here()
        self.begin_function("void", false)
        a.addi(rv.SP, rv.SP, -16)
        a.sd(rv.RA, rv.SP, 8)
        a.sd(rv.FP, rv.SP, 0)
        a.mv(rv.FP, rv.SP)
        let patch = self.a.here()
        a.emit(0)
        a.emit(0)
        a.sub(rv.SP, rv.SP, rv.T0)
        for g in p.globals {
            self.crt = g.crt
            let at = Tree { k: "", line: g.line, col: g.col }
            if self.globals.contains(g.name) || self.funcs.contains(g.name) { self.fail(at, "`${g.name}` is already declared") }
            if g.ty != "" { self.known_type(at, g.ty) }
            if g.constant && (g.init.k == "int" || g.init.k == "str" || g.init.k == "bool" || g.init.k == "float") {
                let ty = if g.init.k == "int" { "int" } else if g.init.k == "str" { "str" } else if g.init.k == "float" { "float" } else { "bool" }
                if g.ty != "" { self.check(at, ty, g.ty, "const ${g.name}") }
                self.globals[g.name] = GlobalInfo { off: -1, ty, mutable: false, value: g.init }
                continue
            }
            let ty = self.expr(g.init, g.ty)
            if g.ty != "" { self.check(g.init, ty, g.ty, "${g.name}") }
            if ty == "void" { self.fail(g.init, "this has no value") }
            let off = self.data_size
            self.data_size += 8
            a.addr_var(rv.T0, off)
            a.sd(rv.A0, rv.T0, 0)
            self.globals[g.name] = GlobalInfo { off, ty: if g.ty != "" { g.ty } else { ty }, mutable: g.mutable, value: Tree { k: "none" } }
        }
        self.crt = false
        self.end_function(patch)
        // the functions
        for name in self.funcs.keys() {
            let f = self.funcs[name]
            let label = if f.owner != "" { "m_${f.owner}_${f.name}" } else { "f_${f.name}" }
            self.offsets[label] = self.a.here()
            self.function(f)
            if self.err != "" { return }
        }
    }

    fn begin_function(self, ret: str, crt: bool) {
        self.scopes = [{}]
        self.slots = 0
        self.ret = ret
        self.loops = []
        self.crt = crt
        self.exit_label = self.a.label()
    }

    // the epilogue, and the frame size patched into the prologue
    fn end_function(self, patch: int) {
        let a = self.a
        a.place(self.exit_label)
        a.mv(rv.SP, rv.FP)
        a.ld(rv.RA, rv.SP, 8)
        a.ld(rv.FP, rv.SP, 0)
        a.addi(rv.SP, rv.SP, 16)
        a.ret()
        let size = (self.slots * 8 + 15) / 16 * 16
        let hi = (size + 0x800) >> 12
        let lo = size - (hi << 12)
        a.code[patch / 4] = rv.u(0x37, rv.T0, hi) & 0xffffffff
        a.code[patch / 4 + 1] = rv.i(0x1b, rv.T0, 0, rv.T0, lo) & 0xffffffff
    }

    fn function(self, f: FnDecl) {
        let a = self.a
        self.begin_function(f.ret, f.crt)
        self.captured = names_in_lambdas(f.body)
        a.addi(rv.SP, rv.SP, -16)
        a.sd(rv.RA, rv.SP, 8)
        a.sd(rv.FP, rv.SP, 0)
        a.mv(rv.FP, rv.SP)
        let patch = a.here()
        a.emit(0)
        a.emit(0)
        a.sub(rv.SP, rv.SP, rv.T0)
        // the parameters: copied from the caller's pushes into locals
        let n = f.params.len()
        for k, prm in f.params {
            let slot = self.declare(f.body, prm.name, prm.ty, true)
            a.ld(rv.T0, rv.FP, 16 + 8 * (n - 1 - k))
            self.store_slot(rv.T0, slot)
        }
        self.block(f.body)
        if f.ret != "void" && !returns(f.body) {
            self.die(Tree { k: "", line: f.line, col: f.col }, "fn ${f.name} ended without returning a value")
        }
        self.end_function(patch)
    }

    // ---- statements ----

    fn block(self, b: Tree) {
        self.scope_in()
        for st in b.kids {
            self.statement(st)
            if self.err != "" { break }
        }
        self.scope_out()
    }

    fn statement(self, st: Tree) {
        let a = self.a
        let k = st.k
        if k == "let" {
            if st.s2 != "" { self.known_type(st, st.s2) }
            let ty = self.expr(st.kids[0], st.s2)
            if ty == "void" { self.fail(st.kids[0], "this has no value to put in `${st.s}`") }
            if st.s2 != "" { self.check(st.kids[0], ty, st.s2, "`${st.s}`") }
            self.bind(st, st.s, if st.s2 != "" { st.s2 } else { ty }, st.n == 1)
        } else if k == "expr" {
            self.expr(st.kids[0], "")
        } else if k == "assign" {
            self.assign(st)
        } else if k == "if" && st.kids[0].k == "iflet" {
            let il = st.kids[0]
            let ot = self.expr(il.kids[0], "")
            if !ot.ends_with("?") { self.fail(il.kids[0], "`if let` needs an option (T?), not ${ot}") }
            let inner = if ot.ends_with("?") { ot.slice(0, ot.len() - 1) } else { ot }
            let otherwise = a.label()
            let end = a.label()
            a.jump_if_zero(rv.A0, otherwise)
            self.unwrap_reg(inner)
            self.scope_in()
            self.bind(il, il.s, inner, false)
            self.block(st.kids[1])
            self.scope_out()
            if st.kids.len() > 2 { a.jump(end) }
            a.place(otherwise)
            if st.kids.len() > 2 { self.block(st.kids[2]) }
            a.place(end)
        } else if k == "if" {
            let ct = self.expr(st.kids[0], "bool")
            self.check(st.kids[0], ct, "bool", "an `if` condition")
            let otherwise = a.label()
            let end = a.label()
            a.jump_if_zero(rv.A0, otherwise)
            self.block(st.kids[1])
            if st.kids.len() > 2 { a.jump(end) }
            a.place(otherwise)
            if st.kids.len() > 2 { self.block(st.kids[2]) }
            a.place(end)
        } else if k == "while" {
            let top = a.label()
            let end = a.label()
            a.place(top)
            let ct = self.expr(st.kids[0], "bool")
            self.check(st.kids[0], ct, "bool", "a `while` condition")
            a.jump_if_zero(rv.A0, end)
            self.loops.push(Loop { brk: end, cont: top })
            self.block(st.kids[1])
            self.loops.pop()
            a.jump(top)
            a.place(end)
        } else if k == "for_range" {
            self.scope_in()
            let lt = self.expr(st.kids[0], "int")
            self.check(st.kids[0], lt, "int", "a range")
            let iv = self.declare(st, st.s, "int", false)
            self.store_slot(rv.A0, iv)
            let ht = self.expr(st.kids[1], "int")
            self.check(st.kids[1], ht, "int", "a range")
            let hv = self.declare(st, " end", "int", false)
            self.store_slot(rv.A0, hv)
            let top = a.label()
            let cont = a.label()
            let end = a.label()
            a.place(top)
            self.load_slot(rv.T0, iv)
            self.load_slot(rv.T1, hv)
            a.slt(rv.A0, rv.T0, rv.T1)
            a.jump_if_zero(rv.A0, end)
            self.loops.push(Loop { brk: end, cont })
            self.block(st.kids[2])
            self.loops.pop()
            a.place(cont)
            self.load_slot(rv.T0, iv)
            a.addi(rv.T0, rv.T0, 1)
            self.store_slot(rv.T0, iv)
            a.jump(top)
            a.place(end)
            self.scope_out()
        } else if k == "for" {
            self.scope_in()
            var lt = self.expr(st.kids[0], "")
            var map_vals = -1
            if lt.starts_with("{") {
                // a map: its keys (and values, for `for k, v in m`)
                let kv = map_types(lt)
                if st.s2 != "" {
                    a.push(rv.A0)
                    self.rt("__m_values", 1)
                    map_vals = self.declare(st, " values", "[${kv[1]}]", false)
                    self.store_slot(rv.A0, map_vals)
                    // the map again for the keys
                    self.expr(st.kids[0], "")
                }
                a.push(rv.A0)
                self.rt("__m_keys", 1)
                lt = "[${kv[0]}]"
            }
            let is_str = lt == "str"
            if !is_str && !lt.starts_with("[") && lt != "?" { self.fail(st.kids[0], "`for` goes over a list, a map, a string or a range (a..b), not ${lt}") }
            let lv = self.declare(st, " list", lt, false)
            self.store_slot(rv.A0, lv)
            let pair = st.s2 != "" && map_vals < 0
            let idx = self.declare(st, if pair { st.s } else { " i" }, "int", false)
            a.li(rv.T0, 0)
            self.store_slot(rv.T0, idx)
            let ev = self.declare(st, if pair { st.s2 } else { st.s }, if is_str { "str" } else { elem(lt) }, false)
            var vv = -1
            if map_vals >= 0 {
                let vals_ty = self.lookup(" values").unwrap().ty
                vv = self.declare(st, st.s2, elem(vals_ty), false)
            }
            let top = a.label()
            let cont = a.label()
            let end = a.label()
            a.place(top)
            self.load_slot(rv.T0, lv)
            a.ld(rv.T1, rv.T0, 0)               // the length, every time round (the list may grow)
            self.load_slot(rv.T2, idx)
            a.slt(rv.A0, rv.T2, rv.T1)
            a.jump_if_zero(rv.A0, end)
            if is_str {
                a.push(rv.T0)
                a.push(rv.T2)
                self.rt("__s_char", 2)
            } else {
                a.ld(rv.T0, rv.T0, 16)
                a.slli(rv.T2, rv.T2, 3)
                a.add(rv.T0, rv.T0, rv.T2)
                a.ld(rv.A0, rv.T0, 0)
            }
            self.store_slot(rv.A0, ev)
            if vv >= 0 {
                self.load_slot(rv.T0, map_vals)
                a.ld(rv.T0, rv.T0, 16)
                self.load_slot(rv.T2, idx)
                a.slli(rv.T2, rv.T2, 3)
                a.add(rv.T0, rv.T0, rv.T2)
                a.ld(rv.T0, rv.T0, 0)
                self.store_slot(rv.T0, vv)
            }
            self.loops.push(Loop { brk: end, cont })
            self.block(st.kids[1])
            self.loops.pop()
            a.place(cont)
            self.load_slot(rv.T0, idx)
            a.addi(rv.T0, rv.T0, 1)
            self.store_slot(rv.T0, idx)
            a.jump(top)
            a.place(end)
            self.scope_out()
        } else if k == "break" || k == "continue" {
            if self.loops.is_empty() {
                self.fail(st, "`${k}` outside a loop")
                return
            }
            let l = self.loops[self.loops.len() - 1]
            a.jump(if k == "break" { l.brk } else { l.cont })
        } else if k == "return" {
            if self.ret == "?" {
                // a lambda whose type comes from its first return
                if st.kids.is_empty() {
                    self.ret = "void"
                } else {
                    self.ret = self.expr(st.kids[0], "")
                }
                a.jump(self.exit_label)
                return
            }
            if st.kids.is_empty() {
                if self.ret != "void" { self.fail(st, "this function returns ${self.ret}: `return` needs a value") }
            } else {
                if self.ret == "void" { self.fail(st, "this function doesn't return a value (add `-> type` to its signature)") }
                let ty = self.expr(st.kids[0], self.ret)
                self.check(st.kids[0], ty, self.ret, "the return value")
            }
            a.jump(self.exit_label)
        } else if k == "match" {
            self.match_(st, false, "")
        } else {
            self.fail(st, "unexpected ${k}")
        }
    }

    // match: compare the value with each arm in turn. As an expression (value), each arm gives a
    // value and the type is returned.
    fn match_(self, st: Tree, value: bool, want: str) -> str {
        let a = self.a
        self.scope_in()
        let vt = self.expr(st.kids[0], "")
        let is_enum = self.enums.contains(vt)
        if vt != "int" && vt != "str" && vt != "bool" && vt != "?" && !is_enum { self.fail(st.kids[0], "match works on int, str, bool and enums, not ${vt}") }
        let v = self.declare(st, " match", vt, false)
        self.store_slot(rv.A0, v)
        let end = a.label()
        var covered: [str] = []
        var wild = false
        var ty = if value { want } else { "void" }
        var first = true
        for k in 1..st.kids.len() {
            let arm = st.kids[k]
            let next = a.label()
            self.scope_in()
            if arm.n == 0 && is_enum {
                // each alternative: its own test; the first that fits runs the body
                let body_l = a.label()
                let alts = arm.kids.len() - 1
                for pk in 0..alts {
                    let pat = arm.kids[pk]
                    let miss = a.label()
                    self.pattern(pat, v, vt, miss, alts == 1)
                    covered.push(pattern_variant(pat))
                    a.jump(body_l)
                    a.place(miss)
                }
                a.jump(next)
                a.place(body_l)
            } else if arm.n == 0 {
                let body_l = a.label()
                for pk in 0..arm.kids.len() - 1 {
                    let pat = arm.kids[pk]
                    if is_enum && pat.k == "name" && self.lookup(pat.s) == none && self.variant(vt, pat.s) >= 0 {
                        a.li(rv.A0, self.variant(vt, pat.s))
                        covered.push(pat.s)
                    } else {
                        let pt = self.expr(pat, vt)
                        self.check(pat, pt, vt, "a match pattern")
                        if is_enum && pat.k == "variant" { covered.push(pat.s) }
                        if is_enum && pat.k == "field" { covered.push(pat.s) }
                    }
                    self.load_slot(rv.T0, v)
                    if vt == "str" {
                        a.push(rv.T0)
                        a.push(rv.A0)
                        self.rt("__str_eq", 2)
                    } else {
                        a.xor(rv.A0, rv.A0, rv.T0)
                        a.seqz(rv.A0, rv.A0)
                    }
                    a.jump_if_not_zero(rv.A0, body_l)
                }
                a.jump(next)
                a.place(body_l)
            } else {
                wild = true
            }
            if value {
                let t = self.value_block(arm.kids[arm.kids.len() - 1], ty)
                if first || ty == "" || ty == "?" { ty = t } else if !self.same(t, ty) { self.fail(arm, "this arm gives ${t}, the others ${ty}") }
                first = false
            } else {
                self.block(arm.kids[arm.kids.len() - 1])
            }
            self.scope_out()
            a.jump(end)
            a.place(next)
        }
        if is_enum && !wild {
            let missing = self.enums[vt].variants.filter(x => !covered.contains(x))
            if !missing.is_empty() { self.fail(st, "this match on ${vt} misses ${missing.join(", ")} (or add `_ =>`)") }
        }
        if value && !wild && !is_enum {
            self.die(st, "no arm of the match fits the value")
        }
        a.place(end)
        self.scope_out()
        return ty
    }

    fn assign(self, st: Tree) {
        let a = self.a
        let target = st.kids[0]
        let value = st.kids[1]
        let op = st.s
        if target.k == "name" {
            if let l = self.lookup(target.s) {
                if !l.mutable { self.fail(target, "`${target.s}` can't change: declare it with `var`") }
                if op == "=" {
                    let ty = self.expr(value, l.ty)
                    self.check(value, ty, l.ty, "`${target.s}`")
                } else {
                    self.compound(st, l.ty, () => self.read_var(l, rv.A0))
                }
                self.write_var(l, rv.A0)
                return
            }
            if self.globals.contains(target.s) {
                let g = self.globals[target.s]
                if !g.mutable { self.fail(target, "`${target.s}` can't change: declare it with `var`") }
                if op == "=" {
                    let ty = self.expr(value, g.ty)
                    self.check(value, ty, g.ty, "`${target.s}`")
                } else {
                    self.compound(st, g.ty, () => {
                        a.addr_var(rv.T0, g.off)
                        a.ld(rv.A0, rv.T0, 0)
                    })
                }
                a.addr_var(rv.T0, g.off)
                a.sd(rv.A0, rv.T0, 0)
                return
            }
            self.fail(target, "no variable called `${target.s}`")
            return
        }
        if target.k == "field" {
            let ot = self.expr(target.kids[0], "")
            let off = self.field_offset(target, ot, target.s)
            let fty = self.field_type(ot, target.s)
            a.push(rv.A0)
            if op == "=" {
                let ty = self.expr(value, fty)
                self.check(value, ty, fty, "field ${target.s}")
            } else {
                self.compound(st, fty, () => {
                    a.ld(rv.T0, rv.SP, 0)
                    a.ld(rv.A0, rv.T0, off)
                })
            }
            a.pop(rv.T0)
            a.sd(rv.A0, rv.T0, off)
            return
        }
        if target.k == "index" {
            let lt = self.expr(target.kids[0], "")
            if lt.starts_with("{") {
                let kv = map_types(lt)
                a.push(rv.A0)
                let kt = self.expr(target.kids[1], kv[0])
                self.check(target.kids[1], kt, kv[0], "a key")
                a.push(rv.A0)
                if op == "=" {
                    let ty = self.expr(value, kv[1])
                    self.check(value, ty, kv[1], "a map value")
                } else {
                    self.compound(st, kv[1], () => {
                        a.ld(rv.T0, rv.SP, 8)
                        a.push(rv.T0)
                        a.ld(rv.T0, rv.SP, 8)
                        a.push(rv.T0)
                        a.li(rv.A0, st.line)
                        a.push(rv.A0)
                        self.rt("__m_get", 3)
                    })
                }
                a.push(rv.A0)
                self.rt("__m_set", 3)
                return
            }
            if !lt.starts_with("[") {
                if lt == "str" { self.fail(target, "strings can't change: build a new one (s.slice, +)") } else { self.fail(target, "only lists can be indexed, not ${lt}") }
                return
            }
            a.push(rv.A0)
            let it = self.expr(target.kids[1], "int")
            self.check(target.kids[1], it, "int", "an index")
            a.ld(rv.T0, rv.SP, 0)
            self.element_address(target)       // t0 = &list[i]
            a.push(rv.T0)
            let et = elem(lt)
            if op == "=" {
                let ty = self.expr(value, et)
                self.check(value, ty, et, "a list element")
            } else {
                self.compound(st, et, () => {
                    a.ld(rv.T0, rv.SP, 0)
                    a.ld(rv.A0, rv.T0, 0)
                })
            }
            a.pop(rv.T0)
            a.addi(rv.SP, rv.SP, 8)
            a.sd(rv.A0, rv.T0, 0)
            return
        }
        self.fail(target, "can't assign to this")
    }

    // x op= value: `load` puts the old value in a0; leaves the new value in a0
    fn compound(self, st: Tree, ty: str, load: fn()) {
        let a = self.a
        let op = st.s.slice(0, st.s.len() - 1)
        load()
        a.push(rv.A0)
        if ty == "str" && op == "+" {
            let vt = self.expr(st.kids[1], "")
            self.to_str(st.kids[1], vt)
            a.push(rv.A0)
            self.rt("__str_cat", 2)
            return
        }
        if ty == "float" {
            let vt = self.expr(st.kids[1], "float")
            self.check(st.kids[1], vt, "float", "`${st.s}`")
            a.pop(rv.T0)
            if op != "+" && op != "-" && op != "*" && op != "/" { self.fail(st, "`${st.s}` doesn't work on floats") }
            a.fmv_dx(0, rv.T0)
            a.fmv_dx(1, rv.A0)
            a.fop(if op == "+" { 0x01 } else if op == "-" { 0x05 } else if op == "*" { 0x09 } else { 0x0d }, 0, 0, 1)
            a.fmv_xd(rv.A0, 0)
            return
        }
        if ty != "int" && ty != "?" { self.fail(st, "`${st.s}` works on int and float (and += on str), not ${ty}") }
        let vt = self.expr(st.kids[1], "int")
        self.check(st.kids[1], vt, "int", "`${st.s}`")
        a.pop(rv.T0)
        self.arith(st, op)
    }

    // t0 (a list) and a0 (an index) -> t0 = the element's address; a runtime error if out of range
    fn element_address(self, e: Tree) {
        let a = self.a
        let ok_l = a.label()
        a.ld(rv.T1, rv.T0, 0)
        a.sltu(rv.T2, rv.A0, rv.T1)       // unsigned: negative indexes are huge
        a.jump_if_not_zero(rv.T2, ok_l)
        a.push(rv.A0)
        a.push(rv.T1)
        a.li(rv.A0, e.line)
        a.push(rv.A0)
        self.rt("__oob", 3)
        a.place(ok_l)
        a.ld(rv.T0, rv.T0, 16)
        a.slli(rv.T1, rv.A0, 3)
        a.add(rv.T0, rv.T0, rv.T1)
    }

    fn field_index(self, e: Tree, ty: str, name: str) -> int {
        if !self.structs.contains(ty) {
            if ty != "?" { self.fail(e, "${ty} has no fields (`.${name}`)") }
            return -1
        }
        let sd = self.structs[ty]
        for k, f in sd.fields {
            if f.name == name { return k }
        }
        self.fail(e, "${ty} has no field `${name}`")
        return -1
    }
    fn field_offset(self, e: Tree, ty: str, name: str) -> int { return max(0, self.field_index(e, ty, name)) * 8 }
    fn field_type(self, ty: str, name: str) -> str {
        if !self.structs.contains(ty) { return "?" }
        for f in self.structs[ty].fields {
            if f.name == name { return f.ty }
        }
        return "?"
    }

    // ---- expressions: the value ends up in a0; returns its type ----

    // an expression; an int where a float is wanted becomes a float
    fn expr(self, e: Tree, want: str) -> str {
        let t = self.expr_raw(e, want)
        if want == "float" && t == "int" {
            self.int_to_float(rv.A0)
            return "float"
        }
        if want.ends_with("?") && t != want && t != "?" {
            let inner = want.slice(0, want.len() - 1)
            if t == "none" { return want }
            if t == inner || (inner == "float" && t == "int") {
                if inner == "float" && t == "int" { self.int_to_float(rv.A0) }
                self.wrap(inner)
                return want
            }
        }
        return t
    }

    // a value (in a0) as an option: values that aren't pointers go in a box
    fn wrap(self, inner: str) {
        if !boxed_option(inner, self.enums) { return }
        let a = self.a
        a.push(rv.A0)
        a.li(rv.A0, 8)
        a.push(rv.A0)
        self.rt("__alloc", 1)
        a.pop(rv.T0)
        a.sd(rv.T0, rv.A0, 0)
    }

    // an option (in a0, known not none) -> its value
    fn unwrap_reg(self, inner: str) {
        if boxed_option(inner, self.enums) { self.a.ld(rv.A0, rv.A0, 0) }
    }

    fn int_to_float(self, reg: int) {
        self.a.fcvt_dl(0, reg)
        self.a.fmv_xd(reg, 0)
    }

    fn expr_raw(self, e: Tree, want: str) -> str {
        if self.err != "" { return "?" }
        let a = self.a
        let k = e.k
        if k == "float" {
            // parsed here, written as its exact bits
            let x = float(e.s) catch 0.0
            a.li(rv.A0, float_bits(x))
            return "float"
        }
        if k == "int" {
            a.li(rv.A0, e.n)
            return "int"
        }
        if k == "bool" {
            a.li(rv.A0, e.n)
            return "bool"
        }
        if k == "str" {
            a.addr_data(rv.A0, self.str_lit(e.s))
            return "str"
        }
        if k == "interp" {
            var first = true
            for part in e.kids {
                let pt = self.expr(part, "")
                self.to_str(part, pt)
                if !first {
                    a.pop(rv.T0)
                    a.push(rv.T0)
                    a.push(rv.A0)
                    self.rt("__str_cat", 2)
                }
                a.push(rv.A0)
                first = false
            }
            a.pop(rv.A0)
            return "str"
        }
        if k == "name" { return self.name(e) }
        if k == "list" { return self.list(e, want) }
        if k == "map" { return self.map_lit(e, want) }
        if k == "new" { return self.construct(e) }
        if k == "bin" { return self.binary(e) }
        if k == "un" {
            let t = self.expr(e.kids[0], "")
            if e.s == "!" {
                self.check(e, t, "bool", "`!`")
                a.seqz(rv.A0, rv.A0)
                return "bool"
            }
            if t == "float" && e.s == "-" {
                a.fmv_dx(0, rv.A0)
                a.fsgnj(1, 0, 0, 0)
                a.fmv_xd(rv.A0, 0)
                return "float"
            }
            self.check(e, t, "int", "`${e.s}`")
            if e.s == "-" { a.neg(rv.A0, rv.A0) } else { a.xori(rv.A0, rv.A0, -1) }
            return "int"
        }
        if k == "field" && e.kids[0].k == "name" && self.enums.contains(e.kids[0].s) && self.lookup(e.kids[0].s) == none {
            return self.make_variant(e, e.kids[0].s, e.s, [], 0)
        }
        if k == "variant" {
            let ty = if e.s2 != "" { e.s2 } else { want }
            if !self.enums.contains(ty) {
                self.fail(e, "`.${e.s}`: which enum? (write Type.${e.s} where the type isn't clear)")
                return "?"
            }
            return self.make_variant(e, ty, e.s, e.kids, e.n)
        }
        if k == "matchx" { return self.match_(e, true, want) }
        if k == "lambda" { return self.lambda(e, want) }
        if k == "none" {
            a.li(rv.A0, 0)
            return if want.ends_with("?") { want } else { "none" }
        }
        if k == "field" {
            let ot = self.expr(e.kids[0], "")
            if (ot == "str" || ot.starts_with("[")) && e.s == "len" {
                self.fail(e, "len is a method: `.len()`")
                return "int"
            }
            let idx = self.field_index(e, ot, e.s)
            a.ld(rv.A0, rv.A0, max(0, idx) * 8)
            return self.field_type(ot, e.s)
        }
        if k == "index" {
            let lt = self.expr(e.kids[0], "")
            a.push(rv.A0)
            if lt.starts_with("{") {
                let kv = map_types(lt)
                let kt = self.expr(e.kids[1], kv[0])
                self.check(e.kids[1], kt, kv[0], "a key")
                a.push(rv.A0)
                a.li(rv.A0, e.line)
                a.push(rv.A0)
                self.rt("__m_get", 3)
                return kv[1]
            }
            let it = self.expr(e.kids[1], "int")
            self.check(e.kids[1], it, "int", "an index")
            if lt == "str" {
                a.push(rv.A0)
                a.li(rv.A0, e.line)
                a.push(rv.A0)
                self.rt("__s_at", 3)
                return "str"
            }
            if lt.starts_with("{") { self.fail(e, "internal: map index") }
            a.pop(rv.T0)
            if !lt.starts_with("[") {
                if lt != "?" { self.fail(e, "only lists and strings can be indexed, not ${lt}") }
                return "?"
            }
            self.element_address(e)
            a.ld(rv.A0, rv.T0, 0)
            return elem(lt)
        }
        if k == "call" { return self.call(e, want) }
        if k == "mcall" { return self.method(e, want) }
        if k == "ifx" {
            let ct = self.expr(e.kids[0], "bool")
            self.check(e.kids[0], ct, "bool", "an `if` condition")
            let otherwise = a.label()
            let end = a.label()
            a.jump_if_zero(rv.A0, otherwise)
            let t1 = self.value_block(e.kids[1], want)
            a.jump(end)
            a.place(otherwise)
            let t2 = self.value_block(e.kids[2], if want != "" { want } else { t1 })
            a.place(end)
            if !self.same(t1, t2) { self.fail(e, "the two branches give different types: ${t1} and ${t2}") }
            return if t1 == "?" { t2 } else { t1 }
        }
        self.fail(e, "unexpected ${k}")
        return "?"
    }

    // { statements...; value }
    fn value_block(self, b: Tree, want: str) -> str {
        self.scope_in()
        var ty = "void"
        for k, st in b.kids {
            if k == b.kids.len() - 1 {
                if st.k != "expr" {
                    self.fail(st, "this `if` gives a value: end the block with one")
                } else {
                    ty = self.expr(st.kids[0], want)
                }
            } else {
                self.statement(st)
            }
        }
        if b.kids.is_empty() { self.fail(b, "this `if` gives a value: the block can't be empty") }
        self.scope_out()
        return ty
    }

    fn name(self, e: Tree) -> str {
        let a = self.a
        if let l = self.lookup(e.s) {
            self.read_var(l, rv.A0)
            return l.ty
        }
        if self.globals.contains(e.s) {
            let g = self.globals[e.s]
            if g.value.k != "none" { return self.expr(g.value, "") }
            a.addr_var(rv.T0, g.off)
            a.ld(rv.A0, rv.T0, 0)
            return g.ty
        }
        if self.funcs.contains(e.s) && !e.s.starts_with("__") {
            // a function as a value: a closure with nothing captured
            let f = self.funcs[e.s]
            a.li(rv.A0, 8)
            a.push(rv.A0)
            self.rt("__alloc", 1)
            a.addr_fn(rv.T0, "f_" + e.s)
            a.sd(rv.T0, rv.A0, 0)
            return "fn(" + f.params.map(p => p.ty).join(",") + ")->" + f.ret
        } else {
            self.fail(e, "no variable called `${e.s}`")
        }
        return "?"
    }

    fn list(self, e: Tree, want: str) -> str {
        let a = self.a
        var ty = if want.starts_with("[") { want } else { "" }
        a.li(rv.A0, max(4, e.kids.len()))
        a.push(rv.A0)
        self.rt("__l_new", 1)
        a.push(rv.A0)
        for x in e.kids {
            let xt = self.expr(x, if ty != "" { elem(ty) } else { "" })
            if xt == "void" { self.fail(x, "this has no value") }
            if ty == "" { ty = "[${xt}]" } else { self.check(x, xt, elem(ty), "a list element") }
            a.ld(rv.T0, rv.SP, 0)
            a.push(rv.T0)
            a.push(rv.A0)
            self.rt("__l_push", 2)
        }
        a.pop(rv.A0)
        if ty == "" {
            self.fail(e, "an empty list needs a type: `var xs: [int] = []`")
            return "?"
        }
        return ty
    }

    // a0 holds an index (or -1): the element there as an option. `elements` puts the elements'
    // address in t0 (it may use a0; the index is kept on the stack meanwhile).
    fn option_from_index(self, e: Tree, inner: str, elements: fn()) {
        let a = self.a
        let none_l = a.label()
        let done = a.label()
        a.slt(rv.T0, rv.A0, rv.ZERO)
        a.jump_if_not_zero(rv.T0, none_l)
        a.push(rv.A0)
        elements()
        a.pop(rv.T1)
        a.slli(rv.T1, rv.T1, 3)
        a.add(rv.T0, rv.T0, rv.T1)
        a.ld(rv.A0, rv.T0, 0)
        self.wrap(inner)
        a.jump(done)
        a.place(none_l)
        a.li(rv.A0, 0)
        a.place(done)
    }

    fn map_lit(self, e: Tree, want: str) -> str {
        let a = self.a
        var ty = if want.starts_with("{") { want } else { "" }
        if ty == "" && e.kids.is_empty() {
            self.fail(e, "an empty map needs a type: `var m: {str: int} = {}`")
            return "?"
        }
        // the key type decides how keys compare: find it first
        var kt = if ty != "" { map_types(ty)[0] } else { "" }
        let fix_at = a.here()                     // this li (the kind of keys) is patched once that's known
        a.li(rv.A0, 0)
        a.push(rv.A0)
        self.rt("__m_new", 1)
        a.push(rv.A0)
        var k = 0
        while k + 1 < e.kids.len() {
            a.ld(rv.T0, rv.SP, 0)
            a.push(rv.T0)
            let t1 = self.expr(e.kids[k], if ty != "" { map_types(ty)[0] } else { "" })
            a.push(rv.A0)
            let t2 = self.expr(e.kids[k + 1], if ty != "" { map_types(ty)[1] } else { "" })
            a.push(rv.A0)
            if ty == "" {
                ty = "{" + t1 + ":" + t2 + "}"
                kt = t1
            } else {
                self.check(e.kids[k], t1, map_types(ty)[0], "a key")
                self.check(e.kids[k + 1], t2, map_types(ty)[1], "a value")
            }
            self.rt("__m_set", 3)
            k += 2
        }
        if kt != "int" && kt != "str" && kt != "?" { self.fail(e, "map keys are int or str, not ${kt}") }
        // __m_new's argument: 1 for str keys
        a.code[fix_at / 4] = rv.i(0x13, rv.A0, 0, rv.ZERO, if kt == "str" { 1 } else { 0 }) & 0xffffffff
        a.pop(rv.A0)
        return ty
    }

    // An enum value: a plain enum's number, or for an enum that carries values, a new [tag, values...].
    // form: 0 just the name, 1 (positional values), 2 { named values }
    fn make_variant(self, e: Tree, ty: str, vname: str, vals: [Tree], form: int) -> str {
        let a = self.a
        let ed = self.enums[ty]
        let v = ed.variants.index_of(vname)
        if v < 0 {
            self.fail(e, "${ty} has no variant ${vname} (it has ${ed.variants.join(", ")})")
            return ty
        }
        let fs = ed.fields[v]
        if !ed.data {
            if form != 0 { self.fail(e, "${ty}.${vname} carries no values") }
            a.li(rv.A0, v)
            return ty
        }
        if form == 1 && vals.len() != fs.len() {
            self.fail(e, "${ty}.${vname} takes ${fs.len()} value${if fs.len() == 1 { "" } else { "s" }}, given ${vals.len()}")
            return ty
        }
        if form == 0 && !fs.is_empty() && fs.any(f => !f.has_def && !f.ty.ends_with("?")) {
            self.fail(e, "${ty}.${vname} carries values: ${ty}.${vname}(...)")
            return ty
        }
        if form == 2 {
            for fi in vals {
                if fs.find(f => f.name == fi.s) == none { self.fail(fi, "${ty}.${vname} has no field `${fi.s}`") }
            }
        }
        a.li(rv.A0, 8 * (1 + fs.len()))
        a.push(rv.A0)
        self.rt("__alloc", 1)
        a.li(rv.T0, v)
        a.sd(rv.T0, rv.A0, 0)
        a.push(rv.A0)
        for k, f in fs {
            if form == 1 {
                let t = self.expr(vals[k], f.ty)
                self.check(vals[k], t, f.ty, "${vname}'s value ${k + 1}")
            } else {
                var given: Tree? = none
                if form == 2 { given = vals.find(fi => fi.s == f.name) }
                if let g = given {
                    let t = self.expr(g.kids[0], f.ty)
                    self.check(g.kids[0], t, f.ty, "field ${f.name}")
                } else if f.has_def {
                    let t = self.expr(f.def, f.ty)
                    self.check(f.def, t, f.ty, "field ${f.name}")
                } else if f.ty.ends_with("?") {
                    a.li(rv.A0, 0)
                } else {
                    self.fail(e, "${ty}.${vname} needs a value for `${f.name}`")
                }
            }
            a.ld(rv.T0, rv.SP, 0)
            a.sd(rv.A0, rv.T0, 8 * (k + 1))
        }
        a.pop(rv.A0)
        return ty
    }

    // Code out of line, right here (jumped over): a function `label` taking `nparams` words; `body`
    // generates it (the parameters are locals " p0", " p1", ...).
    fn out_of_line(self, label: str, nparams: int, ret: str, body: fn()) {
        let a = self.a
        let over = a.label()
        a.jump(over)
        self.offsets[label] = a.here()
        let saved_scopes = self.scopes
        let saved_slots = self.slots
        let saved_ret = self.ret
        let saved_loops = self.loops
        let saved_exit = self.exit_label
        let saved_captured = self.captured
        self.begin_function(ret, self.crt)
        self.captured = []
        a.addi(rv.SP, rv.SP, -16)
        a.sd(rv.RA, rv.SP, 8)
        a.sd(rv.FP, rv.SP, 0)
        a.mv(rv.FP, rv.SP)
        let patch = a.here()
        a.emit(0)
        a.emit(0)
        a.sub(rv.SP, rv.SP, rv.T0)
        for k in 0..nparams {
            let slot = self.declare(Tree { k: "" }, " p${k}", "int", false)
            a.ld(rv.T0, rv.FP, 16 + 8 * (nparams - 1 - k))
            self.store_slot(rv.T0, slot)
        }
        body()
        self.end_function(patch)
        self.scopes = saved_scopes
        self.slots = saved_slots
        self.ret = saved_ret
        self.loops = saved_loops
        self.exit_label = saved_exit
        self.captured = saved_captured
        a.place(over)
    }

    // a value-carrying enum as text: Circle(1.0), Rect { w: 2.0, h: 1.0 }, Empty
    fn show_enum(self, e: Tree, ty: str) {
        let a = self.a
        let label = "s_" + ty
        if !self.offsets.contains(label) {
            self.offsets[label] = -1          // taken (recursive types call it from inside)
            let ed = self.enums[ty]
            self.out_of_line(label, 1, "str", () => {
                let done = self.exit_label
                for v, vname in ed.variants {
                    let next = a.label()
                    let p0 = self.lookup(" p0").unwrap()
                    self.load_slot(rv.T0, p0.slot)
                    a.ld(rv.T0, rv.T0, 0)
                    a.li(rv.T1, v)
                    a.xor(rv.T1, rv.T1, rv.T0)
                    a.jump_if_not_zero(rv.T1, next)
                    let fs = ed.fields[v]
                    let br = ed.braces[v]
                    a.addr_data(rv.A0, self.str_lit(if fs.is_empty() { vname } else if br { vname + " { " } else { vname + "(" }))
                    for k, f in fs {
                        a.push(rv.A0)
                        var sep = if k == 0 { "" } else { ", " }
                        if br { sep = sep + f.name + ": " }
                        if sep != "" {
                            a.addr_data(rv.A0, self.str_lit(sep))
                            a.push(rv.A0)
                            self.rt("__str_cat", 2)
                            a.push(rv.A0)
                        }
                        self.load_slot(rv.T0, p0.slot)
                        a.ld(rv.A0, rv.T0, 8 * (k + 1))
                        if f.ty == "str" {
                            a.push(rv.A0)
                            a.li(rv.A0, 0)
                            a.push(rv.A0)
                            self.rt("__quote", 2)
                        } else {
                            self.to_str(e, f.ty)
                        }
                        a.push(rv.A0)
                        self.rt("__str_cat", 2)
                    }
                    if !fs.is_empty() {
                        a.push(rv.A0)
                        a.addr_data(rv.A0, self.str_lit(if br { " }" } else { ")" }))
                        a.push(rv.A0)
                        self.rt("__str_cat", 2)
                    }
                    a.jump(done)
                    a.place(next)
                }
                a.addr_data(rv.A0, self.str_lit("?"))
            })
        }
        a.push(rv.A0)
        self.a.call(label)
        a.addi(rv.SP, rv.SP, 8)
    }

    // Does the value in local `slot` (of enum `ty`) fit pattern `pat`? Jumps to `fail` if not;
    // names in the pattern become locals. `binds`: whether it may bind names.
    fn pattern(self, pat: Tree, slot: int, ty: str, fail: int, binds: bool) {
        let a = self.a
        let ed = self.enums[ty]
        var vname = ""
        var subs: [Tree] = []
        var form = 0
        if pat.k == "name" { vname = pat.s }
        else if pat.k == "call" {
            vname = pat.s
            subs = pat.kids
            form = 1
        } else if pat.k == "new" {
            vname = pat.s
            subs = pat.kids
            form = 2
        } else if pat.k == "variant" {
            vname = pat.s
            subs = pat.kids
            form = pat.n
        } else if pat.k == "field" && pat.kids[0].k == "name" && pat.kids[0].s == ty {
            vname = pat.s
        } else if pat.k == "mcall" && pat.kids[0].k == "name" && pat.kids[0].s == ty {
            vname = pat.s
            subs = pat.kids.slice(1, pat.kids.len())
            form = 1
        } else {
            self.fail(pat, "a pattern for ${ty}: Variant, Variant(x, _), Variant { field }, .Variant")
            return
        }
        let v = ed.variants.index_of(vname)
        if v < 0 {
            self.fail(pat, "${ty} has no variant ${vname}")
            return
        }
        // the tag
        self.load_slot(rv.T0, slot)
        if ed.data { a.ld(rv.T0, rv.T0, 0) }
        a.li(rv.T1, v)
        a.xor(rv.T1, rv.T1, rv.T0)
        a.jump_if_not_zero(rv.T1, fail)
        let fs = ed.fields[v]
        if form == 1 && subs.len() != fs.len() {
            self.fail(pat, "${vname} carries ${fs.len()} value${if fs.len() == 1 { "" } else { "s" }}: write all of them (_ for any)")
            return
        }
        for k, sub0 in subs {
            var fi = k
            var sub = sub0
            if form == 2 {
                fi = -1
                for j, f in fs {
                    if f.name == sub0.s { fi = j }
                }
                if fi < 0 {
                    self.fail(sub0, "${vname} has no field `${sub0.s}`")
                    return
                }
                sub = sub0.kids[0]
            }
            let fty = fs[fi].ty
            self.load_slot(rv.T0, slot)
            a.ld(rv.A0, rv.T0, 8 * (fi + 1))
            if sub.k == "name" && sub.s == "_" { continue }
            if sub.k == "name" && !(self.enums.contains(fty) && self.variant(fty, sub.s) >= 0) {
                if !binds { self.fail(sub, "patterns joined with | can't name values") }
                self.bind(sub, sub.s, fty, false)
                continue
            }
            if self.enums.contains(fty) && (sub.k == "name" || sub.k == "call" || sub.k == "new" || sub.k == "variant" || sub.k == "field" || sub.k == "mcall") {
                let inner = self.declare(sub, " sub${self.slots}", fty, false)
                self.store_slot(rv.A0, inner)
                self.pattern(sub, inner, fty, fail, binds)
                continue
            }
            // a literal: compare
            let held = self.declare(sub, " lit${self.slots}", fty, false)
            self.store_slot(rv.A0, held)
            let lt = self.expr(sub, fty)
            self.check(sub, lt, fty, "a pattern")
            self.load_slot(rv.T0, held)
            if fty == "str" {
                a.push(rv.T0)
                a.push(rv.A0)
                self.rt("__str_eq", 2)
                a.jump_if_zero(rv.A0, fail)
            } else {
                a.xor(rv.A0, rv.A0, rv.T0)
                a.jump_if_not_zero(rv.A0, fail)
            }
        }
    }

    fn construct(self, e: Tree) -> str {
        let a = self.a
        if !self.structs.contains(e.s) {
            self.fail(e, "no struct called ${e.s}")
            return "?"
        }
        let sd = self.structs[e.s]
        for fi in e.kids {
            if sd.fields.find(f => f.name == fi.s) == none { self.fail(fi, "${e.s} has no field `${fi.s}`") }
        }
        a.li(rv.A0, max(8, 8 * sd.fields.len()))
        a.push(rv.A0)
        self.rt("__alloc", 1)
        a.push(rv.A0)
        for k, f in sd.fields {
            let given = e.kids.find(fi => fi.s == f.name)
            if let g = given {
                let t = self.expr(g.kids[0], f.ty)
                self.check(g.kids[0], t, f.ty, "field ${f.name}")
            } else if f.has_def {
                let t = self.expr(f.def, f.ty)
                self.check(f.def, t, f.ty, "field ${f.name}")
            } else if f.ty.ends_with("?") {
                a.li(rv.A0, 0)
            } else {
                self.fail(e, "${e.s} needs a value for `${f.name}` (it has no default)")
            }
            a.ld(rv.T0, rv.SP, 0)
            a.sd(rv.A0, rv.T0, 8 * k)
        }
        a.pop(rv.A0)
        return e.s
    }

    fn binary(self, e: Tree) -> str {
        let a = self.a
        let op = e.s
        if op == "??" {
            let lt = self.expr(e.kids[0], "")
            if !lt.ends_with("?") {
                self.fail(e.kids[0], "`??` needs an option on its left (T?), not ${lt}")
                return lt
            }
            let inner = lt.slice(0, lt.len() - 1)
            let other = a.label()
            let end = a.label()
            a.jump_if_zero(rv.A0, other)
            self.unwrap_reg(inner)
            a.jump(end)
            a.place(other)
            let rt2 = self.expr(e.kids[1], inner)
            self.check(e.kids[1], rt2, inner, "`??`")
            a.place(end)
            return inner
        }
        if op == "&&" || op == "||" {
            let end = a.label()
            let lt = self.expr(e.kids[0], "bool")
            self.check(e.kids[0], lt, "bool", "`${op}`")
            if op == "&&" { a.jump_if_zero(rv.A0, end) } else { a.jump_if_not_zero(rv.A0, end) }
            let rt2 = self.expr(e.kids[1], "bool")
            self.check(e.kids[1], rt2, "bool", "`${op}`")
            a.place(end)
            return "bool"
        }
        let lt = self.expr(e.kids[0], "")
        a.push(rv.A0)
        let rt2 = self.expr(e.kids[1], if lt == "?" { "" } else { lt })
        a.pop(rv.T0)                      // t0 = left, a0 = right
        if lt == "str" || rt2 == "str" {
            if op == "+" {
                if lt != "str" || rt2 != "str" {
                    self.fail(e, "`+` joins two strings; for other values use \"\${x}\"")
                }
                a.push(rv.T0)
                a.push(rv.A0)
                self.rt("__str_cat", 2)
                return "str"
            }
            self.check(e, rt2, lt, "`${op}`")
            if op == "==" || op == "!=" {
                a.push(rv.T0)
                a.push(rv.A0)
                self.rt("__str_eq", 2)
                if op == "!=" { a.xori(rv.A0, rv.A0, 1) }
                return "bool"
            }
            if op == "<" || op == "<=" || op == ">" || op == ">=" {
                a.push(rv.T0)
                a.push(rv.A0)
                self.rt("__str_cmp", 2)
                a.mv(rv.T0, rv.A0)
                a.li(rv.A0, 0)
                self.compare(op)
                return "bool"
            }
            self.fail(e, "`${op}` doesn't work on strings")
            return "?"
        }
        if lt == "float" || rt2 == "float" {
            if lt == "int" { self.int_to_float(rv.T0) }
            if rt2 == "int" { self.int_to_float(rv.A0) }
            let other = if lt == "float" { rt2 } else { lt }
            if other != "int" && other != "float" && other != "?" { self.fail(e, "`${op}` between float and ${other}") }
            a.fmv_dx(0, rv.T0)
            a.fmv_dx(1, rv.A0)
            if op == "+" || op == "-" || op == "*" || op == "/" {
                a.fop(if op == "+" { 0x01 } else if op == "-" { 0x05 } else if op == "*" { 0x09 } else { 0x0d }, 0, 0, 1)
                a.fmv_xd(rv.A0, 0)
                return "float"
            }
            if op == "==" || op == "!=" {
                a.fcmp(2, rv.A0, 0, 1)
                if op == "!=" { a.xori(rv.A0, rv.A0, 1) }
                return "bool"
            }
            if op == "<" { a.fcmp(1, rv.A0, 0, 1) }
            else if op == ">" { a.fcmp(1, rv.A0, 1, 0) }
            else if op == "<=" { a.fcmp(0, rv.A0, 0, 1) }
            else if op == ">=" { a.fcmp(0, rv.A0, 1, 0) }
            else {
                self.fail(e, "`${op}` doesn't work on floats")
                return "?"
            }
            return "bool"
        }
        if op == "==" || op == "!=" {
            let with_none = lt == "none" || rt2 == "none"
            if !self.same(lt, rt2) && !(with_none && (lt.ends_with("?") || rt2.ends_with("?") || lt == rt2)) { self.fail(e, "comparing ${lt} with ${rt2}") }
            if self.enums.contains(lt) && self.enums[lt].data && !with_none {
                self.fail(e, "${lt} values can't be compared with ==: use match")
            }
            if lt.ends_with("?") && !with_none && boxed_option(lt.slice(0, lt.len() - 1), self.enums) {
                self.fail(e, "compare an option with none, or unwrap it first (?? or if let)")
            }
            a.xor(rv.A0, rv.T0, rv.A0)
            if op == "==" { a.seqz(rv.A0, rv.A0) } else { a.snez(rv.A0, rv.A0) }
            return "bool"
        }
        self.check(e.kids[0], lt, "int", "`${op}`")
        self.check(e.kids[1], rt2, "int", "`${op}`")
        if op == "<" || op == "<=" || op == ">" || op == ">=" {
            self.compare(op)
            return "bool"
        }
        self.arith(e, op)
        return "int"
    }

    // t0 op a0 -> a0 (a boolean)
    fn compare(self, op: str) {
        let a = self.a
        if op == "<" { a.slt(rv.A0, rv.T0, rv.A0) }
        if op == ">" { a.slt(rv.A0, rv.A0, rv.T0) }
        if op == "<=" {
            a.slt(rv.A0, rv.A0, rv.T0)
            a.xori(rv.A0, rv.A0, 1)
        }
        if op == ">=" {
            a.slt(rv.A0, rv.T0, rv.A0)
            a.xori(rv.A0, rv.A0, 1)
        }
    }

    // t0 op a0 -> a0 (ints)
    fn arith(self, e: Tree, op: str) {
        let a = self.a
        if op == "+" { a.add(rv.A0, rv.T0, rv.A0) } else if op == "-" { a.sub(rv.A0, rv.T0, rv.A0) } else if op == "*" { a.mul(rv.A0, rv.T0, rv.A0) } else if op == "/" || op == "%" {
            let ok_l = a.label()
            a.jump_if_not_zero(rv.A0, ok_l)
            self.die(e, "division by zero")
            a.place(ok_l)
            if op == "/" { a.div(rv.A0, rv.T0, rv.A0) } else { a.rem(rv.A0, rv.T0, rv.A0) }
        } else if op == "&" { a.and(rv.A0, rv.T0, rv.A0) } else if op == "|" { a.or(rv.A0, rv.T0, rv.A0) } else if op == "^" { a.xor(rv.A0, rv.T0, rv.A0) } else if op == "<<" { a.sll(rv.A0, rv.T0, rv.A0) } else if op == ">>" { a.sra(rv.A0, rv.T0, rv.A0) } else { self.fail(e, "unknown operator ${op}") }
    }

    // the value in a0 (of type ty) -> a string in a0
    fn to_str(self, e: Tree, ty: str) {
        let a = self.a
        if ty == "str" || ty == "?" { return }
        if ty == "none" {
            a.addr_data(rv.A0, self.str_lit("none"))
            return
        }
        if ty.ends_with("?") {
            let inner = ty.slice(0, ty.len() - 1)
            let is_none = a.label()
            let end = a.label()
            a.jump_if_zero(rv.A0, is_none)
            self.unwrap_reg(inner)
            self.to_str(e, inner)
            a.jump(end)
            a.place(is_none)
            a.addr_data(rv.A0, self.str_lit("none"))
            a.place(end)
            return
        }
        a.push(rv.A0)
        if ty == "int" { self.rt("__int_str", 1) }
        else if ty == "float" { self.rt("__float_str", 1) }
        else if ty == "[float]" { self.rt("__l_float_str", 1) } else if ty == "bool" { self.rt("__bool_str", 1) } else if ty == "[int]" { self.rt("__l_int_str", 1) } else if ty == "[str]" { self.rt("__l_str_str", 1) } else if ty == "[bool]" { self.rt("__l_bool_str", 1) } else if ty == "void" {
            self.fail(e, "this has no value to show")
            a.pop(rv.A0)
        } else if ty.starts_with("{") {
            let kv = map_types(ty)
            a.li(rv.A0, show_kind(kv[0]) * 8 + show_kind(kv[1]))
            a.push(rv.A0)
            self.rt("__m_str", 2)
        } else if ty.starts_with("fn(") {
            a.pop(rv.A0)
            a.addr_data(rv.A0, self.str_lit("<fn>"))
        } else if self.enums.contains(ty) && self.enums[ty].data {
            a.pop(rv.A0)
            self.show_enum(e, ty)
        } else if self.enums.contains(ty) {
            // its variant's name
            a.pop(rv.T0)
            let done = a.label()
            for k, name in self.enums[ty].variants {
                let next = a.label()
                a.li(rv.T1, k)
                a.xor(rv.T1, rv.T1, rv.T0)
                a.jump_if_not_zero(rv.T1, next)
                a.addr_data(rv.A0, self.str_lit(name))
                a.jump(done)
                a.place(next)
            }
            a.addr_data(rv.A0, self.str_lit("?"))
            a.place(done)
        } else {
            a.pop(rv.A0)
            a.addr_data(rv.A0, self.str_lit(if ty.starts_with("[") { "[...]" } else { ty }))
        }
    }

    // arguments: each pushed, type-checked against the parameters
    fn call_args_typed(self, e: Tree, params: [Param], skip: int, first: int, what: str) {
        let n = params.len() - skip
        let given = e.kids.len() - first
        if given != n {
            self.fail(e, "${what} takes ${n} argument${if n == 1 { "" } else { "s" }}, given ${given}")
            return
        }
        for k in 0..n {
            let p = params[k + skip]
            let x = e.kids[k + first]
            let t = self.expr(x, p.ty)
            self.check(x, t, p.ty, "argument `${p.name}` of ${what}")
            self.a.push(rv.A0)
        }
    }

    fn call(self, e: Tree, want: str) -> str {
        let a = self.a
        let name = e.s
        if name == "print" || name == "println" {
            if e.kids.len() > 1 {
                self.fail(e, "${name} takes one value (put several in a string: \"\${a} \${b}\")")
                return "void"
            }
            if e.kids.len() == 1 {
                let t = self.expr(e.kids[0], "")
                self.to_str(e.kids[0], t)
            } else {
                a.addr_data(rv.A0, self.str_lit(""))
            }
            a.push(rv.A0)
            self.rt(if name == "print" { "__print" } else { "__println" }, 1)
            return "void"
        }
        if name.starts_with("__") && self.crt {
            if let t = self.intrinsic(e) { return t }
        }
        if name == "some" && self.lookup(name) == none {
            if e.kids.len() != 1 {
                self.fail(e, "some() takes one value")
                return "?"
            }
            let inner = if want.ends_with("?") { want.slice(0, want.len() - 1) } else { "" }
            let t = self.expr(e.kids[0], inner)
            if t == "void" || t == "none" { self.fail(e, "some() of nothing") }
            self.wrap(t)
            return t + "?"
        }
        if (name == "int" || name == "float") && self.lookup(name) == none {
            if e.kids.len() != 1 {
                self.fail(e, "${name}() takes one number")
                return name
            }
            let t = self.expr(e.kids[0], "")
            if t == "str" {
                self.fail(e, if name == "int" { "for text, use parse_int(s)" } else { "for text, use parse_float(s)" })
            } else if t != "int" && t != "float" && t != "?" {
                self.fail(e, "${name}() of ${t}")
            }
            if name == "float" && t == "int" { self.int_to_float(rv.A0) }
            if name == "int" && t == "float" {
                a.fmv_dx(0, rv.A0)
                a.fcvt_ld(rv.A0, 0, 1)
            }
            return name
        }
        if let l = self.lookup(name) {
            if l.ty.starts_with("fn(") {
                return self.call_value(e, l.ty, 0, () => self.read_var(l, rv.A0))
            }
            self.fail(e, "`${name}` is a variable, not a function")
        }
        if self.globals.contains(name) && self.globals[name].ty.starts_with("fn(") {
            let g = self.globals[name]
            return self.call_value(e, g.ty, 0, () => {
                a.addr_var(rv.T0, g.off)
                a.ld(rv.A0, rv.T0, 0)
            })
        }
        if !self.funcs.contains(name) {
            if self.structs.contains(name) {
                self.fail(e, "to make a ${name}, write ${name} { field: value, ... }")
            } else {
                self.fail(e, "no function called `${name}`")
            }
            return "?"
        }
        let f = self.funcs[name]
        if f.owner != "" { self.fail(e, "`${name}` is a method") }
        if name.starts_with("__") && !self.crt { self.fail(e, "`${name}` is internal to the runtime") }
        self.call_args_typed(e, f.params, 0, 0, name)
        self.rt(name, f.params.len())
        return f.ret
    }

    // the runtime's raw memory access and system calls
    fn intrinsic(self, e: Tree) -> str? {
        let a = self.a
        let name = e.s
        let n = e.kids.len()
        if name == "__syscall" {
            for x in e.kids {
                self.expr(x, "")
                a.push(rv.A0)
            }
            // the number first, then up to six arguments
            a.ld(rv.A7, rv.SP, 8 * (n - 1))
            for k in 1..n { a.ld(rv.A0 + k - 1, rv.SP, 8 * (n - 1 - k)) }
            a.ecall()
            a.addi(rv.SP, rv.SP, 8 * n)
            return some("int")
        }
        if name == "__ld" || name == "__ld8" {
            self.expr(e.kids[0], "")
            if name == "__ld" { a.ld(rv.A0, rv.A0, 0) } else { a.lbu(rv.A0, rv.A0, 0) }
            return some("int")
        }
        if name == "__st" || name == "__st8" {
            self.expr(e.kids[0], "")
            a.push(rv.A0)
            self.expr(e.kids[1], "")
            a.pop(rv.T0)
            if name == "__st" { a.sd(rv.A0, rv.T0, 0) } else { a.sb(rv.A0, rv.T0, 0) }
            return some("void")
        }
        if name == "__sp" {
            a.mv(rv.A0, rv.SP)
            return some("int")
        }
        if name == "__data_size" {
            a.li(rv.A0, self.data_size)
            return some("int")
        }
        if name == "__heap" {
            a.addr_var(rv.A0, 0)
            return some("int")
        }
        if name == "__int" {
            self.expr(e.kids[0], "")
            return some("int")
        }
        if name == "__str" {
            self.expr(e.kids[0], "")
            return some("str")
        }
        if name == "__float" {
            self.expr(e.kids[0], "")
            return some("float")
        }
        if name == "__call1" {
            // __call1(f, x): call a closure with one argument
            self.expr(e.kids[0], "")
            a.push(rv.A0)
            self.expr(e.kids[1], "")
            a.push(rv.A0)
            a.ld(rv.T0, rv.SP, 8)
            a.ld(rv.T0, rv.T0, 0)
            a.jalr(rv.T0)
            a.addi(rv.SP, rv.SP, 16)
            return some("int")
        }
        if name == "__copy" {
            // __copy(dst, src, n): bytes, front to back
            for x in e.kids {
                self.expr(x, "")
                a.push(rv.A0)
            }
            a.pop(rv.A2)
            a.pop(rv.A1)
            a.pop(rv.A0)
            let top = a.label()
            let end = a.label()
            a.place(top)
            a.jump_if_zero(rv.A2, end)
            a.lbu(rv.T0, rv.A1, 0)
            a.sb(rv.T0, rv.A0, 0)
            a.addi(rv.A0, rv.A0, 1)
            a.addi(rv.A1, rv.A1, 1)
            a.addi(rv.A2, rv.A2, -1)
            a.jump(top)
            a.place(end)
            return some("void")
        }
        return none
    }

    fn method(self, e: Tree, want: str) -> str {
        let a = self.a
        let name = e.s
        let obj = e.kids[0]
        if obj.k == "name" && (self.structs.contains(obj.s) || self.enums.contains(obj.s)) && self.lookup(obj.s) == none {
            // Type.function(...) or Enum.Variant(...)
            let key = "${obj.s}.${name}"
            if self.funcs.contains(key) && self.funcs[key].is_static {
                let f = self.funcs[key]
                self.call_args_typed(e, f.params, 0, 1, key)
                a.call("m_${obj.s}_${name}")
                if f.params.len() > 0 { a.addi(rv.SP, rv.SP, 8 * f.params.len()) }
                return f.ret
            }
            if self.enums.contains(obj.s) {
                return self.make_variant(e, obj.s, name, e.kids.slice(1, e.kids.len()), 1)
            }
            self.fail(e, "${obj.s} has no function `${name}` (methods are called on a value)")
            return "?"
        }
        let ot = self.expr(obj, "")
        if ot == "?" { return "?" }
        let argc = e.kids.len() - 1
        if ot == "str" {
            if name == "len" && argc == 0 {
                a.ld(rv.A0, rv.A0, 0)
                return "int"
            }
            if name == "is_empty" && argc == 0 {
                a.ld(rv.A0, rv.A0, 0)
                a.seqz(rv.A0, rv.A0)
                return "bool"
            }
            let sig = STR_METHODS.find(m => m[0] == name)
            if let m = sig {
                a.push(rv.A0)
                let params = m.slice(2, m.len())
                if argc != params.len() {
                    self.fail(e, "str.${name} takes ${params.len()} argument${if params.len() == 1 { "" } else { "s" }}, given ${argc}")
                    return "?"
                }
                for k, pt in params {
                    let t = self.expr(e.kids[k + 1], pt)
                    self.check(e.kids[k + 1], t, pt, "str.${name}")
                    a.push(rv.A0)
                }
                self.rt("__s_" + name, argc + 1)
                return m[1]
            }
            self.fail(e, "str has no method `${name}`")
            return "?"
        }
        if ot.ends_with("?") {
            let inner = ot.slice(0, ot.len() - 1)
            if (name == "is_some" || name == "is_none") && argc == 0 {
                if name == "is_some" { a.snez(rv.A0, rv.A0) } else { a.seqz(rv.A0, rv.A0) }
                return "bool"
            }
            if name == "unwrap" && argc == 0 {
                let ok_l = a.label()
                a.jump_if_not_zero(rv.A0, ok_l)
                self.die(e, "unwrap() of none")
                a.place(ok_l)
                self.unwrap_reg(inner)
                return inner
            }
            self.fail(e, "${ot} is an option: use ?? default, if let v = ..., or unwrap() before .${name}")
            return "?"
        }
        if ot.starts_with("{") {
            let kv = map_types(ot)
            if (name == "len" || name == "is_empty") && argc == 0 {
                a.ld(rv.A0, rv.A0, 0)
                if name == "is_empty" {
                    a.seqz(rv.A0, rv.A0)
                    return "bool"
                }
                return "int"
            }
            a.push(rv.A0)
            if (name == "contains" || name == "remove") && argc == 1 {
                let t = self.expr(e.kids[1], kv[0])
                self.check(e.kids[1], t, kv[0], name)
                a.push(rv.A0)
                self.rt("__m_" + name, 2)
                return if name == "contains" { "bool" } else { "void" }
            }
            if name == "get" && argc == 1 {
                // V?: none when the key isn't there
                let t = self.expr(e.kids[1], kv[0])
                self.check(e.kids[1], t, kv[0], "get")
                a.push(rv.A0)
                self.rt("__m_find", 2)
                self.option_from_index(e, kv[1], () => {
                    self.expr(e.kids[0], "")
                    a.ld(rv.T0, rv.A0, 32)
                })
                return kv[1] + "?"
            }
            if name == "get" && argc == 2 {
                let t = self.expr(e.kids[1], kv[0])
                self.check(e.kids[1], t, kv[0], "get")
                a.push(rv.A0)
                let d = self.expr(e.kids[2], kv[1])
                self.check(e.kids[2], d, kv[1], "get's default")
                a.push(rv.A0)
                self.rt("__m_get_or", 3)
                return kv[1]
            }
            if (name == "keys" || name == "values" || name == "clear") && argc == 0 {
                self.rt("__m_" + name, 1)
                if name == "keys" { return "[${kv[0]}]" }
                if name == "values" { return "[${kv[1]}]" }
                return "void"
            }
            a.addi(rv.SP, rv.SP, 8)
            self.fail(e, "${ot} has no method `${name}` with ${argc} argument${if argc == 1 { "" } else { "s" }} (len is_empty contains get(k, default) remove keys values clear)")
            return "?"
        }
        if ot == "float" {
            if argc != 0 || !["sqrt", "floor", "ceil", "round", "abs"].contains(name) {
                self.fail(e, "float has no method `${name}` (with ${argc} arguments): sqrt floor ceil round abs")
                return "?"
            }
            a.fmv_dx(0, rv.A0)
            if name == "sqrt" {
                a.fsqrt(0, 0)
            } else if name == "abs" {
                a.fsgnj(2, 0, 0, 0)
            } else {
                // through an int, for numbers that have a fraction (|x| < 2^52); bigger ones are whole already
                let big = a.label()
                let done = a.label()
                a.li(rv.T1, 0x4330000000000000)      // 2^52
                a.fmv_dx(1, rv.T1)
                a.fsgnj(2, 2, 0, 0)                  // f2 = |x|
                a.fcmp(1, rv.T2, 2, 1)               // |x| < 2^52 ?
                a.jump_if_zero(rv.T2, big)
                a.fcvt_ld(rv.T0, 0, if name == "floor" { 2 } else if name == "ceil" { 3 } else { 4 })
                a.fcvt_dl(1, rv.T0)
                a.fsgnj(0, 0, 1, 0)                  // keep the sign (-0.5.ceil() is -0.0)
                a.place(big)
                a.place(done)
            }
            a.fmv_xd(rv.A0, 0)
            return "float"
        }
        if ot.starts_with("[") {
            let et = elem(ot)
            if (name == "len" || name == "is_empty") && argc == 0 {
                a.ld(rv.A0, rv.A0, 0)
                if name == "is_empty" {
                    a.seqz(rv.A0, rv.A0)
                    return "bool"
                }
                return "int"
            }
            a.push(rv.A0)
            let line_arg = () => {
                a.li(rv.A0, e.line)
                a.push(rv.A0)
            }
            if name == "push" && argc == 1 {
                let t = self.expr(e.kids[1], et)
                self.check(e.kids[1], t, et, "push")
                a.push(rv.A0)
                self.rt("__l_push", 2)
                return "void"
            }
            if name == "pop" && argc == 0 {
                line_arg()
                self.rt("__l_pop", 2)
                return et
            }
            if (name == "first" || name == "last" || name == "get") && argc == (if name == "get" { 1 } else { 0 }) {
                // T?: none when there's no such element
                if name == "get" {
                    self.int_arg(e, 1, "get")
                } else {
                    a.li(rv.A0, if name == "first" { 0 } else { -1 })
                    a.push(rv.A0)
                }
                self.rt("__l_at", 2)
                self.option_from_index(e, et, () => {
                    self.expr(e.kids[0], "")
                    a.ld(rv.T0, rv.A0, 16)
                })
                return et + "?"
            }
            if name == "find" && argc == 1 {
                let ft = self.expr(e.kids[1], "fn(${et})->bool")
                if !ft.starts_with("fn(") { self.fail(e.kids[1], "find takes a function, like x => x > 2") }
                a.push(rv.A0)
                self.rt("__l_find", 2)
                self.option_from_index(e, et, () => {
                    self.expr(e.kids[0], "")
                    a.ld(rv.T0, rv.A0, 16)
                })
                return et + "?"
            }
            if name == "insert" && argc == 2 {
                self.int_arg(e, 1, "insert")
                let t = self.expr(e.kids[2], et)
                self.check(e.kids[2], t, et, "insert")
                a.push(rv.A0)
                line_arg()
                self.rt("__l_insert", 4)
                return "void"
            }
            if name == "remove" && argc == 1 {
                self.int_arg(e, 1, "remove")
                line_arg()
                self.rt("__l_remove", 3)
                return et
            }
            if name == "slice" && argc == 2 {
                self.int_arg(e, 1, "slice")
                self.int_arg(e, 2, "slice")
                self.rt("__l_slice", 3)
                return ot
            }
            if (name == "contains" || name == "index_of") && argc == 1 {
                let t = self.expr(e.kids[1], et)
                self.check(e.kids[1], t, et, name)
                a.push(rv.A0)
                let kind = if et == "str" { "str" } else { "int" }
                self.rt("__l_${name}_${kind}", 2)
                return if name == "contains" { "bool" } else { "int" }
            }
            if (name == "map" || name == "filter" || name == "any" || name == "all" || name == "count") && argc == 1 && e.kids[1].k != "str" {
                let want_f = if name == "map" { "fn(${et})->?" } else { "fn(${et})->bool" }
                let ft = self.expr(e.kids[1], want_f)
                if !ft.starts_with("fn(") || fn_params(ft).len() != 1 {
                    self.fail(e.kids[1], "${name} takes a function of one ${et}, like x => ...")
                    return "?"
                }
                self.check(e.kids[1], fn_params(ft)[0], et, name)
                let r = fn_ret(ft)
                if name != "map" { self.check(e.kids[1], r, "bool", name) }
                if name == "map" && r == "void" { self.fail(e.kids[1], "map's function gives no value") }
                a.push(rv.A0)
                self.rt("__l_" + name, 2)
                if name == "map" { return "[${r}]" }
                if name == "filter" { return ot }
                if name == "count" { return "int" }
                return "bool"
            }
            if (name == "reverse" || name == "clear") && argc == 0 {
                self.rt("__l_" + name, 1)
                return "void"
            }
            if name == "copy" && argc == 0 {
                a.li(rv.A0, 0)
                a.push(rv.A0)
                a.li(rv.A0, 1 << 62)
                a.push(rv.A0)
                self.rt("__l_slice", 3)
                return ot
            }
            if name == "sort" && argc == 0 {
                if et != "int" && et != "str" { self.fail(e, "sort works on [int] and [str]") }
                self.rt(if et == "str" { "__l_sort_str" } else { "__l_sort_int" }, 1)
                return "void"
            }
            if name == "sum" && argc == 0 {
                self.check(e, et, "int", "sum")
                self.rt("__l_sum", 1)
                return "int"
            }
            if name == "join" && argc == 1 {
                if et != "str" { self.fail(e, "join works on [str]") }
                let t = self.expr(e.kids[1], "str")
                self.check(e.kids[1], t, "str", "join")
                a.push(rv.A0)
                self.rt("__l_join", 2)
                return "str"
            }
            a.addi(rv.SP, rv.SP, 8)
            self.fail(e, "${ot} has no method `${name}` (with ${argc} argument${if argc == 1 { "" } else { "s" }})")
            return "?"
        }
        let key = "${ot}.${name}"
        if !self.funcs.contains(key) && self.field_type(ot, name).starts_with("fn(") {
            // a field holding a function: call it
            let off = self.field_offset(e, ot, name)
            a.ld(rv.A0, rv.A0, off)
            return self.call_value(e, self.field_type(ot, name), 1, () => {})
        }
        if !self.funcs.contains(key) {
            self.fail(e, "${ot} has no method `${name}`")
            return "?"
        }
        let f = self.funcs[key]
        a.push(rv.A0)
        self.call_args_typed(e, f.params, 1, 1, "${ot}.${name}")
        self.a.call("m_${ot}_${name}")
        a.addi(rv.SP, rv.SP, 8 * f.params.len())
        return f.ret
    }

    // Call a function value (a closure): `load` puts it in a0. Its arguments are e.kids[first..].
    // The closure goes on the stack first, then the arguments: a plain function ignores it.
    fn call_value(self, e: Tree, ty: str, first: int, load: fn()) -> str {
        let a = self.a
        load()
        a.push(rv.A0)
        let ps = fn_params(ty)
        let n = ps.len()
        if e.kids.len() - first != n {
            self.fail(e, "this function takes ${n} argument${if n == 1 { "" } else { "s" }}, given ${e.kids.len() - first}")
            return "?"
        }
        for k in 0..n {
            let x = e.kids[k + first]
            let t = self.expr(x, ps[k])
            self.check(x, t, ps[k], "argument ${k + 1}")
            a.push(rv.A0)
        }
        a.ld(rv.T0, rv.SP, 8 * n)
        a.ld(rv.T0, rv.T0, 0)
        a.jalr(rv.T0)
        a.addi(rv.SP, rv.SP, 8 * (n + 1))
        return fn_ret(ty)
    }

    // A lambda: its code right here (jumped over), and a closure object holding what it uses from
    // around it: the value of a `let` or a parameter, the box of a `var` (so both sides share it).
    fn lambda(self, e: Tree, want: str) -> str {
        let a = self.a
        var wp: [str] = []
        if want.starts_with("fn(") { wp = fn_params(want) }
        let wr = if want.starts_with("fn(") { fn_ret(want) } else { "?" }
        let body = e.kids[e.kids.len() - 1]
        var ptypes: [str] = []
        for k in 0..e.kids.len() - 1 {
            let prm = e.kids[k]
            if prm.s2 != "" {
                self.known_type(prm, prm.s2)
                ptypes.push(prm.s2)
            } else if k < wp.len() {
                ptypes.push(wp[k])
            } else {
                self.fail(prm, "give `${prm.s}` a type: (${prm.s}: int) => ...")
                ptypes.push("?")
            }
        }
        // what it captures: the locals around it that it names
        var caps: [str] = []
        for nm in names_in(body) {
            if !caps.contains(nm) && self.lookup(nm) != none && e.kids.slice(0, e.kids.len() - 1).find(p => p.s == nm) == none {
                caps.push(nm)
            }
        }
        a.li(rv.A0, 8 * (1 + caps.len()))
        a.push(rv.A0)
        self.rt("__alloc", 1)
        a.push(rv.A0)
        self.lambdas += 1
        let label = "l_${self.lambdas}"
        a.addr_fn(rv.T0, label)
        a.sd(rv.T0, rv.A0, 0)
        for k, nm in caps {
            let l = self.lookup(nm).unwrap()
            self.load_slot(rv.T0, l.slot)          // the value, or the box
            a.ld(rv.T1, rv.SP, 0)
            a.sd(rv.T0, rv.T1, 8 * (k + 1))
        }
        // the code
        let over = a.label()
        a.jump(over)
        self.offsets[label] = a.here()
        let saved_scopes = self.scopes
        let saved_slots = self.slots
        let saved_ret = self.ret
        let saved_loops = self.loops
        let saved_exit = self.exit_label
        let saved_captured = self.captured
        let outer: [Local] = caps.map(nm => self.lookup(nm).unwrap())
        self.begin_function(wr, self.crt)
        self.captured = names_in_lambdas(body)
        a.addi(rv.SP, rv.SP, -16)
        a.sd(rv.RA, rv.SP, 8)
        a.sd(rv.FP, rv.SP, 0)
        a.mv(rv.FP, rv.SP)
        let patch = a.here()
        a.emit(0)
        a.emit(0)
        a.sub(rv.SP, rv.SP, rv.T0)
        let n = ptypes.len()
        for k in 0..n {
            let slot = self.declare(e.kids[k], e.kids[k].s, ptypes[k], false)
            a.ld(rv.T0, rv.FP, 16 + 8 * (n - 1 - k))
            self.store_slot(rv.T0, slot)
        }
        a.ld(rv.T1, rv.FP, 16 + 8 * n)               // the closure
        for k, nm in caps {
            let o = outer[k]
            let slot = self.declare(e, nm, o.ty, o.mutable)
            let top = self.scopes[self.scopes.len() - 1]
            top[nm] = Local { slot, ty: o.ty, mutable: o.mutable && o.boxed, boxed: o.boxed }
            a.ld(rv.T0, rv.T1, 8 * (k + 1))
            self.store_slot(rv.T0, slot)
        }
        var ret = self.ret
        if body.k == "block" {
            self.block(body)
            ret = if self.ret == "?" { "void" } else { self.ret }
            if ret != "void" && !returns(body) { self.die(e, "a function ended without returning a value") }
        } else {
            ret = self.expr(body, if wr == "?" { "" } else { wr })
            if wr != "?" && wr != "void" { self.check(body, ret, wr, "the function's value") }
            if wr == "void" { ret = "void" }
        }
        self.end_function(patch)
        self.scopes = saved_scopes
        self.slots = saved_slots
        self.ret = saved_ret
        self.loops = saved_loops
        self.exit_label = saved_exit
        self.captured = saved_captured
        a.place(over)
        a.pop(rv.A0)
        return "fn(" + ptypes.join(",") + ")->" + ret
    }

    fn int_arg(self, e: Tree, k: int, what: str) {
        let t = self.expr(e.kids[k], "int")
        self.check(e.kids[k], t, "int", what)
        self.a.push(rv.A0)
    }
}

// name, result, parameter types
const STR_METHODS = [
    ["slice", "str", "int", "int"],
    ["contains", "bool", "str"],
    ["find", "int", "str"],
    ["starts_with", "bool", "str"],
    ["ends_with", "bool", "str"],
    ["upper", "str"],
    ["lower", "str"],
    ["trim", "str"],
    ["split", "[str]", "str"],
    ["lines", "[str]"],
    ["chars", "[str]"],
    ["replace", "str", "str", "str"],
    ["repeat", "str", "int"],
    ["byte", "int", "int"],
    ["count", "int", "str"],
    ["reverse", "str"],
]

// a double's IEEE 754 bits (the host has no bit casts: frexp by hand; halving and doubling are exact)
fn float_bits(x: float) -> int {
    if x != x { return 0x7ff8000000000000 }
    var sign = 0
    var v = x
    if v < 0.0 || (v == 0.0 && 1.0 / v < 0.0) {
        sign = 1 << 63
        v = -v
    }
    if v == 0.0 { return sign }
    if v > 1.7976931348623157e308 { return sign | 0x7ff0000000000000 }
    var e = 0
    while v >= 2.0 {
        v = v / 2.0
        e += 1
    }
    while v < 1.0 && e > -1022 {
        v = v * 2.0
        e -= 1
    }
    if v < 1.0 {
        // subnormal: no hidden bit
        return sign | int(v * 4503599627370496.0)
    }
    return sign | (e + 1023) << 52 | int((v - 1.0) * 4503599627370496.0)
}

// the variant a pattern is about
fn pattern_variant(p: Tree) -> str {
    return p.s
}

// is an option of this type a box (ints, floats, bools, enums), or the pointer itself (none = 0)?
fn boxed_option(ty: str, enums: {str: EnumDecl}) -> bool {
    return ty == "int" || ty == "float" || ty == "bool" || enums.contains(ty) || ty.ends_with("?")
}

// "{str:[int]}" -> ["str", "[int]"]
fn map_types(ty: str) -> [str] {
    var depth = 0
    var i = 1
    while i < ty.len() - 1 {
        let c = ty[i]
        if c == "(" || c == "[" || c == "{" { depth += 1 }
        if c == ")" || c == "]" || c == "}" { depth -= 1 }
        if c == ":" && depth == 0 { return [ty.slice(1, i), ty.slice(i + 1, ty.len() - 1)] }
        i += 1
    }
    return ["?", "?"]
}

// how the runtime shows a value of this type in a map: 0 int, 1 str, 2 bool, 3 float, else ...
fn show_kind(ty: str) -> int {
    if ty == "int" { return 0 }
    if ty == "str" { return 1 }
    if ty == "bool" { return 2 }
    if ty == "float" { return 3 }
    return 4
}

// the parts of "fn(int,[str])->bool"
fn fn_params(ty: str) -> [str] {
    var out: [str] = []
    if !ty.starts_with("fn(") { return out }
    var depth = 0
    var start = 3
    var i = 3
    while i < ty.len() {
        let c = ty[i]
        if c == "(" || c == "[" { depth += 1 }
        if c == ")" || c == "]" {
            if depth == 0 {
                if i > start { out.push(ty.slice(start, i)) }
                return out
            }
            depth -= 1
        }
        if c == "," && depth == 0 {
            out.push(ty.slice(start, i))
            start = i + 1
        }
        i += 1
    }
    return out
}

fn fn_ret(ty: str) -> str {
    var depth = 0
    var i = 3
    while i < ty.len() {
        let c = ty[i]
        if c == "(" || c == "[" { depth += 1 }
        if c == ")" || c == "]" {
            if depth == 0 { return ty.slice(i + 3, ty.len()) }
            depth -= 1
        }
        i += 1
    }
    return "?"
}

// every name a tree mentions
fn names_in(t: Tree) -> [str] {
    var out: [str] = []
    collect_names(t, out, false)
    return out
}

// the names mentioned inside the lambdas in a tree
fn names_in_lambdas(t: Tree) -> [str] {
    var out: [str] = []
    collect_names(t, out, true)
    return out
}

fn collect_names(t: Tree, out: [str], only_lambdas: bool) {
    if t.k == "lambda" && only_lambdas {
        collect_names(t, out, false)
        return
    }
    if !only_lambdas && (t.k == "name" || t.k == "call") && !out.contains(t.s) { out.push(t.s) }
    for k in t.kids { collect_names(k, out, only_lambdas) }
}

fn elem(ty: str) -> str {
    if ty.starts_with("[") && ty.ends_with("]") { return ty.slice(1, ty.len() - 1) }
    return "?"
}

// does a block always end in a return (so no "ended without returning" is needed)?
fn returns(b: Tree) -> bool {
    if b.kids.is_empty() { return false }
    let last = b.kids[b.kids.len() - 1]
    if last.k == "return" { return true }
    if last.k == "if" && last.kids.len() == 3 { return returns(last.kids[1]) && returns(last.kids[2]) }
    if last.k == "while" && last.kids[0].k == "bool" && last.kids[0].n == 1 { return true }
    return false
}

// ---- the whole thing ----

struct Error {
    msg: str,
    line: int,
    col: int,
}

struct Output {
    image: rv.Image = rv.Image {},
    errors: [Error] = [],
    ms: int = 0,
    code_bytes: int = 0,
    functions: int = 0,
}

fn parse_into(src: str, p: Program, crt_src: bool) -> Error? {
    let lx = Lexer { src }
    lx.run()
    if lx.err != "" { return some(Error { msg: lx.err, line: lx.err_line, col: lx.err_col }) }
    let ps = Parser { toks: lx.toks, crt: crt_src }
    ps.program(p)
    if ps.err != "" { return some(Error { msg: ps.err, line: ps.err_line, col: ps.err_col }) }
    return none
}

// Compile a program. On success out.errors is empty and out.image is ready for proc.spawn.
fn compile(src: str, now: fn() -> int) -> Output {
    let t0 = now()
    let out = Output {}
    let p = Program {}
    if let e = parse_into(userland.runtime(), p, true) {
        out.errors.push(Error { msg: "(in the runtime) ${e.msg}", line: e.line, col: e.col })
        return out
    }
    if let e = parse_into(src, p, false) {
        out.errors.push(e)
        return out
    }
    let g = Gen {}
    g.program(p)
    if g.err != "" {
        out.errors.push(Error { msg: g.err, line: g.err_line, col: g.err_col })
        return out
    }
    let e = rv.link(g.a, g.offsets, g.rodata, g.data_size, out.image)
    if e != "" {
        out.errors.push(Error { msg: e, line: 1, col: 1 })
        return out
    }
    out.code_bytes = g.a.code.len() * 4
    out.functions = g.funcs.len()
    out.ms = now() - t0
    return out
}

// ---- executables: a compiled program saved as a file ----
//
// The file system keeps text, so the machine code is written out in hex after a header line:
//     #!stella-exe 1 <data_at> <data_size>

const EXE_MAGIC = "#!stella-exe 1"
const HEX = "0123456789abcdef"

fn exe_text(img: rv.Image) -> str {
    var parts: [str] = ["${EXE_MAGIC} ${img.data_at} ${img.data_size}"]
    var row: [str] = []
    for b in img.bytes {
        row.push(HEX[b >> 4] + HEX[b & 15])
        if row.len() == 64 {
            parts.push(row.join(""))
            row = []
        }
    }
    if !row.is_empty() { parts.push(row.join("")) }
    return parts.join("\n") + "\n"
}

fn is_exe(text: str) -> bool { return text.starts_with(EXE_MAGIC) }

fn exe_parse(text: str) -> rv.Image? {
    let ls = text.split("\n")
    let head = ls[0].split(" ")
    if !is_exe(text) || head.len() != 4 { return none }
    let img = rv.Image {}
    img.data_at = int(head[2]) catch -1
    img.data_size = int(head[3]) catch -1
    var bytes: [int] = []
    for k in 1..ls.len() {
        let l = ls[k]
        var i = 0
        while i + 1 < l.len() {
            let hi = digit_value(st_k_byte(l, i))
            let lo = digit_value(st_k_byte(l, i + 1))
            if hi < 0 || lo < 0 { return none }
            bytes.push(hi * 16 + lo)
            i += 2
        }
    }
    img.bytes = bytes
    if img.data_at < bytes.len() || img.data_at % 4096 != 0 || img.data_size < 0 { return none }
    return some(img)
}
