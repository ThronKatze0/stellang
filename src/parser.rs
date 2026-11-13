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
    List(Box<Type>),         // [T]
    Map(Box<Type>, Box<Type>), // {K: V}
    Set(Box<Type>),          // {T}
    Fn(Vec<Type>, Box<Type>), // fn(A, B) -> R
    Result(Box<Type>),       // T!  = a T or an error message
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
            Type::Struct(n) => write!(f, "{n}"),
            Type::List(t) => write!(f, "[{t}]"),
            Type::Result(t) => write!(f, "{t}!"),
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
pub enum Pattern {
    Any,
    Int(i64),
    Bool(bool),
    Str(String),
    Ok(String),  // ok(name) / ok(_)
    Err(String), // err(name) / err(_)
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
    Match(Box<Expr>, Vec<(Pattern, Pos, Body)>),
}

#[derive(Clone)]
pub enum Stmt {
    Let { name: String, mutable: bool, ty: Option<Type>, value: Expr, pos: Pos },
    Assign(Expr, Expr),
    Expr(Expr),
    Return(Option<Expr>, Pos),
    If(Expr, Vec<Stmt>, Vec<Stmt>),
    While(Expr, Vec<Stmt>),
    // for x in xs / for i, x in xs / for k, v in map / for i in a..b
    For { var: String, var2: Option<String>, iter: Expr, end: Option<Expr>, body: Vec<Stmt> },
    Break(Pos),
    Continue(Pos),
}

pub struct Func {
    pub name: String,
    pub params: Vec<(String, Option<Type>)>, // only `self` may omit its type
    pub ret: Type,
    pub body: Vec<Stmt>,
    pub pos: Pos,
}

pub struct StructDef {
    pub name: String,
    pub fields: Vec<(String, Type)>,
    pub pos: Pos,
}

pub struct Impl {
    pub name: String,
    pub methods: Vec<Func>,
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
    pub impls: Vec<Impl>,
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
            Tok::Struct => m.structs.push(p.structdef()?),
            Tok::Impl => {
                let pos = p.pos();
                p.next();
                let name = p.ident()?;
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
                m.impls.push(Impl { name, methods, pos });
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
            t => return p.fail(format!("expected `fn`, `struct`, `impl` or `import`, found {t}")),
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
                _ if self.eat(&Tok::Dot) => Type::Struct(format!("{name}.{}", self.ident()?)),
                _ => Type::Struct(name),
            }
        };
        Ok(if self.eat(&Tok::Bang) { Type::Result(Box::new(t)) } else { t })
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
        let pos = self.pos();
        self.next();
        let name = self.ident()?;
        self.expect(Tok::LParen)?;
        let mut first = method;
        let params = self.list(Tok::RParen, |p| {
            let r = p.param(first);
            first = false;
            r
        })?;
        let ret = if self.eat(&Tok::Arrow) { self.ty()? } else { Type::Void };
        Ok(Func { name, params, ret, body: self.block()?, pos })
    }

    fn structdef(&mut self) -> P<StructDef> {
        let pos = self.pos();
        self.next();
        let name = self.ident()?;
        self.open()?;
        let fields = self.list(Tok::RBrace, |p| {
            let (n, t) = p.param(false)?;
            Ok((n, t.unwrap()))
        })?;
        Ok(StructDef { name, fields, pos })
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
                let name = self.ident()?;
                let ty = if self.eat(&Tok::Colon) { Some(self.ty()?) } else { None };
                self.expect(Tok::Assign)?;
                Stmt::Let { name, mutable, ty, value: self.expr()?, pos }
            }
            Tok::Return => {
                self.next();
                let bare = matches!(self.peek(), Tok::Newline | Tok::Semi | Tok::Star | Tok::RBrace);
                Stmt::Return(if bare { None } else { Some(self.expr()?) }, pos)
            }
            Tok::If => self.if_stmt()?,
            Tok::While => {
                self.next();
                let c = self.head()?;
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
        let c = self.head()?;
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
                Tok::Plus | Tok::Minus => 5,
                Tok::Times | Tok::Slash | Tok::Percent => 6,
                _ => 0,
            };
            if prec < min { return Ok(lhs) }
            let pos = self.pos();
            let op = self.next();
            let rhs = self.binary(prec + 1)?;
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
        let mut e = self.primary()?;
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
                Tok::Question => {
                    self.next();
                    Expr { kind: ExprKind::Try(Box::new(e)), pos }
                }
                Tok::LBrace | Tok::Star if !self.no_struct => {
                    let name = match &e.kind {
                        ExprKind::Var(n) => n.clone(),
                        ExprKind::Field(m, n) if matches!(&m.kind, ExprKind::Var(_)) => {
                            let ExprKind::Var(m) = &m.kind else { unreachable!() };
                            format!("{m}.{n}")
                        }
                        _ => return Ok(e),
                    };
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
        let kind = match self.next() {
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
                ExprKind::Match(Box::new(subject), arms)
            }
            t => return Err((pos, format!("expected a value, found {t}"))),
        };
        Ok(Expr { kind, pos })
    }

    fn arm(&mut self) -> P<(Pattern, Pos, Body)> {
        let pos = self.pos();
        let pat = match self.next() {
            Tok::Int(n) => Pattern::Int(n),
            Tok::Minus => match self.next() {
                Tok::Int(n) => Pattern::Int(-n),
                t => return Err((pos, format!("expected a number after `-`, found {t}"))),
            },
            Tok::Str(s) => Pattern::Str(s),
            Tok::Ident(s) if s == "_" => Pattern::Any,
            Tok::Ident(s) if s == "true" || s == "false" => Pattern::Bool(s == "true"),
            Tok::Ident(s) if s == "ok" || s == "err" => {
                self.expect(Tok::LParen)?;
                let name = self.ident()?;
                self.expect(Tok::RParen)?;
                if s == "ok" { Pattern::Ok(name) } else { Pattern::Err(name) }
            }
            t => return Err((pos, format!("expected a pattern (number, string, true/false, ok(x), err(e) or _), found {t}"))),
        };
        self.expect(Tok::FatArrow)?;
        let body = if self.at_open() { Body::Block(self.block()?) } else { Body::Expr(Box::new(self.expr()?)) };
        Ok((pat, pos, body))
    }
}
