//! JSX: `<div class="x">"text" {value}</div>` is an expression of type `Node`.
//!
//! An element is lowered to HTML text built in a list of string parts (static text is merged at
//! compile time and escaped once; values are escaped at run time). On the server a `Node` is that
//! HTML; in the browser (`--web`) it is the same HTML, with event handlers registered in the runtime
//! and referenced as `data-on-click="17"` attributes, which the page loader turns into real listeners.
//! Components are functions returning `Node`: `<Card title="x" />` calls `Card(title: "x")`.

use super::*;
use crate::parser::{Attr, Child, Element};

/// Elements that never have children or a closing tag.
const VOID_TAGS: &[&str] = &["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"];

pub(super) struct JsxBuf {
    parts: String, // the list of string parts being built
    text: String,  // static HTML not yet added to it
}

/// Escape text for HTML (at compile time).
fn esc(s: &str) -> String {
    let mut o = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => o.push_str("&amp;"),
            '<' => o.push_str("&lt;"),
            '>' => o.push_str("&gt;"),
            '"' => o.push_str("&quot;"),
            '\'' => o.push_str("&#39;"),
            c => o.push(c),
        }
    }
    o
}

fn is_component(tag: &str) -> bool {
    tag.rsplit('.').next().is_some_and(|t| t.starts_with(|c: char| c.is_ascii_uppercase()))
}

impl Gen {
    /// `<...>` used as a value: build its HTML and return it as a Node.
    pub(super) fn element_value(&mut self, el: &Element) -> R<Val> {
        let parts = self.new_list(&Type::Str);
        self.jsx.push(JsxBuf { parts: parts.v.clone(), text: String::new() });
        let r = self.jsx_element(el);
        if r.is_ok() {
            self.jsx_flush();
        }
        self.jsx.pop();
        r?;
        let sep = self.str_const("");
        let s = self.rt(Type::Str, "st_join", &[format!("ptr {}", parts.v), format!("ptr {sep}")]);
        Ok(val(s.v, Type::Node))
    }

    fn jsx_text(&mut self, s: &str) {
        self.jsx.last_mut().unwrap().text.push_str(s);
    }

    pub(super) fn jsx_flush(&mut self) {
        let b = self.jsx.last_mut().unwrap();
        if b.text.is_empty() {
            return;
        }
        let (t, parts) = (mem::take(&mut b.text), b.parts.clone());
        let c = self.str_const(&t);
        self.rt(Type::Void, "st_vec_push_str", &[format!("ptr {parts}"), format!("ptr {c}")]);
    }

    /// Add a run-time string (already escaped HTML) to the element being built.
    fn jsx_push(&mut self, v: &str) {
        self.jsx_flush();
        let parts = self.jsx.last().unwrap().parts.clone();
        self.rt(Type::Void, "st_vec_push_str", &[format!("ptr {parts}"), format!("ptr {v}")]);
    }

    fn escaped(&mut self, v: &Val, pos: Pos) -> R<String> {
        let s = self.show(v, false, pos)?;
        Ok(self.rt(Type::Str, "st_html_escape", &[format!("ptr {}", s.v)]).v)
    }

    fn jsx_element(&mut self, el: &Element) -> R<()> {
        if is_component(&el.tag) {
            let v = self.component(el)?;
            self.jsx_push(&v.v);
            return Ok(());
        }
        if el.tag.is_empty() {
            if !el.attrs.is_empty() {
                return err(el.pos, "a fragment `<>` can't have attributes");
            }
            return self.jsx_children(&el.children);
        }
        if !el.tag.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-') {
            return err(el.pos, format!("`<{}>`: HTML tags are lowercase; components start with a capital letter", el.tag));
        }
        self.jsx_text(&format!("<{}", el.tag));
        for a in &el.attrs {
            self.jsx_attr(a)?;
        }
        self.jsx_text(">");
        if VOID_TAGS.contains(&el.tag.as_str()) {
            if !el.children.is_empty() {
                return err(el.pos, format!("<{}> can't have children", el.tag));
            }
            return Ok(());
        }
        self.jsx_children(&el.children)?;
        self.jsx_text(&format!("</{}>", el.tag));
        Ok(())
    }

    fn jsx_attr(&mut self, a: &Attr) -> R<()> {
        let name = if a.name == "key" { "data-key" } else { a.name.as_str() };
        if name.starts_with("on") && name.len() > 2 {
            let Some(e) = &a.value else { return err(a.pos, format!("`{name}` needs a function: `{name}={{() => ...}}`")) };
            return self.handler(&name[2..], e, a.pos);
        }
        let Some(e) = &a.value else {
            self.jsx_text(&format!(" {name}"));
            return Ok(());
        };
        if let ExprKind::Str(s) = &e.kind {
            self.jsx_text(&format!(" {name}=\"{}\"", esc(s)));
            return Ok(());
        }
        let v = self.expr(e, None)?;
        self.attr_value(name, v, e.pos)
    }

    fn attr_value(&mut self, name: &str, v: Val, pos: Pos) -> R<()> {
        match v.ty.clone() {
            Type::Bool => {
                // `disabled={busy}`: there or not
                self.jsx_flush();
                let (on, off) = (self.str_const(&format!(" {name}")), self.str_const(""));
                let t = self.tmp();
                self.ins(format!("{t} = select i1 {}, ptr {on}, ptr {off}", v.v));
                self.jsx_push(&t);
            }
            Type::Str | Type::Int | Type::Float | Type::Node => {
                let s = self.escaped(&v, pos)?;
                self.jsx_text(&format!(" {name}=\""));
                self.jsx_push(&s);
                self.jsx_text("\"");
            }
            Type::Opt(t) => {
                // `title={maybe}`: left out when none
                self.jsx_flush();
                let has = self.extract(&v, 0, Type::Bool);
                let (ls, le) = (self.lbl("attr"), self.lbl("noattr"));
                self.term(format!("br i1 {}, label %{ls}, label %{le}", has.v));
                self.label(&ls);
                let x = self.extract(&v, 1, *t);
                self.attr_value(name, x, pos)?;
                self.jsx_flush();
                self.label(&le);
            }
            t => return err(pos, format!("attribute `{name}` can't be {t} (use a str, number or bool)")),
        }
        Ok(())
    }

    /// `onclick={() => ...}` / `oninput={value => ...}`: a fn() or a fn(str) taking the input's value
    /// (or the key, for key events).
    fn handler(&mut self, event: &str, e: &Expr, pos: Pos) -> R<()> {
        let event = event.trim_start_matches('_').to_lowercase();
        let arity = match &e.kind {
            ExprKind::Lambda(l) => l.params.len(),
            _ => usize::from(matches!(self.probe(e, None)?, Type::Fn(ref ps, _) if ps.len() == 1)),
        };
        let want = Type::Fn(if arity == 1 { vec![Type::Str] } else { vec![] }, Box::new(Type::Void));
        let f = self.expr(e, Some(&want))?;
        if f.ty != want {
            return err(pos, format!("an event handler is a fn() or a fn(str) (the input's value), not {}", f.ty));
        }
        if self.web || self.kernel {
            let id = self.rt(Type::Int, "st_on", &[format!("ptr {}", f.v), format!("i64 {arity}")]);
            let s = self.rt(Type::Str, "st_itoa", &[format!("i64 {}", id.v)]);
            self.jsx_text(&format!(" data-on-{event}=\""));
            self.jsx_push(&s.v);
            self.jsx_text("\"");
        }
        Ok(())
    }

    pub(super) fn jsx_children(&mut self, cs: &[Child]) -> R<()> {
        for c in cs {
            match c {
                Child::Text(e) => match &e.kind {
                    ExprKind::Str(s) => self.jsx_text(&esc(s)),
                    _ => {
                        let v = self.typed(e, &Type::Str)?;
                        let h = self.escaped(&v, e.pos)?;
                        self.jsx_push(&h);
                    }
                },
                Child::Value(e) => {
                    let v = self.expr(e, None)?;
                    self.jsx_value(v, e.pos)?;
                }
                Child::Elem(el) => self.jsx_element(el)?,
                Child::For(s) | Child::If(s) => {
                    self.jsx_flush();
                    self.stmt(s)?;
                }
            }
        }
        Ok(())
    }

    /// `{value}` inside an element.
    fn jsx_value(&mut self, v: Val, pos: Pos) -> R<()> {
        match v.ty.clone() {
            Type::Node => self.jsx_push(&v.v),
            Type::Void => return err(pos, "this has no value to show"),
            Type::Result(_) => return err(pos, "this is a result; handle the error first (`?`, `catch`)"),
            Type::Opt(t) => {
                self.jsx_flush();
                let has = self.extract(&v, 0, Type::Bool);
                let (ls, le) = (self.lbl("some"), self.lbl("none"));
                self.term(format!("br i1 {}, label %{ls}, label %{le}", has.v));
                self.label(&ls);
                let x = self.extract(&v, 1, *t);
                self.jsx_value(x, pos)?;
                self.jsx_flush();
                self.label(&le);
            }
            Type::List(et) if *et == Type::Node => {
                let sep = self.str_const("");
                let s = self.rt(Type::Str, "st_join", &[format!("ptr {}", v.v), format!("ptr {sep}")]);
                self.jsx_push(&s.v);
            }
            Type::List(et) => {
                self.jsx_flush();
                self.each(&v, &et, |g, x, _| {
                    g.jsx_value(x, pos)?;
                    g.jsx_flush();
                    Ok(())
                })?;
            }
            _ => {
                let h = self.escaped(&v, pos)?;
                self.jsx_push(&h);
            }
        }
        Ok(())
    }

    /// `<Card title="x">children</Card>`: call `Card`, matching attributes to parameters by name
    /// (or to the fields of its one struct parameter). Children go to a `children: Node` parameter.
    fn component(&mut self, el: &Element) -> R<Val> {
        let key = match el.tag.split_once('.') {
            Some((m, n)) if self.is_module(m) => format!("{m}.{n}"),
            Some((m, _)) => return err(el.pos, format!("unknown module `{m}` (add `import {m}`)")),
            None => self.key(&el.tag),
        };
        let Some(sig) = self.funcs.get(&key).cloned() else {
            return err(el.pos, format!("unknown component `{}` (write `fn {}(...) -> Node`)", el.tag, el.tag));
        };
        if sig.ret != Type::Node {
            return err(el.pos, format!("`{}` returns {}, so it isn't a component (components return Node)", el.tag, sig.ret));
        }
        self.note(el.pos, sig_text(&el.tag, &sig));
        let children = (!el.children.is_empty()).then(|| Expr {
            kind: ExprKind::Element(Box::new(Element { tag: String::new(), attrs: vec![], children: el.children.clone(), pos: el.pos })),
            pos: el.pos,
        });
        // the attributes as `name: value` (a bare attribute is `true`)
        let mut given: Vec<(String, Expr)> = el
            .attrs
            .iter()
            .map(|a| (a.name.clone(), a.value.clone().unwrap_or(Expr { kind: ExprKind::Bool(true), pos: a.pos })))
            .collect();
        if let Some(c) = &children {
            given.push(("children".into(), c.clone()));
        }
        let props_struct = match sig.params.as_slice() {
            [Type::Struct(sk)] if !given.iter().any(|g| g.0 == sig.names[0]) => Some(sk.clone()),
            _ => None,
        };
        let mut argl = vec![];
        if let Some(sk) = props_struct {
            let decl = self.structs[&sk].clone();
            let vals = self.fill(&el.tag, &sk, &decl, Some(&given), None, el.pos)?;
            let obj = self.build(&format!("%\"S.{sk}\""), None, &vals);
            argl.push(format!("ptr {obj}"));
        } else {
            for (n, _) in &given {
                if !sig.names.contains(n) {
                    return err(el.pos, format!("<{}> has no prop `{n}` (it takes {})", el.tag, sig.names.join(", ")));
                }
            }
            for (i, (n, t)) in sig.names.iter().zip(&sig.params).enumerate() {
                let v = match given.iter().find(|g| g.0 == *n) {
                    Some((_, e)) => self.typed(e, t)?,
                    None if sig.defaults.get(i).is_some_and(Option::is_some) => {
                        let e = sig.defaults[i].clone().unwrap();
                        self.call_default(&default_sym(&sig.sym, i), &e, &sig.module, t)?
                    }
                    None if matches!(t, Type::Opt(_)) => val("zeroinitializer", t.clone()),
                    None if n == "children" && *t == Type::Node => val(self.str_const(""), Type::Node),
                    None => return err(el.pos, format!("<{}> needs `{n}` ({t})", el.tag)),
                };
                argl.push(format!("{} {}", ll(t), v.v));
            }
        }
        Ok(self.emit_call(&Type::Node, &sig.sym, &argl))
    }
}
