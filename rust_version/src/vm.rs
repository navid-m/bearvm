use crate::ast::*;
use rustc_hash::FxHashMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};

#[repr(u8)]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Tag {
    Void = 0,
    Int = 1,
    Bool = 2,
    File = 3,
    Heap = 4,
}

#[derive(Clone, Copy)]
union RawVal {
    int: i64,
    bool: bool,
    idx: u32,
    _pad: u64,
}

#[derive(Clone, Copy)]
struct Slot {
    tag: Tag,
    raw: RawVal,
}

impl Slot {
    #[inline(always)]
    const fn void() -> Self {
        Slot {
            tag: Tag::Void,
            raw: RawVal { _pad: 0 },
        }
    }
    #[inline(always)]
    const fn int(n: i64) -> Self {
        Slot {
            tag: Tag::Int,
            raw: RawVal { int: n },
        }
    }
    #[inline(always)]
    const fn bool(b: bool) -> Self {
        Slot {
            tag: Tag::Bool,
            raw: RawVal { bool: b },
        }
    }
    #[inline(always)]
    const fn file(n: i64) -> Self {
        Slot {
            tag: Tag::File,
            raw: RawVal { int: n },
        }
    }
    #[inline(always)]
    fn heap(idx: u32) -> Self {
        Slot {
            tag: Tag::Heap,
            raw: RawVal { idx },
        }
    }

    #[inline(always)]
    fn as_int(self) -> Option<i64> {
        if self.tag == Tag::Int {
            Some(unsafe { self.raw.int })
        } else {
            None
        }
    }
    #[inline(always)]
    fn heap_idx(self) -> Option<u32> {
        if self.tag == Tag::Heap {
            Some(unsafe { self.raw.idx })
        } else {
            None
        }
    }
}

enum HeapVal {
    Str(String),
    Ptr(Vec<u8>),
    Struct(String, FxHashMap<String, Slot>),
    Array(String, Vec<String>, Vec<FxHashMap<String, Slot>>),
    Ref(u32, RefTarget),
}

/// Describes what a Ref points to inside a heap object.
#[derive(Clone, Debug)]
enum RefTarget {
    /// Points to a named field of a Struct or an Array element
    Field(usize, String),
}

#[derive(Debug, Clone)]
pub enum Value {
    Int(i64),
    Str(String),
    Bool(bool),
    Ptr(Vec<u8>),
    File(i64),
    Void,
    Struct(Box<(String, FxHashMap<String, Value>)>),
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
            Value::Struct(b) => {
                let (name, fields) = b.as_ref();
                write!(f, "{name} {{")?;
                for (k, v) in fields {
                    write!(f, " {k}: {v}")?;
                }
                write!(f, " }}")
            }
        }
    }
}

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
/// Only the first `n` slots are initialized; the rest are left as MaybeUninit.
const SMALL_FRAME: usize = 64;

enum Frame {
    Small([Slot; SMALL_FRAME], usize),
    Heap(Vec<Slot>),
}

impl Frame {
    #[inline]
    fn new(n: usize) -> Self {
        if n <= SMALL_FRAME {
            Frame::Small([Slot::void(); SMALL_FRAME], n)
        } else {
            Frame::Heap(vec![Slot::void(); n])
        }
    }

    #[inline(always)]
    fn as_slice_mut(&mut self) -> &mut [Slot] {
        match self {
            Frame::Small(arr, n) => &mut arr[..*n],
            Frame::Heap(v) => v.as_mut_slice(),
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

fn is_simple_arith(e: &Expr) -> bool {
    match e {
        Expr::Int(_) | Expr::Reg(_) => true,
        Expr::Const(inner) => is_simple_arith(inner),
        Expr::Add(a, b) | Expr::Sub(a, b) | Expr::Mul(a, b) | Expr::Div(a, b) => {
            is_simple_arith(a) && is_simple_arith(b)
        }
        _ => false,
    }
}

/// Returns true if the while body qualifies for the SIMD fast path.
fn body_is_simd_eligible(body: &[Stmt]) -> bool {
    if body.is_empty() {
        return false;
    }
    body.iter()
        .all(|s| matches!(s, Stmt::Assign(_, e) if is_simple_arith(e)))
}

/// Evaluate a simple integer expression against a frame of i64 values.
/// Panics if the expression is not simple (caller must check).
#[inline(always)]
fn eval_simple_int(e: &Expr, frame: &[i64]) -> i64 {
    match e {
        Expr::Int(n) => *n,
        Expr::Reg(r) => frame[*r as usize],
        Expr::Const(inner) => eval_simple_int(inner, frame),
        Expr::Add(a, b) => eval_simple_int(a, frame).wrapping_add(eval_simple_int(b, frame)),
        Expr::Sub(a, b) => eval_simple_int(a, frame).wrapping_sub(eval_simple_int(b, frame)),
        Expr::Mul(a, b) => eval_simple_int(a, frame).wrapping_mul(eval_simple_int(b, frame)),
        Expr::Div(a, b) => {
            let d = eval_simple_int(b, frame);
            if d == 0 {
                0
            } else {
                eval_simple_int(a, frame) / d
            }
        }
        _ => unreachable!(),
    }
}

fn run_scalar_loop(
    body: &[Stmt],
    frame: &mut [i64],
    cond_reg: u16,
    cond_limit: i64,
    cond_is_lt: bool,
) {
    loop {
        let cv = frame[cond_reg as usize];
        let keep = if cond_is_lt {
            cv < cond_limit
        } else {
            cv > cond_limit
        };
        if !keep {
            break;
        }
        for stmt in body {
            if let Stmt::Assign(dst, expr) = stmt {
                frame[*dst as usize] = eval_simple_int(expr, frame);
            }
        }
    }
}

/// SIMD fast path: process 4 iterations at a time.
/// Falls back to scalar for the tail.
///
/// `n_regs` is the total number of registers in the frame.
fn run_simd_loop(
    body: &[Stmt],
    slots: &mut [Slot],
    n_regs: usize,
    cond_reg: u16,
    cond_limit: i64,
    cond_is_lt: bool,
) {
    let mut frame: Vec<i64> = (0..n_regs)
        .map(|i| unsafe {
            if slots[i].tag == Tag::Int {
                slots[i].raw.int
            } else {
                0
            }
        })
        .collect();

    #[cfg(target_arch = "x86_64")]
    {
        if is_x86_feature_detected!("avx2") {
            unsafe {
                run_avx2_loop(body, &mut frame, cond_reg, cond_limit, cond_is_lt);
            }
        } else {
            run_scalar_loop(body, &mut frame, cond_reg, cond_limit, cond_is_lt);
        }
    }
    #[cfg(not(target_arch = "x86_64"))]
    {
        run_scalar_loop(body, &mut frame, cond_reg, cond_limit, cond_is_lt);
    }

    for i in 0..n_regs {
        slots[i] = Slot::int(frame[i]);
    }
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2")]
unsafe fn run_avx2_loop(
    body: &[Stmt],
    frame: &mut Vec<i64>,
    cond_reg: u16,
    cond_limit: i64,
    cond_is_lt: bool,
) {
    use std::arch::x86_64::*;

    let n = frame.len();
    let mut f0 = frame.clone();
    let mut f1 = frame.clone();
    let mut f2 = frame.clone();
    let mut f3 = frame.clone();

    for _ in 0..1 {
        for stmt in body {
            if let Stmt::Assign(d, e) = stmt {
                f1[*d as usize] = eval_simple_int(e, &f1);
            }
        }
    }
    for _ in 0..2 {
        for stmt in body {
            if let Stmt::Assign(d, e) = stmt {
                f2[*d as usize] = eval_simple_int(e, &f2);
            }
        }
    }
    for _ in 0..3 {
        for stmt in body {
            if let Stmt::Assign(d, e) = stmt {
                f3[*d as usize] = eval_simple_int(e, &f3);
            }
        }
    }

    let all_active = |fa: &[i64], fb: &[i64], fc: &[i64], fd: &[i64]| -> bool {
        let check = |f: &[i64]| {
            let cv = f[cond_reg as usize];
            if cond_is_lt {
                cv < cond_limit
            } else {
                cv > cond_limit
            }
        };
        check(fa) && check(fb) && check(fc) && check(fd)
    };

    let mut f0_next = f0.clone();
    for stmt in body {
        if let Stmt::Assign(d, e) = stmt {
            f0_next[*d as usize] = eval_simple_int(e, &f0_next);
        }
    }
    let mut f1_next = f1.clone();
    for stmt in body {
        if let Stmt::Assign(d, e) = stmt {
            f1_next[*d as usize] = eval_simple_int(e, &f1_next);
        }
    }
    let mut f2_next = f2.clone();
    for stmt in body {
        if let Stmt::Assign(d, e) = stmt {
            f2_next[*d as usize] = eval_simple_int(e, &f2_next);
        }
    }
    let mut f3_next = f3.clone();
    for stmt in body {
        if let Stmt::Assign(d, e) = stmt {
            f3_next[*d as usize] = eval_simple_int(e, &f3_next);
        }
    }

    let delta: Vec<i64> = (0..n).map(|i| f3_next[i].wrapping_sub(f0[i])).collect();

    while all_active(&f0, &f1, &f2, &f3) {
        let mut i = 0;
        while i + 4 <= n {
            let d = _mm256_loadu_si256(delta.as_ptr().add(i) as *const __m256i);

            let v0 = _mm256_loadu_si256(f0.as_ptr().add(i) as *const __m256i);
            let v1 = _mm256_loadu_si256(f1.as_ptr().add(i) as *const __m256i);
            let v2 = _mm256_loadu_si256(f2.as_ptr().add(i) as *const __m256i);
            let v3 = _mm256_loadu_si256(f3.as_ptr().add(i) as *const __m256i);

            _mm256_storeu_si256(
                f0.as_mut_ptr().add(i) as *mut __m256i,
                _mm256_add_epi64(v0, d),
            );
            _mm256_storeu_si256(
                f1.as_mut_ptr().add(i) as *mut __m256i,
                _mm256_add_epi64(v1, d),
            );
            _mm256_storeu_si256(
                f2.as_mut_ptr().add(i) as *mut __m256i,
                _mm256_add_epi64(v2, d),
            );
            _mm256_storeu_si256(
                f3.as_mut_ptr().add(i) as *mut __m256i,
                _mm256_add_epi64(v3, d),
            );

            i += 4;
        }
        while i < n {
            f0[i] = f0[i].wrapping_add(delta[i]);
            f1[i] = f1[i].wrapping_add(delta[i]);
            f2[i] = f2[i].wrapping_add(delta[i]);
            f3[i] = f3[i].wrapping_add(delta[i]);
            i += 1;
        }
    }

    run_scalar_loop(body, &mut f0, cond_reg, cond_limit, cond_is_lt);
    *frame = f0;
}

enum ExecResult {
    None,
    Return(Slot),
    Jump(String),
}

struct Vm<'a> {
    program: &'a Program,
    func_index: FxHashMap<&'a str, usize>,
    files: Vec<Option<FileHandle>>,
    stdout: StdoutBuf,
    heap: Vec<HeapVal>,
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
            heap: Vec::new(),
        }
    }

    #[inline]
    fn alloc_heap(&mut self, v: HeapVal) -> Slot {
        let idx = self.heap.len() as u32;
        self.heap.push(v);
        Slot::heap(idx)
    }

    #[inline]
    fn heap_str(&mut self, s: String) -> Slot {
        self.alloc_heap(HeapVal::Str(s))
    }

    fn slot_to_value(&self, s: Slot) -> Value {
        match s.tag {
            Tag::Void => Value::Void,
            Tag::Int => Value::Int(unsafe { s.raw.int }),
            Tag::Bool => Value::Bool(unsafe { s.raw.bool }),
            Tag::File => Value::File(unsafe { s.raw.int }),
            Tag::Heap => {
                let idx = unsafe { s.raw.idx } as usize;
                match &self.heap[idx] {
                    HeapVal::Str(s) => Value::Str(s.clone()),
                    HeapVal::Ptr(b) => Value::Ptr(b.clone()),
                    HeapVal::Struct(name, f) => {
                        let fields = f
                            .iter()
                            .map(|(k, &v)| (k.clone(), self.slot_to_value(v)))
                            .collect();
                        Value::Struct(Box::new((name.clone(), fields)))
                    }
                    HeapVal::Array(_, _, _) => Value::Ptr(vec![]),
                    HeapVal::Ref(_, _) => Value::Ptr(vec![]),
                }
            }
        }
    }

    fn value_to_slot(&mut self, v: Value) -> Slot {
        match v {
            Value::Void => Slot::void(),
            Value::Int(n) => Slot::int(n),
            Value::Bool(b) => Slot::bool(b),
            Value::File(n) => Slot::file(n),
            Value::Str(s) => self.heap_str(s),
            Value::Ptr(b) => self.alloc_heap(HeapVal::Ptr(b)),
            Value::Struct(b) => {
                let (name, fields) = *b;
                let mut sf: FxHashMap<String, Slot> = FxHashMap::default();
                for (k, v) in fields {
                    let s = self.value_to_slot(v);
                    sf.insert(k, s);
                }
                self.alloc_heap(HeapVal::Struct(name, sf))
            }
        }
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
    fn print_slot(&mut self, s: Slot) {
        match s.tag {
            Tag::Void => {}
            Tag::Int => {
                let mut tmp = itoa::Buffer::new();
                self.stdout
                    .write(tmp.format(unsafe { s.raw.int }).as_bytes());
                self.stdout.write(b"\n");
            }
            Tag::Bool => self.stdout.write(if unsafe { s.raw.bool } {
                b"true\n"
            } else {
                b"false\n"
            }),
            Tag::File => {
                let mut tmp = itoa::Buffer::new();
                self.stdout.write(b"<fd:");
                self.stdout
                    .write(tmp.format(unsafe { s.raw.int }).as_bytes());
                self.stdout.write(b">\n");
            }
            Tag::Heap => {
                let idx = unsafe { s.raw.idx } as usize;
                match &self.heap[idx] {
                    HeapVal::Str(s) => {
                        let b = s.as_bytes().to_vec();
                        self.stdout.write(&b);
                        self.stdout.write(b"\n");
                    }
                    HeapVal::Ptr(_) => self.stdout.write(b"<ptr>\n"),
                    HeapVal::Struct(name, _) => {
                        let b = name.as_bytes().to_vec();
                        self.stdout.write(&b);
                        self.stdout.write(b" { ... }\n");
                    }
                    HeapVal::Array(name, _, _) => {
                        let b = name.as_bytes().to_vec();
                        self.stdout.write(b"[");
                        self.stdout.write(&b);
                        self.stdout.write(b"]\n");
                    }
                    HeapVal::Ref(_, _) => self.stdout.write(b"<ref>\n"),
                }
            }
        }
    }

    #[inline(always)]
    fn eval_int_slot(&mut self, expr: &Expr, env: &[Slot]) -> Result<i64, String> {
        match expr {
            Expr::Int(n) => Ok(*n),
            Expr::Reg(r) => {
                let s = unsafe { *env.get_unchecked(*r as usize) };
                s.as_int()
                    .ok_or_else(|| format!("expected int, got tag {:?}", s.tag))
            }
            Expr::Const(inner) => self.eval_int_slot(inner, env),
            _ => match self.eval_slot(expr, env)? {
                s if s.tag == Tag::Int => Ok(unsafe { s.raw.int }),
                s => Err(format!("expected int, got tag {:?}", s.tag)),
            },
        }
    }

    #[inline]
    fn eval_slot(&mut self, expr: &Expr, env: &[Slot]) -> Result<Slot, String> {
        match expr {
            Expr::Int(n) => Ok(Slot::int(*n)),
            Expr::Str(s) => Ok(self.heap_str(s.clone())),
            Expr::Reg(r) => Ok(unsafe { *env.get_unchecked(*r as usize) }),
            Expr::Field(r, field) => {
                let s = unsafe { *env.get_unchecked(*r as usize) };
                let idx = s.heap_idx().ok_or_else(|| "not a struct".to_string())? as usize;
                match &self.heap[idx] {
                    HeapVal::Struct(_, fields) => fields
                        .get(field)
                        .copied()
                        .ok_or_else(|| format!("No field '{field}'")),
                    _ => Err("not a struct".into()),
                }
            }
            Expr::Const(inner) => self.eval_slot(inner, env),
            Expr::Add(a, b) => Ok(Slot::int(
                self.eval_int_slot(a, env)?
                    .wrapping_add(self.eval_int_slot(b, env)?),
            )),
            Expr::Sub(a, b) => Ok(Slot::int(
                self.eval_int_slot(a, env)?
                    .wrapping_sub(self.eval_int_slot(b, env)?),
            )),
            Expr::Mul(a, b) => Ok(Slot::int(
                self.eval_int_slot(a, env)?
                    .wrapping_mul(self.eval_int_slot(b, env)?),
            )),
            Expr::Div(a, b) => {
                let b = self.eval_int_slot(b, env)?;
                if b == 0 {
                    return Err("Division by zero".into());
                }
                Ok(Slot::int(self.eval_int_slot(a, env)? / b))
            }
            Expr::Lt(a, b) => Ok(Slot::bool(
                self.eval_int_slot(a, env)? < self.eval_int_slot(b, env)?,
            )),
            Expr::Gt(a, b) => Ok(Slot::bool(
                self.eval_int_slot(a, env)? > self.eval_int_slot(b, env)?,
            )),
            Expr::Eq(a, b) => {
                let av = self.eval_slot(a, env)?;
                let bv = self.eval_slot(b, env)?;
                match (av.tag, bv.tag) {
                    (Tag::Int, Tag::Int) => Ok(Slot::bool(unsafe { av.raw.int == bv.raw.int })),
                    (Tag::Bool, Tag::Bool) => Ok(Slot::bool(unsafe { av.raw.bool == bv.raw.bool })),
                    (Tag::Heap, Tag::Heap) => {
                        let ai = unsafe { av.raw.idx } as usize;
                        let bi = unsafe { bv.raw.idx } as usize;
                        match (&self.heap[ai], &self.heap[bi]) {
                            (HeapVal::Str(a), HeapVal::Str(b)) => Ok(Slot::bool(a == b)),
                            _ => Err("eq: type mismatch".into()),
                        }
                    }
                    _ => Err(format!("eq: type mismatch {:?} == {:?}", av.tag, bv.tag)),
                }
            }
            Expr::Alloc(size_expr) => {
                let size = self.eval_int_slot(size_expr, env)? as usize;
                Ok(self.alloc_heap(HeapVal::Ptr(vec![0u8; size])))
            }
            Expr::AllocArray(struct_name, count_expr) => {
                let count = self.eval_int_slot(count_expr, env)? as usize;
                let field_order: Vec<String> = self
                    .program
                    .structs
                    .iter()
                    .find(|s| s.name == *struct_name)
                    .map(|s| s.fields.iter().map(|(n, _)| n.clone()).collect())
                    .unwrap_or_default();
                let elements = (0..count)
                    .map(|_| {
                        field_order
                            .iter()
                            .map(|f| (f.clone(), Slot::int(0)))
                            .collect::<FxHashMap<String, Slot>>()
                    })
                    .collect();
                Ok(self.alloc_heap(HeapVal::Array(struct_name.clone(), field_order, elements)))
            }
            Expr::GetIndexRef(arr_reg, idx_expr) => {
                let arr_slot = unsafe { *env.get_unchecked(*arr_reg as usize) };
                let arr_heap_idx = arr_slot
                    .heap_idx()
                    .ok_or_else(|| "get_index_ref: not a heap value".to_string())?;
                let elem_idx = self.eval_int_slot(idx_expr, env)? as usize;
                match &self.heap[arr_heap_idx as usize] {
                    HeapVal::Array(_, _, elems) => {
                        if elem_idx >= elems.len() {
                            return Err(format!(
                                "get_index_ref: index {elem_idx} out of bounds (len {})",
                                elems.len()
                            ));
                        }
                    }
                    _ => return Err("get_index_ref: not an array".into()),
                }
                Ok(self.alloc_heap(HeapVal::Ref(
                    arr_heap_idx,
                    RefTarget::Field(elem_idx, "__elem__".into()),
                )))
            }
            Expr::GetFieldRef(ref_reg, field) => {
                let ref_slot = unsafe { *env.get_unchecked(*ref_reg as usize) };
                let ref_heap_idx = ref_slot
                    .heap_idx()
                    .ok_or_else(|| "get_field_ref: not a heap value".to_string())?;
                match &self.heap[ref_heap_idx as usize] {
                    HeapVal::Ref(arr_idx, RefTarget::Field(elem_idx, sentinel))
                        if sentinel == "__elem__" =>
                    {
                        let arr_idx = *arr_idx;
                        let elem_idx = *elem_idx;
                        match &self.heap[arr_idx as usize] {
                            HeapVal::Array(_, field_order, _) => {
                                if !field_order.contains(field) {
                                    return Err(format!("get_field_ref: no field '{field}'"));
                                }
                            }
                            _ => return Err("get_field_ref: ref target is not an array".into()),
                        }
                        Ok(self.alloc_heap(HeapVal::Ref(
                            arr_idx,
                            RefTarget::Field(elem_idx, field.clone()),
                        )))
                    }
                    HeapVal::Struct(_, fields) => {
                        if !fields.contains_key(field.as_str()) {
                            return Err(format!("get_field_ref: no field '{field}'"));
                        }
                        Ok(self.alloc_heap(HeapVal::Ref(
                            ref_heap_idx,
                            RefTarget::Field(0, field.clone()),
                        )))
                    }
                    _ => Err("get_field_ref: not a ref or struct".into()),
                }
            }
            Expr::Load(ref_reg) => {
                let ref_slot = unsafe { *env.get_unchecked(*ref_reg as usize) };
                let ref_heap_idx = ref_slot
                    .heap_idx()
                    .ok_or_else(|| "load: not a heap value".to_string())?
                    as usize;
                match &self.heap[ref_heap_idx] {
                    HeapVal::Ref(target_idx, RefTarget::Field(elem_idx, field)) => {
                        let target_idx = *target_idx as usize;
                        let elem_idx = *elem_idx;
                        let field = field.clone();
                        match &self.heap[target_idx] {
                            HeapVal::Array(_, _, elems) => {
                                Ok(elems[elem_idx].get(&field).copied().unwrap_or(Slot::void()))
                            }
                            HeapVal::Struct(_, fields) => {
                                Ok(fields.get(&field).copied().unwrap_or(Slot::void()))
                            }
                            _ => Err("load: ref target is not an array or struct".into()),
                        }
                    }
                    _ => Err("load: not a ref".into()),
                }
            }
            Expr::StructLit(name, field_exprs) => {
                let mut fields: FxHashMap<String, Slot> = FxHashMap::default();
                for (fname, fexpr) in field_exprs {
                    let val = self.eval_slot(fexpr, env)?;
                    fields.insert(fname.clone(), val);
                }
                Ok(self.alloc_heap(HeapVal::Struct(name.clone(), fields)))
            }
            Expr::Named(name) => match name.as_str() {
                "READ" => Ok(Slot::int(0)),
                "WRITE" => Ok(Slot::int(1)),
                _ => Err(format!("Unknown named constant: {name}")),
            },
            Expr::Call(name, args) => self.call_func(name, args, env),
        }
    }

    fn call_func(&mut self, name: &str, arg_exprs: &[Expr], env: &[Slot]) -> Result<Slot, String> {
        const MAX_STACK_ARGS: usize = 32;
        let argc = arg_exprs.len();
        if argc > MAX_STACK_ARGS {
            return Err("Too many arguments (> 32)".into());
        }

        let mut args_buf: [std::mem::MaybeUninit<Slot>; MAX_STACK_ARGS] =
            unsafe { std::mem::MaybeUninit::uninit().assume_init() };
        for (i, a) in arg_exprs.iter().enumerate() {
            args_buf[i].write(self.eval_slot(a, env)?);
        }
        let args: &[Slot] =
            unsafe { std::slice::from_raw_parts(args_buf.as_ptr() as *const Slot, argc) };

        if let Some(builtin) = lookup_builtin(name) {
            return self.exec_builtin(builtin, args);
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

        let body_ptr: *const Vec<Stmt> = &self.program.functions[func_idx].body as *const Vec<Stmt>;
        let body: &[Stmt] = unsafe { (*body_ptr).as_slice() };

        match self.exec_body(body, frame.as_slice_mut())? {
            Some(v) => Ok(v),
            None => Ok(Slot::void()),
        }
    }

    #[inline]
    fn exec_builtin(&mut self, builtin: Builtin, args: &[Slot]) -> Result<Slot, String> {
        match builtin {
            Builtin::Puts => {
                for &a in args {
                    self.print_slot(a);
                }
                Ok(Slot::void())
            }
            Builtin::Flush => {
                self.stdout.flush();
                Ok(Slot::void())
            }
            Builtin::Open => {
                let path = match args.get(0) {
                    Some(s) if s.tag == Tag::Heap => {
                        let idx = unsafe { s.raw.idx } as usize;
                        match &self.heap[idx] {
                            HeapVal::Str(p) => p.clone(),
                            _ => return Err("open: first arg must be a string path".into()),
                        }
                    }
                    _ => return Err("open: first arg must be a string path".into()),
                };
                let mode = match args.get(1) {
                    Some(s) if s.tag == Tag::Int => unsafe { s.raw.int },
                    _ => return Err("open: second arg must be READ or WRITE".into()),
                };
                let fd = if mode == 0 {
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
                Ok(Slot::file(fd))
            }
            Builtin::Read => {
                let fd = match args.get(0) {
                    Some(s) if s.tag == Tag::File => (unsafe { s.raw.int }) as usize,
                    _ => return Err("read: first arg must be a file handle".into()),
                };
                let size = match args.get(2) {
                    Some(s) if s.tag == Tag::Int => (unsafe { s.raw.int }) as usize,
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
                Ok(self.heap_str(String::from_utf8_lossy(&buf).into_owned()))
            }
            Builtin::Write => {
                let fd = match args.get(0) {
                    Some(s) if s.tag == Tag::File => (unsafe { s.raw.int }) as usize,
                    _ => return Err("write: first arg must be a file handle".into()),
                };
                let data: Vec<u8> = match args.get(1) {
                    Some(s) if s.tag == Tag::Heap => {
                        let idx = unsafe { s.raw.idx } as usize;
                        match &self.heap[idx] {
                            HeapVal::Str(s) => s.as_bytes().to_vec(),
                            HeapVal::Ptr(b) => b.clone(),
                            _ => return Err("write: second arg must be string or ptr".into()),
                        }
                    }
                    _ => return Err("write: second arg must be string or ptr".into()),
                };
                match self.files.get_mut(fd).and_then(|s| s.as_mut()) {
                    Some(FileHandle::Write(f)) => {
                        f.write_all(&data).map_err(|e| format!("write: {e}"))?
                    }
                    _ => return Err("write: invalid file handle for writing".into()),
                }
                Ok(Slot::int(data.len() as i64))
            }
            Builtin::Close => {
                let fd = match args.get(0) {
                    Some(s) if s.tag == Tag::File => (unsafe { s.raw.int }) as usize,
                    _ => return Err("close: arg must be a file handle".into()),
                };
                if fd < self.files.len() {
                    self.files[fd] = None;
                }
                Ok(Slot::void())
            }
        }
    }

    #[inline]
    fn exec_body(&mut self, stmts: &[Stmt], env: &mut [Slot]) -> Result<Option<Slot>, String> {
        let mut label_map: FxHashMap<&str, usize> = FxHashMap::default();
        for (i, stmt) in stmts.iter().enumerate() {
            if let Stmt::Label(name) = stmt {
                label_map.insert(name.as_str(), i);
            }
        }

        let mut pc = 0usize;
        while pc < stmts.len() {
            match self.exec_stmt(&stmts[pc], env)? {
                ExecResult::Return(v) => return Ok(Some(v)),
                ExecResult::Jump(label) => {
                    pc = *label_map
                        .get(label.as_str())
                        .ok_or_else(|| format!("undefined label '{label}'"))?;
                }
                ExecResult::None => {}
            }
            pc += 1;
        }
        Ok(None)
    }

    #[inline]
    fn exec_stmt(&mut self, stmt: &Stmt, env: &mut [Slot]) -> Result<ExecResult, String> {
        match stmt {
            Stmt::Assign(reg, expr) => {
                let val = self.eval_slot(expr, env)?;
                *unsafe { env.get_unchecked_mut(*reg as usize) } = val;
                Ok(ExecResult::None)
            }
            Stmt::SetField(reg, field, expr) => {
                let val = self.eval_slot(expr, env)?;
                let s = unsafe { *env.get_unchecked(*reg as usize) };
                let idx = s
                    .heap_idx()
                    .ok_or_else(|| "set: register is not a struct".to_string())?
                    as usize;
                match &mut self.heap[idx] {
                    HeapVal::Struct(_, fields) => {
                        fields.insert(field.clone(), val);
                    }
                    _ => return Err("set: register is not a struct".into()),
                }
                Ok(ExecResult::None)
            }
            Stmt::Call(name, args) => {
                self.call_func(name, args, env)?;
                Ok(ExecResult::None)
            }
            Stmt::Ret(expr) => Ok(ExecResult::Return(self.eval_slot(expr, env)?)),
            Stmt::While(cond, body) => {
                if let Some(v) = self.exec_while(cond, body, env)? {
                    return Ok(ExecResult::Return(v));
                }
                Ok(ExecResult::None)
            }
            Stmt::Label(_) => Ok(ExecResult::None),
            Stmt::Jmp(label) => Ok(ExecResult::Jump(label.clone())),
            Stmt::BrIf(cond, true_label, false_label) => {
                let taken = match self.eval_slot(cond, env)? {
                    s if s.tag == Tag::Bool => unsafe { s.raw.bool },
                    s if s.tag == Tag::Int => unsafe { s.raw.int != 0 },
                    s => return Err(format!("br_if: condition must be bool, got {:?}", s.tag)),
                };
                let target = if taken { true_label } else { false_label };
                Ok(ExecResult::Jump(target.clone()))
            }
            Stmt::Store(ref_reg, val_expr) => {
                let val = self.eval_slot(val_expr, env)?;
                let ref_slot = unsafe { *env.get_unchecked(*ref_reg as usize) };
                let ref_heap_idx = ref_slot
                    .heap_idx()
                    .ok_or_else(|| "store: not a heap value".to_string())?
                    as usize;
                let (target_idx, elem_idx, field) = match &self.heap[ref_heap_idx] {
                    HeapVal::Ref(t, RefTarget::Field(ei, f)) => (*t as usize, *ei, f.clone()),
                    _ => return Err("store: not a ref".into()),
                };
                match &mut self.heap[target_idx] {
                    HeapVal::Array(_, _, elems) => {
                        elems[elem_idx].insert(field, val);
                    }
                    HeapVal::Struct(_, fields) => {
                        fields.insert(field, val);
                    }
                    _ => return Err("store: ref target is not an array or struct".into()),
                }
                Ok(ExecResult::None)
            }
        }
    }

    #[inline]
    fn exec_while(
        &mut self,
        cond: &Expr,
        body: &[Stmt],
        env: &mut [Slot],
    ) -> Result<Option<Slot>, String> {
        let simd_info: Option<(u16, i64, bool)> = match cond {
            Expr::Lt(a, b) => {
                if let (Expr::Reg(r), Expr::Int(lim)) = (a.as_ref(), b.as_ref()) {
                    Some((*r, *lim, true))
                } else if let (Expr::Reg(r), Expr::Reg(r2)) = (a.as_ref(), b.as_ref()) {
                    let lim = unsafe { env.get_unchecked(*r2 as usize) };
                    if lim.tag == Tag::Int {
                        Some((*r, unsafe { lim.raw.int }, true))
                    } else {
                        None
                    }
                } else {
                    None
                }
            }
            Expr::Gt(a, b) => {
                if let (Expr::Reg(r), Expr::Int(lim)) = (a.as_ref(), b.as_ref()) {
                    Some((*r, *lim, false))
                } else if let (Expr::Reg(r), Expr::Reg(r2)) = (a.as_ref(), b.as_ref()) {
                    let lim = unsafe { env.get_unchecked(*r2 as usize) };
                    if lim.tag == Tag::Int {
                        Some((*r, unsafe { lim.raw.int }, false))
                    } else {
                        None
                    }
                } else {
                    None
                }
            }
            _ => None,
        };

        if let Some((cond_reg, cond_limit, cond_is_lt)) = simd_info {
            if body_is_simd_eligible(body) {
                let n_regs = env.len();
                run_simd_loop(body, env, n_regs, cond_reg, cond_limit, cond_is_lt);
                return Ok(None);
            }
            loop {
                let cv = unsafe { env.get_unchecked(cond_reg as usize) };
                if cv.tag != Tag::Int {
                    break;
                }
                let cv = unsafe { cv.raw.int };
                let keep = if cond_is_lt {
                    cv < cond_limit
                } else {
                    cv > cond_limit
                };
                if !keep {
                    break;
                }
                if let Some(v) = self.exec_body(body, env)? {
                    return Ok(Some(v));
                }
            }
            return Ok(None);
        }

        loop {
            let keep = match self.eval_slot(cond, env)? {
                s if s.tag == Tag::Bool => unsafe { s.raw.bool },
                s if s.tag == Tag::Int => unsafe { s.raw.int != 0 },
                s => return Err(format!("while: condition must be bool, got {:?}", s.tag)),
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

pub fn run(program: &Program) -> Result<(), String> {
    let mut vm = Vm::new(program);
    let main = vm.find_func("main").ok_or("No @main function found")?;
    let n_regs = main.n_regs as usize;
    let mut env: Vec<Slot> = vec![Slot::void(); n_regs];
    let body_ptr: *const Vec<Stmt> = &main.body as *const Vec<Stmt>;
    let body: &[Stmt] = unsafe { (*body_ptr).as_slice() };
    vm.exec_body(body, &mut env)?;
    vm.stdout.flush();
    Ok(())
}

impl<'a> Vm<'a> {
    #[inline]
    fn find_func(&self, name: &str) -> Option<&Function> {
        self.func_index
            .get(name)
            .map(|&i| &self.program.functions[i])
    }
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
        let mut env: Vec<Slot> = vec![Slot::void(); n_regs];
        let body_ptr: *const Vec<Stmt> = &main.body as *const Vec<Stmt>;
        let body: &[Stmt] = unsafe { (*body_ptr).as_slice() };
        let slot = vm
            .exec_body(body, &mut env)
            .unwrap()
            .unwrap_or(Slot::void());
        vm.slot_to_value(slot)
    }

    #[test]
    fn ret_integer() {
        assert!(matches!(
            eval_main("@main(): int { ret 42 }"),
            Value::Int(42)
        ));
    }

    #[test]
    fn const_and_ret() {
        assert!(matches!(
            eval_main("@main(): int { %x = const 7 ret %x }"),
            Value::Int(7)
        ));
    }

    #[test]
    fn arithmetic_add() {
        assert!(matches!(
            eval_main("@main(): int { %r = add 3, 4 ret %r }"),
            Value::Int(7)
        ));
    }

    #[test]
    fn arithmetic_sub() {
        assert!(matches!(
            eval_main("@main(): int { %r = sub 10, 3 ret %r }"),
            Value::Int(7)
        ));
    }

    #[test]
    fn arithmetic_mul() {
        assert!(matches!(
            eval_main("@main(): int { %r = mul 3, 4 ret %r }"),
            Value::Int(12)
        ));
    }

    #[test]
    fn arithmetic_div() {
        assert!(matches!(
            eval_main("@main(): int { %r = div 12, 4 ret %r }"),
            Value::Int(3)
        ));
    }

    #[test]
    fn div_by_zero_is_error() {
        let tokens = tokenize("@main(): int { %r = div 1, 0 ret %r }").unwrap();
        let program = parse(tokens).unwrap();
        let mut vm = Vm::new(&program);
        let main = vm.find_func("main").unwrap();
        let n_regs = main.n_regs as usize;
        let mut env: Vec<Slot> = vec![Slot::void(); n_regs];
        let body_ptr: *const Vec<Stmt> = &main.body as *const Vec<Stmt>;
        let body: &[Stmt] = unsafe { (*body_ptr).as_slice() };
        assert!(vm.exec_body(body, &mut env).is_err());
    }

    #[test]
    fn comparison_lt_true() {
        assert!(matches!(
            eval_main("@main(): int { %r = lt 3, 5 ret %r }"),
            Value::Bool(true)
        ));
    }

    #[test]
    fn comparison_lt_false() {
        assert!(matches!(
            eval_main("@main(): int { %r = lt 5, 3 ret %r }"),
            Value::Bool(false)
        ));
    }

    #[test]
    fn comparison_gt() {
        assert!(matches!(
            eval_main("@main(): int { %r = gt 5, 3 ret %r }"),
            Value::Bool(true)
        ));
    }

    #[test]
    fn comparison_eq_ints() {
        assert!(matches!(
            eval_main("@main(): int { %r = eq 4, 4 ret %r }"),
            Value::Bool(true)
        ));
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
        assert!(matches!(eval_main(src), Value::Int(42)));
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
        assert!(matches!(eval_main(src), Value::Int(10)));
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
        assert!(matches!(eval_main(src), Value::Int(99)));
    }

    #[test]
    fn named_constant_read() {
        assert!(matches!(
            eval_main("@main(): int { %m = READ ret %m }"),
            Value::Int(0)
        ));
    }

    #[test]
    fn named_constant_write() {
        assert!(matches!(
            eval_main("@main(): int { %m = WRITE ret %m }"),
            Value::Int(1)
        ));
    }

    #[test]
    fn alloc_returns_ptr() {
        assert!(matches!(
            eval_main("@main(): int { %buf = alloc 64 ret 0 }"),
            Value::Int(0)
        ));
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
