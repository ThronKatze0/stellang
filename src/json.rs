//! Just enough JSON for the language server (the compiler has no dependencies).

use std::fmt::Write;

#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
}

impl Json {
    pub fn get(&self, key: &str) -> &Json {
        match self {
            Json::Obj(fs) => fs.iter().find(|f| f.0 == key).map_or(&Json::Null, |f| &f.1),
            _ => &Json::Null,
        }
    }

    /// `j.at(&["params", "textDocument", "uri"])`
    pub fn at(&self, path: &[&str]) -> &Json {
        path.iter().fold(self, |j, k| j.get(k))
    }

    pub fn str(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s),
            _ => None,
        }
    }

    pub fn num(&self) -> Option<f64> {
        match self {
            Json::Num(n) => Some(*n),
            _ => None,
        }
    }

    pub fn arr(&self) -> &[Json] {
        match self {
            Json::Arr(xs) => xs,
            _ => &[],
        }
    }

    pub fn write(&self, out: &mut String) {
        match self {
            Json::Null => out.push_str("null"),
            Json::Bool(b) => write!(out, "{b}").unwrap(),
            Json::Num(n) if n.fract() == 0.0 && n.abs() < 1e15 => write!(out, "{}", *n as i64).unwrap(),
            Json::Num(n) => write!(out, "{n}").unwrap(),
            Json::Str(s) => quote(s, out),
            Json::Arr(xs) => {
                out.push('[');
                for (i, x) in xs.iter().enumerate() {
                    if i > 0 { out.push(',') }
                    x.write(out);
                }
                out.push(']');
            }
            Json::Obj(fs) => {
                out.push('{');
                for (i, (k, v)) in fs.iter().enumerate() {
                    if i > 0 { out.push(',') }
                    quote(k, out);
                    out.push(':');
                    v.write(out);
                }
                out.push('}');
            }
        }
    }
}

impl std::fmt::Display for Json {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        let mut s = String::new();
        self.write(&mut s);
        f.write_str(&s)
    }
}

fn quote(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => write!(out, "\\u{:04x}", c as u32).unwrap(),
            c => out.push(c),
        }
    }
    out.push('"');
}

/// Build an object: `obj([("a", 1.into()), ...])`
pub fn obj<const N: usize>(fields: [(&str, Json); N]) -> Json {
    Json::Obj(fields.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
}

impl From<&str> for Json {
    fn from(s: &str) -> Json { Json::Str(s.into()) }
}
impl From<String> for Json {
    fn from(s: String) -> Json { Json::Str(s) }
}
impl From<bool> for Json {
    fn from(b: bool) -> Json { Json::Bool(b) }
}
impl From<i64> for Json {
    fn from(n: i64) -> Json { Json::Num(n as f64) }
}
impl From<u32> for Json {
    fn from(n: u32) -> Json { Json::Num(n as f64) }
}
impl From<usize> for Json {
    fn from(n: usize) -> Json { Json::Num(n as f64) }
}
impl<T: Into<Json>> From<Vec<T>> for Json {
    fn from(xs: Vec<T>) -> Json { Json::Arr(xs.into_iter().map(Into::into).collect()) }
}

pub fn parse(s: &str) -> Option<Json> {
    let cs: Vec<char> = s.chars().collect();
    let mut i = 0;
    let v = value(&cs, &mut i)?;
    ws(&cs, &mut i);
    (i == cs.len()).then_some(v)
}

fn ws(cs: &[char], i: &mut usize) {
    while *i < cs.len() && cs[*i].is_whitespace() { *i += 1 }
}

fn value(cs: &[char], i: &mut usize) -> Option<Json> {
    ws(cs, i);
    let word = |i: &mut usize, w: &str, v: Json| {
        let end = *i + w.len();
        (cs.get(*i..end)?.iter().collect::<String>() == w).then(|| { *i = end; v })
    };
    match *cs.get(*i)? {
        '{' => {
            *i += 1;
            let mut fs = vec![];
            ws(cs, i);
            if cs.get(*i) == Some(&'}') { *i += 1; return Some(Json::Obj(fs)) }
            loop {
                ws(cs, i);
                let Json::Str(k) = value(cs, i)? else { return None };
                ws(cs, i);
                if cs.get(*i) != Some(&':') { return None }
                *i += 1;
                fs.push((k, value(cs, i)?));
                ws(cs, i);
                match cs.get(*i)? {
                    ',' => *i += 1,
                    '}' => { *i += 1; return Some(Json::Obj(fs)) }
                    _ => return None,
                }
            }
        }
        '[' => {
            *i += 1;
            let mut xs = vec![];
            ws(cs, i);
            if cs.get(*i) == Some(&']') { *i += 1; return Some(Json::Arr(xs)) }
            loop {
                xs.push(value(cs, i)?);
                ws(cs, i);
                match cs.get(*i)? {
                    ',' => *i += 1,
                    ']' => { *i += 1; return Some(Json::Arr(xs)) }
                    _ => return None,
                }
            }
        }
        '"' => {
            *i += 1;
            let mut s = String::new();
            loop {
                let c = *cs.get(*i)?;
                *i += 1;
                match c {
                    '"' => return Some(Json::Str(s)),
                    '\\' => {
                        let e = *cs.get(*i)?;
                        *i += 1;
                        s.push(match e {
                            'n' => '\n', 't' => '\t', 'r' => '\r', 'b' => '\u{8}', 'f' => '\u{c}',
                            'u' => {
                                let hex = |i: &mut usize| -> Option<u32> {
                                    let h: String = cs.get(*i..*i + 4)?.iter().collect();
                                    *i += 4;
                                    u32::from_str_radix(&h, 16).ok()
                                };
                                let mut c = hex(i)?;
                                if (0xD800..0xDC00).contains(&c) && cs.get(*i) == Some(&'\\') && cs.get(*i + 1) == Some(&'u') {
                                    *i += 2;
                                    let lo = hex(i)?;
                                    c = 0x10000 + ((c - 0xD800) << 10) + (lo.wrapping_sub(0xDC00) & 0x3FF);
                                }
                                char::from_u32(c).unwrap_or('\u{FFFD}')
                            }
                            c => c,
                        });
                    }
                    c => s.push(c),
                }
            }
        }
        't' => word(i, "true", Json::Bool(true)),
        'f' => word(i, "false", Json::Bool(false)),
        'n' => word(i, "null", Json::Null),
        _ => {
            let start = *i;
            while *i < cs.len() && matches!(cs[*i], '0'..='9' | '-' | '+' | '.' | 'e' | 'E') { *i += 1 }
            cs[start..*i].iter().collect::<String>().parse().ok().map(Json::Num)
        }
    }
}
