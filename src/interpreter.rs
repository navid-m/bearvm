use crate::ast::*;
use rustc_hash::FxHashMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};

const STDOUT_BUF_SIZE: usize = 65536;
struct StdoutBuf {
    buf: [u8; STDOUT_BUF_SIZE],
    pos: usize,
}

impl StdoutBuf {
    const fn new() -> Self {
        StdoutBuf {
            buf: [0u8; STDOUT_BUF_SIZE],
            pos: 0,
        }
    }

    #[inline]
    fn flush(&mut self) {
        if self.pos == 0 {
            return;
        }
        use std::io::Write as _;
        let _ = std::io::stdout().write_all(&self.buf[..self.pos]);
        self.pos = 0;
    }

    #[inline]
    fn write(&mut self, s: &[u8]) {
        if self.pos + s.len() > STDOUT_BUF_SIZE {
            self.flush();
        }
        if s.len() > STDOUT_BUF_SIZE {
            use std::io::Write as _;
            let _ = std::io::stdout().write_all(s);
            return;
        }
        unsafe {
            std::ptr::copy_nonoverlapping(s.as_ptr(), self.buf.as_mut_ptr().add(self.pos), s.len());
        }
        self.pos += s.len();
    }
}

/// Stack frame — uses a fixed-size array for small functions to avoid heap allocation.
const SMALL_FRAME: usize = 64;
enum Frame {
    Small(Box<[Value; SMALL_FRAME]>, usize),
    Heap(Vec<Value>),
}

impl Frame {
    #[inline]
    fn new(n: usize) -> Self {
        if n <= SMALL_FRAME {
            let arr = vec![Value::Void; SMALL_FRAME].into_boxed_slice();
            let arr = unsafe { Box::from_raw(Box::into_raw(arr) as *mut [Value; SMALL_FRAME]) };
            Frame::Small(arr, n)
        } else {
            Frame::Heap(vec![Value::Void; n])
        }
    }

    #[inline(always)]
    fn as_slice_mut(&mut self) -> &mut [Value] {
        match self {
            Frame::Small(arr, n) => &mut arr[..*n],
            Frame::Heap(v) => v.as_mut_slice(),
        }
    }
}

#[derive(Debug, Clone)]
pub enum Value {
    Int(i64),
    Str(String),
    Bool(bool),
    Ptr(Vec<u8>),
    File(i64),
    Void,
    Struct(String, FxHashMap<String, Value>),
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

#[derive(Clone, Copy)]
enum Builtin {
    Puts,
    Flush,
    Open,
    Read,
    Write,
    Close,
}

#[inline(always)]
fn lookup_builtin(name: &str) -> Option<Builtin> {
    match name {
        "puts" => Some(Builtin::Puts),
        "flush" => Some(Builtin::Flush),
        "open" => Some(Builtin::Open),
        "read" => Some(Builtin::Read),
        "write" => Some(Builtin::Write),
        "close" => Some(Builtin::Close),
        _ => None,
    }
}

enum FileHandle {
    Read(File),
    Write(File),
}

struct Vm<'a> {
    /// The program itself.
    program: &'a Program,

    /// Pre-built function name -> index map; eliminates O(n) linear scan per call.
    func_index: FxHashMap<&'a str, usize>,

    /// Associated file handles.
    files: Vec<Option<FileHandle>>,

    /// The standard output buffer.
    stdout: StdoutBuf,
}

impl<'a> Vm<'a> {
    fn new(program: &'a Program) -> Self {
        let mut func_index: FxHashMap<&'a str, usize> = FxHashMap::default();
        func_index.reserve(program.functions.len());
        for (i, f) in program.functions.iter().enumerate() {
            func_index.insert(f.name.as_str(), i);
        }
        Vm {
            program,
            func_index,
            files: Vec::new(),
            stdout: StdoutBuf::new(),
        }
    }

    #[inline]
    fn find_func(&self, name: &str) -> Option<&Function> {
        self.func_index
            .get(name)
            .map(|&i| &self.program.functions[i])
    }

    #[inline]
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

    #[inline]
    fn print_value(&mut self, val: &Value) {
        match val {
            Value::Int(n) => {
                let mut tmp = itoa::Buffer::new();
                self.stdout.write(tmp.format(*n).as_bytes());
                self.stdout.write(b"\n");
            }
            Value::Str(s) => {
                self.stdout.write(s.as_bytes());
                self.stdout.write(b"\n");
            }
            Value::Bool(b) => {
                self.stdout.write(if *b { b"true\n" } else { b"false\n" });
            }
            Value::Ptr(_) => self.stdout.write(b"<ptr>\n"),
            Value::File(fd) => {
                let mut tmp = itoa::Buffer::new();
                self.stdout.write(b"<fd:");
                self.stdout.write(tmp.format(*fd).as_bytes());
                self.stdout.write(b">\n");
            }
            Value::Void => {}
            Value::Struct(name, _) => {
                self.stdout.write(name.as_bytes());
                self.stdout.write(b" { ... }\n");
            }
        }
    }

    /// Fast path: evaluate an expression expected to produce an i64.
    /// Avoids boxing the result into Value for the common arithmetic/register case.
    #[inline(always)]
    fn eval_int(&mut self, expr: &Expr, env: &[Value]) -> Result<i64, String> {
        match expr {
            Expr::Int(n) => Ok(*n),
            Expr::Reg(r) => match unsafe { env.get_unchecked(*r as usize) } {
                Value::Int(n) => Ok(*n),
                v => Err(format!("expected int, got {v:?}")),
            },
            Expr::Const(inner) => self.eval_int(inner, env),
            _ => match self.eval_expr(expr, env)? {
                Value::Int(n) => Ok(n),
                v => Err(format!("expected int, got {v:?}")),
            },
        }
    }

    #[inline]
    fn eval_expr(&mut self, expr: &Expr, env: &[Value]) -> Result<Value, String> {
        match expr {
            Expr::Int(n) => Ok(Value::Int(*n)),
            Expr::Str(s) => Ok(Value::Str(s.clone())),
            Expr::Reg(r) => Ok(unsafe { env.get_unchecked(*r as usize) }.clone()),
            Expr::Field(r, field) => match unsafe { env.get_unchecked(*r as usize) } {
                Value::Struct(_, fields) => fields
                    .get(field)
                    .cloned()
                    .ok_or_else(|| format!("No field '{field}'")),
                v => Err(format!("not a struct (got {v:?})")),
            },
            Expr::Const(inner) => self.eval_expr(inner, env),
            Expr::Add(a, b) => Ok(Value::Int(
                self.eval_int(a, env)?.wrapping_add(self.eval_int(b, env)?),
            )),
            Expr::Sub(a, b) => Ok(Value::Int(
                self.eval_int(a, env)?.wrapping_sub(self.eval_int(b, env)?),
            )),
            Expr::Mul(a, b) => Ok(Value::Int(
                self.eval_int(a, env)?.wrapping_mul(self.eval_int(b, env)?),
            )),
            Expr::Div(a, b) => {
                let b = self.eval_int(b, env)?;
                if b == 0 {
                    return Err("Division by zero".into());
                }
                Ok(Value::Int(self.eval_int(a, env)? / b))
            }
            Expr::Lt(a, b) => Ok(Value::Bool(self.eval_int(a, env)? < self.eval_int(b, env)?)),
            Expr::Gt(a, b) => Ok(Value::Bool(self.eval_int(a, env)? > self.eval_int(b, env)?)),
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
                let mut fields = FxHashMap::default();
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
        env: &[Value],
    ) -> Result<Value, String> {
        const MAX_STACK_ARGS: usize = 32;
        let argc = arg_exprs.len();
        let mut args_buf: [std::mem::MaybeUninit<Value>; MAX_STACK_ARGS] =
            unsafe { std::mem::MaybeUninit::uninit().assume_init() };

        if argc > MAX_STACK_ARGS {
            return Err("Too many arguments (> 32)".into());
        }
        for (i, a) in arg_exprs.iter().enumerate() {
            args_buf[i].write(self.eval_expr(a, env)?);
        }
        let args: &[Value] =
            unsafe { std::slice::from_raw_parts(args_buf.as_ptr() as *const Value, argc) };

        if let Some(builtin) = lookup_builtin(name) {
            let result = self.exec_builtin(builtin, args);
            for i in 0..argc {
                unsafe { args_buf[i].assume_init_drop() };
            }
            return result;
        }

        let func_idx = *self
            .func_index
            .get(name)
            .ok_or_else(|| format!("Undefined function: {name}"))?;

        let n_regs = self.program.functions[func_idx].n_regs as usize;
        let param_count = self.program.functions[func_idx].params.len();

        let mut frame = Frame::new(n_regs);
        let frame_slice = frame.as_slice_mut();

        for i in 0..param_count {
            let idx = self.program.functions[func_idx].params[i].2 as usize;
            frame_slice[idx] = unsafe { std::ptr::read(args_buf[i].as_ptr()) };
        }
        for i in param_count..argc {
            unsafe { args_buf[i].assume_init_drop() };
        }

        let body_ptr: *const Vec<Stmt> = &self.program.functions[func_idx].body as *const Vec<Stmt>;
        let body: &[Stmt] = unsafe { (*body_ptr).as_slice() };

        match self.exec_body(body, frame.as_slice_mut())? {
            Some(v) => Ok(v),
            None => Ok(Value::Void),
        }
    }

    #[inline]
    fn exec_builtin(&mut self, builtin: Builtin, args: &[Value]) -> Result<Value, String> {
        match builtin {
            Builtin::Puts => {
                for a in args {
                    self.print_value(a);
                }
                self.stdout.flush();
                Ok(Value::Void)
            }
            Builtin::Flush => {
                self.stdout.flush();
                Ok(Value::Void)
            }
            Builtin::Open => {
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
            Builtin::Read => {
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
            Builtin::Write => {
                let fd = match args.get(0) {
                    Some(Value::File(n)) => *n as usize,
                    _ => return Err("write: first arg must be a file handle".into()),
                };
                let data: Vec<u8> = match args.get(1) {
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
            Builtin::Close => {
                let fd = match args.get(0) {
                    Some(Value::File(n)) => *n as usize,
                    _ => return Err("close: arg must be a file handle".into()),
                };
                if fd < self.files.len() {
                    self.files[fd] = None;
                }
                Ok(Value::Void)
            }
        }
    }

    #[inline]
    fn exec_body(&mut self, stmts: &[Stmt], env: &mut [Value]) -> Result<Option<Value>, String> {
        for stmt in stmts {
            if let Some(v) = self.exec_stmt(stmt, env)? {
                return Ok(Some(v));
            }
        }
        Ok(None)
    }

    #[inline]
    fn exec_stmt(&mut self, stmt: &Stmt, env: &mut [Value]) -> Result<Option<Value>, String> {
        match stmt {
            Stmt::Assign(reg, expr) => {
                let val = self.eval_expr(expr, env)?;
                *unsafe { env.get_unchecked_mut(*reg as usize) } = val;
                Ok(None)
            }
            Stmt::SetField(reg, field, expr) => {
                let val = self.eval_expr(expr, env)?;
                match unsafe { env.get_unchecked_mut(*reg as usize) } {
                    Value::Struct(_, fields) => {
                        fields.insert(field.clone(), val);
                    }
                    _ => return Err(format!("set: register is not a struct")),
                }
                Ok(None)
            }
            Stmt::Call(name, args) => {
                self.call_func(name, args, env)?;
                Ok(None)
            }
            Stmt::Ret(expr) => {
                let val = self.eval_expr(expr, env)?;
                Ok(Some(val))
            }
            Stmt::While(cond, body) => {
                loop {
                    let keep = match cond {
                        Expr::Lt(a, b) => self.eval_int(a, env)? < self.eval_int(b, env)?,
                        Expr::Gt(a, b) => self.eval_int(a, env)? > self.eval_int(b, env)?,
                        _ => match self.eval_expr(cond, env)? {
                            Value::Bool(b) => b,
                            Value::Int(n) => n != 0,
                            v => return Err(format!("while: condition must be bool, got {v:?}")),
                        },
                    };
                    if !keep {
                        break;
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
    let main = vm.find_func("main").ok_or("No @main function found")?;
    let n_regs = main.n_regs as usize;
    let mut env: Vec<Value> = vec![Value::Void; n_regs];
    let body_ptr: *const Vec<Stmt> = &main.body as *const Vec<Stmt>;
    let body: &[Stmt] = unsafe { (*body_ptr).as_slice() };

    vm.exec_body(body, &mut env)?;
    vm.stdout.flush();
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::{lexer::tokenize, parser::parse};

    fn run_src(src: &str) -> Result<(), String> {
        let tokens = tokenize(src).unwrap();
        let program = parse(tokens).unwrap();
        run(&program)
    }

    fn eval_main(src: &str) -> Value {
        let tokens = tokenize(src).unwrap();
        let program = parse(tokens).unwrap();
        let mut vm = Vm::new(&program);
        let main = vm.find_func("main").unwrap();
        let n_regs = main.n_regs as usize;
        let mut env: Vec<Value> = vec![Value::Void; n_regs];
        let body_ptr: *const Vec<Stmt> = &main.body as *const Vec<Stmt>;
        let body: &[Stmt] = unsafe { (*body_ptr).as_slice() };
        vm.exec_body(body, &mut env).unwrap().unwrap_or(Value::Void)
    }

    #[test]
    fn ret_integer() {
        let v = eval_main("@main(): int { ret 42 }");
        assert!(matches!(v, Value::Int(42)));
    }

    #[test]
    fn const_and_ret() {
        let v = eval_main("@main(): int { %x = const 7 ret %x }");
        assert!(matches!(v, Value::Int(7)));
    }

    #[test]
    fn arithmetic_add() {
        let v = eval_main("@main(): int { %r = add 3, 4 ret %r }");
        assert!(matches!(v, Value::Int(7)));
    }

    #[test]
    fn arithmetic_sub() {
        let v = eval_main("@main(): int { %r = sub 10, 3 ret %r }");
        assert!(matches!(v, Value::Int(7)));
    }

    #[test]
    fn arithmetic_mul() {
        let v = eval_main("@main(): int { %r = mul 3, 4 ret %r }");
        assert!(matches!(v, Value::Int(12)));
    }

    #[test]
    fn arithmetic_div() {
        let v = eval_main("@main(): int { %r = div 12, 4 ret %r }");
        assert!(matches!(v, Value::Int(3)));
    }

    #[test]
    fn div_by_zero_is_error() {
        let tokens = tokenize("@main(): int { %r = div 1, 0 ret %r }").unwrap();
        let program = parse(tokens).unwrap();
        let mut vm = Vm::new(&program);
        let main = vm.find_func("main").unwrap();
        let n_regs = main.n_regs as usize;
        let mut env: Vec<Value> = vec![Value::Void; n_regs];
        let body_ptr: *const Vec<Stmt> = &main.body as *const Vec<Stmt>;
        let body: &[Stmt] = unsafe { (*body_ptr).as_slice() };
        assert!(vm.exec_body(body, &mut env).is_err());
    }

    #[test]
    fn comparison_lt_true() {
        let v = eval_main("@main(): int { %r = lt 3, 5 ret %r }");
        assert!(matches!(v, Value::Bool(true)));
    }

    #[test]
    fn comparison_lt_false() {
        let v = eval_main("@main(): int { %r = lt 5, 3 ret %r }");
        assert!(matches!(v, Value::Bool(false)));
    }

    #[test]
    fn comparison_gt() {
        let v = eval_main("@main(): int { %r = gt 5, 3 ret %r }");
        assert!(matches!(v, Value::Bool(true)));
    }

    #[test]
    fn comparison_eq_ints() {
        let v = eval_main("@main(): int { %r = eq 4, 4 ret %r }");
        assert!(matches!(v, Value::Bool(true)));
    }

    #[test]
    fn while_loop_counts() {
        let v =
            eval_main("@main(): int { %i = const 0 while (lt %i, 5) { %i = add %i, 1 } ret %i }");
        assert!(matches!(v, Value::Int(5)));
    }

    #[test]
    fn call_user_function() {
        let src = r#"
@double(%x: int): int { ret mul %x, 2 }
@main(): int { %r = call double(21) ret %r }
"#;
        let v = eval_main(src);
        assert!(matches!(v, Value::Int(42)));
    }

    #[test]
    fn struct_field_access() {
        let src = r#"
struct Point { x: int y: int }
@main(): int {
    %p = Point { x: 10 y: 20 }
    %v = %p.x
    ret %v
}
"#;
        let v = eval_main(src);
        assert!(matches!(v, Value::Int(10)));
    }

    #[test]
    fn struct_set_field() {
        let src = r#"
struct Point { x: int y: int }
@main(): int {
    %p = Point { x: 1 y: 2 }
    set %p.x = const 99
    %v = %p.x
    ret %v
}
"#;
        let v = eval_main(src);
        assert!(matches!(v, Value::Int(99)));
    }

    #[test]
    fn named_constant_read() {
        let v = eval_main("@main(): int { %m = READ ret %m }");
        assert!(matches!(v, Value::Int(0)));
    }

    #[test]
    fn named_constant_write() {
        let v = eval_main("@main(): int { %m = WRITE ret %m }");
        assert!(matches!(v, Value::Int(1)));
    }

    #[test]
    fn alloc_returns_ptr() {
        let v = eval_main("@main(): int { %buf = alloc 64 ret 0 }");
        assert!(matches!(v, Value::Int(0)));
    }

    #[test]
    fn no_main_is_error() {
        let tokens = tokenize("@other: void { ret 0 }").unwrap();
        let program = parse(tokens).unwrap();
        assert!(run(&program).is_err());
    }

    #[test]
    fn undefined_register_is_error() {
        let tokens = tokenize("@main(): int { %x = const 1 ret %x }").unwrap();
        let program = parse(tokens).unwrap();
        assert!(run(&program).is_ok());
    }

    #[test]
    fn simple_bear_runs() {
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
        assert!(run_src(src).is_ok());
    }

    #[test]
    fn loop_bear_runs() {
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
        assert!(run_src(src).is_ok());
    }
}
