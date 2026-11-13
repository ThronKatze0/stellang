// json: parse JSON into a `Json` value and turn it back into text.
// (To turn your own structs, enums, lists and maps into JSON, use the builtin `to_json(value)`.)
//
//     let doc = json.parse(req.body)?
//     let name = doc.get("user")?.get("name")?.as_str() ?? "anonymous"
//     match doc {
//         Obj(fields) => println(fields.keys()),
//         _ => println("not an object"),
//     }

extern fn st_chr(code: int) -> str

enum Json {
    Null,
    Bool(bool),
    Num(float),
    Str(str),
    Arr([Json]),
    Obj({str: Json}),

    // A field of an object.
    fn get(self, key: str) -> Json? {
        let Obj(fields) = self else { return none }
        return fields.get(key)
    }

    // An item of an array.
    fn at(self, i: int) -> Json? {
        let Arr(items) = self else { return none }
        return items.get(i)
    }

    fn as_str(self) -> str? {
        let Str(s) = self else { return none }
        return s
    }

    fn as_float(self) -> float? {
        let Num(n) = self else { return none }
        return n
    }

    fn as_int(self) -> int? {
        let Num(n) = self else { return none }
        return int(n)
    }

    fn as_bool(self) -> bool? {
        let Bool(b) = self else { return none }
        return b
    }

    fn as_list(self) -> [Json]? {
        let Arr(items) = self else { return none }
        return items
    }

    fn is_null(self) -> bool {
        return self == .Null
    }

    // Back to JSON text.
    fn stringify(self) -> str {
        return match self {
            Null => "null",
            Bool(b) => str(b),
            Num(n) => if n == float(int(n)) && abs(n) < 1e15 { str(int(n)) } else { to_json(n) },
            Str(s) => to_json(s),
            Arr(items) => "[" + items.map(x => x.stringify()).join(",") + "]",
            Obj(fields) => {
                let parts: [str] = []
                for k, v in fields { parts.push(to_json(k) + ":" + v.stringify()) }
                "{" + parts.join(",") + "}"
            },
        }
    }
}

struct Parser {
    cs: [str],
    i: int = 0,

    fn peek(self) -> str {
        return self.cs.get(self.i) ?? ""
    }

    fn skip_ws(self) {
        while self.peek() == " " || self.peek() == "\n" || self.peek() == "\t" || self.peek() == "\r" {
            self.i += 1
        }
    }

    fn fail(self, what: str) -> str {
        let got = if self.i < self.cs.len() { "`${self.peek()}`" } else { "the end" }
        return "bad JSON at ${self.i}: expected ${what}, found ${got}"
    }

    fn expect(self, s: str) -> void! {
        if self.peek() != s {
            return err(self.fail("`${s}`"))
        }
        self.i += 1
    }

    fn word(self, w: str, v: Json) -> Json! {
        for c in w.chars() {
            self.expect(c)?
        }
        return v
    }

    fn value(self) -> Json! {
        self.skip_ws()
        let c = self.peek()
        return match c {
            "{" => self.object(),
            "[" => self.array(),
            "\"" => Json.Str(self.string()?),
            "t" => self.word("true", .Bool(true)),
            "f" => self.word("false", .Bool(false)),
            "n" => self.word("null", .Null),
            _ => self.number(),
        }
    }

    fn object(self) -> Json! {
        self.i += 1
        let fields: {str: Json} = {}
        self.skip_ws()
        if self.peek() == "}" {
            self.i += 1
            return Json.Obj(fields)
        }
        while true {
            self.skip_ws()
            let key = self.string()?
            self.skip_ws()
            self.expect(":")?
            fields[key] = self.value()?
            self.skip_ws()
            if self.peek() == "}" {
                self.i += 1
                return Json.Obj(fields)
            }
            self.expect(",")?
        }
    }

    fn array(self) -> Json! {
        self.i += 1
        let items: [Json] = []
        self.skip_ws()
        if self.peek() == "]" {
            self.i += 1
            return Json.Arr(items)
        }
        while true {
            items.push(self.value()?)
            self.skip_ws()
            if self.peek() == "]" {
                self.i += 1
                return Json.Arr(items)
            }
            self.expect(",")?
        }
    }

    fn string(self) -> str! {
        self.expect("\"")?
        let out: [str] = []
        while true {
            let c = self.peek()
            self.i += 1
            match c {
                "" => { return err(self.fail("`\"`")) },
                "\"" => { return out.join("") },
                "\\" => {
                    let e = self.peek()
                    self.i += 1
                    out.push(match e {
                        "n" => "\n",
                        "t" => "\t",
                        "r" => "\r",
                        "b" => st_chr(8),
                        "f" => st_chr(12),
                        "u" => st_chr(self.hex4()?),
                        "\"" | "\\" | "/" => e,
                        _ => { return err(self.fail("an escape")) },
                    })
                },
                _ => out.push(c),
            }
        }
        return err("unreachable")
    }

    fn hex4(self) -> int! {
        var n = 0
        for k in 0..4 {
            let d = "0123456789abcdef".find(self.peek().lower())
            if d < 0 || self.peek() == "" {
                return err(self.fail("a hex digit"))
            }
            n = n * 16 + d
            self.i += 1
        }
        return n
    }

    fn number(self) -> Json! {
        let start = self.i
        while "0123456789+-.eE".contains(self.peek()) && self.peek() != "" {
            self.i += 1
        }
        if self.i == start {
            return err(self.fail("a value"))
        }
        let n = float(self.cs.slice(start, self.i).join("")) catch e {
            return err("bad JSON number at ${start}")
        }
        return Json.Num(n)
    }
}

// Parse JSON text.
fn parse(text: str) -> Json! {
    let p = Parser { cs: text.chars() }
    let v = p.value()?
    p.skip_ws()
    if p.i < p.cs.len() {
        return err(p.fail("the end"))
    }
    return v
}
