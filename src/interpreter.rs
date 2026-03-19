use crate::ast::*;
use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};

#[derive(Debug, Clone)]
pub enum Value {
    Int(i64),
    Str(String),
    Bool(bool),
    Ptr(Vec<u8>),
    File(i64),
    Void,
    Struct(String, HashMap<String, Value>),
}

impl std::fmt::Display for Value {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Value::Int(n) => write!(f, "{n}"),
            Value::Str(s) => write!(f, "{s}"),
            Value::Bool(b) => write!(f, "{b}"),
            Value::Ptr(_) => write!(f, "<ptr>"),
            Value::File(fd) => write!(f, "<fd:{fd}>"),
            Value::Void => write!(f, ""),
            Value::Struct(name, fields) => {
                write!(f, "{name} {{")?;
                for (k, v) in fields {
                    write!(f, " {k}: {v}")?;
                }
                write!(f, " }}")
            }
        }
    }
}

struct Vm<'a> {
    /// The program itself
    program: &'a Program,

    /// The open file handles
    files: Vec<Option<FileHandle>>,
}

enum FileHandle {
    Read(File),
    Write(File),
}

impl<'a> Vm<'a> {
    fn new(program: &'a Program) -> Self {
        Vm {
            program,
            files: Vec::new(),
        }
    }

    fn find_func(&self, name: &str) -> Option<&Function> {
        self.program.functions.iter().find(|f| f.name == name)
    }

    fn alloc_file(&mut self, handle: FileHandle) -> i64 {
        for (i, slot) in self.files.iter_mut().enumerate() {
            if slot.is_none() {
                *slot = Some(handle);
                return i as i64;
            }
        }
        self.files.push(Some(handle));
        (self.files.len() - 1) as i64
    }

    fn eval_expr(&mut self, expr: &Expr, env: &HashMap<String, Value>) -> Result<Value, String> {
        match expr {
            Expr::Int(n) => Ok(Value::Int(*n)),
            Expr::Str(s) => Ok(Value::Str(s.clone())),
            Expr::Reg(r) => env
                .get(r)
                .cloned()
                .ok_or_else(|| format!("Undefined register %{r}")),
            Expr::Field(r, field) => match env.get(r) {
                Some(Value::Struct(_, fields)) => fields
                    .get(field)
                    .cloned()
                    .ok_or_else(|| format!("No field '{field}' on %{r}")),
                Some(v) => Err(format!("%{r} is not a struct (got {v:?})")),
                None => Err(format!("Undefined register %{r}")),
            },
            Expr::Const(inner) => self.eval_expr(inner, env),
            Expr::Add(a, b) => {
                let av = self.eval_expr(a, env)?;
                let bv = self.eval_expr(b, env)?;
                match (av, bv) {
                    (Value::Int(x), Value::Int(y)) => Ok(Value::Int(x + y)),
                    (a, b) => Err(format!("add: type mismatch {a:?} + {b:?}")),
                }
            }
            Expr::Sub(a, b) => {
                let av = self.eval_expr(a, env)?;
                let bv = self.eval_expr(b, env)?;
                match (av, bv) {
                    (Value::Int(x), Value::Int(y)) => Ok(Value::Int(x - y)),
                    (a, b) => Err(format!("sub: type mismatch {a:?} - {b:?}")),
                }
            }
            Expr::Mul(a, b) => {
                let av = self.eval_expr(a, env)?;
                let bv = self.eval_expr(b, env)?;
                match (av, bv) {
                    (Value::Int(x), Value::Int(y)) => Ok(Value::Int(x * y)),
                    (a, b) => Err(format!("mul: type mismatch {a:?} * {b:?}")),
                }
            }
            Expr::Div(a, b) => {
                let av = self.eval_expr(a, env)?;
                let bv = self.eval_expr(b, env)?;
                match (av, bv) {
                    (Value::Int(x), Value::Int(y)) => {
                        if y == 0 {
                            return Err("Division by zero".into());
                        }
                        Ok(Value::Int(x / y))
                    }
                    (a, b) => Err(format!("div: type mismatch {a:?} / {b:?}")),
                }
            }
            Expr::Lt(a, b) => {
                let av = self.eval_expr(a, env)?;
                let bv = self.eval_expr(b, env)?;
                match (av, bv) {
                    (Value::Int(x), Value::Int(y)) => Ok(Value::Bool(x < y)),
                    (a, b) => Err(format!("lt: type mismatch {a:?} < {b:?}")),
                }
            }
            Expr::Gt(a, b) => {
                let av = self.eval_expr(a, env)?;
                let bv = self.eval_expr(b, env)?;
                match (av, bv) {
                    (Value::Int(x), Value::Int(y)) => Ok(Value::Bool(x > y)),
                    (a, b) => Err(format!("gt: type mismatch {a:?} > {b:?}")),
                }
            }
            Expr::Eq(a, b) => {
                let av = self.eval_expr(a, env)?;
                let bv = self.eval_expr(b, env)?;
                match (av, bv) {
                    (Value::Int(x), Value::Int(y)) => Ok(Value::Bool(x == y)),
                    (Value::Str(x), Value::Str(y)) => Ok(Value::Bool(x == y)),
                    (a, b) => Err(format!("eq: type mismatch {a:?} == {b:?}")),
                }
            }
            Expr::Alloc(size_expr) => {
                let size = match self.eval_expr(size_expr, env)? {
                    Value::Int(n) => n as usize,
                    v => return Err(format!("alloc: expected int size, got {v:?}")),
                };
                Ok(Value::Ptr(vec![0u8; size]))
            }
            Expr::StructLit(name, field_exprs) => {
                let mut fields = HashMap::new();
                for (fname, fexpr) in field_exprs {
                    let val = self.eval_expr(fexpr, env)?;
                    fields.insert(fname.clone(), val);
                }
                Ok(Value::Struct(name.clone(), fields))
            }
            Expr::Named(name) => match name.as_str() {
                "READ" => Ok(Value::Int(0)),
                "WRITE" => Ok(Value::Int(1)),
                _ => Err(format!("Unknown named constant: {name}")),
            },
            Expr::Call(name, args) => self.call_func(name, args, env),
        }
    }

    fn call_func(
        &mut self,
        name: &str,
        arg_exprs: &[Expr],
        env: &HashMap<String, Value>,
    ) -> Result<Value, String> {
        let mut args = Vec::new();
        for a in arg_exprs {
            args.push(self.eval_expr(a, env)?);
        }

        match name {
            "puts" => {
                for a in &args {
                    println!("{a}");
                }
                Ok(Value::Void)
            }
            "open" => {
                let path = match args.get(0) {
                    Some(Value::Str(s)) => s.clone(),
                    _ => return Err("open: first arg must be a string path".into()),
                };
                let mode = match args.get(1) {
                    Some(Value::Int(0)) => "read",
                    Some(Value::Int(1)) => "write",
                    _ => return Err("open: second arg must be READ or WRITE".into()),
                };
                let fd = if mode == "read" {
                    let f = File::open(&path).map_err(|e| format!("open: {e}"))?;
                    self.alloc_file(FileHandle::Read(f))
                } else {
                    let f = OpenOptions::new()
                        .write(true)
                        .create(true)
                        .truncate(true)
                        .open(&path)
                        .map_err(|e| format!("open: {e}"))?;
                    self.alloc_file(FileHandle::Write(f))
                };
                Ok(Value::File(fd))
            }
            "read" => {
                let fd = match args.get(0) {
                    Some(Value::File(n)) => *n as usize,
                    _ => return Err("read: first arg must be a file handle".into()),
                };
                let size = match args.get(2) {
                    Some(Value::Int(n)) => *n as usize,
                    _ => return Err("read: third arg must be size".into()),
                };
                let mut buf = vec![0u8; size];
                let n = match self.files.get_mut(fd).and_then(|s| s.as_mut()) {
                    Some(FileHandle::Read(f)) => {
                        f.read(&mut buf).map_err(|e| format!("read: {e}"))?
                    }
                    _ => return Err("read: invalid file handle".into()),
                };
                buf.truncate(n);
                Ok(Value::Str(String::from_utf8_lossy(&buf).into_owned()))
            }
            "write" => {
                let fd = match args.get(0) {
                    Some(Value::File(n)) => *n as usize,
                    _ => return Err("write: first arg must be a file handle".into()),
                };
                let data = match args.get(1) {
                    Some(Value::Str(s)) => s.as_bytes().to_vec(),
                    Some(Value::Ptr(b)) => b.clone(),
                    _ => return Err("write: second arg must be string or ptr".into()),
                };
                match self.files.get_mut(fd).and_then(|s| s.as_mut()) {
                    Some(FileHandle::Write(f)) => {
                        f.write_all(&data).map_err(|e| format!("write: {e}"))?
                    }
                    _ => return Err("write: invalid file handle for writing".into()),
                }
                Ok(Value::Int(data.len() as i64))
            }
            "close" => {
                let fd = match args.get(0) {
                    Some(Value::File(n)) => *n as usize,
                    _ => return Err("close: arg must be a file handle".into()),
                };
                if fd < self.files.len() {
                    self.files[fd] = None;
                }
                Ok(Value::Void)
            }
            _ => {
                let func = self
                    .program
                    .functions
                    .iter()
                    .find(|f| f.name == name)
                    .ok_or_else(|| format!("Undefined function: {name}"))?
                    .clone();

                let mut new_env: HashMap<String, Value> = HashMap::new();
                for ((pname, _), val) in func.params.iter().zip(args.into_iter()) {
                    new_env.insert(pname.clone(), val);
                }

                match self.exec_body(&func.body, &mut new_env)? {
                    Some(v) => Ok(v),
                    None => Ok(Value::Void),
                }
            }
        }
    }

    /// Returns Some(value) on ret, None if body falls through
    fn exec_body(
        &mut self,
        stmts: &[Stmt],
        env: &mut HashMap<String, Value>,
    ) -> Result<Option<Value>, String> {
        for stmt in stmts {
            if let Some(v) = self.exec_stmt(stmt, env)? {
                return Ok(Some(v));
            }
        }
        Ok(None)
    }

    fn exec_stmt(
        &mut self,
        stmt: &Stmt,
        env: &mut HashMap<String, Value>,
    ) -> Result<Option<Value>, String> {
        match stmt {
            Stmt::Assign(reg, expr) => {
                let val = self.eval_expr(expr, env)?;
                env.insert(reg.clone(), val);
                Ok(None)
            }
            Stmt::SetField(reg, field, expr) => {
                let val = self.eval_expr(expr, env)?;
                match env.get_mut(reg) {
                    Some(Value::Struct(_, fields)) => {
                        fields.insert(field.clone(), val);
                    }
                    _ => return Err(format!("set: %{reg} is not a struct")),
                }
                Ok(None)
            }
            Stmt::Call(name, args) => {
                self.call_func(name, args, &env.clone())?;
                Ok(None)
            }
            Stmt::Ret(expr) => {
                let val = self.eval_expr(expr, env)?;
                Ok(Some(val))
            }
            Stmt::While(cond, body) => {
                loop {
                    let cv = self.eval_expr(cond, env)?;
                    match cv {
                        Value::Bool(false) => break,
                        Value::Bool(true) => {}
                        Value::Int(0) => break,
                        Value::Int(_) => {}
                        v => return Err(format!("while: condition must be bool, got {v:?}")),
                    }
                    if let Some(v) = self.exec_body(body, env)? {
                        return Ok(Some(v));
                    }
                }
                Ok(None)
            }
        }
    }
}

pub fn run(program: &Program) -> Result<(), String> {
    let mut vm = Vm::new(program);
    let main = vm
        .find_func("main")
        .ok_or("No @main function found")?
        .clone();

    let mut env = HashMap::new();
    vm.exec_body(&main.body, &mut env)?;
    Ok(())
}
