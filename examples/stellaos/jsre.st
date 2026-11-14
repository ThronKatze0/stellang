// Regular expressions for StellaOS's JavaScript: compiled to a small backtracking machine.
//
// Supports: literals and escapes (\d \w \s \D \W \S \b \B \n \t \uXXXX ...), ., [classes] and
// [^negated], anchors ^ $, groups (capturing, (?:...), named (?<n>...)), alternation |, quantifiers
// * + ? {n} {n,} {n,m} and their lazy forms, backreferences \1, lookahead (?=...) (?!...), flags
// i m s g.
//
// The machine keeps its own backtracking stack (no recursion per character, so long text can't
// overflow the kernel stack), and gives up after a million steps, so a pathological pattern
// ((a+)+b on "aaaa...") can't freeze the system.

const MAX_STEPS = 1_000_000

struct Ins {
    op: str,                  // char, any, class, split, jmp, save, match, bol, eol, wordb, nwordb, backref, look
    c: int = 0,               // char: the code point; save/backref: the slot or group
    x: int = 0,               // jumps
    y: int = 0,
    ranges: [int] = [],       // class: lo, hi pairs
    neg: bool = false,        // class negated / negative lookahead
    sub: [Ins] = [],          // lookahead's program
}

struct Re {
    prog: [Ins] = [],
    groups: int = 1,
    names: {str: int} = {},
    icase: bool = false,
    multiline: bool = false,
    dotall: bool = false,
    error: str = "",
}

struct Compiler {
    cs: [int],
    i: int = 0,
    groups: int = 1,
    names: {str: int} = {},
    error: str = "",
    icase: bool = false,

    fn peek(self) -> int { return if self.i < self.cs.len() { self.cs[self.i] } else { -1 } }
    fn at_end(self) -> bool { return self.i >= self.cs.len() }

    // alternatives: a|b|c. Each but the last: split (this one / the next); the branch; jmp to the end
    fn alt(self) -> [Ins] {
        var branches: [[Ins]] = [self.seq()]
        while self.peek() == 124 && self.error == "" {
            self.i += 1
            branches.push(self.seq())
        }
        if branches.len() == 1 { return branches[0] }
        var total = 0
        for bi, b in branches { total += b.len() + (if bi + 1 < branches.len() { 2 } else { 0 }) }
        var out: [Ins] = []
        for bi, b in branches {
            if bi + 1 < branches.len() {
                out.push(Ins { op: "split", x: 1, y: b.len() + 2 })
                for ins in b { out.push(ins) }
                out.push(Ins { op: "jmp", x: total - out.len() })
            } else {
                for ins in b { out.push(ins) }
            }
        }
        return out
    }

    fn seq(self) -> [Ins] {
        var out: [Ins] = []
        while !self.at_end() && self.peek() != 124 && self.peek() != 41 && self.error == "" {
            let atom = self.atom()
            if self.error != "" { return out }
            let q = self.quant(atom)
            for ins in q { out.push(ins) }
            if out.len() > 20000 {
                self.error = "pattern too large"
                return out
            }
        }
        return out
    }

    fn quant(self, atom: [Ins]) -> [Ins] {
        let c = self.peek()
        var lo = 1
        var hi = 1
        if c == 42 {
            lo = 0
            hi = -1
        } else if c == 43 {
            lo = 1
            hi = -1
        } else if c == 63 {
            lo = 0
            hi = 1
        } else if c == 123 {
            // {n}, {n,}, {n,m}; a { that isn't one is a literal
            var j = self.i + 1
            var a = 0
            var digits = 0
            while j < self.cs.len() && self.cs[j] >= 48 && self.cs[j] <= 57 {
                a = a * 10 + self.cs[j] - 48
                j += 1
                digits += 1
            }
            if digits == 0 { return atom }
            var b = a
            if j < self.cs.len() && self.cs[j] == 44 {
                j += 1
                b = -1
                var bd = 0
                var bv = 0
                while j < self.cs.len() && self.cs[j] >= 48 && self.cs[j] <= 57 {
                    bv = bv * 10 + self.cs[j] - 48
                    j += 1
                    bd += 1
                }
                if bd > 0 { b = bv }
            }
            if j >= self.cs.len() || self.cs[j] != 125 { return atom }
            self.i = j
            lo = a
            hi = b
            if lo > 1000 || hi > 1000 {
                self.error = "repetition count too large"
                return atom
            }
        } else {
            return atom
        }
        self.i += 1
        var lazy = false
        if self.peek() == 63 {
            lazy = true
            self.i += 1
        }
        var out: [Ins] = []
        for n in 0..lo { for ins in atom { out.push(ins) } }
        if hi == -1 {
            // L: split body, end; body; jmp L
            let body_len = atom.len()
            out.push(if lazy { Ins { op: "split", x: body_len + 2, y: 1 } } else { Ins { op: "split", x: 1, y: body_len + 2 } })
            for ins in atom { out.push(ins) }
            out.push(Ins { op: "jmp", x: 0 - (body_len + 1) })
        } else {
            for n in lo..hi {
                let remaining = (hi - n) * (atom.len() + 1)
                let skip = atom.len() + 1
                out.push(if lazy { Ins { op: "split", x: skip, y: 1 } } else { Ins { op: "split", x: 1, y: skip } })
                for ins in atom { out.push(ins) }
            }
        }
        return out
    }

    fn atom(self) -> [Ins] {
        let c = self.peek()
        self.i += 1
        if c == 46 { return [Ins { op: "any" }] }
        if c == 94 { return [Ins { op: "bol" }] }
        if c == 36 { return [Ins { op: "eol" }] }
        if c == 40 {
            // a group
            var capture = true
            var look = ""
            var name = ""
            if self.peek() == 63 {
                self.i += 1
                let k = self.peek()
                self.i += 1
                if k == 58 {
                    capture = false
                } else if k == 61 || k == 33 {
                    look = if k == 61 { "pos" } else { "neg" }
                    capture = false
                } else if k == 60 && self.peek() != 61 && self.peek() != 33 {
                    var nm: [int] = []
                    while !self.at_end() && self.peek() != 62 {
                        nm.push(self.peek())
                        self.i += 1
                    }
                    self.i += 1
                    name = nm.map(x => st_chr(x)).join("")
                } else {
                    self.error = "lookbehind isn't supported"
                    return []
                }
            }
            let slot = self.groups
            if capture {
                self.groups += 1
                if name != "" { self.names[name] = slot }
            }
            let inner = self.alt()
            if self.peek() != 41 {
                self.error = "missing )"
                return []
            }
            self.i += 1
            if look != "" { return [Ins { op: "look", neg: look == "neg", sub: inner }] }
            if !capture { return inner }
            var out = [Ins { op: "save", c: 2 * slot }]
            for ins in inner { out.push(ins) }
            out.push(Ins { op: "save", c: 2 * slot + 1 })
            return out
        }
        if c == 91 { return [self.class()] }
        if c == 92 { return self.escape(false) }
        if c == 41 || c == 42 || c == 43 || c == 63 {
            self.error = "nothing to repeat"
            return []
        }
        return [self.char(c)]
    }

    fn char(self, c: int) -> Ins {
        if self.icase && ((c >= 65 && c <= 90) || (c >= 97 && c <= 122)) {
            let lo = c | 32
            return Ins { op: "class", ranges: [lo, lo, lo - 32, lo - 32] }
        }
        return Ins { op: "char", c }
    }

    // after a backslash
    fn escape(self, in_class: bool) -> [Ins] {
        let c = self.peek()
        self.i += 1
        if c == 100 { return [Ins { op: "class", ranges: [48, 57] }] }
        if c == 68 { return [Ins { op: "class", ranges: [48, 57], neg: true }] }
        if c == 119 { return [Ins { op: "class", ranges: WORD }] }
        if c == 87 { return [Ins { op: "class", ranges: WORD, neg: true }] }
        if c == 115 { return [Ins { op: "class", ranges: SPACE }] }
        if c == 83 { return [Ins { op: "class", ranges: SPACE, neg: true }] }
        if !in_class && c == 98 { return [Ins { op: "wordb" }] }
        if !in_class && c == 66 { return [Ins { op: "nwordb" }] }
        if !in_class && c >= 49 && c <= 57 {
            var n = c - 48
            while self.peek() >= 48 && self.peek() <= 57 {
                n = n * 10 + self.peek() - 48
                self.i += 1
            }
            return [Ins { op: "backref", c: n }]
        }
        return [self.char(self.escaped(c))]
    }

    // the code point an escape like \n, \t, A, \x41 or \. stands for
    fn escaped(self, c: int) -> int {
        if c == 110 { return 10 }
        if c == 116 { return 9 }
        if c == 114 { return 13 }
        if c == 102 { return 12 }
        if c == 118 { return 11 }
        if c == 48 { return 0 }
        if c == 120 || c == 117 {
            let n = if c == 120 { 2 } else { 4 }
            var v = 0
            var got = 0
            if c == 117 && self.peek() == 123 {
                self.i += 1
                while !self.at_end() && self.peek() != 125 {
                    v = v * 16 + hexd(self.peek())
                    self.i += 1
                }
                self.i += 1
                return v
            }
            while got < n && !self.at_end() && hexd(self.peek()) >= 0 {
                v = v * 16 + hexd(self.peek())
                self.i += 1
                got += 1
            }
            return if got == n { v } else { c }
        }
        return c
    }

    fn class(self) -> Ins {
        let ins = Ins { op: "class" }
        if self.peek() == 94 {
            ins.neg = true
            self.i += 1
        }
        var first = true
        while !self.at_end() && (self.peek() != 93 || first) {
            first = false
            var lo = self.peek()
            self.i += 1
            if lo == 92 {
                let e = self.peek()
                if e == 100 || e == 119 || e == 115 || e == 68 || e == 87 || e == 83 {
                    let sub = self.escape(true)[0]
                    if sub.neg {
                        // [\D] and friends: approximate by the complement's ranges
                        for r in complement(sub.ranges) { ins.ranges.push(r) }
                    } else {
                        for r in sub.ranges { ins.ranges.push(r) }
                    }
                    continue
                }
                self.i += 1
                lo = if e == 98 { 8 } else { self.escaped(e) }
            }
            var hi = lo
            if self.peek() == 45 && self.i + 1 < self.cs.len() && self.cs[self.i + 1] != 93 {
                self.i += 1
                hi = self.peek()
                self.i += 1
                if hi == 92 {
                    let e = self.peek()
                    self.i += 1
                    hi = self.escaped(e)
                }
            }
            if hi < lo {
                self.error = "range out of order in character class"
                return ins
            }
            ins.ranges.push(lo)
            ins.ranges.push(hi)
            if self.icase {
                // the other case of letters in the range
                for ch in lo..min(hi, 0x7f) + 1 {
                    if ch >= 65 && ch <= 90 {
                        ins.ranges.push(ch + 32)
                        ins.ranges.push(ch + 32)
                    } else if ch >= 97 && ch <= 122 {
                        ins.ranges.push(ch - 32)
                        ins.ranges.push(ch - 32)
                    }
                }
            }
        }
        if self.at_end() {
            self.error = "missing ]"
            return ins
        }
        self.i += 1
        return ins
    }
}

const WORD = [48, 57, 65, 90, 95, 95, 97, 122]
const SPACE = [9, 13, 32, 32, 160, 160, 0x2028, 0x2029, 0xfeff, 0xfeff]

fn complement(r: [int]) -> [int] {
    // r as sorted ranges; the gaps between them
    var out: [int] = []
    var prev = 0
    var i = 0
    while i + 1 < r.len() {
        if r[i] > prev {
            out.push(prev)
            out.push(r[i] - 1)
        }
        prev = r[i + 1] + 1
        i += 2
    }
    out.push(prev)
    out.push(0x10ffff)
    return out
}

fn hexd(c: int) -> int {
    if c >= 48 && c <= 57 { return c - 48 }
    if c >= 97 && c <= 102 { return c - 87 }
    if c >= 65 && c <= 70 { return c - 55 }
    return -1
}

extern fn st_chr(code: int) -> str
extern fn st_ord(s: str) -> int

fn code_points(s: str) -> [int] {
    return s.chars().map(c => st_ord(c))
}

fn compile(pattern: str, icase: bool, multiline: bool, dotall: bool) -> Re {
    let c = Compiler { cs: code_points(pattern), icase }
    var prog = c.alt()
    if c.error == "" && !c.at_end() { c.error = "unmatched )" }
    prog.push(Ins { op: "match" })
    return Re { prog, groups: c.groups, names: c.names, icase, multiline, dotall, error: c.error }
}

fn is_word(c: int) -> bool { return (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }

fn in_class(ins: Ins, c: int) -> bool {
    var hit = false
    var i = 0
    while i + 1 < ins.ranges.len() {
        if c >= ins.ranges[i] && c <= ins.ranges[i + 1] {
            hit = true
            break
        }
        i += 2
    }
    return hit != ins.neg
}

struct Frame {
    pc: int,
    sp: int,
    caps: [int],
}

// Run `prog` at position `start` of `text`. Returns the capture positions (2 per group; -1 unset),
// or [] if it doesn't match there.
fn run(re: Re, prog: [Ins], text: [int], start: int, budget: [int]) -> [int] {
    var caps: [int] = []
    for i in 0..2 * re.groups { caps.push(-1) }
    var stack = [Frame { pc: 0, sp: start, caps }]
    while !stack.is_empty() {
        let f = stack.pop()
        var pc = f.pc
        var sp = f.sp
        var cp = f.caps
        while true {
            budget[0] = budget[0] - 1
            if budget[0] < 0 { return [] }
            let ins = prog[pc]
            let op = ins.op
            if op == "char" {
                if sp < text.len() && text[sp] == ins.c {
                    pc += 1
                    sp += 1
                    continue
                }
                break
            }
            if op == "any" {
                if sp < text.len() && (re.dotall || (text[sp] != 10 && text[sp] != 13 && text[sp] != 0x2028 && text[sp] != 0x2029)) {
                    pc += 1
                    sp += 1
                    continue
                }
                break
            }
            if op == "class" {
                if sp < text.len() && in_class(ins, text[sp]) {
                    pc += 1
                    sp += 1
                    continue
                }
                break
            }
            if op == "split" {
                var copy: [int] = []
                for x in cp { copy.push(x) }
                stack.push(Frame { pc: pc + ins.y, sp, caps: copy })
                if stack.len() > 100_000 { return [] }
                pc += ins.x
                continue
            }
            if op == "jmp" {
                pc += ins.x
                continue
            }
            if op == "save" {
                var copy: [int] = []
                for x in cp { copy.push(x) }
                copy[ins.c] = sp
                cp = copy
                pc += 1
                continue
            }
            if op == "bol" {
                if sp == 0 || (re.multiline && (text[sp - 1] == 10 || text[sp - 1] == 13)) {
                    pc += 1
                    continue
                }
                break
            }
            if op == "eol" {
                if sp == text.len() || (re.multiline && (text[sp] == 10 || text[sp] == 13)) {
                    pc += 1
                    continue
                }
                break
            }
            if op == "wordb" || op == "nwordb" {
                let a = sp > 0 && is_word(text[sp - 1])
                let b = sp < text.len() && is_word(text[sp])
                if (a != b) == (op == "wordb") {
                    pc += 1
                    continue
                }
                break
            }
            if op == "backref" {
                let g = ins.c
                if 2 * g + 1 >= cp.len() || cp[2 * g] < 0 || cp[2 * g + 1] < 0 {
                    pc += 1
                    continue
                }
                let s0 = cp[2 * g]
                let n = cp[2 * g + 1] - s0
                var same = sp + n <= text.len()
                if same {
                    for k in 0..n {
                        var x = text[s0 + k]
                        var y = text[sp + k]
                        if re.icase {
                            if x >= 65 && x <= 90 { x += 32 }
                            if y >= 65 && y <= 90 { y += 32 }
                        }
                        if x != y {
                            same = false
                            break
                        }
                    }
                }
                if same {
                    pc += 1
                    sp += n
                    continue
                }
                break
            }
            if op == "look" {
                var sub = ins.sub
                sub.push(Ins { op: "match" })
                let r = run(re, sub, text, sp, budget)
                let hit = !r.is_empty()
                if hit != ins.neg {
                    pc += 1
                    continue
                }
                break
            }
            if op == "match" {
                cp[0] = start
                cp[1] = sp
                return cp
            }
            break
        }
    }
    return []
}

// The first match at or after `from`: capture positions in code points, or [].
fn exec(re: Re, text: [int], from: int) -> [int] {
    let budget = [MAX_STEPS]
    var start = from
    while start <= text.len() {
        let r = run(re, re.prog, text, start, budget)
        if !r.is_empty() { return r }
        if budget[0] < 0 { return [] }
        start += 1
    }
    return []
}
