use crate::ast;

const COLORS: [&str; 5] = [
    "\x1b[1;36m",
    "\x1b[1;33m",
    "\x1b[1;32m",
    "\x1b[1;34m",
    "\x1b[1;31m",
];

const RESET: &str = "\x1b[0m";

fn color(depth: usize) -> &'static str {
    COLORS[depth % COLORS.len()]
}

const BRANCH: &str = "├── ";
const LAST: &str = "└── ";
const PIPE: &str = "│   ";
const SPACE: &str = "    ";

pub struct AstPrinter;

impl AstPrinter {
    pub fn print(program: &ast::Program) {
        println!("{}program{}", color(0), RESET);

        let total = program.structs.len() + program.functions.len();
        let mut idx = 0;

        for s in &program.structs {
            let last = idx == total - 1;
            Self::print_struct(s, "", last, 1);
            idx += 1;
        }

        for f in &program.functions {
            let last = idx == total - 1;
            Self::print_function(f, "", last, 1);
            idx += 1;
        }
    }

    fn print_struct(s: &ast::StructDef, prefix: &str, is_last: bool, depth: usize) {
        let connector = if is_last { LAST } else { BRANCH };
        println!(
            "{}{}{}struct({}){}",
            prefix,
            connector,
            color(depth),
            s.name,
            RESET
        );

        let child_prefix = Self::child_prefix(prefix, is_last);
        let total = s.fields.len();
        for (i, (name, ty)) in s.fields.iter().enumerate() {
            let last = i == total - 1;
            Self::print_field(name, ty, &child_prefix, last, depth + 1);
        }
    }

    fn print_field(name: &str, ty: &ast::Ty, prefix: &str, is_last: bool, depth: usize) {
        let connector = if is_last { LAST } else { BRANCH };
        println!(
            "{}{}{}field({}: {}){}",
            prefix,
            connector,
            color(depth),
            name,
            ty,
            RESET
        );
    }

    fn print_function(f: &ast::Function, prefix: &str, is_last: bool, depth: usize) {
        let connector = if is_last { LAST } else { BRANCH };
        println!(
            "{}{}{}fn(@{}): {}{}",
            prefix,
            connector,
            color(depth),
            f.name,
            f.ret_ty,
            RESET
        );

        let child_prefix = Self::child_prefix(prefix, is_last);

        if !f.params.is_empty() {
            let has_body = !f.body.is_empty();
            let params_last = !has_body;
            let conn = if params_last { LAST } else { BRANCH };
            println!(
                "{}{}{}params{}",
                child_prefix,
                conn,
                color(depth + 1),
                RESET
            );

            let param_prefix = Self::child_prefix(&child_prefix, params_last);
            let total = f.params.len();
            for (i, (name, ty, _)) in f.params.iter().enumerate() {
                let last = i == total - 1;
                let conn = if last { LAST } else { BRANCH };
                println!(
                    "{}{}{}param({}: {}){}",
                    param_prefix,
                    conn,
                    color(depth + 2),
                    name,
                    ty,
                    RESET
                );
            }
        }

        let total = f.body.len();
        for (i, stmt) in f.body.iter().enumerate() {
            let last = i == total - 1;
            Self::print_stmt(stmt, &child_prefix, last, depth + 1);
        }
    }

    fn print_stmt(stmt: &ast::Stmt, prefix: &str, is_last: bool, depth: usize) {
        let connector = if is_last { LAST } else { BRANCH };
        match stmt {
            ast::Stmt::Assign(reg, expr) => {
                println!(
                    "{}{}{}assign(%{}){}",
                    prefix,
                    connector,
                    color(depth),
                    reg,
                    RESET
                );
                let cp = Self::child_prefix(prefix, is_last);
                Self::print_expr(expr, &cp, true, depth + 1);
            }
            ast::Stmt::SetField(reg, field, expr) => {
                println!(
                    "{}{}{}set_field(%{}.{}){}",
                    prefix,
                    connector,
                    color(depth),
                    reg,
                    field,
                    RESET
                );
                let cp = Self::child_prefix(prefix, is_last);
                Self::print_expr(expr, &cp, true, depth + 1);
            }
            ast::Stmt::Call(func, args) => {
                println!(
                    "{}{}{}call({}){}",
                    prefix,
                    connector,
                    color(depth),
                    func,
                    RESET
                );
                let cp = Self::child_prefix(prefix, is_last);
                for (i, arg) in args.iter().enumerate() {
                    let last = i == args.len() - 1;
                    Self::print_expr(arg, &cp, last, depth + 1);
                }
            }
            ast::Stmt::Ret(expr) => {
                println!("{}{}{}ret{}", prefix, connector, color(depth), RESET);
                let cp = Self::child_prefix(prefix, is_last);
                Self::print_expr(expr, &cp, true, depth + 1);
            }
            ast::Stmt::While(cond, body) => {
                println!("{}{}{}while{}", prefix, connector, color(depth), RESET);
                let cp = Self::child_prefix(prefix, is_last);

                let body_empty = body.is_empty();
                let cond_last = body_empty;
                let conn = if cond_last { LAST } else { BRANCH };
                println!("{}{}{}cond{}", cp, conn, color(depth + 1), RESET);
                let cond_p = Self::child_prefix(&cp, cond_last);
                Self::print_expr(cond, &cond_p, true, depth + 2);

                if !body_empty {
                    let conn = LAST;
                    println!("{}{}{}body{}", cp, conn, color(depth + 1), RESET);
                    let body_p = Self::child_prefix(&cp, true);
                    for (i, s) in body.iter().enumerate() {
                        let last = i == body.len() - 1;
                        Self::print_stmt(s, &body_p, last, depth + 2);
                    }
                }
            }
            ast::Stmt::Label(name) => {
                println!(
                    "{}{}{}label({}:){}",
                    prefix,
                    connector,
                    color(depth),
                    name,
                    RESET
                );
            }
            ast::Stmt::Jmp(label) => {
                println!(
                    "{}{}{}jmp({}){}",
                    prefix,
                    connector,
                    color(depth),
                    label,
                    RESET
                );
            }
            ast::Stmt::BrIf(cond, t_label, f_label) => {
                println!(
                    "{}{}{}br_if({}, {}){}",
                    prefix,
                    connector,
                    color(depth),
                    t_label,
                    f_label,
                    RESET
                );
                let cp = Self::child_prefix(prefix, is_last);
                println!("{}{}{}cond{}", cp, LAST, color(depth + 1), RESET);
                let cond_p = Self::child_prefix(&cp, true);
                Self::print_expr(cond, &cond_p, true, depth + 2);
            }
            ast::Stmt::Store(reg, expr) => {
                println!(
                    "{}{}{}store(%{}){}",
                    prefix,
                    connector,
                    color(depth),
                    reg,
                    RESET
                );
                let cp = Self::child_prefix(prefix, is_last);
                Self::print_expr(expr, &cp, true, depth + 1);
            }
        }
    }

    fn print_expr(expr: &ast::Expr, prefix: &str, is_last: bool, depth: usize) {
        let connector = if is_last { LAST } else { BRANCH };
        match expr {
            ast::Expr::Int(n) => {
                println!("{}{}{}int({}){}", prefix, connector, color(depth), n, RESET);
            }
            ast::Expr::Str(s) => {
                println!(
                    "{}{}{}str(\"{}\"){}",
                    prefix,
                    connector,
                    color(depth),
                    s,
                    RESET
                );
            }
            ast::Expr::Reg(reg) => {
                println!(
                    "{}{}{}reg(%{}){}",
                    prefix,
                    connector,
                    color(depth),
                    reg,
                    RESET
                );
            }
            ast::Expr::Field(reg, field) => {
                println!(
                    "{}{}{}field(%{}.{}){}",
                    prefix,
                    connector,
                    color(depth),
                    reg,
                    field,
                    RESET
                );
            }
            ast::Expr::Const(inner) => {
                println!("{}{}{}const{}", prefix, connector, color(depth), RESET);
                let cp = Self::child_prefix(prefix, is_last);
                Self::print_expr(inner, &cp, true, depth + 1);
            }
            ast::Expr::Alloc(inner) => {
                println!("{}{}{}alloc{}", prefix, connector, color(depth), RESET);
                let cp = Self::child_prefix(prefix, is_last);
                Self::print_expr(inner, &cp, true, depth + 1);
            }
            ast::Expr::Add(a, b) => Self::print_binop("add", a, b, prefix, is_last, depth),
            ast::Expr::Sub(a, b) => Self::print_binop("sub", a, b, prefix, is_last, depth),
            ast::Expr::Mul(a, b) => Self::print_binop("mul", a, b, prefix, is_last, depth),
            ast::Expr::Div(a, b) => Self::print_binop("div", a, b, prefix, is_last, depth),
            ast::Expr::Lt(a, b) => Self::print_binop("lt", a, b, prefix, is_last, depth),
            ast::Expr::Gt(a, b) => Self::print_binop("gt", a, b, prefix, is_last, depth),
            ast::Expr::Eq(a, b) => Self::print_binop("eq", a, b, prefix, is_last, depth),
            ast::Expr::Call(func, args) => {
                println!(
                    "{}{}{}call({}){}",
                    prefix,
                    connector,
                    color(depth),
                    func,
                    RESET
                );
                let cp = Self::child_prefix(prefix, is_last);
                for (i, arg) in args.iter().enumerate() {
                    let last = i == args.len() - 1;
                    Self::print_expr(arg, &cp, last, depth + 1);
                }
            }
            ast::Expr::AllocArray(ty_name, count) => {
                println!(
                    "{}{}{}alloc_array({}){}",
                    prefix,
                    connector,
                    color(depth),
                    ty_name,
                    RESET
                );
                let cp = Self::child_prefix(prefix, is_last);
                Self::print_expr(count, &cp, true, depth + 1);
            }
            ast::Expr::GetIndexRef(reg, idx) => {
                println!(
                    "{}{}{}get_index_ref(%{}){}",
                    prefix,
                    connector,
                    color(depth),
                    reg,
                    RESET
                );
                let cp = Self::child_prefix(prefix, is_last);
                Self::print_expr(idx, &cp, true, depth + 1);
            }
            ast::Expr::GetFieldRef(reg, field) => {
                println!(
                    "{}{}{}get_field_ref(%{}, {}){}",
                    prefix,
                    connector,
                    color(depth),
                    reg,
                    field,
                    RESET
                );
            }
            ast::Expr::Load(reg) => {
                println!(
                    "{}{}{}load(%{}){}",
                    prefix,
                    connector,
                    color(depth),
                    reg,
                    RESET
                );
            }
            ast::Expr::StructLit(ty_name, fields) => {
                println!(
                    "{}{}{}struct_lit({}){}",
                    prefix,
                    connector,
                    color(depth),
                    ty_name,
                    RESET
                );
                let cp = Self::child_prefix(prefix, is_last);
                for (i, (name, expr)) in fields.iter().enumerate() {
                    let last = i == fields.len() - 1;
                    let conn = if last { LAST } else { BRANCH };
                    println!(
                        "{}{}{}field_init({}){}",
                        cp,
                        conn,
                        color(depth + 1),
                        name,
                        RESET
                    );
                    let fcp = Self::child_prefix(&cp, last);
                    Self::print_expr(expr, &fcp, true, depth + 2);
                }
            }
            ast::Expr::Named(name) => {
                println!(
                    "{}{}{}named({}){}",
                    prefix,
                    connector,
                    color(depth),
                    name,
                    RESET
                );
            }
        }
    }

    fn print_binop(
        op: &str,
        a: &ast::Expr,
        b: &ast::Expr,
        prefix: &str,
        is_last: bool,
        depth: usize,
    ) {
        let connector = if is_last { LAST } else { BRANCH };
        println!("{}{}{}{}{}", prefix, connector, color(depth), op, RESET);
        let cp = Self::child_prefix(prefix, is_last);
        Self::print_expr(a, &cp, false, depth + 1);
        Self::print_expr(b, &cp, true, depth + 1);
    }

    fn child_prefix(prefix: &str, is_last: bool) -> String {
        format!("{}{}", prefix, if is_last { SPACE } else { PIPE })
    }
}
