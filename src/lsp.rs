//! `stellang lsp`: a language server over stdio (JSON-RPC, LSP 3.17).
//!
//! It has no grammar or type rules of its own: diagnostics come from the real compiler, hover types
//! from notes the type checker leaves, highlighting from the real lexer plus the parsed declarations,
//! formatting from `stellang fmt`. Change the language and the editor support follows.

use crate::codegen::{self, Note, Unit};
use crate::json::{self, obj, Json};
use crate::lexer::{self, Part, Pos, Tok, Token, WORDS};
use crate::parser::Module;
use crate::{fmt, grammar, load, Sources, STD};
use std::collections::{HashMap, HashSet};
use std::io::{self, BufRead, Write};
use std::path::Path;

const TOKEN_TYPES: &[&str] = &[
    "keyword", "string", "number", "operator", "function", "method", "type", "enum", "enumMember", "struct",
    "variable", "parameter", "property", "comment", "namespace",
];
const TOKEN_MODIFIERS: &[&str] = &["declaration", "defaultLibrary"];

fn tt(name: &str) -> u32 {
    TOKEN_TYPES.iter().position(|t| *t == name).unwrap() as u32
}

/// Methods of the builtin types, for completion after `.`.
const BUILTIN_METHODS: &[(&str, &[&str])] = &[
    ("str", &["len", "is_empty", "split", "lines", "chars", "find", "count", "slice", "trim", "trim_start", "trim_end", "lower", "upper", "starts_with", "ends_with", "contains", "replace", "repeat", "reverse"]),
    ("list", &["len", "is_empty", "push", "pop", "insert", "remove", "slice", "contains", "index_of", "sort", "reverse", "map", "filter", "any", "all", "sum", "join", "first", "last", "get", "find"]),
    ("map", &["len", "is_empty", "get", "contains", "remove", "keys", "values"]),
    ("set", &["len", "is_empty", "add", "contains", "remove", "to_list"]),
    ("opt", &["is_some", "is_none", "unwrap"]),
    ("float", &["floor", "ceil", "round", "sqrt", "abs"]),
];

#[derive(Default)]
struct Server {
    docs: HashMap<String, String>, // path -> text of open documents
    std_dir: String,
    published: HashMap<String, HashSet<String>>, // doc path -> files we put diagnostics on
    last_tokens: HashMap<String, Json>,
}

/// A declaration, for hover, go to definition, symbols and completion.
#[derive(Clone)]
struct Decl {
    name: String,
    owner: Option<String>, // the type, for variants, methods and fields
    module: String,
    file: String,
    pos: Pos,
    kind: &'static str, // fn struct enum variant method field const
    sig: String,
    doc: String,
}

pub fn run() {
    let mut s = Server { std_dir: write_std(), ..Default::default() };
    let stdin = io::stdin();
    let mut input = stdin.lock();
    while let Some(msg) = read_msg(&mut input) {
        let Some(msg) = json::parse(&msg) else { continue };
        let method = msg.get("method").str().unwrap_or("").to_string();
        let id = msg.get("id").clone();
        let params = msg.get("params");
        let result = match method.as_str() {
            "initialize" => Some(capabilities()),
            "shutdown" => Some(Json::Null),
            "exit" => return,
            "textDocument/didOpen" => {
                let d = params.get("textDocument");
                s.open(d.get("uri").str().unwrap_or(""), d.get("text").str().unwrap_or(""));
                None
            }
            "textDocument/didChange" => {
                let uri = params.at(&["textDocument", "uri"]).str().unwrap_or("");
                if let Some(c) = params.get("contentChanges").arr().last() {
                    s.open(uri, c.get("text").str().unwrap_or(""));
                }
                None
            }
            "textDocument/didSave" => {
                let uri = params.at(&["textDocument", "uri"]).str().unwrap_or("").to_string();
                if let Some(t) = s.docs.get(&to_path(&uri)).cloned() {
                    s.open(&uri, &t);
                }
                None
            }
            "textDocument/didClose" => {
                let path = to_path(params.at(&["textDocument", "uri"]).str().unwrap_or(""));
                s.docs.remove(&path);
                None
            }
            "textDocument/semanticTokens/full" => Some(s.semantic_tokens(&doc_path(params))),
            "textDocument/hover" => Some(s.hover(&doc_path(params), position(params))),
            "textDocument/definition" => Some(s.definition(&doc_path(params), position(params))),
            "textDocument/completion" => Some(s.completion(&doc_path(params), position(params))),
            "textDocument/documentSymbol" => Some(s.symbols(&doc_path(params))),
            "textDocument/formatting" => Some(s.format(&doc_path(params))),
            "textDocument/references" => Some(s.references(&doc_path(params), position(params))),
            "textDocument/documentHighlight" => Some(s.highlights(&doc_path(params), position(params))),
            "textDocument/prepareRename" => Some(s.prepare_rename(&doc_path(params), position(params))),
            "textDocument/rename" => match s.rename(&doc_path(params), position(params), params.get("newName").str().unwrap_or("")) {
                Ok(r) => Some(r),
                Err(m) => {
                    send(&obj([("jsonrpc", "2.0".into()), ("id", id), ("error", obj([("code", (-32803i64).into()), ("message", m.into())]))]));
                    continue;
                }
            },
            "textDocument/inlayHint" => Some(s.inlay_hints(&doc_path(params), params)),
            "textDocument/signatureHelp" => Some(s.signature_help(&doc_path(params), position(params))),
            "textDocument/foldingRange" => Some(s.folding(&doc_path(params))),
            "textDocument/codeLens" => Some(s.code_lens(&doc_path(params))),
            "workspace/symbol" => Some(s.workspace_symbols(params.get("query").str().unwrap_or(""))),
            _ => (id != Json::Null).then_some(Json::Null), // answer unknown requests, ignore notifications
        };
        if let (Some(r), false) = (result, id == Json::Null) {
            send(&obj([("jsonrpc", "2.0".into()), ("id", id), ("result", r)]));
        }
    }
}

fn capabilities() -> Json {
    obj([
        (
            "capabilities",
            obj([
                ("textDocumentSync", obj([("openClose", true.into()), ("change", 1u32.into()), ("save", true.into())])),
                ("hoverProvider", true.into()),
                ("definitionProvider", true.into()),
                ("documentSymbolProvider", true.into()),
                ("documentFormattingProvider", true.into()),
                ("completionProvider", obj([("triggerCharacters", vec!["."].into())])),
                ("referencesProvider", true.into()),
                ("documentHighlightProvider", true.into()),
                ("renameProvider", obj([("prepareProvider", true.into())])),
                ("inlayHintProvider", true.into()),
                ("signatureHelpProvider", obj([("triggerCharacters", vec!["(", ","].into())])),
                ("foldingRangeProvider", true.into()),
                ("codeLensProvider", obj([("resolveProvider", false.into())])),
                ("workspaceSymbolProvider", true.into()),
                (
                    "semanticTokensProvider",
                    obj([
                        ("legend", obj([("tokenTypes", TOKEN_TYPES.to_vec().into()), ("tokenModifiers", TOKEN_MODIFIERS.to_vec().into())])),
                        ("full", true.into()),
                    ]),
                ),
            ]),
        ),
        ("serverInfo", obj([("name", "stellang".into()), ("version", env!("CARGO_PKG_VERSION").into())])),
    ])
}

// ---- transport ----

fn read_msg(r: &mut impl BufRead) -> Option<String> {
    let mut len = None;
    loop {
        let mut line = String::new();
        if r.read_line(&mut line).ok()? == 0 {
            return None;
        }
        let line = line.trim_end();
        if line.is_empty() {
            break;
        }
        if let Some(v) = line.to_ascii_lowercase().strip_prefix("content-length:") {
            len = v.trim().parse::<usize>().ok();
        }
    }
    let mut buf = vec![0; len?];
    r.read_exact(&mut buf).ok()?;
    String::from_utf8(buf).ok()
}

fn send(msg: &Json) {
    let body = msg.to_string();
    let mut out = io::stdout().lock();
    let _ = write!(out, "Content-Length: {}\r\n\r\n{body}", body.len());
    let _ = out.flush();
}

fn notify(method: &str, params: Json) {
    send(&obj([("jsonrpc", "2.0".into()), ("method", method.into()), ("params", params)]));
}

// ---- paths and positions ----

fn to_path(uri: &str) -> String {
    let p = uri.strip_prefix("file://").unwrap_or(uri);
    let b = p.as_bytes();
    let mut out = vec![];
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(&p[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn to_uri(path: &str) -> String {
    let mut s = String::from("file://");
    for b in path.bytes() {
        if b.is_ascii_alphanumeric() || b"/-_.~".contains(&b) {
            s.push(b as char);
        } else {
            s += &format!("%{b:02X}");
        }
    }
    s
}

fn doc_path(params: &Json) -> String {
    to_path(params.at(&["textDocument", "uri"]).str().unwrap_or(""))
}

/// (line, UTF-16 column), both 0-based
fn position(params: &Json) -> (u32, u32) {
    let p = params.get("position");
    (p.get("line").num().unwrap_or(0.0) as u32, p.get("character").num().unwrap_or(0.0) as u32)
}

/// UTF-16 column of 1-based char column `col` on `line`.
fn utf16_col(line: &str, col: u32) -> u32 {
    line.chars().take(col.saturating_sub(1) as usize).map(|c| c.len_utf16() as u32).sum()
}

/// 1-based char column of UTF-16 column `u`.
fn char_col(line: &str, u: u32) -> u32 {
    let mut n = 0;
    for (i, c) in line.chars().enumerate() {
        if n >= u {
            return i as u32 + 1;
        }
        n += c.len_utf16() as u32;
    }
    line.chars().count() as u32 + 1
}

fn lsp_pos(text: &str, p: Pos) -> Json {
    let line = text.lines().nth(p.line as usize - 1).unwrap_or("");
    obj([("line", (p.line - 1).into()), ("character", utf16_col(line, p.col).into())])
}

fn range(text: &str, from: Pos, to: Pos) -> Json {
    obj([("start", lsp_pos(text, from)), ("end", lsp_pos(text, to))])
}

/// Copy the std modules to disk, so "go to definition" can open them.
fn write_std() -> String {
    let base = std::env::var("XDG_CACHE_HOME")
        .map(Into::into)
        .or_else(|_| std::env::var("HOME").map(|h| Path::new(&h).join(".cache")))
        .unwrap_or_else(|_| std::env::temp_dir());
    let dir = base.join("stellang").join(format!("std-{}", env!("CARGO_PKG_VERSION")));
    let _ = std::fs::create_dir_all(&dir);
    for (name, src) in STD {
        let f = dir.join(format!("{name}.st"));
        if std::fs::read_to_string(&f).ok().as_deref() != Some(src) {
            let _ = std::fs::write(&f, src);
        }
    }
    dir.display().to_string()
}

// ---- analysis ----

struct Analysis {
    units: Vec<Unit>,
    notes: Vec<Note>,
    error: Option<(String, Pos, String)>,
}

impl Server {
    fn text_of(&self, path: &str) -> Option<String> {
        self.docs.get(path).cloned().or_else(|| std::fs::read_to_string(path).ok())
    }

    fn analyze(&self, path: &str) -> Analysis {
        let text = self.docs.get(path).cloned().unwrap_or_default();
        self.analyze_file(path, &text)
    }

    fn analyze_file(&self, path: &str, text: &str) -> Analysis {
        let text = text.to_string();
        let mut units = vec![];
        let srcs = Sources { std_dir: Some(&self.std_dir), open: &self.docs };
        if let Err(e) = load(&mut units, "", path.to_string(), &text, &srcs) {
            return Analysis { units, notes: vec![], error: Some(e) };
        }
        let (r, notes) = codegen::check(&units, false);
        Analysis { units, notes, error: r.err() }
    }

    fn open(&mut self, uri: &str, text: &str) {
        let path = to_path(uri);
        self.docs.insert(path.clone(), text.to_string());
        let a = self.analyze(&path);
        let mut by_file: HashMap<String, Vec<Json>> = HashMap::from([(path.clone(), vec![])]);
        if let Some((file, p, m)) = &a.error {
            let t = self.text_of(file).unwrap_or_default();
            let p = &name_before_paren(&t, *p);
            let end = token_end(&t, *p);
            let d = obj([("range", range(&t, *p, end)), ("severity", 1u32.into()), ("source", "stellang".into()), ("message", m.as_str().into())]);
            by_file.entry(file.clone()).or_default().push(d);
        }
        let before = self.published.remove(&path).unwrap_or_default();
        for f in before {
            by_file.entry(f).or_default();
        }
        for (f, ds) in &by_file {
            notify("textDocument/publishDiagnostics", obj([("uri", to_uri(f).into()), ("diagnostics", Json::Arr(ds.clone()))]));
        }
        self.published.insert(path, by_file.into_iter().filter(|(_, d)| !d.is_empty()).map(|(f, _)| f).collect());
    }

    // ---- declarations ----

    fn decls(&self, units: &[Unit]) -> Vec<Decl> {
        let mut out = vec![];
        for u in units {
            let text = self.text_of(&u.file).unwrap_or_default();
            let lines: Vec<&str> = text.lines().collect();
            let m: &Module = &u.module;
            let mut add = |name: &str, owner: Option<&str>, pos: Pos, kind: &'static str, sig: String| {
                out.push(Decl {
                    name: name.into(),
                    owner: owner.map(Into::into),
                    module: u.name.clone(),
                    file: u.file.clone(),
                    pos,
                    kind,
                    sig,
                    doc: doc_above(&lines, pos.line),
                });
            };
            for f in &m.funcs {
                add(&f.name, None, f.pos, "fn", line_sig(&lines, f.pos));
            }
            for c in &m.consts {
                add(&c.name, None, c.pos, "const", line_sig(&lines, c.pos));
            }
            for s in &m.structs {
                add(&s.name, None, s.pos, "struct", block_sig(&lines, s.pos));
                for f in &s.fields {
                    add(&f.name, Some(&s.name), s.pos, "field", format!("{}.{}: {}", s.name, f.name, f.ty));
                }
            }
            for e in &m.enums {
                add(&e.name, None, e.pos, "enum", block_sig(&lines, e.pos));
                for v in &e.variants {
                    add(&v.name, Some(&e.name), v.pos, "variant", format!("{}.{}", e.name, line_sig(&lines, v.pos).trim_end_matches(',')));
                }
            }
            for im in &m.impls {
                for f in &im.methods {
                    let kind = if f.params.first().is_some_and(|p| p.0 == "self" && p.1.is_none()) { "method" } else { "fn" };
                    let sig = line_sig(&lines, f.pos).replacen(&format!("fn {}(", f.name), &format!("fn {}.{}(", im.name, f.name), 1);
                    add(&f.name, Some(&im.name), f.pos, kind, sig);
                }
            }
        }
        out
    }

    /// The declarations a name at token `k` could mean, best first.
    fn resolve<'a>(&self, path: &str, decls: &'a [Decl], toks: &[Token], k: usize, units: &[Unit], notes: &[Note]) -> Vec<&'a Decl> {
        let Tok::Ident(name) = &toks[k].tok else { return vec![] };
        let prev = |n: usize| k.checked_sub(n).map(|i| &toks[i].tok);
        // the name in a declaration itself (`fn find`, `struct Todo`, a variant)
        let here = toks[k].pos;
        let kw = k.checked_sub(1).map(|i| toks[i].pos);
        let own: Vec<&Decl> = decls.iter().filter(|d| d.name == *name && d.file == path && (d.pos == here || Some(d.pos) == kw) && d.kind != "field").collect();
        if !own.is_empty() {
            return own;
        }
        let modules: HashSet<&str> = units.iter().map(|u| u.name.as_str()).collect();
        let named = |d: &&Decl| d.name == *name;
        if prev(1) == Some(&Tok::Dot) {
            if let Some(Tok::Ident(q)) = prev(2) {
                if modules.contains(q.as_str()) {
                    return decls.iter().filter(named).filter(|d| d.module == *q && d.owner.is_none()).collect();
                }
                let owned: Vec<&Decl> = decls.iter().filter(named).filter(|d| d.owner.as_deref() == Some(q.as_str())).collect();
                if !owned.is_empty() {
                    return owned;
                }
            }
            // `x.name`: the type checker noted the receiver's type at the `.`
            let dot = toks[k - 1].pos;
            let Some(n) = notes.iter().rev().find(|n| n.file == path && n.pos == dot) else {
                // no note: a builtin method, or the file doesn't type-check right now
                return if notes.is_empty() { decls.iter().filter(named).filter(|d| d.owner.is_some()).collect() } else { vec![] };
            };
            let qualified = n.text.trim_start_matches("fn ").split(['(', ':']).next().unwrap_or("").to_string();
            let owner = qualified.rsplit_once('.').map(|(t, _)| t.rsplit('.').next().unwrap_or(t).to_string());
            return decls.iter().filter(named).filter(|d| d.owner.is_some() && d.owner == owner).collect();
        }
        let mut found: Vec<&Decl> = decls.iter().filter(named).filter(|d| d.owner.is_none() && d.module.is_empty()).collect();
        found.extend(decls.iter().filter(named).filter(|d| d.kind == "variant"));
        found
    }

    // ---- requests ----

    fn hover(&self, path: &str, (line, ch): (u32, u32)) -> Json {
        let Some(text) = self.docs.get(path) else { return Json::Null };
        let Ok(toks) = lexer::lex(text) else { return Json::Null };
        let toks = flatten(&toks);
        let Some(k) = token_at(text, &toks, line, ch) else { return Json::Null };
        let a = self.analyze(path);
        let decls = self.decls(&a.units);
        let mut parts = vec![];
        // what the type checker saw at this spot (or at the `.` / `let` just before it)
        let prev = k.checked_sub(1).map(|i| &toks[i]);
        let at = |p: Pos| a.notes.iter().rev().find(|n| n.file == path && n.pos == p);
        let note = at(toks[k].pos).or_else(|| prev.filter(|t| matches!(t.tok, Tok::Dot | Tok::Let | Tok::Var)).and_then(|t| at(t.pos)));
        let found = self.resolve(path, &decls, &toks, k, &a.units, &a.notes);
        // a declaration (with parameter names and its doc comment) beats the checker's bare signature
        let decl = found.first().filter(|d| note.is_none() || !matches!(d.kind, "field" | "const") || d.doc.len() > 0);
        match (note, decl) {
            (Some(n), Some(d)) if !matches!(d.kind, "fn" | "method") => {
                parts.push(format!("```stellang\n{}\n```", n.text));
                if !d.doc.is_empty() {
                    parts.push(d.doc.clone());
                }
            }
            (_, Some(d)) => {
                parts.push(format!("```stellang\n{}\n```", d.sig));
                if !d.doc.is_empty() {
                    parts.push(d.doc.clone());
                }
            }
            (Some(n), None) => parts.push(format!("```stellang\n{}\n```", n.text)),
            (None, None) => {}
        }
        if parts.is_empty() {
            return Json::Null;
        }
        parts.dedup();
        obj([("contents", obj([("kind", "markdown".into()), ("value", parts.join("\n\n").into())]))])
    }

    /// Where the name at token `k` of `path` is defined: a declaration, or the binding of a local.
    fn def_of(&self, path: &str, toks: &[Token], k: usize, decls: &[Decl], units: &[Unit], notes: &[Note]) -> Option<(String, Pos)> {
        let Tok::Ident(name) = &toks[k].tok else { return None };
        let found = self.resolve(path, decls, toks, k, units, notes);
        let own = found.first().filter(|d| d.file == path && (d.pos == toks[k].pos || k > 0 && d.pos == toks[k - 1].pos));
        if let Some(d) = own.or(if k > 0 && toks[k - 1].tok == Tok::Dot { found.first() } else { None }) {
            return Some((d.file.clone(), d.pos));
        }
        if k > 0 && toks[k - 1].tok == Tok::Dot {
            return None;
        }
        // a local (it shadows anything global): the nearest binding of that name at or above
        if let Some(p) = self.local_binding(toks, k, name) {
            return Some((path.to_string(), p));
        }
        found.first().map(|d| (d.file.clone(), d.pos))
    }

    /// The nearest `let`/`var`/`for`/parameter/lambda/pattern binding of `name` at or above token `k`.
    fn local_binding(&self, toks: &[Token], k: usize, name: &str) -> Option<Pos> {
        for i in (0..=k).rev() {
            if toks[i].tok != Tok::Ident(name.to_string()) {
                continue;
            }
            let before = i.checked_sub(1).map(|j| &toks[j].tok);
            let after = toks.get(i + 1).map(|t| &t.tok);
            let binds = matches!(before, Some(Tok::Let | Tok::Var | Tok::For | Tok::LParen | Tok::Comma))
                && matches!(after, Some(Tok::Colon | Tok::Assign | Tok::In | Tok::Comma | Tok::RParen | Tok::FatArrow | Tok::Else))
                || matches!(after, Some(Tok::FatArrow))
                || matches!(before, Some(Tok::Catch));
            if binds {
                return Some(toks[i].pos);
            }
        }
        None
    }

    fn definition(&self, path: &str, (line, ch): (u32, u32)) -> Json {
        let Some(text) = self.docs.get(path) else { return Json::Null };
        let Ok(toks) = lexer::lex(text) else { return Json::Null };
        let toks = flatten(&toks);
        let Some(k) = token_at(text, &toks, line, ch) else { return Json::Null };
        let a = self.analyze(path);
        let decls = self.decls(&a.units);
        match self.def_of(path, &toks, k, &decls, &a.units, &a.notes) {
            Some((file, p)) => {
                let t = self.text_of(&file).unwrap_or_default();
                obj([("uri", to_uri(&file).into()), ("range", range(&t, p, p))])
            }
            None => Json::Null,
        }
    }

    /// Every use of the name under the cursor that means the same thing: (file, start, end).
    fn occurrences(&self, path: &str, (line, ch): (u32, u32), only_here: bool) -> Option<(Vec<(String, Pos, Pos)>, String)> {
        let text = self.docs.get(path)?;
        let toks = flatten(&lexer::lex(text).ok()?);
        let k = token_at(text, &toks, line, ch)?;
        let Tok::Ident(name) = &toks[k].tok else { return None };
        let a = self.analyze(path);
        let decls = self.decls(&a.units);
        let target = self.def_of(path, &toks, k, &decls, &a.units, &a.notes)?;
        let mut files: Vec<String> = vec![path.to_string()];
        if !only_here {
            files.extend(a.units.iter().map(|u| u.file.clone()).filter(|f| f != path && !f.starts_with(&self.std_dir)));
            files.extend(self.docs.keys().filter(|f| *f != path).cloned());
        }
        files.dedup();
        let mut out = vec![];
        let mut seen = HashSet::new();
        for f in files {
            if !seen.insert(f.clone()) {
                continue;
            }
            let Some(t) = self.text_of(&f) else { continue };
            let Ok(ft) = lexer::lex(&t) else { continue };
            let ft = flatten(&ft);
            // names are resolved in the context of the file that uses them
            let (fdecls, funits, fnotes);
            let (dd, uu, nn) = if f == path {
                (&decls, &a.units, &a.notes)
            } else {
                let fa = self.analyze_file(&f, &t);
                fdecls = self.decls(&fa.units);
                (funits, fnotes) = (fa.units, fa.notes);
                (&fdecls, &funits, &fnotes)
            };
            for (i, x) in ft.iter().enumerate() {
                if x.tok == Tok::Ident(name.clone()) && self.def_of(&f, &ft, i, dd, uu, nn).as_ref() == Some(&target) {
                    out.push((f.clone(), x.pos, Pos { line: x.pos.line, col: x.pos.col + name.chars().count() as u32 }));
                }
            }
        }
        Some((out, target.0))
    }

    fn references(&self, path: &str, at: (u32, u32)) -> Json {
        let Some((occ, _)) = self.occurrences(path, at, false) else { return Json::Null };
        Json::Arr(occ.iter().map(|(f, a, b)| {
            let t = self.text_of(f).unwrap_or_default();
            obj([("uri", to_uri(f).into()), ("range", range(&t, *a, *b))])
        }).collect())
    }

    fn highlights(&self, path: &str, at: (u32, u32)) -> Json {
        let Some((occ, _)) = self.occurrences(path, at, true) else { return Json::Null };
        let Some(text) = self.docs.get(path) else { return Json::Null };
        Json::Arr(occ.iter().filter(|o| o.0 == path).map(|(_, a, b)| obj([("range", range(text, *a, *b)), ("kind", 1u32.into())])).collect())
    }

    fn rename(&self, path: &str, at: (u32, u32), new_name: &str) -> Result<Json, String> {
        let ok = new_name.chars().next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
            && new_name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
            && !WORDS.iter().any(|w| w.0 == new_name);
        if !ok {
            return Err(format!("`{new_name}` isn't a valid name"));
        }
        let Some((occ, def_file)) = self.occurrences(path, at, false) else { return Err("nothing to rename here".into()) };
        if def_file.starts_with(&self.std_dir) {
            return Err("that is defined in the standard library".into());
        }
        let mut changes: Vec<(String, Json)> = vec![];
        for (f, a, b) in &occ {
            let t = self.text_of(f).unwrap_or_default();
            let edit = obj([("range", range(&t, *a, *b)), ("newText", new_name.into())]);
            let uri = to_uri(f);
            match changes.iter_mut().find(|c| c.0 == uri) {
                Some((_, Json::Arr(es))) => es.push(edit),
                _ => changes.push((uri, Json::Arr(vec![edit]))),
            }
        }
        Ok(obj([("changes", Json::Obj(changes))]))
    }

    fn prepare_rename(&self, path: &str, (line, ch): (u32, u32)) -> Json {
        let Some(text) = self.docs.get(path) else { return Json::Null };
        let Ok(toks) = lexer::lex(text) else { return Json::Null };
        let toks = flatten(&toks);
        let Some(k) = token_at(text, &toks, line, ch) else { return Json::Null };
        let Tok::Ident(name) = &toks[k].tok else { return Json::Null };
        if grammar::words().builtins.contains(name) || ["true", "false", "none", "self", "int", "float", "bool", "str", "void"].contains(&name.as_str()) {
            return Json::Null;
        }
        let p = toks[k].pos;
        range(text, p, Pos { line: p.line, col: p.col + name.chars().count() as u32 })
    }

    /// `: type` after `let` names that have no written type.
    fn inlay_hints(&self, path: &str, params: &Json) -> Json {
        let Some(text) = self.docs.get(path) else { return Json::Null };
        let Ok(toks) = lexer::lex(text) else { return Json::Null };
        let toks = flatten(&toks);
        let a = self.analyze(path);
        let (from, to) = (params.at(&["range", "start", "line"]).num().unwrap_or(0.0) as u32 + 1, params.at(&["range", "end", "line"]).num().unwrap_or(1e9) as u32 + 1);
        let mut out = vec![];
        for (i, t) in toks.iter().enumerate() {
            if !matches!(t.tok, Tok::Let | Tok::Var) || t.pos.line < from || t.pos.line > to {
                continue;
            }
            let (Some(name), Some(next)) = (toks.get(i + 1), toks.get(i + 2)) else { continue };
            let Tok::Ident(n) = &name.tok else { continue };
            if next.tok != Tok::Assign {
                continue;
            }
            let Some(note) = a.notes.iter().find(|x| x.file == path && x.pos == t.pos) else { continue };
            let Some((_, ty)) = note.text.split_once(": ") else { continue };
            let end = Pos { line: name.pos.line, col: name.pos.col + n.chars().count() as u32 };
            out.push(obj([("position", lsp_pos(text, end)), ("label", format!(": {ty}").into()), ("kind", 1u32.into()), ("paddingLeft", false.into())]));
        }
        Json::Arr(out)
    }

    /// The parameters of the call the cursor is in.
    fn signature_help(&self, path: &str, (line, ch): (u32, u32)) -> Json {
        let Some(text) = self.docs.get(path) else { return Json::Null };
        let Ok(toks) = lexer::lex(text) else { return Json::Null };
        let toks = flatten(&toks);
        let l = text.lines().nth(line as usize).unwrap_or("");
        let cur = Pos { line: line + 1, col: char_col(l, ch) };
        let before = toks.iter().take_while(|t| (t.pos.line, t.pos.col) < (cur.line, cur.col)).count();
        let (mut depth, mut commas) = (0, 0);
        let mut open = None;
        for i in (0..before).rev() {
            match toks[i].tok {
                Tok::RParen | Tok::RBrack | Tok::RBrace => depth += 1,
                Tok::LParen if depth == 0 => {
                    open = Some(i);
                    break;
                }
                Tok::LParen | Tok::LBrack | Tok::LBrace if depth > 0 => depth -= 1,
                Tok::LBrack | Tok::LBrace => return Json::Null,
                Tok::Comma if depth == 0 => commas += 1,
                _ => {}
            }
        }
        let Some(open) = open.filter(|o| *o > 0) else { return Json::Null };
        let a = self.analyze(path);
        let decls = self.decls(&a.units);
        let Some(d) = self.resolve(path, &decls, &toks, open - 1, &a.units, &a.notes).into_iter().find(|d| matches!(d.kind, "fn" | "method" | "variant")) else { return Json::Null };
        let sig = d.sig.lines().next().unwrap_or("");
        let inside = sig.find('(').and_then(|s| sig.rfind(')').map(|e| &sig[s + 1..e])).unwrap_or("");
        let mut params = split_top(inside);
        if d.kind == "method" && params.first().is_some_and(|p| p.trim() == "self") {
            params.remove(0);
        }
        let ps: Vec<Json> = params.iter().map(|p| obj([("label", p.trim().into())])).collect();
        let info = obj([("label", sig.into()), ("documentation", d.doc.as_str().into()), ("parameters", Json::Arr(ps))]);
        obj([("signatures", Json::Arr(vec![info])), ("activeSignature", 0u32.into()), ("activeParameter", (commas as u32).into())])
    }

    fn folding(&self, path: &str) -> Json {
        let Some(text) = self.docs.get(path) else { return Json::Null };
        let Ok(toks) = lexer::lex(text) else { return Json::Null };
        let Ok(m) = crate::parser::parse(toks.clone()) else { return Json::Null };
        let mut stack = vec![];
        let mut out = vec![];
        for (k, opens) in m.braces {
            if opens {
                stack.push(k);
            } else if let Some(o) = stack.pop() {
                let (a, b) = (toks[o].pos.line, toks[k].pos.line);
                if b > a + 1 {
                    out.push(obj([("startLine", (a - 1).into()), ("endLine", (b - 2).into())]));
                }
            }
        }
        // runs of comment lines
        let lines: Vec<&str> = text.lines().collect();
        let mut i = 0;
        while i < lines.len() {
            let start = i;
            while i < lines.len() && lines[i].trim_start().starts_with("//") { i += 1 }
            if i - start >= 2 {
                out.push(obj([("startLine", start.into()), ("endLine", (i - 1).into()), ("kind", "comment".into())]));
            }
            i = i.max(start + 1);
        }
        Json::Arr(out)
    }

    /// "▶ Run" and "Build" above `fn main`.
    fn code_lens(&self, path: &str) -> Json {
        let Some(text) = self.docs.get(path) else { return Json::Null };
        let Ok(toks) = lexer::lex(text) else { return Json::Arr(vec![]) };
        let Some(i) = toks.windows(2).position(|w| w[0].tok == Tok::Fn && w[1].tok == Tok::Ident("main".into())) else { return Json::Arr(vec![]) };
        let p = toks[i].pos;
        let r = range(text, p, p);
        let lens = |title: &str, cmd: &str| obj([("range", r.clone()), ("command", obj([("title", title.into()), ("command", cmd.into()), ("arguments", Json::Arr(vec![to_uri(path).into()]))]))]);
        Json::Arr(vec![lens("▶ Run", "stellang.run"), lens("Build", "stellang.build")])
    }

    fn workspace_symbols(&self, query: &str) -> Json {
        let q = query.to_lowercase();
        let mut out = vec![];
        let mut seen = HashSet::new();
        for path in self.docs.keys() {
            let a = self.analyze(path);
            for d in self.decls(&a.units) {
                if d.kind == "field" || d.file.starts_with(&self.std_dir) || !d.name.to_lowercase().contains(&q) || !seen.insert((d.file.clone(), d.pos.line, d.pos.col, d.name.clone())) {
                    continue;
                }
                let t = self.text_of(&d.file).unwrap_or_default();
                let kind: u32 = match d.kind { "fn" => 12, "method" => 6, "struct" => 23, "enum" => 10, "variant" => 22, "const" => 14, _ => 13 };
                out.push(obj([
                    ("name", d.name.as_str().into()),
                    ("kind", kind.into()),
                    ("containerName", d.owner.clone().unwrap_or_default().into()),
                    ("location", obj([("uri", to_uri(&d.file).into()), ("range", range(&t, d.pos, d.pos))])),
                ]));
            }
        }
        Json::Arr(out)
    }

    fn completion(&self, path: &str, (line, ch): (u32, u32)) -> Json {
        let Some(text) = self.docs.get(path) else { return Json::Null };
        let l = text.lines().nth(line as usize).unwrap_or("");
        let before: String = l.chars().take(char_col(l, ch) as usize - 1).collect();
        let word_start = before.trim_end_matches(|c: char| c.is_ascii_alphanumeric() || c == '_');
        let a = self.analyze(path);
        let decls = self.decls(&a.units);
        let mut items: Vec<(String, u32, String)> = vec![]; // label, kind, detail
        let kind_num = |k: &str| match k {
            "fn" => 3,
            "method" => 2,
            "field" => 5,
            "struct" => 22,
            "enum" => 13,
            "variant" => 20,
            "const" => 21,
            _ => 6,
        };
        if let Some(recv) = word_start.strip_suffix('.') {
            let q: String = recv.chars().rev().take_while(|c| c.is_ascii_alphanumeric() || *c == '_').collect::<Vec<_>>().into_iter().rev().collect();
            let is_module = a.units.iter().any(|u| u.name == q && !q.is_empty());
            let is_type = decls.iter().any(|d| d.name == q && matches!(d.kind, "struct" | "enum"));
            for d in &decls {
                let fits = if is_module {
                    d.module == q && d.owner.is_none()
                } else if is_type {
                    d.owner.as_deref() == Some(q.as_str()) && matches!(d.kind, "variant" | "fn")
                } else {
                    // a value: what the type checker said its type is, if it said
                    let ty = a.notes.iter().rev().find(|n| n.file == path && n.text.starts_with(&format!("{q}: "))).map(|n| n.text[q.len() + 2..].to_string());
                    match &ty {
                        Some(t) => d.owner.as_deref().is_some_and(|o| t.trim_end_matches('?') == o || t.ends_with(&format!(".{o}"))) && matches!(d.kind, "method" | "field"),
                        None => matches!(d.kind, "method" | "field"),
                    }
                };
                if fits {
                    items.push((d.name.clone(), kind_num(d.kind), d.sig.clone()));
                }
            }
            if !is_module && !is_type {
                let ty = a.notes.iter().rev().find(|n| n.file == path && n.text.starts_with(&format!("{q}: "))).map(|n| n.text[q.len() + 2..].to_string());
                let groups: Vec<&str> = match ty.as_deref() {
                    Some("str") => vec!["str"],
                    Some("float") => vec!["float"],
                    Some(t) if t.ends_with('?') => vec!["opt"],
                    Some(t) if t.starts_with('[') => vec!["list"],
                    Some(t) if t.starts_with('{') && t.contains(':') => vec!["map"],
                    Some(t) if t.starts_with('{') => vec!["set"],
                    Some(_) => vec![],
                    None => BUILTIN_METHODS.iter().map(|g| g.0).collect(),
                };
                for (g, ms) in BUILTIN_METHODS {
                    if groups.contains(g) {
                        items.extend(ms.iter().map(|m| (m.to_string(), 2, format!("{g} method"))));
                    }
                }
            }
        } else {
            let w = grammar::words();
            for kw in w.declare.iter().chain(&w.control).chain(&w.constants).filter(|k| k.is_ascii()) {
                items.push((kw.clone(), 14, "keyword".into()));
            }
            for b in w.builtins.iter().chain(&w.types) {
                items.push((b.clone(), 3, "builtin".into()));
            }
            for u in &a.units {
                if !u.name.is_empty() {
                    items.push((u.name.clone(), 9, format!("module {}", u.name)));
                }
            }
            for d in decls.iter().filter(|d| d.module.is_empty() && (d.owner.is_none() || d.kind == "variant")) {
                items.push((d.name.clone(), kind_num(d.kind), d.sig.clone()));
            }
            // locals the type checker saw in this file
            for n in a.notes.iter().filter(|n| n.file == path && n.pos.line <= line + 1) {
                let t = n.text.trim_start_matches("let ").trim_start_matches("var ");
                if let Some((name, ty)) = t.split_once(": ") {
                    if !name.contains(['.', ' ']) {
                        items.push((name.to_string(), 6, ty.to_string()));
                    }
                }
            }
        }
        let mut seen = HashSet::new();
        items.retain(|i| seen.insert(i.0.clone()));
        Json::Arr(items.into_iter().map(|(l, k, d)| obj([("label", l.into()), ("kind", k.into()), ("detail", d.into())])).collect())
    }

    fn symbols(&self, path: &str) -> Json {
        let a = self.analyze(path);
        let Some(text) = self.docs.get(path) else { return Json::Null };
        let decls = self.decls(&a.units);
        let kind = |k: &str| -> u32 {
            match k {
                "fn" => 12,
                "method" => 6,
                "struct" => 23,
                "enum" => 10,
                "variant" => 22,
                "const" => 14,
                _ => 8,
            }
        };
        let mine: Vec<&Decl> = decls.iter().filter(|d| d.file == path && d.kind != "field").collect();
        let sym = |d: &Decl, children: Vec<Json>| {
            let r = range(text, d.pos, Pos { line: d.pos.line, col: d.pos.col + 1 });
            obj([
                ("name", d.name.as_str().into()),
                ("detail", d.sig.lines().next().unwrap_or("").into()),
                ("kind", kind(d.kind).into()),
                ("range", r.clone()),
                ("selectionRange", r),
                ("children", Json::Arr(children)),
            ])
        };
        let mut out = vec![];
        for d in mine.iter().filter(|d| d.owner.is_none()) {
            let children: Vec<Json> = mine.iter().filter(|c| c.owner.as_deref() == Some(d.name.as_str())).map(|c| sym(c, vec![])).collect();
            out.push(sym(d, children));
        }
        Json::Arr(out)
    }

    fn format(&self, path: &str) -> Json {
        let Some(text) = self.docs.get(path) else { return Json::Null };
        let Ok(new) = fmt::format(text, None) else { return Json::Null };
        if new == *text {
            return Json::Arr(vec![]);
        }
        let lines = text.lines().count() as u32 + 1;
        let r = obj([
            ("start", obj([("line", 0u32.into()), ("character", 0u32.into())])),
            ("end", obj([("line", lines.into()), ("character", 0u32.into())])),
        ]);
        Json::Arr(vec![obj([("range", r), ("newText", new.into())])])
    }

    // ---- highlighting ----

    fn semantic_tokens(&mut self, path: &str) -> Json {
        let Some(text) = self.docs.get(path).cloned() else { return Json::Null };
        let Ok(toks) = lexer::lex(&text) else {
            // mid-edit (say, an unterminated string): keep the last good colors
            return self.last_tokens.get(path).cloned().unwrap_or(Json::Null);
        };
        let a = self.analyze(path);
        let decls = self.decls(&a.units);
        let names = |kinds: &[&str]| -> HashSet<String> { decls.iter().filter(|d| kinds.contains(&d.kind)).map(|d| d.name.clone()).collect() };
        let (types, enums, variants, funcs) = (names(&["struct"]), names(&["enum"]), names(&["variant"]), names(&["fn"]));
        let modules: HashSet<&str> = a.units.iter().map(|u| u.name.as_str()).filter(|n| !n.is_empty()).collect();
        let w = grammar::words();
        let builtins: HashSet<&str> = w.builtins.iter().map(String::as_str).collect();
        let prim: HashSet<&str> = w.types.iter().map(String::as_str).collect();
        let lines: Vec<&str> = text.lines().collect();

        // (line, utf16 col, utf16 len, type, modifiers)
        let mut out: Vec<(u32, u32, u32, u32, u32)> = vec![];
        let cs: Vec<char> = text.chars().collect();
        for (start, end, line) in comments(&cs) {
            let l = lines.get(line as usize - 1).copied().unwrap_or("");
            let col = cs[..start].iter().rev().take_while(|c| **c != '\n').count() as u32 + 1;
            let len: u32 = cs[start..end].iter().map(|c| c.len_utf16() as u32).sum();
            out.push((line - 1, utf16_col(l, col), len, tt("comment"), 0));
        }
        let mut emit = |pos: Pos, start: usize, end: usize, ty: &str, mods: u32| {
            let len: u32 = cs[start..end.min(cs.len())].iter().map(|c| c.len_utf16() as u32).sum();
            if len > 0 {
                let l = lines.get(pos.line as usize - 1).copied().unwrap_or("");
                out.push((pos.line - 1, utf16_col(l, pos.col), len, tt(ty), mods));
            }
        };
        let flat = flatten_with_strings(&toks, &cs);
        for (k, t) in flat.iter().enumerate() {
            let prev = k.checked_sub(1).map(|i| &flat[i].tok);
            let next = flat.get(k + 1).map(|t| &t.tok);
            let (ty, mods) = match &t.tok {
                Tok::Str(_) | Tok::Interp(_) => ("string", 0),
                Tok::Int(_) | Tok::Float(_) => ("number", 0),
                // keywords are left to the grammar, which tells declarations (`struct`) from control flow (`if`)
                tok if WORDS.iter().any(|w| w.1 == *tok) || lexer::EMOJI.iter().any(|e| e.0 == *tok) => continue,
                Tok::Arrow | Tok::FatArrow | Tok::Question | Tok::QuestionQuestion | Tok::Bang | Tok::Pipe | Tok::Eq | Tok::Ne
                | Tok::Lt | Tok::Le | Tok::Gt | Tok::Ge | Tok::AndAnd | Tok::OrOr | Tok::Plus | Tok::Minus | Tok::Times
                | Tok::Slash | Tok::Percent | Tok::Assign | Tok::PlusEq | Tok::MinusEq | Tok::TimesEq | Tok::SlashEq | Tok::DotDot => ("operator", 0),
                Tok::Ident(n) => {
                    let decl = matches!(prev, Some(Tok::Fn | Tok::Struct | Tok::Enum | Tok::Const)) as u32;
                    let call = next == Some(&Tok::LParen);
                    match n.as_str() {
                        "true" | "false" | "none" | "self" => continue,
                        _ if prev == Some(&Tok::Dot) && variants.contains(n) => ("enumMember", 0),
                        _ if prev == Some(&Tok::Dot) && call => ("method", 0),
                        _ if prev == Some(&Tok::Dot) && (types.contains(n) || enums.contains(n)) => (if enums.contains(n) { "enum" } else { "struct" }, 0),
                        _ if prev == Some(&Tok::Dot) && funcs.contains(n) => ("function", 0),
                        _ if prev == Some(&Tok::Dot) => ("property", 0),
                        _ if prim.contains(n.as_str()) && !call => ("type", 2),
                        _ if enums.contains(n) => ("enum", decl),
                        _ if types.contains(n) => ("struct", decl),
                        _ if variants.contains(n) => ("enumMember", 0),
                        _ if modules.contains(n.as_str()) => ("namespace", 0),
                        _ if call && builtins.contains(n.as_str()) => ("function", 2),
                        _ if call || prev == Some(&Tok::Fn) => ("function", decl),
                        _ if n.starts_with(|c: char| c.is_ascii_uppercase()) => ("type", 0),
                        _ => ("variable", 0),
                    }
                }
                _ => continue,
            };
            emit(t.pos, t.start, t.end, ty, mods);
        }
        out.sort();
        let mut data: Vec<u32> = vec![];
        let (mut pl, mut pc) = (0, 0);
        for (l, c, len, ty, m) in out {
            let dc = if l == pl { c - pc } else { c };
            data.extend([l - pl, dc, len, ty, m]);
            (pl, pc) = (l, c);
        }
        let r = obj([("data", data.into())]);
        self.last_tokens.insert(path.to_string(), r.clone());
        r
    }
}

/// Tokens, with the code inside `${...}` spliced in (strings stay whole tokens).
fn flatten(toks: &[Token]) -> Vec<Token> {
    let mut out = vec![];
    for t in toks {
        out.push(t.clone());
        if let Tok::Interp(parts) = &t.tok {
            for p in parts {
                if let Part::Code(inner, _) = p {
                    out.extend(flatten(inner));
                }
            }
        }
    }
    out
}

/// Like `flatten`, but an interpolated string becomes string pieces around its code tokens
/// (semantic tokens may not overlap).
fn flatten_with_strings(toks: &[Token], cs: &[char]) -> Vec<Token> {
    let mut out = vec![];
    for t in toks {
        let Tok::Interp(parts) = &t.tok else {
            out.push(t.clone());
            continue;
        };
        let mut at = t.start; // start of the string piece still to emit
        let piece = |from: usize, to: usize, out: &mut Vec<Token>| {
            if to > from {
                let line = cs[..from].iter().filter(|c| **c == '\n').count() as u32 + 1;
                let col = cs[..from].iter().rev().take_while(|c| **c != '\n').count() as u32 + 1;
                out.push(Token { tok: Tok::Str(String::new()), pos: Pos { line, col }, start: from, end: to });
            }
        };
        for p in parts {
            let Part::Code(inner, _) = p else { continue };
            let (Some(first), Some(last)) = (inner.iter().find(|x| x.tok != Tok::Newline), inner.iter().rev().find(|x| x.tok != Tok::Eof && x.tok != Tok::Newline)) else { continue };
            let mut open = first.start;
            while open > at && !(cs[open - 1] == '{' && open >= 2 && cs[open - 2] == '$') { open -= 1 }
            piece(at, open, &mut out);
            out.extend(flatten_with_strings(inner, cs).into_iter().filter(|x| x.tok != Tok::Eof));
            let mut close = last.end;
            while close < t.end && cs[close] != '}' { close += 1 }
            at = close;
        }
        piece(at, t.end, &mut out);
    }
    out
}

/// `//` comments: (start, end, line), skipping `//` inside strings.
fn comments(cs: &[char]) -> Vec<(usize, usize, u32)> {
    let (mut out, mut line, mut i, mut in_str) = (vec![], 1, 0, false);
    while i < cs.len() {
        match cs[i] {
            '\n' => {
                line += 1;
                in_str = false;
            }
            '\\' if in_str => i += 1,
            '"' => in_str = !in_str,
            '/' if !in_str && cs.get(i + 1) == Some(&'/') => {
                let start = i;
                while i < cs.len() && cs[i] != '\n' { i += 1 }
                out.push((start, i, line));
                continue;
            }
            _ => {}
        }
        i += 1;
    }
    out
}

/// The token under a (0-based line, UTF-16 column) cursor; at a token's end counts too.
fn token_at(text: &str, toks: &[Token], line: u32, ch: u32) -> Option<usize> {
    let l = text.lines().nth(line as usize)?;
    let col = char_col(l, ch);
    let hit = |t: &Token, slack: u32| t.pos.line == line + 1 && t.pos.col <= col && col < t.pos.col + (t.end - t.start) as u32 + slack;
    toks.iter().position(|t| matches!(t.tok, Tok::Ident(_)) && hit(t, 1)).or_else(|| toks.iter().position(|t| hit(t, 0)))
}

/// Errors about calls point at the `(`; underline the name before it instead.
fn name_before_paren(text: &str, p: Pos) -> Pos {
    let line: Vec<char> = text.lines().nth(p.line as usize - 1).unwrap_or("").chars().collect();
    let i = p.col as usize - 1;
    if line.get(i) != Some(&'(') {
        return p;
    }
    let mut j = i;
    while j > 0 && (line[j - 1].is_ascii_alphanumeric() || line[j - 1] == '_') {
        j -= 1;
    }
    if j == i { p } else { Pos { line: p.line, col: j as u32 + 1 } }
}

/// Where the token starting at `p` ends (for underlining an error).
fn token_end(text: &str, p: Pos) -> Pos {
    let line = text.lines().nth(p.line as usize - 1).unwrap_or("");
    let rest: Vec<char> = line.chars().skip(p.col as usize - 1).collect();
    let n = match rest.first() {
        Some(c) if c.is_ascii_alphanumeric() || *c == '_' => rest.iter().take_while(|c| c.is_ascii_alphanumeric() || **c == '_').count(),
        Some(_) => 1,
        None => 0,
    };
    Pos { line: p.line, col: p.col + n as u32 }
}

/// The `//` comment lines right above a declaration.
fn doc_above(lines: &[&str], line: u32) -> String {
    let mut doc = vec![];
    let mut i = line as usize - 1;
    while i > 0 {
        i -= 1;
        match lines[i].trim().strip_prefix("//") {
            Some(c) => doc.push(c.strip_prefix(' ').unwrap_or(c).to_string()),
            None => break,
        }
    }
    doc.reverse();
    doc.join("\n")
}

/// A declaration's first line, without its `{`.
fn line_sig(lines: &[&str], p: Pos) -> String {
    let l = lines.get(p.line as usize - 1).copied().unwrap_or("");
    let s: String = l.chars().skip(p.col as usize - 1).collect();
    s.trim().trim_end_matches('{').trim_end_matches('⭐').trim().to_string()
}

/// A struct or enum: its lines up to the closing brace (methods left out).
fn block_sig(lines: &[&str], p: Pos) -> String {
    let mut out = vec![];
    let mut depth = 0;
    for l in lines.iter().skip(p.line as usize - 1).take(60) {
        let t = l.trim();
        if depth == 1 && t.starts_with("fn ") {
            out.push("    ...".to_string());
            break;
        }
        out.push(if out.is_empty() { t.to_string() } else { format!("    {t}") });
        depth += l.matches('{').count() as i32 - l.matches('}').count() as i32;
        if depth <= 0 {
            break;
        }
    }
    if out.last().is_some_and(|l| l == "    ...") {
        out.push("}".into());
    }
    if let Some(last) = out.last_mut() {
        if last.trim() == "}" {
            *last = "}".into();
        }
    }
    out.join("\n")
}

/// `a: int, f: fn(int, str) -> bool` split on the commas that aren't nested.
fn split_top(s: &str) -> Vec<String> {
    let (mut out, mut cur, mut depth) = (vec![], String::new(), 0);
    for c in s.chars() {
        match c {
            '(' | '[' | '{' => depth += 1,
            ')' | ']' | '}' => depth -= 1,
            ',' if depth == 0 => {
                out.push(std::mem::take(&mut cur));
                continue;
            }
            _ => {}
        }
        cur.push(c);
    }
    if !cur.trim().is_empty() {
        out.push(cur);
    }
    out
}
