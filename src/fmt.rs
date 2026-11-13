//! `stellang fmt`: re-indent, and optionally swap keywords to their emoji twins or back.
//! Works on tokens, so comments and line layout survive.

use crate::lexer::{continues_before, lex, Error, Tok, Token, EMOJI};
use crate::parser::parse;
use std::collections::{HashMap, HashSet};

fn braces(toks: &[Token]) -> Result<HashMap<usize, bool>, Error> {
    Ok(parse(toks.to_vec())?.braces.into_iter().collect())
}

/// `to_emoji`: Some(true) = emoji, Some(false) = plain keywords, None = keep spelling.
pub fn format(src: &str, to_emoji: Option<bool>) -> Result<String, Error> {
    let src = match to_emoji {
        Some(e) => convert(src, e)?,
        None => src.to_string(),
    };
    reindent(&src)
}

fn convert(src: &str, to_emoji: bool) -> Result<String, Error> {
    let toks = lex(src)?;
    let braces = braces(&toks)?;
    let cs: Vec<char> = src.chars().collect();
    let (mut out, mut last) = (String::new(), 0);
    for (k, t) in toks.iter().enumerate() {
        let rep = match &t.tok {
            Tok::Star | Tok::LBrace | Tok::RBrace => {
                let opens = braces.get(&k).copied().unwrap_or(t.tok != Tok::RBrace);
                if to_emoji { "⭐" } else if opens { "{" } else { "}" }
            }
            tok => match EMOJI.iter().find(|kw| kw.0 == *tok) {
                Some(kw) if to_emoji => kw.1,
                Some(kw) => kw.2,
                None => continue,
            },
        };
        out.extend(&cs[last..t.start]);
        let word = rep.chars().all(|c| c.is_ascii_alphabetic());
        if word && out.ends_with(|c: char| c.is_ascii_alphanumeric() || c == '_') {
            out.push(' ');
        }
        out += rep;
        if word && cs.get(t.end).is_some_and(|&c| c.is_ascii_alphanumeric() || c == '_') {
            out.push(' ');
        }
        last = t.end;
    }
    out.extend(&cs[last..]);
    Ok(out)
}

/// Four spaces per open block; lines that continue the previous one (`.method()`, `+ x`) get one more.
fn reindent(src: &str) -> Result<String, Error> {
    let toks = lex(src)?;
    let braces = braces(&toks)?;
    let closes: HashSet<usize> = braces.iter().filter(|b| !*b.1).map(|b| *b.0).collect();
    let mut delta: HashMap<u32, i32> = HashMap::new();
    for (&k, &opens) in &braces {
        *delta.entry(toks[k].pos.line).or_default() += if opens { 1 } else { -1 };
    }
    let mut first: HashMap<u32, usize> = HashMap::new();
    for (k, t) in toks.iter().enumerate() {
        if t.tok != Tok::Newline {
            first.entry(t.pos.line).or_insert(k);
        }
    }
    let (mut out, mut depth) = (String::new(), 0);
    for (n, line) in src.lines().enumerate() {
        let n = n as u32 + 1;
        let mut d = depth;
        if let Some(&k) = first.get(&n) {
            if closes.contains(&k) {
                d -= 1;
            }
            if continues_before(&toks[k].tok) && !matches!(toks[k].tok, Tok::Else | Tok::Catch) {
                d += 1;
            }
        }
        let line = line.trim();
        if !line.is_empty() {
            out += &"    ".repeat(d.max(0) as usize);
            out += line;
        }
        out.push('\n');
        depth += delta.get(&n).copied().unwrap_or(0);
    }
    Ok(out)
}
