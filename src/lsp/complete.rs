//! Completion, parameter-name hints and quick fixes.
//!
//! Completion asks the real type checker: the word being typed is swapped for a placeholder name,
//! the file is checked, and the checker's probes say what type sits before the `.`, what type a
//! `.Variant` must have, and what a `match` is matching on. So it is exactly as smart as the
//! compiler, and learns every new feature with it.

use super::*;

const HOLE: &str = "__complete";

/// What the builtin types can do: (type, name, params, returns, doc).
pub(super) const BUILTIN_METHODS: &[(&str, &str, &str, &str, &str)] = &[
    ("str", "len", "", "int", "Length in bytes."),
    ("str", "is_empty", "", "bool", "True for `\"\"`."),
    ("str", "split", "sep: str", "[str]", "The pieces between each `sep`."),
    ("str", "lines", "", "[str]", "The lines, without their line breaks."),
    ("str", "chars", "", "[str]", "Each character as a one-character string."),
    ("str", "find", "needle: str", "int", "Byte index of the first `needle`, or -1."),
    ("str", "count", "needle: str", "int", "How many times `needle` occurs."),
    ("str", "slice", "from: int, to: int", "str", "Bytes `from` up to (not including) `to`."),
    ("str", "trim", "", "str", "Without whitespace at both ends."),
    ("str", "trim_start", "", "str", "Without leading whitespace."),
    ("str", "trim_end", "", "str", "Without trailing whitespace."),
    ("str", "lower", "", "str", "In lowercase."),
    ("str", "upper", "", "str", "In uppercase."),
    ("str", "starts_with", "prefix: str", "bool", "Whether it begins with `prefix`."),
    ("str", "ends_with", "suffix: str", "bool", "Whether it ends with `suffix`."),
    ("str", "contains", "needle: str", "bool", "Whether `needle` occurs in it."),
    ("str", "replace", "from: str, to: str", "str", "Every `from` replaced by `to`."),
    ("str", "repeat", "n: int", "str", "`n` copies, joined."),
    ("str", "reverse", "", "str", "Back to front."),
    ("list", "len", "", "int", "Number of items."),
    ("list", "is_empty", "", "bool", "True when there are no items."),
    ("list", "push", "item: T", "void", "Add `item` at the end."),
    ("list", "pop", "", "T", "Remove and return the last item (panics when empty)."),
    ("list", "insert", "i: int, item: T", "void", "Put `item` at index `i`, moving the rest up."),
    ("list", "remove", "i: int", "T", "Take out the item at index `i`."),
    ("list", "slice", "from: int, to: int", "[T]", "A copy of items `from` up to (not including) `to`."),
    ("list", "contains", "item: T", "bool", "Whether `item` is in the list."),
    ("list", "index_of", "item: T", "int", "Index of the first `item`, or -1."),
    ("list", "sort", "", "void", "Sort in place (numbers and strings)."),
    ("list", "reverse", "", "void", "Reverse in place."),
    ("list", "map", "f: fn(T) -> U", "[U]", "A new list of `f(item)` for every item."),
    ("list", "filter", "f: fn(T) -> bool", "[T]", "The items for which `f` is true."),
    ("list", "find", "f: fn(T) -> bool", "T?", "The first item for which `f` is true."),
    ("list", "any", "f: fn(T) -> bool", "bool", "Whether `f` is true for some item."),
    ("list", "all", "f: fn(T) -> bool", "bool", "Whether `f` is true for every item."),
    ("list", "sum", "", "T", "The total of a list of numbers."),
    ("list", "join", "sep: str", "str", "The items as one string, `sep` between them."),
    ("list", "first", "", "T?", "The first item, or `none`."),
    ("list", "last", "", "T?", "The last item, or `none`."),
    ("list", "get", "i: int", "T?", "The item at `i`, or `none` when out of range."),
    ("map", "len", "", "int", "Number of entries."),
    ("map", "is_empty", "", "bool", "True when there are no entries."),
    ("map", "get", "key: K", "V?", "The value for `key`, or `none`. `m.get(key, fallback)` gives `fallback` instead."),
    ("map", "contains", "key: K", "bool", "Whether `key` has a value."),
    ("map", "remove", "key: K", "bool", "Delete `key`; true if it was there."),
    ("map", "keys", "", "[K]", "All keys."),
    ("map", "values", "", "[V]", "All values."),
    ("set", "len", "", "int", "Number of items."),
    ("set", "is_empty", "", "bool", "True when empty."),
    ("set", "add", "item: T", "void", "Put `item` in the set."),
    ("set", "contains", "item: T", "bool", "Whether `item` is in the set."),
    ("set", "remove", "item: T", "bool", "Take `item` out; true if it was there."),
    ("set", "to_list", "", "[T]", "The items as a list."),
    ("opt", "is_some", "", "bool", "True when there is a value."),
    ("opt", "is_none", "", "bool", "True when there is no value."),
    ("opt", "unwrap", "", "T", "The value; panics on `none` (prefer `??`, `?`, `if let`)."),
    ("float", "floor", "", "float", "Round down."),
    ("float", "ceil", "", "float", "Round up."),
    ("float", "round", "", "float", "Round to the nearest whole number."),
    ("float", "sqrt", "", "float", "Square root."),
    ("float", "abs", "", "float", "Without its sign."),
];

/// The builtin functions: (name, params, returns, doc).
pub(super) const BUILTIN_FNS: &[(&str, &str, &str, &str)] = &[
    ("println", "value", "void", "Print any value and a line break."),
    ("print", "value", "void", "Print any value."),
    ("str", "value", "str", "Any value as text."),
    ("int", "value", "int!", "A float rounded toward zero (an `int`), or a string parsed (an `int!`)."),
    ("float", "value", "float", "An int as a float, or a string parsed (a `float!`)."),
    ("min", "a, b", "number", "The smaller of two numbers."),
    ("max", "a, b", "number", "The larger of two numbers."),
    ("abs", "x", "number", "A number without its sign."),
    ("env", "name: str", "str", "An environment variable (`\"\"` when unset)."),
    ("panic", "message: str", "void", "Stop the program with a message and the source location."),
    ("some", "value", "T?", "An optional that holds `value`."),
    ("ok", "value", "T!", "A successful result."),
    ("err", "message: str", "T!", "A failed result with a message."),
    ("to_json", "value", "str", "Any struct, enum, list, map or scalar as JSON."),
    ("args", "", "[str]", "The command-line arguments, without the program name."),
    ("read_line", "", "str?", "One line from standard input without its line break; `none` at the end of input."),
    ("exit", "code: int", "void", "End the program now with an exit code."),
];

/// Keyword snippets: (label, snippet, detail).
const SNIPPETS: &[(&str, &str, &str)] = &[
    ("fn", "fn ${1:name}(${2}) ${3:-> ${4:int} }{\n\t$0\n}", "function"),
    ("main", "fn main() {\n\t$0\n}", "fn main"),
    ("struct", "struct ${1:Name} {\n\t${2:field}: ${3:str},\n}", "struct declaration"),
    ("enum", "enum ${1:Name} {\n\t${2:A},\n\t${3:B},\n}", "enum declaration"),
    ("if", "if ${1:condition} {\n\t$0\n}", "if"),
    ("ife", "if ${1:condition} {\n\t$2\n} else {\n\t$0\n}", "if / else"),
    ("iflet", "if let some(${1:value}) = ${2:optional} {\n\t$0\n}", "if let"),
    ("else", "else {\n\t$0\n}", "else"),
    ("for", "for ${1:item} in ${2:items} {\n\t$0\n}", "for … in"),
    ("fori", "for ${1:i} in ${2:0}..${3:n} {\n\t$0\n}", "for over a range"),
    ("while", "while ${1:condition} {\n\t$0\n}", "while"),
    ("match", "match ${1:value} {\n\t${2:pattern} => ${3:result},\n\t_ => ${0:other},\n}", "match"),
    ("let", "let ${1:name} = ${0:value}", "immutable binding"),
    ("var", "var ${1:name} = ${0:value}", "mutable binding"),
    ("letelse", "let ${1:value} = ${2:optional} else {\n\t${0:return}\n}", "let … else"),
    ("const", "const ${1:NAME} = ${0:value}", "constant"),
    ("return", "return $0", "return"),
    ("import", "import ${0:http}", "import a module"),
    ("catch", "catch ${1:e} {\n\t$0\n}", "handle an error"),
    ("lambda", "(${1:x}) => ${0:x}", "anonymous function"),
    ("server", "import http\n\nfn main() -> void! {\n\tlet app = http.app()\n\tapp.get(\"/\", (req, res) => res.send(\"${1:hello}\"))\n\tapp.listen(${2:8080})?\n}", "a web server"),
];

#[derive(Clone)]
struct Item {
    label: String,
    kind: u32,
    detail: String,
    doc: String,
    snippet: Option<String>,
    sort: u8,
    edit: Option<(Pos, String)>, // replace from here to the cursor (postfix completions)
    filter: Option<String>,
    extra: Vec<Json>, // additional edits (imports, `?.`)
    sig_help: bool,
    deprecated: bool,
    label_detail: Option<String>,
    label_desc: Option<String>,
}

fn item(label: impl Into<String>, kind: u32, detail: impl Into<String>, sort: u8) -> Item {
    Item {
        label: label.into(),
        kind,
        detail: detail.into(),
        doc: String::new(),
        snippet: None,
        sort,
        edit: None,
        filter: None,
        extra: vec![],
        sig_help: false,
        deprecated: false,
        label_detail: None,
        label_desc: None,
    }
}

// LSP CompletionItemKind
const K_METHOD: u32 = 2;
const K_FUNCTION: u32 = 3;
const K_FIELD: u32 = 5;
const K_VARIABLE: u32 = 6;
const K_MODULE: u32 = 9;
const K_ENUM: u32 = 13;
const K_KEYWORD: u32 = 14;
const K_SNIPPET: u32 = 15;
const K_ENUM_MEMBER: u32 = 20;
const K_CONSTANT: u32 = 21;
const K_STRUCT: u32 = 22;
const K_TYPE: u32 = 25;

fn decl_kind(k: &str) -> u32 {
    match k {
        "fn" => K_FUNCTION,
        "method" => K_METHOD,
        "field" => K_FIELD,
        "struct" => K_STRUCT,
        "enum" => K_ENUM,
        "variant" => K_ENUM_MEMBER,
        "const" => K_CONSTANT,
        _ => K_VARIABLE,
    }
}

/// `fn add(self, a: int, b: str) -> T` -> (["a: int", "b: str"], "T")
pub(super) fn params_of(sig: &str) -> (Vec<String>, String) {
    let first = sig.lines().next().unwrap_or("");
    let Some(open) = first.find('(') else { return (vec![], String::new()) };
    let mut depth = 0;
    let mut close = first.len();
    for (i, c) in first[open..].char_indices() {
        match c {
            '(' | '[' | '{' => depth += 1,
            ')' | ']' | '}' => {
                depth -= 1;
                if depth == 0 {
                    close = open + i;
                    break;
                }
            }
            _ => {}
        }
    }
    let mut ps: Vec<String> = split_top(&first[open + 1..close.min(first.len())]).into_iter().map(|p| p.trim().to_string()).filter(|p| !p.is_empty()).collect();
    if ps.first().is_some_and(|p| p == "self") {
        ps.remove(0);
    }
    let ret = first.get(close + 1..).unwrap_or("").trim().strip_prefix("->").unwrap_or("").trim().trim_end_matches('{').trim().to_string();
    (ps, ret)
}

/// `name(${1:a}, ${2:b})$0`
fn call_snippet(name: &str, params: &[String], parens_follow: bool) -> String {
    if parens_follow {
        return name.to_string();
    }
    let ps: Vec<String> = params
        .iter()
        .enumerate()
        .map(|(i, p)| {
            let n = p.split(':').next().unwrap_or(p).trim();
            let n = if n.contains(['(', ' ', '[']) { "arg" } else { n };
            if p.contains("fn(") {
                // a callback: write the lambda's head
                let ins = p.split("fn(").nth(1).and_then(|r| r.split(')').next()).unwrap_or("");
                let k = if ins.trim().is_empty() { 0 } else { split_top(ins).len() };
                let names = lambda_names(ins, k);
                format!("(${{{}:{}}}) => ${{{}}}", i + 1, names, i + 2 + params.len())
            } else {
                format!("${{{}:{n}}}", i + 1)
            }
        })
        .collect();
    format!("{name}({})$0", ps.join(", "))
}

/// Parameter names for a callback with these parameter types: `Request, Response` -> `req, res`.
fn lambda_names(types: &str, n: usize) -> String {
    let mut used = HashSet::new();
    let ts = split_top(types);
    (0..n)
        .map(|i| {
            let t = ts.get(i).map(|t| t.trim()).unwrap_or("");
            let base = match t.rsplit('.').next().unwrap_or(t) {
                "Request" => "req".to_string(),
                "Response" => "res".to_string(),
                "WebSocket" => "ws".to_string(),
                "str" => "s".to_string(),
                "int" => "n".to_string(),
                "fn()" => "next".to_string(),
                t if t.starts_with('[') => "items".to_string(),
                t if t.chars().next().is_some_and(|c| c.is_ascii_uppercase()) => to_snake(t),
                _ => "x".to_string(),
            };
            let mut name = base.clone();
            let mut k = 2;
            while !used.insert(name.clone()) {
                name = format!("{base}{k}");
                k += 1;
            }
            name
        })
        .collect::<Vec<_>>()
        .join(", ")
}

fn to_snake(s: &str) -> String {
    let mut out = String::new();
    for (i, c) in s.chars().enumerate() {
        if c.is_ascii_uppercase() {
            if i > 0 {
                out.push('_');
            }
            out.push(c.to_ascii_lowercase());
        } else if c.is_ascii_alphanumeric() || c == '_' {
            out.push(c);
        }
    }
    if out.is_empty() { "x".into() } else { out }
}

/// Which kind of builtin a type string is: `[int]` -> list.
fn group_of(ty: &str) -> Option<&'static str> {
    Some(match ty {
        "str" => "str",
        "float" => "float",
        t if t.ends_with('?') => "opt",
        t if t.starts_with('[') => "list",
        t if t.starts_with('{') && t.contains(':') => "map",
        t if t.starts_with('{') => "set",
        _ => return None,
    })
}

/// `{str: [int]}` -> ("str", "[int]")
fn map_parts(ty: &str) -> (String, String) {
    let inner = ty.trim_start_matches('{').trim_end_matches('}');
    let mut depth = 0;
    for (i, c) in inner.char_indices() {
        match c {
            '(' | '[' | '{' => depth += 1,
            ')' | ']' | '}' => depth -= 1,
            ':' if depth == 0 => return (inner[..i].trim().into(), inner[i + 1..].trim().into()),
            _ => {}
        }
    }
    (inner.into(), String::new())
}

/// The builtin method's signature with `T`, `K`, `V` filled in from the receiver's type.
fn builtin_sig(ty: &str, group: &str, params: &str, ret: &str) -> (String, String) {
    let (t, k, v) = match group {
        "list" => (ty.trim_start_matches('[').trim_end_matches(']').to_string(), String::new(), String::new()),
        "set" => (ty.trim_start_matches('{').trim_end_matches('}').to_string(), String::new(), String::new()),
        "opt" => (ty.trim_end_matches('?').to_string(), String::new(), String::new()),
        "map" => {
            let (k, v) = map_parts(ty);
            (String::new(), k, v)
        }
        _ => (String::new(), String::new(), String::new()),
    };
    let fill = |s: &str| -> String {
        let mut out = String::new();
        let cs: Vec<char> = s.chars().collect();
        for (i, c) in cs.iter().enumerate() {
            let alone = |j: Option<&char>| j.is_none_or(|c| !c.is_ascii_alphanumeric());
            let standalone = alone(i.checked_sub(1).map(|j| &cs[j])) && alone(cs.get(i + 1));
            match c {
                'T' if standalone && !t.is_empty() => out += &t,
                'K' if standalone && !k.is_empty() => out += &k,
                'V' if standalone && !v.is_empty() => out += &v,
                c => out.push(*c),
            }
        }
        out
    };
    (fill(params), fill(ret))
}

pub(super) fn builtin_methods_for(ty: &str) -> Vec<(&'static str, String, String, &'static str)> {
    let Some(g) = group_of(ty) else { return vec![] };
    BUILTIN_METHODS
        .iter()
        .filter(|m| m.0 == g)
        .map(|m| {
            let (p, r) = builtin_sig(ty, g, m.2, m.3);
            (m.1, p, r, m.4)
        })
        .collect()
}

/// Edit distance, for "did you mean".
fn distance(a: &str, b: &str) -> usize {
    let (a, b): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
    let mut row: Vec<usize> = (0..=b.len()).collect();
    for i in 1..=a.len() {
        let mut prev = row[0];
        row[0] = i;
        for j in 1..=b.len() {
            let cur = row[j];
            row[j] = (row[j] + 1).min(row[j - 1] + 1).min(prev + usize::from(a[i - 1] != b[j - 1]));
            prev = cur;
        }
    }
    row[b.len()]
}

/// Is the end of `before` (one line) inside a string (not in `${...}`) or a comment?
fn in_string_or_comment(before: &str) -> bool {
    let cs: Vec<char> = before.chars().collect();
    let (mut in_str, mut interp) = (false, 0);
    let mut i = 0;
    while i < cs.len() {
        let c = cs[i];
        if in_str && interp == 0 {
            match c {
                '\\' => i += 1,
                '"' => in_str = false,
                '$' if cs.get(i + 1) == Some(&'{') => {
                    interp = 1;
                    i += 1;
                }
                _ => {}
            }
        } else {
            match c {
                '/' if cs.get(i + 1) == Some(&'/') => return true,
                '"' if interp == 0 => in_str = true,
                '"' => {} // a string inside `${...}`: rare, ignore
                '{' if interp > 0 => interp += 1,
                '}' if interp > 0 => interp -= 1,
                _ => {}
            }
        }
        i += 1;
    }
    in_str && interp == 0
}

/// Where the cursor is, as far as the tokens before it tell.
#[derive(Debug, PartialEq)]
enum Ctx {
    Import,
    Type,
    Member { dot: Pos, recv: Vec<Tok>, recv_start: Pos },
    Shorthand { dot: Pos },
    StructField { path: Vec<String>, used: Vec<String> },
    MatchArm { subject: Pos },
    Tag,                                    // `<|`: an element or component name
    CloseTag(String),                       // `</|`
    Attr { tag: String, used: Vec<String> }, // `<div |` / `<Card title="x" |`
    Plain,
}

/// Can a `<` after this token start a JSX tag (rather than compare)?
fn tag_can_start(prev: Option<&Tok>) -> bool {
    !matches!(prev, Some(Tok::Ident(_) | Tok::RParen | Tok::RBrack | Tok::Int(_) | Tok::Float(_)))
}

/// Is the cursor in JSX: after `<`, after `</`, or among a tag's attributes?
fn jsx_context(toks: &[&Token]) -> Option<Ctx> {
    let n = toks.len();
    let tok = |i: usize| &toks[i].tok;
    let last = n.checked_sub(1).map(tok)?;
    if *last == Tok::Lt && tag_can_start(n.checked_sub(2).map(tok)) {
        return Some(Ctx::Tag);
    }
    if *last == Tok::Slash && n >= 2 && *tok(n - 2) == Tok::Lt {
        // the innermost tag still open
        let mut open: Vec<String> = vec![];
        let mut i = 0;
        while i + 1 < n - 2 {
            if *tok(i) == Tok::Lt && tag_can_start(i.checked_sub(1).map(tok)) {
                let closing = *tok(i + 1) == Tok::Slash;
                let at = i + 1 + closing as usize;
                if let Some(Tok::Ident(name)) = toks.get(at).map(|t| &t.tok) {
                    let mut name = name.clone();
                    let mut j = at + 1;
                    while j + 1 < n && matches!(tok(j), Tok::Dot | Tok::Minus) && toks[j - 1].end == toks[j].start {
                        if let Tok::Ident(x) = tok(j + 1) {
                            name.push(if *tok(j) == Tok::Dot { '.' } else { '-' });
                            name += x;
                        }
                        j += 2;
                    }
                    // a tag that closes itself (`/>`) never opens
                    let mut depth = 0;
                    let mut k = j;
                    let mut selfclose = false;
                    while k < n {
                        match tok(k) {
                            Tok::LBrace => depth += 1,
                            Tok::RBrace => depth -= 1,
                            Tok::Slash if depth == 0 && toks.get(k + 1).is_some_and(|t| t.tok == Tok::Gt) => {
                                selfclose = true;
                                break;
                            }
                            Tok::Gt if depth == 0 => break,
                            _ => {}
                        }
                        k += 1;
                    }
                    if closing {
                        if let Some(p) = open.iter().rposition(|o| *o == name) {
                            open.truncate(p);
                        }
                    } else if !selfclose {
                        open.push(name);
                    }
                    i = k;
                }
            }
            i += 1;
        }
        return Some(Ctx::CloseTag(open.pop().unwrap_or_default()));
    }
    // among the attributes of an unfinished tag head?
    let mut depth = 0;
    let mut used = vec![];
    let mut i = n;
    while i > 0 {
        i -= 1;
        match tok(i) {
            Tok::RBrace => depth += 1,
            Tok::LBrace if depth > 0 => depth -= 1,
            Tok::LBrace => return None, // inside an attribute's {value}
            _ if depth > 0 => {}
            Tok::Gt => return None,
            Tok::Ident(a) if *tok(i.saturating_sub(1)) != Tok::Lt => used.push(a.clone()),
            Tok::Ident(_) | Tok::Dot | Tok::Minus | Tok::Newline | Tok::Assign | Tok::Str(_) | Tok::Interp(_) => {}
            Tok::Lt if tag_can_start(i.checked_sub(1).map(tok)) => {
                let Some(Tok::Ident(first)) = toks.get(i + 1).map(|t| &t.tok) else { return None };
                let mut name = first.clone();
                let mut j = i + 2;
                while j + 1 < n && matches!(tok(j), Tok::Dot | Tok::Minus) && toks[j - 1].end == toks[j].start {
                    if let Tok::Ident(x) = tok(j + 1) {
                        name.push(if *tok(j) == Tok::Dot { '.' } else { '-' });
                        name += x;
                    }
                    j += 2;
                }
                if j > n || (j == n && toks[n - 1].end == toks[n - 1].start) {
                    return None;
                }
                used.retain(|u| !name.split(['.', '-']).any(|p| p == u));
                return (j <= n).then_some(Ctx::Attr { tag: name, used });
            }
            _ => return None,
        }
    }
    None
}

const HTML_TAGS: &[&str] = &[
    "div", "span", "p", "a", "button", "ul", "ol", "li", "h1", "h2", "h3", "h4", "section", "main", "header", "footer", "nav", "article",
    "aside", "form", "label", "select", "option", "textarea", "table", "thead", "tbody", "tr", "th", "td", "strong", "em", "b", "i",
    "code", "pre", "small", "img", "input", "br", "hr", "html", "head", "body", "title", "meta", "link", "script", "style",
];
const VOID_TAGS: &[&str] = &["input", "br", "hr", "img", "meta", "link"];
const HTML_ATTRS: &[(&str, &str)] = &[
    ("class", "CSS classes"), ("id", "element id"), ("style", "inline CSS"), ("key", "identity in a list (keeps the element when the list changes)"),
    ("href", "link target"), ("src", "source URL"), ("alt", "text instead of the image"), ("type", "input / button type"),
    ("value", "the field's value"), ("placeholder", "hint text"), ("name", "form field name"), ("title", "tooltip"),
    ("disabled", "bool"), ("checked", "bool"), ("autofocus", "bool"), ("for", "the input a label is for"), ("rows", "textarea rows"),
];
const EVENTS: &[(&str, &str, &str)] = &[
    ("onclick", "() => $0", "fn()"), ("oninput", "v => $0", "fn(str): the field's text"), ("onchange", "v => $0", "fn(str): the new value (\"true\"/\"false\" for a checkbox)"),
    ("onsubmit", "form => $0", "fn(str): the fields as a=1&b=2"), ("onkeydown", "key => $0", "fn(str): the key"), ("onkeyup", "key => $0", "fn(str): the key"),
    ("onfocus", "() => $0", "fn()"), ("onblur", "() => $0", "fn()"), ("ondblclick", "() => $0", "fn()"),
];

fn context(toks: &[Token], word_start: Pos) -> Ctx {
    let toks: Vec<&Token> = toks.iter().filter(|t| t.tok != Tok::Eof && (t.pos.line, t.pos.col) < (word_start.line, word_start.col)).collect();
    let last = toks.last().map(|t| &t.tok);
    let on_line = |t: &&&Token| t.pos.line == word_start.line;
    // `import x`
    if toks.iter().rev().take_while(on_line).count() == 1 && last == Some(&Tok::Import) {
        return Ctx::Import;
    }
    if let Some(c) = jsx_context(&toks) {
        return c;
    }
    // the bracket the cursor is in
    let mut stack: Vec<usize> = vec![];
    for (i, t) in toks.iter().enumerate() {
        match t.tok {
            Tok::LParen | Tok::LBrace | Tok::LBrack => stack.push(i),
            Tok::RParen | Tok::RBrace | Tok::RBrack => {
                stack.pop();
            }
            _ => {}
        }
    }
    let open = stack.last().copied();
    let before_open = |n: usize| open.and_then(|o| o.checked_sub(n)).map(|i| &toks[i].tok);
    // the statement the open bracket belongs to starts after the last newline/brace before it
    let stmt_head = |o: usize| -> Vec<&Tok> {
        let mut i = o;
        let mut depth = 0;
        while i > 0 {
            match toks[i - 1].tok {
                Tok::RParen | Tok::RBrack | Tok::RBrace => depth += 1,
                Tok::LParen | Tok::LBrack if depth > 0 => depth -= 1,
                Tok::LBrace if depth > 0 => depth -= 1,
                Tok::Newline | Tok::LBrace | Tok::Semi if depth == 0 => break,
                _ => {}
            }
            i -= 1;
        }
        toks[i..o].iter().map(|t| &t.tok).collect()
    };

    if last == Some(&Tok::Dot) {
        let dot = toks[toks.len() - 1].pos;
        let n = toks.len() - 1;
        let prev = n.checked_sub(1).map(|i| &toks[i]);
        let attached = prev.is_some_and(|p| p.pos.line == dot.line && p.end == dot_offset(p, toks[n]))
            && matches!(prev.map(|p| &p.tok), Some(Tok::Ident(_) | Tok::RParen | Tok::RBrack | Tok::Question | Tok::Str(_) | Tok::Interp(_) | Tok::Int(_) | Tok::Float(_)));
        if !attached {
            return Ctx::Shorthand { dot };
        }
        // the receiver: a chain of names, calls and indexing back from the dot
        let mut i = n;
        let mut depth = 0;
        while i > 0 {
            let t = &toks[i - 1].tok;
            match t {
                Tok::RParen | Tok::RBrack => depth += 1,
                Tok::LParen | Tok::LBrack if depth > 0 => depth -= 1,
                _ if depth > 0 => {}
                Tok::Ident(_) | Tok::Dot | Tok::Question | Tok::Str(_) | Tok::Interp(_) | Tok::Int(_) | Tok::Float(_) => {}
                _ => break,
            }
            if depth == 0 && matches!(t, Tok::LParen | Tok::LBrack) {
                break;
            }
            i -= 1;
        }
        let recv = toks[i..n].iter().map(|t| t.tok.clone()).collect();
        return Ctx::Member { dot, recv, recv_start: toks.get(i).map_or(dot, |t| t.pos) };
    }
    if last == Some(&Tok::Arrow) {
        return Ctx::Type;
    }
    if last == Some(&Tok::Colon) {
        let n = toks.len();
        let name_before_let = n >= 3 && matches!(toks[n - 3].tok, Tok::Let | Tok::Var | Tok::Const);
        let in_decl_body = open.is_some_and(|o| {
            let h = stmt_head(o);
            matches!(h.first(), Some(Tok::Struct | Tok::Enum))
        });
        let in_params = open.is_some_and(|o| toks[o].tok == Tok::LParen) && {
            let h = stmt_head(open.unwrap());
            // `fn name(` or a lambda `(` that isn't a call
            matches!(before_open(1), Some(Tok::Ident(_))) && matches!(before_open(2), Some(Tok::Fn))
                || !matches!(before_open(1), Some(Tok::Ident(_) | Tok::RParen | Tok::RBrack))
                || h.first() == Some(&&Tok::Extern)
        };
        let in_variant = open.is_some_and(|o| toks[o].tok == Tok::LParen) && {
            let mut i = open.unwrap();
            let mut inside_enum = false;
            // walk out to the enclosing `{` and see if it opened an enum
            let mut depth = 0;
            while i > 0 {
                i -= 1;
                match toks[i].tok {
                    Tok::RBrace => depth += 1,
                    Tok::LBrace if depth > 0 => depth -= 1,
                    Tok::LBrace => {
                        inside_enum = i >= 2 && toks[i - 2].tok == Tok::Enum;
                        break;
                    }
                    _ => {}
                }
            }
            inside_enum
        };
        if name_before_let || in_decl_body || in_params || in_variant {
            return Ctx::Type;
        }
    }
    // `Name {` ... a struct literal: offer the fields not written yet
    if let Some(o) = open.filter(|o| toks[*o].tok == Tok::LBrace) {
        if matches!(last, Some(Tok::LBrace | Tok::Comma | Tok::Newline)) {
            let h = stmt_head(o);
            let is_decl = matches!(h.first(), Some(Tok::Struct | Tok::Enum | Tok::Fn | Tok::Impl));
            // the path right before `{`: `Todo`, `.Done`, `Status.Done`, `http.Request`
            let mut path = vec![];
            let mut i = o;
            while i > 0 {
                match &toks[i - 1].tok {
                    Tok::Ident(n) => path.insert(0, n.clone()),
                    Tok::Dot => path.insert(0, String::new()),
                    _ => break,
                }
                i -= 1;
            }
            let typed = path.last().is_some_and(|n| n.starts_with(|c: char| c.is_ascii_uppercase()));
            if !is_decl && typed && !h.contains(&&Tok::Match) {
                let mut used = vec![];
                let mut depth = 0;
                for (j, t) in toks.iter().enumerate().skip(o + 1) {
                    match t.tok {
                        Tok::LParen | Tok::LBrace | Tok::LBrack => depth += 1,
                        Tok::RParen | Tok::RBrace | Tok::RBrack => depth -= 1,
                        Tok::Ident(ref n) if depth == 0 && matches!(toks.get(j + 1).map(|t| &t.tok), Some(Tok::Colon | Tok::Comma) | None) && matches!(toks[j - 1].tok, Tok::LBrace | Tok::Comma | Tok::Newline) => used.push(n.clone()),
                        _ => {}
                    }
                }
                return Ctx::StructField { path, used };
            }
            // the arms of a `match`
            if h.first() == Some(&&Tok::Match) || h.contains(&&Tok::Match) {
                let m = (0..o).rev().find(|i| toks[*i].tok == Tok::Match);
                if let Some(m) = m.filter(|m| m + 1 < o) {
                    return Ctx::MatchArm { subject: toks[m + 1].pos };
                }
            }
        }
    }
    Ctx::Plain
}

/// Char offset where `next` starts, to tell `x.` from `x .`.
fn dot_offset(_prev: &Token, next: &Token) -> usize {
    next.start
}

impl Server {
    pub(super) fn completion(&self, path: &str, (line, ch): (u32, u32)) -> Json {
        let Some(text) = self.docs.get(path) else { return Json::Null };
        let l = text.lines().nth(line as usize).unwrap_or("");
        let col = char_col(l, ch); // 1-based column of the cursor
        let before: String = l.chars().take(col as usize - 1).collect();
        let after: String = l.chars().skip(col as usize - 1).collect();
        if in_string_or_comment(&before) {
            return Json::Arr(vec![]);
        }
        let prefix: String = before.chars().rev().take_while(|c| c.is_ascii_alphanumeric() || *c == '_').collect::<Vec<_>>().into_iter().rev().collect();
        let word_start = Pos { line: line + 1, col: col - prefix.chars().count() as u32 };
        let parens_follow = after.trim_start().starts_with('(');

        // the tokens before the cursor tell the context
        let upto: String = {
            let mut s: String = text.lines().take(line as usize).map(|l| format!("{l}\n")).collect();
            s += &before[..before.len() - prefix.len()];
            s
        };
        let toks = lexer::lex(&upto).map(|t| flatten(&t)).unwrap_or_default();
        let ctx = context(&toks, word_start);

        // check the file with a placeholder where the word is being typed
        let hole = match ctx {
            Ctx::MatchArm { .. } => format!("{HOLE} => {{}}"),
            _ => HOLE.to_string(),
        };
        let patched: String = text
            .lines()
            .enumerate()
            .map(|(i, x)| {
                if i == line as usize {
                    let head: String = x.chars().take(word_start.col as usize - 1).collect();
                    let tail: String = x.chars().skip(col as usize - 1).skip_while(|c| c.is_ascii_alphanumeric() || *c == '_').collect();
                    format!("{head}{hole}{tail}\n")
                } else {
                    format!("{x}\n")
                }
            })
            .collect();
        let a = self.analyze_file(path, &patched);
        let fresh = !a.units.is_empty();
        let (decls, model) = if fresh {
            (self.decls(&a.units), Model::of(&a.units))
        } else if let Some(c) = self.cache.get(path) {
            (c.decls.clone(), c.model.clone())
        } else {
            (vec![], Model::default())
        };
        let mut notes: Vec<Note> = a.notes.clone();
        if let Some(c) = self.cache.get(path) {
            notes.extend(c.notes.iter().cloned()); // older notes, for names the new check didn't reach
        }
        let probe = |kind: &str, p: Pos| a.probes.iter().rev().find(|n| n.file == path && n.pos == p && n.text.starts_with(kind)).map(|n| n.text[kind.len()..].trim().to_string());
        let imported: Vec<String> = if fresh { a.units.iter().map(|u| u.name.clone()).collect() } else { self.cache.get(path).map(|c| c.modules.clone()).unwrap_or_default() };

        let mut items: Vec<Item> = vec![];
        match &ctx {
            Ctx::Import => {
                for (name, src) in STD {
                    let doc = src.lines().take_while(|l| l.starts_with("//")).map(|l| l.trim_start_matches("//").trim()).collect::<Vec<_>>().join("\n");
                    let mut it = item(*name, K_MODULE, "standard library", 0);
                    it.doc = doc;
                    items.push(it);
                }
                if let Some(dir) = Path::new(path).parent() {
                    for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
                        let p = e.path();
                        if p.extension().is_some_and(|x| x == "st") && p.display().to_string() != path {
                            let stem = p.file_stem().unwrap().to_string_lossy().into_owned();
                            items.push(item(stem, K_MODULE, format!("{}", p.file_name().unwrap().to_string_lossy()), 1));
                        }
                    }
                }
            }
            Ctx::Type => {
                for t in ["int", "float", "bool", "str", "void"] {
                    items.push(item(t, K_KEYWORD, "builtin type", 1));
                }
                for d in decls.iter().filter(|d| matches!(d.kind, "struct" | "enum")) {
                    let name = if d.module.is_empty() { d.name.clone() } else { format!("{}.{}", d.module, d.name) };
                    if !d.module.is_empty() && !imported.contains(&d.module) {
                        continue;
                    }
                    let mut it = item(name, decl_kind(d.kind), d.kind, if d.module.is_empty() { 0 } else { 2 });
                    it.doc = format!("```stellang\n{}\n```\n{}", d.sig, d.doc);
                    items.push(it);
                }
                let mut it = item("fn()", K_SNIPPET, "function type", 3);
                it.snippet = Some("fn(${1:int}) -> ${0:int}".into());
                items.push(it);
                for (label, snip, detail) in [("[T]", "[${0:int}]", "list"), ("{K: V}", "{${1:str}: ${0:int}}", "map"), ("{T}", "{${0:str}}", "set")] {
                    let mut it = item(label, K_SNIPPET, detail, 3);
                    it.snippet = Some(snip.into());
                    items.push(it);
                }
            }
            Ctx::Member { dot, recv, recv_start } => {
                let simple = match recv.as_slice() {
                    [Tok::Ident(n)] => Some(n.clone()),
                    _ => None,
                };
                let module_type = match recv.as_slice() {
                    [Tok::Ident(m), Tok::Dot, Tok::Ident(t)] => Some((m.clone(), t.clone())),
                    _ => None,
                };
                let is_local = simple.as_ref().is_some_and(|n| self.local_binding(&toks, toks.len().saturating_sub(1), n).is_some());
                if let Some(m) = simple.as_ref().filter(|m| !is_local && (imported.contains(m) || STD.iter().any(|s| s.0 == m.as_str()))) {
                    // a module: its functions, types and constants (importing it if needed)
                    let (mdecls, extra) = if imported.contains(m) {
                        (decls.clone(), vec![])
                    } else {
                        (self.std_decls(m), vec![self.import_edit(text, m)])
                    };
                    for d in mdecls.iter().filter(|d| d.module == *m && d.owner.is_none() && !d.name.starts_with("st_")) {
                        let mut it = self.decl_item(d, parens_follow, if d.kind == "fn" { 0 } else { 1 });
                        it.extra = extra.clone();
                        items.push(it);
                    }
                } else if let Some((owner, module)) = simple
                    .as_ref()
                    .filter(|n| !is_local && n.starts_with(|c: char| c.is_ascii_uppercase()))
                    .map(|n| (n.clone(), String::new()))
                    .or(module_type.clone())
                    .filter(|(t, m)| decls.iter().any(|d| d.name == *t && d.module == *m && matches!(d.kind, "struct" | "enum")))
                {
                    // a type: its variants and static functions
                    for d in decls.iter().filter(|d| d.owner.as_deref() == Some(owner.as_str()) && d.module == module && matches!(d.kind, "variant" | "fn")) {
                        let mut it = self.decl_item(d, parens_follow, 0);
                        if d.kind == "variant" {
                            if let Some(s) = model.variant_snippet(&module, &owner, &d.name, false) {
                                it.snippet = Some(s);
                            }
                        }
                        items.push(it);
                    }
                } else {
                    // a value: ask the type checker what it is
                    let ty = probe("@recv", *dot).or_else(|| {
                        let n = simple.as_ref()?;
                        notes.iter().rev().find_map(|x| {
                            let t = x.text.trim_start_matches("let ").trim_start_matches("var ");
                            t.strip_prefix(&format!("{n}: ")).map(str::to_string)
                        })
                    });
                    let recv_text: String = {
                        let rl = text.lines().nth(recv_start.line as usize - 1).unwrap_or("");
                        if recv_start.line == dot.line {
                            rl.chars().skip(recv_start.col as usize - 1).take((dot.col - recv_start.col) as usize).collect()
                        } else {
                            String::new()
                        }
                    };
                    match ty {
                        Some(ty) => {
                            self.members_of(&ty, &decls, parens_follow, &mut items, *dot, text);
                            self.postfix(&ty, &recv_text, *recv_start, &model, &mut items);
                        }
                        None => {
                            // unknown: every field and method we know of
                            for d in decls.iter().filter(|d| matches!(d.kind, "method" | "field")) {
                                items.push(self.decl_item(d, parens_follow, 3));
                            }
                            for m in BUILTIN_METHODS {
                                let mut it = item(m.1, K_METHOD, format!("{} method", m.0), 4);
                                it.snippet = Some(call_snippet(m.1, &split_top(m.2), parens_follow));
                                it.doc = m.4.into();
                                items.push(it);
                            }
                            if !recv_text.is_empty() {
                                self.postfix("", &recv_text, *recv_start, &model, &mut items);
                            }
                        }
                    }
                }
            }
            Ctx::Shorthand { dot } => {
                // `.Variant` where the type is known from context
                let want = probe("@want", *dot);
                let key = want.as_deref().map(|w| w.trim_end_matches(['?', '!']).to_string());
                let mut found = false;
                if let Some(k) = key {
                    let (module, name) = k.rsplit_once('.').map_or((String::new(), k.clone()), |(m, n)| (m.to_string(), n.to_string()));
                    for d in decls.iter().filter(|d| d.owner.as_deref() == Some(name.as_str()) && d.module == module && matches!(d.kind, "variant" | "fn")) {
                        found = true;
                        let mut it = self.decl_item(d, parens_follow, 0);
                        if d.kind == "variant" {
                            it.snippet = model.variant_snippet(&module, &name, &d.name, false);
                        }
                        items.push(it);
                    }
                }
                if !found {
                    for d in decls.iter().filter(|d| d.kind == "variant" && (d.module.is_empty() || imported.contains(&d.module))) {
                        let mut it = self.decl_item(d, parens_follow, 1);
                        it.snippet = model.variant_snippet(&d.module, d.owner.as_deref().unwrap_or(""), &d.name, false);
                        items.push(it);
                    }
                }
            }
            Ctx::StructField { path: tp, used } => {
                let (module, name, variant) = match tp.as_slice() {
                    [m, t] if !m.is_empty() && imported.contains(m) => (m.clone(), t.clone(), None),
                    [t] => (String::new(), t.clone(), None),
                    [e, v] if !e.is_empty() => (String::new(), e.clone(), Some(v.clone())),
                    [_, v] => (String::new(), String::new(), Some(v.clone())),
                    [m, e, v] => (m.clone(), e.clone(), Some(v.clone())),
                    _ => (String::new(), String::new(), None),
                };
                let fields = match &variant {
                    None => model.struct_fields(&module, &name),
                    Some(v) => model.variant_fields(&module, &name, v),
                };
                let mut n = 0;
                for (f, ty, optional) in fields.iter().filter(|f| !used.contains(&f.0)) {
                    n += 1;
                    let mut it = item(f.clone(), K_FIELD, ty.clone(), if *optional { 1 } else { 0 });
                    it.snippet = Some(format!("{f}: ${{1}}"));
                    it.label_desc = Some(if *optional { format!("{ty} (optional)") } else { ty.clone() });
                    items.push(it);
                }
                let required: Vec<&(String, String, bool)> = fields.iter().filter(|f| !f.2 && !used.contains(&f.0)).collect();
                if required.len() > 1 {
                    let mut it = item("all required fields", K_SNIPPET, "fill in the struct", 0);
                    let parts: Vec<String> = required.iter().enumerate().map(|(i, f)| format!("{}: ${{{}}}", f.0, i + 1)).collect();
                    it.snippet = Some(parts.join(", "));
                    it.filter = Some(prefix.clone());
                    items.push(it);
                }
                if n == 0 {
                    self.plain_items(path, &decls, &model, &notes, &imported, text, word_start, parens_follow, &mut items);
                } else {
                    // values too, for shorthand fields (`Todo { title }`)
                    let mut ls = vec![];
                    self.locals(path, &notes, &model, word_start, &mut ls);
                    items.extend(ls.into_iter().map(|mut i| {
                        i.sort = 2;
                        i
                    }));
                }
            }
            Ctx::MatchArm { subject } => {
                // the subject's position is where its expression's operator is: anywhere after `match` on that line
                let ty = a.probes.iter().find(|n| n.file == path && n.pos.line == subject.line && n.pos.col >= subject.col && n.text.starts_with("@match")).map(|n| n.text["@match".len()..].trim().to_string());
                if let Some(ty) = ty {
                    for (pat, detail) in model.patterns(&ty) {
                        let mut it = item(pat.replace("${1:", "").replace("${2:", "").replace('}', "").replace('$', ""), K_ENUM_MEMBER, detail, 0);
                        it.label = clean_snippet(&pat);
                        it.snippet = Some(format!("{pat} => $0"));
                        items.push(it);
                    }
                    let all = model.arms(&ty, "");
                    if !all.is_empty() {
                        let mut it = item("all cases", K_SNIPPET, format!("one arm for every case of {ty}"), 0);
                        it.snippet = Some(all);
                        it.filter = Some(prefix.clone());
                        items.push(it);
                    }
                }
                let mut it = item("_", K_KEYWORD, "anything else", 2);
                it.snippet = Some("_ => $0".into());
                items.push(it);
            }
            Ctx::Tag => {
                for d in decls.iter().filter(|d| d.kind == "fn" && d.name.starts_with(|c: char| c.is_ascii_uppercase()) && params_of(&d.sig).1 == "Node" && (d.module.is_empty() || imported.contains(&d.module))) {
                    let name = if d.module.is_empty() { d.name.clone() } else { format!("{}.{}", d.module, d.name) };
                    let props = component_props(d, &model);
                    let mut k = 0;
                    let required: Vec<String> = props.iter().filter(|p| !p.2 && p.0 != "children").map(|p| {
                        k += 1;
                        if p.1 == "str" { format!("{}=\"${{{k}}}\"", p.0) } else { format!("{}={{${{{k}}}}}", p.0) }
                    }).collect();
                    let head = if required.is_empty() { name.clone() } else { format!("{name} {}", required.join(" ")) };
                    let mut it = item(name.clone(), K_STRUCT, "component", if d.module.is_empty() { 0 } else { 1 });
                    it.snippet = Some(if props.iter().any(|p| p.0 == "children") { format!("{head}>$0</{name}>") } else { format!("{head} />") });
                    it.label_desc = Some("component".into());
                    it.doc = format!("```stellang\n{}\n```\n{}", d.sig.trim_end_matches('{').trim(), d.doc);
                    items.push(it);
                }
                for t in HTML_TAGS {
                    let mut it = item(*t, K_KEYWORD, "HTML element", 2);
                    it.snippet = Some(if VOID_TAGS.contains(t) { format!("{t} $0/>") } else { format!("{t}>$0</{t}>") });
                    items.push(it);
                }
                let mut it = item("<>", K_SNIPPET, "fragment: several elements as one", 3);
                it.snippet = Some(">$0</>".into());
                it.filter = Some(prefix.clone());
                items.push(it);
            }
            Ctx::CloseTag(name) => {
                if !name.is_empty() {
                    let mut it = item(name.clone(), K_KEYWORD, "close the tag", 0);
                    it.snippet = Some(format!("{name}>"));
                    items.push(it);
                }
            }
            Ctx::Attr { tag, used } => {
                let comp = tag.rsplit('.').next().is_some_and(|t| t.starts_with(|c: char| c.is_ascii_uppercase()));
                if comp {
                    let (module, name) = tag.rsplit_once('.').map_or((String::new(), tag.clone()), |(m, n)| (m.to_string(), n.to_string()));
                    if let Some(d) = decls.iter().find(|d| d.kind == "fn" && d.name == name && d.module == module) {
                        for (p, ty, optional) in component_props(d, &model).into_iter().filter(|p| !used.contains(&p.0) && p.0 != "children") {
                            let mut it = item(p.clone(), K_FIELD, ty.clone(), if optional { 1 } else { 0 });
                            it.snippet = Some(if ty == "str" { format!("{p}=\"$1\"") } else if ty.starts_with("fn(") { format!("{p}={{() => $1}}") } else { format!("{p}={{$1}}") });
                            it.label_desc = Some(if optional { format!("{ty} (optional)") } else { ty });
                            items.push(it);
                        }
                    }
                } else {
                    for (a, doc) in HTML_ATTRS.iter().filter(|a| !used.iter().any(|u| u == a.0)) {
                        let mut it = item(*a, K_FIELD, *doc, 0);
                        it.snippet = Some(if matches!(*a, "disabled" | "checked" | "autofocus") { format!("{a}={{$1}}") } else { format!("{a}=\"$1\"") });
                        items.push(it);
                    }
                    for (e, snip, doc) in EVENTS.iter().filter(|e| !used.iter().any(|u| u == e.0)) {
                        let mut it = item(*e, K_METHOD, *doc, 1);
                        it.snippet = Some(format!("{e}={{{snip}}}"));
                        it.label_desc = Some("event".into());
                        items.push(it);
                    }
                }
            }
            Ctx::Plain => self.plain_items(path, &decls, &model, &notes, &imported, text, word_start, parens_follow, &mut items),
        }

        let mut seen = HashSet::new();
        items.retain(|i| seen.insert((i.label.clone(), i.kind)));
        let replace = |from: Pos| range(text, from, Pos { line: line + 1, col });
        Json::Arr(
            items
                .into_iter()
                .map(|it| {
                    let mut fs: Vec<(String, Json)> = vec![
                        ("label".into(), it.label.as_str().into()),
                        ("kind".into(), it.kind.into()),
                        ("detail".into(), it.detail.as_str().into()),
                        ("sortText".into(), format!("{}{}", it.sort, it.label).into()),
                    ];
                    if !it.doc.is_empty() {
                        fs.push(("documentation".into(), obj([("kind", "markdown".into()), ("value", it.doc.as_str().into())])));
                    }
                    if it.label_detail.is_some() || it.label_desc.is_some() {
                        let mut ld = vec![];
                        if let Some(d) = &it.label_detail {
                            ld.push(("detail".to_string(), Json::from(d.as_str())));
                        }
                        if let Some(d) = &it.label_desc {
                            ld.push(("description".to_string(), Json::from(d.as_str())));
                        }
                        fs.push(("labelDetails".into(), Json::Obj(ld)));
                    }
                    let new_text = it.snippet.clone().unwrap_or_else(|| it.label.clone());
                    if it.snippet.is_some() {
                        fs.push(("insertTextFormat".into(), 2u32.into()));
                    }
                    // a postfix completion replaces the word and deletes `recv.` with a separate edit,
                    // so the editor filters and ranks it by its own name, after the real members
                    let mut extra = it.extra.clone();
                    let new_text = match &it.edit {
                        Some((from, snippet)) => {
                            extra.push(obj([("range", range(text, *from, word_start)), ("newText", "".into())]));
                            snippet.clone()
                        }
                        None => new_text,
                    };
                    fs.push(("textEdit".into(), obj([("range", replace(word_start)), ("newText", new_text.into())])));
                    if let Some(f) = &it.filter {
                        fs.push(("filterText".into(), f.as_str().into()));
                    }
                    if !extra.is_empty() {
                        fs.push(("additionalTextEdits".into(), Json::Arr(extra)));
                    }
                    if it.sig_help {
                        fs.push(("command".into(), obj([("title", "parameters".into()), ("command", "editor.action.triggerParameterHints".into())])));
                    }
                    if it.deprecated {
                        fs.push(("tags".into(), Json::Arr(vec![1u32.into()])));
                    }
                    Json::Obj(fs)
                })
                .collect(),
        )
    }

    fn decl_item(&self, d: &Decl, parens_follow: bool, sort: u8) -> Item {
        let mut it = item(d.name.clone(), decl_kind(d.kind), d.sig.lines().next().unwrap_or(""), sort);
        it.doc = if d.doc.is_empty() { format!("```stellang\n{}\n```", d.sig) } else { format!("```stellang\n{}\n```\n\n{}", d.sig, d.doc) };
        match d.kind {
            "fn" | "method" => {
                let (ps, ret) = params_of(&d.sig);
                it.snippet = Some(call_snippet(&d.name, &ps, parens_follow));
                it.sig_help = !ps.is_empty() && !parens_follow;
                it.label_detail = Some(format!("({})", ps.join(", ")));
                it.label_desc = Some(if ret.is_empty() { "void".into() } else { ret });
            }
            "field" => {
                it.label_desc = d.sig.split_once(": ").map(|(_, t)| t.to_string());
            }
            "variant" => {
                it.label_desc = d.owner.clone();
            }
            "struct" | "enum" => {
                it.label_desc = Some(if d.module.is_empty() { d.kind.to_string() } else { format!("{} {}", d.module, d.kind) });
            }
            "const" => {
                it.label_desc = d.sig.split_once('=').map(|(_, v)| v.trim().to_string());
            }
            _ => {}
        }
        it
    }

    /// Fields and methods of a value of type `ty`.
    fn members_of(&self, ty: &str, decls: &[Decl], parens_follow: bool, items: &mut Vec<Item>, dot: Pos, text: &str) {
        let base = ty.trim_end_matches(['?', '!']);
        let (module, name) = base.rsplit_once('.').map_or((String::new(), base.to_string()), |(m, n)| (m.to_string(), n.to_string()));
        let own: Vec<&Decl> = decls.iter().filter(|d| d.owner.as_deref() == Some(name.as_str()) && d.module == module && matches!(d.kind, "method" | "field")).collect();
        let wrapped = ty.ends_with(['?', '!']);
        for d in &own {
            let mut it = self.decl_item(d, parens_follow, if d.kind == "field" { 0 } else { 1 });
            if wrapped {
                // `x?.field`: reach through the optional or result
                it.extra = vec![obj([("range", range(text, dot, Pos { line: dot.line, col: dot.col + 1 })), ("newText", "?.".into())])];
                it.detail = format!("{} (through ?.)", it.detail);
                it.sort = 3;
            }
            items.push(it);
        }
        for (name, params, ret, doc) in builtin_methods_for(ty) {
            let mut it = item(name, K_METHOD, format!("fn {name}({params}) -> {ret}"), 2);
            let ps = split_top(&params).into_iter().map(|p| p.trim().to_string()).filter(|p| !p.is_empty()).collect::<Vec<_>>();
            it.snippet = Some(call_snippet(name, &ps, parens_follow));
            it.sig_help = !ps.is_empty() && !parens_follow;
            it.label_detail = Some(format!("({params})"));
            it.label_desc = Some(ret.clone());
            it.doc = format!("```stellang\nfn {name}({params}) -> {ret}\n```\n\n{doc}");
            items.push(it);
        }
    }

    /// `x.match`, `x.if`, `x.for`, ... (rewrite the expression before the dot).
    fn postfix(&self, ty: &str, recv: &str, start: Pos, model: &Model, items: &mut Vec<Item>) {
        if recv.is_empty() {
            return;
        }
        let mut add = |label: &str, snippet: String, detail: &str| {
            let mut it = item(label, K_SNIPPET, detail, 5);
            it.edit = Some((start, snippet));
            it.doc = format!("```stellang\n{}\n```", clean_snippet(&it.edit.as_ref().unwrap().1));
            items.push(it);
        };
        let arms = model.arms(ty, "\t");
        if !arms.is_empty() {
            add("match", format!("match {recv} {{\n{arms}\n}}"), "match on every case");
        } else {
            add("match", format!("match {recv} {{\n\t${{1:pattern}} => ${{2:value}},\n\t_ => $0,\n}}"), "match");
        }
        add("let", format!("let ${{1:name}} = {recv}"), "bind to a name");
        add("var", format!("var ${{1:name}} = {recv}"), "bind to a mutable name");
        add("println", format!("println({recv})$0"), "print it");
        add("str", format!("str({recv})$0"), "as text");
        add("return", format!("return {recv}"), "return it");
        if ty == "bool" || ty.is_empty() {
            add("if", format!("if {recv} {{\n\t$0\n}}"), "if it is true");
            add("not", format!("!{recv}"), "negate");
            add("while", format!("while {recv} {{\n\t$0\n}}"), "loop while true");
        }
        if ty.starts_with('[') || ty.starts_with('{') || ty.is_empty() {
            add("for", format!("for ${{1:item}} in {recv} {{\n\t$0\n}}"), "loop over it");
        }
        if ty.ends_with('?') || ty.is_empty() {
            add("iflet", format!("if let some(${{1:value}}) = {recv} {{\n\t$0\n}}"), "if it has a value");
            add("else", format!("let ${{1:value}} = {recv} else {{\n\t${{0:return}}\n}}"), "unwrap or leave");
            add("or", format!("{recv} ?? ${{0:fallback}}"), "with a fallback");
        }
        if ty.ends_with('!') || ty.is_empty() {
            add("catch", format!("{recv} catch ${{1:e}} {{\n\t$0\n}}"), "handle the error");
            add("try", format!("{recv}?"), "pass the error up");
        }
        if ty.ends_with('?') || ty.ends_with('!') {
            add("try", format!("{recv}?"), "pass none / the error up");
        }
    }

    fn locals(&self, path: &str, notes: &[Note], model: &Model, cursor: Pos, items: &mut Vec<Item>) {
        // the function the cursor is in
        let f = model.funcs.iter().filter(|f| f.file == path && f.pos.line <= cursor.line).max_by_key(|f| f.pos.line);
        let from = f.map_or(1, |f| f.pos.line);
        if let Some(f) = f {
            for (n, t) in &f.params {
                let mut it = item(n.clone(), K_VARIABLE, t.clone(), 0);
                it.label_desc = Some(t.clone());
                items.push(it);
            }
        }
        for n in notes.iter().filter(|n| n.file == path && n.pos.line >= from && (n.pos.line, n.pos.col) < (cursor.line, cursor.col)) {
            let mutable = n.text.starts_with("var ");
            let t = n.text.trim_start_matches("let ").trim_start_matches("var ");
            if let Some((name, ty)) = t.split_once(": ") {
                if !name.contains(['.', ' ', '(']) && name != HOLE && !name.starts_with('?') {
                    let mut it = item(name, K_VARIABLE, if mutable { format!("var {ty}") } else { ty.to_string() }, 0);
                    it.label_desc = Some(ty.to_string());
                    items.push(it);
                }
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn plain_items(&self, path: &str, decls: &[Decl], model: &Model, notes: &[Note], imported: &[String], text: &str, cursor: Pos, parens_follow: bool, items: &mut Vec<Item>) {
        self.locals(path, notes, model, cursor, items);
        for d in decls.iter().filter(|d| d.module.is_empty() && d.owner.is_none()) {
            items.push(self.decl_item(d, parens_follow, 1));
            if d.kind == "struct" {
                // `Todo { id: $1, title: $2 }`
                let req: Vec<String> = model.struct_fields("", &d.name).into_iter().filter(|f| !f.2).map(|f| f.0).collect();
                let parts: Vec<String> = req.iter().enumerate().map(|(i, f)| format!("{f}: ${{{}}}", i + 1)).collect();
                let mut it = item(format!("{} {{…}}", d.name), K_SNIPPET, format!("new {}", d.name), 1);
                it.snippet = Some(if parts.is_empty() { format!("{} {{}}$0", d.name) } else { format!("{} {{ {} }}$0", d.name, parts.join(", ")) });
                it.filter = Some(d.name.clone());
                items.push(it);
            }
        }
        for d in decls.iter().filter(|d| d.kind == "variant" && d.module.is_empty()) {
            let owner = d.owner.clone().unwrap_or_default();
            let mut it = self.decl_item(d, parens_follow, 2);
            it.label = format!("{owner}.{}", d.name);
            it.snippet = model.variant_snippet("", &owner, &d.name, true);
            items.push(it);
        }
        for m in imported.iter().filter(|m| !m.is_empty()) {
            let mut it = item(m.clone(), K_MODULE, format!("module {m}"), 2);
            it.doc = format!("`import {m}`");
            items.push(it);
        }
        for (m, src) in STD.iter().filter(|(m, _)| !imported.iter().any(|i| i == m)) {
            let mut it = item(*m, K_MODULE, format!("import {m}"), 6);
            it.doc = src.lines().take_while(|l| l.starts_with("//")).map(|l| l.trim_start_matches("//").trim()).collect::<Vec<_>>().join("\n");
            it.extra = vec![self.import_edit(text, m)];
            it.label_desc = Some("auto-import".into());
            items.push(it);
        }
        for (name, params, ret, doc) in BUILTIN_FNS {
            let mut it = item(*name, K_FUNCTION, format!("fn {name}({params}) -> {ret}"), 3);
            let ps: Vec<String> = split_top(params).into_iter().map(|p| p.trim().to_string()).collect();
            it.snippet = Some(call_snippet(name, &ps, parens_follow));
            it.doc = format!("```stellang\nfn {name}({params}) -> {ret}\n```\n\n{doc}");
            it.label_detail = Some(format!("({params})"));
            it.label_desc = Some("builtin".into());
            it.sig_help = !parens_follow;
            items.push(it);
        }
        for c in ["true", "false", "none", "self"] {
            items.push(item(c, K_KEYWORD, "keyword", 4));
        }
        for t in ["int", "float", "bool", "str", "void"] {
            items.push(item(t, K_TYPE, "builtin type", 5));
        }
        let w = grammar::words();
        for kw in w.declare.iter().chain(&w.control).filter(|k| k.is_ascii()) {
            items.push(item(kw.clone(), K_KEYWORD, "keyword", 4));
        }
        for (label, snip, detail) in SNIPPETS {
            let mut it = item(*label, K_SNIPPET, *detail, 4);
            it.snippet = Some(snip.to_string());
            it.doc = format!("```stellang\n{}\n```", clean_snippet(snip));
            items.push(it);
        }
    }

    /// Declarations of a std module the file doesn't import yet.
    fn std_decls(&self, m: &str) -> Vec<Decl> {
        let file = format!("{}/{m}.st", self.std_dir);
        let mut units = vec![];
        let srcs = Sources { std_dir: Some(&self.std_dir), open: &self.docs };
        let src = STD.iter().find(|s| s.0 == m).map(|s| s.1).unwrap_or("");
        if load(&mut units, m, file, src, &srcs).is_err() {
            return vec![];
        }
        self.decls(&units)
    }

    /// An edit adding `import m` after the other imports.
    fn import_edit(&self, text: &str, m: &str) -> Json {
        let lines: Vec<&str> = text.lines().collect();
        let last_import = lines.iter().rposition(|l| l.trim_start().starts_with("import "));
        let at = match last_import {
            Some(i) => i + 1,
            None => lines.iter().take_while(|l| l.trim_start().starts_with("//") || l.trim().is_empty() && false).count(),
        };
        let p = obj([("line", (at as u32).into()), ("character", 0u32.into())]);
        let blank = if last_import.is_none() { "\n" } else { "" };
        obj([("range", obj([("start", p.clone()), ("end", p)])), ("newText", format!("import {m}\n{blank}").into())])
    }

    // ---- parameter-name hints ----

    pub(super) fn param_hints(&self, path: &str, text: &str, toks: &[Token], from: u32, to: u32, decls: &[Decl], a: &Analysis) -> Vec<Json> {
        let mut out = vec![];
        for k in 0..toks.len().saturating_sub(1) {
            if toks[k + 1].tok != Tok::LParen || !matches!(toks[k].tok, Tok::Ident(_)) || toks[k].pos.line < from || toks[k].pos.line > to {
                continue;
            }
            if k > 0 && toks[k - 1].tok == Tok::Fn {
                continue;
            }
            let Some(d) = self.resolve(path, decls, toks, k, &a.units, &a.notes).into_iter().find(|d| matches!(d.kind, "fn" | "method")) else { continue };
            let (ps, _) = params_of(&d.sig);
            if ps.len() < 2 && !ps.first().is_some_and(|p| p.contains("bool")) {
                continue; // one obvious argument needs no label
            }
            // the start of each argument
            let mut depth = 0;
            let mut arg = 0;
            let mut starts = vec![k + 2];
            for (j, t) in toks.iter().enumerate().skip(k + 2) {
                match t.tok {
                    Tok::LParen | Tok::LBrack | Tok::LBrace => depth += 1,
                    Tok::RParen | Tok::RBrack | Tok::RBrace if depth == 0 => break,
                    Tok::RParen | Tok::RBrack | Tok::RBrace => depth -= 1,
                    Tok::Comma if depth == 0 => {
                        arg += 1;
                        starts.push(j + 1);
                    }
                    _ => {}
                }
            }
            let _ = arg;
            for (i, s) in starts.iter().enumerate() {
                let Some(p) = ps.get(i) else { break };
                let mut s = *s;
                while toks.get(s).is_some_and(|t| t.tok == Tok::Newline) {
                    s += 1;
                }
                let Some(t) = toks.get(s) else { break };
                if t.tok == Tok::RParen {
                    break;
                }
                let name = p.split(':').next().unwrap_or("").trim();
                // `f(name)` or `f(x.name)` already says it; lambdas speak for themselves
                let same = matches!(&t.tok, Tok::Ident(n) if n == name) || toks.get(s + 2).is_some_and(|x| matches!(&x.tok, Tok::Ident(n) if n == name) && toks[s + 1].tok == Tok::Dot && !matches!(toks.get(s + 3).map(|x| &x.tok), Some(Tok::Dot | Tok::LParen)));
                if same || name.is_empty() || p.contains("fn(") {
                    continue;
                }
                out.push(obj([("position", lsp_pos(text, t.pos)), ("label", format!("{name}:").into()), ("kind", 2u32.into()), ("paddingRight", true.into())]));
            }
        }
        out
    }

    // ---- quick fixes ----

    pub(super) fn code_actions(&self, path: &str, params: &Json) -> Json {
        let Some(text) = self.docs.get(path) else { return Json::Null };
        let uri = to_uri(path);
        let mut out = vec![];
        let edit = |title: String, edits: Vec<Json>, diag: &Json, preferred: bool| {
            obj([
                ("title", title.into()),
                ("kind", "quickfix".into()),
                ("diagnostics", Json::Arr(vec![diag.clone()])),
                ("isPreferred", preferred.into()),
                ("edit", obj([("changes", Json::Obj(vec![(uri.clone(), Json::Arr(edits))]))])),
            ])
        };
        let a = self.analyze(path);
        let decls = if a.units.is_empty() { self.cache.get(path).map(|c| c.decls.clone()).unwrap_or_default() } else { self.decls(&a.units) };
        let model = if a.units.is_empty() { self.cache.get(path).map(|c| c.model.clone()).unwrap_or_default() } else { Model::of(&a.units) };
        for d in params.at(&["context", "diagnostics"]).arr() {
            let msg = d.get("message").str().unwrap_or("");
            let r = d.get("range");
            let start = Pos { line: r.at(&["start", "line"]).num().unwrap_or(0.0) as u32 + 1, col: 0 };
            let named = msg.split('`').nth(1).unwrap_or("").to_string();

            // a module used but not imported
            if (msg.starts_with("unknown name") || msg.starts_with("unknown function")) && STD.iter().any(|s| s.0 == named) {
                out.push(edit(format!("Import `{named}`"), vec![self.import_edit(text, &named)], d, true));
                continue;
            }
            // a `match` that misses cases
            if let Some(rest) = msg.strip_prefix("this `match` doesn't handle ") {
                let missing: Vec<&str> = rest.split(" (add arms").next().unwrap_or("").split(", ").collect();
                if let Some(e) = self.missing_arms(text, start.line, &missing, &model) {
                    out.push(edit("Add the missing match arms".into(), vec![e], d, true));
                }
                continue;
            }
            // a misspelled name
            if msg.starts_with("unknown") || msg.contains("has no") {
                let wanted = if msg.contains("has no") { msg.rsplit('`').nth(1).unwrap_or("").to_string() } else { named.clone() };
                if wanted.is_empty() {
                    continue;
                }
                let mut names: Vec<String> = decls.iter().map(|d| d.name.clone()).collect();
                names.extend(a.notes.iter().filter_map(|n| n.text.trim_start_matches("let ").trim_start_matches("var ").split_once(": ").map(|x| x.0.to_string())));
                names.extend(BUILTIN_METHODS.iter().map(|m| m.1.to_string()));
                names.extend(BUILTIN_FNS.iter().map(|f| f.0.to_string()));
                names.retain(|n| !n.contains(['.', ' ']) && *n != wanted);
                names.sort();
                names.dedup();
                let mut best: Vec<(usize, String)> = names.into_iter().map(|n| (distance(&n, &wanted), n)).filter(|(dd, n)| *dd <= 2.max(wanted.len() / 3) && *dd < n.len().max(wanted.len())).collect();
                best.sort();
                // where the misspelled word is on that line
                let line = text.lines().nth(start.line as usize - 1).unwrap_or("");
                let Some(at) = find_word(line, &wanted) else { continue };
                let from = Pos { line: start.line, col: at as u32 + 1 };
                let to = Pos { line: start.line, col: (at + wanted.chars().count()) as u32 + 1 };
                for (i, (_, n)) in best.into_iter().take(3).enumerate() {
                    out.push(edit(format!("Change to `{n}`"), vec![obj([("range", range(text, from, to)), ("newText", n.into())])], d, i == 0));
                }
            }
        }
        Json::Arr(out)
    }

    /// An edit adding arms for `missing` (like `Shape.Circle`) to the `match` on line `line`.
    fn missing_arms(&self, text: &str, line: u32, missing: &[&str], model: &Model) -> Option<Json> {
        let toks = flatten(&lexer::lex(text).ok()?);
        let m = toks.iter().position(|t| t.tok == Tok::Match && t.pos.line == line).or_else(|| toks.iter().rposition(|t| t.tok == Tok::Match && t.pos.line <= line))?;
        let open = (m..toks.len()).find(|i| matches!(toks[*i].tok, Tok::LBrace | Tok::Star))?;
        let mut depth = 0;
        let mut close = None;
        for (i, t) in toks.iter().enumerate().skip(open) {
            match t.tok {
                Tok::LBrace => depth += 1,
                Tok::RBrace => {
                    depth -= 1;
                    if depth == 0 {
                        close = Some(i);
                        break;
                    }
                }
                _ => {}
            }
        }
        let close = close?;
        let close_pos = toks[close].pos;
        let lines: Vec<&str> = text.lines().collect();
        let indent_of = |l: u32| lines.get(l as usize - 1).map(|s| s.chars().take_while(|c| c.is_whitespace()).collect::<String>()).unwrap_or_default();
        let same_line = toks[open].pos.line == close_pos.line;
        // an existing arm tells the style: does it end with a comma?
        let commas = toks[open..close].iter().any(|t| t.tok == Tok::Comma);
        let arms: Vec<String> = missing
            .iter()
            .map(|c| {
                let pat = model.pattern_for(c);
                format!("{pat} => panic(\"todo: {}\"){}", c.rsplit('.').next().unwrap_or(c), if commas || same_line { "," } else { "" })
            })
            .collect();
        if same_line {
            // `match x { A => 1 }` -> `match x { A => 1, B => ... }`
            let prev = &toks[close - 1];
            let sep = if prev.tok == Tok::Comma { " " } else { ", " };
            let joined = arms.join(" ");
            let joined = joined.trim_end_matches(',');
            return Some(obj([("range", range(text, close_pos, close_pos)), ("newText", format!("{}{joined} ", sep.trim_start_matches(if prev.tok == Tok::Comma { "" } else { "" })).into())]));
        }
        let inner = format!("{}    ", indent_of(close_pos.line));
        let inner = toks[open + 1..close].iter().find(|t| t.tok != Tok::Newline).map_or(inner, |t| indent_of(t.pos.line));
        // after the last arm, before the line with `}`
        let mut needs_comma = String::new();
        if commas {
            if let Some(last) = toks[open + 1..close].iter().rev().find(|t| t.tok != Tok::Newline) {
                if last.tok != Tok::Comma && last.tok != Tok::RBrace {
                    needs_comma = ",".into();
                }
            }
        }
        let at = Pos { line: close_pos.line, col: 1 };
        let body: String = arms.iter().map(|a| format!("{inner}{a}\n")).collect();
        let mut edits = vec![];
        if !needs_comma.is_empty() {
            let last = toks[open + 1..close].iter().rev().find(|t| t.tok != Tok::Newline)?;
            let end_col = text.lines().nth(last.pos.line as usize - 1).map_or(0, |l| l.trim_end().chars().count() as u32 + 1);
            let p = Pos { line: last.pos.line, col: end_col };
            edits.push(obj([("range", range(text, p, p)), ("newText", ",".into())]));
        }
        let _ = edits;
        Some(obj([("range", range(text, at, at)), ("newText", body.into())]))
    }
}

fn find_word(line: &str, w: &str) -> Option<usize> {
    let cs: Vec<char> = line.chars().collect();
    let wc: Vec<char> = w.chars().collect();
    (0..cs.len().saturating_sub(wc.len() - 1)).find(|&i| {
        cs[i..].starts_with(&wc)
            && (i == 0 || !(cs[i - 1].is_ascii_alphanumeric() || cs[i - 1] == '_'))
            && cs.get(i + wc.len()).is_none_or(|c| !(c.is_ascii_alphanumeric() || *c == '_'))
    })
}

/// A snippet as plain text: `${1:x}` -> `x`.
fn clean_snippet(s: &str) -> String {
    let cs: Vec<char> = s.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    let mut depth = 0;
    while i < cs.len() {
        if cs[i] == '$' && cs.get(i + 1) == Some(&'{') {
            i += 2;
            while i < cs.len() && cs[i].is_ascii_digit() {
                i += 1;
            }
            if cs.get(i) == Some(&':') {
                i += 1;
            }
            depth += 1;
            continue;
        }
        if cs[i] == '$' && cs.get(i + 1).is_some_and(|c| c.is_ascii_digit()) {
            i += 2;
            continue;
        }
        if cs[i] == '}' && depth > 0 {
            depth -= 1;
            i += 1;
            continue;
        }
        out.push(if cs[i] == '\t' { ' ' } else { cs[i] });
        if cs[i] == '\t' {
            out += "   ";
        }
        i += 1;
    }
    out
}

// ---- the shape of the program's types ----

#[derive(Clone, Default)]
pub(super) struct Model {
    structs: Vec<(String, String, Vec<(String, String, bool)>)>, // module, name, (field, type, optional)
    enums: Vec<(String, String, Vec<(String, Vec<(String, String)>, bool)>)>, // module, name, (variant, fields, braces)
    pub(super) funcs: Vec<FnInfo>,
}

#[derive(Clone)]
pub(super) struct FnInfo {
    pub file: String,
    pub pos: Pos,
    pub params: Vec<(String, String)>,
}

impl Model {
    pub(super) fn of(units: &[Unit]) -> Model {
        let mut m = Model::default();
        for u in units {
            for s in &u.module.structs {
                let fields = s.fields.iter().map(|f| (f.name.clone(), f.ty.to_string(), f.default.is_some() || matches!(f.ty, crate::parser::Type::Opt(_)))).collect();
                m.structs.push((u.name.clone(), s.name.clone(), fields));
            }
            for e in &u.module.enums {
                let vs = e.variants.iter().map(|v| (v.name.clone(), v.fields.iter().map(|f| (f.name.clone(), f.ty.to_string())).collect(), v.braces)).collect();
                m.enums.push((u.name.clone(), e.name.clone(), vs));
            }
            let mut add = |f: &crate::parser::Func, owner: Option<&str>| {
                let params = f
                    .params
                    .iter()
                    .map(|(n, t)| (n.clone(), t.as_ref().map_or_else(|| owner.unwrap_or("").to_string(), |t| t.to_string())))
                    .collect();
                m.funcs.push(FnInfo { file: u.file.clone(), pos: f.pos, params });
            };
            for f in &u.module.funcs {
                add(f, None);
            }
            for im in &u.module.impls {
                for f in &im.methods {
                    add(f, Some(&im.name));
                }
            }
        }
        m
    }

    fn struct_fields(&self, module: &str, name: &str) -> Vec<(String, String, bool)> {
        self.structs.iter().find(|s| s.0 == module && s.1 == name).map(|s| s.2.clone()).unwrap_or_default()
    }

    fn variant(&self, module: &str, e: &str, v: &str) -> Option<&(String, Vec<(String, String)>, bool)> {
        self.enums.iter().filter(|x| x.0 == module && (e.is_empty() || x.1 == e)).flat_map(|x| x.2.iter()).find(|x| x.0 == v)
    }

    fn variant_fields(&self, module: &str, e: &str, v: &str) -> Vec<(String, String, bool)> {
        self.variant(module, e, v).map(|x| x.1.iter().map(|(n, t)| (n.clone(), t.clone(), t.ends_with('?'))).collect()).unwrap_or_default()
    }

    /// `Circle(${1:float})` / `Rect { w: $1, h: $2 }` / `Red`; with `qualified`, `Shape.` in front.
    fn variant_snippet(&self, module: &str, e: &str, v: &str, qualified: bool) -> Option<String> {
        let (_, fields, braces) = self.variant(module, e, v)?;
        let head = if qualified { format!("{e}.{v}") } else { v.to_string() };
        Some(if fields.is_empty() {
            format!("{head}$0")
        } else if *braces {
            let ps: Vec<String> = fields.iter().enumerate().map(|(i, (n, _))| format!("{n}: ${{{}}}", i + 1)).collect();
            format!("{head} {{ {} }}$0", ps.join(", "))
        } else {
            let ps: Vec<String> = fields.iter().enumerate().map(|(i, (n, t))| format!("${{{}:{}}}", i + 1, if n.parse::<u32>().is_ok() { t.as_str() } else { n.as_str() })).collect();
            format!("{head}({})$0", ps.join(", "))
        })
    }

    /// A pattern for one case (`Shape.Circle`, `some`, `true`) with its fields bound to names.
    fn pattern_for(&self, case: &str) -> String {
        match case {
            "some" => return "some(value)".into(),
            "none" => return "none".into(),
            "ok" => return "ok(value)".into(),
            "err" => return "err(e)".into(),
            "true" | "false" => return case.into(),
            _ => {}
        }
        let v = case.rsplit('.').next().unwrap_or(case);
        let e = case.rsplit('.').nth(1).unwrap_or("");
        let found = self.enums.iter().filter(|x| e.is_empty() || x.1 == e).flat_map(|x| x.2.iter()).find(|x| x.0 == v);
        let Some((_, fields, braces)) = found else { return format!(".{v}") };
        bind_pattern(v, fields, *braces, None)
    }

    /// The patterns that cover `ty`, as snippets, with a description.
    fn patterns(&self, ty: &str) -> Vec<(String, String)> {
        let base = ty.trim_end_matches('!');
        if ty.ends_with('?') {
            return vec![("some(${1:value})".into(), "has a value".into()), ("none".into(), "no value".into())];
        }
        if ty.ends_with('!') {
            return vec![("ok(${1:value})".into(), "succeeded".into()), ("err(${1:e})".into(), "failed".into())];
        }
        if ty == "bool" {
            return vec![("true".into(), "bool".into()), ("false".into(), "bool".into())];
        }
        let (module, name) = base.rsplit_once('.').map_or((String::new(), base.to_string()), |(m, n)| (m.to_string(), n.to_string()));
        let Some(e) = self.enums.iter().find(|x| x.0 == module && x.1 == name) else { return vec![] };
        e.2.iter().map(|(v, fields, braces)| (bind_pattern(v, fields, *braces, Some(1)), format!("{name}.{v}"))).collect()
    }

    /// Every arm for a `match` on `ty`, as one snippet.
    fn arms(&self, ty: &str, indent: &str) -> String {
        let pats = self.patterns(ty);
        let mut n = 0;
        let lines: Vec<String> = pats
            .iter()
            .map(|(p, _)| {
                // renumber the tab stops so they run through all arms
                let p = clean_snippet(p);
                n += 1;
                format!("{indent}{p} => ${{{n}}},")
            })
            .collect();
        lines.join("\n")
    }
}

/// `.Circle(r)`, `.Done { at }`, `.Red`; with `stops`, the names are snippet placeholders.
fn bind_pattern(v: &str, fields: &[(String, String)], braces: bool, stops: Option<u32>) -> String {
    let mut used = HashSet::new();
    let names: Vec<String> = fields
        .iter()
        .enumerate()
        .map(|(i, (n, t))| {
            let base = if n.parse::<u32>().is_ok() { lambda_names(t, 1) } else { n.clone() };
            let mut name = base.clone();
            let mut k = 2;
            while !used.insert(name.clone()) {
                name = format!("{base}{k}");
                k += 1;
            }
            match stops {
                Some(s) if !braces => format!("${{{}:{name}}}", s + i as u32),
                _ => name,
            }
        })
        .collect();
    if fields.is_empty() {
        format!(".{v}")
    } else if braces {
        format!(".{v} {{ {} }}", names.join(", "))
    } else {
        format!(".{v}({})", names.join(", "))
    }
}

/// A component's props: (name, type, optional) from its parameters, or from the fields of its one
/// props struct.
fn component_props(d: &Decl, model: &Model) -> Vec<(String, String, bool)> {
    let (params, _) = params_of(&d.sig);
    let ps: Vec<(String, String)> = params
        .iter()
        .map(|p| {
            let (n, t) = p.split_once(':').unwrap_or((p.as_str(), ""));
            (n.trim().to_string(), t.trim().to_string())
        })
        .collect();
    if let [(_, t)] = ps.as_slice() {
        let (m, n) = t.rsplit_once('.').map_or((d.module.clone(), t.clone()), |(m, n)| (m.to_string(), n.to_string()));
        let fields = model.struct_fields(&m, &n);
        if !fields.is_empty() {
            return fields;
        }
    }
    ps.into_iter().map(|(n, t)| {
        let opt = t.ends_with('?');
        (n, t, opt)
    }).collect()
}
