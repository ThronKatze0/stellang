//! `from_json(text)`: JSON text into the type the code expects (`let t: Todo = from_json(body)?`),
//! the reverse of `to_json`: structs from objects (missing fields take their defaults; optional ones
//! become none), enums from "Name" or {"type": "Name", ...}, lists, sets, maps, optionals, scalars.
//! It parses with std/json.st, so it needs `import json`.

use super::*;

const JSON: &str = "json.Json";

impl Gen {
    pub(super) fn from_json(&mut self, args: &[Expr], pos: Pos, want: Option<&Type>) -> R<Val> {
        let [a] = args else { return err(pos, format!("`from_json` takes 1 argument, got {}", args.len())) };
        if !self.enums.contains_key(JSON) {
            return err(pos, "`from_json` needs `import json`");
        }
        let t = match want {
            Some(Type::Result(t)) => (**t).clone(),
            Some(t) if *t != Type::Void => t.clone(),
            _ => return err(pos, "can't tell what to decode the JSON into; write `let x: Todo = from_json(text)?`"),
        };
        let s = self.typed(a, &Type::Str)?;
        let parse = self.funcs["json.parse"].clone();
        let parsed = self.emit_call(&parse.ret, &parse.sym, &[format!("ptr {}", s.v)]);
        let rt = Type::Result(Box::new(t.clone()));
        let slot = self.alloca(&rt);
        let failed = self.extract(&parsed, 0, Type::Bool);
        let (lbad, lgood, lend) = (self.lbl("badjson"), self.lbl("json"), self.lbl("decoded"));
        self.term(format!("br i1 {}, label %{lbad}, label %{lgood}", failed.v));
        self.label(&lbad);
        let msg = self.extract(&parsed, 2, Type::Str);
        let e = self.err_of(&t, &msg.v);
        self.store(&slot, &e);
        self.term(format!("br label %{lend}"));
        self.label(&lgood);
        let j = self.extract(&parsed, 1, Type::Enum(JSON.into()));
        let sym = self.decoder(&t, pos)?;
        let r = self.emit_call(&rt, &sym, &[format!("ptr {}", j.v)]);
        self.store(&slot, &r);
        self.label(&lend);
        Ok(self.load(&slot, rt))
    }

    /// `@"fromjson.T"(json.Json) -> T!`, emitted once per type.
    fn decoder(&mut self, t: &Type, pos: Pos) -> R<String> {
        let sym = format!("@\"fromjson.{t}\"");
        if !self.shown.insert(sym.clone()) {
            return Ok(sym);
        }
        let rt = Type::Result(Box::new(t.clone()));
        let saved = mem::take(&mut self.f);
        self.f.open = true;
        self.f.cur = "entry".into();
        self.f.scopes = vec![HashMap::new()];
        self.f.ret = rt.clone();
        let j = val("%j", Type::Enum(JSON.into()));
        let r = self.decode_body(t, &j, pos);
        let f = mem::replace(&mut self.f, saved);
        r?;
        write!(self.code, "define internal {} {sym}(ptr %j) {{\nentry:\n{}\n{}\n}}\n\n", ll(&rt), f.allocas.join("\n"), f.body.join("\n")).unwrap();
        Ok(sym)
    }

    /// Return an error from the decoder being generated.
    fn json_fail(&mut self, msg: &str) {
        let Type::Result(t) = self.f.ret.clone() else { unreachable!() };
        let m = self.str_const(&format!("from_json: {msg}"));
        let e = self.err_of(&t, &m);
        self.term(format!("ret {} {}", ll(&self.f.ret), e.v));
    }

    /// Continue only if `j` is the Json variant `name`; returns its payload.
    fn json_expect(&mut self, j: &Val, name: &str, payload: Option<Type>, what: &str) -> R<Option<Val>> {
        let i = self.variant_index(JSON, name, Pos { line: 1, col: 1 })?;
        let (tag, ok) = (self.tmp(), self.tmp());
        self.ins(format!("{tag} = load i64, ptr {}", j.v));
        self.ins(format!("{ok} = icmp eq i64 {tag}, {i}"));
        let (lbad, lgood) = (self.lbl("notjson"), self.lbl("isjson"));
        self.term(format!("br i1 {ok}, label %{lgood}, label %{lbad}"));
        self.label(&lbad);
        self.json_fail(&format!("expected {what}"));
        self.label(&lgood);
        Ok(payload.map(|_| self.variant_field(j, JSON, i, 0)))
    }

    fn is_json(&mut self, j: &Val, name: &str) -> R<String> {
        let i = self.variant_index(JSON, name, Pos { line: 1, col: 1 })?;
        let (tag, ok) = (self.tmp(), self.tmp());
        self.ins(format!("{tag} = load i64, ptr {}", j.v));
        self.ins(format!("{ok} = icmp eq i64 {tag}, {i}"));
        Ok(ok)
    }

    /// Decode `j` as a `t` inside the current decoder (errors return from it).
    fn json_value(&mut self, t: &Type, j: &Val, pos: Pos) -> R<Val> {
        Ok(match t {
            Type::Int => {
                let n = self.json_expect(j, "Num", Some(Type::Float), "a number")?.unwrap();
                self.emit_call(&Type::Int, "@llvm.fptosi.sat.i64.f64", &[format!("double {}", n.v)])
            }
            Type::Float => self.json_expect(j, "Num", Some(Type::Float), "a number")?.unwrap(),
            Type::Bool => self.json_expect(j, "Bool", Some(Type::Bool), "true or false")?.unwrap(),
            Type::Str => self.json_expect(j, "Str", Some(Type::Str), "a string")?.unwrap(),
            Type::Opt(inner) => {
                let slot = self.alloca(t);
                self.ins(format!("store {} zeroinitializer, ptr {slot}", ll(t)));
                let null = self.is_json(j, "Null")?;
                let (lsome, lend) = (self.lbl("jsome"), self.lbl("jopt"));
                self.term(format!("br i1 {null}, label %{lend}, label %{lsome}"));
                self.label(&lsome);
                let v = self.json_value(inner, j, pos)?;
                let s = self.some_of(&v);
                self.store(&slot, &s);
                self.label(&lend);
                self.load(&slot, t.clone())
            }
            Type::List(_) | Type::Set(_) | Type::Map(..) | Type::Struct(_) | Type::Enum(_) => {
                let sym = self.decoder(t, pos)?;
                let rt = Type::Result(Box::new(t.clone()));
                let r = self.emit_call(&rt, &sym, &[format!("ptr {}", j.v)]);
                let failed = self.extract(&r, 0, Type::Bool);
                let (lbad, lok) = (self.lbl("jerr"), self.lbl("jok"));
                self.term(format!("br i1 {}, label %{lbad}, label %{lok}", failed.v));
                self.label(&lbad);
                let m = self.extract(&r, 2, Type::Str);
                let Type::Result(outer) = self.f.ret.clone() else { unreachable!() };
                let e = self.err_of(&outer, &m.v);
                self.term(format!("ret {} {}", ll(&self.f.ret), e.v));
                self.label(&lok);
                self.extract(&r, 1, t.clone())
            }
            _ => return err(pos, format!("from_json can't make a {t}")),
        })
    }

    fn decode_body(&mut self, t: &Type, j: &Val, pos: Pos) -> R<()> {
        let jt = Type::Enum(JSON.into());
        let v = match t {
            Type::List(et) | Type::Set(et) => {
                let items = self.json_expect(j, "Arr", Some(Type::List(Box::new(jt.clone()))), "an array")?.unwrap();
                let out = if matches!(t, Type::Set(_)) { val(self.map_new(et), t.clone()) } else { self.new_list(et) };
                self.each(&items, &jt, |g, x, _| {
                    let v = g.json_value(et, &x, pos)?;
                    if matches!(t, Type::Set(_)) {
                        g.map_set(&out.v, &v, None);
                    } else {
                        g.push(&out.v, &v);
                    }
                    Ok(())
                })?;
                out
            }
            Type::Map(kt, vt) => {
                let m = self.json_expect(j, "Obj", Some(Type::Map(Box::new(Type::Str), Box::new(jt.clone()))), "an object")?.unwrap();
                let (ks, vs) = (self.map_list(&m.v, 0, &Type::Str), self.map_list(&m.v, 1, &jt));
                let out = self.map_new(kt);
                self.each(&ks, &Type::Str, |g, k, i| {
                    let (_, d) = g.vec_parts(&vs.v);
                    let p = g.tmp();
                    g.ins(format!("{p} = getelementptr inbounds ptr, ptr {d}, i64 {i}"));
                    let x = g.load(&p, jt.clone());
                    let key = match **kt {
                        Type::Str => k,
                        Type::Int => {
                            let n = g.alloca(&Type::Int);
                            let e = g.rt(Type::Str, "st_parse_int", &[format!("ptr {}", k.v), format!("ptr {n}")]).v;
                            let bad = g.tmp();
                            g.ins(format!("{bad} = icmp ne ptr {e}, null"));
                            let (lb, lg) = (g.lbl("badkey"), g.lbl("key"));
                            g.term(format!("br i1 {bad}, label %{lb}, label %{lg}"));
                            g.label(&lb);
                            g.json_fail("expected number keys");
                            g.label(&lg);
                            g.load(&n, Type::Int)
                        }
                        _ => {
                            let tr = g.str_const("true");
                            let b = g.rt(Type::Bool, "st_streq", &[format!("ptr {}", k.v), format!("ptr {tr}")]);
                            b
                        }
                    };
                    let v = g.json_value(vt, &x, pos)?;
                    g.map_set(&out, &key, Some(&v));
                    Ok(())
                })?;
                val(out, t.clone())
            }
            Type::Struct(k) => {
                let m = self.json_expect(j, "Obj", Some(Type::Map(Box::new(Type::Str), Box::new(jt.clone()))), &format!("an object for {}", short_name(k)))?.unwrap();
                let fields = self.structs[k].clone();
                let vals = self.json_fields(&m, k, &fields, short_name(k), pos)?;
                let obj = self.build(&format!("%\"S.{k}\""), None, &vals);
                val(obj, t.clone())
            }
            Type::Enum(k) => return self.decode_enum(k, j, pos),
            _ => self.json_value(t, j, pos)?,
        };
        let r = self.ok_of(t, &v);
        self.term(format!("ret {} {}", ll(&self.f.ret), r.v));
        Ok(())
    }

    /// The fields of a struct (or a variant with named fields) from object `m`.
    fn json_fields(&mut self, m: &Val, dkey: &str, fields: &[(String, Type)], what: &str, pos: Pos) -> R<Vec<Val>> {
        let jt = Type::Enum(JSON.into());
        let mut vals = vec![];
        for (f, ft) in fields {
            let key = val(self.str_const(f), Type::Str);
            let (found, x) = self.map_get(&m.v, &key, &jt);
            let slot = self.alloca(ft);
            let (lhas, lmiss, lend) = (self.lbl("field"), self.lbl("nofield"), self.lbl("gotfield"));
            self.term(format!("br i1 {found}, label %{lhas}, label %{lmiss}"));
            self.label(&lhas);
            let v = self.json_value(ft, &x, pos)?;
            self.store(&slot, &v);
            self.term(format!("br label %{lend}"));
            self.label(&lmiss);
            match self.default_of(dkey, f, ft)? {
                Some(d) => self.store(&slot, &d),
                None if matches!(ft, Type::Opt(_)) => self.ins(format!("store {} zeroinitializer, ptr {slot}", ll(ft))),
                None => self.json_fail(&format!("missing field `{f}` in {what}")),
            }
            self.label(&lend);
            vals.push(self.load(&slot, ft.clone()));
        }
        Ok(vals)
    }

    fn decode_enum(&mut self, k: &str, j: &Val, pos: Pos) -> R<()> {
        let jt = Type::Enum(JSON.into());
        let vs = self.enums[k].clone();
        let all_unit = vs.iter().all(|v| v.fields.is_empty());
        let et = Type::Enum(k.into());
        let short = short_name(k).to_string();
        let name = if all_unit {
            self.json_expect(j, "Str", Some(Type::Str), &format!("a {short} name"))?.unwrap()
        } else {
            let m = self.json_expect(j, "Obj", Some(Type::Map(Box::new(Type::Str), Box::new(jt.clone()))), &format!("an object for {short}"))?.unwrap();
            let key = val(self.str_const("type"), Type::Str);
            let (found, x) = self.map_get(&m.v, &key, &jt);
            let (lhas, lmiss) = (self.lbl("type"), self.lbl("notype"));
            self.term(format!("br i1 {found}, label %{lhas}, label %{lmiss}"));
            self.label(&lmiss);
            self.json_fail(&format!("missing \"type\" in {short}"));
            self.label(&lhas);
            self.json_expect(&x, "Str", Some(Type::Str), "a string \"type\"")?.unwrap()
        };
        for (i, v) in vs.iter().enumerate() {
            let s = self.str_const(&v.name);
            let hit = self.rt(Type::Bool, "st_streq", &[format!("ptr {}", name.v), format!("ptr {s}")]);
            let (lyes, lno) = (self.lbl("variant"), self.lbl("other"));
            self.term(format!("br i1 {}, label %{lyes}, label %{lno}", hit.v));
            self.label(&lyes);
            let value = if v.fields.is_empty() {
                val(format!("@\"U.{k}.{}\"", v.name), et.clone())
            } else {
                // {"type": "Circle", "value": 2.0} / "values": [...] / named fields
                let Some(m) = self.json_expect(j, "Obj", Some(Type::Map(Box::new(Type::Str), Box::new(jt.clone()))), "an object")? else { unreachable!() };
                let vals = if v.named {
                    self.json_fields(&m, &format!("{k}::{}", v.name), &v.fields, &v.name, pos)?
                } else if v.fields.len() == 1 {
                    let key = val(self.str_const("value"), Type::Str);
                    let (found, x) = self.map_get(&m.v, &key, &jt);
                    let (lhas, lmiss) = (self.lbl("val"), self.lbl("noval"));
                    self.term(format!("br i1 {found}, label %{lhas}, label %{lmiss}"));
                    self.label(&lmiss);
                    self.json_fail(&format!("missing \"value\" in {}", v.name));
                    self.label(&lhas);
                    vec![self.json_value(&v.fields[0].1, &x, pos)?]
                } else {
                    let key = val(self.str_const("values"), Type::Str);
                    let (found, x) = self.map_get(&m.v, &key, &jt);
                    let (lhas, lmiss) = (self.lbl("vals"), self.lbl("novals"));
                    self.term(format!("br i1 {found}, label %{lhas}, label %{lmiss}"));
                    self.label(&lmiss);
                    self.json_fail(&format!("missing \"values\" in {}", v.name));
                    self.label(&lhas);
                    let items = self.json_expect(&x, "Arr", Some(Type::List(Box::new(jt.clone()))), "an array of values")?.unwrap();
                    let (len, d) = self.vec_parts(&items.v);
                    let short_ = self.tmp();
                    self.ins(format!("{short_} = icmp slt i64 {len}, {}", v.fields.len()));
                    let (lb, lg) = (self.lbl("few"), self.lbl("enough"));
                    self.term(format!("br i1 {short_}, label %{lb}, label %{lg}"));
                    self.label(&lb);
                    self.json_fail(&format!("too few values for {}", v.name));
                    self.label(&lg);
                    let mut out = vec![];
                    for (n, (_, ft)) in v.fields.iter().enumerate() {
                        let p = self.tmp();
                        self.ins(format!("{p} = getelementptr inbounds ptr, ptr {d}, i64 {n}"));
                        let x = self.load(&p, jt.clone());
                        out.push(self.json_value(ft, &x, pos)?);
                    }
                    out
                };
                val(self.build(&format!("%\"V.{k}.{}\"", v.name), Some(i), &vals), et.clone())
            };
            let r = self.ok_of(&et, &value);
            self.term(format!("ret {} {}", ll(&self.f.ret), r.v));
            self.label(&lno);
        }
        self.json_fail(&format!("unknown {short} variant"));
        Ok(())
    }
}
