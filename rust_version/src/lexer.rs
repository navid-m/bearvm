#[derive(Debug, Clone, PartialEq)]
pub enum Token {
    Int(i64),
    Str(String),
    Ident(String),
    Reg(String),
    Func(String),
    Label(String),
    Const,
    Add,
    Sub,
    Mul,
    Div,
    Lt,
    Gt,
    Eq,
    Ret,
    Call,
    While,
    Alloc,
    AllocArray,
    Set,
    Struct,
    Store,
    Load,
    GetIndexRef,
    GetFieldRef,
    Jmp,
    BrIf,
    TyInt,
    TyVoid,
    TyString,
    TyBool,
    LBrace,
    RBrace,
    LParen,
    RParen,
    Colon,
    Comma,
    Dot,
    Assign,
    Eof,
}

pub fn tokenize(src: &str) -> Result<Vec<Token>, String> {
    let mut tokens = Vec::new();
    let chars: Vec<char> = src.chars().collect();
    let mut i = 0;

    while i < chars.len() {
        if chars[i].is_whitespace() {
            i += 1;
            continue;
        }
        if chars[i] == ';' {
            while i < chars.len() && chars[i] != '\n' {
                i += 1;
            }
            continue;
        }
        match chars[i] {
            '{' => {
                tokens.push(Token::LBrace);
                i += 1;
            }
            '}' => {
                tokens.push(Token::RBrace);
                i += 1;
            }
            '(' => {
                tokens.push(Token::LParen);
                i += 1;
            }
            ')' => {
                tokens.push(Token::RParen);
                i += 1;
            }
            ':' => {
                tokens.push(Token::Colon);
                i += 1;
            }
            ',' => {
                tokens.push(Token::Comma);
                i += 1;
            }
            '.' => {
                tokens.push(Token::Dot);
                i += 1;
            }
            '=' => {
                tokens.push(Token::Assign);
                i += 1;
            }
            '"' => {
                i += 1;
                let mut s = String::new();
                while i < chars.len() && chars[i] != '"' {
                    if chars[i] == '\\' && i + 1 < chars.len() {
                        i += 1;
                        match chars[i] {
                            'n' => s.push('\n'),
                            't' => s.push('\t'),
                            '"' => s.push('"'),
                            '\\' => s.push('\\'),
                            c => {
                                s.push('\\');
                                s.push(c);
                            }
                        }
                    } else {
                        s.push(chars[i]);
                    }
                    i += 1;
                }
                if i >= chars.len() {
                    return Err("Unterminated string literal".into());
                }
                i += 1;
                tokens.push(Token::Str(s));
            }
            '%' => {
                i += 1;
                let name = read_ident(&chars, &mut i);
                tokens.push(Token::Reg(name));
            }
            '@' => {
                i += 1;
                let name = read_ident(&chars, &mut i);
                tokens.push(Token::Func(name));
            }
            c if c.is_ascii_digit()
                || (c == '-' && i + 1 < chars.len() && chars[i + 1].is_ascii_digit()) =>
            {
                let neg = c == '-';
                if neg {
                    i += 1;
                }
                let mut num = String::new();
                while i < chars.len() && chars[i].is_ascii_digit() {
                    num.push(chars[i]);
                    i += 1;
                }
                let n: i64 = num.parse().map_err(|e| format!("Bad int: {e}"))?;
                tokens.push(Token::Int(if neg { -n } else { n }));
            }
            c if c.is_alphabetic() || c == '_' => {
                let word = read_ident(&chars, &mut i);
                let tok = match word.as_str() {
                    "const" => Token::Const,
                    "add" => Token::Add,
                    "sub" => Token::Sub,
                    "mul" => Token::Mul,
                    "div" => Token::Div,
                    "lt" => Token::Lt,
                    "gt" => Token::Gt,
                    "eq" => Token::Eq,
                    "ret" => Token::Ret,
                    "call" => Token::Call,
                    "while" => Token::While,
                    "alloc" => Token::Alloc,
                    "alloc_array" => Token::AllocArray,
                    "set" => Token::Set,
                    "struct" => Token::Struct,
                    "store" => Token::Store,
                    "load" => Token::Load,
                    "get_index_ref" => Token::GetIndexRef,
                    "get_field_ref" => Token::GetFieldRef,
                    "jmp" => Token::Jmp,
                    "br_if" => Token::BrIf,
                    "int" => Token::TyInt,
                    "void" => Token::TyVoid,
                    "string" => Token::TyString,
                    "bool" => Token::TyBool,
                    _ => {
                        let j = i;
                        if j < chars.len() && chars[j] == ':' {
                            let after = j + 1;
                            let mut k = after;
                            while k < chars.len() && chars[k] == ' ' {
                                k += 1;
                            }
                            let next = chars.get(k).copied();
                            if matches!(next, None | Some('\n') | Some('\r') | Some(';')) {
                                i = after;
                                Token::Label(word)
                            } else {
                                Token::Ident(word)
                            }
                        } else {
                            Token::Ident(word)
                        }
                    }
                };
                tokens.push(tok);
            }
            c => return Err(format!("Unexpected character: {c:?} at position {i}")),
        }
    }

    tokens.push(Token::Eof);
    Ok(tokens)
}

fn read_ident(chars: &[char], i: &mut usize) -> String {
    let mut s = String::new();
    while *i < chars.len() && (chars[*i].is_alphanumeric() || chars[*i] == '_') {
        s.push(chars[*i]);
        *i += 1;
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lex(src: &str) -> Vec<Token> {
        tokenize(src).expect("lex failed")
    }

    #[test]
    fn empty_input() {
        assert_eq!(lex(""), vec![Token::Eof]);
    }

    #[test]
    fn keywords() {
        let toks = lex("const add sub mul div lt gt eq ret call while alloc set struct");
        assert_eq!(toks[0], Token::Const);
        assert_eq!(toks[1], Token::Add);
        assert_eq!(toks[2], Token::Sub);
        assert_eq!(toks[3], Token::Mul);
        assert_eq!(toks[4], Token::Div);
        assert_eq!(toks[5], Token::Lt);
        assert_eq!(toks[6], Token::Gt);
        assert_eq!(toks[7], Token::Eq);
        assert_eq!(toks[8], Token::Ret);
        assert_eq!(toks[9], Token::Call);
        assert_eq!(toks[10], Token::While);
        assert_eq!(toks[11], Token::Alloc);
        assert_eq!(toks[12], Token::Set);
        assert_eq!(toks[13], Token::Struct);
    }

    #[test]
    fn type_keywords() {
        let toks = lex("int void string bool");
        assert_eq!(toks[0], Token::TyInt);
        assert_eq!(toks[1], Token::TyVoid);
        assert_eq!(toks[2], Token::TyString);
        assert_eq!(toks[3], Token::TyBool);
    }

    #[test]
    fn punctuation() {
        let toks = lex("{ } ( ) : , . =");
        assert_eq!(toks[0], Token::LBrace);
        assert_eq!(toks[1], Token::RBrace);
        assert_eq!(toks[2], Token::LParen);
        assert_eq!(toks[3], Token::RParen);
        assert_eq!(toks[4], Token::Colon);
        assert_eq!(toks[5], Token::Comma);
        assert_eq!(toks[6], Token::Dot);
        assert_eq!(toks[7], Token::Assign);
    }

    #[test]
    fn integer_literals() {
        let toks = lex("0 42 -7");
        assert_eq!(toks[0], Token::Int(0));
        assert_eq!(toks[1], Token::Int(42));
        assert_eq!(toks[2], Token::Int(-7));
    }

    #[test]
    fn string_literal() {
        let toks = lex(r#""hello world""#);
        assert_eq!(toks[0], Token::Str("hello world".into()));
    }

    #[test]
    fn string_escape_sequences() {
        let toks = lex(r#""line1\nline2""#);
        assert_eq!(toks[0], Token::Str("line1\nline2".into()));
    }

    #[test]
    fn register_and_func_sigils() {
        let toks = lex("%my_reg @my_func");
        assert_eq!(toks[0], Token::Reg("my_reg".into()));
        assert_eq!(toks[1], Token::Func("my_func".into()));
    }

    #[test]
    fn identifier() {
        let toks = lex("puts other_func");
        assert_eq!(toks[0], Token::Ident("puts".into()));
        assert_eq!(toks[1], Token::Ident("other_func".into()));
    }

    #[test]
    fn line_comment_skipped() {
        let toks = lex("; this is a comment\n42");
        assert_eq!(toks[0], Token::Int(42));
    }

    #[test]
    fn unterminated_string_is_error() {
        assert!(tokenize(r#""oops"#).is_err());
    }

    #[test]
    fn unexpected_char_is_error() {
        assert!(tokenize("^").is_err());
    }

    #[test]
    fn full_function_header() {
        let toks = lex("@main(): int {");
        assert_eq!(toks[0], Token::Func("main".into()));
        assert_eq!(toks[1], Token::LParen);
        assert_eq!(toks[2], Token::RParen);
        assert_eq!(toks[3], Token::Colon);
        assert_eq!(toks[4], Token::TyInt);
        assert_eq!(toks[5], Token::LBrace);
    }
}
