use crate::diag::Diag;

#[derive(Debug, Clone, PartialEq)]
pub enum Tok {
    At(String), // @interface, @effect, @noalias, ...
    Ident(String),
    Int(u64),
    Float(f32),
    KwFor,
    KwReturn,
    KwConst,
    KwVoid,
    KwFloat,
    KwUsize,
    Plus,
    PlusPlus,
    PlusEq,
    Minus,
    Star,
    Slash,
    Lt,
    Le,
    Gt,
    Ge,
    EqEq,
    Ne,
    Assign,
    LParen,
    RParen,
    LBrace,
    RBrace,
    LBracket,
    RBracket,
    Semi,
    Comma,
    Colon,
    Eof,
}

#[derive(Debug, Clone)]
pub struct Token {
    pub tok: Tok,
    pub line: u32,
}

pub fn lex(src: &str) -> Result<Vec<Token>, Diag> {
    let chars: Vec<char> = src.chars().collect();
    let mut toks = Vec::new();
    let mut i = 0usize;
    let mut line = 1u32;

    while i < chars.len() {
        let c = chars[i];
        match c {
            '\n' => {
                line += 1;
                i += 1;
            }
            ' ' | '\t' | '\r' => i += 1,
            '/' if chars.get(i + 1) == Some(&'/') => {
                while i < chars.len() && chars[i] != '\n' {
                    i += 1;
                }
            }
            '/' => {
                toks.push(Token { tok: Tok::Slash, line });
                i += 1;
            }
            '@' => {
                i += 1;
                let start = i;
                while i < chars.len() && (chars[i].is_ascii_alphanumeric() || chars[i] == '_') {
                    i += 1;
                }
                if start == i {
                    return Err(Diag::err(None, "expected directive name after `@`", line));
                }
                let s: String = chars[start..i].iter().collect();
                toks.push(Token { tok: Tok::At(s), line });
            }
            c if c.is_ascii_alphabetic() || c == '_' => {
                let start = i;
                while i < chars.len() && (chars[i].is_ascii_alphanumeric() || chars[i] == '_') {
                    i += 1;
                }
                let s: String = chars[start..i].iter().collect();
                let tok = match s.as_str() {
                    "for" => Tok::KwFor,
                    "return" => Tok::KwReturn,
                    "const" => Tok::KwConst,
                    "void" => Tok::KwVoid,
                    "float" => Tok::KwFloat,
                    "usize" => Tok::KwUsize,
                    "in" | "out" | "inout" | "oneway" | "bycopy" | "byref" => {
                        return Err(Diag::err(
                            None,
                            format!("`{}` is reserved by Objective-C's grammar (protocol qualifier)", s),
                            line,
                        ));
                    }
                    _ => Tok::Ident(s),
                };
                toks.push(Token { tok, line });
            }
            c if c.is_ascii_digit() => {
                let start = i;
                while i < chars.len() && chars[i].is_ascii_digit() {
                    i += 1;
                }
                let mut is_float = false;
                if i < chars.len() && chars[i] == '.' {
                    is_float = true;
                    i += 1;
                    while i < chars.len() && chars[i].is_ascii_digit() {
                        i += 1;
                    }
                }
                let text: String = chars[start..i].iter().collect();
                if i < chars.len() && chars[i] == 'f' {
                    is_float = true;
                    i += 1;
                }
                if is_float {
                    let v: f32 = text
                        .parse()
                        .map_err(|_| Diag::err(None, format!("bad float literal `{}`", text), line))?;
                    toks.push(Token { tok: Tok::Float(v), line });
                } else {
                    let v: u64 = text
                        .parse()
                        .map_err(|_| Diag::err(None, format!("bad integer literal `{}`", text), line))?;
                    toks.push(Token { tok: Tok::Int(v), line });
                }
            }
            '+' => {
                if chars.get(i + 1) == Some(&'+') {
                    toks.push(Token { tok: Tok::PlusPlus, line });
                    i += 2;
                } else if chars.get(i + 1) == Some(&'=') {
                    toks.push(Token { tok: Tok::PlusEq, line });
                    i += 2;
                } else {
                    toks.push(Token { tok: Tok::Plus, line });
                    i += 1;
                }
            }
            '-' => {
                toks.push(Token { tok: Tok::Minus, line });
                i += 1;
            }
            '*' => {
                toks.push(Token { tok: Tok::Star, line });
                i += 1;
            }
            '<' => {
                if chars.get(i + 1) == Some(&'=') {
                    toks.push(Token { tok: Tok::Le, line });
                    i += 2;
                } else {
                    toks.push(Token { tok: Tok::Lt, line });
                    i += 1;
                }
            }
            '>' => {
                if chars.get(i + 1) == Some(&'=') {
                    toks.push(Token { tok: Tok::Ge, line });
                    i += 2;
                } else {
                    toks.push(Token { tok: Tok::Gt, line });
                    i += 1;
                }
            }
            '=' => {
                if chars.get(i + 1) == Some(&'=') {
                    toks.push(Token { tok: Tok::EqEq, line });
                    i += 2;
                } else {
                    toks.push(Token { tok: Tok::Assign, line });
                    i += 1;
                }
            }
            '!' => {
                if chars.get(i + 1) == Some(&'=') {
                    toks.push(Token { tok: Tok::Ne, line });
                    i += 2;
                } else {
                    return Err(Diag::err(None, "unexpected `!`", line));
                }
            }
            '(' => {
                toks.push(Token { tok: Tok::LParen, line });
                i += 1;
            }
            ')' => {
                toks.push(Token { tok: Tok::RParen, line });
                i += 1;
            }
            '{' => {
                toks.push(Token { tok: Tok::LBrace, line });
                i += 1;
            }
            '}' => {
                toks.push(Token { tok: Tok::RBrace, line });
                i += 1;
            }
            '[' => {
                toks.push(Token { tok: Tok::LBracket, line });
                i += 1;
            }
            ']' => {
                toks.push(Token { tok: Tok::RBracket, line });
                i += 1;
            }
            ';' => {
                toks.push(Token { tok: Tok::Semi, line });
                i += 1;
            }
            ',' => {
                toks.push(Token { tok: Tok::Comma, line });
                i += 1;
            }
            ':' => {
                toks.push(Token { tok: Tok::Colon, line });
                i += 1;
            }
            _ => return Err(Diag::err(None, format!("unexpected character `{}`", c), line)),
        }
    }

    toks.push(Token { tok: Tok::Eof, line });
    Ok(toks)
}
