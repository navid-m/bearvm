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
