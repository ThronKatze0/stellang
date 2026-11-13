//! Generated helper functions: structural `==`, `str()` of enums, and `to_json()`.

use super::*;

impl Gen {
    /// Emit `define internal <ret> <sym>(<params>)` with a body built by `body` (once per symbol).
    fn helper(&mut self, sym: &str, params: &str, ret: &str, body: impl FnOnce(&mut Self) -> R<()>) -> R<()> {
        let saved = mem::take(&mut self.f);
        self.f.open = true;
        self.f.cur = "entry".into();
        self.f.scopes = vec![HashMap::new()];
        let r = body(self);
        let f = mem::replace(&mut self.f, saved);
        r?;
        write!(self.code, "define internal {ret} {sym}({params}) {{\nentry:\n{}\n{}\n}}\n\n", f.allocas.join("\n"), f.body.join("\n")).unwrap();
        Ok(())
    }

    fn concat(&mut self, a: &str, b: &str) -> String {
        self.rt(Type::Str, "st_concat", &[format!("ptr {a}"), format!("ptr {b}")]).v
    }

    /// `open + parts.join(sep) + close`
    fn wrap_join(&mut self, parts: &Val, sep: &str, open: &str, close: &str) -> String {
        let sep = self.str_const(sep);
        let body = self.rt(Type::Str, "st_join", &[format!("ptr {}", parts.v), format!("ptr {sep}")]).v;
        let (o, c) = (self.str_const(open), self.str_const(close));
        let a = self.concat(&o, &body);
        self.concat(&a, &c)
    }

    fn push_str(&mut self, list: &Val, s: &str) {
        self.rt(Type::Void, "st_vec_push_str", &[format!("ptr {}", list.v), format!("ptr {s}")]);
    }

    /// Jump to one label per variant of enum `k`, by the tag of `x`.
    fn switch_variants(&mut self, x: &Val, k: &str) -> Vec<String> {
        let n = self.enums[k].len();
        let tag = self.tmp();
        self.ins(format!("{tag} = load i64, ptr {}", x.v));
        let labels: Vec<String> = (0..n).map(|_| self.lbl("variant")).collect();
        let bad = self.lbl("badtag");
        let cases: Vec<String> = labels.iter().enumerate().map(|(i, l)| format!("i64 {i}, label %{l}")).collect();
        self.term(format!("switch i64 {tag}, label %{bad} [ {} ]", cases.join(" ")));
        self.label(&bad);
        self.term("unreachable".into());
        labels
    }

    // ---- == ----

    pub(super) fn eq_fn(&mut self, t: &Type, pos: Pos) -> R<String> {
        let sym = format!("@\"eq.{t}\"");
        if self.shown.insert(sym.clone()) {
            let l = ll(t);
            self.helper(&sym, &format!("{l} %a, {l} %b"), "i1", |g| g.eq_body(t, pos))?;
        }
        Ok(sym)
    }

    fn eq_body(&mut self, t: &Type, pos: Pos) -> R<()> {
        let (a, b) = (val("%a", t.clone()), val("%b", t.clone()));
        let (lyes, lno) = (self.lbl("same"), self.lbl("differ"));
        let same_ptr = |g: &mut Self| {
            let (s, l) = (g.tmp(), g.lbl("cmp"));
            g.ins(format!("{s} = icmp eq ptr %a, %b"));
            g.term(format!("br i1 {s}, label %{lyes}, label %{l}"));
            g.label(&l);
        };
        match t {
            Type::Struct(k) => {
                same_ptr(self);
                for (f, ft) in self.structs[k].clone() {
                    let (pa, _) = self.field_ptr(&a, &f, pos)?;
                    let (pb, _) = self.field_ptr(&b, &f, pos)?;
                    let (va, vb) = (self.load(&pa, ft.clone()), self.load(&pb, ft));
                    let e = self.eq(va, vb, pos)?;
                    self.need(&e, &lno);
                }
            }
            Type::Enum(k) => {
                same_ptr(self);
                let (ta, tb, s) = (self.tmp(), self.tmp(), self.tmp());
                self.ins(format!("{ta} = load i64, ptr %a"));
                self.ins(format!("{tb} = load i64, ptr %b"));
                self.ins(format!("{s} = icmp eq i64 {ta}, {tb}"));
                self.need(&s, &lno);
                let labels = self.switch_variants(&a, k);
                for (i, l) in labels.iter().enumerate() {
                    self.label(l);
                    for j in 0..self.enums[k][i].fields.len() {
                        let (va, vb) = (self.variant_field(&a, k, i, j), self.variant_field(&b, k, i, j));
                        let e = self.eq(va, vb, pos)?;
                        self.need(&e, &lno);
                    }
                    self.term(format!("br label %{lyes}"));
                }
            }
            Type::List(et) => {
                same_ptr(self);
                let (la, lb, s) = (self.tmp(), self.tmp(), self.tmp());
                self.ins(format!("{la} = load i64, ptr %a"));
                self.ins(format!("{lb} = load i64, ptr %b"));
                self.ins(format!("{s} = icmp eq i64 {la}, {lb}"));
                self.need(&s, &lno);
                let lno2 = lno.clone();
                self.each(&a, et, |g, x, i| {
                    let (_, d) = g.vec_parts("%b");
                    let p = g.tmp();
                    g.ins(format!("{p} = getelementptr inbounds {}, ptr {d}, i64 {i}", ll(et)));
                    let y = g.load(&p, (**et).clone());
                    let e = g.eq(x, y, pos)?;
                    g.need(&e, &lno2);
                    Ok(())
                })?;
            }
            Type::Opt(inner) => {
                let (ha, hb) = (self.extract(&a, 0, Type::Bool), self.extract(&b, 0, Type::Bool));
                let s = self.tmp();
                self.ins(format!("{s} = icmp eq i1 {}, {}", ha.v, hb.v));
                self.need(&s, &lno);
                let l = self.lbl("both");
                self.term(format!("br i1 {}, label %{l}, label %{lyes}", ha.v));
                self.label(&l);
                let (va, vb) = (self.extract(&a, 1, (**inner).clone()), self.extract(&b, 1, (**inner).clone()));
                let e = self.eq(va, vb, pos)?;
                self.need(&e, &lno);
            }
            t => return err(pos, format!("`==` can't compare {t}")),
        }
        if self.f.open {
            self.term(format!("br label %{lyes}"));
        }
        self.label(&lyes);
        self.term("ret i1 true".into());
        self.label(&lno);
        self.term("ret i1 false".into());
        Ok(())
    }

    // ---- str() ----

    /// `Circle(2.0)`, `Rect { w: 1, h: 2 }`, `Empty`
    pub(super) fn show_enum(&mut self, k: &str, pos: Pos) -> R<()> {
        let x = val("%x", Type::Enum(k.into()));
        let labels = self.switch_variants(&x, k);
        for (i, l) in labels.iter().enumerate() {
            self.label(l);
            let v = self.enums[k][i].clone();
            if v.fields.is_empty() {
                let s = self.str_const(&v.name);
                self.term(format!("ret ptr {s}"));
                continue;
            }
            let parts = self.new_list(&Type::Str);
            for (j, (f, _)) in v.fields.iter().enumerate() {
                let fv = self.variant_field(&x, k, i, j);
                let mut s = self.show(&fv, true, pos)?.v;
                if v.named {
                    let label = self.str_const(&format!("{f}: "));
                    s = self.concat(&label, &s);
                }
                self.push_str(&parts, &s);
            }
            let r = if v.braces {
                self.wrap_join(&parts, ", ", &format!("{} {{ ", v.name), " }")
            } else {
                self.wrap_join(&parts, ", ", &format!("{}(", v.name), ")")
            };
            self.term(format!("ret ptr {r}"));
        }
        Ok(())
    }

    /// `str()` of a `T?`: the value, or `none`.
    pub(super) fn show_opt(&mut self, v: &Val, nested: bool, pos: Pos, none: &str, json: bool) -> R<Val> {
        let Type::Opt(inner) = v.ty.clone() else { unreachable!() };
        let slot = self.alloca(&Type::Str);
        let has = self.extract(v, 0, Type::Bool);
        let (ls, ln, le) = (self.lbl("some"), self.lbl("none"), self.lbl("shown"));
        self.term(format!("br i1 {}, label %{ls}, label %{ln}", has.v));
        self.label(&ls);
        let x = self.extract(v, 1, *inner);
        let s = if json { self.json(&x, pos)? } else { self.show(&x, nested, pos)? };
        self.store(&slot, &s);
        self.term(format!("br label %{le}"));
        self.label(&ln);
        let n = val(self.str_const(none), Type::Str);
        self.store(&slot, &n);
        self.label(&le);
        Ok(self.load(&slot, Type::Str))
    }

    // ---- to_json() ----

    /// Any value as JSON text. Structs become objects, enums `"Name"` (when no variant holds values)
    /// or `{"type": "Name", ...fields}`, `none` becomes `null`.
    pub(super) fn json(&mut self, v: &Val, pos: Pos) -> R<Val> {
        Ok(match &v.ty {
            Type::Int => self.rt(Type::Str, "st_itoa", &[format!("i64 {}", v.v)]),
            Type::Float => self.rt(Type::Str, "st_json_num", &[format!("double {}", v.v)]),
            Type::Bool => val(self.bool_str(&v.v), Type::Str),
            Type::Str => self.rt(Type::Str, "st_json_quote", &[format!("ptr {}", v.v)]),
            Type::Opt(_) => self.show_opt(v, false, pos, "null", true)?,
            Type::Void | Type::Result(_) | Type::Fn(..) => return err(pos, format!("can't turn {} into JSON", v.ty)),
            t => {
                let sym = format!("@\"json.{t}\"");
                if self.shown.insert(sym.clone()) {
                    let t2 = t.clone();
                    self.helper(&sym, &format!("{} %x", ll(t)), "ptr", |g| g.json_body(&t2, pos))?;
                }
                self.emit_call(&Type::Str, &sym, &[format!("{} {}", ll(&v.ty), v.v)])
            }
        })
    }

    fn json_body(&mut self, t: &Type, pos: Pos) -> R<()> {
        let x = val("%x", t.clone());
        let parts = self.new_list(&Type::Str);
        let (open, close) = match t {
            Type::List(et) | Type::Set(et) => {
                let xs = if matches!(t, Type::Set(_)) { self.map_list("%x", 0, et) } else { x.clone() };
                self.each(&xs, et, |g, e, _| {
                    let s = g.json(&e, pos)?;
                    g.push_str(&parts, &s.v);
                    Ok(())
                })?;
                ("[", "]")
            }
            Type::Map(kt, vt) => {
                let (ks, vs) = (self.map_list("%x", 0, kt), self.map_list("%x", 1, vt));
                self.each(&ks, kt, |g, k, i| {
                    let (_, d) = g.vec_parts(&vs.v);
                    let p = g.tmp();
                    g.ins(format!("{p} = getelementptr inbounds {}, ptr {d}, i64 {i}", ll(vt)));
                    let v = g.load(&p, (**vt).clone());
                    let ks = g.show(&k, false, pos)?;
                    let kq = g.rt(Type::Str, "st_json_quote", &[format!("ptr {}", ks.v)]).v;
                    let colon = g.str_const(":");
                    let kc = g.concat(&kq, &colon);
                    let vj = g.json(&v, pos)?;
                    let kv = g.concat(&kc, &vj.v);
                    g.push_str(&parts, &kv);
                    Ok(())
                })?;
                ("{", "}")
            }
            Type::Struct(k) => {
                for (f, ft) in self.structs[k].clone() {
                    let (p, _) = self.field_ptr(&x, &f, pos)?;
                    let v = self.load(&p, ft);
                    let s = self.json(&v, pos)?;
                    let label = self.str_const(&format!("\"{f}\":"));
                    let s = self.concat(&label, &s.v);
                    self.push_str(&parts, &s);
                }
                ("{", "}")
            }
            Type::Enum(k) => return self.json_enum(k, pos),
            _ => unreachable!("json() handles scalars"),
        };
        let r = self.wrap_join(&parts, ",", open, close);
        self.term(format!("ret ptr {r}"));
        Ok(())
    }

    fn json_enum(&mut self, k: &str, pos: Pos) -> R<()> {
        let x = val("%x", Type::Enum(k.into()));
        let all_unit = self.enums[k].iter().all(|v| v.fields.is_empty());
        let labels = self.switch_variants(&x, k);
        for (i, l) in labels.iter().enumerate() {
            self.label(l);
            let v = self.enums[k][i].clone();
            if all_unit {
                let s = self.str_const(&format!("\"{}\"", v.name));
                self.term(format!("ret ptr {s}"));
                continue;
            }
            let parts = self.new_list(&Type::Str);
            let tag = self.str_const(&format!("\"type\":\"{}\"", v.name));
            self.push_str(&parts, &tag);
            let mut values = vec![];
            for (j, (f, _)) in v.fields.iter().enumerate() {
                let fv = self.variant_field(&x, k, i, j);
                let s = self.json(&fv, pos)?.v;
                if v.named {
                    let label = self.str_const(&format!("\"{f}\":"));
                    let s = self.concat(&label, &s);
                    self.push_str(&parts, &s);
                } else {
                    values.push(s);
                }
            }
            match values.len() {
                0 => {}
                1 => {
                    let label = self.str_const("\"value\":");
                    let s = self.concat(&label, &values[0]);
                    self.push_str(&parts, &s);
                }
                _ => {
                    let vs = self.new_list(&Type::Str);
                    for s in &values {
                        self.push_str(&vs, s);
                    }
                    let arr = self.wrap_join(&vs, ",", "\"values\":[", "]");
                    self.push_str(&parts, &arr);
                }
            }
            let r = self.wrap_join(&parts, ",", "{", "}");
            self.term(format!("ret ptr {r}"));
        }
        Ok(())
    }
}
