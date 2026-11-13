use crate::lexer::{Error, Part, Pos, Tok, Token};
use std::fmt;

#[derive(Debug, Clone, PartialEq, Default)]
pub enum Type {
    Int,
    Float,
    Bool,
    Str,
    #[default]
    Void,
    Struct(String),          // a reference to a heap object (like a Java/JS object)
    Enum(String),            // a tagged union; the parser writes every named type as Struct, codegen sorts them out
    List(Box<Type>),         // [T]
    Map(Box<Type>, Box<Type>), // {K: V}
    Set(Box<Type>),          // {T}
    Fn(Vec<Type>, Box<Type>), // fn(A, B) -> R
    Result(Box<Type>),       // T!  = a T or an error message
    Opt(Box<Type>),          // T?  = a T or `none`
    Generic(String, Vec<Type>), // Box<int>: a generic type applied to arguments (resolved to a Struct/Enum instance)
    Node,                    // a JSX element (an HTML fragment on the server, a DOM node in the browser)
}

impl fmt::Display for Type {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Type::Int => write!(f, "int"),
            Type::Float => write!(f, "float"),
            Type::Map(k, v) => write!(f, "{{{k}: {v}}}"),
            Type::Set(t) => write!(f, "{{{t}}}"),
            Type::Bool => write!(f, "bool"),
            Type::Str => write!(f, "str"),
            Type::Void => write!(f, "void"),
            Type::Struct(n) | Type::Enum(n) => write!(f, "{n}"),
            Type::Opt(t) => write!(f, "{t}?"),
            Type::List(t) => write!(f, "[{t}]"),
            Type::Result(t) => write!(f, "{t}!"),
            Type::Node => write!(f, "Node"),
            Type::Generic(n, args) => {
                let a: Vec<String> = args.iter().map(|t| t.to_string()).collect();
                write!(f, "{n}<{}>", a.join(", "))
            }
            Type::Fn(ps, r) => {
                let ps: Vec<String> = ps.iter().map(|p| p.to_string()).collect();
                write!(f, "fn({})", ps.join(", "))?;
                if **r != Type::Void { write!(f, " -> {r}")? }
                Ok(())
            }
        }
    }
}

#[derive(Clone)]
pub struct Expr {
    pub kind: ExprKind,
    pub pos: Pos,
}

#[derive(Clone)]
pub struct Pat {
    pub kind: PatKind,
    pub pos: Pos,
}

#[derive(Clone)]
pub enum PatKind {
    Any,                                   // _
    Name(String),                          // a new binding, a unit variant (`Red`) or `none`
    Int(i64),
    Bool(bool),
    Str(String),
    Variant(Vec<String>, Option<Vec<Pat>>), // Circle(r) / Shape.Circle(r) / .Red / ok(x) / some(x)
    Fields(Vec<String>, Vec<(String, Pat)>), // Rect { w, h: 0 } / Point { x, y }
    Or(Vec<Pat>),                          // 1 | 2 | 3
}

/// The head of an `if` or `while`: a plain condition, or `let PATTERN = value`.
#[derive(Clone)]
pub enum Cond {
    Expr(Expr),
    Let(Pat, Expr),
}

#[derive(Clone)]
pub struct Arm {
    pub pat: Pat,
    pub guard: Option<Expr>,
    pub body: Body,
}

#[derive(Clone)]
pub enum Body {
    Expr(Box<Expr>),
    Block(Vec<Stmt>),
}

#[derive(Clone)]
pub struct Lambda {
    pub params: Vec<(String, Option<Type>)>,
    pub ret: Option<Type>,
    pub body: Body,
}

#[derive(Clone)]
pub enum ExprKind {
    Int(i64),
    Float(f64),
    Bool(bool),
    Str(String),
    Var(String),
    Unary(char, Box<Expr>),
    Binary(Tok, Box<Expr>, Box<Expr>),
    Call(Box<Expr>, Vec<Expr>),
    Field(Box<Expr>, String),
    Index(Box<Expr>, Box<Expr>),
    List(Vec<Expr>),
    Map(Vec<(Expr, Expr)>), // {k: v, ...}; also the empty `{}`
    Set(Vec<Expr>),         // {a, b, ...}
    StructLit(String, Vec<(String, Expr)>), // Point { x: 1, y } ; name may be `mod.Name`
    Lambda(Box<Lambda>),
    Try(Box<Expr>),                       // expr?
    CatchValue(Box<Expr>, Box<Expr>),     // expr catch fallback
    CatchBlock(Box<Expr>, String, Vec<Stmt>), // expr catch e { ... }
    Match(Box<Expr>, std::rc::Rc<Vec<Arm>>),
    If(Box<Cond>, Vec<Stmt>, Vec<Stmt>), // `if` used as a value
    Member(String),                      // `.Circle`: a variant of the enum the context expects
    // `a?.b.c`: if `a` is none the whole thing is none; otherwise `rest` with the value of `a` as `name`
    Chain(String, Box<Expr>, Box<Expr>),
}

#[derive(Clone)]
pub enum Stmt {
    Let { name: String, mutable: bool, ty: Option<Type>, value: Expr, pos: Pos },
    // `let Circle(r) = shape else { return }` / `let user = find(id) else { ... }`
    LetElse { pat: Pat, mutable: bool, value: Expr, els: Option<Vec<Stmt>>, pos: Pos },
    Assign(Expr, Expr),
    Expr(Expr),
    Return(Option<Expr>, Pos),
    If(Cond, Vec<Stmt>, Vec<Stmt>),
    While(Cond, Vec<Stmt>),
    // for x in xs / for i, x in xs / for k, v in map / for i in a..b
    For { var: String, var2: Option<String>, iter: Expr, end: Option<Expr>, body: Vec<Stmt> },
    Break(Pos),
    Continue(Pos),
}

/// `T` or `T: Show + Eq` in `fn f<...>` / `struct Box<...>`.
#[derive(Clone, Debug)]
pub struct TParam {
    pub name: String,
    pub bounds: Vec<String>,
}

#[derive(Clone)]
pub struct Func {
    pub name: String,
    pub tparams: Vec<TParam>,
    pub params: Vec<(String, Option<Type>)>, // only `self` may omit its type
    pub ret: Type,
    pub body: Vec<Stmt>,
    pub pos: Pos,
}

#[derive(Clone)]
pub struct Field {
    pub name: String,
    pub ty: Type,
    pub default: Option<Expr>,
}

#[derive(Clone)]
pub struct StructDef {
    pub name: String,
    pub tparams: Vec<TParam>,
    pub fields: Vec<Field>,
    pub pos: Pos,
}

#[derive(Clone)]
pub struct Variant {
    pub name: String,
    pub fields: Vec<Field>, // tuple variants get the names "0", "1", ... unless named
    pub braces: bool,       // `Rect { w: int }` rather than `Circle(int)`
    pub pos: Pos,
}

#[derive(Clone)]
pub struct EnumDef {
    pub name: String,
    pub tparams: Vec<TParam>,
    pub variants: Vec<Variant>,
    pub pos: Pos,
}

pub struct Const {
    pub name: String,
    pub ty: Option<Type>,
    pub value: Expr,
    pub pos: Pos,
}

pub struct Impl {
    pub name: String,
    pub trait_: Option<String>, // `impl Show for Point`
    pub methods: Vec<Func>,
    pub pos: Pos,
}

/// `trait Show { fn show(self) -> str; fn twice(self) -> str { ... } }`
pub struct Trait {
    pub name: String,
    pub methods: Vec<(Func, bool)>, // (method, has a default body)
    pub pos: Pos,
}

pub struct Extern {
    pub name: String,
    pub params: Vec<Type>,
    pub ret: Type,
    pub pos: Pos,
}

#[derive(Default)]
pub struct Module {
    pub imports: Vec<(String, Pos)>,
    pub structs: Vec<StructDef>,
    pub enums: Vec<EnumDef>,
    pub consts: Vec<Const>,
    pub impls: Vec<Impl>,
    pub traits: Vec<Trait>,
    pub funcs: Vec<Func>,
    pub externs: Vec<Extern>,
    /// (token index, opens?) for every block brace; `stellang fmt` uses it to tell ⭐ apart
    pub braces: Vec<(usize, bool)>,
}

type P<T> = Result<T, Error>;

pub fn parse(toks: Vec<Token>) -> P<Module> {
    let mut p = Parser { toks, i: 0, braces: vec![], no_struct: false };
    let mut m = Module::default();
    loop {
        p.nl();
        match p.peek().clone() {
            Tok::Import => {
                let pos = p.pos();
                p.next();
                m.imports.push((p.ident()?, pos));
            }
            Tok::Fn => m.funcs.push(p.func(false)?),
            Tok::Struct => {
                let (s, methods) = p.structdef()?;
                if !methods.is_empty() {
                    m.impls.push(Impl { name: s.name.clone(), trait_: None, methods, pos: s.pos });
                }
                m.structs.push(s);
            }
            Tok::Enum => {
                let (e, methods) = p.enumdef()?;
                if !methods.is_empty() {
                    m.impls.push(Impl { name: e.name.clone(), trait_: None, methods, pos: e.pos });
                }
                m.enums.push(e);
            }
            Tok::Const => {
                let pos = p.pos();
                p.next();
                let name = p.ident()?;
                let ty = if p.eat(&Tok::Colon) { Some(p.ty()?) } else { None };
                p.expect(Tok::Assign)?;
                m.consts.push(Const { name, ty, value: p.expr()?, pos });
            }
            Tok::Impl => {
                let pos = p.pos();
                p.next();
                let mut name = p.impl_name()?;
                let mut trait_ = None;
                if p.eat(&Tok::For) {
                    trait_ = Some(name);
                    name = p.impl_name()?;
                }
                p.open()?;
                let mut methods = vec![];
                loop {
                    p.nl();
                    if p.closes() { break }
                    if *p.peek() != Tok::Fn {
                        return p.fail(format!("expected `fn` inside impl, found {}", p.peek()));
                    }
                    methods.push(p.func(true)?);
                }
                m.impls.push(Impl { name, trait_, methods, pos });
            }
            Tok::Trait => {
                let pos = p.pos();
                p.next();
                let name = p.ident()?;
                p.open()?;
                let mut methods = vec![];
                loop {
                    p.nl();
                    if p.closes() { break }
                    if *p.peek() != Tok::Fn {
                        return p.fail(format!("expected `fn` inside trait, found {}", p.peek()));
                    }
                    methods.push(p.func_decl()?);
                }
                m.traits.push(Trait { name, methods, pos });
            }
            Tok::Extern => {
                let pos = p.pos();
                p.next();
                p.expect(Tok::Fn)?;
                let name = p.ident()?;
                p.expect(Tok::LParen)?;
                let params = p.list(Tok::RParen, |p| Ok(p.param(false)?.1.unwrap()))?;
                let ret = if p.eat(&Tok::Arrow) { p.ty()? } else { Type::Void };
                m.externs.push(Extern { name, params, ret, pos });
            }
            Tok::Eof => {
                m.braces = p.braces;
                return Ok(m);
            }
            t => return p.fail(format!("expected `fn`, `struct`, `enum`, `trait`, `impl`, `const` or `import`, found {t}")),
        }
    }
}

/// `"a ${x} b"` becomes `"a " + str(x) + " b"`.
fn interp(parts: Vec<Part>, pos: Pos) -> P<Expr> {
    let mut out = Expr { kind: ExprKind::Str(String::new()), pos };
    for part in parts {
        let e = match part {
            Part::Lit(s) if s.is_empty() => continue,
            Part::Lit(s) => Expr { kind: ExprKind::Str(s), pos },
            Part::Code(toks, at) => {
                let mut p = Parser { toks, i: 0, braces: vec![], no_struct: false };
                p.nl();
                if *p.peek() == Tok::Eof {
                    return Err((at, "empty `${}` in string".into()));
                }
                let e = p.expr()?;
                p.nl();
                if *p.peek() != Tok::Eof {
                    return p.fail(format!("expected `}}` after the value, found {}", p.peek()));
                }
                let f = Expr { kind: ExprKind::Var("str".into()), pos: e.pos };
                Expr { kind: ExprKind::Call(Box::new(f), vec![e]), pos: at }
            }
        };
        out = match out.kind {
            ExprKind::Str(ref s) if s.is_empty() => e,
            _ => Expr { kind: ExprKind::Binary(Tok::Plus, Box::new(out), Box::new(e)), pos },
        };
    }
    Ok(out)
}

struct Parser {
    toks: Vec<Token>,
    i: usize,
    braces: Vec<(usize, bool)>,
    no_struct: bool, // in `if x {`, `{` starts the block, not a struct literal
}

impl Parser {
    fn peek(&self) -> &Tok { &self.toks[self.i].tok }
    fn peek_at(&self, k: usize) -> &Tok { &self.toks[(self.i + k).min(self.toks.len() - 1)].tok }
    fn pos(&self) -> Pos { self.toks[self.i].pos }
    fn fail<T>(&self, msg: String) -> P<T> { Err((self.pos(), msg)) }

    fn next(&mut self) -> Tok {
        let t = self.toks[self.i].tok.clone();
        if self.i + 1 < self.toks.len() { self.i += 1 }
        t
    }

    fn eat(&mut self, t: &Tok) -> bool {
        let hit = self.peek() == t;
        if hit { self.next(); }
        hit
    }

    /// Skip line breaks and `;`; true if there were any.
    fn nl(&mut self) -> bool {
        let start = self.i;
        while matches!(self.peek(), Tok::Newline | Tok::Semi) { self.next(); }
        self.i != start
    }

    fn expect(&mut self, t: Tok) -> P<()> {
        if self.eat(&t) { Ok(()) } else { self.fail(format!("expected {t}, found {}", self.peek())) }
    }

    fn ident(&mut self) -> P<String> {
        match self.peek().clone() {
            Tok::Ident(s) => { self.next(); Ok(s) }
            t => self.fail(format!("expected a name, found {t}")),
        }
    }

    fn at_open(&self) -> bool { matches!(self.peek(), Tok::Star | Tok::LBrace) }

    fn open(&mut self) -> P<()> {
        if !self.at_open() {
            return self.fail(format!("expected `{{`, found {}", self.peek()));
        }
        self.braces.push((self.i, true));
        self.next();
        Ok(())
    }

    fn closes(&mut self) -> bool {
        let hit = matches!(self.peek(), Tok::Star | Tok::RBrace);
        if hit {
            self.braces.push((self.i, false));
            self.next();
        }
        hit
    }

    fn close(&mut self, t: &Tok) -> bool {
        if *t == Tok::RBrace { self.closes() } else { self.eat(t) }
    }

    /// Items separated by commas or line breaks, up to `close`. Opening token already eaten.
    fn list<T>(&mut self, close: Tok, mut item: impl FnMut(&mut Self) -> P<T>) -> P<Vec<T>> {
        let saved = std::mem::replace(&mut self.no_struct, false);
        let mut v = vec![];
        loop {
            self.nl();
            if self.close(&close) { break }
            v.push(item(self)?);
            let broke = self.nl();
            if !self.eat(&Tok::Comma) && !broke {
                if self.close(&close) { break }
                return self.fail(format!("expected `,` or {close}, found {}", self.peek()));
            }
        }
        self.no_struct = saved;
        Ok(v)
    }

    fn ty(&mut self) -> P<Type> {
        let t = if self.eat(&Tok::LBrack) {
            let t = self.ty()?;
            self.expect(Tok::RBrack)?;
            Type::List(Box::new(t))
        } else if self.at_open() {
            // {K: V} map, {T} set
            self.open()?;
            let k = self.ty()?;
            let t = if self.eat(&Tok::Colon) { Type::Map(Box::new(k), Box::new(self.ty()?)) } else { Type::Set(Box::new(k)) };
            if !self.closes() {
                return self.fail(format!("expected `}}`, found {}", self.peek()));
            }
            t
        } else if self.eat(&Tok::Fn) {
            self.expect(Tok::LParen)?;
            let ps = self.list(Tok::RParen, |p| p.ty())?;
            let r = if self.eat(&Tok::Arrow) { self.ty()? } else { Type::Void };
            Type::Fn(ps, Box::new(r))
        } else {
            let name = self.ident()?;
            match name.as_str() {
                "int" => Type::Int,
                "float" => Type::Float,
                "bool" => Type::Bool,
                "str" => Type::Str,
                "void" => Type::Void,
                _ => {
                    let name = if self.eat(&Tok::Dot) { format!("{name}.{}", self.ident()?) } else { name };
                    if name == "Node" {
                        Type::Node
                    } else if *self.peek() == Tok::Lt {
                        Type::Generic(name, self.type_args()?)
                    } else {
                        Type::Struct(name)
                    }
                }
            }
        };
        let mut t = t;
        loop {
            if self.eat(&Tok::Bang) {
                t = Type::Result(Box::new(t));
            } else if self.eat(&Tok::Question) {
                t = Type::Opt(Box::new(t));
            } else {
                return Ok(t);
            }
        }
    }

    /// `<int, str>` after a generic type's name.
    fn type_args(&mut self) -> P<Vec<Type>> {
        self.expect(Tok::Lt)?;
        let mut v = vec![];
        loop {
            v.push(self.ty()?);
            if self.eat(&Tok::Comma) { continue }
            // `Box<int>= x` lexes as `>=`: take the `>` and leave a `=`
            if *self.peek() == Tok::Ge {
                self.toks[self.i].tok = Tok::Assign;
                return Ok(v);
            }
            self.expect(Tok::Gt)?;
            return Ok(v);
        }
    }

    /// `<T, U: Show + Eq>` after a function or type name (or nothing).
    fn tparams(&mut self) -> P<Vec<TParam>> {
        if !self.eat(&Tok::Lt) {
            return Ok(vec![]);
        }
        let mut v: Vec<TParam> = vec![];
        loop {
            let name = self.ident()?;
            let mut bounds = vec![];
            if self.eat(&Tok::Colon) {
                loop {
                    let mut b = self.ident()?;
                    if self.eat(&Tok::Dot) { b = format!("{b}.{}", self.ident()?) }
                    bounds.push(b);
                    if !self.eat(&Tok::Plus) { break }
                }
            }
            v.push(TParam { name, bounds });
            if self.eat(&Tok::Comma) { continue }
            self.expect(Tok::Gt)?;
            return Ok(v);
        }
    }

    /// The type named after `impl` / `for`: `Point`, `Box<T>` (the arguments just repeat the type's parameters), `int`.
    fn impl_name(&mut self) -> P<String> {
        let mut name = self.ident()?;
        if self.eat(&Tok::Dot) { name = format!("{name}.{}", self.ident()?) }
        if *self.peek() == Tok::Lt {
            self.type_args()?;
        }
        Ok(name)
    }

    /// `name: Type`, or a bare `self` when `allow_self`.
    fn param(&mut self, allow_self: bool) -> P<(String, Option<Type>)> {
        let n = self.ident()?;
        if allow_self && n == "self" && *self.peek() != Tok::Colon {
            return Ok((n, None));
        }
        self.expect(Tok::Colon)?;
        Ok((n, Some(self.ty()?)))
    }

    fn func(&mut self, method: bool) -> P<Func> {
        let mut f = self.signature(method)?;
        f.body = self.block()?;
        Ok(f)
    }

    /// A trait method: a signature, with or without a default body.
    fn func_decl(&mut self) -> P<(Func, bool)> {
        let mut f = self.signature(true)?;
        if self.at_open() {
            f.body = self.block()?;
            return Ok((f, true));
        }
        Ok((f, false))
    }

    fn signature(&mut self, method: bool) -> P<Func> {
        let pos = self.pos();
        self.next();
        let name = self.ident()?;
        let tparams = self.tparams()?;
        self.expect(Tok::LParen)?;
        let mut first = method;
        let params = self.list(Tok::RParen, |p| {
            let r = p.param(first);
            first = false;
            r
        })?;
        let ret = if self.eat(&Tok::Arrow) { self.ty()? } else { Type::Void };
        Ok(Func { name, tparams, params, ret, body: vec![], pos })
    }

    /// `name: Type` or `name: Type = default`.
    fn field(&mut self) -> P<Field> {
        let name = self.ident()?;
        self.expect(Tok::Colon)?;
        let ty = self.ty()?;
        let default = if self.eat(&Tok::Assign) { Some(self.expr()?) } else { None };
        Ok(Field { name, ty, default })
    }

    /// The `{ ... }` of a struct or enum: items separated by commas or line breaks, plus `fn` methods.
    fn body<T>(&mut self, mut item: impl FnMut(&mut Self) -> P<T>) -> P<(Vec<T>, Vec<Func>)> {
        self.open()?;
        let saved = std::mem::replace(&mut self.no_struct, false);
        let (mut items, mut methods) = (vec![], vec![]);
        loop {
            self.nl();
            if self.closes() { break }
            if *self.peek() == Tok::Fn {
                methods.push(self.func(true)?);
                continue;
            }
            items.push(item(self)?);
            let broke = self.nl();
            if !self.eat(&Tok::Comma) && !broke {
                if self.closes() { break }
                return self.fail(format!("expected `,` or `}}`, found {}", self.peek()));
            }
        }
        self.no_struct = saved;
        Ok((items, methods))
    }

    fn structdef(&mut self) -> P<(StructDef, Vec<Func>)> {
        let pos = self.pos();
        self.next();
        let name = self.ident()?;
        let tparams = self.tparams()?;
        let (fields, methods) = self.body(|p| p.field())?;
        Ok((StructDef { name, tparams, fields, pos }, methods))
    }

    fn enumdef(&mut self) -> P<(EnumDef, Vec<Func>)> {
        let pos = self.pos();
        self.next();
        let name = self.ident()?;
        let tparams = self.tparams()?;
        let (variants, methods) = self.body(|p| {
            let pos = p.pos();
            let name = p.ident()?;
            if p.eat(&Tok::LParen) {
                let mut k = 0;
                let fields = p.list(Tok::RParen, |p| {
                    k += 1;
                    if matches!(p.peek(), Tok::Ident(_)) && *p.peek_at(1) == Tok::Colon {
                        return p.field();
                    }
                    Ok(Field { name: (k - 1).to_string(), ty: p.ty()?, default: None })
                })?;
                Ok(Variant { name, fields, braces: false, pos })
            } else if p.at_open() {
                p.open()?;
                let fields = p.list(Tok::RBrace, |p| p.field())?;
                Ok(Variant { name, fields, braces: true, pos })
            } else {
                Ok(Variant { name, fields: vec![], braces: false, pos })
            }
        })?;
        Ok((EnumDef { name, tparams, variants, pos }, methods))
    }

    fn block(&mut self) -> P<Vec<Stmt>> {
        self.open()?;
        let saved = std::mem::replace(&mut self.no_struct, false);
        let mut v = vec![];
        loop {
            self.nl();
            if self.closes() { break }
            v.push(self.stmt()?);
            if !matches!(self.peek(), Tok::Newline | Tok::Semi | Tok::Star | Tok::RBrace) {
                return self.fail(format!("expected the end of the line, found {}", self.peek()));
            }
        }
        self.no_struct = saved;
        Ok(v)
    }

    /// An expression where `{` begins the following block (if/while/for/match heads).
    fn head(&mut self) -> P<Expr> {
        let saved = std::mem::replace(&mut self.no_struct, true);
        let e = self.expr();
        self.no_struct = saved;
        e
    }

    fn stmt(&mut self) -> P<Stmt> {
        let pos = self.pos();
        Ok(match self.peek().clone() {
            Tok::Let | Tok::Var => {
                let mutable = self.next() == Tok::Var;
                let simple = matches!(self.peek(), Tok::Ident(_)) && matches!(self.peek_at(1), Tok::Colon | Tok::Assign);
                if simple {
                    let name = self.ident()?;
                    let ty = if self.eat(&Tok::Colon) { Some(self.ty()?) } else { None };
                    self.expect(Tok::Assign)?;
                    let value = self.expr()?;
                    if ty.is_none() && *self.peek() == Tok::Else {
                        self.next();
                        let pat = Pat { kind: PatKind::Name(name), pos };
                        return Ok(Stmt::LetElse { pat, mutable, value, els: Some(self.block()?), pos });
                    }
                    return Ok(Stmt::Let { name, mutable, ty, value, pos });
                }
                let pat = self.pattern()?;
                self.expect(Tok::Assign)?;
                let value = self.expr()?;
                let els = if self.eat(&Tok::Else) { Some(self.block()?) } else { None };
                Stmt::LetElse { pat, mutable, value, els, pos }
            }
            Tok::Return => {
                self.next();
                let bare = matches!(self.peek(), Tok::Newline | Tok::Semi | Tok::Star | Tok::RBrace);
                Stmt::Return(if bare { None } else { Some(self.expr()?) }, pos)
            }
            Tok::If => self.if_stmt()?,
            Tok::While => {
                self.next();
                let c = self.cond()?;
                Stmt::While(c, self.block()?)
            }
            Tok::For => {
                self.next();
                let var = self.ident()?;
                let var2 = if self.eat(&Tok::Comma) { Some(self.ident()?) } else { None };
                self.expect(Tok::In)?;
                let iter = self.head()?;
                let end = if self.eat(&Tok::DotDot) { Some(self.head()?) } else { None };
                Stmt::For { var, var2, iter, end, body: self.block()? }
            }
            Tok::Break => { self.next(); Stmt::Break(pos) }
            Tok::Continue => { self.next(); Stmt::Continue(pos) }
            _ => {
                let e = self.expr()?;
                let op = match self.peek() {
                    Tok::Assign => None,
                    Tok::PlusEq => Some(Tok::Plus),
                    Tok::MinusEq => Some(Tok::Minus),
                    Tok::TimesEq => Some(Tok::Times),
                    Tok::SlashEq => Some(Tok::Slash),
                    _ => return Ok(Stmt::Expr(e)),
                };
                let apos = self.pos();
                self.next();
                let mut value = self.expr()?;
                if let Some(op) = op {
                    // `a += b` is `a = a + b`
                    value = Expr { kind: ExprKind::Binary(op, Box::new(e.clone()), Box::new(value)), pos: apos };
                }
                Stmt::Assign(e, value)
            }
        })
    }

    fn if_stmt(&mut self) -> P<Stmt> {
        self.next();
        let c = self.cond()?;
        let then = self.block()?;
        let els = if !self.eat(&Tok::Else) {
            vec![]
        } else if *self.peek() == Tok::If {
            vec![self.if_stmt()?]
        } else {
            self.block()?
        };
        Ok(Stmt::If(c, then, els))
    }

    /// `if` in a value position: `let x = if a { 1 } else { 2 }` (a block's value is its last line).
    fn if_expr(&mut self) -> P<Expr> {
        let pos = self.pos();
        self.next();
        let c = self.cond()?;
        let then = self.block()?;
        let els = if !self.eat(&Tok::Else) {
            vec![]
        } else if *self.peek() == Tok::If {
            vec![Stmt::Expr(self.if_expr()?)]
        } else {
            self.block()?
        };
        Ok(Expr { kind: ExprKind::If(Box::new(c), then, els), pos })
    }

    /// The head of `if` / `while`: an expression, or `let PATTERN = value`.
    fn cond(&mut self) -> P<Cond> {
        if self.eat(&Tok::Let) {
            let pat = self.pattern()?;
            self.expect(Tok::Assign)?;
            return Ok(Cond::Let(pat, self.head()?));
        }
        Ok(Cond::Expr(self.head()?))
    }

    /// `A | B | C`
    fn pattern(&mut self) -> P<Pat> {
        let first = self.pat1()?;
        if *self.peek() != Tok::Pipe {
            return Ok(first);
        }
        let pos = first.pos;
        let mut alts = vec![first];
        while self.eat(&Tok::Pipe) {
            alts.push(self.pat1()?);
        }
        Ok(Pat { kind: PatKind::Or(alts), pos })
    }

    fn pat1(&mut self) -> P<Pat> {
        let pos = self.pos();
        let kind = match self.next() {
            Tok::Int(n) => PatKind::Int(n),
            Tok::Minus => match self.next() {
                Tok::Int(n) => PatKind::Int(-n),
                t => return Err((pos, format!("expected a number after `-`, found {t}"))),
            },
            Tok::Str(s) => PatKind::Str(s),
            Tok::Ident(s) if s == "_" => PatKind::Any,
            Tok::Ident(s) if s == "true" || s == "false" => PatKind::Bool(s == "true"),
            t @ (Tok::Ident(_) | Tok::Dot) => {
                let mut path = vec![];
                let dotted = t == Tok::Dot;
                if let Tok::Ident(s) = t { path.push(s) } else { path.push(self.ident()?) }
                while *self.peek() == Tok::Dot && matches!(self.peek_at(1), Tok::Ident(_)) {
                    self.next();
                    path.push(self.ident()?);
                }
                if self.eat(&Tok::LParen) {
                    PatKind::Variant(path, Some(self.list(Tok::RParen, |p| p.pattern())?))
                } else if self.at_open() {
                    self.open()?;
                    let fields = self.list(Tok::RBrace, |p| {
                        let fpos = p.pos();
                        let f = p.ident()?;
                        if p.eat(&Tok::Colon) {
                            Ok((f, p.pattern()?))
                        } else {
                            Ok((f.clone(), Pat { kind: PatKind::Name(f), pos: fpos })) // `Rect { w, h }`
                        }
                    })?;
                    PatKind::Fields(path, fields)
                } else if path.len() == 1 && !dotted {
                    PatKind::Name(path.pop().unwrap())
                } else {
                    PatKind::Variant(path, None)
                }
            }
            t => return Err((pos, format!("expected a pattern (a number, string, true/false, a name, a variant like Circle(r), ok(x), none or _), found {t}"))),
        };
        Ok(Pat { kind, pos })
    }

    fn expr(&mut self) -> P<Expr> {
        let e = self.binary(1)?;
        let pos = self.pos();
        if !self.eat(&Tok::Catch) {
            return Ok(e);
        }
        // `catch e { ... }` or `catch fallback`
        if let (Tok::Ident(name), true) = (self.peek().clone(), matches!(self.peek_at(1), Tok::LBrace | Tok::Star)) {
            self.next();
            return Ok(Expr { kind: ExprKind::CatchBlock(Box::new(e), name, self.block()?), pos });
        }
        Ok(Expr { kind: ExprKind::CatchValue(Box::new(e), Box::new(self.binary(1)?)), pos })
    }

    fn binary(&mut self, min: u8) -> P<Expr> {
        let mut lhs = self.unary()?;
        loop {
            let prec = match self.peek() {
                Tok::OrOr => 1,
                Tok::AndAnd => 2,
                Tok::Eq | Tok::Ne => 3,
                Tok::Lt | Tok::Le | Tok::Gt | Tok::Ge | Tok::In => 4,
                Tok::QuestionQuestion => 5,
                Tok::Plus | Tok::Minus => 6,
                Tok::Times | Tok::Slash | Tok::Percent => 7,
                _ => 0,
            };
            if prec < min { return Ok(lhs) }
            let pos = self.pos();
            let op = self.next();
            // `a ?? b ?? c` groups to the right
            let rhs = self.binary(if op == Tok::QuestionQuestion { prec } else { prec + 1 })?;
            lhs = Expr { kind: ExprKind::Binary(op, Box::new(lhs), Box::new(rhs)), pos };
        }
    }

    fn unary(&mut self) -> P<Expr> {
        let pos = self.pos();
        let op = match self.peek() {
            Tok::Minus => '-',
            Tok::Bang => '!',
            _ => return self.postfix(),
        };
        self.next();
        Ok(Expr { kind: ExprKind::Unary(op, Box::new(self.unary()?)), pos })
    }

    fn postfix(&mut self) -> P<Expr> {
        let e = self.primary()?;
        self.postfix_from(e)
    }

    fn postfix_from(&mut self, mut e: Expr) -> P<Expr> {
        loop {
            let pos = self.pos();
            e = match self.peek() {
                Tok::Dot => {
                    self.next();
                    Expr { kind: ExprKind::Field(Box::new(e), self.ident()?), pos }
                }
                Tok::LParen => {
                    self.next();
                    Expr { kind: ExprKind::Call(Box::new(e), self.list(Tok::RParen, |p| p.expr())?), pos }
                }
                Tok::LBrack => {
                    self.next();
                    let saved = std::mem::replace(&mut self.no_struct, false);
                    self.nl();
                    let i = self.expr()?;
                    self.nl();
                    self.no_struct = saved;
                    self.expect(Tok::RBrack)?;
                    Expr { kind: ExprKind::Index(Box::new(e), Box::new(i)), pos }
                }
                Tok::Question if *self.peek_at(1) == Tok::Dot => {
                    self.next();
                    let name = format!("?{}", self.i);
                    let rest = self.postfix_from(Expr { kind: ExprKind::Var(name.clone()), pos })?;
                    return Ok(Expr { kind: ExprKind::Chain(name, Box::new(e), Box::new(rest)), pos });
                }
                Tok::Question => {
                    self.next();
                    Expr { kind: ExprKind::Try(Box::new(e)), pos }
                }
                Tok::LBrace | Tok::Star if !self.no_struct => {
                    // `Point {`, `geo.Point {`, `Shape.Rect {`, `.Rect {`
                    fn path(e: &Expr) -> Option<String> {
                        match &e.kind {
                            ExprKind::Var(n) => Some(n.clone()),
                            ExprKind::Member(n) => Some(format!(".{n}")),
                            ExprKind::Field(m, n) => Some(format!("{}.{n}", path(m)?)),
                            _ => None,
                        }
                    }
                    let Some(name) = path(&e) else { return Ok(e) };
                    self.open()?;
                    let fields = self.list(Tok::RBrace, |p| {
                        let fpos = p.pos();
                        let f = p.ident()?;
                        if p.eat(&Tok::Colon) {
                            Ok((f, p.expr()?))
                        } else {
                            Ok((f.clone(), Expr { kind: ExprKind::Var(f), pos: fpos })) // shorthand `Point { x, y }`
                        }
                    })?;
                    Expr { kind: ExprKind::StructLit(name, fields), pos: e.pos }
                }
                _ => return Ok(e),
            };
        }
    }

    /// After `(`: does a matching `)` follow with `=>` (or `:` type `=>`) after it?
    fn lambda_ahead(&self) -> bool {
        let mut depth = 0;
        for k in self.i..self.toks.len() {
            match self.toks[k].tok {
                Tok::LParen => depth += 1,
                Tok::RParen => {
                    depth -= 1;
                    if depth == 0 {
                        return matches!(self.toks.get(k + 1).map(|t| &t.tok), Some(Tok::FatArrow | Tok::Colon));
                    }
                }
                Tok::Newline | Tok::Eof | Tok::LBrace | Tok::RBrace => return false,
                _ => {}
            }
        }
        false
    }

    fn lambda(&mut self) -> P<Expr> {
        let pos = self.pos();
        let params = if self.eat(&Tok::LParen) {
            self.list(Tok::RParen, |p| {
                let n = p.ident()?;
                Ok((n, if p.eat(&Tok::Colon) { Some(p.ty()?) } else { None }))
            })?
        } else {
            vec![(self.ident()?, None)]
        };
        let ret = if self.eat(&Tok::Colon) { Some(self.ty()?) } else { None };
        self.expect(Tok::FatArrow)?;
        let body = if self.at_open() { Body::Block(self.block()?) } else { Body::Expr(Box::new(self.expr()?)) };
        Ok(Expr { kind: ExprKind::Lambda(Box::new(Lambda { params, ret, body })), pos })
    }

    fn primary(&mut self) -> P<Expr> {
        let pos = self.pos();
        if (*self.peek() == Tok::LParen && self.lambda_ahead())
            || (matches!(self.peek(), Tok::Ident(_)) && *self.peek_at(1) == Tok::FatArrow)
        {
            return self.lambda();
        }
        if *self.peek() == Tok::If {
            return self.if_expr();
        }
        let kind = match self.next() {
            Tok::Dot => ExprKind::Member(self.ident()?),
            Tok::Int(n) => ExprKind::Int(n),
            Tok::Float(n) => ExprKind::Float(n),
            Tok::Str(s) => ExprKind::Str(s),
            Tok::Interp(parts) => return interp(parts, pos),
            Tok::LBrace | Tok::Star => {
                self.i -= 1;
                self.open()?;
                let mut pairs = None;
                let items = self.list(Tok::RBrace, |p| {
                    let k = p.expr()?;
                    let is_pair = p.eat(&Tok::Colon);
                    if *pairs.get_or_insert(is_pair) != is_pair {
                        return p.fail("mixing `key: value` and plain items in one `{...}`".into());
                    }
                    Ok((k, if is_pair { Some(p.expr()?) } else { None }))
                })?;
                if pairs == Some(false) {
                    ExprKind::Set(items.into_iter().map(|x| x.0).collect())
                } else {
                    ExprKind::Map(items.into_iter().map(|(k, v)| (k, v.unwrap())).collect())
                }
            }
            Tok::Ident(s) if s == "true" || s == "false" => ExprKind::Bool(s == "true"),
            Tok::Ident(s) => ExprKind::Var(s),
            Tok::LParen => {
                let saved = std::mem::replace(&mut self.no_struct, false);
                self.nl();
                let e = self.expr()?;
                self.nl();
                self.no_struct = saved;
                self.expect(Tok::RParen)?;
                return Ok(e);
            }
            Tok::LBrack => ExprKind::List(self.list(Tok::RBrack, |p| p.expr())?),
            Tok::Match => {
                let subject = self.head()?;
                self.open()?;
                let arms = self.list(Tok::RBrace, |p| p.arm())?;
                ExprKind::Match(Box::new(subject), std::rc::Rc::new(arms))
            }
            t => return Err((pos, format!("expected a value, found {t}"))),
        };
        Ok(Expr { kind, pos })
    }

    fn arm(&mut self) -> P<Arm> {
        let pat = self.pattern()?;
        let guard = if self.eat(&Tok::If) { Some(self.expr()?) } else { None };
        self.expect(Tok::FatArrow)?;
        let body = if self.at_open() {
            Body::Block(self.block()?)
        } else if matches!(self.peek(), Tok::Return | Tok::Break | Tok::Continue) {
            Body::Block(vec![self.stmt()?]) // `none => return`, `0 => break`
        } else {
            Body::Expr(Box::new(self.expr()?))
        };
        Ok(Arm { pat, guard, body })
    }
}
