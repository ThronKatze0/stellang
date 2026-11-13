use std::fmt;

#[derive(Debug, Clone, PartialEq)]
pub enum Tok {
    // keywords
    Fn, Struct, Enum, Trait, Const, Impl, Extern, Import, Let, Var, If, Else, While, For, In, Return, Break, Continue, Match, Catch,
    Star, // ⭐ (emoji twin of `{` and `}`; the parser knows which)
    Ident(String), Int(i64), Float(f64), Str(String),
    Interp(Vec<Part>), // a string with `${...}` in it
    LParen, RParen, LBrace, RBrace, LBrack, RBrack, Comma, Colon, Semi, Dot, DotDot,
    Arrow, FatArrow, Question, QuestionQuestion, Bang, Pipe,
    Amp, Caret, Tilde, Shl, Shr, // bitwise (`>>` is two `>` the parser joins, so `Box<Box<int>>` still closes)
    Assign, PlusEq, MinusEq, TimesEq, SlashEq,
    Plus, Minus, Times, Slash, Percent, Eq, Ne, Lt, Le, Gt, Ge, AndAnd, OrOr,
    Newline,
    Eof,
}

/// A piece of an interpolated string: text, or the tokens of a `${...}` expression.
#[derive(Debug, Clone, PartialEq)]
pub enum Part {
    Lit(String),
    Code(Vec<Token>, Pos),
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Pos {
    pub line: u32,
    pub col: u32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Token {
    pub tok: Tok,
    pub pos: Pos,
    pub start: usize, // char offsets into the source
    pub end: usize,
}

pub type Error = (Pos, String);

pub const WORDS: [(&str, Tok); 20] = [
    ("fn", Tok::Fn), ("struct", Tok::Struct), ("enum", Tok::Enum), ("trait", Tok::Trait), ("const", Tok::Const), ("impl", Tok::Impl), ("extern", Tok::Extern),
    ("import", Tok::Import), ("let", Tok::Let), ("var", Tok::Var), ("if", Tok::If), ("else", Tok::Else),
    ("while", Tok::While), ("for", Tok::For), ("in", Tok::In), ("return", Tok::Return),
    ("break", Tok::Break), ("continue", Tok::Continue), ("match", Tok::Match), ("catch", Tok::Catch),
];

/// The emoji joke: each of these is an alternative spelling of a keyword. ⭐ is both `{` and `}`.
pub const EMOJI: [(Tok, &str, &str); 10] = [
    (Tok::Fn, "🦍", "fn"),
    (Tok::Struct, "🦧", "struct"),
    (Tok::If, "🦅", "if"),
    (Tok::Else, "🐒", "else"),
    (Tok::While, "🐭", "while"),
    (Tok::Let, "🦦", "let"),
    (Tok::Var, "🦁", "var"),
    (Tok::Return, "🐺", "return"),
    (Tok::Break, "🦭", "break"),
    (Tok::Semi, "❤️", ";"),
];

impl fmt::Display for Tok {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        if let Some((w, _)) = WORDS.iter().find(|w| w.1 == *self) {
            return write!(f, "`{w}`");
        }
        let s = match self {
            Tok::Ident(s) => return write!(f, "`{s}`"),
            Tok::Int(n) => return write!(f, "`{n}`"),
            Tok::Float(n) => return write!(f, "`{n}`"),
            Tok::Interp(_) => return write!(f, "a string"),
            Tok::Str(s) => return write!(f, "{s:?}"),
            Tok::Newline => return write!(f, "end of line"),
            Tok::Eof => return write!(f, "end of file"),
            Tok::Star => "⭐",
            Tok::LParen => "(", Tok::RParen => ")", Tok::LBrace => "{", Tok::RBrace => "}",
            Tok::LBrack => "[", Tok::RBrack => "]", Tok::Comma => ",", Tok::Colon => ":", Tok::Semi => ";",
            Tok::Dot => ".", Tok::DotDot => "..", Tok::Arrow => "->", Tok::FatArrow => "=>",
            Tok::Question => "?", Tok::QuestionQuestion => "??", Tok::Pipe => "|", Tok::Bang => "!", Tok::Assign => "=", Tok::PlusEq => "+=",
            Tok::MinusEq => "-=", Tok::TimesEq => "*=", Tok::SlashEq => "/=",
            Tok::Plus => "+", Tok::Minus => "-", Tok::Times => "*", Tok::Slash => "/", Tok::Percent => "%",
            Tok::Eq => "==", Tok::Ne => "!=", Tok::Lt => "<", Tok::Le => "<=", Tok::Gt => ">", Tok::Ge => ">=",
            Tok::AndAnd => "&&", Tok::OrOr => "||",
            Tok::Amp => "&", Tok::Caret => "^", Tok::Tilde => "~", Tok::Shl => "<<", Tok::Shr => ">>",
            _ => unreachable!("keywords handled above"),
        };
        write!(f, "`{s}`")
    }
}

/// A line ending in one of these continues on the next line.
fn continues_after(t: &Tok) -> bool {
    use Tok::*;
    matches!(
        t,
        Plus | Minus | Times | Slash | Percent | Eq | Ne | Lt | Le | Gt | Ge | AndAnd | OrOr | Bang | Comma
            | LParen | LBrack | Dot | DotDot | Colon | Arrow | FatArrow | Assign | PlusEq | MinusEq | TimesEq
            | SlashEq | Catch | Pipe | QuestionQuestion | Amp | Caret | Shl
    )
}

/// A line starting with one of these continues the previous line.
pub fn continues_before(t: &Tok) -> bool {
    use Tok::*;
    matches!(t, Plus | Times | Slash | Percent | Eq | Ne | Lt | Le | Gt | Ge | AndAnd | OrOr | Dot | Else | Catch | Pipe | QuestionQuestion)
}

/// Position `p` inside a `${...}` snippet, moved to where the snippet sits in the file.
fn shift(p: Pos, base: Pos) -> Pos {
    Pos { line: p.line + base.line - 1, col: if p.line == 1 { p.col + base.col - 1 } else { p.col } }
}

/// Index of the `}` closing a `${` whose code starts at `i` (skips nested braces and strings).
fn interp_end(cs: &[char], mut i: usize) -> Option<usize> {
    let mut depth = 0;
    while let Some(&c) = cs.get(i) {
        match c {
            '\n' => return None,
            '{' => depth += 1,
            '}' if depth == 0 => return Some(i),
            '}' => depth -= 1,
            '"' => {
                i += 1;
                while *cs.get(i)? != '"' {
                    i += if cs[i] == '\\' { 2 } else { 1 };
                }
            }
            _ => {}
        }
        i += 1;
    }
    None
}

pub fn lex(src: &str) -> Result<Vec<Token>, Error> {
    let cs: Vec<char> = src.chars().collect();
    let mut ps = Vec::with_capacity(cs.len() + 1);
    let (mut line, mut col) = (1, 1);
    for &c in &cs {
        ps.push(Pos { line, col });
        if c == '\n' { line += 1; col = 1 } else { col += 1 }
    }
    ps.push(Pos { line, col });

    let mut out: Vec<Token> = Vec::new();
    let mut i = 0;
    while i < cs.len() {
        let (c, pos) = (cs[i], ps[i]);
        let next = cs.get(i + 1).copied().unwrap_or('\0');
        let start = i;
        if c == '\n' {
            i += 1;
            out.push(Token { tok: Tok::Newline, pos, start, end: i });
            continue;
        }
        if c.is_whitespace() || c == '\u{FE0F}' {
            i += 1;
            continue;
        }
        if c == '/' && next == '/' {
            while i < cs.len() && cs[i] != '\n' { i += 1 }
            continue;
        }
        let emoji = if c == '⭐' { Some(Tok::Star) } else { EMOJI.iter().find(|k| k.1.starts_with(c)).map(|k| k.0.clone()) };
        let tok = if let Some(t) = emoji {
            i += 1;
            if cs.get(i) == Some(&'\u{FE0F}') { i += 1 } // ❤️ = ❤ + variation selector
            t
        } else if c == '0' && matches!(next, 'x' | 'X' | 'b' | 'B' | 'o' | 'O') {
            // 0xFF, 0b1010, 0o755 (with `_` anywhere); up to 64 bits, so 0xFFFF_FFFF_FFFF_FFFF is -1
            let radix = match next { 'x' | 'X' => 16, 'b' | 'B' => 2, _ => 8 };
            i += 2;
            let from = i;
            while i < cs.len() && (cs[i].is_ascii_alphanumeric() || cs[i] == '_') { i += 1 }
            let s: String = cs[from..i].iter().filter(|&&c| c != '_').collect();
            match u64::from_str_radix(&s, radix) {
                Ok(n) => Tok::Int(n as i64),
                Err(_) if s.is_empty() => return Err((pos, "expected digits after the number prefix".into())),
                Err(_) => {
                    let all: String = cs[start..i].iter().collect();
                    let bad = s.chars().any(|c| !c.is_digit(radix));
                    return Err((pos, if bad { format!("{all} is not a valid base-{radix} number") } else { format!("number {all} is too large (64 bits at most)") }));
                }
            }
        } else if c.is_ascii_digit() {
            let digits = |i: &mut usize| while *i < cs.len() && (cs[*i].is_ascii_digit() || cs[*i] == '_') { *i += 1 };
            digits(&mut i);
            let mut float = false;
            if cs.get(i) == Some(&'.') && cs.get(i + 1).is_some_and(|c| c.is_ascii_digit()) {
                i += 1; // `1.5`, but not `0..10`
                digits(&mut i);
                float = true;
            }
            if matches!(cs.get(i), Some('e' | 'E')) {
                let k = i + 1 + matches!(cs.get(i + 1), Some('+' | '-')) as usize;
                if cs.get(k).is_some_and(|c| c.is_ascii_digit()) {
                    i = k;
                    digits(&mut i);
                    float = true;
                }
            }
            let s: String = cs[start..i].iter().filter(|&&c| c != '_').collect();
            if float {
                Tok::Float(s.parse().unwrap())
            } else {
                Tok::Int(s.parse().map_err(|_| (pos, format!("number {s} is too large")))?)
            }
        } else if c.is_ascii_alphabetic() || c == '_' {
            while i < cs.len() && (cs[i].is_ascii_alphanumeric() || cs[i] == '_') { i += 1 }
            let s: String = cs[start..i].iter().collect();
            WORDS.iter().find(|w| w.0 == s).map_or(Tok::Ident(s), |w| w.1.clone())
        } else if c == '"' {
            // """ ... """: a string over several lines (the line break right after the opening quotes isn't part of it)
            let triple = cs.get(i + 1) == Some(&'"') && cs.get(i + 2) == Some(&'"');
            i += if triple { 3 } else { 1 };
            if triple && cs.get(i) == Some(&'\n') {
                i += 1;
            }
            let mut s = String::new();
            let mut parts = vec![];
            loop {
                match cs.get(i) {
                    None => return Err((pos, "unterminated string".into())),
                    Some('\n') if !triple => return Err((pos, "unterminated string (for several lines, use \"\"\"...\"\"\")".into())),
                    Some('"') if triple => {
                        if cs.get(i + 1) == Some(&'"') && cs.get(i + 2) == Some(&'"') {
                            i += 3;
                            break;
                        }
                        s.push('"');
                        i += 1;
                    }
                    Some('"') => { i += 1; break }
                    Some('$') if cs.get(i + 1) == Some(&'{') => {
                        let from = i + 2;
                        let to = interp_end(&cs, from).ok_or((ps[i], "unterminated `${` in string".to_string()))?;
                        let code: String = cs[from..to].iter().collect();
                        let base = ps[from];
                        let mut toks = lex(&code).map_err(|(p, m)| (shift(p, base), m))?;
                        for t in &mut toks {
                            t.pos = shift(t.pos, base);
                            t.start += from;
                            t.end += from;
                        }
                        parts.push(Part::Lit(std::mem::take(&mut s)));
                        parts.push(Part::Code(toks, base));
                        i = to + 1;
                    }
                    Some('\\') => {
                        s.push(match cs.get(i + 1) {
                            Some('n') => '\n',
                            Some('r') => '\r',
                            Some('t') => '\t',
                            Some('\\') => '\\',
                            Some('"') => '"',
                            Some('$') => '$',
                            _ => return Err((ps[i], "unknown escape (use \\n \\r \\t \\\\ \\\" \\$)".into())),
                        });
                        i += 2;
                    }
                    Some(&ch) => { s.push(ch); i += 1 }
                }
            }
            if parts.is_empty() {
                Tok::Str(s)
            } else {
                parts.push(Part::Lit(s));
                Tok::Interp(parts)
            }
        } else {
            let two = match (c, next) {
                ('-', '>') => Some(Tok::Arrow), ('=', '>') => Some(Tok::FatArrow), ('.', '.') => Some(Tok::DotDot),
                ('=', '=') => Some(Tok::Eq), ('!', '=') => Some(Tok::Ne), ('<', '=') => Some(Tok::Le),
                ('>', '=') => Some(Tok::Ge), ('&', '&') => Some(Tok::AndAnd), ('|', '|') => Some(Tok::OrOr),
                ('+', '=') => Some(Tok::PlusEq), ('-', '=') => Some(Tok::MinusEq),
                ('*', '=') => Some(Tok::TimesEq), ('/', '=') => Some(Tok::SlashEq), ('?', '?') => Some(Tok::QuestionQuestion), ('<', '<') => Some(Tok::Shl),
                _ => None,
            };
            if let Some(t) = two {
                i += 2;
                t
            } else {
                i += 1;
                match c {
                    '+' => Tok::Plus, '-' => Tok::Minus, '*' => Tok::Times, '/' => Tok::Slash,
                    '%' => Tok::Percent, '<' => Tok::Lt, '>' => Tok::Gt, '!' => Tok::Bang, '=' => Tok::Assign,
                    '(' => Tok::LParen, ')' => Tok::RParen, '{' => Tok::LBrace, '}' => Tok::RBrace,
                    '[' => Tok::LBrack, ']' => Tok::RBrack, ',' => Tok::Comma, ':' => Tok::Colon,
                    ';' => Tok::Semi, '.' => Tok::Dot, '?' => Tok::Question, '|' => Tok::Pipe,
                    '&' => Tok::Amp, '^' => Tok::Caret, '~' => Tok::Tilde,
                    _ => return Err((pos, format!("unexpected character '{c}'"))),
                }
            }
        };
        out.push(Token { tok, pos, start, end: i });
    }
    out.push(Token { tok: Tok::Eof, pos: ps[cs.len()], start: cs.len(), end: cs.len() });

    // Newlines end statements, except where the line obviously continues.
    let mut toks: Vec<Token> = Vec::with_capacity(out.len());
    for (k, t) in out.iter().enumerate() {
        if t.tok == Tok::Newline {
            let prev = toks.last().map(|p| &p.tok);
            let next = &out[k + 1].tok;
            if prev.is_none_or(|p| *p == Tok::Newline || continues_after(p)) || *next == Tok::Newline || continues_before(next) {
                continue;
            }
        }
        toks.push(t.clone());
    }
    Ok(toks)
}
