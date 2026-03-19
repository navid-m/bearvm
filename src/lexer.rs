#[derive(Debug, Clone, PartialEq)]
pub enum Token {
    // literals
    Int(i64),
    Str(String),
    // identifiers / keywords
    Ident(String),
    Reg(String),   // %name
    Func(String),  // @name
    // keywords
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
    Set,
    Struct,
    // types
    TyInt,
    TyVoid,
    TyString,
    TyBool,
    // punctuation
    LBrace,
    RBrace,
    LParen,
    RParen,
    Colon,
    Comma,
    Dot,
    Assign,   // =
    Eof,
}

pub fn tokenize(src: &str) -> Result<Vec<Token>, String> {
    let mut tokens = Vec::new();
    let chars: Vec<char> = src.chars().collect();
    let mut i = 0;

    while i < chars.len() {
        // skip whitespace
        if chars[i].is_whitespace() {
            i += 1;
            continue;
        }
        // line comments
        if chars[i] == ';' {
            while i < chars.len() && chars[i] != '\n' {
                i += 1;
            }
            continue;
        }
        match chars[i] {
            '{' => { tokens.push(Token::LBrace); i += 1; }
            '}' => { tokens.push(Token::RBrace); i += 1; }
            '(' => { tokens.push(Token::LParen); i += 1; }
            ')' => { tokens.push(Token::RParen); i += 1; }
            ':' => { tokens.push(Token::Colon); i += 1; }
            ',' => { tokens.push(Token::Comma); i += 1; }
            '.' => { tokens.push(Token::Dot); i += 1; }
            '=' => { tokens.push(Token::Assign); i += 1; }
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
                            c => { s.push('\\'); s.push(c); }
                        }
                    } else {
                        s.push(chars[i]);
                    }
                    i += 1;
                }
                if i >= chars.len() {
                    return Err("Unterminated string literal".into());
                }
                i += 1; // closing "
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
            c if c.is_ascii_digit() || (c == '-' && i + 1 < chars.len() && chars[i+1].is_ascii_digit()) => {
                let neg = c == '-';
                if neg { i += 1; }
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
                    "const"  => Token::Const,
                    "add"    => Token::Add,
                    "sub"    => Token::Sub,
                    "mul"    => Token::Mul,
                    "div"    => Token::Div,
                    "lt"     => Token::Lt,
                    "gt"     => Token::Gt,
                    "eq"     => Token::Eq,
                    "ret"    => Token::Ret,
                    "call"   => Token::Call,
                    "while"  => Token::While,
                    "alloc"  => Token::Alloc,
                    "set"    => Token::Set,
                    "struct" => Token::Struct,
                    "int"    => Token::TyInt,
                    "void"   => Token::TyVoid,
                    "string" => Token::TyString,
                    "bool"   => Token::TyBool,
                    _        => Token::Ident(word),
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
