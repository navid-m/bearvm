use crate::ast::*;
use crate::lexer::Token;

struct Parser {
    tokens: Vec<Token>,
    pos: usize,
}

impl Parser {
    fn peek(&self) -> &Token {
        &self.tokens[self.pos]
    }

    fn advance(&mut self) -> Token {
        let t = self.tokens[self.pos].clone();
        if self.pos + 1 < self.tokens.len() {
            self.pos += 1;
        }
        t
    }

    fn expect(&mut self, expected: &Token) -> Result<(), String> {
        let t = self.advance();
        if std::mem::discriminant(&t) == std::mem::discriminant(expected) {
            Ok(())
        } else {
            Err(format!("Expected {expected:?}, got {t:?}"))
        }
    }

    fn expect_ident(&mut self) -> Result<String, String> {
        match self.advance() {
            Token::Ident(s) => Ok(s),
            t => Err(format!("Expected identifier, got {t:?}")),
        }
    }

    fn expect_reg(&mut self) -> Result<String, String> {
        match self.advance() {
            Token::Reg(s) => Ok(s),
            t => Err(format!("Expected register (%name), got {t:?}")),
        }
    }

    fn expect_func(&mut self) -> Result<String, String> {
        match self.advance() {
            Token::Func(s) => Ok(s),
            t => Err(format!("Expected function (@name), got {t:?}")),
        }
    }

    fn parse_ty(&mut self) -> Result<Ty, String> {
        match self.advance() {
            Token::TyInt => Ok(Ty::Int),
            Token::TyVoid => Ok(Ty::Void),
            Token::TyString => Ok(Ty::Str),
            Token::TyBool => Ok(Ty::Bool),
            Token::Ident(s) => Ok(Ty::Named(s)),
            t => Err(format!("Expected type, got {t:?}")),
        }
    }

    /// Parse an optional argument list. Parens are optional — `call foo` is valid.
    fn parse_args(&mut self) -> Result<Vec<Expr>, String> {
        if self.peek() != &Token::LParen {
            return Ok(Vec::new());
        }
        self.advance();
        let mut args = Vec::new();
        while self.peek() != &Token::RParen {
            args.push(self.parse_expr()?);
            if self.peek() == &Token::Comma {
                self.advance();
            }
        }
        self.expect(&Token::RParen)?;
        Ok(args)
    }

    fn parse_expr(&mut self) -> Result<Expr, String> {
        match self.peek().clone() {
            Token::Const => {
                self.advance();
                let inner = self.parse_expr()?;
                Ok(Expr::Const(Box::new(inner)))
            }
            Token::Add => {
                self.advance();
                let a = self.parse_expr()?;
                self.expect(&Token::Comma)?;
                let b = self.parse_expr()?;
                Ok(Expr::Add(Box::new(a), Box::new(b)))
            }
            Token::Sub => {
                self.advance();
                let a = self.parse_expr()?;
                self.expect(&Token::Comma)?;
                let b = self.parse_expr()?;
                Ok(Expr::Sub(Box::new(a), Box::new(b)))
            }
            Token::Mul => {
                self.advance();
                let a = self.parse_expr()?;
                self.expect(&Token::Comma)?;
                let b = self.parse_expr()?;
                Ok(Expr::Mul(Box::new(a), Box::new(b)))
            }
            Token::Div => {
                self.advance();
                let a = self.parse_expr()?;
                self.expect(&Token::Comma)?;
                let b = self.parse_expr()?;
                Ok(Expr::Div(Box::new(a), Box::new(b)))
            }
            Token::Lt => {
                self.advance();
                let a = self.parse_expr()?;
                self.expect(&Token::Comma)?;
                let b = self.parse_expr()?;
                Ok(Expr::Lt(Box::new(a), Box::new(b)))
            }
            Token::Gt => {
                self.advance();
                let a = self.parse_expr()?;
                self.expect(&Token::Comma)?;
                let b = self.parse_expr()?;
                Ok(Expr::Gt(Box::new(a), Box::new(b)))
            }
            Token::Eq => {
                self.advance();
                let a = self.parse_expr()?;
                self.expect(&Token::Comma)?;
                let b = self.parse_expr()?;
                Ok(Expr::Eq(Box::new(a), Box::new(b)))
            }
            Token::Call => {
                self.advance();
                let name = match self.advance() {
                    Token::Ident(s) => s,
                    Token::Func(s) => s,
                    t => return Err(format!("Expected function name after call, got {t:?}")),
                };
                let args = self.parse_args()?;
                Ok(Expr::Call(name, args))
            }
            Token::Alloc => {
                self.advance();
                let size = self.parse_expr()?;
                Ok(Expr::Alloc(Box::new(size)))
            }
            Token::Int(n) => {
                let n = n;
                self.advance();
                Ok(Expr::Int(n))
            }
            Token::Str(s) => {
                let s = s.clone();
                self.advance();
                Ok(Expr::Str(s))
            }
            Token::Reg(r) => {
                let r = r.clone();
                self.advance();
                if self.peek() == &Token::Dot {
                    self.advance();
                    let field = self.expect_ident()?;
                    return Ok(Expr::Field(r, field));
                }
                Ok(Expr::Reg(r))
            }
            Token::Ident(name) => {
                let name = name.clone();
                self.advance();
                if self.peek() == &Token::LBrace {
                    self.advance();
                    let mut fields = Vec::new();
                    while self.peek() != &Token::RBrace {
                        let fname = self.expect_ident()?;
                        self.expect(&Token::Colon)?;
                        let val = self.parse_expr()?;
                        fields.push((fname, val));
                    }
                    self.expect(&Token::RBrace)?;
                    return Ok(Expr::StructLit(name, fields));
                }
                Ok(Expr::Named(name))
            }
            t => Err(format!("Unexpected token in expression: {t:?}")),
        }
    }

    fn parse_stmt(&mut self) -> Result<Stmt, String> {
        match self.peek().clone() {
            Token::Reg(r) => {
                let r = r.clone();
                self.advance();
                self.expect(&Token::Assign)?;
                let expr = self.parse_expr()?;
                Ok(Stmt::Assign(r, expr))
            }
            Token::Set => {
                self.advance();
                let r = self.expect_reg()?;
                self.expect(&Token::Dot)?;
                let field = self.expect_ident()?;
                self.expect(&Token::Assign)?;
                let expr = self.parse_expr()?;
                Ok(Stmt::SetField(r, field, expr))
            }
            Token::Call => {
                self.advance();
                let name = match self.advance() {
                    Token::Ident(s) => s,
                    Token::Func(s) => s,
                    t => return Err(format!("Expected function name after call, got {t:?}")),
                };
                let args = self.parse_args()?;
                Ok(Stmt::Call(name, args))
            }
            Token::Ret => {
                self.advance();
                let expr = self.parse_expr()?;
                Ok(Stmt::Ret(expr))
            }
            Token::While => {
                self.advance();
                self.expect(&Token::LParen)?;
                let cond = self.parse_expr()?;
                self.expect(&Token::RParen)?;
                self.expect(&Token::LBrace)?;
                let mut body = Vec::new();
                while self.peek() != &Token::RBrace {
                    body.push(self.parse_stmt()?);
                }
                self.expect(&Token::RBrace)?;
                Ok(Stmt::While(cond, body))
            }
            t => Err(format!("Unexpected token in statement: {t:?}")),
        }
    }

    fn parse_struct(&mut self) -> Result<StructDef, String> {
        self.expect(&Token::Struct)?;
        let name = self.expect_ident()?;
        self.expect(&Token::LBrace)?;
        let mut fields = Vec::new();
        while self.peek() != &Token::RBrace {
            let fname = self.expect_ident()?;
            self.expect(&Token::Colon)?;
            let ty = self.parse_ty()?;
            fields.push((fname, ty));
        }
        self.expect(&Token::RBrace)?;
        Ok(StructDef { name, fields })
    }

    fn parse_function(&mut self) -> Result<Function, String> {
        let name = self.expect_func()?;
        let mut params = Vec::new();

        if self.peek() == &Token::LParen {
            self.advance();
            while self.peek() != &Token::RParen {
                let pname = self.expect_reg()?;
                self.expect(&Token::Colon)?;
                let ty = self.parse_ty()?;
                params.push((pname, ty));
                if self.peek() == &Token::Comma {
                    self.advance();
                }
            }
            self.expect(&Token::RParen)?;
        }

        let ret_ty = if self.peek() == &Token::Colon {
            self.advance();
            self.parse_ty()?
        } else {
            Ty::Void
        };

        self.expect(&Token::LBrace)?;
        let mut body = Vec::new();
        while self.peek() != &Token::RBrace {
            body.push(self.parse_stmt()?);
        }
        self.expect(&Token::RBrace)?;

        Ok(Function {
            name,
            params,
            ret_ty,
            body,
        })
    }

    fn parse_program(&mut self) -> Result<Program, String> {
        let mut structs = Vec::new();
        let mut functions = Vec::new();

        while self.peek() != &Token::Eof {
            match self.peek() {
                Token::Struct => structs.push(self.parse_struct()?),
                Token::Func(_) => functions.push(self.parse_function()?),
                t => return Err(format!("Unexpected top-level token: {t:?}")),
            }
        }

        Ok(Program { structs, functions })
    }
}

pub fn parse(tokens: Vec<Token>) -> Result<Program, String> {
    let mut p = Parser { tokens, pos: 0 };
    p.parse_program()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lexer::tokenize;

    fn parse_src(src: &str) -> Program {
        let tokens = tokenize(src).expect("lex failed");
        parse(tokens).expect("parse failed")
    }

    #[test]
    fn minimal_void_function_no_parens() {
        let p = parse_src("@other_func: void { ret 0 }");
        assert_eq!(p.functions.len(), 1);
        assert_eq!(p.functions[0].name, "other_func");
        assert_eq!(p.functions[0].ret_ty, Ty::Void);
        assert!(p.functions[0].params.is_empty());
    }

    #[test]
    fn function_with_empty_parens_and_return_type() {
        let p = parse_src("@main(): int { ret 0 }");
        assert_eq!(p.functions[0].ret_ty, Ty::Int);
    }

    #[test]
    fn call_without_parens() {
        let p = parse_src("@main(): int { call other_func ret 0 }");
        let body = &p.functions[0].body;
        assert!(
            matches!(&body[0], Stmt::Call(name, args) if name == "other_func" && args.is_empty())
        );
    }

    #[test]
    fn call_with_args() {
        let p = parse_src(r#"@main(): int { call puts("hi") ret 0 }"#);
        let body = &p.functions[0].body;
        assert!(matches!(&body[0], Stmt::Call(name, args) if name == "puts" && args.len() == 1));
    }

    #[test]
    fn assign_const_int() {
        let p = parse_src("@main(): int { %x = const 42 ret 0 }");
        assert!(matches!(&p.functions[0].body[0], Stmt::Assign(r, _) if r == "x"));
    }

    #[test]
    fn assign_add() {
        let p = parse_src("@main(): int { %r = add %a, %b ret 0 }");
        assert!(matches!(&p.functions[0].body[0], Stmt::Assign(r, Expr::Add(..)) if r == "r"));
    }

    #[test]
    fn while_loop() {
        let p = parse_src("@main(): int { while (lt %i, 10) { call puts(\"x\") } ret 0 }");
        assert!(matches!(&p.functions[0].body[0], Stmt::While(..)));
    }

    #[test]
    fn set_field() {
        let p = parse_src("@main(): int { set %p.age = const 1 ret 0 }");
        assert!(
            matches!(&p.functions[0].body[0], Stmt::SetField(r, f, _) if r == "p" && f == "age")
        );
    }

    #[test]
    fn field_access_expr() {
        let p = parse_src("@main(): int { %v = %p.name ret 0 }");
        assert!(
            matches!(&p.functions[0].body[0], Stmt::Assign(_, Expr::Field(r, f)) if r == "p" && f == "name")
        );
    }

    #[test]
    fn alloc_expr() {
        let p = parse_src("@main(): int { %buf = alloc 1024 ret 0 }");
        assert!(matches!(
            &p.functions[0].body[0],
            Stmt::Assign(_, Expr::Alloc(_))
        ));
    }

    #[test]
    fn named_constant_read() {
        let p = parse_src("@main(): int { %m = READ ret 0 }");
        assert!(matches!(&p.functions[0].body[0], Stmt::Assign(_, Expr::Named(n)) if n == "READ"));
    }

    #[test]
    fn struct_definition() {
        let p = parse_src("struct Person { name: string age: int }");
        assert_eq!(p.structs.len(), 1);
        assert_eq!(p.structs[0].name, "Person");
        assert_eq!(p.structs[0].fields.len(), 2);
        assert_eq!(p.structs[0].fields[0], ("name".into(), Ty::Str));
        assert_eq!(p.structs[0].fields[1], ("age".into(), Ty::Int));
    }

    #[test]
    fn struct_literal_in_assign() {
        let p = parse_src(r#"@main(): int { %p = Person { name: "Alice" age: 25 } ret 0 }"#);
        assert!(matches!(
            &p.functions[0].body[0],
            Stmt::Assign(_, Expr::StructLit(..))
        ));
    }

    #[test]
    fn parses_simple_bear() {
        let src = r#"
@other_func: void {
    call puts("here i go, doing some thing")
}
@main(): int {
    %0 = const 10
    call puts(%0)
    %1 = const "Hello, world."
    call puts(%1)
    call puts("Hi there.")
    call other_func
    ret 0
}
"#;
        let p = parse_src(src);
        assert_eq!(p.functions.len(), 2);
        assert_eq!(p.functions[0].name, "other_func");
        assert_eq!(p.functions[1].name, "main");
        assert_eq!(p.functions[1].body.len(), 7);
    }

    #[test]
    fn parses_loop_bear() {
        let src = r#"
@main(): int {
    %i = const 0
    while (lt %i, 10) {
        call puts("looping")
        %i = add %i, 1
    }
    ret 0
}
"#;
        let p = parse_src(src);
        assert_eq!(p.functions[0].body.len(), 3);
        assert!(matches!(&p.functions[0].body[1], Stmt::While(..)));
    }

    #[test]
    fn parses_structs_bear() {
        let src = r#"
struct Person {
    name: string
    age: int
}
@main(): int {
    %p = Person { name: "Alice" age: 25 }
    call puts(%p.name)
    set %p.age = add %p.age, 1
    call puts(%p.age)
    ret 0
}
"#;
        let p = parse_src(src);
        assert_eq!(p.structs.len(), 1);
        assert_eq!(p.functions.len(), 1);
    }

    #[test]
    fn unknown_top_level_token_is_error() {
        let tokens = tokenize("42").unwrap();
        assert!(parse(tokens).is_err());
    }
}
