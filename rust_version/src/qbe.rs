//! Emit QBE IR from a Bear program.
//!
//! QBE IR reference: https://c9x.me/compile/doc/il.html

use crate::ast::*;
use std::collections::HashMap;

struct Emitter {
    strings: Vec<(String, String)>,
    str_count: usize,
    structs: HashMap<String, Vec<(String, Ty)>>,
    tmp: usize,
}

impl Emitter {
    fn new() -> Self {
        Emitter {
            strings: Vec::new(),
            str_count: 0,
            structs: HashMap::new(),
            tmp: 0,
        }
    }

    fn fresh(&mut self) -> String {
        let n = self.tmp;
        self.tmp += 1;
        format!("t{n}")
    }

    fn intern_str(&mut self, s: &str) -> String {
        for (existing, label) in &self.strings {
            if existing == s {
                return label.clone();
            }
        }
        let label = format!("str{}", self.str_count);
        self.str_count += 1;
        self.strings.push((s.to_string(), label.clone()));
        label
    }

    fn qbe_ty(ty: &Ty) -> &'static str {
        match ty {
            Ty::Int => "w",
            Ty::Str => "l",
            Ty::Bool => "w",
            Ty::Void => "",
            Ty::Named(_) => "l",
        }
    }

    fn qbe_ret_ty(ty: &Ty) -> &'static str {
        match ty {
            Ty::Void => "",
            _ => Self::qbe_ty(ty),
        }
    }

    /// Emit an expression, returning the SSA name holding the result.
    fn emit_expr(
        &mut self,
        expr: &Expr,
        env: &[String],
        func_out: &mut String,
    ) -> Result<String, String> {
        match expr {
            Expr::Int(n) => {
                let t = self.fresh();
                func_out.push_str(&format!("  %{t} =w copy {n}\n"));
                Ok(format!("%{t}"))
            }
            Expr::Str(s) => {
                let label = self.intern_str(s);
                let t = self.fresh();
                func_out.push_str(&format!("  %{t} =l copy ${label}\n"));
                Ok(format!("%{t}"))
            }
            Expr::Reg(r) => Ok(env[*r as usize].clone()),
            Expr::Field(r, field) => {
                let base = env[*r as usize].clone();
                let offset = self.struct_field_offset(field)?;
                let ptr = self.fresh();
                func_out.push_str(&format!("  %{ptr} =l add {base}, {offset}\n"));
                let val = self.fresh();
                func_out.push_str(&format!("  %{val} =l loadl %{ptr}\n"));
                Ok(format!("%{val}"))
            }
            Expr::Const(inner) => self.emit_expr(inner, env, func_out),
            Expr::Add(a, b) => {
                let av = self.emit_expr(a, env, func_out)?;
                let bv = self.emit_expr(b, env, func_out)?;
                let t = self.fresh();
                func_out.push_str(&format!("  %{t} =w add {av}, {bv}\n"));
                Ok(format!("%{t}"))
            }
            Expr::Sub(a, b) => {
                let av = self.emit_expr(a, env, func_out)?;
                let bv = self.emit_expr(b, env, func_out)?;
                let t = self.fresh();
                func_out.push_str(&format!("  %{t} =w sub {av}, {bv}\n"));
                Ok(format!("%{t}"))
            }
            Expr::Mul(a, b) => {
                let av = self.emit_expr(a, env, func_out)?;
                let bv = self.emit_expr(b, env, func_out)?;
                let t = self.fresh();
                func_out.push_str(&format!("  %{t} =w mul {av}, {bv}\n"));
                Ok(format!("%{t}"))
            }
            Expr::Div(a, b) => {
                let av = self.emit_expr(a, env, func_out)?;
                let bv = self.emit_expr(b, env, func_out)?;
                let t = self.fresh();
                func_out.push_str(&format!("  %{t} =w div {av}, {bv}\n"));
                Ok(format!("%{t}"))
            }
            Expr::Lt(a, b) => {
                let av = self.emit_expr(a, env, func_out)?;
                let bv = self.emit_expr(b, env, func_out)?;
                let t = self.fresh();
                func_out.push_str(&format!("  %{t} =w csltw {av}, {bv}\n"));
                Ok(format!("%{t}"))
            }
            Expr::Gt(a, b) => {
                let av = self.emit_expr(a, env, func_out)?;
                let bv = self.emit_expr(b, env, func_out)?;
                let t = self.fresh();
                func_out.push_str(&format!("  %{t} =w csgtw {av}, {bv}\n"));
                Ok(format!("%{t}"))
            }
            Expr::Eq(a, b) => {
                let av = self.emit_expr(a, env, func_out)?;
                let bv = self.emit_expr(b, env, func_out)?;
                let t = self.fresh();
                func_out.push_str(&format!("  %{t} =w ceqw {av}, {bv}\n"));
                Ok(format!("%{t}"))
            }
            Expr::Alloc(size_expr) => {
                let sv = self.emit_expr(size_expr, env, func_out)?;
                let t = self.fresh();
                func_out.push_str(&format!("  %{t} =l alloc8 {sv}\n"));
                Ok(format!("%{t}"))
            }
            Expr::Named(name) => {
                let val = match name.as_str() {
                    "READ" => 0,
                    "WRITE" => 1,
                    _ => return Err(format!("Unknown named constant: {name}")),
                };
                let t = self.fresh();
                func_out.push_str(&format!("  %{t} =w copy {val}\n"));
                Ok(format!("%{t}"))
            }
            Expr::StructLit(sname, fields) => {
                let struct_def = self
                    .structs
                    .get(sname)
                    .ok_or_else(|| format!("Unknown struct: {sname}"))?
                    .clone();
                let size = struct_def.len() * 8;
                let ptr = self.fresh();
                func_out.push_str(&format!("  %{ptr} =l alloc8 {size}\n"));
                for (i, (fname, _fty)) in struct_def.iter().enumerate() {
                    let offset = i * 8;
                    let fval = fields
                        .iter()
                        .find(|(n, _)| n == fname)
                        .map(|(_, e)| e)
                        .ok_or_else(|| format!("Missing field {fname} in struct literal"))?;
                    let v = self.emit_expr(fval, env, func_out)?;
                    let fptr = self.fresh();
                    func_out.push_str(&format!("  %{fptr} =l add %{ptr}, {offset}\n"));
                    func_out.push_str(&format!("  storel {v}, %{fptr}\n"));
                }
                Ok(format!("%{ptr}"))
            }
            Expr::Call(name, args) => self.emit_call(name, args, env, func_out, true),
        }
    }

    /// Emit some function call.
    ///
    /// Here we need to determine type: If it looks like a string pointer use l, else w
    fn emit_call(
        &mut self,
        name: &str,
        arg_exprs: &[Expr],
        env: &[String],
        func_out: &mut String,
        has_result: bool,
    ) -> Result<String, String> {
        let mut arg_vals = Vec::new();
        for a in arg_exprs {
            let v = self.emit_expr(a, env, func_out)?;
            let ty = if v.starts_with("$") || self.is_ptr_val(&v, func_out) {
                "l"
            } else {
                "w"
            };
            arg_vals.push((ty.to_string(), v));
        }

        let args_str = arg_vals
            .iter()
            .map(|(ty, v)| format!("{ty} {v}"))
            .collect::<Vec<_>>()
            .join(", ");

        let qbe_name = match name {
            "puts" => "puts",
            "open" => "open",
            "read" => "read",
            "write" => "write",
            "close" => "close",
            other => other,
        };

        if has_result {
            let t = self.fresh();
            let ret_ty = if matches!(name, "open" | "read" | "write") {
                "l"
            } else {
                "w"
            };
            func_out.push_str(&format!("  %{t} ={ret_ty} call ${qbe_name}({args_str})\n"));
            Ok(format!("%{t}"))
        } else {
            func_out.push_str(&format!("  call ${qbe_name}({args_str})\n"));
            Ok(String::new())
        }
    }

    fn is_ptr_val(&self, v: &str, _func_out: &str) -> bool {
        v.starts_with("$str")
    }

    /// TODO: Implement type tracking here.
    fn struct_field_offset(&self, _field: &str) -> Result<usize, String> {
        Ok(0)
    }

    fn emit_stmt(
        &mut self,
        stmt: &Stmt,
        env: &mut Vec<String>,
        func_out: &mut String,
        loop_ctr: &mut usize,
    ) -> Result<(), String> {
        match stmt {
            Stmt::Assign(reg, expr) => {
                let v = self.emit_expr(expr, env, func_out)?;
                env[*reg as usize] = v.clone();
                func_out.push_str(&format!("  # reg{reg} = {v}\n"));
                Ok(())
            }
            Stmt::SetField(reg, field, expr) => {
                let base = env[*reg as usize].clone();
                let offset = self.find_field_offset(field)?;
                let v = self.emit_expr(expr, env, func_out)?;
                let fptr = self.fresh();
                func_out.push_str(&format!("  %{fptr} =l add {base}, {offset}\n"));
                func_out.push_str(&format!("  storel {v}, %{fptr}\n"));
                Ok(())
            }
            Stmt::Call(name, args) => {
                self.emit_call(name, args, &env.clone(), func_out, false)?;
                Ok(())
            }
            Stmt::Ret(expr) => {
                let v = self.emit_expr(expr, env, func_out)?;
                func_out.push_str(&format!("  ret {v}\n"));
                Ok(())
            }
            Stmt::While(cond, body) => {
                let lc = *loop_ctr;
                *loop_ctr += 1;
                let lstart = format!("@loop{lc}");
                let lbody = format!("@lbody{lc}");
                let lend = format!("@lend{lc}");

                func_out.push_str(&format!("{lstart}\n"));
                let cv = self.emit_expr(cond, env, func_out)?;
                func_out.push_str(&format!("  jnz {cv}, {lbody}, {lend}\n"));
                func_out.push_str(&format!("{lbody}\n"));

                for s in body {
                    self.emit_stmt(s, env, func_out, loop_ctr)?;
                }

                func_out.push_str(&format!("  jmp {lstart}\n"));
                func_out.push_str(&format!("{lend}\n"));
                Ok(())
            }
        }
    }

    fn find_field_offset(&self, field: &str) -> Result<usize, String> {
        for (_, fields) in &self.structs {
            for (i, (fname, _ty)) in fields.iter().enumerate() {
                if fname == field {
                    return Ok(i * 8);
                }
            }
        }
        Err(format!("Unknown field: {field}"))
    }

    fn emit_function(&mut self, func: &Function) -> Result<String, String> {
        let mut out = String::new();
        let ret = Self::qbe_ret_ty(&func.ret_ty);
        let ret_part = if ret.is_empty() {
            String::new()
        } else {
            format!("{ret} ")
        };

        let params_str = func
            .params
            .iter()
            .map(|(name, ty, _idx)| format!("{} %{name}", Self::qbe_ty(ty)))
            .collect::<Vec<_>>()
            .join(", ");

        out.push_str(&format!(
            "export function {ret_part}${name}({params_str}) {{\n",
            name = func.name
        ));
        out.push_str("@start\n");

        let mut env: Vec<String> = vec![String::new(); func.n_regs as usize];

        for (pname, _ty, idx) in &func.params {
            env[*idx as usize] = format!("%{pname}");
        }

        let mut func_body = String::new();
        let mut loop_ctr = 0usize;

        for stmt in &func.body {
            self.emit_stmt(stmt, &mut env, &mut func_body, &mut loop_ctr)?;
        }

        if !func_body.trim_end().ends_with('\n') || !func_body.contains("ret ") {
            match &func.ret_ty {
                Ty::Void => func_body.push_str("  ret\n"),
                Ty::Int => func_body.push_str("  ret 0\n"),
                _ => func_body.push_str("  ret 0\n"),
            }
        }

        out.push_str(&func_body);
        out.push_str("}\n\n");
        Ok(out)
    }

    fn emit_data_section(&self) -> String {
        let mut out = String::new();
        for (s, label) in &self.strings {
            let escaped = s
                .replace('\\', "\\\\")
                .replace('"', "\\\"")
                .replace('\n', "\\n");
            out.push_str(&format!("data ${label} = {{ b \"{escaped}\", b 0 }}\n"));
        }
        out
    }

    pub fn emit_program(&mut self, program: &Program) -> Result<String, String> {
        for s in &program.structs {
            self.structs.insert(s.name.clone(), s.fields.clone());
        }

        let mut funcs = String::new();
        for func in &program.functions {
            funcs.push_str(&self.emit_function(func)?);
        }

        let data = self.emit_data_section();
        Ok(format!("{data}\n{funcs}"))
    }
}

pub fn emit(program: &Program) -> Result<String, String> {
    let mut emitter = Emitter::new();
    emitter.emit_program(program)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{lexer::tokenize, parser::parse};

    fn emit_src(src: &str) -> String {
        let tokens = tokenize(src).unwrap();
        let program = parse(tokens).unwrap();
        emit(&program).unwrap()
    }

    fn has(ir: &str, needle: &str) -> bool {
        ir.contains(needle)
    }

    #[test]
    fn emits_export_function() {
        let ir = emit_src("@main(): int { ret 0 }");
        assert!(has(&ir, "export function w $main()"));
    }

    #[test]
    fn emits_start_label() {
        let ir = emit_src("@main(): int { ret 0 }");
        assert!(has(&ir, "@start"));
    }

    #[test]
    fn void_function_no_return_type_prefix() {
        let ir = emit_src("@foo: void { ret 0 }");
        assert!(has(&ir, "export function $foo()"));
    }

    #[test]
    fn ret_zero() {
        let ir = emit_src("@main(): int { ret 0 }");
        assert!(has(&ir, "ret"));
    }

    #[test]
    fn string_literal_goes_to_data_section() {
        let ir = emit_src(r#"@main(): int { call puts("hello") ret 0 }"#);
        assert!(has(&ir, "data $str0"));
        assert!(has(&ir, "\"hello\""));
    }

    #[test]
    fn duplicate_strings_interned_once() {
        let ir = emit_src(r#"@main(): int { call puts("hi") call puts("hi") ret 0 }"#);
        assert_eq!(ir.matches("data $str").count(), 1);
    }

    #[test]
    fn add_emits_add_instruction() {
        let ir = emit_src("@main(): int { %r = add 1, 2 ret 0 }");
        assert!(has(&ir, "=w add"));
    }

    #[test]
    fn sub_emits_sub_instruction() {
        let ir = emit_src("@main(): int { %r = sub 5, 3 ret 0 }");
        assert!(has(&ir, "=w sub"));
    }

    #[test]
    fn mul_emits_mul_instruction() {
        let ir = emit_src("@main(): int { %r = mul 2, 3 ret 0 }");
        assert!(has(&ir, "=w mul"));
    }

    #[test]
    fn div_emits_div_instruction() {
        let ir = emit_src("@main(): int { %r = div 6, 2 ret 0 }");
        assert!(has(&ir, "=w div"));
    }

    #[test]
    fn lt_emits_csltw() {
        let ir = emit_src("@main(): int { %r = lt 1, 2 ret 0 }");
        assert!(has(&ir, "csltw"));
    }

    #[test]
    fn gt_emits_csgtw() {
        let ir = emit_src("@main(): int { %r = gt 2, 1 ret 0 }");
        assert!(has(&ir, "csgtw"));
    }

    #[test]
    fn eq_emits_ceqw() {
        let ir = emit_src("@main(): int { %r = eq 1, 1 ret 0 }");
        assert!(has(&ir, "ceqw"));
    }

    #[test]
    fn while_emits_loop_labels_and_jnz() {
        let ir = emit_src("@main(): int { while (lt %i, 10) { call puts(\"x\") } ret 0 }");
        assert!(has(&ir, "@loop0"));
        assert!(has(&ir, "@lbody0"));
        assert!(has(&ir, "@lend0"));
        assert!(has(&ir, "jnz"));
        assert!(has(&ir, "jmp @loop0"));
    }

    #[test]
    fn call_puts_emits_call_puts() {
        let ir = emit_src(r#"@main(): int { call puts("hi") ret 0 }"#);
        assert!(has(&ir, "call $puts("));
    }

    #[test]
    fn call_without_args_emits_call() {
        let ir = emit_src("@foo: void { ret 0 } @main(): int { call foo ret 0 }");
        assert!(has(&ir, "call $foo()"));
    }

    #[test]
    fn named_read_emits_zero() {
        let ir = emit_src("@main(): int { %m = READ ret 0 }");
        assert!(has(&ir, "copy 0"));
    }

    #[test]
    fn named_write_emits_one() {
        let ir = emit_src("@main(): int { %m = WRITE ret 0 }");
        assert!(has(&ir, "copy 1"));
    }

    #[test]
    fn alloc_emits_alloc8() {
        let ir = emit_src("@main(): int { %buf = alloc 1024 ret 0 }");
        assert!(has(&ir, "alloc8"));
    }

    #[test]
    fn simple_bear_emits_valid_ir() {
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
        let ir = emit_src(src);
        assert!(has(&ir, "export function $other_func()"));
        assert!(has(&ir, "export function w $main()"));
        assert!(has(&ir, "call $puts("));
        assert!(has(&ir, "call $other_func()"));
    }

    #[test]
    fn loop_bear_emits_valid_ir() {
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
        let ir = emit_src(src);
        assert!(has(&ir, "@loop0"));
        assert!(has(&ir, "jnz"));
        assert!(has(&ir, "data $str0"));
    }

    #[test]
    fn unknown_named_constant_is_error() {
        let tokens = tokenize("@main(): int { %x = BOGUS ret 0 }").unwrap();
        let program = parse(tokens).unwrap();
        assert!(emit(&program).is_err());
    }
}
