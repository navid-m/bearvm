//! Emit LLVM IR (textual .ll) from a Bear program.
//! LLVM IR reference: https://llvm.org/docs/LangRef.html

const std = @import("std");
const lexer = @import("lexer.zig");

const Emitter = struct {
    alloc: std.mem.Allocator,
    out: std.ArrayList(u8),
    strings: std.ArrayList(StringEntry),
    str_count: usize,
    tmp: usize,
    loop_ctr: usize,
    structs: std.StringHashMap([]const lexer.StructField),

    const StringEntry = struct {
        content: []const u8,
        label: []const u8,
        len: usize,
    };

    fn init(alloc: std.mem.Allocator) Emitter {
        return .{
            .alloc = alloc,
            .out = .empty,
            .strings = .empty,
            .str_count = 0,
            .tmp = 0,
            .loop_ctr = 0,
            .structs = std.StringHashMap([]const lexer.StructField).init(alloc),
        };
    }

    fn deinit(self: *Emitter) void {
        for (self.strings.items) |e| self.alloc.free(e.label);
        self.strings.deinit(self.alloc);
        self.structs.deinit();
        self.out.deinit(self.alloc);
    }

    fn fresh(self: *Emitter) ![]const u8 {
        const n = self.tmp;
        self.tmp += 1;
        return std.fmt.allocPrint(self.alloc, "%t{d}", .{n});
    }

    fn internStr(self: *Emitter, s: []const u8) ![]const u8 {
        for (self.strings.items) |e| {
            if (std.mem.eql(u8, e.content, s)) return e.label;
        }
        const label = try std.fmt.allocPrint(self.alloc, "@.str{d}", .{self.str_count});
        self.str_count += 1;
        try self.strings.append(self.alloc, .{ .content = s, .label = label, .len = s.len + 1 });
        return label;
    }

    fn llvmTy(ty: lexer.Ty) []const u8 {
        return switch (ty) {
            .int => "i64",
            .str => "ptr",
            .bool_ => "i1",
            .void_ => "void",
            .named => "ptr",
        };
    }

    fn fieldOffset(self: *Emitter, field: []const u8) !usize {
        var it = self.structs.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.*, 0..) |f, i| {
                if (std.mem.eql(u8, f.name, field)) return i;
            }
        }
        return error.UnknownField;
    }

    fn emitExpr(self: *Emitter, expr: *lexer.Expr, env: [][]const u8) (error{ OutOfMemory, UnknownField, UnknownNamedConstant, UnknownStruct, MissingField } || std.fs.File.WriteError)![]const u8 {
        const w = self.out.writer(self.alloc);
        switch (expr.*) {
            .int => |n| {
                const t = try self.fresh();
                try w.print("  {s} = add i64 0, {d}\n", .{ t, n });
                return t;
            },
            .str => |s| {
                const label = try self.internStr(s);
                const t = try self.fresh();
                try w.print("  {s} = getelementptr inbounds [{d} x i8], ptr {s}, i64 0, i64 0\n", .{ t, s.len + 1, label });
                return t;
            },
            .reg => |r| return try self.alloc.dupe(u8, env[r]),
            .field => |f| {
                const base = env[f.reg];
                const idx = try self.fieldOffset(f.field);
                const gep = try self.fresh();
                try w.print("  {s} = getelementptr inbounds i64, ptr {s}, i64 {d}\n", .{ gep, base, idx });
                const val = try self.fresh();
                try w.print("  {s} = load i64, ptr {s}\n", .{ val, gep });
                return val;
            },
            .const_ => |inner| return self.emitExpr(inner, env),
            .add => |b| {
                const av = try self.emitExpr(b.a, env);
                const bv = try self.emitExpr(b.b, env);
                const t = try self.fresh();
                try w.print("  {s} = add i64 {s}, {s}\n", .{ t, av, bv });
                return t;
            },
            .sub => |b| {
                const av = try self.emitExpr(b.a, env);
                const bv = try self.emitExpr(b.b, env);
                const t = try self.fresh();
                try w.print("  {s} = sub i64 {s}, {s}\n", .{ t, av, bv });
                return t;
            },
            .mul => |b| {
                const av = try self.emitExpr(b.a, env);
                const bv = try self.emitExpr(b.b, env);
                const t = try self.fresh();
                try w.print("  {s} = mul i64 {s}, {s}\n", .{ t, av, bv });
                return t;
            },
            .div => |b| {
                const av = try self.emitExpr(b.a, env);
                const bv = try self.emitExpr(b.b, env);
                const t = try self.fresh();
                try w.print("  {s} = sdiv i64 {s}, {s}\n", .{ t, av, bv });
                return t;
            },
            .lt => |b| {
                const av = try self.emitExpr(b.a, env);
                const bv = try self.emitExpr(b.b, env);
                const cmp = try self.fresh();
                try w.print("  {s} = icmp slt i64 {s}, {s}\n", .{ cmp, av, bv });
                const t = try self.fresh();
                try w.print("  {s} = zext i1 {s} to i64\n", .{ t, cmp });
                return t;
            },
            .gt => |b| {
                const av = try self.emitExpr(b.a, env);
                const bv = try self.emitExpr(b.b, env);
                const cmp = try self.fresh();
                try w.print("  {s} = icmp sgt i64 {s}, {s}\n", .{ cmp, av, bv });
                const t = try self.fresh();
                try w.print("  {s} = zext i1 {s} to i64\n", .{ t, cmp });
                return t;
            },
            .eq => |b| {
                const av = try self.emitExpr(b.a, env);
                const bv = try self.emitExpr(b.b, env);
                const cmp = try self.fresh();
                try w.print("  {s} = icmp eq i64 {s}, {s}\n", .{ cmp, av, bv });
                const t = try self.fresh();
                try w.print("  {s} = zext i1 {s} to i64\n", .{ t, cmp });
                return t;
            },
            .alloc => |size_expr| {
                const sv = try self.emitExpr(size_expr, env);
                const t = try self.fresh();
                try w.print("  {s} = alloca i8, i64 {s}, align 8\n", .{ t, sv });
                return t;
            },
            .named => |name| {
                const val: i64 = if (std.mem.eql(u8, name, "READ"))
                    0
                else if (std.mem.eql(u8, name, "WRITE"))
                    1
                else
                    return error.UnknownNamedConstant;
                const t = try self.fresh();
                try w.print("  {s} = add i64 0, {d}\n", .{ t, val });
                return t;
            },
            .struct_lit => |sl| {
                const fields = self.structs.get(sl.name) orelse return error.UnknownStruct;
                const size = fields.len * 8;
                const ptr = try self.fresh();
                try w.print("  {s} = alloca i8, i64 {d}, align 8\n", .{ ptr, size });
                for (fields, 0..) |fd, i| {
                    var fval: ?*lexer.Expr = null;
                    for (sl.fields.items) |fi| {
                        if (std.mem.eql(u8, fi.name, fd.name)) {
                            fval = fi.expr;
                            break;
                        }
                    }
                    const v = try self.emitExpr(fval orelse return error.MissingField, env);
                    const gep = try self.fresh();
                    try w.print("  {s} = getelementptr inbounds i64, ptr {s}, i64 {d}\n", .{ gep, ptr, i });
                    try w.print("  store i64 {s}, ptr {s}\n", .{ v, gep });
                }
                return ptr;
            },
            .call => |c| return self.emitCallExpr(c.name, c.args.items, env),
        }
    }

    /// Build the argument list string for a call, tracking which args are ptrs.
    fn buildArgsStr(self: *Emitter, name: []const u8, arg_exprs: []*lexer.Expr, env: [][]const u8) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        const bw = buf.writer(self.alloc);
        for (arg_exprs, 0..) |a, i| {
            const is_str = (a.* == .str or a.* == .const_ and a.const_.* == .str);
            const v = try self.emitExpr(a, env);
            const ty: []const u8 = if (is_str or
                (std.mem.eql(u8, name, "puts") and i == 0)) "ptr" else "i64";
            if (i > 0) try bw.writeAll(", ");
            try bw.print("{s} {s}", .{ ty, v });
        }
        return buf.toOwnedSlice(self.alloc);
    }

    fn emitCallExpr(self: *Emitter, name: []const u8, arg_exprs: []*lexer.Expr, env: [][]const u8) ![]const u8 {
        const w = self.out.writer(self.alloc);
        const args_str = try self.buildArgsStr(name, arg_exprs, env);
        const ret_ty: []const u8 = if (std.mem.eql(u8, name, "puts"))
            "i32"
        else
            "i64";
        const t = try self.fresh();
        try w.print("  {s} = call {s} @{s}({s})\n", .{ t, ret_ty, name, args_str });
        return t;
    }

    fn emitCallStmt(self: *Emitter, name: []const u8, arg_exprs: []*lexer.Expr, env: [][]const u8) !void {
        const w = self.out.writer(self.alloc);
        const args_str = try self.buildArgsStr(name, arg_exprs, env);
        const ret_ty: []const u8 = if (std.mem.eql(u8, name, "puts")) "i32" else "i64";
        const t = try self.fresh();
        try w.print("  {s} = call {s} @{s}({s})\n", .{ t, ret_ty, name, args_str });
    }

    fn emitStmt(self: *Emitter, stmt: *const lexer.Stmt, env: [][]const u8, func_name: []const u8) !void {
        const w = self.out.writer(self.alloc);
        switch (stmt.*) {
            .assign => |a| {
                const v = try self.emitExpr(a.expr, env);
                env[a.reg] = v;
            },
            .set_field => |sf| {
                const base = env[sf.reg];
                const idx = try self.fieldOffset(sf.field);
                const v = try self.emitExpr(sf.expr, env);
                const gep = try self.fresh();
                try w.print("  {s} = getelementptr inbounds i64, ptr {s}, i64 {d}\n", .{ gep, base, idx });
                try w.print("  store i64 {s}, ptr {s}\n", .{ v, gep });
            },
            .call => |c| try self.emitCallStmt(c.name, c.args.items, env),
            .ret => |e| {
                const v = try self.emitExpr(e, env);
                try w.print("  ret i64 {s}\n", .{v});
            },
            .while_ => |wh| {
                const lc = self.loop_ctr;
                self.loop_ctr += 1;
                const lcheck = try std.fmt.allocPrint(self.alloc, "{s}.loop{d}.check", .{ func_name, lc });
                const lbody = try std.fmt.allocPrint(self.alloc, "{s}.loop{d}.body", .{ func_name, lc });
                const lend = try std.fmt.allocPrint(self.alloc, "{s}.loop{d}.end", .{ func_name, lc });

                try w.print("  br label %{s}\n", .{lcheck});
                try w.print("{s}:\n", .{lcheck});
                const cv = try self.emitExpr(wh.cond, env);
                const cond1 = try self.fresh();
                try w.print("  {s} = icmp ne i64 {s}, 0\n", .{ cond1, cv });
                try w.print("  br i1 {s}, label %{s}, label %{s}\n", .{ cond1, lbody, lend });
                try w.print("{s}:\n", .{lbody});
                for (wh.body.items) |*s| try self.emitStmt(s, env, func_name);
                try w.print("  br label %{s}\n", .{lcheck});
                try w.print("{s}:\n", .{lend});
            },
            .label => |name| try w.print("{s}:\n", .{name}),
            .jmp => |target| try w.print("  br label %{s}\n", .{target}),
            .br_if => |br| {
                const cond_v = env[br.cond];
                const cond1 = try self.fresh();
                try w.print("  {s} = icmp ne i64 {s}, 0\n", .{ cond1, cond_v });
                try w.print("  br i1 {s}, label %{s}, label %{s}\n", .{ cond1, br.true_label, br.false_label });
            },
        }
    }

    fn emitFunction(self: *Emitter, func: *const lexer.Function) !void {
        const w = self.out.writer(self.alloc);
        const ret = if (func.ret_ty == .void_) "void" else "i64";
        try w.print("define {s} @{s}(", .{ ret, func.name });
        for (func.params.items, 0..) |p, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("{s} %{s}", .{ llvmTy(p.ty), p.name });
        }
        try w.writeAll(") {\nentry:\n");

        const env = try self.alloc.alloc([]const u8, func.n_regs);
        defer self.alloc.free(env);
        for (env) |*e| e.* = "undef";
        for (func.params.items) |p| {
            env[p.idx] = try std.fmt.allocPrint(self.alloc, "%{s}", .{p.name});
        }

        const body_start = self.out.items.len;
        for (func.body.items) |*s| try self.emitStmt(s, env, func.name);

        const body_text = self.out.items[body_start..];
        if (std.mem.indexOf(u8, body_text, "\n  ret ") == null and
            !std.mem.endsWith(u8, std.mem.trimRight(u8, body_text, "\n"), "  ret void") and
            !std.mem.endsWith(u8, std.mem.trimRight(u8, body_text, "\n"), "  ret i64"))
        {
            if (func.ret_ty == .void_) {
                try w.writeAll("  ret void\n");
            } else {
                try w.writeAll("  ret i64 0\n");
            }
        }

        try w.writeAll("}\n\n");
    }

    fn emitDeclarations(self: *Emitter) !void {
        const w = self.out.writer(self.alloc);
        try w.writeAll("declare i32 @puts(ptr)\n");
        try w.writeAll("declare i64 @open(ptr, i64)\n");
        try w.writeAll("declare i64 @read(i64, ptr, i64)\n");
        try w.writeAll("declare i64 @write(i64, ptr, i64)\n");
        try w.writeAll("declare i64 @close(i64)\n");
        try w.writeByte('\n');
    }

    fn emitDataSection(self: *Emitter) !void {
        const w = self.out.writer(self.alloc);
        for (self.strings.items) |e| {
            try w.print("{s} = private unnamed_addr constant [{d} x i8] c\"", .{ e.label, e.len });
            for (e.content) |ch| {
                switch (ch) {
                    '\n' => try w.writeAll("\\0A"),
                    '"' => try w.writeAll("\\22"),
                    '\\' => try w.writeAll("\\5C"),
                    else => try w.writeByte(ch),
                }
            }
            try w.writeAll("\\00\"\n");
        }
        if (self.strings.items.len > 0) try w.writeByte('\n');
    }

    pub fn emitProgram(self: *Emitter, program: *const lexer.Program) ![]const u8 {
        for (program.structs.items) |*s| {
            try self.structs.put(s.name, s.fields.items);
        }

        var func_buf: std.ArrayList(u8) = .empty;
        const saved = self.out;
        self.out = func_buf;
        for (program.functions.items) |*f| try self.emitFunction(f);
        func_buf = self.out;
        self.out = saved;

        const w = self.out.writer(self.alloc);
        try w.writeAll("; Bear LLVM IR\n");
        try w.writeAll("target triple = \"x86_64-unknown-linux-gnu\"\n\n");
        try self.emitDeclarations();
        try self.emitDataSection();
        try self.out.appendSlice(self.alloc, func_buf.items);
        func_buf.deinit(self.alloc);

        return self.out.toOwnedSlice(self.alloc);
    }
};

pub fn emit(program: *const lexer.Program, alloc: std.mem.Allocator) ![]const u8 {
    var e = Emitter.init(alloc);
    defer e.deinit();
    return e.emitProgram(program);
}
