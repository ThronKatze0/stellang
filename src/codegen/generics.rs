//! Generics, by monomorphization: `fn first<T>(xs: [T]) -> T?`, `struct Box<T>`, `enum Tree<T>`.
//!
//! A generic declaration is kept as a template. Each use with concrete types (`Box<int>`, `first` called
//! with a `[str]`) makes an instance: a struct, enum or function with its own key (`Box<int>`,
//! `first<str>`) that the rest of the compiler treats like any hand-written one. The type arguments of
//! a call are inferred from the arguments (and from the expected type, for things like `Stack.new()`).
//! Bodies are type-checked per instance, after the bound checks (`T: Show`) passed.

use super::*;
use crate::parser::{EnumDef, StructDef, TParam, Variant};

#[derive(Clone)]
pub(super) enum GDef {
    Struct(StructDef),
    Enum(EnumDef),
}

/// A generic struct or enum, with its methods (from its body, `impl` blocks and trait impls).
#[derive(Clone)]
pub(super) struct GType {
    pub module: String,
    pub params: Vec<TParam>,
    pub def: GDef,
    pub methods: Vec<Func>,
    pub traits: Vec<String>,
}

/// A generic function, or a method with its own type parameters (`outer` binds the type's).
#[derive(Clone)]
pub(super) struct GFn {
    pub module: String,
    pub func: Func,
    pub outer: HashMap<String, Type>,
    pub self_ty: Option<Type>,
}

/// An instance whose body still has to be generated.
pub(super) struct Pending {
    pub key: String,
    pub func: Func,
    pub module: String,
    pub subst: HashMap<String, Type>,
}

/// A trait: its methods, some with default bodies.
#[derive(Clone)]
pub(super) struct TraitInfo {
    pub methods: Vec<(Func, bool)>,
}

/// `geo.Box<geo.Point>` -> `Box<geo.Point>`
pub(super) fn short_name(k: &str) -> &str {
    let end = k.find('<').unwrap_or(k.len());
    match k[..end].rfind('.') {
        Some(i) => &k[i + 1..],
        None => k,
    }
}

/// `geo.Box<int>` -> `geo.Box`
pub(super) fn base_name(k: &str) -> &str {
    &k[..k.find('<').unwrap_or(k.len())]
}

/// The name a primitive goes by in `impl Show for int` and in method keys (`int::show`).
pub(super) fn prim_name(t: &Type) -> Option<&'static str> {
    Some(match t {
        Type::Int => "int",
        Type::Float => "float",
        Type::Str => "str",
        Type::Bool => "bool",
        _ => return None,
    })
}

fn mentions(t: &Type, names: &[String], b: &HashMap<String, Type>) -> bool {
    match t {
        Type::Struct(n) => names.contains(n) && !b.contains_key(n),
        Type::List(x) | Type::Set(x) | Type::Opt(x) | Type::Result(x) => mentions(x, names, b),
        Type::Map(k, v) => mentions(k, names, b) || mentions(v, names, b),
        Type::Fn(ps, r) => ps.iter().any(|p| mentions(p, names, b)) || mentions(r, names, b),
        Type::Generic(_, args) => args.iter().any(|a| mentions(a, names, b)),
        _ => false,
    }
}

impl Gen {
    /// `Box<int>`: the instance of template `tkey` for `args` (made on first use).
    pub(super) fn instantiate_type(&mut self, tkey: &str, args: Vec<Type>, pos: Pos) -> R<Type> {
        let g = self.gtypes[tkey].clone();
        let shown: Vec<String> = args.iter().map(|a| a.to_string()).collect();
        let key = format!("{tkey}<{}>", shown.join(", "));
        if self.structs.contains_key(&key) {
            return Ok(Type::Struct(key));
        }
        if self.enums.contains_key(&key) {
            return Ok(Type::Enum(key));
        }
        if args.len() != g.params.len() {
            let names: Vec<&str> = g.params.iter().map(|p| p.name.as_str()).collect();
            return err(pos, format!("`{}` takes {} type argument(s) ({}), got {}", short_name(tkey), g.params.len(), names.join(", "), args.len()));
        }
        if key.len() > 400 {
            return err(pos, format!("`{}` keeps nesting itself deeper (endless generic recursion)", short_name(tkey)));
        }
        for a in &args {
            if matches!(a, Type::Void | Type::Result(_)) {
                return err(pos, format!("{a} can't be a type argument"));
            }
        }
        for (p, a) in g.params.iter().zip(&args) {
            self.check_bounds(p, a, &g.module, pos)?;
        }
        let subst: HashMap<String, Type> = g.params.iter().map(|p| p.name.clone()).zip(args.iter().cloned()).collect();
        self.inst_of.insert(key.clone(), (tkey.to_string(), args));
        let ty = match &g.def {
            GDef::Struct(_) => {
                self.structs.insert(key.clone(), vec![]);
                Type::Struct(key.clone())
            }
            GDef::Enum(_) => {
                self.enums.insert(key.clone(), vec![]);
                Type::Enum(key.clone())
            }
        };
        for t in &g.traits {
            self.impls_of.insert((key.clone(), t.clone()));
        }
        let module = mem::replace(&mut self.module, g.module.clone());
        let saved = mem::replace(&mut self.tparams, subst.clone());
        match &g.def {
            GDef::Struct(s) => {
                let fields = self.fields(&key, &s.fields, s.pos)?;
                self.structs.insert(key.clone(), fields);
            }
            GDef::Enum(e) => {
                let vs = self.variants(&key, &e.variants)?;
                self.enums.insert(key.clone(), vs);
            }
        }
        for m in &g.methods {
            let mk = format!("{key}::{}", m.name);
            let is_static = m.params.first().is_none_or(|p| p.0 != "self" || p.1.is_some());
            if !m.tparams.is_empty() {
                let self_ty = (!is_static).then(|| ty.clone());
                self.gfns.insert(mk.clone(), GFn { module: g.module.clone(), func: m.clone(), outer: subst.clone(), self_ty });
                if is_static {
                    self.statics.insert(mk);
                }
                continue;
            }
            let sig = self.sig(m, (!is_static).then_some(&ty), format!("@\"st.{mk}\""))?;
            if is_static {
                self.statics.insert(mk.clone());
            }
            self.add_fn(mk.clone(), sig, m.pos, &m.name)?;
            self.pending.push(Pending { key: mk, func: m.clone(), module: g.module.clone(), subst: subst.clone() });
        }
        self.tparams = saved;
        self.module = module;
        Ok(ty)
    }

    /// The variants of an enum (shared by plain enums and instances of generic ones).
    pub(super) fn variants(&mut self, k: &str, variants: &[Variant]) -> R<Vec<VariantInfo>> {
        let mut vs: Vec<VariantInfo> = vec![];
        for v in variants {
            if vs.iter().any(|o| o.name == v.name) {
                return err(v.pos, format!("duplicate variant `{}`", v.name));
            }
            if ["ok", "err", "some", "none"].contains(&v.name.as_str()) {
                return err(v.pos, format!("`{}` is a builtin pattern; pick another variant name", v.name));
            }
            let fields = self.fields(&format!("{k}::{}", v.name), &v.fields, v.pos)?;
            let named = v.braces || v.fields.iter().any(|f| f.name.parse::<usize>().is_err());
            vs.push(VariantInfo { name: v.name.clone(), fields, braces: v.braces, named });
        }
        Ok(vs)
    }

    /// The trait a bound names, as a key.
    fn trait_key(&self, name: &str, module: &str, pos: Pos) -> R<String> {
        let k = match name.split_once('.') {
            Some(_) => name.to_string(),
            None if module.is_empty() => name.to_string(),
            None => format!("{module}.{name}"),
        };
        if self.traits.contains_key(&k) {
            return Ok(k);
        }
        if self.traits.contains_key(name) {
            return Ok(name.to_string());
        }
        err(pos, format!("unknown trait `{name}`"))
    }

    /// The key a type's methods and trait impls are filed under (`Point`, `Box<int>`, `int`).
    pub(super) fn method_owner(t: &Type) -> Option<String> {
        match t {
            Type::Struct(k) | Type::Enum(k) => Some(k.clone()),
            t => prim_name(t).map(str::to_string),
        }
    }

    pub(super) fn implements(&self, t: &Type, trait_key: &str) -> bool {
        let Some(owner) = Self::method_owner(t) else { return false };
        self.impls_of.contains(&(owner, trait_key.to_string()))
    }

    /// `T: Show + Eq` with `T` = `a`.
    fn check_bounds(&self, p: &TParam, a: &Type, module: &str, pos: Pos) -> R<()> {
        for b in &p.bounds {
            let tk = self.trait_key(b, module, pos)?;
            if !self.implements(a, &tk) {
                return err(pos, format!("{a} doesn't implement `{b}` (needed for `{}`; add `impl {b} for {a} {{ ... }}`)", p.name));
            }
        }
        Ok(())
    }

    /// Resolve `t` as written in a template from `module`, with type parameters bound by `b`.
    pub(super) fn resolve_in(&mut self, t: &Type, module: &str, b: &HashMap<String, Type>, pos: Pos) -> R<Type> {
        let m = mem::replace(&mut self.module, module.to_string());
        let saved = mem::replace(&mut self.tparams, b.clone());
        let r = self.resolve(t, pos);
        self.tparams = saved;
        self.module = m;
        r
    }

    /// The template a type name refers to, if it names a generic type.
    pub(super) fn template_key(&self, name: &str) -> Option<String> {
        let k = match name.split_once('.') {
            Some((m, s)) if self.imports[&self.module].contains(m) => format!("{m}.{s}"),
            Some(_) => return None,
            None => self.key(name),
        };
        self.gtypes.contains_key(&k).then_some(k)
    }

    /// Match pattern `p` (a type as written, mentioning the type parameters `names`) against the real
    /// type `t`, binding the parameters in `b`.
    pub(super) fn unify(&self, p: &Type, t: &Type, names: &[String], b: &mut HashMap<String, Type>, module: &str) -> Result<(), String> {
        match (p, t) {
            (Type::Struct(n), _) if names.contains(n) => match b.get(n) {
                Some(have) if have == t => Ok(()),
                Some(have) if *have == Type::Float && *t == Type::Int => Ok(()),
                Some(have) if *have == Type::Int && *t == Type::Float => {
                    b.insert(n.clone(), Type::Float);
                    Ok(())
                }
                Some(have) => Err(format!("`{n}` is {have} here, but {t} there")),
                None => {
                    if *t == Type::Void {
                        return Err(format!("`{n}` can't be void"));
                    }
                    b.insert(n.clone(), t.clone());
                    Ok(())
                }
            },
            (Type::List(x), Type::List(y)) | (Type::Set(x), Type::Set(y)) | (Type::Result(x), Type::Result(y)) => self.unify(x, y, names, b, module),
            (Type::Opt(x), Type::Opt(y)) => self.unify(x, y, names, b, module),
            (Type::Opt(x), y) => self.unify(x, y, names, b, module),
            (Type::Result(x), y) => self.unify(x, y, names, b, module),
            (Type::Map(k1, v1), Type::Map(k2, v2)) => {
                self.unify(k1, k2, names, b, module)?;
                self.unify(v1, v2, names, b, module)
            }
            (Type::Fn(ps, r), Type::Fn(qs, s)) if ps.len() == qs.len() => {
                for (p, q) in ps.iter().zip(qs) {
                    self.unify(p, q, names, b, module)?;
                }
                self.unify(r, s, names, b, module)
            }
            (Type::Generic(n, pargs), Type::Struct(k) | Type::Enum(k)) => {
                let Some((tk, aargs)) = self.inst_of.get(k) else { return Ok(()) };
                let full = match n.split_once('.') {
                    Some(_) => n.clone(),
                    None if module.is_empty() => n.clone(),
                    None => format!("{module}.{n}"),
                };
                if *tk != full || pargs.len() != aargs.len() {
                    return Ok(());
                }
                for (p, a) in pargs.iter().zip(aargs.clone()) {
                    self.unify(p, &a, names, b, module)?;
                }
                Ok(())
            }
            _ => Ok(()),
        }
    }

    /// The type `e` would have, without keeping the code (used to infer type arguments).
    pub(super) fn probe(&mut self, e: &Expr, hint: Option<&Type>) -> R<Type> {
        let (nb, open, cur, nn) = (self.f.body.len(), self.f.open, self.f.cur.clone(), self.notes.len());
        let r = match (hint, &e.kind) {
            (Some(h), ExprKind::Lambda(_)) => self.expr(e, Some(h)),
            (Some(h), _) => self.typed(e, h),
            (None, _) => self.expr(e, None),
        };
        self.f.body.truncate(nb);
        self.f.open = open;
        self.f.cur = cur;
        self.notes.truncate(nn);
        r.map(|v| v.ty)
    }

    /// Bind the type parameters `names` from the values given for each pattern (lambdas last, since
    /// their parameter types come from the others) and from the type the caller expects.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn infer(
        &mut self,
        names: &[String],
        mut b: HashMap<String, Type>,
        module: &str,
        given: &[(Type, &Expr)],
        ret: Option<&Type>,
        want: Option<&Type>,
        what: &str,
        pos: Pos,
    ) -> R<HashMap<String, Type>> {
        for pass in 0..2 {
            for (p, e) in given {
                let is_lambda = matches!(e.kind, ExprKind::Lambda(_));
                if (pass == 0) == is_lambda {
                    continue;
                }
                let hint = if !mentions(p, names, &b) {
                    Some(self.resolve_in(p, module, &b, e.pos)?)
                } else if let (true, Type::Fn(ps, r)) = (is_lambda, p) {
                    // a lambda needs its parameter types; the result type may still be open
                    if ps.iter().any(|x| mentions(x, names, &b)) {
                        let open: Vec<&String> = names.iter().filter(|n| !b.contains_key(*n)).collect();
                        let n = open.first().map_or("T".to_string(), |n| n.to_string());
                        return err(e.pos, format!("can't tell what `{n}` is for this lambda; give its parameters types: `(x: int) => ...`"));
                    }
                    let ps = ps.iter().map(|x| self.resolve_in(x, module, &b, e.pos)).collect::<R<Vec<_>>>()?;
                    let r = if mentions(r, names, &b) { None } else { Some(self.resolve_in(r, module, &b, e.pos)?) };
                    let ExprKind::Lambda(l) = &e.kind else { unreachable!() };
                    let (nb, open, cur, nn) = (self.f.body.len(), self.f.open, self.f.cur.clone(), self.notes.len());
                    let v = self.lambda_typed(l, Some(ps), r, e.pos);
                    self.f.body.truncate(nb);
                    self.f.open = open;
                    self.f.cur = cur;
                    self.notes.truncate(nn);
                    let t = v?.ty;
                    self.unify(p, &t, names, &mut b, module).map_err(|m| (e.pos, format!("{m} (in {what})")))?;
                    continue;
                } else {
                    None
                };
                let t = self.probe(e, hint.as_ref())?;
                self.unify(p, &t, names, &mut b, module).map_err(|m| (e.pos, format!("{m} (in {what})")))?;
            }
        }
        if let (Some(r), Some(w)) = (ret, want) {
            if names.iter().any(|n| !b.contains_key(n)) {
                let mut tb = b.clone();
                if self.unify(r, w, names, &mut tb, module).is_ok() {
                    b = tb;
                }
            }
        }
        if let Some(n) = names.iter().find(|n| !b.contains_key(*n)) {
            return err(pos, format!("can't tell what `{n}` is in {what}; give the result a type, like `let x: ... = ...`"));
        }
        Ok(b)
    }

    /// Call generic function (or method) `gkey`, inferring its type arguments.
    pub(super) fn call_generic(&mut self, gkey: &str, recv: Option<Val>, args: &[Expr], pos: Pos, want: Option<&Type>) -> R<Val> {
        let g = self.gfns[gkey].clone();
        let names: Vec<String> = g.func.tparams.iter().map(|p| p.name.clone()).collect();
        let skip = recv.is_some() as usize;
        let pats: Vec<Type> = g.func.params[skip..].iter().map(|p| p.1.clone().unwrap_or_default()).collect();
        let shown = short_name(gkey).replace("::", ".");
        if args.len() != pats.len() {
            return err(pos, format!("`{shown}` takes {} argument(s), got {}", pats.len(), args.len()));
        }
        let given: Vec<(Type, &Expr)> = pats.into_iter().zip(args.iter()).collect();
        let what = format!("`{shown}`");
        let b = self.infer(&names, g.outer.clone(), &g.module, &given, Some(&g.func.ret), want, &what, pos)?;
        let ikey = self.instantiate_fn(gkey, &g, &b, pos)?;
        let sig = self.funcs[&ikey].clone();
        self.note(pos, sig_text(&shown, &sig));
        let mut argl = vec![];
        if let Some(r) = recv {
            argl.push(format!("{} {}", ll(&r.ty), r.v));
        }
        argl.extend(self.args(&sig.params[skip..], args, pos, &shown)?);
        Ok(self.emit_call(&sig.ret, &sig.sym, &argl))
    }

    /// The instance of generic function `gkey` for bindings `b`; returns its key in `funcs`.
    pub(super) fn instantiate_fn(&mut self, gkey: &str, g: &GFn, b: &HashMap<String, Type>, pos: Pos) -> R<String> {
        let own: Vec<String> = g.func.tparams.iter().map(|p| b[&p.name].to_string()).collect();
        let ikey = format!("{gkey}<{}>", own.join(", "));
        if self.funcs.contains_key(&ikey) {
            return Ok(ikey);
        }
        if ikey.len() > 400 {
            return err(pos, format!("`{}` keeps instantiating itself with bigger types (endless generic recursion)", short_name(gkey)));
        }
        for p in &g.func.tparams {
            self.check_bounds(p, &b[&p.name], &g.module, pos)?;
        }
        let module = mem::replace(&mut self.module, g.module.clone());
        let saved = mem::replace(&mut self.tparams, b.clone());
        let sig = self.sig(&g.func, g.self_ty.as_ref(), format!("@\"st.{ikey}\""));
        self.tparams = saved;
        self.module = module;
        self.funcs.insert(ikey.clone(), sig?);
        self.pending.push(Pending { key: ikey.clone(), func: g.func.clone(), module: g.module.clone(), subst: b.clone() });
        Ok(ikey)
    }

    /// The instance a template is used as, from the expected type (`let b: Box<int> = Box { ... }`).
    pub(super) fn instance_from_want(&self, tkey: &str, want: Option<&Type>) -> Option<String> {
        match peel_all(want) {
            Some(Type::Struct(k) | Type::Enum(k)) if self.inst_of.get(k).is_some_and(|i| i.0 == tkey) => Some(k.clone()),
            _ => None,
        }
    }

    /// Infer the instance of template `tkey` from values given for some of its fields.
    pub(super) fn infer_type(&mut self, tkey: &str, given: &[(Type, &Expr)], want: Option<&Type>, pos: Pos) -> R<String> {
        if let Some(k) = self.instance_from_want(tkey, want) {
            return Ok(k);
        }
        let g = self.gtypes[tkey].clone();
        let names: Vec<String> = g.params.iter().map(|p| p.name.clone()).collect();
        let ret = Type::Generic(short_name(tkey).to_string(), names.iter().map(|n| Type::Struct(n.clone())).collect());
        let what = format!("`{}`", short_name(tkey));
        let b = self.infer(&names, HashMap::new(), &g.module, given, Some(&ret), want, &what, pos)?;
        let args = names.iter().map(|n| b[n].clone()).collect();
        match self.instantiate_type(tkey, args, pos)? {
            Type::Struct(k) | Type::Enum(k) => Ok(k),
            _ => unreachable!(),
        }
    }

    /// Field types of a template's struct, or of one of its enum's variants, as written.
    pub(super) fn template_fields(&self, tkey: &str, variant: Option<&str>) -> Vec<(String, Type)> {
        match (&self.gtypes[tkey].def, variant) {
            (GDef::Struct(s), _) => s.fields.iter().map(|f| (f.name.clone(), f.ty.clone())).collect(),
            (GDef::Enum(e), Some(v)) => e.variants.iter().find(|x| x.name == v).map_or(vec![], |x| x.fields.iter().map(|f| (f.name.clone(), f.ty.clone())).collect()),
            (GDef::Enum(_), None) => vec![],
        }
    }

    /// `impl Show for Point`: check the methods against the trait and fill in its defaults.
    pub(super) fn trait_methods(&self, trait_name: &str, methods: &[Func], ty_name: &str, pos: Pos) -> R<(String, Vec<Func>)> {
        let tk = self.trait_key(trait_name, &self.module, pos)?;
        let t = self.traits[&tk].clone();
        let mut out = methods.to_vec();
        for m in methods {
            if !t.methods.iter().any(|(tm, _)| tm.name == m.name) {
                return err(m.pos, format!("`{}` isn't part of trait `{trait_name}`", m.name));
            }
        }
        for (tm, has_body) in &t.methods {
            match methods.iter().find(|m| m.name == tm.name) {
                Some(m) => {
                    if m.params.len() != tm.params.len() {
                        return err(m.pos, format!("`{}` takes {} parameter(s) in trait `{trait_name}`", tm.name, tm.params.len()));
                    }
                }
                None if *has_body => out.push(tm.clone()),
                None => return err(pos, format!("`impl {trait_name} for {ty_name}` is missing `fn {}`", tm.name)),
            }
        }
        Ok((tk, out))
    }

    /// Generate the bodies of instances made so far (each may make more).
    pub(super) fn gen_pending(&mut self) -> R<()> {
        while let Some(p) = self.pending.pop() {
            let module = mem::replace(&mut self.module, p.module.clone());
            let saved = mem::replace(&mut self.tparams, p.subst.clone());
            self.gen_named(&p.key, &p.func).map_err(|(pos, m)| (pos, if m.contains("(in `") { m } else { format!("{m} (in `{}`)", p.key.replace("::", ".")) }))?;
            self.tparams = saved;
            self.module = module;
        }
        Ok(())
    }
}
