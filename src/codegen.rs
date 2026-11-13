//! Type-checks and lowers modules to textual LLVM IR in one walk.
//!
//! Every value is a scalar: `int` (i64), `float` (double), `bool` (i1), or a pointer into the GC heap
//! (`str`, lists, maps, sets, struct objects, closures). Maps and sets store keys and values as 8-byte slots. A result `T!` is the small LLVM struct `{ i1 is_err, T value, ptr message }`.
//! Locals captured by a lambda live in a heap box so the lambda and the function share them.

use crate::lexer::{Pos, Tok};
use crate::parser::{Arm, Body, Cond, Expr, ExprKind, Func, Lambda, Module, Pat, PatKind, Stmt, Type};
use std::collections::{HashMap, HashSet};
use std::fmt::Write;
use std::mem;

mod fromjson;
mod generics;
mod helpers;
mod jsx;
mod patterns;

use generics::{prim_name, short_name, GDef, GFn, GType, Pending, TraitInfo};

type R<T> = Result<T, (Pos, String)>;

pub struct Unit {
    pub name: String, // "" for the main file
    pub file: String,
    pub module: Module,
}

/// The function that computes parameter `i`'s default, for the function `sym` (`@"st.f"` -> `@"def.st.f.1"`).
fn default_sym(sym: &str, i: usize) -> String {
    format!("@\"def.{}.{i}\"", sym.trim_start_matches('@').trim_matches('"'))
}

/// The function that computes field `f`'s default, for a struct or `Enum::Variant`.
fn field_default_sym(dkey: &str, f: &str) -> String {
    format!("@\"fdef.{dkey}.{f}\"")
}

pub const RESERVED: &[&str] = &[
    "print", "println", "str", "int", "float", "env", "panic", "ok", "err", "bool", "void", "true", "false", "min", "max",
    "abs", "some", "none", "to_json", "self", "sleep", "now_ms", "url_encode",
    "url_decode", "args", "read_line", "exit",
];

/// Signatures of the newer builtins, for hover.
const BUILTIN_SIGS: &[(&str, &str)] = &[
    ("sleep", "fn sleep(ms: int)"),
    ("now_ms", "fn now_ms() -> int"),
    ("url_encode", "fn url_encode(s: str) -> str"),
    ("url_decode", "fn url_decode(s: str) -> str"),
    ("args", "fn args() -> [str]"),
    ("read_line", "fn read_line() -> str?"),
    ("exit", "fn exit(code: int)"),
];

const RUNTIME: &str = r#"%st.vec = type { i64, i64, ptr }
declare void @st_init()
declare void @st_panic(ptr) noreturn cold
declare void @st_panic_msg(ptr, ptr) noreturn cold
declare void @st_fail(ptr) noreturn cold
declare ptr @st_alloc(i64)
declare ptr @st_vec_new(i64, i64, i64)
declare void @st_vec_grow(ptr, i64)
declare void @st_print_s(ptr)
declare void @st_nl()
declare i64 @st_strlen(ptr)
declare zeroext i1 @st_streq(ptr, ptr)
declare ptr @st_concat(ptr, ptr)
declare ptr @st_html_escape(ptr)
declare i64 @st_on(ptr, i64)
declare ptr @st_hook()
declare ptr @st_itoa(i64)
declare ptr @st_parse_int(ptr, ptr)
declare ptr @st_env(ptr)
declare ptr @st_url_encode(ptr)
declare ptr @st_url_decode(ptr)
declare void @st_sleep(i64)
declare i64 @st_now_ms()
declare void @st_set_args(i32, ptr)
declare ptr @st_args()
declare ptr @st_read_line()
declare void @st_exit(i64) noreturn
declare ptr @st_slice(ptr, i64, i64, ptr)
declare i64 @st_find(ptr, ptr)
declare ptr @st_split(ptr, ptr)
declare ptr @st_trim(ptr)
declare zeroext i1 @st_starts(ptr, ptr)
declare zeroext i1 @st_ends(ptr, ptr)
declare zeroext i1 @st_contains(ptr, ptr)
declare ptr @st_lower(ptr)
declare ptr @st_upper(ptr)
declare ptr @st_replace(ptr, ptr, ptr)
declare ptr @st_join(ptr, ptr)
declare ptr @st_ftoa(double)
declare ptr @st_parse_float(ptr, ptr)
declare ptr @st_quote(ptr)
declare ptr @st_json_quote(ptr)
declare ptr @st_json_num(double)
declare ptr @st_char_at(ptr, i64, ptr)
declare ptr @st_repeat(ptr, i64)
declare ptr @st_chars(ptr)
declare ptr @st_lines(ptr)
declare ptr @st_trim_start(ptr)
declare ptr @st_trim_end(ptr)
declare i64 @st_count(ptr, ptr)
declare ptr @st_reverse(ptr)
declare i64 @st_strcmp(ptr, ptr)
declare void @st_vec_push_str(ptr, ptr)
declare ptr @st_vec_slice(ptr, i64, i64, i64, i64, ptr)
declare void @st_vec_insert(ptr, i64, i64, ptr)
declare void @st_vec_remove(ptr, i64, i64)
declare void @st_vec_reverse(ptr, i64)
declare void @st_vec_sort(ptr, i64)
declare ptr @st_map_new(i64)
declare i64 @st_map_len(ptr)
declare void @st_map_set(ptr, i64, i64)
declare zeroext i1 @st_map_get(ptr, i64, ptr)
declare zeroext i1 @st_map_remove(ptr, i64)
declare ptr @st_map_list(ptr, i64, i64, i64)
declare double @llvm.floor.f64(double)
declare double @llvm.ceil.f64(double)
declare double @llvm.round.f64(double)
declare double @llvm.sqrt.f64(double)
declare double @llvm.fabs.f64(double)
declare i64 @llvm.abs.i64(i64, i1)
declare i64 @llvm.fptosi.sat.i64.f64(double)
@.true = private unnamed_addr constant [5 x i8] c"true\00"
@.false = private unnamed_addr constant [6 x i8] c"false\00"
"#;

/// str methods backed by the C runtime: name -> (C function, params, result, takes a panic location)
fn str_method(name: &str) -> Option<(&'static str, Vec<Type>, Type, bool)> {
    use Type::*;
    Some(match name {
        "len" => ("st_strlen", vec![], Int, false),
        "split" => ("st_split", vec![Str], List(Box::new(Str)), false),
        "find" => ("st_find", vec![Str], Int, false),
        "slice" => ("st_slice", vec![Int, Int], Str, true),
        "trim" => ("st_trim", vec![], Str, false),
        "starts_with" => ("st_starts", vec![Str], Bool, false),
        "ends_with" => ("st_ends", vec![Str], Bool, false),
        "contains" => ("st_contains", vec![Str], Bool, false),
        "lower" => ("st_lower", vec![], Str, false),
        "upper" => ("st_upper", vec![], Str, false),
        "replace" => ("st_replace", vec![Str, Str], Str, false),
        "repeat" => ("st_repeat", vec![Int], Str, false),
        "chars" => ("st_chars", vec![], List(Box::new(Str)), false),
        "lines" => ("st_lines", vec![], List(Box::new(Str)), false),
        "trim_start" => ("st_trim_start", vec![], Str, false),
        "trim_end" => ("st_trim_end", vec![], Str, false),
        "count" => ("st_count", vec![Str], Int, false),
        "reverse" => ("st_reverse", vec![], Str, false),
        _ => return None,
    })
}

fn sig_text(name: &str, s: &Sig) -> String {
    let ps: Vec<String> = s.params.iter().map(|p| p.to_string()).collect();
    let ret = if s.ret == Type::Void { String::new() } else { format!(" -> {}", s.ret) };
    format!("fn {name}({}){ret}", ps.join(", "))
}

fn err<T>(pos: Pos, m: impl Into<String>) -> R<T> {
    Err((pos, m.into()))
}

fn ll(t: &Type) -> String {
    match t {
        Type::Int => "i64".into(),
        Type::Float => "double".into(),
        Type::Bool => "i1".into(),
        Type::Void => "void".into(),
        Type::Str | Type::List(_) | Type::Map(..) | Type::Set(_) | Type::Struct(_) | Type::Enum(_) | Type::Fn(..) | Type::Node | Type::Generic(..) => "ptr".into(),
        Type::Result(t) => format!("{{ i1, {}, ptr }}", if **t == Type::Void { "i1".into() } else { ll(t) }),
        Type::Opt(t) => format!("{{ i1, {} }}", ll(t)),
    }
}

/// Element types whose lists hold no pointers (the GC needn't scan them).
fn atomic(t: &Type) -> i64 {
    matches!(t, Type::Int | Type::Float | Type::Bool) as i64
}

fn float_lit(x: f64) -> String {
    format!("0x{:016X}", x.to_bits())
}

fn check_key(t: &Type, pos: Pos) -> R<()> {
    if matches!(t, Type::Int | Type::Str | Type::Bool) { Ok(()) } else { err(pos, format!("map keys and set items must be int, str or bool, not {t}")) }
}

fn expect_ty(want: &Type, got: &Type, pos: Pos) -> R<()> {
    if want == got { Ok(()) } else { err(pos, format!("expected {want}, found {got}")) }
}

/// For `[]`, lambdas and struct literals, a `T!` context means a `T` is welcome too.
fn peel(want: Option<&Type>) -> Option<&Type> {
    match want {
        Some(Type::Result(t)) => Some(t),
        w => w,
    }
}

/// Like `peel`, and a `T?` context also welcomes a `T` (for `.Variant` and literals).
fn peel_all(want: Option<&Type>) -> Option<&Type> {
    match want {
        Some(Type::Result(t) | Type::Opt(t)) => peel_all(Some(t)),
        w => w,
    }
}

/// A map value or set item has to fit an 8-byte slot.
fn fits_slot(t: &Type) -> bool {
    !matches!(t, Type::Void | Type::Result(_) | Type::Opt(_))
}

// ---- which names do lambdas use? (those locals get boxed) ----

fn names_stmts(ss: &[Stmt], inl: bool, out: &mut HashSet<String>) {
    for s in ss {
        match s {
            Stmt::Let { value, .. } => names_expr(value, inl, out),
            Stmt::Assign(a, b) => {
                names_expr(a, inl, out);
                names_expr(b, inl, out);
            }
            Stmt::Expr(e) | Stmt::Return(Some(e), _) => names_expr(e, inl, out),
            Stmt::LetElse { value, els, .. } => {
                names_expr(value, inl, out);
                if let Some(ss) = els { names_stmts(ss, inl, out) }
            }
            Stmt::If(c, a, b) => {
                names_cond(c, inl, out);
                names_stmts(a, inl, out);
                names_stmts(b, inl, out);
            }
            Stmt::While(c, b) => {
                names_cond(c, inl, out);
                names_stmts(b, inl, out);
            }
            Stmt::For { iter, end, body, .. } => {
                names_expr(iter, inl, out);
                if let Some(e) = end { names_expr(e, inl, out) }
                names_stmts(body, inl, out);
            }
            Stmt::Return(None, _) | Stmt::Break(_) | Stmt::Continue(_) => {}
        }
    }
}

fn names_cond(c: &Cond, inl: bool, out: &mut HashSet<String>) {
    match c {
        Cond::Expr(e) | Cond::Let(_, e) => names_expr(e, inl, out),
    }
}

fn names_body(b: &Body, inl: bool, out: &mut HashSet<String>) {
    match b {
        Body::Expr(e) => names_expr(e, inl, out),
        Body::Block(ss) => names_stmts(ss, inl, out),
    }
}

fn names_expr(e: &Expr, inl: bool, out: &mut HashSet<String>) {
    match &e.kind {
        ExprKind::Var(n) => {
            if inl { out.insert(n.clone()); }
        }
        ExprKind::Int(_) | ExprKind::Float(_) | ExprKind::Bool(_) | ExprKind::Str(_) | ExprKind::Member(_) => {}
        ExprKind::If(c, a, b) => {
            names_cond(c, inl, out);
            names_stmts(a, inl, out);
            names_stmts(b, inl, out);
        }
        ExprKind::Unary(_, x) | ExprKind::Field(x, _) | ExprKind::Try(x) => names_expr(x, inl, out),
        ExprKind::Binary(_, a, b) | ExprKind::Index(a, b) | ExprKind::CatchValue(a, b) | ExprKind::Chain(_, a, b) => {
            names_expr(a, inl, out);
            names_expr(b, inl, out);
        }
        ExprKind::Call(c, args) => {
            names_expr(c, inl, out);
            args.iter().for_each(|a| names_expr(a, inl, out));
        }
        ExprKind::List(xs) | ExprKind::Set(xs) => xs.iter().for_each(|a| names_expr(a, inl, out)),
        ExprKind::Map(xs) => xs.iter().for_each(|(k, v)| {
            names_expr(k, inl, out);
            names_expr(v, inl, out);
        }),
        ExprKind::StructLit(_, fs) => fs.iter().for_each(|(_, a)| names_expr(a, inl, out)),
        ExprKind::Lambda(l) => names_body(&l.body, true, out),
        ExprKind::CatchBlock(x, _, ss) => {
            names_expr(x, inl, out);
            names_stmts(ss, inl, out);
        }
        ExprKind::Element(el) => names_element(el, inl, out),
        ExprKind::JsxPush(cs) => names_children(cs, inl, out),
        ExprKind::Match(s, arms) => {
            names_expr(s, inl, out);
            for a in arms.iter() {
                if let Some(g) = &a.guard { names_expr(g, inl, out) }
                names_body(&a.body, inl, out);
            }
        }
    }
}

fn is_call_to(e: &Expr, name: &str) -> bool {
    matches!(&e.kind, ExprKind::Call(c, _) if matches!(&c.kind, ExprKind::Var(n) if n == name))
}

fn names_element(el: &crate::parser::Element, inl: bool, out: &mut HashSet<String>) {
    if el.tag.starts_with(|c: char| c.is_ascii_uppercase()) && inl {
        out.insert(el.tag.clone());
    }
    for a in &el.attrs {
        if let Some(v) = &a.value { names_expr(v, inl, out) }
    }
    names_children(&el.children, inl, out);
}

fn names_children(cs: &[crate::parser::Child], inl: bool, out: &mut HashSet<String>) {
    use crate::parser::Child;
    for c in cs {
        match c {
            Child::Text(e) | Child::Value(e) => names_expr(e, inl, out),
            Child::Elem(el) => names_element(el, inl, out),
            Child::For(s) | Child::If(s) => names_stmts(std::slice::from_ref(&**s), inl, out),
        }
    }
}

#[derive(Clone)]
struct Val {
    v: String,
    ty: Type,
}

fn val(v: impl Into<String>, ty: Type) -> Val {
    Val { v: v.into(), ty }
}

fn void() -> Val {
    val("", Type::Void)
}

#[derive(Clone)]
struct Var {
    addr: String,
    ty: Type,
    mutable: bool,
}

#[derive(Clone)]
struct Sig {
    params: Vec<Type>,
    names: Vec<String>, // parameter names (for JSX props); empty for externs
    ret: Type,
    sym: String,
    is_extern: bool,
    defaults: Vec<Option<Expr>>, // per parameter; each one is compiled into `default_sym(sym, i)`
    module: String,              // where the defaults are evaluated
}

/// Collects the values of the branches of a `match` that reach its end.
#[derive(Default)]
struct Join {
    slot: Option<(String, Type)>,
    mixed: bool, // some live branch has no value or a different type
    live: bool,
    result_at: Option<Pos>, // a branch whose value is a result (must not be dropped silently)
}

#[derive(Clone)]
struct VariantInfo {
    name: String,
    fields: Vec<(String, Type)>,
    braces: bool,
    named: bool, // the fields have real names (not "0", "1", ...)
}

/// What a `Name { ... }` literal builds.
enum Lit {
    Struct(String),
    Variant(String, usize),
    GVariant(String, String), // a variant of a generic enum (the instance is still to be inferred)
}

#[derive(Default)]
struct FnState {
    allocas: Vec<String>,
    body: Vec<String>,
    open: bool, // the current block can still take instructions (= is reachable)
    cur: String,
    scopes: Vec<HashMap<String, Var>>,
    ret: Type,
    loops: Vec<(String, String, bool)>, // (break label, continue label, has a break)
    captured: HashSet<String>,
}

#[derive(Default)]
struct Gen {
    files: HashMap<String, String>,
    imports: HashMap<String, HashSet<String>>,
    structs: HashMap<String, Vec<(String, Type)>>,
    enums: HashMap<String, Vec<VariantInfo>>,
    defaults: HashMap<String, (String, Vec<(String, Expr)>)>, // struct or `Enum::Variant` -> (module, field defaults), see `field_default_sym`
    default_fns: HashSet<String>, // the default-value functions made so far
    consts: HashMap<String, Type>,
    const_order: Vec<String>,
    statics: HashSet<String>, // `Type::name` functions without `self`
    funcs: HashMap<String, Sig>,
    module: String,
    decls: String,
    code: String,
    globals: String,
    nstr: usize,
    n: usize,
    wrappers: Vec<String>,
    shown: HashSet<String>, // types whose `str()` helper is emitted
    f: FnState,
    notes: Vec<Note>,
    // generics
    tparams: HashMap<String, Type>, // the type parameters bound in the instance being generated
    gtypes: HashMap<String, GType>,
    gfns: HashMap<String, GFn>,
    inst_of: HashMap<String, (String, Vec<Type>)>, // instance key -> (template, type arguments)
    pending: Vec<Pending>,
    traits: HashMap<String, TraitInfo>,
    impls_of: HashSet<(String, String)>, // (type key, trait key)
    impl_methods: Vec<(String, String, Vec<Func>)>, // (module, type key, methods incl. trait defaults)
    jsx: Vec<jsx::JsxBuf>, // elements being built
    web: bool,             // compiling for the browser (WebAssembly)
    kernel: bool,          // compiling for bare metal (stellang --kernel)
}

/// What the type checker learned about a spot in the source (for editor hovers).
#[derive(Clone, Debug)]
pub struct Note {
    pub file: String,
    pub pos: Pos,
    pub text: String,
}

pub fn compile(units: &[Unit]) -> Result<String, (String, Pos, String)> {
    check(units, true).0
}

/// Compile for the browser (WebAssembly): the entry point is `st_start`, event handlers are kept.
pub fn compile_web(units: &[Unit]) -> Result<String, (String, Pos, String)> {
    let mut g = Gen { web: true, ..Gen::default() };
    for u in units {
        g.files.insert(u.name.clone(), u.file.clone());
        g.imports.insert(u.name.clone(), u.module.imports.iter().map(|i| i.0.clone()).collect());
    }
    let r = g.run(units, true);
    r.map_err(|(p, m)| (g.files[&g.module].clone(), p, m))
}

/// Compile for bare metal (`stellang --kernel`): like a native program, minus the host-only attributes.
pub fn compile_kernel(units: &[Unit]) -> Result<String, (String, Pos, String)> {
    let mut g = Gen { kernel: true, ..Gen::default() };
    for u in units {
        g.files.insert(u.name.clone(), u.file.clone());
        g.imports.insert(u.name.clone(), u.module.imports.iter().map(|i| i.0.clone()).collect());
    }
    let r = g.run(units, true);
    r.map_err(|(p, m)| (g.files[&g.module].clone(), p, m))
}

/// Type-check (and generate code for) `units`; also returns the notes for editor hovers.
/// Without `require_main`, a file without `main` is fine (a module being edited).
pub fn check(units: &[Unit], require_main: bool) -> (Result<String, (String, Pos, String)>, Vec<Note>) {
    let mut g = Gen::default();
    for u in units {
        g.files.insert(u.name.clone(), u.file.clone());
        g.imports.insert(u.name.clone(), u.module.imports.iter().map(|i| i.0.clone()).collect());
    }
    let need_main = require_main || units[0].module.funcs.iter().any(|f| f.name == "main");
    let r = g.run(units, need_main);
    let r = r.map_err(|(p, m)| (g.files[&g.module].clone(), p, m));
    (r, mem::take(&mut g.notes))
}

impl Gen {
    fn key(&self, name: &str) -> String {
        if self.module.is_empty() { name.into() } else { format!("{}.{name}", self.module) }
    }

    fn is_module(&self, name: &str) -> bool {
        self.find(name).is_none() && self.imports[&self.module].contains(name)
    }

    fn resolve(&mut self, t: &Type, pos: Pos) -> R<Type> {
        Ok(match t {
            Type::Struct(n) | Type::Enum(n) if self.tparams.contains_key(n) => self.tparams[n].clone(),
            Type::Generic(n, args) => {
                let Some(tk) = self.template_key(n) else {
                    let plain = self.resolve(&Type::Struct(n.clone()), pos)?;
                    return err(pos, format!("`{plain}` isn't generic; write just `{n}`"));
                };
                let args = args.iter().map(|a| self.resolve(a, pos)).collect::<R<Vec<_>>>()?;
                self.instantiate_type(&tk, args, pos)?
            }
            Type::Struct(n) | Type::Enum(n) if self.template_key(n).is_some() => {
                // `Box` inside Box's own methods means `Box<T>`
                let tk = self.template_key(n).unwrap();
                let ps = self.gtypes[&tk].params.clone();
                if !ps.iter().all(|p| self.tparams.contains_key(&p.name)) {
                    let names: Vec<&str> = ps.iter().map(|p| p.name.as_str()).collect();
                    return err(pos, format!("`{n}` needs type arguments, like `{n}<{}>`", names.join(", ")));
                }
                let args = ps.iter().map(|p| self.tparams[&p.name].clone()).collect();
                self.instantiate_type(&tk, args, pos)?
            }
            Type::Struct(n) | Type::Enum(n) => {
                let k = match n.split_once('.') {
                    Some((m, s)) if self.imports[&self.module].contains(m) => format!("{m}.{s}"),
                    Some((m, _)) => return err(pos, format!("unknown module `{m}` (add `import {m}`)")),
                    None => self.key(n),
                };
                if self.structs.contains_key(&k) {
                    Type::Struct(k)
                } else if self.enums.contains_key(&k) {
                    Type::Enum(k)
                } else {
                    return err(pos, format!("unknown type `{n}`"));
                }
            }
            Type::List(e) => Type::List(Box::new(self.resolve(e, pos)?)),
            Type::Set(e) => Type::Set(Box::new(self.resolve(e, pos)?)),
            Type::Map(k, v) => {
                let v = self.resolve(v, pos)?;
                if !fits_slot(&v) {
                    return err(pos, format!("a map can't hold {v} (put it in a struct)"));
                }
                Type::Map(Box::new(self.resolve(k, pos)?), Box::new(v))
            }
            Type::Opt(e) => {
                let e = self.resolve(e, pos)?;
                if matches!(e, Type::Void | Type::Opt(_) | Type::Result(_)) {
                    return err(pos, format!("{e}? isn't a type"));
                }
                Type::Opt(Box::new(e))
            }
            Type::Result(e) => Type::Result(Box::new(self.resolve(e, pos)?)),
            Type::Fn(ps, r) => Type::Fn(ps.iter().map(|p| self.resolve(p, pos)).collect::<R<_>>()?, Box::new(self.resolve(r, pos)?)),
            t => t.clone(),
        })
    }

    fn sig(&mut self, f: &Func, self_ty: Option<&Type>, sym: String) -> R<Sig> {
        let mut params = vec![];
        for (i, (n, t)) in f.params.iter().enumerate() {
            params.push(match (t, self_ty) {
                (None, Some(s)) if i == 0 => s.clone(),
                (None, _) => return err(f.pos, format!("parameter `{n}` needs a type, like `{n}: int`")),
                (Some(t), _) => self.resolve(t, f.pos)?,
            });
        }
        let defaults = f.defaults.clone();
        Ok(Sig { params, names: f.params.iter().map(|p| p.0.clone()).collect(), ret: self.resolve(&f.ret, f.pos)?, sym, is_extern: false, defaults, module: self.module.clone() })
    }

    fn type_of_key(&self, k: &str) -> Type {
        if self.enums.contains_key(k) { Type::Enum(k.into()) } else { Type::Struct(k.into()) }
    }

    /// `Shape` or `geo.Shape` written as an expression: the type's key.
    fn type_path(&self, e: &Expr) -> Option<String> {
        let k = match &e.kind {
            ExprKind::Var(n) if self.find(n).is_none() => self.key(n),
            ExprKind::Field(m, n) => match &m.kind {
                ExprKind::Var(m) if self.is_module(m) => format!("{m}.{n}"),
                _ => return None,
            },
            _ => return None,
        };
        (self.structs.contains_key(&k) || self.enums.contains_key(&k) || self.gtypes.contains_key(&k)).then_some(k)
    }

    fn add_fn(&mut self, key: String, sig: Sig, pos: Pos, name: &str) -> R<()> {
        if RESERVED.contains(&name) || self.funcs.contains_key(&key) || self.gfns.contains_key(&key) {
            return err(pos, format!("`{name}` is already defined"));
        }
        self.funcs.insert(key, sig);
        Ok(())
    }

    /// For completion: the type a `.Variant` shorthand is expected to have.
    fn probe_want(&mut self, pos: Pos, want: Option<&Type>) {
        if let Some(t) = peel_all(want) {
            self.note(pos, format!("@want {t}"));
        }
    }

    fn note(&mut self, pos: Pos, text: String) {
        let file = self.files[&self.module].clone();
        self.notes.push(Note { file, pos, text });
    }

    fn run(&mut self, units: &[Unit], need_main: bool) -> R<String> {
        for u in units {
            self.module = u.name.clone();
            let names = u.module.structs.iter().map(|s| (&s.name, s.pos)).chain(u.module.enums.iter().map(|e| (&e.name, e.pos)));
            for (name, pos) in names {
                let k = self.key(name);
                if RESERVED.contains(&name.as_str()) || self.structs.contains_key(&k) || self.enums.contains_key(&k) || self.gtypes.contains_key(&k) || name == "Node" {
                    return err(pos, format!("`{name}` is already defined"));
                }
                let module = u.name.clone();
                if let Some(s) = u.module.structs.iter().find(|s| s.name == *name) {
                    if !s.tparams.is_empty() {
                        let g = GType { module, params: s.tparams.clone(), def: GDef::Struct(s.clone()), methods: vec![], traits: vec![] };
                        self.gtypes.insert(k, g);
                    } else {
                        self.structs.insert(k, vec![]);
                    }
                } else {
                    let e = u.module.enums.iter().find(|e| e.name == *name).unwrap();
                    if !e.tparams.is_empty() {
                        let g = GType { module, params: e.tparams.clone(), def: GDef::Enum(e.clone()), methods: vec![], traits: vec![] };
                        self.gtypes.insert(k, g);
                    } else {
                        self.enums.insert(k, vec![]);
                    }
                }
            }
            for t in &u.module.traits {
                let k = self.key(&t.name);
                if self.traits.contains_key(&k) || self.structs.contains_key(&k) || self.enums.contains_key(&k) || self.gtypes.contains_key(&k) {
                    return err(t.pos, format!("`{}` is already defined", t.name));
                }
                self.traits.insert(k, TraitInfo { methods: t.methods.clone() });
            }
        }
        // the methods of generic types (complete before the first instance is made)
        for u in units {
            self.module = u.name.clone();
            for im in &u.module.impls {
                let sk = self.key(&im.name);
                if !self.gtypes.contains_key(&sk) {
                    continue;
                }
                let methods = match &im.trait_ {
                    Some(t) => {
                        let (tk, ms) = self.trait_methods(t, &im.methods, &im.name, im.pos)?;
                        self.gtypes.get_mut(&sk).unwrap().traits.push(tk);
                        ms
                    }
                    None => im.methods.clone(),
                };
                for m in &methods {
                    if self.gtypes[&sk].methods.iter().any(|o| o.name == m.name) {
                        return err(m.pos, format!("`{}` is already defined", m.name));
                    }
                }
                self.gtypes.get_mut(&sk).unwrap().methods.extend(methods);
            }
        }
        for u in units {
            self.module = u.name.clone();
            for s in &u.module.structs {
                if !s.tparams.is_empty() {
                    continue;
                }
                let k = self.key(&s.name);
                let fields = self.fields(&k, &s.fields, s.pos)?;
                self.structs.insert(k, fields);
            }
            for e in &u.module.enums {
                if !e.tparams.is_empty() {
                    continue;
                }
                let k = self.key(&e.name);
                let vs = self.variants(&k, &e.variants)?;
                self.enums.insert(k, vs);
            }
            for f in &u.module.funcs {
                let k = self.key(&f.name);
                if !f.tparams.is_empty() {
                    if RESERVED.contains(&f.name.as_str()) || self.funcs.contains_key(&k) || self.gfns.contains_key(&k) {
                        return err(f.pos, format!("`{}` is already defined", f.name));
                    }
                    self.gfns.insert(k, GFn { module: u.name.clone(), func: f.clone(), outer: HashMap::new(), self_ty: None });
                    continue;
                }
                let sig = self.sig(f, None, format!("@\"st.{k}\""))?;
                self.add_fn(k, sig, f.pos, &f.name)?;
            }
            for x in &u.module.externs {
                let params = x.params.iter().map(|p| self.resolve(p, x.pos)).collect::<R<Vec<_>>>()?;
                let ret = self.resolve(&x.ret, x.pos)?;
                if !RUNTIME.contains(&format!("@{}(", x.name)) && !self.decls.contains(&format!("@{}(", x.name)) {
                    let ps: Vec<String> = params.iter().map(ll).collect();
                    writeln!(self.decls, "declare {} @{}({})", ll(&ret), x.name, ps.join(", ")).unwrap();
                }
                let sig = Sig { params, names: vec![], ret, sym: format!("@{}", x.name), is_extern: true, defaults: vec![], module: self.module.clone() };
                self.add_fn(self.key(&x.name), sig, x.pos, &x.name)?;
            }
            for im in &u.module.impls {
                let prim = match im.name.as_str() {
                    "int" => Some(Type::Int),
                    "float" => Some(Type::Float),
                    "str" => Some(Type::Str),
                    "bool" => Some(Type::Bool),
                    _ => None,
                };
                let sk = if prim.is_some() { im.name.clone() } else { self.key(&im.name) };
                if self.gtypes.contains_key(&sk) {
                    continue;
                }
                if prim.is_none() && !self.structs.contains_key(&sk) && !self.enums.contains_key(&sk) {
                    return err(im.pos, format!("`impl` for unknown type `{}`", im.name));
                }
                let self_ty = prim.unwrap_or_else(|| self.type_of_key(&sk));
                let methods = match &im.trait_ {
                    Some(t) => {
                        let (tk, ms) = self.trait_methods(t, &im.methods, &im.name, im.pos)?;
                        self.impls_of.insert((sk.clone(), tk));
                        ms
                    }
                    None => im.methods.clone(),
                };
                for m in &methods {
                    let k = format!("{sk}::{}", m.name);
                    let is_static = m.params.first().is_none_or(|p| p.0 != "self" || p.1.is_some());
                    if !is_static && self.enums.get(&sk).is_some_and(|vs| vs.iter().any(|v| v.name == m.name)) {
                        return err(m.pos, format!("`{}` is already a variant of `{}`", m.name, im.name));
                    }
                    if !m.tparams.is_empty() {
                        if self.funcs.contains_key(&k) || self.gfns.contains_key(&k) {
                            return err(m.pos, format!("`{}` is already defined", m.name));
                        }
                        let st = (!is_static).then(|| self_ty.clone());
                        self.gfns.insert(k.clone(), GFn { module: u.name.clone(), func: m.clone(), outer: HashMap::new(), self_ty: st });
                        if is_static {
                            self.statics.insert(k);
                        }
                        continue;
                    }
                    let sig = self.sig(m, (!is_static).then_some(&self_ty), format!("@\"st.{k}\""))?;
                    if is_static {
                        self.statics.insert(k.clone());
                    }
                    self.add_fn(k, sig, m.pos, &m.name)?;
                }
                self.impl_methods.push((u.name.clone(), sk, methods));
            }
        }
        // constants: dependencies (later units) first, each in order of declaration
        for u in units.iter().rev() {
            self.module = u.name.clone();
            for c in &u.module.consts {
                let k = self.key(&c.name);
                if RESERVED.contains(&c.name.as_str()) || self.consts.contains_key(&k) || self.funcs.contains_key(&k) {
                    return err(c.pos, format!("`{}` is already defined", c.name));
                }
                let want = c.ty.as_ref().map(|t| self.resolve(t, c.pos)).transpose()?;
                let body = Body::Expr(Box::new(c.value.clone()));
                let t = self.function(&format!("@\"const.{k}\""), &[], want, &body, None, &[], c.pos, &format!("`{}`", c.name))?;
                if t == Type::Void {
                    return err(c.pos, "a constant needs a value");
                }
                writeln!(self.globals, "@\"g.{k}\" = internal global {} zeroinitializer", ll(&t)).unwrap();
                self.consts.insert(k.clone(), t);
                self.const_order.push(k);
            }
        }
        // default values: each one becomes a small function of its own (like a constant), so its type is
        // checked here, once, and a call that leaves the value out just calls it. Generic instances get
        // theirs when they're made, since only then are the types known.
        let mut fns: Vec<String> = vec![];
        for u in units {
            self.module = u.name.clone();
            fns.extend(u.module.funcs.iter().filter(|f| f.tparams.is_empty()).map(|f| self.key(&f.name)));
        }
        for (_, sk, methods) in &self.impl_methods {
            fns.extend(methods.iter().filter(|m| m.tparams.is_empty()).map(|m| format!("{sk}::{}", m.name)));
        }
        for k in fns {
            let sig = self.funcs[&k].clone();
            for (i, d) in sig.defaults.iter().enumerate() {
                if let Some(e) = d {
                    self.default_fn(&default_sym(&sig.sym, i), e, &sig.module, &sig.params[i])?;
                }
            }
        }
        for u in units {
            self.module = u.name.clone();
            let mut holders: Vec<(String, Vec<(String, Type)>)> = vec![];
            for st in u.module.structs.iter().filter(|st| st.tparams.is_empty()) {
                let k = self.key(&st.name);
                holders.push((k.clone(), self.structs[&k].clone()));
            }
            for e in u.module.enums.iter().filter(|e| e.tparams.is_empty()) {
                let k = self.key(&e.name);
                holders.extend(self.enums[&k].iter().map(|v| (format!("{k}::{}", v.name), v.fields.clone())));
            }
            for (dkey, fields) in holders {
                let Some((m, defs)) = self.defaults.get(&dkey).cloned() else { continue };
                for (f, e) in defs {
                    let ft = fields.iter().find(|x| x.0 == f).unwrap().1.clone();
                    self.default_fn(&field_default_sym(&dkey, &f), &e, &m, &ft)?;
                }
            }
        }
        for u in units {
            self.module = u.name.clone();
            for f in &u.module.funcs {
                if f.tparams.is_empty() {
                    self.gen_named(&self.key(&f.name), f)?;
                }
            }
        }
        for (module, sk, methods) in mem::take(&mut self.impl_methods) {
            self.module = module;
            for m in &methods {
                if m.tparams.is_empty() {
                    self.gen_named(&format!("{sk}::{}", m.name), m)?;
                }
            }
        }
        self.gen_pending()?;
        self.module = String::new();

        let main = match self.funcs.get("main") {
            None if !need_main => Type::Void,
            Some(s) if s.params.is_empty() => s.ret.clone(),
            Some(_) => return err(units[0].module.funcs.iter().find(|f| f.name == "main").unwrap().pos, "`main` can't take parameters"),
            None => return err(Pos { line: 1, col: 1 }, "no `main` function (write `fn main() { ... }`)"),
        };
        let call = if need_main { format!("call {} @\"st.main\"()", ll(&main)) } else { "call void @st_init()".into() };
        let entry = match &main {
            Type::Void => format!("  {call}\n  ret i32 0"),
            Type::Int => format!("  %r = {call}\n  %c = trunc i64 %r to i32\n  ret i32 %c"),
            Type::Result(t) if matches!(**t, Type::Void | Type::Int) => format!(
                "  %r = {call}\n  %e = extractvalue {0} %r, 0\n  br i1 %e, label %fail, label %ok\nfail:\n  %m = extractvalue {0} %r, 2\n  call void @st_fail(ptr %m)\n  unreachable\nok:\n{1}",
                ll(&main),
                if **t == Type::Int { format!("  %v = extractvalue {} %r, 1\n  %c = trunc i64 %v to i32\n  ret i32 %c", ll(&main)) } else { "  ret i32 0".into() }
            ),
            t => return err(Pos { line: 1, col: 1 }, format!("`main` must return nothing, int, void! or int!, not {t}")),
        };

        let mut out = String::from(RUNTIME);
        out += &self.decls;
        let mut keys: Vec<&String> = self.structs.keys().collect();
        keys.sort();
        for k in keys {
            let fs: Vec<String> = self.structs[k].iter().map(|(_, t)| ll(t)).collect();
            writeln!(out, "%\"S.{k}\" = type {{ {} }}", fs.join(", ")).unwrap();
        }
        let mut keys: Vec<&String> = self.enums.keys().collect();
        keys.sort();
        for k in keys {
            for (i, v) in self.enums[k].iter().enumerate() {
                let mut fs = vec!["i64".to_string()];
                fs.extend(v.fields.iter().map(|(_, t)| ll(t)));
                writeln!(out, "%\"V.{k}.{}\" = type {{ {} }}", v.name, fs.join(", ")).unwrap();
                if v.fields.is_empty() {
                    writeln!(out, "@\"U.{k}.{}\" = private unnamed_addr constant %\"V.{k}.{}\" {{ i64 {i} }}", v.name, v.name).unwrap();
                }
            }
        }
        out += &self.code;
        for k in mem::take(&mut self.wrappers) {
            let s = &self.funcs[&k];
            let ps: Vec<String> = s.params.iter().enumerate().map(|(i, t)| format!("{} %a{i}", ll(t))).collect();
            let call = format!("call {} {}({})", ll(&s.ret), s.sym, ps.join(", "));
            let body = if s.ret == Type::Void { format!("  {call}\n  ret void") } else { format!("  %r = {call}\n  ret {} %r", ll(&s.ret)) };
            let params = if ps.is_empty() { "ptr %env".to_string() } else { format!("ptr %env, {}", ps.join(", ")) };
            writeln!(out, "@\"clo.{k}\" = private constant ptr @\"st.{k}$val\"").unwrap();
            writeln!(out, "define internal {} @\"st.{k}$val\"({params}) {{\n{body}\n}}\n", ll(&s.ret)).unwrap();
        }
        let mut init = String::new();
        for (i, k) in self.const_order.iter().enumerate() {
            let t = ll(&self.consts[k]);
            write!(init, "  %c{i} = call {t} @\"const.{k}\"(ptr null)\n  store {t} %c{i}, ptr @\"g.{k}\"\n").unwrap();
        }
        if self.web {
            writeln!(out, "define i32 @st_start() {{\n  call void @st_init()\n{init}{entry}\n}}").unwrap();
        } else {
            writeln!(out, "define i32 @main(i32 %argc, ptr %argv) {{\n  call void @st_set_args(i32 %argc, ptr %argv)\n  call void @st_init()\n{init}{entry}\n}}").unwrap();
        }
        out += &self.globals;
        if self.web || self.kernel {
            out += "attributes #0 = { nounwind }\n";
        } else {
            // stack-clash protection: big frames touch every page, so they hit the guard page instead of jumping it
            out += "attributes #0 = { \"probe-stack\"=\"inline-asm\" }\n";
        }
        Ok(out)
    }

    /// A default value as a function of its own, evaluated in `module` and checked against the type it fills in.
    fn default_fn(&mut self, sym: &str, e: &Expr, module: &str, t: &Type) -> R<()> {
        // once: another default may already have made it (`a: E = E {}` needs E's field defaults)
        if !self.default_fns.insert(sym.into()) {
            return Ok(());
        }
        let saved = mem::replace(&mut self.module, module.into());
        let body = Body::Expr(Box::new(e.clone()));
        // on an error, `module` stays put so the message names the file the default is written in
        self.function(sym, &[], Some(t.clone()), &body, None, &[], e.pos, "a default value")?;
        self.module = saved;
        Ok(())
    }

    /// The value of a default: a call to its function (made here, for a generic instance, if it isn't yet).
    pub(super) fn call_default(&mut self, sym: &str, e: &Expr, module: &str, t: &Type) -> R<Val> {
        if !self.default_fns.contains(sym) {
            self.default_fn(sym, e, module, t)?;
        }
        let r = self.tmp();
        self.ins(format!("{r} = call {} {sym}(ptr null)", ll(t)));
        Ok(val(r, t.clone()))
    }

    fn gen_named(&mut self, key: &str, f: &Func) -> R<()> {
        let sig = self.funcs[key].clone();
        let params: Vec<(String, Type)> = f.params.iter().map(|p| p.0.clone()).zip(sig.params).collect();
        self.function(&sig.sym, &params, Some(sig.ret), &Body::Block(vec![]), Some(&f.body), &[], f.pos, &format!("`{}`", f.name))?;
        Ok(())
    }

    // ---- emission helpers ----

    fn tmp(&mut self) -> String {
        self.n += 1;
        format!("%t{}", self.n)
    }

    fn lbl(&mut self, s: &str) -> String {
        self.n += 1;
        format!("{s}{}", self.n)
    }

    fn ensure_open(&mut self) {
        if !self.f.open {
            let l = self.lbl("dead");
            self.f.body.push(format!("{l}:"));
            self.f.cur = l;
            self.f.open = true;
        }
    }

    fn ins(&mut self, s: String) {
        self.ensure_open();
        self.f.body.push(format!("  {s}"));
    }

    fn term(&mut self, s: String) {
        self.ins(s);
        self.f.open = false;
    }

    fn label(&mut self, l: &str) {
        if self.f.open { self.term(format!("br label %{l}")) }
        self.f.body.push(format!("{l}:"));
        self.f.cur = l.into();
        self.f.open = true;
    }

    fn alloca(&mut self, t: &Type) -> String {
        let a = self.tmp();
        self.f.allocas.push(format!("  {a} = alloca {}", ll(t)));
        a
    }

    fn str_const(&mut self, s: &str) -> String {
        let name = format!("@.str.{}", self.nstr);
        self.nstr += 1;
        let mut enc = String::new();
        for b in s.bytes() {
            if b == b' ' || (b.is_ascii_graphic() && b != b'"' && b != b'\\') {
                enc.push(b as char);
            } else {
                write!(enc, "\\{b:02X}").unwrap();
            }
        }
        writeln!(self.globals, "{name} = private unnamed_addr constant [{} x i8] c\"{enc}\\00\"", s.len() + 1).unwrap();
        name
    }

    fn size_of(&mut self, t: &Type) -> String {
        let (g, sz) = (self.tmp(), self.tmp());
        self.ins(format!("{g} = getelementptr {}, ptr null, i64 1", ll(t)));
        self.ins(format!("{sz} = ptrtoint ptr {g} to i64"));
        sz
    }

    fn store(&mut self, addr: &str, v: &Val) {
        self.ins(format!("store {} {}, ptr {addr}", ll(&v.ty), v.v));
    }

    fn load(&mut self, addr: &str, ty: Type) -> Val {
        let t = self.tmp();
        self.ins(format!("{t} = load {}, ptr {addr}", ll(&ty)));
        val(t, ty)
    }

    /// Call `f` (an LLVM symbol or pointer); `args` are already typed (`i64 %x`).
    fn emit_call(&mut self, ret: &Type, f: &str, args: &[String]) -> Val {
        let call = format!("call {} {f}({})", ll(ret), args.join(", "));
        if *ret == Type::Void {
            self.ins(call);
            return void();
        }
        let t = self.tmp();
        self.ins(format!("{t} = {call}"));
        val(t, ret.clone())
    }

    fn rt(&mut self, ret: Type, f: &str, args: &[String]) -> Val {
        self.emit_call(&ret, &format!("@{f}"), args)
    }

    fn where_(&mut self, pos: Pos) -> String {
        format!("{}:{}:{}", self.files[&self.module], pos.line, pos.col)
    }

    /// Branch to a runtime panic (exit code 101) when `bad` is true.
    fn check(&mut self, bad: &str, msg: &str, pos: Pos) {
        let (lp, lok) = (self.lbl("panic"), self.lbl("ok"));
        self.term(format!("br i1 {bad}, label %{lp}, label %{lok}"));
        self.label(&lp);
        let w = self.where_(pos);
        let m = self.str_const(&format!("{w}: panic: {msg}\n"));
        self.ins(format!("call void @st_panic(ptr {m})"));
        self.term("unreachable".into());
        self.label(&lok);
    }

    fn find(&self, n: &str) -> Option<Var> {
        self.f.scopes.iter().rev().find_map(|s| s.get(n)).cloned()
    }

    /// A new local. Locals that some lambda refers to live in a GC box instead of the stack.
    fn declare(&mut self, name: &str, v: &Val, mutable: bool) {
        let a = if self.f.captured.contains(name) {
            let sz = self.size_of(&v.ty);
            self.rt(Type::Str, "st_alloc", &[format!("i64 {sz}")]).v
        } else {
            self.alloca(&v.ty)
        };
        self.store(&a, v);
        self.f.scopes.last_mut().unwrap().insert(name.into(), Var { addr: a, ty: v.ty.clone(), mutable });
    }

    fn ok_of(&mut self, t: &Type, v: &Val) -> Val {
        let rt = Type::Result(Box::new(t.clone()));
        if *t == Type::Void {
            return val("zeroinitializer", rt);
        }
        let r = self.tmp();
        self.ins(format!("{r} = insertvalue {} zeroinitializer, {} {}, 1", ll(&rt), ll(t), v.v));
        val(r, rt)
    }

    fn err_of(&mut self, t: &Type, msg: &str) -> Val {
        let rt = Type::Result(Box::new(t.clone()));
        let (a, b) = (self.tmp(), self.tmp());
        self.ins(format!("{a} = insertvalue {} zeroinitializer, i1 true, 0", ll(&rt)));
        self.ins(format!("{b} = insertvalue {} {a}, ptr {msg}, 2", ll(&rt)));
        val(b, rt)
    }

    fn extract(&mut self, r: &Val, i: u8, ty: Type) -> Val {
        let t = self.tmp();
        self.ins(format!("{t} = extractvalue {} {}, {i}", ll(&r.ty), r.v));
        val(t, ty)
    }

    /// (length, data pointer) of the list with header `h`.
    fn vec_parts(&mut self, h: &str) -> (String, String) {
        let (len, dp, d) = (self.tmp(), self.tmp(), self.tmp());
        self.ins(format!("{len} = load i64, ptr {h}"));
        self.ins(format!("{dp} = getelementptr inbounds %st.vec, ptr {h}, i32 0, i32 2"));
        self.ins(format!("{d} = load ptr, ptr {dp}"));
        (len, d)
    }

    fn field_ptr(&mut self, b: &Val, f: &str, pos: Pos) -> R<(String, Type)> {
        let Type::Struct(s) = &b.ty else {
            return match &b.ty {
                Type::Opt(_) => err(pos, format!("this is optional ({}); unwrap it first: `if let x = ...`, `?? fallback` or `let x = ... else {{ ... }}`", b.ty)),
                Type::Enum(_) => err(pos, format!("{} is an enum; look inside with `match` or `if let`", b.ty)),
                _ => err(pos, format!("{} has no field `{f}`", b.ty)),
            };
        };
        let Some(i) = self.structs[s].iter().position(|(n, _)| n == f) else {
            return err(pos, format!("`{s}` has no field or method `{f}`"));
        };
        let ft = self.structs[s][i].1.clone();
        let p = self.tmp();
        self.ins(format!("{p} = getelementptr inbounds %\"S.{s}\", ptr {}, i32 0, i32 {i}", b.v));
        Ok((p, ft))
    }

    /// Address of element `idx` of list `h`, bounds-checked. Also returns the index.
    fn index_ptr(&mut self, h: &Val, idx: &Expr, pos: Pos) -> R<(String, Type, String)> {
        let Type::List(et) = &h.ty else { return err(pos, format!("can't index into {}", h.ty)) };
        let et = (**et).clone();
        let i = self.typed(idx, &Type::Int)?;
        let (len, d) = self.vec_parts(&h.v);
        let bad = self.tmp();
        self.ins(format!("{bad} = icmp uge i64 {}, {len}", i.v));
        self.check(&bad, "index out of bounds", pos);
        let p = self.tmp();
        self.ins(format!("{p} = getelementptr inbounds {}, ptr {d}, i64 {}", ll(&et), i.v));
        Ok((p, et, i.v))
    }

    /// Field types of a struct or variant; remembers their default values.
    fn fields(&mut self, key: &str, fs: &[crate::parser::Field], pos: Pos) -> R<Vec<(String, Type)>> {
        let (mut out, mut defs): (Vec<(String, Type)>, Vec<(String, Expr)>) = (vec![], vec![]);
        for f in fs {
            if out.iter().any(|(o, _)| *o == f.name) {
                return err(pos, format!("duplicate field `{}`", f.name));
            }
            out.push((f.name.clone(), self.resolve(&f.ty, pos)?));
            if let Some(d) = &f.default {
                defs.push((f.name.clone(), d.clone()));
            }
        }
        self.defaults.insert(key.into(), (self.module.clone(), defs));
        Ok(out)
    }

    /// `v` as a `want`; an int is welcome where a float is wanted, a `T` where a `T?` is.
    fn coerce(&mut self, v: Val, want: &Type, pos: Pos) -> R<Val> {
        if let Type::Opt(t) = want {
            if v.ty != *want && v.ty != Type::Void {
                let v = self.coerce(v, t, pos)?;
                return Ok(self.some_of(&v));
            }
        }
        if *want == Type::Str && v.ty == Type::Node {
            return Ok(val(v.v, Type::Str)); // a Node is its HTML
        }
        if *want == Type::Float && v.ty == Type::Int {
            let t = self.tmp();
            self.ins(format!("{t} = sitofp i64 {} to double", v.v));
            return Ok(val(t, Type::Float));
        }
        expect_ty(want, &v.ty, pos)?;
        Ok(v)
    }

    fn typed(&mut self, e: &Expr, want: &Type) -> R<Val> {
        let v = self.expr(e, Some(want))?;
        self.coerce(v, want, e.pos)
    }

    /// int + float: both become floats.
    fn promote(&mut self, a: Val, b: Val, pos: Pos) -> R<(Val, Val)> {
        Ok(match (&a.ty, &b.ty) {
            (Type::Int, Type::Float) => (self.coerce(a, &Type::Float, pos)?, b),
            (Type::Float, Type::Int) => {
                let b = self.coerce(b, &Type::Float, pos)?;
                (a, b)
            }
            _ => (a, b),
        })
    }

    /// Maps and sets keep everything in 8-byte slots.
    fn slot_of(&mut self, v: &Val) -> String {
        let cast = match v.ty {
            Type::Int => return v.v.clone(),
            Type::Bool => "zext i1",
            Type::Float => "bitcast double",
            _ => "ptrtoint ptr",
        };
        let t = self.tmp();
        self.ins(format!("{t} = {cast} {} to i64", v.v));
        t
    }

    fn unslot(&mut self, s: &str, ty: Type) -> Val {
        let cast = match ty {
            Type::Int => return val(s, ty),
            Type::Bool => "trunc",
            Type::Float => "bitcast",
            _ => "inttoptr",
        };
        let t = self.tmp();
        self.ins(format!("{t} = {cast} i64 {s} to {}", ll(&ty)));
        val(t, ty)
    }

    fn map_new(&mut self, key: &Type) -> String {
        self.rt(Type::Str, "st_map_new", &[format!("i64 {}", (*key == Type::Str) as i64)]).v
    }

    fn map_set(&mut self, m: &str, k: &Val, v: Option<&Val>) {
        let ks = self.slot_of(k);
        let vs = v.map_or("0".into(), |v| self.slot_of(v));
        self.rt(Type::Void, "st_map_set", &[format!("ptr {m}"), format!("i64 {ks}"), format!("i64 {vs}")]);
    }

    /// (found, value or a zero value) for key `k`.
    fn map_get(&mut self, m: &str, k: &Val, vt: &Type) -> (String, Val) {
        let ks = self.slot_of(k);
        let out = self.alloca(&Type::Int);
        self.ins(format!("store i64 0, ptr {out}"));
        let found = self.rt(Type::Bool, "st_map_get", &[format!("ptr {m}"), format!("i64 {ks}"), format!("ptr {out}")]).v;
        let raw = self.load(&out, Type::Int).v;
        (found, self.unslot(&raw, vt.clone()))
    }

    fn map_has(&mut self, m: &str, k: &Val) -> String {
        let ks = self.slot_of(k);
        self.rt(Type::Bool, "st_map_get", &[format!("ptr {m}"), format!("i64 {ks}"), "ptr null".into()]).v
    }

    /// The keys (`which` 0) or values (1) of a map, or the items of a set, as a fresh list.
    fn map_list(&mut self, m: &str, which: i64, et: &Type) -> Val {
        let esz = self.size_of(et);
        let args = [format!("ptr {m}"), format!("i64 {which}"), format!("i64 {esz}"), format!("i64 {}", atomic(et))];
        self.rt(Type::List(Box::new(et.clone())), "st_map_list", &args)
    }

    fn new_list(&mut self, et: &Type) -> Val {
        let esz = self.size_of(et);
        self.rt(Type::List(Box::new(et.clone())), "st_vec_new", &["i64 0".into(), format!("i64 {esz}"), format!("i64 {}", atomic(et))])
    }

    /// Run `body(element, index)` for every element of list `h`.
    fn each(&mut self, h: &Val, et: &Type, mut body: impl FnMut(&mut Self, Val, &str) -> R<()>) -> R<()> {
        let i = self.alloca(&Type::Int);
        self.ins(format!("store i64 0, ptr {i}"));
        let (lc, lb, le) = (self.lbl("each"), self.lbl("item"), self.lbl("done"));
        self.label(&lc);
        let iv = self.load(&i, Type::Int).v;
        let (len, d) = self.vec_parts(&h.v);
        let k = self.tmp();
        self.ins(format!("{k} = icmp slt i64 {iv}, {len}"));
        self.term(format!("br i1 {k}, label %{lb}, label %{le}"));
        self.label(&lb);
        let p = self.tmp();
        self.ins(format!("{p} = getelementptr inbounds {}, ptr {d}, i64 {iv}", ll(et)));
        let x = self.load(&p, et.clone());
        body(self, x, &iv)?;
        let n = self.tmp();
        self.ins(format!("{n} = add i64 {iv}, 1"));
        self.ins(format!("store i64 {n}, ptr {i}"));
        self.term(format!("br label %{lc}"));
        self.label(&le);
        Ok(())
    }

    fn push(&mut self, h: &str, x: &Val) {
        let (len, _) = self.vec_parts(h);
        let (cp, cap, full) = (self.tmp(), self.tmp(), self.tmp());
        self.ins(format!("{cp} = getelementptr inbounds %st.vec, ptr {h}, i32 0, i32 1"));
        self.ins(format!("{cap} = load i64, ptr {cp}"));
        self.ins(format!("{full} = icmp eq i64 {len}, {cap}"));
        let (lg, lok) = (self.lbl("grow"), self.lbl("room"));
        self.term(format!("br i1 {full}, label %{lg}, label %{lok}"));
        self.label(&lg);
        let esz = self.size_of(&x.ty);
        self.rt(Type::Void, "st_vec_grow", &[format!("ptr {h}"), format!("i64 {esz}")]);
        self.label(&lok);
        let (_, d) = self.vec_parts(h); // data may have moved
        let (p, n1) = (self.tmp(), self.tmp());
        self.ins(format!("{p} = getelementptr inbounds {}, ptr {d}, i64 {len}", ll(&x.ty)));
        self.store(&p, x);
        self.ins(format!("{n1} = add i64 {len}, 1"));
        self.ins(format!("store i64 {n1}, ptr {h}"));
    }

    /// `a == b`: by value for everything but functions (structs, enums, lists, maps and sets compare their contents).
    fn eq(&mut self, a: Val, b: Val, pos: Pos) -> R<String> {
        let (a, b) = match (&a.ty, &b.ty) {
            (Type::Opt(_), t) if *t != a.ty => {
                let w = a.ty.clone();
                (a, self.coerce(b, &w, pos)?)
            }
            (t, Type::Opt(_)) if *t != b.ty => {
                let w = b.ty.clone();
                (self.coerce(a, &w, pos)?, b)
            }
            _ => (a, b),
        };
        let (a, b) = self.promote(a, b, pos)?;
        expect_ty(&a.ty, &b.ty, pos)?;
        let t = self.tmp();
        match a.ty {
            Type::Int | Type::Bool => self.ins(format!("{t} = icmp eq {} {}, {}", ll(&a.ty), a.v, b.v)),
            Type::Float => self.ins(format!("{t} = fcmp oeq double {}, {}", a.v, b.v)),
            Type::Str => return Ok(self.rt(Type::Bool, "st_streq", &[format!("ptr {}", a.v), format!("ptr {}", b.v)]).v),
            Type::Struct(_) | Type::Enum(_) | Type::List(_) | Type::Opt(_) | Type::Map(..) | Type::Set(_) => {
                let f = self.eq_fn(&a.ty, pos)?;
                let l = ll(&a.ty);
                return Ok(self.emit_call(&Type::Bool, &f, &[format!("{l} {}", a.v), format!("{l} {}", b.v)]).v);
            }
            t => return err(pos, format!("`==` can't compare {t}")),
        }
        Ok(t)
    }

    /// `x in c`: substring, list element, map key or set item.
    fn contains(&mut self, c: &Val, x: Val, pos: Pos) -> R<Val> {
        Ok(match c.ty.clone() {
            Type::Str => {
                let x = self.coerce(x, &Type::Str, pos)?;
                self.rt(Type::Bool, "st_contains", &[format!("ptr {}", c.v), format!("ptr {}", x.v)])
            }
            Type::Map(k, _) | Type::Set(k) => {
                let x = self.coerce(x, &k, pos)?;
                val(self.map_has(&c.v, &x), Type::Bool)
            }
            Type::List(et) => {
                let i = self.index_of(c, &et, x, pos)?;
                let t = self.tmp();
                self.ins(format!("{t} = icmp sge i64 {i}, 0"));
                val(t, Type::Bool)
            }
            t => return err(pos, format!("`in` looks inside a str, list, map or set, not {t}")),
        })
    }

    /// Index of the first element equal to `x`, or -1.
    fn index_of(&mut self, h: &Val, et: &Type, x: Val, pos: Pos) -> R<String> {
        let x = self.coerce(x, et, pos)?;
        let found = self.alloca(&Type::Int);
        self.ins(format!("store i64 -1, ptr {found}"));
        self.each(h, et, |g, e, i| {
            let same = g.eq(e, x.clone(), pos)?;
            let (old, first, hit, new) = (g.tmp(), g.tmp(), g.tmp(), g.tmp());
            g.ins(format!("{old} = load i64, ptr {found}"));
            g.ins(format!("{first} = icmp slt i64 {old}, 0"));
            g.ins(format!("{hit} = and i1 {same}, {first}"));
            g.ins(format!("{new} = select i1 {hit}, i64 {i}, i64 {old}"));
            g.ins(format!("store i64 {new}, ptr {found}"));
            Ok(())
        })?;
        Ok(self.load(&found, Type::Int).v)
    }

    fn len_of(&mut self, v: &Val) -> Option<String> {
        Some(match v.ty {
            Type::Str => self.rt(Type::Int, "st_strlen", &[format!("ptr {}", v.v)]).v,
            Type::List(_) => self.load(&v.v, Type::Int).v,
            Type::Map(..) | Type::Set(_) => self.rt(Type::Int, "st_map_len", &[format!("ptr {}", v.v)]).v,
            _ => return None,
        })
    }

    /// `str(v)`. Strs nested in lists and maps are shown quoted: `["a", "b"]`.
    fn show(&mut self, v: &Val, nested: bool, pos: Pos) -> R<Val> {
        let p = format!("{} {}", ll(&v.ty), v.v);
        Ok(match &v.ty {
            Type::Str if !nested => v.clone(),
            Type::Node => val(v.v.clone(), Type::Str),
            Type::Str => self.rt(Type::Str, "st_quote", &[p]),
            Type::Int => self.rt(Type::Str, "st_itoa", &[format!("i64 {}", v.v)]),
            Type::Float => self.rt(Type::Str, "st_ftoa", &[format!("double {}", v.v)]),
            Type::Bool => val(self.bool_str(&v.v), Type::Str),
            Type::Fn(..) => val(self.str_const("<fn>"), Type::Str),
            Type::Opt(_) => self.show_opt(v, nested, pos, "none", false)?,
            Type::Void | Type::Result(_) => return err(pos, format!("can't turn {} into a str", v.ty)),
            t => {
                let sym = self.show_fn(t, pos)?;
                self.emit_call(&Type::Str, &sym, &[p])
            }
        })
    }

    /// The `str()` helper for a list, map, set or struct type (emitted once; recursive types are fine).
    fn show_fn(&mut self, t: &Type, pos: Pos) -> R<String> {
        let sym = format!("@\"show.{t}\"");
        if !self.shown.insert(sym.clone()) {
            return Ok(sym);
        }
        let saved = mem::take(&mut self.f);
        self.f.open = true;
        self.f.cur = "entry".into();
        self.f.scopes = vec![HashMap::new()];
        let r = self.show_body(t, pos);
        let f = mem::replace(&mut self.f, saved);
        r?;
        write!(self.code, "define internal ptr {sym}({} %x) {{\nentry:\n{}\n{}\n}}\n\n", ll(t), f.allocas.join("\n"), f.body.join("\n")).unwrap();
        Ok(sym)
    }

    fn show_body(&mut self, t: &Type, pos: Pos) -> R<()> {
        let x = val("%x", t.clone());
        if let Type::Enum(k) = t {
            return self.show_enum(k, pos);
        }
        let parts = self.new_list(&Type::Str);
        let add = |g: &mut Self, s: Val| {
            g.rt(Type::Void, "st_vec_push_str", &[format!("ptr {}", parts.v), format!("ptr {}", s.v)]);
        };
        let (open, close) = match t {
            Type::List(et) => {
                self.each(&x, et, |g, e, _| {
                    let s = g.show(&e, true, pos)?;
                    add(g, s);
                    Ok(())
                })?;
                ("[".to_string(), "]")
            }
            Type::Set(et) => {
                let xs = self.map_list("%x", 0, et);
                self.each(&xs, et, |g, e, _| {
                    let s = g.show(&e, true, pos)?;
                    add(g, s);
                    Ok(())
                })?;
                ("{".into(), "}")
            }
            Type::Map(kt, vt) => {
                let (ks, vs) = (self.map_list("%x", 0, kt), self.map_list("%x", 1, vt));
                self.each(&ks, kt, |g, k, i| {
                    let (_, d) = g.vec_parts(&vs.v);
                    let p = g.tmp();
                    g.ins(format!("{p} = getelementptr inbounds {}, ptr {d}, i64 {i}", ll(vt)));
                    let v = g.load(&p, (**vt).clone());
                    let (k, v) = (g.show(&k, true, pos)?, g.show(&v, true, pos)?);
                    let colon = g.str_const(": ");
                    let kc = g.rt(Type::Str, "st_concat", &[format!("ptr {}", k.v), format!("ptr {colon}")]);
                    let kv = g.rt(Type::Str, "st_concat", &[format!("ptr {}", kc.v), format!("ptr {}", v.v)]);
                    add(g, kv);
                    Ok(())
                })?;
                ("{".into(), "}")
            }
            Type::Struct(k) => {
                for (f, ft) in self.structs[k].clone() {
                    let (p, _) = self.field_ptr(&x, &f, pos)?;
                    let v = self.load(&p, ft);
                    let s = self.show(&v, true, pos)?;
                    let label = self.str_const(&format!("{f}: "));
                    let s = self.rt(Type::Str, "st_concat", &[format!("ptr {label}"), format!("ptr {}", s.v)]);
                    add(self, s);
                }
                let name = generics::base_name(short_name(k));
                if self.structs[k].is_empty() { (format!("{name} {{"), "}") } else { (format!("{name} {{ "), " }") }
            }
            _ => unreachable!("show() handles scalars"),
        };
        let sep = self.str_const(", ");
        let body = self.rt(Type::Str, "st_join", &[format!("ptr {}", parts.v), format!("ptr {sep}")]);
        let (o, c) = (self.str_const(&open), self.str_const(close));
        let a = self.rt(Type::Str, "st_concat", &[format!("ptr {o}"), format!("ptr {}", body.v)]);
        let r = self.rt(Type::Str, "st_concat", &[format!("ptr {}", a.v), format!("ptr {c}")]);
        self.term(format!("ret ptr {}", r.v));
        Ok(())
    }

    fn cond(&mut self, e: &Expr) -> R<String> {
        let v = self.expr(e, Some(&Type::Bool))?;
        expect_ty(&Type::Bool, &v.ty, e.pos)?;
        Ok(v.v)
    }

    /// Return `v` from the current function (wrapping `T` into `T!` when needed).
    fn ret_value(&mut self, v: Val, pos: Pos) -> R<()> {
        let rt = self.f.ret.clone();
        let v = match &rt {
            Type::Void => void(), // an expression lambda used where nothing is expected
            Type::Result(t) if !matches!(v.ty, Type::Result(_)) => {
                let v = self.coerce(v, t, pos)?;
                self.ok_of(t, &v)
            }
            _ => self.coerce(v, &rt, pos)?,
        };
        if rt == Type::Void {
            self.term("ret void".into());
        } else {
            self.term(format!("ret {} {}", ll(&rt), v.v));
        }
        Ok(())
    }

    // ---- functions & statements ----

    /// Emit one LLVM function. `ret` None = infer from the expression body. Returns the return type.
    #[allow(clippy::too_many_arguments)]
    fn function(
        &mut self,
        sym: &str,
        params: &[(String, Type)],
        ret: Option<Type>,
        body: &Body,
        block: Option<&[Stmt]>,
        captures: &[(String, Var)],
        pos: Pos,
        what: &str,
    ) -> R<Type> {
        let saved = mem::take(&mut self.f);
        let r = self.function_inner(sym, params, ret, body, block, captures, pos, what);
        self.f = saved;
        r
    }

    #[allow(clippy::too_many_arguments)]
    fn function_inner(
        &mut self,
        sym: &str,
        params: &[(String, Type)],
        ret: Option<Type>,
        body: &Body,
        block: Option<&[Stmt]>,
        captures: &[(String, Var)],
        pos: Pos,
        what: &str,
    ) -> R<Type> {
        self.f.open = true;
        self.f.cur = "entry".into();
        self.f.scopes = vec![HashMap::new()];
        self.f.ret = ret.clone().unwrap_or_default();
        match block {
            Some(ss) => names_stmts(ss, false, &mut self.f.captured),
            None => names_body(body, false, &mut self.f.captured),
        }
        let closure = block.is_none();
        let mut plist = vec![];
        if closure {
            plist.push("ptr %env".to_string());
        }
        for (i, (n, var)) in captures.iter().enumerate() {
            let (g, b) = (self.tmp(), self.tmp());
            self.ins(format!("{g} = getelementptr ptr, ptr %env, i64 {}", i + 1));
            self.ins(format!("{b} = load ptr, ptr {g}"));
            self.f.scopes[0].insert(n.clone(), Var { addr: b, ty: var.ty.clone(), mutable: var.mutable });
        }
        let mut seen = HashSet::new();
        for (n, t) in params {
            if !seen.insert(n) {
                return err(pos, format!("duplicate parameter `{n}`"));
            }
            let p = format!("%p.{n}");
            plist.push(format!("{} {p}", ll(t)));
            self.declare(n, &val(p, t.clone()), true);
        }
        let stmts: Option<&[Stmt]> = match (block, body) {
            (Some(ss), _) => Some(ss),
            (None, Body::Block(ss)) => Some(ss),
            (None, Body::Expr(_)) => None,
        };
        match (stmts, body) {
            (Some(ss), _) => {
                self.block(ss)?;
                if self.f.open {
                    match self.f.ret.clone() {
                        Type::Void => self.term("ret void".into()),
                        Type::Result(t) if *t == Type::Void => self.ret_value(void(), pos)?,
                        t => return err(pos, format!("{what} must return a {t} on every path (missing `return`?)")),
                    }
                }
            }
            (None, Body::Expr(e)) => {
                let v = self.expr(e, ret.as_ref())?;
                if ret.is_none() {
                    self.f.ret = v.ty.clone();
                }
                if self.f.open {
                    self.ret_value(v, e.pos)?;
                }
            }
            (None, Body::Block(_)) => unreachable!(),
        }
        let rt = self.f.ret.clone();
        write!(
            self.code,
            "define internal {} {sym}({}) #0 {{\nentry:\n{}\n{}\n}}\n\n",
            ll(&rt),
            plist.join(", "),
            self.f.allocas.join("\n"),
            self.f.body.join("\n")
        )
        .unwrap();
        Ok(rt)
    }

    fn block(&mut self, stmts: &[Stmt]) -> R<()> {
        self.f.scopes.push(HashMap::new());
        let mut r = Ok(());
        for s in stmts {
            if !self.f.open {
                break; // the rest is unreachable (after return / break / continue)
            }
            r = self.stmt(s);
            if r.is_err() {
                break;
            }
        }
        self.f.scopes.pop();
        r
    }

    fn stmt(&mut self, s: &Stmt) -> R<()> {
        match s {
            Stmt::Let { name, mutable, ty, value, pos } => {
                if RESERVED.contains(&name.as_str()) {
                    return err(*pos, format!("`{name}` is a builtin name"));
                }
                let want = ty.as_ref().map(|t| self.resolve(t, *pos)).transpose()?;
                let mut v = self.expr(value, want.as_ref())?;
                if let Some(t) = &want {
                    v = self.coerce(v, t, value.pos)?;
                }
                if v.ty == Type::Void {
                    return err(value.pos, "this has no value");
                }
                self.note(*pos, format!("{} {name}: {}", if *mutable { "var" } else { "let" }, v.ty));
                self.declare(name, &v, *mutable);
            }
            Stmt::Assign(target, value) => {
                // the value is computed before the target's address (it may grow a list)
                let (addr, t, v) = match &target.kind {
                    ExprKind::Var(n) => {
                        let Some(var) = self.find(n) else {
                            if self.consts.contains_key(&self.key(n)) {
                                return err(target.pos, format!("`{n}` is a constant; it can't be changed"));
                            }
                            return err(target.pos, format!("unknown name `{n}`"));
                        };
                        if !var.mutable {
                            return err(target.pos, format!("`{n}` is a `let`; declare it with `var` to change it"));
                        }
                        let v = self.expr(value, Some(&var.ty))?;
                        (var.addr, var.ty, v)
                    }
                    ExprKind::Field(b, f) => {
                        let b = self.expr(b, None)?;
                        let ft = match &b.ty {
                            Type::Struct(s) => self.structs[s].iter().find(|x| x.0 == *f).map(|x| x.1.clone()),
                            _ => None,
                        };
                        let v = self.expr(value, ft.as_ref())?;
                        let (p, t) = self.field_ptr(&b, f, target.pos)?;
                        self.note(target.pos, format!("{}.{f}: {t}", b.ty));
                        (p, t, v)
                    }
                    ExprKind::Index(b, i) => {
                        let h = self.expr(b, None)?;
                        let et = match &h.ty {
                            Type::List(t) => Some((**t).clone()),
                            Type::Map(k, vt) => {
                                let v = self.typed(value, vt)?;
                                let k = self.typed(i, k)?;
                                self.map_set(&h.v, &k, Some(&v));
                                return Ok(());
                            }
                            Type::Str => return err(target.pos, "strs can't be changed; build a new one"),
                            _ => None,
                        };
                        let v = self.expr(value, et.as_ref())?;
                        let (p, t, _) = self.index_ptr(&h, i, target.pos)?;
                        (p, t, v)
                    }
                    _ => return err(target.pos, "can't assign to this"),
                };
                let v = self.coerce(v, &t, value.pos)?;
                self.store(&addr, &v);
            }
            Stmt::Expr(e) => {
                let v = self.expr(e, None)?;
                if matches!(v.ty, Type::Result(_)) {
                    return err(e.pos, "this can fail and the error is ignored: handle it with `?`, `catch` or `match`");
                }
            }
            Stmt::Return(e, pos) => {
                let ret = self.f.ret.clone();
                let v = match e {
                    Some(e) => self.expr(e, Some(&ret))?,
                    None => void(),
                };
                self.ret_value(v, *pos)?;
            }
            Stmt::If(c, then, els) => {
                self.gen_if(c, then, els, None, false)?;
            }
            Stmt::While(c, body) => {
                let (lc, le) = (self.lbl("while"), self.lbl("done"));
                self.label(&lc);
                let forever = matches!(c, Cond::Expr(Expr { kind: ExprKind::Bool(true), .. }));
                self.f.scopes.push(HashMap::new());
                let r = self.test_cond(c, &le).and_then(|_| self.loop_body(body, &le, &lc));
                self.f.scopes.pop();
                let broke = r?;
                if self.f.open {
                    self.term(format!("br label %{lc}"));
                }
                self.label(&le);
                if forever && !broke {
                    self.term("unreachable".into());
                }
            }
            Stmt::LetElse { pat, mutable, value, els, pos } => {
                let v = self.expr(value, None)?;
                let pat = if els.is_some() { patterns::unwrap_pat(pat, &v.ty) } else { pat.clone() };
                let (lfail, lok) = (self.lbl("nomatch"), self.lbl("matched"));
                let mut binds = vec![];
                self.pat_test(&pat, &v, &lfail, &mut binds)?;
                self.term(format!("br label %{lok}"));
                self.label(&lfail);
                match els {
                    Some(ss) => {
                        self.block(ss)?;
                        if self.f.open {
                            return err(*pos, "the `else` block of `let ... else` must leave (return, break or continue)");
                        }
                    }
                    None => {
                        if !self.irrefutable(&pat, &v.ty) {
                            return err(*pos, "this pattern might not match; add `else { ... }` for the other case");
                        }
                        self.term("unreachable".into());
                    }
                }
                self.label(&lok);
                for (n, b) in binds {
                    self.declare(&n, &b, *mutable);
                }
            }
            Stmt::For { var, var2, iter, end, body } => {
                let (lc, lb, ls, le) = (self.lbl("for"), self.lbl("each"), self.lbl("next"), self.lbl("endfor"));
                self.f.scopes.push(HashMap::new());
                let i = self.alloca(&Type::Int);
                let iv;
                match end {
                    Some(e) => {
                        if var2.is_some() {
                            return err(iter.pos, "a range gives one number at a time: `for i in 0..10`");
                        }
                        let (a, b) = (self.typed(iter, &Type::Int)?, self.typed(e, &Type::Int)?);
                        self.ins(format!("store i64 {}, ptr {i}", a.v));
                        self.label(&lc);
                        iv = self.load(&i, Type::Int).v;
                        let k = self.tmp();
                        self.ins(format!("{k} = icmp slt i64 {iv}, {}", b.v));
                        self.term(format!("br i1 {k}, label %{lb}, label %{le}"));
                        self.label(&lb);
                        self.declare(var, &val(iv.clone(), Type::Int), false);
                    }
                    None => {
                        // maps and sets loop over a snapshot, so changing them inside the loop is fine
                        let h = self.expr(iter, None)?;
                        let (h, et, vals) = match h.ty.clone() {
                            Type::List(et) => (h, *et, None),
                            Type::Str => (self.rt(Type::List(Box::new(Type::Str)), "st_chars", &[format!("ptr {}", h.v)]), Type::Str, None),
                            Type::Set(t) => (self.map_list(&h.v, 0, &t), *t, None),
                            Type::Map(k, v) => {
                                let vals = var2.is_some().then(|| self.map_list(&h.v, 1, &v));
                                (self.map_list(&h.v, 0, &k), *k, vals)
                            }
                            t => return err(iter.pos, format!("`for` loops over a list, str, map, set or a range like 0..10, not {t}")),
                        };
                        self.ins(format!("store i64 0, ptr {i}"));
                        self.label(&lc);
                        iv = self.load(&i, Type::Int).v;
                        let (len, d) = self.vec_parts(&h.v); // re-read: the body may push
                        let k = self.tmp();
                        self.ins(format!("{k} = icmp slt i64 {iv}, {len}"));
                        self.term(format!("br i1 {k}, label %{lb}, label %{le}"));
                        self.label(&lb);
                        let p = self.tmp();
                        self.ins(format!("{p} = getelementptr inbounds {}, ptr {d}, i64 {iv}", ll(&et)));
                        let x = self.load(&p, et);
                        match (var2, vals) {
                            (None, _) => self.declare(var, &x, false),
                            (Some(v2), Some(vs)) => {
                                // for key, value in map
                                let Type::List(vt) = vs.ty.clone() else { unreachable!() };
                                let (_, vd) = self.vec_parts(&vs.v);
                                let q = self.tmp();
                                self.ins(format!("{q} = getelementptr inbounds {}, ptr {vd}, i64 {iv}", ll(&vt)));
                                let v = self.load(&q, *vt);
                                self.declare(var, &x, false);
                                self.declare(v2, &v, false);
                            }
                            (Some(v2), None) => {
                                // for index, item in list
                                self.declare(var, &val(iv.clone(), Type::Int), false);
                                self.declare(v2, &x, false);
                            }
                        }
                    }
                }
                self.loop_body(body, &le, &ls)?;
                self.label(&ls);
                let n = self.tmp();
                self.ins(format!("{n} = add i64 {iv}, 1"));
                self.ins(format!("store i64 {n}, ptr {i}"));
                self.term(format!("br label %{lc}"));
                self.f.scopes.pop();
                self.label(&le);
            }
            Stmt::Break(pos) | Stmt::Continue(pos) => {
                let brk = matches!(s, Stmt::Break(_));
                let Some(l) = self.f.loops.last_mut() else {
                    return err(*pos, format!("`{}` outside of a loop", if brk { "break" } else { "continue" }));
                };
                l.2 |= brk;
                let target = if brk { l.0.clone() } else { l.1.clone() };
                self.term(format!("br label %{target}"));
            }
        }
        Ok(())
    }

    /// Returns whether the body contains a `break` for this loop.
    fn loop_body(&mut self, body: &[Stmt], brk: &str, cont: &str) -> R<bool> {
        self.f.loops.push((brk.into(), cont.into(), false));
        let r = self.block(body);
        let (_, _, broke) = self.f.loops.pop().unwrap();
        r.map(|_| broke)
    }

    /// A branch value made to fit the type the context expects, when it easily can (`T` -> `T!` / `T?`, int -> float).
    fn fit(&mut self, v: Val, want: Option<&Type>) -> Val {
        let Some(w) = want else { return v };
        if v.ty == *w || v.ty == Type::Void {
            return v;
        }
        match w {
            Type::Result(t) if v.ty == **t || (**t == Type::Float && v.ty == Type::Int) => {
                let t = (**t).clone();
                let x = self.fit(v, Some(&t));
                self.ok_of(&t, &x)
            }
            Type::Opt(t) if v.ty == **t || (**t == Type::Float && v.ty == Type::Int) => {
                let t = (**t).clone();
                let x = self.fit(v, Some(&t));
                self.some_of(&x)
            }
            Type::Float if v.ty == Type::Int => {
                let t = self.tmp();
                self.ins(format!("{t} = sitofp i64 {} to double", v.v));
                val(t, Type::Float)
            }
            _ => v,
        }
    }

    fn join(&mut self, j: &mut Join, v: Val, end: &str, pos: Pos, want: Option<&Type>) {
        if !self.f.open {
            return;
        }
        let v = self.fit(v, want);
        j.live = true;
        if matches!(v.ty, Type::Result(_)) {
            j.result_at.get_or_insert(pos);
        }
        match j.slot.clone() {
            _ if v.ty == Type::Void => j.mixed = true,
            None => {
                let a = self.alloca(&v.ty);
                self.store(&a, &v);
                j.slot = Some((a, v.ty));
            }
            Some((a, t)) if t == v.ty => self.store(&a, &v),
            Some(_) => j.mixed = true,
        }
        self.term(format!("br label %{end}"));
    }

    fn finish(&mut self, j: Join, end: &str, exhaustive: bool) -> R<Val> {
        self.label(end);
        if !j.live {
            self.term("unreachable".into());
            return Ok(void());
        }
        Ok(match j.slot {
            Some((a, t)) if exhaustive && !j.mixed => self.load(&a, t),
            _ => {
                if let Some(p) = j.result_at {
                    return err(p, "this can fail and the error is ignored: handle it with `?`, `catch` or `match`");
                }
                void()
            }
        })
    }

    fn arm_body(&mut self, b: &Body, want: Option<&Type>) -> R<Val> {
        match b {
            Body::Expr(e) => self.expr(e, want),
            Body::Block(ss) => self.block_value(ss, want),
        }
    }

    /// Run a block; its value is the value of its last line (if that is an expression).
    fn block_value(&mut self, ss: &[Stmt], want: Option<&Type>) -> R<Val> {
        self.f.scopes.push(HashMap::new());
        let r = self.block_value_inner(ss, want);
        self.f.scopes.pop();
        r
    }

    fn block_value_inner(&mut self, ss: &[Stmt], want: Option<&Type>) -> R<Val> {
        for (i, s) in ss.iter().enumerate() {
            if !self.f.open {
                break;
            }
            if let (true, Stmt::Expr(e)) = (i + 1 == ss.len(), s) {
                return self.expr(e, want);
            }
            self.stmt(s)?;
        }
        Ok(void())
    }

    /// Branch to `fail` unless the condition holds; `let` patterns bind into the current scope.
    fn test_cond(&mut self, c: &Cond, fail: &str) -> R<()> {
        match c {
            Cond::Expr(e) => {
                let c = self.cond(e)?;
                self.need(&c, fail);
            }
            Cond::Let(p, e) => {
                let v = self.expr(e, None)?;
                let p = patterns::unwrap_pat(p, &v.ty);
                let mut binds = vec![];
                self.pat_test(&p, &v, fail, &mut binds)?;
                for (n, b) in binds {
                    self.declare(&n, &b, false);
                }
            }
        }
        Ok(())
    }

    /// Continue only if `ok` is true, otherwise jump to `fail`.
    fn need(&mut self, ok: &str, fail: &str) {
        let l = self.lbl("pass");
        self.term(format!("br i1 {ok}, label %{l}, label %{fail}"));
        self.label(&l);
    }

    /// `if` as a statement (`value` false) or as an expression.
    fn gen_if(&mut self, c: &Cond, then: &[Stmt], els: &[Stmt], want: Option<&Type>, value: bool) -> R<Val> {
        let (le, lend) = (self.lbl("else"), self.lbl("endif"));
        let mut j = Join::default();
        self.f.scopes.push(HashMap::new());
        let r = self.test_cond(c, &le).and_then(|_| if value { self.block_value(then, want) } else { self.block(then).map(|_| void()) });
        self.f.scopes.pop();
        let pos = match c { Cond::Expr(e) | Cond::Let(_, e) => e.pos };
        self.join(&mut j, r?, &lend, pos, want);
        self.label(&le);
        let v = if value { self.block_value(els, want)? } else { self.block(els).map(|_| void())? };
        self.join(&mut j, v, &lend, pos, want);
        self.finish(j, &lend, !els.is_empty())
    }

    // ---- expressions ----

    fn expr(&mut self, e: &Expr, want: Option<&Type>) -> R<Val> {
        let pos = e.pos;
        Ok(match &e.kind {
            ExprKind::Int(n) if peel_all(want) == Some(&Type::Float) => val(float_lit(*n as f64), Type::Float),
            ExprKind::Int(n) => val(n.to_string(), Type::Int),
            ExprKind::Float(x) => val(float_lit(*x), Type::Float),
            ExprKind::Bool(b) => val(b.to_string(), Type::Bool),
            ExprKind::Str(s) => val(self.str_const(s), Type::Str),
            ExprKind::Var(n) => match self.find(n) {
                Some(v) => {
                    self.note(pos, format!("{n}: {}", v.ty));
                    self.load(&v.addr, v.ty)
                }
                None if n == "none" => match peel(want) {
                    Some(t @ Type::Opt(_)) => val("zeroinitializer", t.clone()),
                    _ => return err(pos, "can't tell what kind of `none` this is; write `let x: int? = none`"),
                },
                None if self.consts.contains_key(&self.key(n)) => {
                    let k = self.key(n);
                    self.note(pos, format!("const {n}: {}", self.consts[&k]));
                    self.const_value(&k)
                }
                None if self.funcs.contains_key(&self.key(n)) => self.fn_value(self.key(n), pos)?,
                None if self.is_module(n) => return err(pos, format!("`{n}` is a module; use `{n}.something`")),
                None if self.structs.contains_key(&self.key(n)) || self.enums.contains_key(&self.key(n)) => {
                    return err(pos, format!("`{n}` is a type; build a value like `{n} {{ ... }}` or `{n}.Variant`"))
                }
                None => return err(pos, format!("unknown name `{n}`")),
            },
            ExprKind::Member(name) => {
                self.probe_want(pos, want);
                let Some(Type::Enum(k)) = peel_all(want).cloned() else {
                    return err(pos, format!("can't tell which enum `.{name}` belongs to; write `Type.{name}`"));
                };
                self.variant_value(&k, name, pos)?
            }
            ExprKind::If(c, then, els) => self.gen_if(c, then, els, want, true)?,
            ExprKind::Chain(name, base, rest) => {
                let v = self.expr(base, None)?;
                let Type::Opt(t) = v.ty.clone() else {
                    // on a result, `x?.y` is just `x?` followed by `.y`
                    let x = self.try_val(v, pos)?;
                    let tv = self.temp_var(&x);
                    self.f.scopes.push(HashMap::from([(name.clone(), tv)]));
                    let r = self.expr(rest, want);
                    self.f.scopes.pop();
                    return r;
                };
                let has = self.extract(&v, 0, Type::Bool);
                let (ls, ln, le) = (self.lbl("chain"), self.lbl("nochain"), self.lbl("endchain"));
                self.term(format!("br i1 {}, label %{ls}, label %{ln}", has.v));
                self.label(&ls);
                let x = self.extract(&v, 1, *t);
                let tv = self.temp_var(&x);
                self.f.scopes.push(HashMap::from([(name.clone(), tv)]));
                let r = self.expr(rest, peel(want).filter(|w| matches!(w, Type::Opt(_))));
                self.f.scopes.pop();
                let r = r?;
                let rt = match &r.ty {
                    Type::Void => Type::Void,
                    Type::Opt(_) => r.ty.clone(),
                    t if fits_slot(t) => Type::Opt(Box::new(t.clone())),
                    t => return err(pos, format!("`?.` can't make an optional of {t}")),
                };
                if rt == Type::Void {
                    self.term(format!("br label %{le}"));
                    self.label(&ln);
                    self.label(&le);
                    return Ok(void());
                }
                let slot = self.alloca(&rt);
                if self.f.open {
                    let r = self.coerce(r, &rt, pos)?;
                    self.store(&slot, &r);
                    self.term(format!("br label %{le}"));
                }
                self.label(&ln);
                self.ins(format!("store {} zeroinitializer, ptr {slot}", ll(&rt)));
                self.label(&le);
                self.load(&slot, rt)
            }
            ExprKind::Field(b, f) => {
                if let Some(tk) = self.type_path(b) {
                    let tk = if self.gtypes.contains_key(&tk) {
                        match self.instance_from_want(&tk, want) {
                            Some(k) => k,
                            None => {
                                let n = short_name(&tk);
                                return err(pos, format!("can't tell which `{n}` this is; give it a type, like `let x: {n}<int> = {n}.{f}`"));
                            }
                        }
                    } else {
                        tk
                    };
                    let k = format!("{tk}::{f}");
                    if self.statics.contains(&k) {
                        return self.fn_value(k, pos);
                    }
                    return self.variant_value(&tk, f, pos);
                }
                if let ExprKind::Var(m) = &b.kind {
                    if self.is_module(m) {
                        let k = format!("{m}.{f}");
                        if self.consts.contains_key(&k) {
                            return Ok(self.const_value(&k));
                        }
                        if !self.funcs.contains_key(&k) {
                            return err(pos, format!("module `{m}` has no function or constant `{f}`"));
                        }
                        return self.fn_value(k, pos);
                    }
                }
                let b = self.expr(b, None)?;
                self.note(pos, format!("@recv {}", b.ty));
                if !matches!(b.ty, Type::Struct(_) | Type::Opt(_) | Type::Enum(_)) {
                    return err(pos, format!("`{f}` is a method here; call it: `.{f}()`"));
                }
                let (p, t) = self.field_ptr(&b, f, pos)?;
                self.note(pos, format!("{}.{f}: {t}", b.ty));
                self.load(&p, t)
            }
            ExprKind::Index(b, i) => {
                let h = self.expr(b, None)?;
                match h.ty.clone() {
                    Type::Str => {
                        let i = self.typed(i, &Type::Int)?;
                        let w = self.where_(pos);
                        let m = self.str_const(&format!("{w}: panic: index out of bounds\n"));
                        self.rt(Type::Str, "st_char_at", &[format!("ptr {}", h.v), format!("i64 {}", i.v), format!("ptr {m}")])
                    }
                    Type::Map(kt, vt) => {
                        let k = self.typed(i, &kt)?;
                        let (found, v) = self.map_get(&h.v, &k, &vt);
                        let missing = self.tmp();
                        self.ins(format!("{missing} = xor i1 {found}, true"));
                        self.check(&missing, "key not in map (use `.get(key, default)` or `key in map`)", pos);
                        v
                    }
                    _ => {
                        let (p, t, _) = self.index_ptr(&h, i, pos)?;
                        self.load(&p, t)
                    }
                }
            }
            ExprKind::Unary(op, x) => {
                let v = self.expr(x, peel(want))?;
                let (want, code) = match (*op, &v.ty) {
                    ('-', Type::Float) => (Type::Float, format!("fneg double {}", v.v)),
                    ('-', _) => (Type::Int, format!("sub i64 0, {}", v.v)),
                    ('~', _) => (Type::Int, format!("xor i64 {}, -1", v.v)),
                    _ => (Type::Bool, format!("xor i1 {}, true", v.v)),
                };
                expect_ty(&want, &v.ty, x.pos)?;
                let t = self.tmp();
                self.ins(format!("{t} = {code}"));
                val(t, want)
            }
            ExprKind::Binary(Tok::QuestionQuestion, l, r) => self.coalesce(l, r, want, pos)?,
            ExprKind::Binary(op, l, r) => self.binary(op, l, r, pos)?,
            ExprKind::Call(callee, args) => self.call(callee, args, pos, want)?,
            ExprKind::List(xs) => {
                let elem_want = match peel(want) {
                    Some(Type::List(t)) => Some((**t).clone()),
                    _ => None,
                };
                let mut vs = vec![];
                for x in xs {
                    let w = elem_want.clone().or_else(|| vs.first().map(|v: &Val| v.ty.clone()));
                    let v = match &w {
                        Some(w) => self.typed(x, w)?,
                        None => self.expr(x, None)?,
                    };
                    vs.push(v);
                }
                let Some(et) = elem_want.or_else(|| vs.first().map(|v| v.ty.clone())) else {
                    return err(pos, "can't tell what this empty list holds; write `let xs: [int] = []`");
                };
                if et == Type::Void {
                    return err(pos, "list elements need a value");
                }
                let esz = self.size_of(&et);
                let h = self.rt(Type::Str, "st_vec_new", &[format!("i64 {}", vs.len()), format!("i64 {esz}"), format!("i64 {}", atomic(&et))]).v;
                let (_, d) = self.vec_parts(&h);
                for (i, v) in vs.iter().enumerate() {
                    let p = self.tmp();
                    self.ins(format!("{p} = getelementptr inbounds {}, ptr {d}, i64 {i}", ll(&et)));
                    self.store(&p, v);
                }
                val(h, Type::List(Box::new(et)))
            }
            ExprKind::Map(pairs) if pairs.is_empty() && matches!(peel(want), Some(Type::Set(_))) => {
                let Some(t @ Type::Set(k)) = peel(want) else { unreachable!() };
                check_key(k, pos)?;
                val(self.map_new(k), t.clone())
            }
            ExprKind::Map(pairs) => {
                let (mut kt, mut vt) = match peel(want) {
                    Some(Type::Map(k, v)) => (Some((**k).clone()), Some((**v).clone())),
                    _ => (None, None),
                };
                let mut vs = vec![];
                for (k, v) in pairs {
                    let k = match &kt { Some(t) => self.typed(k, t)?, None => self.expr(k, None)? };
                    let v = match &vt { Some(t) => self.typed(v, t)?, None => self.expr(v, None)? };
                    kt.get_or_insert(k.ty.clone());
                    vt.get_or_insert(v.ty.clone());
                    vs.push((k, v));
                }
                let (Some(kt), Some(vt)) = (kt, vt) else {
                    return err(pos, "can't tell what this empty map holds; write `let m: {str: int} = {}`");
                };
                check_key(&kt, pos)?;
                if !fits_slot(&vt) {
                    return err(pos, format!("a map can't hold {vt} (put it in a struct)"));
                }
                let m = self.map_new(&kt);
                for (k, v) in &vs {
                    self.map_set(&m, k, Some(v));
                }
                val(m, Type::Map(Box::new(kt), Box::new(vt)))
            }
            ExprKind::Set(xs) => {
                let mut et = match peel(want) {
                    Some(Type::Set(t)) => Some((**t).clone()),
                    _ => None,
                };
                let mut vs = vec![];
                for x in xs {
                    let v = match &et { Some(t) => self.typed(x, t)?, None => self.expr(x, None)? };
                    et.get_or_insert(v.ty.clone());
                    vs.push(v);
                }
                let et = et.unwrap(); // the parser never makes an empty set
                check_key(&et, pos)?;
                let m = self.map_new(&et);
                for v in &vs {
                    self.map_set(&m, v, None);
                }
                val(m, Type::Set(Box::new(et)))
            }
            ExprKind::StructLit(name, fields) => match self.lit_target(name, want, pos)? {
                Lit::Struct(k) if self.gtypes.contains_key(&k) => {
                    let tf = self.template_fields(&k, None);
                    let given: Vec<(Type, &Expr)> = fields.iter().filter_map(|(f, e)| tf.iter().find(|x| x.0 == *f).map(|x| (x.1.clone(), e))).collect();
                    let k = self.infer_type(&k, &given, want, pos)?;
                    let decl = self.structs[&k].clone();
                    let vals = self.fill(name, &k, &decl, Some(fields), None, pos)?;
                    let obj = self.build(&format!("%\"S.{k}\""), None, &vals);
                    val(obj, Type::Struct(k))
                }
                Lit::GVariant(tk, v) => {
                    let tf = self.template_fields(&tk, Some(&v));
                    let given: Vec<(Type, &Expr)> = fields.iter().filter_map(|(f, e)| tf.iter().find(|x| x.0 == *f).map(|x| (x.1.clone(), e))).collect();
                    let k = self.infer_type(&tk, &given, want, pos)?;
                    let i = self.variant_index(&k, &v, pos)?;
                    if !self.enums[&k][i].braces {
                        return err(pos, format!("`{v}` takes its values in parentheses: `{v}(...)`"));
                    }
                    self.make_variant(&k, i, Some(fields), None, pos)?
                }
                Lit::Struct(k) => {
                    let decl = self.structs[&k].clone();
                    let vals = self.fill(name, &k, &decl, Some(fields), None, pos)?;
                    let obj = self.build(&format!("%\"S.{k}\""), None, &vals);
                    val(obj, Type::Struct(k))
                }
                Lit::Variant(k, i) => {
                    let v = self.enums[&k][i].clone();
                    if !v.braces {
                        return err(pos, format!("`{}` takes its values in parentheses: `{}(...)`", v.name, v.name));
                    }
                    self.make_variant(&k, i, Some(fields), None, pos)?
                }
            },
            ExprKind::Lambda(l) => self.lambda(l, peel(want), pos)?,
            ExprKind::Try(x) => {
                // `let t: Todo = from_json(s)?`: the call is asked for a Todo!
                let w = want.filter(|_| is_call_to(x, "from_json")).map(|w| Type::Result(Box::new(w.clone())));
                let v = self.expr(x, w.as_ref())?;
                self.try_val(v, pos)?
            }
            ExprKind::CatchValue(x, fallback) => {
                let w = want.filter(|_| is_call_to(x, "from_json")).map(|w| Type::Result(Box::new(w.clone())));
                let v = self.expr(x, w.as_ref())?;
                let (e, t) = self.failed(&v, pos)?;
                if t == Type::Void {
                    return err(pos, "this has no value to fall back from; use `catch e { ... }`");
                }
                let slot = self.alloca(&t);
                let (lerr, lok, lend) = (self.lbl("caught"), self.lbl("fine"), self.lbl("endcatch"));
                self.term(format!("br i1 {}, label %{lerr}, label %{lok}", e.v));
                self.label(&lok);
                let ok = self.extract(&v, 1, t.clone());
                self.store(&slot, &ok);
                self.term(format!("br label %{lend}"));
                self.label(&lerr);
                let fb = self.typed(fallback, &t)?;
                self.store(&slot, &fb);
                self.label(&lend);
                self.load(&slot, t)
            }
            ExprKind::CatchBlock(x, name, block) => {
                let w = want.filter(|_| is_call_to(x, "from_json")).map(|w| Type::Result(Box::new(w.clone())));
                let v = self.expr(x, w.as_ref())?;
                let (e, t) = self.failed(&v, pos)?;
                let is_opt = matches!(v.ty, Type::Opt(_));
                if is_opt && name != "_" {
                    return err(pos, "an optional has no error message; write `catch _ { ... }`");
                }
                let slot = (t != Type::Void).then(|| self.alloca(&t));
                let (lerr, lok, lend) = (self.lbl("caught"), self.lbl("fine"), self.lbl("endcatch"));
                self.term(format!("br i1 {}, label %{lerr}, label %{lok}", e.v));
                self.label(&lok);
                if let Some(s) = &slot {
                    let ok = self.extract(&v, 1, t.clone());
                    self.store(s, &ok);
                }
                self.term(format!("br label %{lend}"));
                self.label(&lerr);
                self.f.scopes.push(HashMap::new());
                if name != "_" {
                    let m = self.extract(&v, 2, Type::Str);
                    self.declare(name, &m, false);
                }
                // the block either leaves, or its last line is the value to use instead
                let r = match &slot {
                    Some(_) => self.block_value(block, Some(&t)),
                    None => self.block(block).map(|_| void()),
                };
                self.f.scopes.pop();
                let fb = r?;
                if let (true, Some(s)) = (self.f.open, &slot) {
                    if fb.ty == Type::Void {
                        return err(pos, format!("this `catch` block must leave (return, break or continue) or end with a {t} to use instead"));
                    }
                    let fb = self.coerce(fb, &t, pos)?;
                    self.store(s, &fb);
                }
                self.label(&lend);
                match slot {
                    Some(s) => self.load(&s, t),
                    None => void(),
                }
            }
            ExprKind::Match(subject, arms) => self.match_expr(subject, arms, want)?,
            ExprKind::Element(el) => self.element_value(el)?,
            ExprKind::JsxPush(cs) => {
                if self.jsx.is_empty() {
                    return err(pos, "JSX children outside an element");
                }
                self.jsx_children(cs)?;
                self.jsx_flush();
                void()
            }
        })
    }

    fn fn_value(&mut self, key: String, pos: Pos) -> R<Val> {
        let s = self.funcs[&key].clone();
        if s.is_extern {
            return err(pos, "an extern function can't be used as a value; wrap it in a lambda");
        }
        if !self.wrappers.contains(&key) {
            self.wrappers.push(key.clone());
        }
        Ok(val(format!("@\"clo.{key}\""), Type::Fn(s.params, Box::new(s.ret))))
    }

    fn lambda(&mut self, l: &Lambda, want: Option<&Type>, pos: Pos) -> R<Val> {
        match want {
            Some(Type::Fn(ps, r)) => self.lambda_typed(l, Some(ps.clone()), Some((**r).clone()), pos),
            _ => self.lambda_typed(l, None, None, pos),
        }
    }

    /// A lambda whose parameter and/or return types may come from where it's used.
    fn lambda_typed(&mut self, l: &Lambda, wps: Option<Vec<Type>>, wret: Option<Type>, pos: Pos) -> R<Val> {
        if let Some(ps) = &wps {
            if ps.len() != l.params.len() {
                return err(pos, format!("expected a function taking {} argument(s), this lambda takes {}", ps.len(), l.params.len()));
            }
        }
        let mut params = vec![];
        for (i, (n, t)) in l.params.iter().enumerate() {
            let t = match (t, &wps) {
                (Some(t), _) => self.resolve(t, pos)?,
                (None, Some(ps)) => ps[i].clone(),
                (None, None) => return err(pos, format!("can't tell the type of `{n}`; write `({n}: int) => ...`")),
            };
            params.push((n.clone(), t));
        }
        let ret = match &l.ret {
            Some(t) => Some(self.resolve(t, pos)?),
            None => wret.or(matches!(l.body, Body::Block(_)).then_some(Type::Void)),
        };
        let mut names = HashSet::new();
        names_body(&l.body, true, &mut names);
        let mut caps: Vec<(String, Var)> = names.into_iter().filter_map(|n| self.find(&n).map(|v| (n, v))).collect();
        caps.sort_by(|a, b| a.0.cmp(&b.0));
        self.n += 1;
        let sym = format!("@\"st.lambda{}\"", self.n);
        let rt = self.function(&sym, &params, ret, &l.body, None, &caps, pos, "this lambda")?;
        let obj = self.rt(Type::Str, "st_alloc", &[format!("i64 {}", (caps.len() + 1) * 8)]).v;
        self.ins(format!("store ptr {sym}, ptr {obj}"));
        for (i, (_, v)) in caps.iter().enumerate() {
            let g = self.tmp();
            self.ins(format!("{g} = getelementptr ptr, ptr {obj}, i64 {}", i + 1));
            self.ins(format!("store ptr {}, ptr {g}", v.addr));
        }
        Ok(val(obj, Type::Fn(params.into_iter().map(|p| p.1).collect(), Box::new(rt))))
    }

    /// `v?`: the value inside a result or optional, or return the error / none from the function.
    fn try_val(&mut self, v: Val, pos: Pos) -> R<Val> {
        if let Type::Opt(t) = v.ty.clone() {
            if !matches!(self.f.ret, Type::Opt(_)) {
                return err(pos, "`?` on an optional passes `none` up, so the function must return an optional (like `-> int?`). Or use `?? fallback` / `let x = ... else { ... }`");
            }
            let has = self.extract(&v, 0, Type::Bool);
            let (lnone, lok) = (self.lbl("none"), self.lbl("some"));
            self.term(format!("br i1 {}, label %{lok}, label %{lnone}", has.v));
            self.label(&lnone);
            self.term(format!("ret {} zeroinitializer", ll(&self.f.ret)));
            self.label(&lok);
            return Ok(self.extract(&v, 1, *t));
        }
        let Type::Result(t) = v.ty.clone() else {
            return err(pos, format!("`?` needs a result (like int!) or an optional (int?), but this is {}", v.ty));
        };
        let Type::Result(ft) = self.f.ret.clone() else {
            return err(pos, "`?` passes the error up, so the function must return a result (like `-> int!`)");
        };
        let e = self.extract(&v, 0, Type::Bool);
        let (lf, lok) = (self.lbl("fail"), self.lbl("ok"));
        self.term(format!("br i1 {}, label %{lf}, label %{lok}", e.v));
        self.label(&lf);
        let m = self.extract(&v, 2, Type::Str);
        let r = self.err_of(&ft, &m.v);
        self.term(format!("ret {} {}", ll(&r.ty), r.v));
        self.label(&lok);
        Ok(if *t == Type::Void { void() } else { self.extract(&v, 1, *t) })
    }

    /// A read-only local holding `v` (for the value inside `a?.b`).
    fn temp_var(&mut self, v: &Val) -> Var {
        let a = self.alloca(&v.ty);
        self.store(&a, v);
        Var { addr: a, ty: v.ty.clone(), mutable: false }
    }

    /// For a result or an optional: (an i1 that is true when it holds no value, the value's type).
    fn failed(&mut self, v: &Val, pos: Pos) -> R<(Val, Type)> {
        match v.ty.clone() {
            Type::Result(t) => Ok((self.extract(v, 0, Type::Bool), *t)),
            Type::Opt(t) => {
                let has = self.extract(v, 0, Type::Bool);
                let n = self.tmp();
                self.ins(format!("{n} = xor i1 {}, true", has.v));
                Ok((val(n, Type::Bool), *t))
            }
            t => err(pos, format!("`catch` and `??` need a result (like int!) or an optional (int?), not {t}")),
        }
    }

    fn const_value(&mut self, k: &str) -> Val {
        let t = self.consts[k].clone();
        self.load(&format!("@\"g.{k}\""), t)
    }

    /// `a ?? b`: the value inside `a`, or `b` (only evaluated when needed).
    fn coalesce(&mut self, l: &Expr, r: &Expr, want: Option<&Type>, pos: Pos) -> R<Val> {
        let lw = match peel(want) {
            Some(Type::Opt(t)) => Some(Type::Opt(t.clone())),
            Some(t) if *t != Type::Void => Some(Type::Opt(Box::new(t.clone()))),
            _ => None,
        };
        let a = self.expr(l, lw.as_ref())?;
        let (missing, t) = self.failed(&a, pos)?;
        if t == Type::Void {
            return err(pos, "this has no value to fall back from");
        }
        let (lnone, lsome, lend) = (self.lbl("none"), self.lbl("some"), self.lbl("endor"));
        self.term(format!("br i1 {}, label %{lnone}, label %{lsome}", missing.v));
        self.label(&lnone);
        let b = self.expr(r, Some(&t))?;
        // `a ?? b` where `b` is optional too stays optional
        let rt = if b.ty == Type::Opt(Box::new(t.clone())) { b.ty.clone() } else { t.clone() };
        let slot = self.alloca(&rt);
        if self.f.open {
            let b = self.coerce(b, &rt, r.pos)?;
            self.store(&slot, &b);
            self.term(format!("br label %{lend}"));
        }
        self.label(&lsome);
        let x = self.extract(&a, 1, t);
        let x = self.coerce(x, &rt, pos)?;
        self.store(&slot, &x);
        self.label(&lend);
        Ok(self.load(&slot, rt))
    }

    fn binary(&mut self, op: &Tok, l: &Expr, r: &Expr, pos: Pos) -> R<Val> {
        if matches!(op, Tok::AndAnd | Tok::OrOr) {
            let and = *op == Tok::AndAnd;
            let a = self.cond(l)?;
            let (lr, le) = (self.lbl("rhs"), self.lbl("sc"));
            self.ensure_open();
            let from = self.f.cur.clone();
            self.term(if and {
                format!("br i1 {a}, label %{lr}, label %{le}")
            } else {
                format!("br i1 {a}, label %{le}, label %{lr}")
            });
            self.label(&lr);
            let b = self.cond(r)?;
            self.ensure_open();
            let rfrom = self.f.cur.clone();
            self.term(format!("br label %{le}"));
            self.label(&le);
            let t = self.tmp();
            self.ins(format!("{t} = phi i1 [ {}, %{from} ], [ {b}, %{rfrom} ]", !and));
            return Ok(val(t, Type::Bool));
        }
        let a = self.expr(l, None)?;
        if *op == Tok::In {
            let c = self.expr(r, None)?;
            return self.contains(&c, a, pos);
        }
        let b = self.expr(r, Some(&a.ty))?;
        if a.ty == Type::Str && *op == Tok::Plus {
            if b.ty != Type::Str {
                return err(r.pos, format!("expected str, found {} (use \"${{x}}\" or str(x))", b.ty));
            }
            return Ok(self.rt(Type::Str, "st_concat", &[format!("ptr {}", a.v), format!("ptr {}", b.v)]));
        }
        if matches!(op, Tok::Eq | Tok::Ne) {
            let e = self.eq(a, b, pos)?;
            if *op == Tok::Eq {
                return Ok(val(e, Type::Bool));
            }
            let t = self.tmp();
            self.ins(format!("{t} = xor i1 {e}, true"));
            return Ok(val(t, Type::Bool));
        }
        if matches!(op, Tok::Amp | Tok::Pipe | Tok::Caret | Tok::Shl | Tok::Shr) {
            for (v, e) in [(&a, l), (&b, r)] {
                if v.ty != Type::Int {
                    return err(e.pos, format!("{op} works on ints, not {}", v.ty));
                }
            }
            let t = self.tmp();
            let inst = match op {
                Tok::Amp => "and",
                Tok::Pipe => "or",
                Tok::Caret => "xor",
                Tok::Shl => "shl",
                _ => "ashr",
            };
            let mut amount = b.v.clone();
            if matches!(op, Tok::Shl | Tok::Shr) {
                // shifting by 64 or more is undefined in LLVM; use the low 6 bits (like Java and x86)
                amount = self.tmp();
                self.ins(format!("{amount} = and i64 {}, 63", b.v));
            }
            self.ins(format!("{t} = {inst} i64 {}, {amount}", a.v));
            return Ok(val(t, Type::Int));
        }
        let (a, b) = self.promote(a, b, pos)?;
        let cmp = matches!(op, Tok::Lt | Tok::Le | Tok::Gt | Tok::Ge);
        let cc = match op {
            Tok::Lt => "lt",
            Tok::Le => "le",
            Tok::Gt => "gt",
            _ => "ge",
        };
        if a.ty == Type::Str && cmp {
            let b = self.coerce(b, &Type::Str, r.pos)?;
            let c = self.rt(Type::Int, "st_strcmp", &[format!("ptr {}", a.v), format!("ptr {}", b.v)]);
            let t = self.tmp();
            self.ins(format!("{t} = icmp s{cc} i64 {}, 0", c.v));
            return Ok(val(t, Type::Bool));
        }
        if let Type::Opt(_) = a.ty {
            return err(l.pos, format!("this is optional ({}); unwrap it first: `x ?? 0`, `if let x = ...` or `?`", a.ty));
        }
        if !matches!(a.ty, Type::Int | Type::Float) {
            return err(l.pos, format!("{op} works on numbers, not {}", a.ty));
        }
        let ty = a.ty.clone();
        expect_ty(&ty, &b.ty, r.pos)?;
        let float = ty == Type::Float;
        let (fi, ii) = match op {
            Tok::Plus => ("fadd", "add"),
            Tok::Minus => ("fsub", "sub"),
            Tok::Times => ("fmul", "mul"),
            Tok::Slash => ("fdiv", "sdiv"),
            Tok::Percent => ("frem", "srem"),
            _ => ("fcmp o", "icmp s"),
        };
        let inst = format!("{}{}", if float { fi } else { ii }, if cmp { cc } else { "" });
        if !float && matches!(op, Tok::Slash | Tok::Percent) {
            // sdiv/srem by 0 or MIN/-1 is UB in LLVM; make it a defined panic
            let (z, m1, mn, o, bad) = (self.tmp(), self.tmp(), self.tmp(), self.tmp(), self.tmp());
            self.ins(format!("{z} = icmp eq i64 {}, 0", b.v));
            self.ins(format!("{m1} = icmp eq i64 {}, -1", b.v));
            self.ins(format!("{mn} = icmp eq i64 {}, {}", a.v, i64::MIN));
            self.ins(format!("{o} = and i1 {m1}, {mn}"));
            self.ins(format!("{bad} = or i1 {z}, {o}"));
            self.check(&bad, "division by zero or overflow", pos);
        }
        let t = self.tmp();
        self.ins(format!("{t} = {inst} {} {}, {}", ll(&ty), a.v, b.v));
        Ok(val(t, if cmp { Type::Bool } else { ty }))
    }

    fn args(&mut self, params: &[Type], args: &[Expr], pos: Pos, name: &str) -> R<Vec<String>> {
        if args.len() != params.len() {
            return err(pos, format!("`{name}` takes {} argument(s), got {}", params.len(), args.len()));
        }
        let mut out = vec![];
        for (pt, a) in params.iter().zip(args) {
            let v = self.typed(a, pt)?;
            out.push(format!("{} {}", ll(pt), v.v));
        }
        Ok(out)
    }

    /// Arguments for a declared function (from parameter `skip` on); trailing ones it leaves out take their defaults.
    fn sig_args(&mut self, sig: &Sig, skip: usize, args: &[Expr], pos: Pos, name: &str) -> R<Vec<String>> {
        let params = &sig.params[skip..];
        let need = (skip..sig.params.len()).take_while(|&i| sig.defaults.get(i).is_none_or(Option::is_none)).count();
        if args.len() < need || args.len() > params.len() {
            let n = if need == params.len() { need.to_string() } else { format!("{need} to {}", params.len()) };
            return err(pos, format!("`{name}` takes {n} argument(s), got {}", args.len()));
        }
        let mut out = self.args(&params[..args.len()], args, pos, name)?;
        for i in skip + args.len()..sig.params.len() {
            let e = sig.defaults[i].clone().unwrap();
            let v = self.call_default(&default_sym(&sig.sym, i), &e, &sig.module, &sig.params[i])?;
            out.push(format!("{} {}", ll(&v.ty), v.v));
        }
        Ok(out)
    }

    fn call(&mut self, callee: &Expr, args: &[Expr], pos: Pos, want: Option<&Type>) -> R<Val> {
        match &callee.kind {
            ExprKind::Var(name) if self.find(name).is_none() => {
                if let Some((_, s)) = BUILTIN_SIGS.iter().find(|b| b.0 == name) {
                    self.note(callee.pos, s.to_string());
                }
                if let Some(v) = self.builtin(name, args, pos, want)? {
                    return Ok(v);
                }
                if self.gfns.contains_key(&self.key(name)) {
                    return self.call_generic(&self.key(name), None, args, pos, want);
                }
                let Some(sig) = self.funcs.get(&self.key(name)).cloned() else {
                    return err(pos, format!("unknown function `{name}`"));
                };
                self.note(callee.pos, sig_text(name, &sig));
                let argl = self.sig_args(&sig, 0, args, pos, name)?;
                Ok(self.emit_call(&sig.ret, &sig.sym, &argl))
            }
            ExprKind::Member(name) => {
                self.probe_want(callee.pos, want);
                let target = peel_all(want).cloned();
                match target {
                    Some(Type::Enum(k)) if self.enums[&k].iter().any(|v| v.name == *name) => {
                        let i = self.enums[&k].iter().position(|v| v.name == *name).unwrap();
                        self.make_variant(&k, i, None, Some(args), pos)
                    }
                    Some(Type::Enum(k) | Type::Struct(k)) if self.gfns.contains_key(&format!("{k}::{name}")) && self.statics.contains(&format!("{k}::{name}")) => {
                        self.call_generic(&format!("{k}::{name}"), None, args, pos, want)
                    }
                    Some(Type::Enum(k) | Type::Struct(k)) if self.statics.contains(&format!("{k}::{name}")) => {
                        let sig = self.funcs[&format!("{k}::{name}")].clone();
                        let argl = self.sig_args(&sig, 0, args, pos, name)?;
                        Ok(self.emit_call(&sig.ret, &sig.sym, &argl))
                    }
                    Some(t @ (Type::Enum(_) | Type::Struct(_))) => err(pos, format!("{t} has no variant or static function `{name}`")),
                    _ => err(pos, format!("can't tell which type `.{name}` belongs to; write `Type.{name}(...)`")),
                }
            }
            ExprKind::Field(base, name) => {
                if let Some(tk) = self.type_path(base) {
                    let tk = if self.gtypes.contains_key(&tk) {
                        let variant = matches!(&self.gtypes[&tk].def, GDef::Enum(e) if e.variants.iter().any(|v| v.name == *name));
                        let pats: Vec<Type> = if variant {
                            self.template_fields(&tk, Some(name)).into_iter().map(|f| f.1).collect()
                        } else {
                            match self.gtypes[&tk].methods.iter().find(|m| m.name == *name) {
                                Some(m) if m.tparams.is_empty() => m.params.iter().map(|p| p.1.clone().unwrap_or_default()).collect(),
                                _ => vec![],
                            }
                        };
                        let given: Vec<(Type, &Expr)> = pats.into_iter().zip(args.iter()).collect();
                        self.infer_type(&tk, &given, want, pos)?
                    } else {
                        tk
                    };
                    if let Some(i) = self.enums.get(&tk).and_then(|vs| vs.iter().position(|v| v.name == *name)) {
                        return self.make_variant(&tk, i, None, Some(args), pos);
                    }
                    let k = format!("{tk}::{name}");
                    if self.gfns.contains_key(&k) && self.statics.contains(&k) {
                        return self.call_generic(&k, None, args, pos, want);
                    }
                    let Some(sig) = self.funcs.get(&k).cloned() else {
                        let what = if self.enums.contains_key(&tk) { "variant or function" } else { "function" };
                        return err(pos, format!("`{tk}` has no {what} `{name}`"));
                    };
                    if !self.statics.contains(&k) {
                        return err(pos, format!("`{name}` is a method; call it on a value: `x.{name}(...)`"));
                    }
                    self.note(callee.pos, sig_text(&format!("{tk}.{name}"), &sig));
                    let argl = self.sig_args(&sig, 0, args, pos, name)?;
                    return Ok(self.emit_call(&sig.ret, &sig.sym, &argl));
                }
                if let ExprKind::Var(m) = &base.kind {
                    if self.is_module(m) {
                        if self.gfns.contains_key(&format!("{m}.{name}")) {
                            return self.call_generic(&format!("{m}.{name}"), None, args, pos, want);
                        }
                        let Some(sig) = self.funcs.get(&format!("{m}.{name}")).cloned() else {
                            return err(pos, format!("module `{m}` has no function `{name}`"));
                        };
                        self.note(callee.pos, sig_text(&format!("{m}.{name}"), &sig));
                        let argl = self.sig_args(&sig, 0, args, pos, name)?;
                        return Ok(self.emit_call(&sig.ret, &sig.sym, &argl));
                    }
                }
                let b = self.expr(base, None)?;
                self.note(callee.pos, format!("@recv {}", b.ty));
                if name == "is_empty" && args.is_empty() {
                    if let Some(n) = self.len_of(&b) {
                        let t = self.tmp();
                        self.ins(format!("{t} = icmp eq i64 {n}, 0"));
                        return Ok(val(t, Type::Bool));
                    }
                }
                if let Some(owner) = Self::method_owner(&b.ty) {
                    let k = format!("{owner}::{name}");
                    if self.gfns.contains_key(&k) {
                        if self.statics.contains(&k) {
                            return err(pos, format!("`{name}` is a static function; call it as `{}.{name}(...)`", short_name(&owner)));
                        }
                        return self.call_generic(&k, Some(b), args, pos, want);
                    }
                    if prim_name(&b.ty).is_some() {
                        if let Some(sig) = self.funcs.get(&k).cloned() {
                            if self.statics.contains(&k) {
                                return err(pos, format!("`{name}` is a static function; call it as `{owner}.{name}(...)`"));
                            }
                            self.note(callee.pos, sig_text(&format!("{owner}.{name}"), &sig));
                            let mut argl = vec![format!("{} {}", ll(&b.ty), b.v)];
                            argl.extend(self.sig_args(&sig, 1, args, pos, name)?);
                            return Ok(self.emit_call(&sig.ret, &sig.sym, &argl));
                        }
                    }
                }
                match b.ty.clone() {
                    Type::Struct(sk) | Type::Enum(sk) => {
                        let k = format!("{sk}::{name}");
                        if let Some(sig) = self.funcs.get(&k).cloned() {
                            if self.statics.contains(&k) {
                                return err(pos, format!("`{name}` is a static function; call it as `{sk}.{name}(...)`"));
                            }
                            self.note(callee.pos, sig_text(&format!("{sk}.{name}"), &sig));
                            let mut argl = vec![format!("ptr {}", b.v)];
                            argl.extend(self.sig_args(&sig, 1, args, pos, name)?);
                            return Ok(self.emit_call(&sig.ret, &sig.sym, &argl));
                        }
                        if matches!(b.ty, Type::Enum(_)) {
                            return err(pos, format!("{sk} has no method `{name}`"));
                        }
                        let (p, t) = self.field_ptr(&b, name, pos)?;
                        let c = self.load(&p, t);
                        self.call_closure(c, args, pos)
                    }
                    Type::Str => {
                        let Some((cf, ps, ret, located)) = str_method(name) else {
                            return err(pos, format!("str has no method `{name}`"));
                        };
                        let mut argl = vec![format!("ptr {}", b.v)];
                        argl.extend(self.args(&ps, args, pos, name)?);
                        if located {
                            let w = self.where_(pos);
                            let m = self.str_const(&format!("{w}: panic: {name}() out of range\n"));
                            argl.push(format!("ptr {m}"));
                        }
                        Ok(self.rt(ret, cf, &argl))
                    }
                    Type::List(et) => self.list_method(&b, &et, name, args, pos),
                    Type::Map(kt, vt) => self.map_method(&b, &kt, &vt, name, args, pos),
                    Type::Set(et) => self.set_method(&b, &et, name, args, pos),
                    Type::Opt(t) => self.opt_method(&b, &t, name, args, pos),
                    Type::Float => {
                        self.args(&[], args, pos, name)?;
                        let f = match name.as_str() {
                            "floor" | "ceil" | "round" | "sqrt" => name.as_str(),
                            "abs" => "fabs",
                            _ => return err(pos, format!("float has no method `{name}` (try floor, ceil, round, sqrt, abs)")),
                        };
                        Ok(self.emit_call(&Type::Float, &format!("@llvm.{f}.f64"), &[format!("double {}", b.v)]))
                    }
                    t => err(pos, format!("{t} has no method `{name}`")),
                }
            }
            _ => {
                let c = self.expr(callee, None)?;
                self.call_closure(c, args, pos)
            }
        }
    }

    fn call_closure(&mut self, c: Val, args: &[Expr], pos: Pos) -> R<Val> {
        let Type::Fn(ps, r) = c.ty.clone() else { return err(pos, format!("{} is not a function", c.ty)) };
        let mut argl = vec![format!("ptr {}", c.v)];
        argl.extend(self.args(&ps, args, pos, "this function")?);
        let fp = self.load(&c.v, Type::Str).v;
        Ok(self.emit_call(&r, &fp, &argl))
    }

    /// Call closure `c` with already computed arguments.
    fn call_val(&mut self, c: &Val, args: &[Val]) -> Val {
        let Type::Fn(_, r) = &c.ty else { unreachable!() };
        let mut argl = vec![format!("ptr {}", c.v)];
        argl.extend(args.iter().map(|a| format!("{} {}", ll(&a.ty), a.v)));
        let fp = self.load(&c.v, Type::Str).v;
        self.emit_call(r, &fp, &argl)
    }

    /// The function argument of `map`, `filter`, ...: a lambda gets its parameter types from the list.
    fn fn_arg(&mut self, args: &[Expr], params: Vec<Type>, ret: Option<Type>, pos: Pos, name: &str) -> R<Val> {
        let [a] = args else { return err(pos, format!("`{name}` takes 1 argument, got {}", args.len())) };
        let f = match &a.kind {
            ExprKind::Lambda(l) => self.lambda_typed(l, Some(params.clone()), ret.clone(), a.pos)?,
            _ => self.expr(a, None)?,
        };
        match &f.ty {
            Type::Fn(ps, r) if *ps == params && ret.as_ref().is_none_or(|w| w == &**r) && **r != Type::Void => Ok(f),
            t => {
                let ps: Vec<String> = params.iter().map(|p| p.to_string()).collect();
                let r = ret.map_or("a value".into(), |r| r.to_string());
                err(a.pos, format!("`{name}` needs a function from ({}) to {r}, not {t}", ps.join(", ")))
            }
        }
    }

    fn located(&mut self, what: &str, pos: Pos) -> String {
        let w = self.where_(pos);
        let m = self.str_const(&format!("{w}: panic: {what}\n"));
        format!("ptr {m}")
    }

    fn list_method(&mut self, h: &Val, et: &Type, name: &str, args: &[Expr], pos: Pos) -> R<Val> {
        let one = std::slice::from_ref(et);
        let hp = format!("ptr {}", h.v);
        Ok(match name {
            "len" => {
                self.args(&[], args, pos, name)?;
                self.load(&h.v, Type::Int)
            }
            "push" => {
                let [a] = args else { return err(pos, format!("`push` takes 1 argument, got {}", args.len())) };
                let x = self.typed(a, et)?;
                self.push(&h.v, &x);
                void()
            }
            "pop" => {
                self.args(&[], args, pos, name)?;
                let (len, d) = self.vec_parts(&h.v);
                let empty = self.tmp();
                self.ins(format!("{empty} = icmp eq i64 {len}, 0"));
                self.check(&empty, "pop() on an empty list", pos);
                let (n1, p) = (self.tmp(), self.tmp());
                self.ins(format!("{n1} = sub i64 {len}, 1"));
                self.ins(format!("store i64 {n1}, ptr {}", h.v));
                self.ins(format!("{p} = getelementptr inbounds {}, ptr {d}, i64 {n1}", ll(et)));
                self.load(&p, et.clone())
            }
            "insert" => {
                let [i, x] = args else { return err(pos, format!("`insert` takes 2 arguments (index, item), got {}", args.len())) };
                let (i, x) = (self.typed(i, &Type::Int)?, self.typed(x, et)?);
                let (esz, w) = (self.size_of(et), self.located("insert() index out of bounds", pos));
                self.rt(Type::Void, "st_vec_insert", &[hp, format!("i64 {}", i.v), format!("i64 {esz}"), w]);
                let (_, d) = self.vec_parts(&h.v);
                let p = self.tmp();
                self.ins(format!("{p} = getelementptr inbounds {}, ptr {d}, i64 {}", ll(et), i.v));
                self.store(&p, &x);
                void()
            }
            "remove" => {
                let [i] = args else { return err(pos, format!("`remove` takes 1 argument (the index), got {}", args.len())) };
                let (p, _, i) = self.index_ptr(h, i, pos)?;
                let x = self.load(&p, et.clone());
                let esz = self.size_of(et);
                self.rt(Type::Void, "st_vec_remove", &[hp, format!("i64 {i}"), format!("i64 {esz}")]);
                x
            }
            "slice" => {
                let a = self.args(&[Type::Int, Type::Int], args, pos, name)?;
                let (esz, w) = (self.size_of(et), self.located("slice() out of range", pos));
                let argl = [hp, a[0].clone(), a[1].clone(), format!("i64 {esz}"), format!("i64 {}", atomic(et)), w];
                self.rt(h.ty.clone(), "st_vec_slice", &argl)
            }
            "first" | "last" | "get" => {
                let (len, d) = self.vec_parts(&h.v);
                let i = match name {
                    "first" => {
                        self.args(&[], args, pos, name)?;
                        "0".to_string()
                    }
                    "last" => {
                        self.args(&[], args, pos, name)?;
                        let t = self.tmp();
                        self.ins(format!("{t} = sub i64 {len}, 1"));
                        t
                    }
                    _ => self.args(&[Type::Int], args, pos, name)?.remove(0).trim_start_matches("i64 ").to_string(),
                };
                let ot = Type::Opt(Box::new(et.clone()));
                let slot = self.alloca(&ot);
                self.ins(format!("store {} zeroinitializer, ptr {slot}", ll(&ot)));
                let (inr, lin, lend) = (self.tmp(), self.lbl("inside"), self.lbl("got"));
                self.ins(format!("{inr} = icmp ult i64 {i}, {len}"));
                self.term(format!("br i1 {inr}, label %{lin}, label %{lend}"));
                self.label(&lin);
                let p = self.tmp();
                self.ins(format!("{p} = getelementptr inbounds {}, ptr {d}, i64 {i}", ll(et)));
                let x = self.load(&p, et.clone());
                let x = self.some_of(&x);
                self.store(&slot, &x);
                self.label(&lend);
                self.load(&slot, ot)
            }
            "find" => {
                let f = self.fn_arg(args, one.to_vec(), Some(Type::Bool), pos, name)?;
                let ot = Type::Opt(Box::new(et.clone()));
                let slot = self.alloca(&ot);
                self.ins(format!("store {} zeroinitializer, ptr {slot}", ll(&ot)));
                let lend = self.lbl("found");
                self.each(h, et, |g, x, _| {
                    let hit = g.call_val(&f, std::slice::from_ref(&x));
                    let ly = g.lbl("hit");
                    let ln = g.lbl("miss");
                    g.term(format!("br i1 {}, label %{ly}, label %{ln}", hit.v));
                    g.label(&ly);
                    let x = g.some_of(&x);
                    g.store(&slot, &x);
                    g.term(format!("br label %{lend}"));
                    g.label(&ln);
                    Ok(())
                })?;
                self.label(&lend);
                self.load(&slot, ot)
            }
            "contains" | "index_of" => {
                let [a] = args else { return err(pos, format!("`{name}` takes 1 argument, got {}", args.len())) };
                let x = self.typed(a, et)?;
                if name == "contains" { self.contains(h, x, pos)? } else { val(self.index_of(h, et, x, pos)?, Type::Int) }
            }
            "reverse" => {
                self.args(&[], args, pos, name)?;
                let esz = self.size_of(et);
                self.rt(Type::Void, "st_vec_reverse", &[hp, format!("i64 {esz}")])
            }
            "sort" => {
                self.args(&[], args, pos, name)?;
                let kind = match et {
                    Type::Int => 0,
                    Type::Float => 1,
                    Type::Str => 2,
                    _ => return err(pos, format!("sort() sorts lists of int, float or str, not [{et}]")),
                };
                self.rt(Type::Void, "st_vec_sort", &[hp, format!("i64 {kind}")])
            }
            "map" => {
                let f = self.fn_arg(args, one.to_vec(), None, pos, name)?;
                let Type::Fn(_, rt) = f.ty.clone() else { unreachable!() };
                let out = self.new_list(&rt);
                self.each(h, et, |g, x, _| {
                    let y = g.call_val(&f, &[x]);
                    g.push(&out.v, &y);
                    Ok(())
                })?;
                out
            }
            "filter" => {
                let f = self.fn_arg(args, one.to_vec(), Some(Type::Bool), pos, name)?;
                let out = self.new_list(et);
                self.each(h, et, |g, x, _| {
                    let keep = g.call_val(&f, std::slice::from_ref(&x));
                    let (ly, ln) = (g.lbl("keep"), g.lbl("skip"));
                    g.term(format!("br i1 {}, label %{ly}, label %{ln}", keep.v));
                    g.label(&ly);
                    g.push(&out.v, &x);
                    g.label(&ln);
                    Ok(())
                })?;
                out
            }
            "any" | "all" => {
                let f = self.fn_arg(args, one.to_vec(), Some(Type::Bool), pos, name)?;
                let any = name == "any";
                let acc = self.alloca(&Type::Bool);
                self.ins(format!("store i1 {}, ptr {acc}", !any));
                self.each(h, et, |g, x, _| {
                    let y = g.call_val(&f, &[x]);
                    let (old, new) = (g.tmp(), g.tmp());
                    g.ins(format!("{old} = load i1, ptr {acc}"));
                    g.ins(format!("{new} = {} i1 {old}, {}", if any { "or" } else { "and" }, y.v));
                    g.ins(format!("store i1 {new}, ptr {acc}"));
                    Ok(())
                })?;
                self.load(&acc, Type::Bool)
            }
            "sum" => {
                self.args(&[], args, pos, name)?;
                let (op, zero) = match et {
                    Type::Int => ("add", "0".to_string()),
                    Type::Float => ("fadd", float_lit(0.0)),
                    _ => return err(pos, format!("sum() adds up numbers, not [{et}]")),
                };
                let acc = self.alloca(et);
                self.ins(format!("store {} {zero}, ptr {acc}", ll(et)));
                self.each(h, et, |g, x, _| {
                    let (old, new) = (g.tmp(), g.tmp());
                    g.ins(format!("{old} = load {}, ptr {acc}", ll(et)));
                    g.ins(format!("{new} = {op} {} {old}, {}", ll(et), x.v));
                    g.ins(format!("store {} {new}, ptr {acc}", ll(et)));
                    Ok(())
                })?;
                self.load(&acc, et.clone())
            }
            "join" => {
                let sep = self.args(&[Type::Str], args, pos, name)?.remove(0);
                let strs = if *et == Type::Str {
                    h.clone()
                } else {
                    let out = self.new_list(&Type::Str);
                    self.each(h, et, |g, x, _| {
                        let s = g.show(&x, false, pos)?;
                        g.push(&out.v, &s);
                        Ok(())
                    })?;
                    out
                };
                self.rt(Type::Str, "st_join", &[format!("ptr {}", strs.v), sep])
            }
            _ => return err(pos, format!("[{et}] has no method `{name}`")),
        })
    }

    fn map_method(&mut self, m: &Val, kt: &Type, vt: &Type, name: &str, args: &[Expr], pos: Pos) -> R<Val> {
        Ok(match (name, args) {
            ("len", []) => val(self.len_of(m).unwrap(), Type::Int),
            ("keys", []) => self.map_list(&m.v, 0, kt),
            ("values", []) => self.map_list(&m.v, 1, vt),
            ("contains", [k]) => {
                let k = self.typed(k, kt)?;
                self.contains(m, k, pos)?
            }
            ("remove", [k]) => {
                let k = self.typed(k, kt)?;
                let ks = self.slot_of(&k);
                self.rt(Type::Bool, "st_map_remove", &[format!("ptr {}", m.v), format!("i64 {ks}")])
            }
            ("get", [k, fallback]) => {
                // m.get(key, default)
                let k = self.typed(k, kt)?;
                let (found, v) = self.map_get(&m.v, &k, vt);
                let d = self.typed(fallback, vt)?;
                let t = self.tmp();
                self.ins(format!("{t} = select i1 {found}, {} {}, {} {}", ll(vt), v.v, ll(vt), d.v));
                val(t, vt.clone())
            }
            ("get", [k]) => {
                // m.get(key) -> V?, for `??`, `if let`, `?` and `match`
                let k = self.typed(k, kt)?;
                let (found, v) = self.map_get(&m.v, &k, vt);
                let rt = Type::Opt(Box::new(vt.clone()));
                let (a, b) = (self.tmp(), self.tmp());
                self.ins(format!("{a} = insertvalue {} zeroinitializer, i1 {found}, 0", ll(&rt)));
                self.ins(format!("{b} = insertvalue {} {a}, {} {}, 1", ll(&rt), ll(vt), v.v));
                val(b, rt)
            }
            _ => return err(pos, format!("{} has no method `{name}` with {} argument(s) (try get, contains, remove, keys, values, len)", m.ty, args.len())),
        })
    }

    fn opt_method(&mut self, o: &Val, t: &Type, name: &str, args: &[Expr], pos: Pos) -> R<Val> {
        let has = self.extract(o, 0, Type::Bool);
        Ok(match (name, args) {
            ("is_some", []) => has,
            ("is_none", []) => {
                let n = self.tmp();
                self.ins(format!("{n} = xor i1 {}, true", has.v));
                val(n, Type::Bool)
            }
            ("unwrap", []) => {
                let n = self.tmp();
                self.ins(format!("{n} = xor i1 {}, true", has.v));
                self.check(&n, "unwrap() on none", pos);
                self.extract(o, 1, t.clone())
            }
            _ => return err(pos, format!("{} has no method `{name}` (try is_some, is_none, unwrap; or unwrap it with `if let`, `??` or `?`)", o.ty)),
        })
    }

    /// `T` -> `T?`
    fn some_of(&mut self, v: &Val) -> Val {
        let ot = Type::Opt(Box::new(v.ty.clone()));
        let (a, b) = (self.tmp(), self.tmp());
        self.ins(format!("{a} = insertvalue {} zeroinitializer, i1 true, 0", ll(&ot)));
        self.ins(format!("{b} = insertvalue {} {a}, {} {}, 1", ll(&ot), ll(&v.ty), v.v));
        val(b, ot)
    }

    fn set_method(&mut self, s: &Val, et: &Type, name: &str, args: &[Expr], pos: Pos) -> R<Val> {
        Ok(match (name, args) {
            ("len", []) => val(self.len_of(s).unwrap(), Type::Int),
            ("to_list", []) => self.map_list(&s.v, 0, et),
            ("add", [x]) => {
                let x = self.typed(x, et)?;
                self.map_set(&s.v, &x, None);
                void()
            }
            ("contains", [x]) => {
                let x = self.typed(x, et)?;
                self.contains(s, x, pos)?
            }
            ("remove", [x]) => {
                let x = self.typed(x, et)?;
                let xs = self.slot_of(&x);
                self.rt(Type::Bool, "st_map_remove", &[format!("ptr {}", s.v), format!("i64 {xs}")])
            }
            _ => return err(pos, format!("{} has no method `{name}` with {} argument(s) (try add, contains, remove, to_list, len)", s.ty, args.len())),
        })
    }

    fn bool_str(&mut self, b: &str) -> String {
        let s = self.tmp();
        self.ins(format!("{s} = select i1 {b}, ptr @.true, ptr @.false"));
        s
    }

    fn builtin(&mut self, name: &str, args: &[Expr], pos: Pos, want: Option<&Type>) -> R<Option<Val>> {
        let one = |g: &mut Self, w: Option<&Type>| -> R<Val> {
            if args.len() != 1 {
                return err(pos, format!("`{name}` takes 1 argument, got {}", args.len()));
            }
            g.expr(&args[0], w)
        };
        Ok(Some(match name {
            "print" | "println" => {
                if !(name == "println" && args.is_empty()) {
                    let v = one(self, None)?;
                    let s = self.show(&v, false, args[0].pos)?;
                    self.rt(Type::Void, "st_print_s", &[format!("ptr {}", s.v)]);
                }
                if name == "println" {
                    self.rt(Type::Void, "st_nl", &[]);
                }
                void()
            }
            "str" => {
                let v = one(self, None)?;
                self.show(&v, false, args[0].pos)?
            }
            "float" => {
                let v = one(self, None)?;
                match v.ty {
                    Type::Float | Type::Int => self.coerce(v, &Type::Float, pos)?,
                    Type::Str => {
                        let out = self.alloca(&Type::Float);
                        let m = self.rt(Type::Str, "st_parse_float", &[format!("ptr {}", v.v), format!("ptr {out}")]).v;
                        let n = self.load(&out, Type::Float).v;
                        let rt = Type::Result(Box::new(Type::Float));
                        let (e, a, b, c) = (self.tmp(), self.tmp(), self.tmp(), self.tmp());
                        self.ins(format!("{e} = icmp ne ptr {m}, null"));
                        self.ins(format!("{a} = insertvalue {} zeroinitializer, i1 {e}, 0", ll(&rt)));
                        self.ins(format!("{b} = insertvalue {} {a}, double {n}, 1", ll(&rt)));
                        self.ins(format!("{c} = insertvalue {} {b}, ptr {m}, 2", ll(&rt)));
                        val(c, rt)
                    }
                    t => return err(args[0].pos, format!("can't turn {t} into a float")),
                }
            }
            "min" | "max" => {
                let [a, b] = args else { return err(pos, format!("`{name}` takes 2 arguments, got {}", args.len())) };
                let a = self.expr(a, None)?;
                let b = self.expr(b, Some(&a.ty))?;
                let (a, b) = self.promote(a, b, pos)?;
                let (c, t) = (self.tmp(), self.tmp());
                let lt = match a.ty {
                    Type::Int => "icmp slt",
                    Type::Float => "fcmp olt",
                    ref t => return err(pos, format!("`{name}` compares numbers, not {t}")),
                };
                expect_ty(&a.ty, &b.ty, args[1].pos)?;
                self.ins(format!("{c} = {lt} {} {}, {}", ll(&a.ty), a.v, b.v));
                let (x, y) = if name == "min" { (&a, &b) } else { (&b, &a) };
                self.ins(format!("{t} = select i1 {c}, {} {}, {} {}", ll(&a.ty), x.v, ll(&a.ty), y.v));
                val(t, a.ty)
            }
            "abs" => {
                let v = one(self, None)?;
                match v.ty {
                    Type::Int => self.emit_call(&Type::Int, "@llvm.abs.i64", &[format!("i64 {}", v.v), "i1 false".into()]),
                    Type::Float => self.emit_call(&Type::Float, "@llvm.fabs.f64", &[format!("double {}", v.v)]),
                    t => return err(args[0].pos, format!("`abs` needs a number, not {t}")),
                }
            }
            "int" => {
                let v = one(self, None)?;
                match v.ty {
                    Type::Int => return Ok(Some(v)),
                    Type::Float => {
                        // saturating: huge values clamp, nan becomes 0
                        return Ok(Some(self.emit_call(&Type::Int, "@llvm.fptosi.sat.i64.f64", &[format!("double {}", v.v)])));
                    }
                    _ => expect_ty(&Type::Str, &v.ty, args[0].pos)?,
                }
                let out = self.alloca(&Type::Int);
                let m = self.rt(Type::Str, "st_parse_int", &[format!("ptr {}", v.v), format!("ptr {out}")]).v;
                let n = self.load(&out, Type::Int).v;
                let rt = Type::Result(Box::new(Type::Int));
                let (e, a, b, c) = (self.tmp(), self.tmp(), self.tmp(), self.tmp());
                self.ins(format!("{e} = icmp ne ptr {m}, null"));
                self.ins(format!("{a} = insertvalue {} zeroinitializer, i1 {e}, 0", ll(&rt)));
                self.ins(format!("{b} = insertvalue {} {a}, i64 {n}, 1", ll(&rt)));
                self.ins(format!("{c} = insertvalue {} {b}, ptr {m}, 2", ll(&rt)));
                val(c, rt)
            }
            "env" => {
                let v = one(self, Some(&Type::Str))?;
                expect_ty(&Type::Str, &v.ty, args[0].pos)?;
                self.rt(Type::Str, "st_env", &[format!("ptr {}", v.v)])
            }
            "url_encode" => {
                let v = one(self, Some(&Type::Str))?;
                expect_ty(&Type::Str, &v.ty, args[0].pos)?;
                self.rt(Type::Str, "st_url_encode", &[format!("ptr {}", v.v)])
            }
            "url_decode" => {
                let v = one(self, Some(&Type::Str))?;
                expect_ty(&Type::Str, &v.ty, args[0].pos)?;
                self.rt(Type::Str, "st_url_decode", &[format!("ptr {}", v.v)])
            }
            "sleep" => {
                let v = one(self, Some(&Type::Int))?;
                expect_ty(&Type::Int, &v.ty, args[0].pos)?;
                self.rt(Type::Void, "st_sleep", &[format!("i64 {}", v.v)])
            }
            "now_ms" => {
                if !args.is_empty() {
                    return err(pos, format!("`now_ms` takes no arguments, got {}", args.len()));
                }
                self.rt(Type::Int, "st_now_ms", &[])
            }
            "args" => {
                if !args.is_empty() {
                    return err(pos, format!("`args` takes no arguments, got {}", args.len()));
                }
                self.rt(Type::List(Box::new(Type::Str)), "st_args", &[])
            }
            "read_line" => {
                if !args.is_empty() {
                    return err(pos, format!("`read_line` takes no arguments, got {}", args.len()));
                }
                // NULL at the end of input: none
                let p = self.rt(Type::Str, "st_read_line", &[]).v;
                let ot = Type::Opt(Box::new(Type::Str));
                let (h, a, b) = (self.tmp(), self.tmp(), self.tmp());
                self.ins(format!("{h} = icmp ne ptr {p}, null"));
                self.ins(format!("{a} = insertvalue {} zeroinitializer, i1 {h}, 0", ll(&ot)));
                self.ins(format!("{b} = insertvalue {} {a}, ptr {p}, 1", ll(&ot)));
                val(b, ot)
            }
            "exit" => {
                let v = one(self, Some(&Type::Int))?;
                expect_ty(&Type::Int, &v.ty, args[0].pos)?;
                self.ins(format!("call void @st_exit(i64 {})", v.v));
                self.term("unreachable".into());
                void()
            }
            "panic" => {
                let v = one(self, Some(&Type::Str))?;
                expect_ty(&Type::Str, &v.ty, args[0].pos)?;
                let w = self.where_(pos);
                let w = self.str_const(&w);
                self.ins(format!("call void @st_panic_msg(ptr {w}, ptr {})", v.v));
                self.term("unreachable".into());
                void()
            }
            "some" => {
                let inner = match peel(want) {
                    Some(Type::Opt(t)) => Some((**t).clone()),
                    _ => None,
                };
                let v = one(self, inner.as_ref())?;
                let v = match &inner {
                    Some(t) => self.coerce(v, t, args[0].pos)?,
                    None => v,
                };
                if !fits_slot(&v.ty) {
                    return err(args[0].pos, format!("{}? isn't a type", v.ty));
                }
                self.some_of(&v)
            }
            "signal" if !self.funcs.contains_key(&self.key("signal")) => {
                if !self.gtypes.contains_key("web.Signal") {
                    return err(pos, "`signal` comes with `import web`");
                }
                let inner = match peel(want) {
                    Some(Type::Struct(k)) if self.inst_of.get(k).is_some_and(|i| i.0 == "web.Signal") => Some(self.inst_of[k].1[0].clone()),
                    _ => None,
                };
                let v = one(self, inner.as_ref())?;
                let v = match &inner {
                    Some(t) => self.coerce(v, t, args[0].pos)?,
                    None => v,
                };
                let st = self.instantiate_type("web.Signal", vec![v.ty.clone()], pos)?;
                let Type::Struct(k) = st.clone() else { unreachable!() };
                // the render's next state cell: empty the first time
                let cell = self.rt(Type::Str, "st_hook", &[]).v;
                let old = self.load(&cell, Type::Str).v;
                let (fresh, lnew, ldone) = (self.tmp(), self.lbl("newsig"), self.lbl("sig"));
                self.ins(format!("{fresh} = icmp eq ptr {old}, null"));
                self.term(format!("br i1 {fresh}, label %{lnew}, label %{ldone}"));
                self.label(&lnew);
                let obj = self.build(&format!("%\"S.{k}\""), None, &[v]);
                self.ins(format!("store ptr {obj}, ptr {cell}"));
                self.label(&ldone);
                let r = self.load(&cell, st);
                r
            }
            "from_json" if !self.funcs.contains_key(&self.key("from_json")) => self.from_json(args, pos, want)?,
            "to_json" => {
                let v = one(self, None)?;
                self.json(&v, args[0].pos)?
            }
            "ok" | "err" => {
                let Some(Type::Result(t)) = want else {
                    return err(pos, format!("can't tell which result type this `{name}(...)` makes; use it in a `return` or a typed `let`"));
                };
                let t = (**t).clone();
                if name == "ok" {
                    if t == Type::Void && args.is_empty() {
                        return Ok(Some(self.ok_of(&t, &void())));
                    }
                    let v = one(self, Some(&t))?;
                    let v = self.coerce(v, &t, args[0].pos)?;
                    self.ok_of(&t, &v)
                } else {
                    let m = one(self, Some(&Type::Str))?;
                    expect_ty(&Type::Str, &m.ty, args[0].pos)?;
                    self.err_of(&t, &m.v)
                }
            }
            _ => return Ok(None),
        }))
    }
}
