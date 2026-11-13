// `calc`: integer arithmetic with + - * / % & | ^ << >> ~ and parentheses, numbers in decimal or 0x/0b.

enum Tok {
    Num(int),
    Op(str),
}

fn lex(s: str) -> [Tok]! {
    var out: [Tok] = []
    let cs = s.chars()
    var i = 0
    while i < cs.len() {
        let c = cs[i]
        if c == " " {
            i += 1
            continue
        }
        if "0123456789".contains(c) {
            var j = i
            while j < cs.len() && "0123456789abcdefABCDEFxXbB_".contains(cs[j]) { j += 1 }
            out.push(.Num(number(cs.slice(i, j).join(""))?))
            i = j
            continue
        }
        let two = if i + 1 < cs.len() { c + cs[i + 1] } else { "" }
        if two == "<<" || two == ">>" {
            out.push(.Op(two))
            i += 2
            continue
        }
        if "+-*/%&|^~()".contains(c) {
            out.push(.Op(c))
            i += 1
            continue
        }
        return err("unexpected '${c}'")
    }
    return out
}

fn number(s: str) -> int! {
    let t = s.replace("_", "").lower()
    var base = 10
    var digits = t
    if t.starts_with("0x") {
        base = 16
        digits = t.slice(2, t.len())
    } else if t.starts_with("0b") {
        base = 2
        digits = t.slice(2, t.len())
    }
    if digits == "" { return err("bad number ${s}") }
    var n = 0
    for d in digits.chars() {
        let v = "0123456789abcdef".find(d)
        if v < 0 || v >= base { return err("bad number ${s}") }
        n = n * base + v
    }
    return n
}

struct Parser {
    toks: [Tok],
    at: int = 0,

    fn peek(self) -> str {
        if let t = self.toks.get(self.at) {
            return match t {
                .Op(o) => o,
                .Num(_) => "num",
            }
        }
        return ""
    }

    // precedence climbing: | < ^ < & < shifts < + - < * / %
    fn expr(self, level: int) -> int! {
        if level == 6 { return self.unary() }
        var x = self.expr(level + 1)?
        while true {
            let op = self.peek()
            let ops = [["|"], ["^"], ["&"], ["<<", ">>"], ["+", "-"], ["*", "/", "%"]][level]
            if !ops.contains(op) { break }
            self.at += 1
            let y = self.expr(level + 1)?
            if (op == "/" || op == "%") && y == 0 { return err("division by zero") }
            x = match op {
                "|" => x | y,
                "^" => x ^ y,
                "&" => x & y,
                "<<" => x << y,
                ">>" => x >> y,
                "+" => x + y,
                "-" => x - y,
                "*" => x * y,
                "/" => x / y,
                _ => x % y,
            }
        }
        return x
    }

    fn unary(self) -> int! {
        let op = self.peek()
        if op == "-" || op == "~" || op == "+" {
            self.at += 1
            let x = self.unary()?
            return if op == "-" { -x } else if op == "~" { ~x } else { x }
        }
        if op == "(" {
            self.at += 1
            let x = self.expr(0)?
            if self.peek() != ")" { return err("missing )") }
            self.at += 1
            return x
        }
        if let t = self.toks.get(self.at) {
            if let .Num(n) = t {
                self.at += 1
                return n
            }
        }
        if op == "" { return err("expression ends too soon") }
        return err("unexpected ${op}")
    }
}

fn eval(s: str) -> int! {
    let p = Parser { toks: lex(s)? }
    let x = p.expr(0)?
    if p.at < p.toks.len() { return err("unexpected ${p.peek()}") }
    return x
}

fn hex(n: int) -> str {
    if n == 0 { return "0x0" }
    var s = ""
    var x = n
    var k = 0
    while x != 0 && k < 16 {
        s = "0123456789abcdef"[x & 15] + s
        x = x >> 4
        k += 1
    }
    return "0x" + s
}
