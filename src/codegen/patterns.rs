//! Enum values, struct/variant literals, and pattern matching (`match`, `if let`, `let ... else`).

use super::*;

/// What a pattern covers, for exhaustiveness: everything, or some of the type's cases.
enum Cov {
    All,
    Tags(HashSet<String>),
}

/// In `if let` / `while let` / `let ... else`, a pattern on an optional or a result looks inside it:
/// `if let user = find(id)` means `if let some(user) = find(id)`.
pub(super) fn unwrap_pat(p: &Pat, ty: &Type) -> Pat {
    let wrap = match ty {
        Type::Opt(_) => "some",
        Type::Result(_) => "ok",
        _ => return p.clone(),
    };
    let explicit = match &p.kind {
        PatKind::Any => true,
        PatKind::Name(n) => n == "none",
        PatKind::Variant(path, _) => path.len() == 1 && ["some", "none", "ok", "err"].contains(&path[0].as_str()),
        _ => false,
    };
    if explicit {
        return p.clone();
    }
    Pat { kind: PatKind::Variant(vec![wrap.into()], Some(vec![p.clone()])), pos: p.pos }
}

impl Gen {
    // ---- building values ----

    /// Allocate an object of LLVM type `lty`, store the tag (for variants) and the fields.
    pub(super) fn build(&mut self, lty: &str, tag: Option<usize>, vals: &[Val]) -> String {
        let (g, sz) = (self.tmp(), self.tmp());
        self.ins(format!("{g} = getelementptr {lty}, ptr null, i64 1"));
        self.ins(format!("{sz} = ptrtoint ptr {g} to i64"));
        let obj = self.rt(Type::Str, "st_alloc", &[format!("i64 {sz}")]).v;
        let off = tag.is_some() as usize;
        if let Some(t) = tag {
            self.ins(format!("store i64 {t}, ptr {obj}"));
        }
        for (i, v) in vals.iter().enumerate() {
            let p = self.tmp();
            self.ins(format!("{p} = getelementptr inbounds {lty}, ptr {obj}, i32 0, i32 {}", i + off));
            self.store(&p, v);
        }
        obj
    }

    /// The values for `fields`, given by name or by position; missing ones use the declared default,
    /// and optional fields default to `none`.
    pub(super) fn fill(
        &mut self,
        what: &str,
        dkey: &str,
        fields: &[(String, Type)],
        named: Option<&[(String, Expr)]>,
        positional: Option<&[Expr]>,
        pos: Pos,
    ) -> R<Vec<Val>> {
        if let Some(given) = named {
            for (f, x) in given {
                if !fields.iter().any(|d| d.0 == *f) {
                    return err(x.pos, format!("`{what}` has no field `{f}`"));
                }
                if given.iter().filter(|g| g.0 == *f).count() > 1 {
                    return err(x.pos, format!("field `{f}` is given twice"));
                }
            }
        }
        if let Some(args) = positional {
            if args.len() > fields.len() {
                return err(pos, format!("`{what}` takes {} value(s), got {}", fields.len(), args.len()));
            }
        }
        let mut vals = vec![];
        for (i, (f, ft)) in fields.iter().enumerate() {
            let given = match (named, positional) {
                (Some(g), _) => g.iter().find(|x| x.0 == *f).map(|x| &x.1),
                (_, Some(a)) => a.get(i),
                _ => None,
            };
            let v = match given {
                Some(x) => self.typed(x, ft)?,
                None => match self.default_of(dkey, f, ft)? {
                    Some(v) => v,
                    None if matches!(ft, Type::Opt(_)) => val("zeroinitializer", ft.clone()),
                    None if f.parse::<usize>().is_ok() => {
                        return err(pos, format!("`{what}` takes {} value(s), got {}", fields.len(), positional.map_or(0, |a| a.len())))
                    }
                    None => return err(pos, format!("missing field `{f}` in `{what}`")),
                },
            };
            vals.push(v);
        }
        Ok(vals)
    }

    /// Evaluate a field's declared default, in the module that declared it (and without local names).
    fn default_of(&mut self, dkey: &str, f: &str, ft: &Type) -> R<Option<Val>> {
        let Some((m, defs)) = self.defaults.get(dkey) else { return Ok(None) };
        let Some((_, e)) = defs.iter().find(|d| d.0 == f) else { return Ok(None) };
        let (m, e) = (m.clone(), e.clone());
        let module = mem::replace(&mut self.module, m);
        let scopes = mem::replace(&mut self.f.scopes, vec![HashMap::new()]);
        let loops = mem::take(&mut self.f.loops);
        let r = self.typed(&e, ft);
        self.module = module;
        self.f.scopes = scopes;
        self.f.loops = loops;
        r.map(Some)
    }

    fn variant_index(&self, k: &str, name: &str, pos: Pos) -> R<usize> {
        match self.enums[k].iter().position(|v| v.name == name) {
            Some(i) => Ok(i),
            None => {
                let names: Vec<&str> = self.enums[k].iter().map(|v| v.name.as_str()).collect();
                err(pos, format!("`{k}` has no variant `{name}` (it has {})", names.join(", ")))
            }
        }
    }

    /// `Shape.Empty` / `.Empty`: a variant without values.
    pub(super) fn variant_value(&mut self, k: &str, name: &str, pos: Pos) -> R<Val> {
        let i = self.variant_index(k, name, pos)?;
        if self.enums[k][i].fields.is_empty() {
            return Ok(val(format!("@\"U.{k}.{name}\""), Type::Enum(k.into())));
        }
        if self.enums[k][i].braces {
            return err(pos, format!("`{name}` holds values: write `{name} {{ ... }}`"));
        }
        err(pos, format!("`{name}` holds values: write `{name}(...)`"))
    }

    pub(super) fn make_variant(&mut self, k: &str, i: usize, named: Option<&[(String, Expr)]>, positional: Option<&[Expr]>, pos: Pos) -> R<Val> {
        let v = self.enums[k][i].clone();
        if v.fields.is_empty() {
            if positional.is_some_and(|a| !a.is_empty()) {
                return err(pos, format!("`{}` holds no values", v.name));
            }
            return Ok(val(format!("@\"U.{k}.{}\"", v.name), Type::Enum(k.into())));
        }
        let vals = self.fill(&v.name, &format!("{k}::{}", v.name), &v.fields, named, positional, pos)?;
        let obj = self.build(&format!("%\"V.{k}.{}\"", v.name), Some(i), &vals);
        Ok(val(obj, Type::Enum(k.into())))
    }

    /// What `Name { ... }` builds: `Point`, `geo.Point`, `Shape.Rect`, `geo.Shape.Rect` or `.Rect`.
    pub(super) fn lit_target(&self, name: &str, want: Option<&Type>, pos: Pos) -> R<Lit> {
        if let Some(v) = name.strip_prefix('.') {
            let Some(Type::Enum(k)) = peel_all(want) else {
                return err(pos, format!("can't tell which enum `.{v}` belongs to; write `Type.{v} {{ ... }}`"));
            };
            return Ok(Lit::Variant(k.clone(), self.variant_index(k, v, pos)?));
        }
        let parts: Vec<&str> = name.split('.').collect();
        let as_type = |n: &str| -> Option<String> {
            let k = match n.split_once('.') {
                Some((m, _)) if self.is_module(m) => n.to_string(),
                Some(_) => return None,
                None => self.key(n),
            };
            (self.structs.contains_key(&k) || self.enums.contains_key(&k)).then_some(k)
        };
        if let Some(k) = as_type(name) {
            if self.enums.contains_key(&k) {
                return err(pos, format!("`{name}` is an enum; pick a variant: `{name}.Variant {{ ... }}`"));
            }
            return Ok(Lit::Struct(k));
        }
        if parts.len() >= 2 {
            let (prefix, v) = name.rsplit_once('.').unwrap();
            if let Some(k) = as_type(prefix).filter(|k| self.enums.contains_key(k)) {
                return Ok(Lit::Variant(k.clone(), self.variant_index(&k, v, pos)?));
            }
            if parts.len() == 2 && !self.is_module(parts[0]) {
                return err(pos, format!("unknown type or module `{}`", parts[0]));
            }
        }
        // the old error messages: unknown type / unknown module
        self.resolve(&Type::Struct(name.into()), pos)?;
        err(pos, format!("unknown type `{name}`"))
    }

    // ---- matching ----

    pub(super) fn match_expr(&mut self, subject: &Expr, arms: &[Arm], want: Option<&Type>) -> R<Val> {
        let s = self.expr(subject, None)?;
        if matches!(s.ty, Type::Void) {
            return err(subject.pos, "this has no value to match on");
        }
        let lend = self.lbl("endmatch");
        let mut j = Join::default();
        let all = self.all_tags(&s.ty);
        let (mut covered, mut full) = (HashSet::new(), false);
        for arm in arms {
            if full {
                return err(arm.pat.pos, "this arm can never run: the arms above already cover everything");
            }
            let lnext = self.lbl("next");
            self.f.scopes.push(HashMap::new());
            let r = self.arm(arm, &s, &lnext, want);
            self.f.scopes.pop();
            let v = r?;
            let at = match &arm.body {
                Body::Expr(e) => e.pos,
                Body::Block(_) => arm.pat.pos,
            };
            self.join(&mut j, v, &lend, at);
            self.label(&lnext);
            if arm.guard.is_none() {
                match self.cover(&arm.pat, &s.ty) {
                    Cov::All => full = true,
                    Cov::Tags(t) => covered.extend(t),
                }
                full |= !all.is_empty() && all.iter().all(|t| covered.contains(t));
            }
        }
        if full {
            self.term("unreachable".into());
        } else {
            if matches!(s.ty, Type::Enum(_) | Type::Opt(_)) {
                let mut missing: Vec<String> = self.tag_order(&s.ty).into_iter().filter(|t| !covered.contains(t)).collect();
                if let Type::Enum(k) = &s.ty {
                    let short = k.rsplit('.').next().unwrap();
                    missing = missing.into_iter().map(|m| format!("{short}.{m}")).collect();
                }
                return err(subject.pos, format!("this `match` doesn't handle {} (add arms, or `_ => ...`)", missing.join(", ")));
            }
            self.join(&mut j, void(), &lend, subject.pos); // nothing matched
        }
        self.finish(j, &lend, full)
    }

    fn arm(&mut self, arm: &Arm, s: &Val, lnext: &str, want: Option<&Type>) -> R<Val> {
        let mut binds = vec![];
        self.pat_test(&arm.pat, s, lnext, &mut binds)?;
        for (n, b) in binds {
            self.declare(&n, &b, false);
        }
        if let Some(g) = &arm.guard {
            let c = self.cond(g)?;
            self.need(&c, lnext);
        }
        self.arm_body(&arm.body, want)
    }

    /// Emit the tests of `p` against `v`: jump to `fail` on a mismatch, fall through on a match.
    /// The names it binds go into `binds`.
    pub(super) fn pat_test(&mut self, p: &Pat, v: &Val, fail: &str, binds: &mut Vec<(String, Val)>) -> R<()> {
        let pos = p.pos;
        let mismatch = |what: &str| err(pos, format!("this pattern is {what}, but the value is {}", v.ty));
        match &p.kind {
            PatKind::Any => {}
            PatKind::Name(n) => {
                if n == "none" {
                    let Type::Opt(_) = v.ty else { return mismatch("`none`") };
                    let (missing, _) = self.failed(v, pos)?;
                    self.need(&missing.v, fail);
                } else if let Some(i) = self.unit_variant(&v.ty, n) {
                    self.tag_test(v, i, fail);
                } else {
                    if RESERVED.contains(&n.as_str()) && n != "self" {
                        return err(pos, format!("`{n}` is a builtin name"));
                    }
                    if binds.iter().any(|b| b.0 == *n) {
                        return err(pos, format!("`{n}` is bound twice in this pattern"));
                    }
                    binds.push((n.clone(), v.clone()));
                }
            }
            PatKind::Int(n) => {
                if v.ty != Type::Int { return mismatch("an int") }
                let t = self.tmp();
                self.ins(format!("{t} = icmp eq i64 {}, {n}", v.v));
                self.need(&t, fail);
            }
            PatKind::Bool(b) => {
                if v.ty != Type::Bool { return mismatch("a bool") }
                let t = self.tmp();
                self.ins(format!("{t} = icmp eq i1 {}, {b}", v.v));
                self.need(&t, fail);
            }
            PatKind::Str(x) => {
                if v.ty != Type::Str { return mismatch("a str") }
                let g = self.str_const(x);
                let r = self.rt(Type::Bool, "st_streq", &[format!("ptr {}", v.v), format!("ptr {g}")]);
                self.need(&r.v, fail);
            }
            PatKind::Or(alts) => {
                let lok = self.lbl("orok");
                for (i, a) in alts.iter().enumerate() {
                    let last = i + 1 == alts.len();
                    let lnext = if last { fail.to_string() } else { self.lbl("ornext") };
                    let mut inner = vec![];
                    self.pat_test(a, v, &lnext, &mut inner)?;
                    if !inner.is_empty() {
                        return err(a.pos, "patterns joined with `|` can't bind names");
                    }
                    self.term(format!("br label %{lok}"));
                    if !last {
                        self.label(&lnext);
                    }
                }
                self.label(&lok);
            }
            PatKind::Variant(path, args) => {
                let last = path.last().unwrap().as_str();
                let builtin = path.len() == 1;
                match (&v.ty, last) {
                    (Type::Result(t), "ok" | "err") if builtin => {
                        let is_ok = last == "ok";
                        let e = self.extract(v, 0, Type::Bool);
                        let want = if is_ok {
                            let n = self.tmp();
                            self.ins(format!("{n} = xor i1 {}, true", e.v));
                            n
                        } else {
                            e.v
                        };
                        self.need(&want, fail);
                        let sub = self.one_sub(args, last, pos)?;
                        if let Some(sub) = sub {
                            let inner = if is_ok {
                                if **t == Type::Void {
                                    if !matches!(sub.kind, PatKind::Any) {
                                        return err(sub.pos, "this result has no value; write `ok(_)`");
                                    }
                                    return Ok(());
                                }
                                self.extract(v, 1, (**t).clone())
                            } else {
                                self.extract(v, 2, Type::Str)
                            };
                            self.pat_test(sub, &inner, fail, binds)?;
                        }
                    }
                    (Type::Opt(t), "some") if builtin => {
                        let has = self.extract(v, 0, Type::Bool);
                        self.need(&has.v, fail);
                        if let Some(sub) = self.one_sub(args, last, pos)? {
                            let inner = self.extract(v, 1, (**t).clone());
                            self.pat_test(sub, &inner, fail, binds)?;
                        }
                    }
                    (Type::Opt(_), "none") if builtin && args.is_none() => {
                        let (missing, _) = self.failed(v, pos)?;
                        self.need(&missing.v, fail);
                    }
                    (Type::Enum(k), _) => {
                        let k = k.clone();
                        self.check_prefix(path, &k, pos)?;
                        let i = self.variant_index(&k, last, pos)?;
                        self.tag_test(v, i, fail);
                        if let Some(args) = args {
                            let vi = self.enums[&k][i].clone();
                            if args.len() != vi.fields.len() {
                                return err(pos, format!("`{last}` holds {} value(s), this pattern has {}", vi.fields.len(), args.len()));
                            }
                            for (j, a) in args.iter().enumerate() {
                                let x = self.variant_field(v, &k, i, j);
                                self.pat_test(a, &x, fail, binds)?;
                            }
                        }
                    }
                    _ => return mismatch(&format!("`{}`", path.join("."))),
                }
            }
            PatKind::Fields(path, fs) => {
                let last = path.last().unwrap().as_str();
                let (fields, k, i) = match &v.ty {
                    Type::Enum(k) => {
                        let k = k.clone();
                        self.check_prefix(path, &k, pos)?;
                        let i = self.variant_index(&k, last, pos)?;
                        self.tag_test(v, i, fail);
                        (self.enums[&k][i].fields.clone(), k, Some(i))
                    }
                    Type::Struct(k) if k.rsplit('.').next() == Some(last) => (self.structs[k].clone(), k.clone(), None),
                    _ => return mismatch(&format!("`{}`", path.join("."))),
                };
                for (f, sub) in fs {
                    let Some(j) = fields.iter().position(|x| x.0 == *f) else {
                        return err(sub.pos, format!("`{last}` has no field `{f}`"));
                    };
                    let x = match i {
                        Some(i) => self.variant_field(v, &k, i, j),
                        None => {
                            let (p, t) = self.field_ptr(v, f, sub.pos)?;
                            self.load(&p, t)
                        }
                    };
                    self.pat_test(sub, &x, fail, binds)?;
                }
            }
        }
        Ok(())
    }

    /// `ok(x)` / `some(x)` take exactly one pattern (or none: `ok` alone is `ok(_)`).
    fn one_sub<'a>(&self, args: &'a Option<Vec<Pat>>, name: &str, pos: Pos) -> R<Option<&'a Pat>> {
        match args.as_deref() {
            None => Ok(None),
            Some([p]) => Ok(Some(p)),
            Some(_) => err(pos, format!("`{name}(...)` takes one pattern")),
        }
    }

    /// In `Shape.Circle(r)` / `geo.Shape.Circle(r)`, the `Shape` part must be the value's enum.
    fn check_prefix(&self, path: &[String], k: &str, pos: Pos) -> R<()> {
        if path.len() < 2 {
            return Ok(());
        }
        let prefix = path[..path.len() - 1].join(".");
        let key = if path.len() == 2 { self.key(&prefix) } else { prefix.clone() };
        if key != k {
            return err(pos, format!("this pattern is for `{prefix}`, but the value is {k}"));
        }
        Ok(())
    }

    fn unit_variant(&self, t: &Type, name: &str) -> Option<usize> {
        let Type::Enum(k) = t else { return None };
        self.enums[k].iter().position(|v| v.name == name)
    }

    fn tag_test(&mut self, v: &Val, i: usize, fail: &str) {
        let (tag, t) = (self.tmp(), self.tmp());
        self.ins(format!("{tag} = load i64, ptr {}", v.v));
        self.ins(format!("{t} = icmp eq i64 {tag}, {i}"));
        self.need(&t, fail);
    }

    /// Field `j` of variant `i` (the caller checked the tag).
    pub(super) fn variant_field(&mut self, v: &Val, k: &str, i: usize, j: usize) -> Val {
        let vi = &self.enums[k][i];
        let (name, ft) = (vi.name.clone(), vi.fields[j].1.clone());
        let p = self.tmp();
        self.ins(format!("{p} = getelementptr inbounds %\"V.{k}.{name}\", ptr {}, i32 0, i32 {}", v.v, j + 1));
        self.load(&p, ft)
    }

    // ---- exhaustiveness ----

    fn tag_order(&self, t: &Type) -> Vec<String> {
        match t {
            Type::Enum(k) => self.enums[k].iter().map(|v| v.name.clone()).collect(),
            Type::Bool => vec!["true".into(), "false".into()],
            Type::Result(_) => vec!["ok".into(), "err".into()],
            Type::Opt(_) => vec!["some".into(), "none".into()],
            _ => vec![],
        }
    }

    fn all_tags(&self, t: &Type) -> HashSet<String> {
        self.tag_order(t).into_iter().collect()
    }

    pub(super) fn irrefutable(&self, p: &Pat, t: &Type) -> bool {
        match self.cover(p, t) {
            Cov::All => true,
            Cov::Tags(c) => {
                let all = self.all_tags(t);
                !all.is_empty() && all.iter().all(|x| c.contains(x))
            }
        }
    }

    fn cover(&self, p: &Pat, t: &Type) -> Cov {
        let one = |s: &str| Cov::Tags(HashSet::from([s.to_string()]));
        let none = || Cov::Tags(HashSet::new());
        match (&p.kind, t) {
            (PatKind::Any, _) => Cov::All,
            (PatKind::Name(n), Type::Opt(_)) if n == "none" => one("none"),
            (PatKind::Name(n), _) if self.unit_variant(t, n).is_some() => one(n),
            (PatKind::Name(_), _) => Cov::All,
            (PatKind::Bool(b), _) => one(&b.to_string()),
            (PatKind::Int(_) | PatKind::Str(_), _) => none(),
            (PatKind::Or(alts), _) => {
                let mut all = HashSet::new();
                for a in alts {
                    match self.cover(a, t) {
                        Cov::All => return Cov::All,
                        Cov::Tags(s) => all.extend(s),
                    }
                }
                Cov::Tags(all)
            }
            (PatKind::Variant(path, args), _) => {
                let last = path.last().unwrap().as_str();
                let subs: Vec<(Pat, Type)> = match (t, last) {
                    (Type::Result(t), "ok") => args.iter().flatten().map(|a| (a.clone(), (**t).clone())).collect(),
                    (Type::Result(_), "err") => args.iter().flatten().map(|a| (a.clone(), Type::Str)).collect(),
                    (Type::Opt(t), "some") => args.iter().flatten().map(|a| (a.clone(), (**t).clone())).collect(),
                    (Type::Opt(_), "none") => vec![],
                    (Type::Enum(k), _) => match self.enums[k].iter().find(|v| v.name == last) {
                        Some(v) => args.iter().flatten().zip(&v.fields).map(|(a, f)| (a.clone(), f.1.clone())).collect(),
                        None => return none(),
                    },
                    _ => return none(),
                };
                if subs.iter().all(|(a, t)| self.irrefutable(a, t)) { one(last) } else { none() }
            }
            (PatKind::Fields(path, fs), _) => {
                let last = path.last().unwrap().as_str();
                let fields = match t {
                    Type::Enum(k) => match self.enums[k].iter().find(|v| v.name == last) {
                        Some(v) => v.fields.clone(),
                        None => return none(),
                    },
                    Type::Struct(k) => self.structs[k].clone(),
                    _ => return none(),
                };
                let ok = fs.iter().all(|(f, sub)| fields.iter().find(|x| x.0 == *f).is_some_and(|x| self.irrefutable(sub, &x.1)));
                match (ok, t) {
                    (true, Type::Struct(_)) => Cov::All,
                    (true, _) => one(last),
                    _ => none(),
                }
            }
        }
    }
}
