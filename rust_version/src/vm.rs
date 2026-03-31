use crate::ast::*;
use rustc_hash::FxHashMap;
use smallvec::{SmallVec, smallvec};
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
    Ref = 5,
}

#[derive(Clone, Copy)]
union RawVal {
    int: i64,
    bool: bool,
    idx: u32,
    ref_: u64,
    _pad: u64,
}

#[derive(Clone, Copy)]
struct Slot {
    tag: Tag,
    raw: RawVal,
}

/// Sentinel value for field_pos meaning "no field resolved yet".
const REF_NO_FIELD: u16 = 0xFFFF;

/// Bit layout of RawVal::ref_ (u64):
///
///  bit 63        — kind: 0 = array-element ref, 1 = struct ref
///  bits [62:32]  — target_hidx: u31 (heap index of the Array or Struct)
///  bits [31:16]  — elem_idx: u16   (array element index; unused/0 for struct refs)
///  bits [15:0]   — field_pos: u16  (positional field index; REF_NO_FIELD = not yet set)
///
/// Using a kind bit instead of a sentinel in elem_idx means elem_idx has its full
/// u16 range (0..=65534 safely, 0xFFFF is also fine since we never test it as sentinel).
const REF_KIND_STRUCT: u64 = 1u64 << 63;

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

    /// Encode an inline array-element reference.
    /// `target`    — heap index of the HeapVal::Array
    /// `elem_idx`  — index of the element within the array (full u16 range)
    /// `field_pos` — positional field index; REF_NO_FIELD (0xFFFF) = not yet narrowed
    #[inline(always)]
    fn ref_array(target: u32, elem_idx: u16, field_pos: u16) -> Self {
        let packed: u64 = ((target as u64) << 32) | ((elem_idx as u64) << 16) | (field_pos as u64);
        Slot {
            tag: Tag::Ref,
            raw: RawVal { ref_: packed },
        }
    }

    /// Encode an inline struct reference.
    /// `target`    — heap index of the HeapVal::Struct
    /// `field_pos` — positional field index; REF_NO_FIELD = not yet narrowed
    #[inline(always)]
    fn ref_struct(target: u32, field_pos: u16) -> Self {
        let packed: u64 = REF_KIND_STRUCT | ((target as u64) << 32) | (field_pos as u64);
        Slot {
            tag: Tag::Ref,
            raw: RawVal { ref_: packed },
        }
    }

    /// Decode a Ref slot. Returns `(is_struct, target_hidx, elem_idx, field_pos)`.
    /// `elem_idx` is meaningless when `is_struct` is true.
    #[inline(always)]
    fn unpack_ref(self) -> (bool, u32, u16, u16) {
        let v = unsafe { self.raw.ref_ };
        let is_struct = (v & REF_KIND_STRUCT) != 0;
        let target = ((v >> 32) & 0x7FFF_FFFF) as u32;
        let elem_idx = ((v >> 16) & 0xFFFF) as u16;
        let field_pos = (v & 0xFFFF) as u16;
        (is_struct, target, elem_idx, field_pos)
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
    Struct(u16, Vec<Slot>),
    Array(u16, Vec<u16>, Vec<Vec<Slot>>),
}

#[derive(Debug, Clone)]
pub enum Value {
    Int(i64),
    Str(String),
    Bool(bool),
    Ptr(Vec<u8>),
    File(i64),
    Void,
    Struct(Box<(String, Vec<(String, Value)>)>),
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

/// Opcode for the flat instruction stream.
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Op {
    LoadInt,
    LoadStr,
    Move,
    LoadNamed,
    Add,
    Sub,
    Mul,
    Div,
    Lt,
    Gt,
    Eq,
    AllocBytes,
    AllocArrayStruct,
    GetIndexRef,
    GetFieldRef,
    LoadRef,
    StoreRef,
    StructLit,
    GetField,
    SetField,
    CallUser,
    CallUserVoid,
    CallBuiltin,
    CallBuiltinVoid,
    Jmp,
    BrIf,
    Ret,
    RetVoid,
    SetLabel,
    SimdLoop,
}

/// A single flat instruction.
#[derive(Clone, Copy, Debug)]
pub struct Instr {
    pub op: Op,
    pub flag: u8,
    pub dst: u16,
    pub a: u16,
    pub b: u16,
}

/// Argument range: a slice of `arg_regs[start..start+len]`.
#[derive(Clone, Copy, Debug)]
pub struct ArgRange {
    pub start: u32,
    pub len: u16,
}

/// A struct-lit field entry: (field_name_pool_idx, src_reg)
#[derive(Clone, Copy, Debug)]
pub struct FieldEntry {
    pub name_idx: u16,
    pub src_reg: u16,
}

/// One step inside a SIMD loop body: dst = op(a, b).
/// flag 0x1 = a is int_pool idx, 0x2 = b is int_pool idx.
#[derive(Clone, Copy, Debug)]
pub struct SimdOp {
    pub op: Op,
    pub flag: u8,
    pub dst: u16,
    pub a: u16,
    pub b: u16,
}

/// Compiled function — owns its instruction array and constant pools.
pub struct CompiledFn {
    pub n_regs: u16,
    pub code: Vec<Instr>,
    pub int_pool: Vec<i64>,
    pub str_pool: Vec<String>,
    pub name_pool: Vec<String>,
    pub arg_regs: Vec<u16>,
    pub arg_ranges: Vec<ArgRange>,
    pub field_entries: Vec<FieldEntry>,
    pub simd_loops: Vec<Vec<SimdOp>>,
}

#[derive(Clone, Copy, Debug)]
enum CallTarget {
    Builtin(Builtin),
    User(u32),
}

#[derive(Clone, Copy, Debug)]
enum Builtin {
    Puts,
    Flush,
    Open,
    Read,
    Write,
    Close,
}

struct Compiler<'p> {
    program: &'p Program,
    call_cache: &'p FxHashMap<String, CallTarget>,
    code: Vec<Instr>,
    int_pool: Vec<i64>,
    str_pool: Vec<String>,
    name_pool: Vec<String>,
    arg_regs: Vec<u16>,
    arg_ranges: Vec<ArgRange>,
    field_entries: Vec<FieldEntry>,
    simd_loops: Vec<Vec<SimdOp>>,
    patches: Vec<(u32, u8, String)>,
    label_pcs: FxHashMap<String, u32>,
    max_reg: u16,
}

impl<'p> Compiler<'p> {
    fn new(program: &'p Program, call_cache: &'p FxHashMap<String, CallTarget>) -> Self {
        Compiler {
            program,
            call_cache,
            code: Vec::new(),
            int_pool: Vec::new(),
            str_pool: Vec::new(),
            name_pool: Vec::new(),
            arg_regs: Vec::new(),
            arg_ranges: Vec::new(),
            field_entries: Vec::new(),
            simd_loops: Vec::new(),
            patches: Vec::new(),
            label_pcs: FxHashMap::default(),
            max_reg: 0,
        }
    }

    fn int_idx(&mut self, n: i64) -> u16 {
        if let Some(i) = self.int_pool.iter().position(|&x| x == n) {
            return i as u16;
        }
        let i = self.int_pool.len() as u16;
        self.int_pool.push(n);
        i
    }

    fn str_idx(&mut self, s: &str) -> u16 {
        if let Some(i) = self.str_pool.iter().position(|x| x == s) {
            return i as u16;
        }
        let i = self.str_pool.len() as u16;
        self.str_pool.push(s.to_owned());
        i
    }

    fn name_idx(&mut self, s: &str) -> u16 {
        if let Some(i) = self.name_pool.iter().position(|x| x == s) {
            return i as u16;
        }
        let i = self.name_pool.len() as u16;
        self.name_pool.push(s.to_owned());
        i
    }

    fn emit(&mut self, ins: Instr) -> u32 {
        let pc = self.code.len() as u32;
        if ins.dst > self.max_reg {
            self.max_reg = ins.dst;
        }
        self.code.push(ins);
        pc
    }

    fn instr(op: Op, flag: u8, dst: u16, a: u16, b: u16) -> Instr {
        Instr {
            op,
            flag,
            dst,
            a,
            b,
        }
    }

    /// Compile an expression, storing result into `dst`. Returns the actual dst used.
    fn compile_expr(&mut self, expr: &Expr, dst: u16) -> Result<u16, String> {
        match expr {
            Expr::Reg(r) => Ok(*r),
            Expr::Const(inner) => self.compile_expr(inner, dst),
            Expr::Int(n) => {
                let idx = self.int_idx(*n);
                self.emit(Self::instr(Op::LoadInt, 0, dst, idx, 0));
                Ok(dst)
            }
            Expr::Str(s) => {
                let idx = self.str_idx(s);
                self.emit(Self::instr(Op::LoadStr, 0, dst, idx, 0));
                Ok(dst)
            }
            Expr::Named(name) => {
                let idx = self.str_idx(name);
                self.emit(Self::instr(Op::LoadNamed, 0, dst, idx, 0));
                Ok(dst)
            }
            Expr::Add(a, b) => self.compile_binop(Op::Add, a, b, dst),
            Expr::Sub(a, b) => self.compile_binop(Op::Sub, a, b, dst),
            Expr::Mul(a, b) => self.compile_binop(Op::Mul, a, b, dst),
            Expr::Div(a, b) => self.compile_binop(Op::Div, a, b, dst),
            Expr::Lt(a, b) => self.compile_binop(Op::Lt, a, b, dst),
            Expr::Gt(a, b) => self.compile_binop(Op::Gt, a, b, dst),
            Expr::Eq(a, b) => self.compile_binop(Op::Eq, a, b, dst),
            Expr::Field(r, field) => {
                let fidx = self.name_idx(field);
                self.emit(Self::instr(Op::GetField, 0, dst, *r, fidx));
                Ok(dst)
            }
            Expr::Alloc(size_expr) => {
                let ra = self.compile_expr(size_expr, dst)?;
                self.emit(Self::instr(Op::AllocBytes, 0, dst, ra, 0));
                Ok(dst)
            }
            Expr::AllocArray(struct_name, count_expr) => {
                let ra = self.compile_expr(count_expr, dst)?;
                let nidx = self.name_idx(struct_name);
                self.emit(Self::instr(Op::AllocArrayStruct, 0, dst, ra, nidx));
                Ok(dst)
            }
            Expr::GetIndexRef(arr_reg, idx_expr) => {
                let rb = self.compile_expr(idx_expr, dst.wrapping_add(1))?;
                self.emit(Self::instr(Op::GetIndexRef, 0, dst, *arr_reg, rb));
                Ok(dst)
            }
            Expr::GetFieldRef(ref_reg, field) => {
                let fidx = self.name_idx(field);
                self.emit(Self::instr(Op::GetFieldRef, 0, dst, *ref_reg, fidx));
                Ok(dst)
            }
            Expr::Load(ref_reg) => {
                self.emit(Self::instr(Op::LoadRef, 0, dst, *ref_reg, 0));
                Ok(dst)
            }
            Expr::StructLit(name, field_exprs) => {
                let nidx = self.name_idx(name);
                let fe_start = self.field_entries.len() as u16;
                for (i, (fname, fexpr)) in field_exprs.iter().enumerate() {
                    let fnidx = self.name_idx(fname);
                    let r = self.compile_expr(fexpr, dst.wrapping_add(1).wrapping_add(i as u16))?;
                    self.field_entries.push(FieldEntry {
                        name_idx: fnidx,
                        src_reg: r,
                    });
                }
                let fe_len = field_exprs.len() as u16;
                let ar_idx = self.arg_ranges.len() as u16;
                self.arg_ranges.push(ArgRange {
                    start: fe_start as u32,
                    len: fe_len,
                });
                self.emit(Self::instr(Op::StructLit, 0, dst, nidx, ar_idx));
                Ok(dst)
            }
            Expr::Call(name, args) => {
                let ar_idx = self.build_arg_range(args, dst)?;
                match self
                    .call_cache
                    .get(name.as_str())
                    .copied()
                    .ok_or_else(|| format!("Undefined function: {name}"))?
                {
                    CallTarget::Builtin(b) => {
                        self.emit(Self::instr(Op::CallBuiltin, 0, dst, b as u16, ar_idx))
                    }
                    CallTarget::User(idx) => {
                        self.emit(Self::instr(Op::CallUser, 0, dst, idx as u16, ar_idx))
                    }
                };
                Ok(dst)
            }
        }
    }

    fn compile_binop(&mut self, op: Op, a: &Expr, b: &Expr, dst: u16) -> Result<u16, String> {
        let ae = if let Expr::Const(inner) = a {
            inner.as_ref()
        } else {
            a
        };
        let be = if let Expr::Const(inner) = b {
            inner.as_ref()
        } else {
            b
        };
        let mut flag: u8 = 0;
        let av: u16;
        let bv: u16;
        if let Expr::Int(n) = ae {
            av = self.int_idx(*n);
            flag |= 0x01;
        } else if let Expr::Reg(r) = ae {
            av = *r;
        } else {
            av = self.compile_expr(a, dst)?;
        }
        if let Expr::Int(n) = be {
            bv = self.int_idx(*n);
            flag |= 0x02;
        } else if let Expr::Reg(r) = be {
            bv = *r;
        } else {
            let scratch = if flag & 0x01 == 0 && av == dst {
                dst.wrapping_add(1)
            } else {
                dst
            };
            bv = self.compile_expr(b, scratch)?;
        }
        self.emit(Self::instr(op, flag, dst, av, bv));
        Ok(dst)
    }

    fn build_arg_range(&mut self, args: &[Expr], base: u16) -> Result<u16, String> {
        let start = self.arg_regs.len() as u32;
        for (i, ae) in args.iter().enumerate() {
            let r = self.compile_expr(ae, base.wrapping_add(i as u16))?;
            self.arg_regs.push(r);
        }
        let idx = self.arg_ranges.len() as u16;
        self.arg_ranges.push(ArgRange {
            start,
            len: args.len() as u16,
        });
        Ok(idx)
    }

    fn compile_stmt(&mut self, stmt: &Stmt) -> Result<(), String> {
        match stmt {
            Stmt::Assign(reg, expr) => {
                let r = self.compile_expr(expr, *reg)?;
                if r != *reg {
                    self.emit(Self::instr(Op::Move, 0, *reg, r, 0));
                }
            }
            Stmt::SetField(reg, field, expr) => {
                let fidx = self.name_idx(field);
                let r = self.compile_expr(expr, reg.wrapping_add(1))?;
                self.emit(Self::instr(Op::SetField, 0, *reg, fidx, r));
            }
            Stmt::Store(ref_reg, val_expr) => {
                let r = self.compile_expr(val_expr, ref_reg.wrapping_add(1))?;
                self.emit(Self::instr(Op::StoreRef, 0, *ref_reg, r, 0));
            }
            Stmt::Call(name, args) => {
                let scratch = self.max_reg.wrapping_add(1);
                let ar_idx = self.build_arg_range(args, scratch)?;
                match self
                    .call_cache
                    .get(name.as_str())
                    .copied()
                    .ok_or_else(|| format!("Undefined function: {name}"))?
                {
                    CallTarget::Builtin(b) => {
                        self.emit(Self::instr(Op::CallBuiltinVoid, 0, 0, b as u16, ar_idx))
                    }
                    CallTarget::User(idx) => {
                        self.emit(Self::instr(Op::CallUserVoid, 0, 0, idx as u16, ar_idx))
                    }
                };
            }
            Stmt::Ret(expr) => {
                let scratch = self.max_reg.wrapping_add(1);
                let r = self.compile_expr(expr, scratch)?;
                self.emit(Self::instr(Op::Ret, 0, r, 0, 0));
            }
            Stmt::While(cond, body) => {
                let cond_pc = self.code.len() as u32;
                let scratch = self.max_reg.wrapping_add(1);
                let cr = self.compile_expr(cond, scratch)?;
                let br_pc = self.emit(Self::instr(Op::BrIf, 0, cr, 0, 0));
                for s in body {
                    self.compile_stmt(s)?;
                }
                self.emit(Self::instr(Op::Jmp, 0, 0, cond_pc as u16, 0));
                let after_pc = self.code.len() as u32;
                self.code[br_pc as usize].a = (br_pc + 1) as u16;
                self.code[br_pc as usize].b = after_pc as u16;
            }
            Stmt::Label(name) => {
                let pc = self.code.len() as u32;
                self.label_pcs.insert(name.clone(), pc);
                self.emit(Self::instr(Op::SetLabel, 0, 0, 0, 0));
            }
            Stmt::Jmp(label) => {
                let patch_pc = self.code.len() as u32;
                self.emit(Self::instr(Op::Jmp, 0, 0, 0, 0));
                self.patches.push((patch_pc, 0, label.clone()));
            }
            Stmt::BrIf(cond, true_label, false_label) => {
                let scratch = self.max_reg.wrapping_add(1);
                let cr = self.compile_expr(cond, scratch)?;
                let patch_pc = self.code.len() as u32;
                self.emit(Self::instr(Op::BrIf, 0, cr, 0, 0));
                self.patches.push((patch_pc, 0, true_label.clone()));
                self.patches.push((patch_pc, 1, false_label.clone()));
            }
        }
        Ok(())
    }

    fn apply_patches(&mut self) -> Result<(), String> {
        for (pc, field, label) in &self.patches {
            let tpc = *self
                .label_pcs
                .get(label.as_str())
                .ok_or_else(|| format!("Undefined label '{label}'"))? as u16;
            if *field == 0 {
                self.code[*pc as usize].a = tpc;
            } else {
                self.code[*pc as usize].b = tpc;
            }
        }
        Ok(())
    }

    fn finish(mut self, n_regs: u16) -> Result<CompiledFn, String> {
        self.apply_patches()?;
        if self.code.is_empty() || !matches!(self.code.last().unwrap().op, Op::Ret | Op::RetVoid) {
            self.emit(Self::instr(Op::RetVoid, 0, 0, 0, 0));
        }
        self.rewrite_simd_loops();
        let actual_n_regs = n_regs.max(self.max_reg + 1);
        Ok(CompiledFn {
            n_regs: actual_n_regs,
            code: self.code,
            int_pool: self.int_pool,
            str_pool: self.str_pool,
            name_pool: self.name_pool,
            arg_regs: self.arg_regs,
            arg_ranges: self.arg_ranges,
            field_entries: self.field_entries,
            simd_loops: self.simd_loops,
        })
    }

    fn rewrite_simd_loops(&mut self) {
        let n = self.code.len();
        let mut i = 0;
        while i + 2 < n {
            let cond_ins = self.code[i];
            if !matches!(cond_ins.op, Op::Lt | Op::Gt) {
                i += 1;
                continue;
            }
            let br_ins = self.code[i + 1];
            if br_ins.op != Op::BrIf {
                i += 1;
                continue;
            }
            if br_ins.dst != cond_ins.dst {
                i += 1;
                continue;
            }

            let body_start = br_ins.a as usize;
            let exit_pc = br_ins.b as usize;

            if body_start != i + 2 {
                i += 1;
                continue;
            }
            if exit_pc <= body_start {
                i += 1;
                continue;
            }

            let jmp_pc = exit_pc - 1;
            if jmp_pc < body_start {
                i += 1;
                continue;
            }
            let jmp_ins = self.code[jmp_pc];
            if jmp_ins.op != Op::Jmp || jmp_ins.a as usize != i {
                i += 1;
                continue;
            }

            let body_slice = &self.code[body_start..jmp_pc];
            let all_arith = body_slice.iter().all(|ins| {
                matches!(
                    ins.op,
                    Op::Add
                        | Op::Sub
                        | Op::Mul
                        | Op::Div
                        | Op::Lt
                        | Op::Gt
                        | Op::Move
                        | Op::LoadInt
                        | Op::SetLabel
                )
            });
            if !all_arith {
                i += 1;
                continue;
            }

            let cond_is_lt = cond_ins.op == Op::Lt;
            if cond_ins.flag & 0x01 != 0 {
                i += 1;
                continue;
            }
            let loop_var_reg = cond_ins.a;
            let limit_is_pool = cond_ins.flag & 0x02 != 0;
            let limit_val = cond_ins.b;

            let simd_body: Vec<SimdOp> = body_slice
                .iter()
                .filter(|ins| !matches!(ins.op, Op::SetLabel))
                .map(|ins| SimdOp {
                    op: ins.op,
                    flag: ins.flag,
                    dst: ins.dst,
                    a: ins.a,
                    b: ins.b,
                })
                .collect();

            if simd_body.is_empty() {
                i += 1;
                continue;
            }

            let loop_idx = self.simd_loops.len() as u16;
            self.simd_loops.push(simd_body);

            let flag: u8 = (cond_is_lt as u8) | ((limit_is_pool as u8) << 1);
            self.code[i] = Self::instr(Op::SimdLoop, flag, loop_var_reg, loop_idx, limit_val);
            for j in (i + 1)..exit_pc {
                self.code[j] = Self::instr(Op::SetLabel, 0, 0, 0, 0);
            }
            i = exit_pc;
        }
    }
}

fn build_call_cache(program: &Program) -> FxHashMap<String, CallTarget> {
    let mut m: FxHashMap<String, CallTarget> = FxHashMap::default();
    m.insert("puts".into(), CallTarget::Builtin(Builtin::Puts));
    m.insert("flush".into(), CallTarget::Builtin(Builtin::Flush));
    m.insert("open".into(), CallTarget::Builtin(Builtin::Open));
    m.insert("read".into(), CallTarget::Builtin(Builtin::Read));
    m.insert("write".into(), CallTarget::Builtin(Builtin::Write));
    m.insert("close".into(), CallTarget::Builtin(Builtin::Close));
    for (i, f) in program.functions.iter().enumerate() {
        m.insert(f.name.clone(), CallTarget::User(i as u32));
    }
    m
}

fn compile_function(
    func: &Function,
    call_cache: &FxHashMap<String, CallTarget>,
    program: &Program,
) -> Result<CompiledFn, String> {
    let mut c = Compiler::new(program, call_cache);
    for stmt in &func.body {
        c.compile_stmt(stmt)?;
    }
    c.finish(func.n_regs)
}

/// Evaluate one SimdOp against a flat i64 frame.
#[inline(always)]
fn eval_simd_op(op: &SimdOp, frame: &[i64], int_pool: &[i64]) -> i64 {
    let a = if op.flag & 0x01 != 0 {
        int_pool[op.a as usize]
    } else {
        frame[op.a as usize]
    };
    let b = if op.flag & 0x02 != 0 {
        int_pool[op.b as usize]
    } else {
        frame[op.b as usize]
    };
    match op.op {
        Op::Add => a.wrapping_add(b),
        Op::Sub => a.wrapping_sub(b),
        Op::Mul => a.wrapping_mul(b),
        Op::Div => {
            if b == 0 {
                0
            } else {
                a / b
            }
        }
        Op::Lt => (a < b) as i64,
        Op::Gt => (a > b) as i64,
        Op::Move => a,
        Op::LoadInt => int_pool[op.a as usize],
        _ => 0,
    }
}

fn run_scalar_simd_loop(
    body: &[SimdOp],
    int_pool: &[i64],
    frame: &mut [i64],
    cond_reg: u16,
    limit: i64,
    cond_is_lt: bool,
) {
    loop {
        let cv = frame[cond_reg as usize];
        if cond_is_lt {
            if cv >= limit {
                break;
            }
        } else {
            if cv <= limit {
                break;
            }
        }
        for op in body {
            frame[op.dst as usize] = eval_simd_op(op, frame, int_pool);
        }
    }
}

#[cfg(target_arch = "aarch64")]
#[target_feature(enable = "neon")]
unsafe fn run_neon_simd_loop(
    body: &[SimdOp],
    int_pool: &[i64],
    frame: &mut Vec<i64>,
    cond_reg: u16,
    limit: i64,
    cond_is_lt: bool,
) {
    unsafe {
        use std::arch::aarch64::*;
        let n = frame.len();
        let mut f0 = frame.clone();
        let mut f1 = frame.clone();
        let mut f2 = frame.clone();
        let mut f3 = frame.clone();

        for op in body {
            f1[op.dst as usize] = eval_simd_op(op, &f1, int_pool);
        }
        for _ in 0..2 {
            for op in body {
                f2[op.dst as usize] = eval_simd_op(op, &f2, int_pool);
            }
        }
        for _ in 0..3 {
            for op in body {
                f3[op.dst as usize] = eval_simd_op(op, &f3, int_pool);
            }
        }

        let mut f0_next = f0.clone();
        for _ in 0..4 {
            for op in body {
                f0_next[op.dst as usize] = eval_simd_op(op, &f0_next, int_pool);
            }
        }
        let delta: Vec<i64> = (0..n).map(|i| f0_next[i].wrapping_sub(f0[i])).collect();

        let all_active = |fa: &[i64], fb: &[i64], fc: &[i64], fd: &[i64]| -> bool {
            let check = |f: &[i64]| {
                let cv = f[cond_reg as usize];
                if cond_is_lt { cv < limit } else { cv > limit }
            };
            check(fa) && check(fb) && check(fc) && check(fd)
        };

        while all_active(&f0, &f1, &f2, &f3) {
            let mut i = 0;
            while i + 2 <= n {
                let d = vld1q_s64(delta.as_ptr().add(i));
                let v0 = vld1q_s64(f0.as_ptr().add(i));
                let v1 = vld1q_s64(f1.as_ptr().add(i));
                let v2 = vld1q_s64(f2.as_ptr().add(i));
                let v3 = vld1q_s64(f3.as_ptr().add(i));
                vst1q_s64(f0.as_mut_ptr().add(i), vaddq_s64(v0, d));
                vst1q_s64(f1.as_mut_ptr().add(i), vaddq_s64(v1, d));
                vst1q_s64(f2.as_mut_ptr().add(i), vaddq_s64(v2, d));
                vst1q_s64(f3.as_mut_ptr().add(i), vaddq_s64(v3, d));
                i += 2;
            }
            while i < n {
                f0[i] = f0[i].wrapping_add(delta[i]);
                f1[i] = f1[i].wrapping_add(delta[i]);
                f2[i] = f2[i].wrapping_add(delta[i]);
                f3[i] = f3[i].wrapping_add(delta[i]);
                i += 1;
            }
        }
        run_scalar_simd_loop(body, int_pool, &mut f0, cond_reg, limit, cond_is_lt);
        *frame = f0;
    }
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2")]
unsafe fn run_avx2_simd_loop(
    body: &[SimdOp],
    int_pool: &[i64],
    frame: &mut Vec<i64>,
    cond_reg: u16,
    limit: i64,
    cond_is_lt: bool,
) {
    use std::arch::x86_64::*;
    let n = frame.len();
    let mut f0 = frame.clone();
    let mut f1 = frame.clone();
    let mut f2 = frame.clone();
    let mut f3 = frame.clone();

    for op in body {
        f1[op.dst as usize] = eval_simd_op(op, &f1, int_pool);
    }
    for _ in 0..2 {
        for op in body {
            f2[op.dst as usize] = eval_simd_op(op, &f2, int_pool);
        }
    }
    for _ in 0..3 {
        for op in body {
            f3[op.dst as usize] = eval_simd_op(op, &f3, int_pool);
        }
    }

    let mut f0_next = f0.clone();
    for op in body {
        f0_next[op.dst as usize] = eval_simd_op(op, &f0_next, int_pool);
    }
    let mut f1_next = f1.clone();
    for op in body {
        f1_next[op.dst as usize] = eval_simd_op(op, &f1_next, int_pool);
    }
    let mut f2_next = f2.clone();
    for op in body {
        f2_next[op.dst as usize] = eval_simd_op(op, &f2_next, int_pool);
    }
    let mut f3_next = f3.clone();
    for op in body {
        f3_next[op.dst as usize] = eval_simd_op(op, &f3_next, int_pool);
    }

    let delta: Vec<i64> = (0..n).map(|i| f3_next[i].wrapping_sub(f0[i])).collect();
    let all_active = |fa: &[i64], fb: &[i64], fc: &[i64], fd: &[i64]| -> bool {
        let check = |f: &[i64]| {
            let cv = f[cond_reg as usize];
            if cond_is_lt { cv < limit } else { cv > limit }
        };
        check(fa) && check(fb) && check(fc) && check(fd)
    };

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
    run_scalar_simd_loop(body, int_pool, &mut f0, cond_reg, limit, cond_is_lt);
    *frame = f0;
}

fn exec_simd_loop(
    body: &[SimdOp],
    int_pool: &[i64],
    slots: &mut [Slot],
    cond_reg: u16,
    limit: i64,
    cond_is_lt: bool,
) {
    let n = slots.len();
    let mut frame: Vec<i64> = (0..n)
        .map(|i| unsafe {
            if slots[i].tag == Tag::Int {
                slots[i].raw.int
            } else {
                0
            }
        })
        .collect();

    #[cfg(target_arch = "aarch64")]
    {
        unsafe {
            run_neon_simd_loop(body, int_pool, &mut frame, cond_reg, limit, cond_is_lt);
        }
    }
    #[cfg(target_arch = "x86_64")]
    {
        if is_x86_feature_detected!("avx2") {
            unsafe {
                run_avx2_simd_loop(body, int_pool, &mut frame, cond_reg, limit, cond_is_lt);
            }
        } else {
            run_scalar_simd_loop(body, int_pool, &mut frame, cond_reg, limit, cond_is_lt);
        }
    }
    #[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
    {
        run_scalar_simd_loop(body, int_pool, &mut frame, cond_reg, limit, cond_is_lt);
    }

    for i in 0..n {
        slots[i] = Slot::int(frame[i]);
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

enum FileHandle {
    Read(File),
    Write(File),
}

struct Vm<'a> {
    program: &'a Program,
    compiled: Vec<CompiledFn>,
    func_index: FxHashMap<&'a str, usize>,
    files: Vec<Option<FileHandle>>,
    stdout: StdoutBuf,
    heap: Vec<HeapVal>,
}

impl<'a> Vm<'a> {
    fn new(program: &'a Program) -> Result<Self, String> {
        let call_cache = build_call_cache(program);
        let mut func_index: FxHashMap<&'a str, usize> = FxHashMap::default();
        for (i, f) in program.functions.iter().enumerate() {
            func_index.insert(f.name.as_str(), i);
        }
        let mut compiled = Vec::with_capacity(program.functions.len());
        for f in &program.functions {
            compiled.push(compile_function(f, &call_cache, program)?);
        }
        Ok(Vm {
            program,
            compiled,
            func_index,
            files: Vec::new(),
            stdout: StdoutBuf::new(),
            heap: Vec::new(),
        })
    }

    #[inline]
    fn alloc_heap(&mut self, v: HeapVal) -> Slot {
        let idx = self.heap.len() as u32;
        self.heap.push(v);
        Slot::heap(idx)
    }

    fn slot_to_value(&self, s: Slot, program: &Program) -> Value {
        match s.tag {
            Tag::Void => Value::Void,
            Tag::Int => Value::Int(unsafe { s.raw.int }),
            Tag::Bool => Value::Bool(unsafe { s.raw.bool }),
            Tag::File => Value::File(unsafe { s.raw.int }),
            Tag::Ref => Value::Void,
            Tag::Heap => {
                let idx = unsafe { s.raw.idx } as usize;
                match &self.heap[idx] {
                    HeapVal::Str(s) => Value::Str(s.clone()),
                    HeapVal::Ptr(b) => Value::Ptr(b.clone()),
                    HeapVal::Struct(name_idx, fields) => {
                        let name = &self.compiled[0].name_pool[*name_idx as usize];
                        let struct_def = program.structs.iter().find(|s| s.name == *name).unwrap();
                        let fields_vec: Vec<(String, Value)> = fields
                            .iter()
                            .enumerate()
                            .map(|(i, &v)| {
                                let field_name = struct_def.fields[i].0.clone();
                                (field_name, self.slot_to_value(v, program))
                            })
                            .collect();
                        Value::Struct(Box::new((name.clone(), fields_vec)))
                    }
                    HeapVal::Array(..) => Value::Ptr(vec![]),
                }
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
            Tag::Void | Tag::Ref => {}
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
                    HeapVal::Struct(name_idx, _) => {
                        let name = &self.compiled[0].name_pool[*name_idx as usize];
                        let b = name.as_bytes().to_vec();
                        self.stdout.write(&b);
                        self.stdout.write(b" { ... }\n");
                    }
                    HeapVal::Array(name_idx, _, _) => {
                        let name = &self.compiled[0].name_pool[*name_idx as usize];
                        let b = name.as_bytes().to_vec();
                        self.stdout.write(b"[");
                        self.stdout.write(&b);
                        self.stdout.write(b"]\n");
                    }
                }
            }
        }
    }

    fn find_func(&self, name: &str) -> Option<usize> {
        self.func_index.get(name).copied()
    }

    /// Look up the positional field index for `field_name` within a named struct or array type.
    /// For arrays: searches `field_order` stored in the `HeapVal::Array`.
    /// For structs: searches the program's struct definition (stable ordering).
    #[inline]
    fn field_pos_in_array(
        heap: &[HeapVal],
        name_pool: &[String],
        arr_hidx: u32,
        field_name: &str,
    ) -> Result<u16, String> {
        match &heap[arr_hidx as usize] {
            HeapVal::Array(_, field_order_indices, _) => field_order_indices
                .iter()
                .position(|&idx| &name_pool[idx as usize] == field_name)
                .map(|p| p as u16)
                .ok_or_else(|| format!("get_field_ref: no field '{field_name}'")),
            _ => Err("get_field_ref: ref target is not an array".into()),
        }
    }

    #[inline]
    fn field_pos_in_struct(
        program: &Program,
        struct_name: &str,
        field_name: &str,
    ) -> Result<u16, String> {
        program
            .structs
            .iter()
            .find(|s| s.name == struct_name)
            .and_then(|s| s.fields.iter().position(|(n, _)| n == field_name))
            .map(|p| p as u16)
            .ok_or_else(|| {
                format!("get_field_ref: no field '{field_name}' on struct '{struct_name}'")
            })
    }

    fn exec_func(&mut self, func_idx: usize, args: &[Slot]) -> Result<Slot, String> {
        let cf_ptr: *const CompiledFn = &self.compiled[func_idx];
        let cf = unsafe { &*cf_ptr };

        let n = cf.n_regs as usize;
        let mut regs: SmallVec<[Slot; 16]> = smallvec![Slot::void(); n];
        for (i, &a) in args.iter().enumerate() {
            let param_reg = self.program.functions[func_idx].params[i].2 as usize;
            regs[param_reg] = a;
        }

        let mut pc: usize = 0;
        let code = cf.code.as_slice();

        macro_rules! reg {
            ($r:expr) => {
                unsafe { *regs.get_unchecked($r as usize) }
            };
        }
        macro_rules! reg_mut {
            ($r:expr) => {
                unsafe { regs.get_unchecked_mut($r as usize) }
            };
        }
        macro_rules! int_of {
            ($s:expr) => {{
                let s: Slot = $s;
                if s.tag == Tag::Int {
                    unsafe { s.raw.int }
                } else {
                    return Err(format!("expected int, got {:?}", s.tag));
                }
            }};
        }
        macro_rules! operand_a {
            ($ins:expr) => {
                if $ins.flag & 0x01 != 0 {
                    cf.int_pool[$ins.a as usize]
                } else {
                    int_of!(reg!($ins.a))
                }
            };
        }
        macro_rules! operand_b {
            ($ins:expr) => {
                if $ins.flag & 0x02 != 0 {
                    cf.int_pool[$ins.b as usize]
                } else {
                    int_of!(reg!($ins.b))
                }
            };
        }

        loop {
            let ins = unsafe { *code.get_unchecked(pc) };
            pc += 1;
            match ins.op {
                Op::SetLabel => {}
                Op::Move => {
                    *reg_mut!(ins.dst) = reg!(ins.a);
                }
                Op::LoadInt => {
                    *reg_mut!(ins.dst) = Slot::int(cf.int_pool[ins.a as usize]);
                }
                Op::LoadStr => {
                    let s = cf.str_pool[ins.a as usize].clone();
                    *reg_mut!(ins.dst) = self.alloc_heap(HeapVal::Str(s));
                }
                Op::LoadNamed => {
                    let name = &cf.str_pool[ins.a as usize];
                    let v = match name.as_str() {
                        "READ" => Slot::int(0),
                        "WRITE" => Slot::int(1),
                        _ => return Err(format!("Unknown named constant: {name}")),
                    };
                    *reg_mut!(ins.dst) = v;
                }
                Op::Add => {
                    *reg_mut!(ins.dst) = Slot::int(operand_a!(ins).wrapping_add(operand_b!(ins)));
                }
                Op::Sub => {
                    *reg_mut!(ins.dst) = Slot::int(operand_a!(ins).wrapping_sub(operand_b!(ins)));
                }
                Op::Mul => {
                    *reg_mut!(ins.dst) = Slot::int(operand_a!(ins).wrapping_mul(operand_b!(ins)));
                }
                Op::Div => {
                    let b = operand_b!(ins);
                    if b == 0 {
                        return Err("Division by zero".into());
                    }
                    *reg_mut!(ins.dst) = Slot::int(operand_a!(ins) / b);
                }
                Op::Lt => {
                    *reg_mut!(ins.dst) = Slot::bool(operand_a!(ins) < operand_b!(ins));
                }
                Op::Gt => {
                    *reg_mut!(ins.dst) = Slot::bool(operand_a!(ins) > operand_b!(ins));
                }
                Op::Eq => {
                    let av = reg!(ins.a);
                    let bv = reg!(ins.b);
                    let eq = match (av.tag, bv.tag) {
                        (Tag::Int, Tag::Int) => unsafe { av.raw.int == bv.raw.int },
                        (Tag::Bool, Tag::Bool) => unsafe { av.raw.bool == bv.raw.bool },
                        (Tag::Heap, Tag::Heap) => {
                            let ai = unsafe { av.raw.idx } as usize;
                            let bi = unsafe { bv.raw.idx } as usize;
                            match (&self.heap[ai], &self.heap[bi]) {
                                (HeapVal::Str(a), HeapVal::Str(b)) => a == b,
                                _ => return Err("eq: type mismatch".into()),
                            }
                        }
                        _ => return Err(format!("eq: type mismatch {:?} == {:?}", av.tag, bv.tag)),
                    };
                    *reg_mut!(ins.dst) = Slot::bool(eq);
                }
                Op::AllocBytes => {
                    let size = int_of!(reg!(ins.a)) as usize;
                    *reg_mut!(ins.dst) = self.alloc_heap(HeapVal::Ptr(vec![0u8; size]));
                }
                Op::AllocArrayStruct => {
                    let count = int_of!(reg!(ins.a)) as usize;
                    let name_idx = ins.b;
                    let struct_name = &cf.name_pool[name_idx as usize];
                    let struct_def = self
                        .program
                        .structs
                        .iter()
                        .find(|s| s.name == *struct_name)
                        .unwrap();
                    let field_order_indices: Vec<u16> = struct_def
                        .fields
                        .iter()
                        .map(|(fname, _)| {
                            cf.name_pool.iter().position(|n| n == fname).unwrap() as u16
                        })
                        .collect();
                    let n_fields = struct_def.fields.len();
                    let elements = (0..count).map(|_| vec![Slot::void(); n_fields]).collect();
                    *reg_mut!(ins.dst) =
                        self.alloc_heap(HeapVal::Array(name_idx, field_order_indices, elements));
                }
                Op::GetIndexRef => {
                    let arr_slot = reg!(ins.a);
                    let arr_hidx = arr_slot
                        .heap_idx()
                        .ok_or("get_index_ref: not a heap value")?;
                    let elem_idx = int_of!(reg!(ins.b)) as usize;
                    match &self.heap[arr_hidx as usize] {
                        HeapVal::Array(_, _, elems) => {
                            if elem_idx >= elems.len() {
                                return Err(format!(
                                    "get_index_ref: index {elem_idx} out of bounds"
                                ));
                            }
                        }
                        _ => return Err("get_index_ref: not an array".into()),
                    }
                    *reg_mut!(ins.dst) = Slot::ref_array(arr_hidx, elem_idx as u16, REF_NO_FIELD);
                }
                Op::GetFieldRef => {
                    let src = reg!(ins.a);
                    let field_name = &cf.name_pool[ins.b as usize];
                    let new_ref = match src.tag {
                        Tag::Ref => {
                            let (is_struct, target, elem_idx, prev_field) = src.unpack_ref();
                            if is_struct {
                                return Err(
                                    "get_field_ref: ref already points to a struct field".into()
                                );
                            }
                            if prev_field != REF_NO_FIELD {
                                return Err("get_field_ref: ref already has a field".into());
                            }
                            let fpos = Self::field_pos_in_array(
                                &self.heap,
                                &cf.name_pool,
                                target,
                                field_name,
                            )?;
                            Slot::ref_array(target, elem_idx, fpos)
                        }
                        Tag::Heap => {
                            let struct_hidx = unsafe { src.raw.idx };
                            match &self.heap[struct_hidx as usize] {
                                HeapVal::Struct(name_idx, fields) => {
                                    let struct_name = &cf.name_pool[*name_idx as usize];
                                    let fpos = Self::field_pos_in_struct(
                                        self.program,
                                        struct_name,
                                        field_name,
                                    )?;
                                    if fpos as usize >= fields.len() {
                                        return Err(format!(
                                            "get_field_ref: field index {fpos} out of range"
                                        ));
                                    }
                                    Slot::ref_struct(struct_hidx, fpos)
                                }
                                _ => return Err("get_field_ref: not a ref or struct".into()),
                            }
                        }
                        _ => return Err("get_field_ref: not a ref or struct".into()),
                    };
                    *reg_mut!(ins.dst) = new_ref;
                }
                Op::LoadRef => {
                    let ref_slot = reg!(ins.a);
                    if ref_slot.tag != Tag::Ref {
                        return Err("load: not a ref".into());
                    }
                    let (is_struct, target, elem_idx, field_pos) = ref_slot.unpack_ref();
                    if field_pos == REF_NO_FIELD {
                        return Err("load: ref has no field (call get_field_ref first)".into());
                    }
                    let val = if is_struct {
                        match &self.heap[target as usize] {
                            HeapVal::Struct(_, fields) => fields
                                .get(field_pos as usize)
                                .copied()
                                .unwrap_or(Slot::void()),
                            _ => return Err("load: struct ref target is not a struct".into()),
                        }
                    } else {
                        match &self.heap[target as usize] {
                            HeapVal::Array(_, _, elems) => elems[elem_idx as usize]
                                .get(field_pos as usize)
                                .copied()
                                .unwrap_or(Slot::void()),
                            _ => return Err("load: array ref target is not an array".into()),
                        }
                    };
                    *reg_mut!(ins.dst) = val;
                }
                Op::StoreRef => {
                    let val = reg!(ins.a);
                    let ref_slot = reg!(ins.dst);
                    if ref_slot.tag != Tag::Ref {
                        return Err("store: not a ref".into());
                    }
                    let (is_struct, target, elem_idx, field_pos) = ref_slot.unpack_ref();
                    if field_pos == REF_NO_FIELD {
                        return Err("store: ref has no field (call get_field_ref first)".into());
                    }
                    if is_struct {
                        match &mut self.heap[target as usize] {
                            HeapVal::Struct(_, fields) => {
                                if field_pos as usize >= fields.len() {
                                    return Err(format!(
                                        "store: field index {field_pos} out of range"
                                    ));
                                }
                                fields[field_pos as usize] = val;
                            }
                            _ => return Err("store: struct ref target is not a struct".into()),
                        }
                    } else {
                        match &mut self.heap[target as usize] {
                            HeapVal::Array(_, _, elems) => {
                                if elem_idx as usize >= elems.len() {
                                    return Err(format!(
                                        "store: element index {elem_idx} out of range"
                                    ));
                                }
                                if field_pos as usize >= elems[elem_idx as usize].len() {
                                    return Err(format!(
                                        "store: field index {field_pos} out of range"
                                    ));
                                }
                                elems[elem_idx as usize][field_pos as usize] = val;
                            }
                            _ => return Err("store: array ref target is not an array".into()),
                        }
                    }
                }
                Op::GetField => {
                    let s = reg!(ins.a);
                    let hidx = s.heap_idx().ok_or("get_field: not a struct")? as usize;
                    let field_name = &cf.name_pool[ins.b as usize];
                    let val = match &self.heap[hidx] {
                        HeapVal::Struct(name_idx, fields) => {
                            let struct_name = &cf.name_pool[*name_idx as usize];
                            let struct_def = self
                                .program
                                .structs
                                .iter()
                                .find(|s| s.name == *struct_name)
                                .ok_or_else(|| {
                                    format!("get_field: struct '{struct_name}' not found")
                                })?;
                            let field_pos = struct_def
                                .fields
                                .iter()
                                .position(|(n, _)| n == field_name)
                                .ok_or_else(|| format!("No field '{field_name}'"))?
                                as usize;
                            fields
                                .get(field_pos)
                                .copied()
                                .ok_or_else(|| format!("No field '{field_name}'"))?
                        }
                        _ => return Err("get_field: not a struct".into()),
                    };
                    *reg_mut!(ins.dst) = val;
                }
                Op::SetField => {
                    let val = reg!(ins.b);
                    let s = reg!(ins.dst);
                    let hidx = s.heap_idx().ok_or("set_field: not a struct")? as usize;
                    let field_name = &cf.name_pool[ins.a as usize];
                    match &mut self.heap[hidx] {
                        HeapVal::Struct(name_idx, fields) => {
                            let struct_name = &cf.name_pool[*name_idx as usize];
                            let struct_def = self
                                .program
                                .structs
                                .iter()
                                .find(|s| s.name == *struct_name)
                                .ok_or_else(|| {
                                    format!("set_field: struct '{struct_name}' not found")
                                })?;
                            let field_pos = struct_def
                                .fields
                                .iter()
                                .position(|(n, _)| n == field_name)
                                .ok_or_else(|| format!("No field '{field_name}'"))?
                                as usize;
                            if field_pos >= fields.len() {
                                return Err(format!(
                                    "set_field: field index {field_pos} out of range"
                                ));
                            }
                            fields[field_pos] = val;
                        }
                        _ => return Err("set_field: not a struct".into()),
                    }
                }
                Op::StructLit => {
                    let name_idx = ins.a;
                    let ar = cf.arg_ranges[ins.b as usize];
                    let struct_name = &cf.name_pool[name_idx as usize];
                    let struct_def = self
                        .program
                        .structs
                        .iter()
                        .find(|s| s.name == *struct_name)
                        .ok_or_else(|| format!("struct_lit: struct '{struct_name}' not found"))?;
                    let n_fields = struct_def.fields.len();
                    let mut fields: Vec<Slot> = vec![Slot::void(); n_fields];
                    for i in 0..ar.len as usize {
                        let fe = cf.field_entries[ar.start as usize + i];
                        let field_name = &cf.name_pool[fe.name_idx as usize];
                        let field_pos = struct_def
                            .fields
                            .iter()
                            .position(|(n, _)| n == field_name)
                            .ok_or_else(|| format!("struct_lit: unknown field '{field_name}'"))?;
                        fields[field_pos] = reg!(fe.src_reg);
                    }
                    *reg_mut!(ins.dst) = self.alloc_heap(HeapVal::Struct(name_idx, fields));
                }
                Op::CallUser => {
                    let ar = cf.arg_ranges[ins.b as usize];
                    let mut args_buf: SmallVec<[Slot; 8]> =
                        smallvec![Slot::void(); ar.len as usize];
                    for i in 0..ar.len as usize {
                        args_buf[i] = reg!(cf.arg_regs[ar.start as usize + i]);
                    }
                    let result = self.exec_func(ins.a as usize, &args_buf)?;
                    *reg_mut!(ins.dst) = result;
                }
                Op::CallUserVoid => {
                    let ar = cf.arg_ranges[ins.b as usize];
                    let args_buf: SmallVec<[Slot; 8]> = {
                        let mut buf = smallvec![Slot::void(); ar.len as usize];
                        for i in 0..ar.len as usize {
                            buf[i] = reg!(cf.arg_regs[ar.start as usize + i]);
                        }
                        buf
                    };
                    self.exec_func(ins.a as usize, &args_buf)?;
                }
                Op::CallBuiltin => {
                    let ar = cf.arg_ranges[ins.b as usize];
                    let args_buf: SmallVec<[Slot; 8]> = {
                        let mut buf = smallvec![Slot::void(); ar.len as usize];
                        for i in 0..ar.len as usize {
                            buf[i] = reg!(cf.arg_regs[ar.start as usize + i]);
                        }
                        buf
                    };
                    let result = self.exec_builtin(ins.a as u8, &args_buf)?;
                    *reg_mut!(ins.dst) = result;
                }
                Op::CallBuiltinVoid => {
                    let ar = cf.arg_ranges[ins.b as usize];
                    let args_buf: SmallVec<[Slot; 8]> = {
                        let mut buf = smallvec![Slot::void(); ar.len as usize];
                        for i in 0..ar.len as usize {
                            buf[i] = reg!(cf.arg_regs[ar.start as usize + i]);
                        }
                        buf
                    };
                    self.exec_builtin(ins.a as u8, &args_buf)?;
                }
                Op::Jmp => {
                    pc = ins.a as usize;
                }
                Op::BrIf => {
                    let cond = reg!(ins.dst);
                    let taken = match cond.tag {
                        Tag::Bool => unsafe { cond.raw.bool },
                        Tag::Int => unsafe { cond.raw.int != 0 },
                        _ => return Err(format!("br_if: expected bool, got {:?}", cond.tag)),
                    };
                    pc = if taken {
                        ins.a as usize
                    } else {
                        ins.b as usize
                    };
                }
                Op::Ret => {
                    return Ok(reg!(ins.dst));
                }
                Op::RetVoid => {
                    return Ok(Slot::void());
                }
                Op::SimdLoop => {
                    let loop_idx = ins.a as usize;
                    let limit = if ins.flag & 0x02 != 0 {
                        cf.int_pool[ins.b as usize]
                    } else {
                        int_of!(reg!(ins.b))
                    };
                    let cond_is_lt = ins.flag & 0x01 != 0;
                    let cond_reg = ins.dst;
                    let body_ptr: *const Vec<SimdOp> = &cf.simd_loops[loop_idx];
                    let body: &[SimdOp] = unsafe { (*body_ptr).as_slice() };
                    let int_pool_ptr: *const Vec<i64> = &cf.int_pool;
                    let int_pool: &[i64] = unsafe { (*int_pool_ptr).as_slice() };
                    exec_simd_loop(body, int_pool, &mut regs, cond_reg, limit, cond_is_lt);
                }
            }
        }
    }

    fn exec_builtin(&mut self, tag: u8, args: &[Slot]) -> Result<Slot, String> {
        match tag {
            0 => {
                for &a in args {
                    self.print_slot(a);
                }
                Ok(Slot::void())
            }
            1 => {
                self.stdout.flush();
                Ok(Slot::void())
            }
            2 => {
                let path = match args.get(0) {
                    Some(s) if s.tag == Tag::Heap => {
                        let idx = unsafe { s.raw.idx } as usize;
                        match &self.heap[idx] {
                            HeapVal::Str(p) => p.clone(),
                            _ => return Err("open: path must be string".into()),
                        }
                    }
                    _ => return Err("open: first arg must be string".into()),
                };
                let mode = match args.get(1) {
                    Some(s) if s.tag == Tag::Int => unsafe { s.raw.int },
                    _ => return Err("open: second arg must be int".into()),
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
            3 => {
                let fd = match args.get(0) {
                    Some(s) if s.tag == Tag::File => (unsafe { s.raw.int }) as usize,
                    _ => return Err("read: first arg must be file".into()),
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
                Ok(self.alloc_heap(HeapVal::Str(String::from_utf8_lossy(&buf).into_owned())))
            }
            4 => {
                let fd = match args.get(0) {
                    Some(s) if s.tag == Tag::File => (unsafe { s.raw.int }) as usize,
                    _ => return Err("write: first arg must be file".into()),
                };
                let data: Vec<u8> = match args.get(1) {
                    Some(s) if s.tag == Tag::Heap => {
                        let idx = unsafe { s.raw.idx } as usize;
                        match &self.heap[idx] {
                            HeapVal::Str(s) => s.as_bytes().to_vec(),
                            HeapVal::Ptr(b) => b.clone(),
                            _ => return Err("write: second arg must be string/ptr".into()),
                        }
                    }
                    _ => return Err("write: second arg must be string/ptr".into()),
                };
                match self.files.get_mut(fd).and_then(|s| s.as_mut()) {
                    Some(FileHandle::Write(f)) => {
                        f.write_all(&data).map_err(|e| format!("write: {e}"))?
                    }
                    _ => return Err("write: invalid file handle for writing".into()),
                }
                Ok(Slot::int(data.len() as i64))
            }
            5 => {
                let fd = match args.get(0) {
                    Some(s) if s.tag == Tag::File => (unsafe { s.raw.int }) as usize,
                    _ => return Err("close: arg must be file".into()),
                };
                if fd < self.files.len() {
                    self.files[fd] = None;
                }
                Ok(Slot::void())
            }
            _ => Err(format!("Unknown builtin tag: {tag}")),
        }
    }
}

pub fn run(program: &Program) -> Result<(), String> {
    let mut vm = Vm::new(program)?;
    let main_idx = vm.find_func("main").ok_or("No @main function found")?;
    vm.exec_func(main_idx, &[])?;
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
        let mut vm = Vm::new(&program).unwrap();
        let main_idx = vm.find_func("main").unwrap();
        let slot = vm.exec_func(main_idx, &[]).unwrap();
        vm.slot_to_value(slot, &program)
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
        let mut vm = Vm::new(&program).unwrap();
        let main_idx = vm.find_func("main").unwrap();
        assert!(vm.exec_func(main_idx, &[]).is_err());
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
@main(): int { %p = Point { x: 10 y: 20 } %v = %p.x ret %v }
"#;
        assert!(matches!(eval_main(src), Value::Int(10)));
    }

    #[test]
    fn struct_set_field() {
        let src = r#"
struct Point { x: int y: int }
@main(): int { %p = Point { x: 1 y: 2 } set %p.x = const 99 %v = %p.x ret %v }
"#;
        assert!(matches!(eval_main(src), Value::Int(99)));
    }

    #[test]
    fn named_constant_read() {
        assert!(matches!(
            eval_main("@main(): int { %m = READ  ret %m }"),
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
    fn simple_bear_runs() {
        let src = r#"
@other_func: void { call puts("here i go, doing some thing") }
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
    while (lt %i, 10) { call puts("looping") %i = add %i, 1 }
    ret 0
}
"#;
        assert!(run_src(src).is_ok());
    }

    #[test]
    fn label_jmp_br_if() {
        let src = r#"
@main(): int {
    %i = const 0
    %n = const 5
loop:
    %cond = lt %i, %n
    br_if %cond, body, done
body:
    %i = add %i, 1
    jmp loop
done:
    ret %i
}
"#;
        assert!(matches!(eval_main(src), Value::Int(5)));
    }

    #[test]
    fn alloc_array_and_refs() {
        let src = r#"
struct Point { x: int y: int }
@main(): int {
    %n = const 3
    %arr = alloc_array Point, %n
    %i = const 0
    %p = get_index_ref %arr, %i
    %xr = get_field_ref %p, x
    store %xr, 42
    %yr = get_field_ref %p, y
    store %yr, 7
    %xv = load %xr
    %yv = load %yr
    %sum = add %xv, %yv
    ret %sum
}
"#;
        assert!(matches!(eval_main(src), Value::Int(49)));
    }

    #[test]
    fn bench2_bear_runs() {
        let src = std::fs::read_to_string("../samples/bench2.bear").unwrap();
        assert!(run_src(&src).is_ok());
    }
}
