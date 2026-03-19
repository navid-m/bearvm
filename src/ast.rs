/// Top-level program
#[derive(Debug, Clone)]
pub struct Program {
    pub structs: Vec<StructDef>,
    pub functions: Vec<Function>,
}

/// struct Foo { field: type, ... }
#[derive(Debug, Clone)]
pub struct StructDef {
    pub name: String,
    pub fields: Vec<(String, Ty)>,
}

/// @name(params): ret_ty { body }
#[derive(Debug, Clone)]
pub struct Function {
    pub name: String,
    pub params: Vec<(String, Ty)>,
    pub ret_ty: Ty,
    pub body: Vec<Stmt>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Ty {
    Int,
    Void,
    Str,
    Bool,
    Named(String),
}

impl std::fmt::Display for Ty {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Ty::Int => write!(f, "int"),
            Ty::Void => write!(f, "void"),
            Ty::Str => write!(f, "string"),
            Ty::Bool => write!(f, "bool"),
            Ty::Named(n) => write!(f, "{n}"),
        }
    }
}

#[derive(Debug, Clone)]
pub enum Stmt {
    /// %r = <expr>
    Assign(String, Expr),

    /// set %r.field = <expr>
    SetField(String, String, Expr),

    /// call <func>(<args>)  — result discarded
    Call(String, Vec<Expr>),

    /// ret <expr>
    Ret(Expr),

    /// while (<cond>) { <body> }
    While(Expr, Vec<Stmt>),
}

#[derive(Debug, Clone)]
pub enum Expr {
    /// integer literal
    Int(i64),

    /// string literal
    Str(String),

    /// register reference %r
    Reg(String),

    /// field access %r.field
    Field(String, String),

    /// const <val>
    Const(Box<Expr>),

    /// add %a, %b
    Add(Box<Expr>, Box<Expr>),

    /// sub %a, %b
    Sub(Box<Expr>, Box<Expr>),

    /// mul %a, %b
    Mul(Box<Expr>, Box<Expr>),

    /// div %a, %b
    Div(Box<Expr>, Box<Expr>),

    /// lt %a, %b
    Lt(Box<Expr>, Box<Expr>),

    /// gt %a, %b
    Gt(Box<Expr>, Box<Expr>),

    /// eq %a, %b
    Eq(Box<Expr>, Box<Expr>),

    /// call <func>(<args>) — result used
    Call(String, Vec<Expr>),

    /// alloc <size>
    Alloc(Box<Expr>),

    /// StructName { field: val, ... }
    StructLit(String, Vec<(String, Expr)>),

    /// named constant like READ, WRITE
    Named(String),
}
