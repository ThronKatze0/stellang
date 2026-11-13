//! Syntax grammars for editors, generated from the compiler's own tables (keywords, emoji twins,
//! builtins), so they never fall behind the language. `stellang grammar textmate|vim` prints them;
//! a test checks that the copies in `editors/` are current.

use crate::codegen::RESERVED;
use crate::lexer::{Tok, EMOJI, WORDS};

/// Keywords that introduce declarations; every other keyword is control flow.
const DECLARE: &[&str] = &["fn", "struct", "enum", "trait", "const", "impl", "extern", "import", "let", "var"];
const TYPES: &[&str] = &["int", "float", "bool", "str", "void"];
const CONSTANTS: &[&str] = &["true", "false", "none"];

pub struct Words {
    pub declare: Vec<String>,
    pub control: Vec<String>,
    pub types: Vec<String>,
    pub constants: Vec<String>,
    pub builtins: Vec<String>,
}

pub fn words() -> Words {
    let mut declare = vec![];
    let mut control = vec![];
    for (w, t) in WORDS.iter() {
        let emoji = EMOJI.iter().find(|e| e.0 == *t).map(|e| e.1.to_string());
        let list = if DECLARE.contains(w) { &mut declare } else { &mut control };
        list.push(w.to_string());
        list.extend(emoji);
    }
    let builtins = RESERVED
        .iter()
        .filter(|w| !TYPES.contains(w) && !CONSTANTS.contains(w) && **w != "self")
        .map(|w| w.to_string())
        .collect();
    let own = |xs: &[&str]| xs.iter().map(|x| x.to_string()).collect();
    Words { declare, control, types: own(TYPES), constants: own(CONSTANTS), builtins }
}

fn alt(ws: &[String]) -> String {
    let ascii: Vec<&str> = ws.iter().filter(|w| w.is_ascii()).map(String::as_str).collect();
    let emoji: Vec<&str> = ws.iter().filter(|w| !w.is_ascii()).map(String::as_str).collect();
    let mut parts = vec![];
    if !ascii.is_empty() {
        parts.push(format!("\\b(?:{})\\b", ascii.join("|")));
    }
    if !emoji.is_empty() {
        parts.push(format!("(?:{})", emoji.join("|")));
    }
    parts.join("|")
}

/// A TextMate grammar (VS Code, Sublime, GitHub, ...). The language server adds semantic colors on top.
/// The scopes are fine-grained so a theme can give every kind of thing its own color: the declared
/// name after `fn`/`struct`/`enum`/`let`/`var`, `.Variant` shorthands, `?`/`!`/`??`/`?.`, the ⭐ braces.
pub fn textmate() -> String {
    use crate::json::{obj, Json};
    let w = words();
    let rule = |name: &str, re: String| obj([("name", name.into()), ("match", re.into())]);
    let caps = |re: String, names: &[&str]| {
        let c: Vec<(String, Json)> = names.iter().enumerate().filter(|(_, n)| !n.is_empty()).map(|(i, n)| ((i + 1).to_string(), obj([("name", (*n).into())]))).collect();
        obj([("match", re.into()), ("captures", Json::Obj(c))])
    };
    let kw = |t: Tok| -> String {
        let mut alts: Vec<String> = WORDS.iter().filter(|x| x.1 == t).map(|x| format!("\\b{}\\b", x.0)).collect();
        alts.extend(EMOJI.iter().filter(|e| e.0 == t).map(|e| e.1.to_string()));
        format!("(?:{})", alts.join("|"))
    };
    // emoji twins of punctuation (❤️ is `;`)
    let punct_emoji: Vec<&str> = EMOJI.iter().filter(|e| !WORDS.iter().any(|w| w.1 == e.0)).map(|e| e.1).collect();
    let ident = "[A-Za-z_][A-Za-z0-9_]*";
    let lower = "[a-z_][A-Za-z0-9_]*";
    let upper = "[A-Z][A-Za-z0-9_]*";
    let mut patterns: Vec<Json> = vec![
        obj([("include", "#comment".into())]),
        obj([("include", "#string".into())]),
        // declarations: the keyword and the name it introduces
        caps(format!("({})\\s+({ident})", kw(Tok::Import)), &["keyword.other.import.stellang", "entity.name.namespace.stellang"]),
        caps(format!("({})\\s+({ident})", kw(Tok::Fn)), &["storage.type.function.stellang", "entity.name.function.declaration.stellang"]),
        caps(format!("({})\\s+({ident})", kw(Tok::Struct)), &["storage.type.struct.stellang", "entity.name.type.struct.stellang"]),
        caps(format!("({})\\s+({ident})", kw(Tok::Enum)), &["storage.type.enum.stellang", "entity.name.type.enum.stellang"]),
        caps(format!("({})\\s+({ident})", kw(Tok::Trait)), &["storage.type.trait.stellang", "entity.name.type.trait.stellang"]),
        caps(format!("({})\\s+({ident})", kw(Tok::Const)), &["storage.modifier.const.stellang", "variable.other.constant.declaration.stellang"]),
        caps(format!("({})\\s+({lower})", kw(Tok::Var)), &["storage.modifier.mut.stellang", "variable.other.mutable.declaration.stellang"]),
        caps(format!("({})\\s+({lower})", kw(Tok::Let)), &["storage.type.let.stellang", "variable.other.readonly.declaration.stellang"]),
        // `trait Show`, `impl Show for Point`, `<T: Show>`
        caps(format!("({})\\s+({upper})\\s+(for)\\b", kw(Tok::Impl)), &["storage.type.impl.stellang", "entity.name.type.trait.stellang", "keyword.other.for.stellang"]),
        // JSX: <div class="x">, <Card title={t} />, </div>, <>...</>
        obj([("include", "#jsx".into())]),
        // generic parameters and arguments: fn f<T: Show>, Box<int>
        caps(format!("(?<=[A-Za-z0-9_])(<)((?:\\s*[A-Za-z_][A-Za-z0-9_.]*(?:\\s*:\\s*[A-Za-z_][A-Za-z0-9_.]*(?:\\s*\\+\\s*[A-Za-z_][A-Za-z0-9_.]*)*)?\\s*,?)+)(>)"),
            &["punctuation.definition.typeparameters.begin.stellang", "meta.type.parameters.stellang", "punctuation.definition.typeparameters.end.stellang"]),
        rule("storage.type.stellang", alt(&w.declare)),
        rule("keyword.control.stellang", alt(&w.control)),
        rule("constant.language.stellang", alt(&w.constants)),
        rule("variable.language.self.stellang", "\\bself\\b".into()),
        rule("variable.language.wildcard.stellang", "\\b_\\b".into()),
        rule("support.type.primitive.stellang", alt(&w.types)),
        rule("support.function.builtin.stellang", format!("(?:{})(?=\\s*\\()", alt(&w.builtins))),
        rule("constant.numeric.float.stellang", "\\b\\d[\\d_]*\\.\\d[\\d_]*(?:[eE][+-]?\\d+)?\\b".into()),
        rule("constant.numeric.integer.stellang", "\\b(?:0[xX][\\da-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\\d[\\d_]*)\\b".into()),
        // `Shape.Circle`, `.Circle` (the type comes from context), field names, method calls
        caps(format!("\\b({upper})(\\.)({upper})\\b"), &["entity.name.type.stellang", "punctuation.accessor.stellang", "variable.other.enummember.stellang"]),
        caps(format!("(?<![\\w\\)\\]\"])(\\.)({upper})\\b"), &["punctuation.accessor.shorthand.stellang", "variable.other.enummember.stellang"]),
        caps(format!("(\\?\\.|\\.)({lower})(?=\\s*\\()"), &["punctuation.accessor.stellang", "entity.name.function.member.stellang"]),
        caps(format!("(\\?\\.|\\.)({lower})\\b"), &["punctuation.accessor.stellang", "variable.other.property.stellang"]),
        caps(format!("^\\s*({lower})\\s*(:)(?!:)"), &["variable.other.property.declaration.stellang", "punctuation.separator.key-value.stellang"]),
        caps(format!("(?<=[{{,]\\s)({lower})\\s*(:)(?!:)"), &["variable.other.property.stellang", "punctuation.separator.key-value.stellang"]),
        rule("entity.name.type.stellang", format!("\\b{upper}\\b")),
        rule("entity.name.function.call.stellang", format!("\\b{lower}(?=\\s*\\()")),
        // operators, from the most specific
        rule("keyword.operator.optional-chain.stellang", "\\?\\.".into()),
        rule("keyword.operator.coalesce.stellang", "\\?\\?".into()),
        rule("storage.type.function.arrow.stellang", "=>".into()),
        rule("punctuation.separator.return-type.stellang", "->".into()),
        rule("keyword.operator.range.stellang", "\\.\\.".into()),
        rule("keyword.operator.comparison.stellang", "==|!=|<=|>=|<|>".into()),
        rule("keyword.operator.logical.stellang", "&&|\\|\\|".into()),
        rule("keyword.operator.assignment.compound.stellang", "\\+=|-=|\\*=|/=".into()),
        rule("keyword.operator.assignment.stellang", "=".into()),
        // `T?` / `x?` and `T!` / `!x`: the error-flow marks
        rule("keyword.operator.optional.stellang", "\\?".into()),
        rule("keyword.operator.result.stellang", "(?<=[A-Za-z0-9_\\]\\)}?])!".into()),
        rule("keyword.operator.logical.not.stellang", "!".into()),
        rule("keyword.operator.pattern.or.stellang", "\\|".into()),
        rule("keyword.operator.arithmetic.stellang", "[-+*/%]".into()),
        rule("punctuation.section.block.star.stellang", "⭐".into()),
        rule("variable.other.stellang", format!("\\b{lower}\\b")),
        rule("punctuation.section.braces.stellang", "[{}]".into()),
        rule("punctuation.section.brackets.stellang", "[\\[\\]]".into()),
        rule("punctuation.section.parens.stellang", "[()]".into()),
        rule("punctuation.separator.comma.stellang", ",".into()),
        rule("punctuation.separator.colon.stellang", ":".into()),
        rule("punctuation.terminator.stellang", ";".into()),
    ];
    if !punct_emoji.is_empty() {
        patterns.push(rule("punctuation.terminator.emoji.stellang", format!("(?:{})", punct_emoji.join("|"))));
    }
    let comment = obj([
        ("name", "comment.line.double-slash.stellang".into()),
        ("begin", "//".into()),
        ("beginCaptures", obj([("0", obj([("name", "punctuation.definition.comment.stellang".into())]))])),
        ("end", "$".into()),
        ("patterns", Json::Arr(vec![rule("keyword.other.todo.stellang", "\\b(?:TODO|FIXME|XXX|HACK|NOTE)\\b".into()), rule("markup.inline.raw.stellang", "`[^`]*`".into())])),
    ]);
    let string = obj([
        ("name", "string.quoted.double.stellang".into()),
        ("begin", "\"".into()),
        ("beginCaptures", obj([("0", obj([("name", "punctuation.definition.string.begin.stellang".into())]))])),
        ("end", "\"".into()),
        ("endCaptures", obj([("0", obj([("name", "punctuation.definition.string.end.stellang".into())]))])),
        (
            "patterns",
            Json::Arr(vec![
                rule("constant.character.escape.stellang", "\\\\[nrt\\\\\"$0]|\\\\u\\{[0-9a-fA-F]+\\}".into()),
                rule("constant.other.placeholder.route.stellang", "(?<=/):[a-z_][A-Za-z0-9_]*".into()),
                obj([
                    ("name", "meta.interpolation.stellang".into()),
                    ("contentName", "source.stellang.embedded".into()),
                    ("begin", "\\$\\{".into()),
                    ("beginCaptures", obj([("0", obj([("name", "punctuation.section.interpolation.begin.stellang".into())]))])),
                    ("end", "\\}".into()),
                    ("endCaptures", obj([("0", obj([("name", "punctuation.section.interpolation.end.stellang".into())]))])),
                    ("patterns", Json::Arr(vec![obj([("include", "$self".into())])])),
                ]),
            ]),
        ),
    ]);
    let attrs = Json::Arr(vec![
        obj([("include", "#comment".into())]),
        obj([("include", "#string".into())]),
        obj([
            ("name", "meta.embedded.expression.stellang".into()),
            ("begin", "\\{".into()),
            ("beginCaptures", obj([("0", obj([("name", "punctuation.section.embedded.begin.stellang".into())]))])),
            ("end", "\\}".into()),
            ("endCaptures", obj([("0", obj([("name", "punctuation.section.embedded.end.stellang".into())]))])),
            ("patterns", Json::Arr(vec![obj([("include", "#braces".into())]), obj([("include", "$self".into())])])),
        ]),
        rule("entity.other.attribute-name.event.stellang", "\\bon[A-Za-z_]+\\b".into()),
        rule("entity.other.attribute-name.stellang", "[A-Za-z_][A-Za-z0-9_-]*".into()),
        rule("keyword.operator.assignment.stellang", "=".into()),
    ]);
    let tag = |name_re: &str, name_scope: &str| {
        obj([
            ("name", "meta.tag.stellang".into()),
            ("begin", format!("(?<![A-Za-z0-9_)\\]])(<)({name_re})(?=[\\s/>])").into()),
            ("beginCaptures", obj([("1", obj([("name", "punctuation.definition.tag.begin.stellang".into())])), ("2", obj([("name", name_scope.into())]))])),
            ("end", "/?>".into()),
            ("endCaptures", obj([("0", obj([("name", "punctuation.definition.tag.end.stellang".into())]))])),
            ("patterns", attrs.clone()),
        ])
    };
    let jsx = obj([(
        "patterns",
        Json::Arr(vec![
            caps("(</)((?:[a-z_][A-Za-z0-9_]*\\.)*[A-Z][A-Za-z0-9_]*)(>)".into(), &["punctuation.definition.tag.begin.stellang", "support.class.component.stellang", "punctuation.definition.tag.end.stellang"]),
            caps("(</)([a-z][a-z0-9-]*)?(>)".into(), &["punctuation.definition.tag.begin.stellang", "entity.name.tag.stellang", "punctuation.definition.tag.end.stellang"]),
            caps("(?<![A-Za-z0-9_)\\]])(<)(>)".into(), &["punctuation.definition.tag.begin.stellang", "punctuation.definition.tag.end.stellang"]),
            tag("(?:[a-z_][A-Za-z0-9_]*\\.)*[A-Z][A-Za-z0-9_]*", "support.class.component.stellang"),
            tag("[a-z][a-z0-9-]*", "entity.name.tag.stellang"),
        ]),
    )]);
    // `{ ... }` with nested braces (inside an attribute's {value})
    let braces = obj([
        ("begin", "\\{".into()),
        ("beginCaptures", obj([("0", obj([("name", "punctuation.section.braces.stellang".into())]))])),
        ("end", "\\}".into()),
        ("endCaptures", obj([("0", obj([("name", "punctuation.section.braces.stellang".into())]))])),
        ("patterns", Json::Arr(vec![obj([("include", "#braces".into())]), obj([("include", "$self".into())])])),
    ]);
    let g = obj([
        ("$comment", "Generated by `stellang grammar textmate`; do not edit.".into()),
        ("name", "stellang".into()),
        ("scopeName", "source.stellang".into()),
        ("fileTypes", Json::Arr(vec!["st".into()])),
        ("patterns", Json::Arr(patterns)),
        ("repository", obj([("comment", comment), ("string", string), ("jsx", jsx), ("braces", braces)])),
    ]);
    format!("{g}\n")
}

/// A Vim syntax file, for Vim and for Neovim without the language server.
pub fn vim() -> String {
    let w = words();
    let kw = |group: &str, ws: &[String]| {
        let ascii: Vec<&str> = ws.iter().filter(|w| w.is_ascii()).map(String::as_str).collect();
        let mut s = format!("syn keyword {group} {}\n", ascii.join(" "));
        for e in ws.iter().filter(|w| !w.is_ascii()) {
            s += &format!("syn match {group} \"{e}\"\n");
        }
        s
    };
    let mut s = String::from("\" Generated by `stellang grammar vim`; do not edit.\nif exists(\"b:current_syntax\") | finish | endif\n\n");
    s += &kw("stellangDeclare", &w.declare);
    s += &kw("stellangControl", &w.control);
    s += &kw("stellangType", &w.types);
    s += &kw("stellangConstant", &w.constants);
    s += &format!("syn match stellangBuiltin \"\\<\\({}\\)\\ze\\s*(\"\n", w.builtins.join("\\|"));
    s += "syn keyword stellangSelf self\n";
    s += "syn match stellangNumber \"\\<0[xX][0-9a-fA-F_]\\+\\>\"\n";
    s += "syn match stellangNumber \"\\<0[bB][01_]\\+\\>\"\n";
    s += "syn match stellangNumber \"\\<\\d[0-9_]*\\(\\.\\d[0-9_]*\\)\\=\\([eE][+-]\\=\\d\\+\\)\\=\\>\"\n";
    s += "syn match stellangTypeName \"\\<[A-Z][A-Za-z0-9_]*\\>\"\n";
    s += "syn match stellangFunction \"\\<[a-z_][A-Za-z0-9_]*\\ze\\s*(\"\n";
    s += "syn region stellangInterp matchgroup=stellangInterpDelim start=\"\\${\" end=\"}\" contained contains=TOP\n";
    s += "syn match stellangEscape \"\\\\[nrt\\\\\\\"$]\" contained\n";
    s += "syn region stellangString start=+\"+ skip=+\\\\\\\\\\|\\\\\"+ end=+\"+ contains=stellangEscape,stellangInterp\n";
    s += "syn match stellangComment \"//.*$\" contains=@Spell\n";
    s += "syn match stellangTag \"\\(\\w\\)\\@<!</\\=\\zs[a-z][a-z0-9-]*\\ze[ \\t/>]\"\n";
    s += "syn match stellangComponent \"\\(\\w\\)\\@<!</\\=\\zs\\([a-z_]\\w*\\.\\)*[A-Z]\\w*\\ze[ \\t/>]\"\n";
    s += "syn match stellangAttr \"\\<on[a-z_]\\+\\ze=\"\n\n";
    for (g, to) in [
        ("Declare", "Keyword"), ("Control", "Conditional"), ("Type", "Type"), ("Constant", "Constant"),
        ("Builtin", "Function"), ("Self", "Identifier"), ("Number", "Number"), ("TypeName", "Type"),
        ("Function", "Function"), ("String", "String"), ("Escape", "SpecialChar"), ("InterpDelim", "Delimiter"),
        ("Comment", "Comment"), ("Tag", "Statement"), ("Component", "Type"), ("Attr", "Special"),
    ] {
        s += &format!("hi def link stellang{g} {to}\n");
    }
    s += "\nlet b:current_syntax = \"stellang\"\n";
    s
}
