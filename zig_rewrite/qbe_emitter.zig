//! Emit QBE IL from a Bear program.
//! QBE IL reference: https://c9x.me/compile/doc/il.html

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

    const StringEntry = struct { content: []const u8, label: []const u8 };

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
        return std.fmt.allocPrint(self.alloc, "t{d}", .{n});
    }

    fn internStr(self: *Emitter, s: []const u8) ![]const u8 {
        for (self.strings.items) |e| {
            if (std.mem.eql(u8, e.content, s)) return e.label;
        }
        const label = try std.fmt.allocPrint(self.alloc, "str{d}", .{self.str_count});
        self.str_count += 1;
        try self.strings.append(self.alloc, .{ .content = s, .label = label });
        return label;
    }

    fn qbeTy(ty: lexer.Ty) []const u8 {
        return switch (ty) {
            .int => "w",
            .str => "l",
            .bool_ => "w",
            .void_ => "",
            .named => "l",
        };
    }

    fn qbeRetTy(ty: lexer.Ty) []const u8 {
        return if (ty == .void_) "" else qbeTy(ty);
    }

    fn fieldOffset(self: *Emitter, field: []const u8) !usize {
        var it = self.structs.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.*, 0..) |f, i| {
                if (std.mem.eql(u8, f.name, field)) return i * 8;
            }
        }
        return error.UnknownField;
    }

    fn emitExpr(self: *Emitter, expr: *lexer.Expr, env: [][]const u8) (error{ OutOfMemory, UnknownField, UnknownNamedConstant, UnknownStruct, MissingField } || std.fs.File.WriteError)![]const u8 {
        const w = self.out.writer(self.alloc);
        switch (expr.*) {
            .int => |n| {
                const t = try self.fresh();
                try w.print("  %{s} =w copy {d}\n", .{ t, n });
                return std.fmt.allocPrint(self.alloc, "%{s}", .{t});
            },
            .str => |s| {
                const label = try self.internStr(s);
                const t = try self.fresh();
                try w.print("  %{s} =l copy ${s}\n", .{ t, label });
                return std.fmt.allocPrint(self.alloc, "%{s}", .{t});
            },
            .reg => |r| return try self.alloc.dupe(u8, env[r]),
            .field => |f| {
                const base = env[f.reg];
                const offset = try self.fieldOffset(f.field);
                const ptr = try self.fresh();
                try w.print("  %{s} =l add {s}, {d}\n", .{ ptr, base, offset });
                const val = try self.fresh();
                try w.print("  %{s} =l loadl %{s}\n", .{ val, ptr });
                return std.fmt.allocPrint(self.alloc, "%{s}", .{val});
            },
            .const_ => |inner| return self.emitExpr(inner, env),
            .add => |b| {
                const av = try self.emitExpr(b.a, env);
                const bv = try self.emitExpr(b.b, env);
                const t = try self.fresh();
                try w.print("  %{s} =w add {s}, {s}\n", .{ t, av, bv });
                return std.fmt.allocPrint(self.alloc, "%{s}", .{t});
            },
            .sub => |b| {
                const av = try self.emitExpr(b.a, env);
                const bv = try self.emitExpr(b.b, env);
                const t = try self.fresh();
                try w.print("  %{s} =w sub {s}, {s}\n", .{ t, av, bv });
                return std.fmt.allocPrint(self.alloc, "%{s}", .{t});
            },
            .mul => |b| {
                const av = try self.emitExpr(b.a, env);
                const bv = try self.emitExpr(b.b, env);
                const t = try self.fresh();
                try w.print("  %{s} =w mul {s}, {s}\n", .{ t, av, bv });
                return std.fmt.allocPrint(self.alloc, "%{s}", .{t});
            },
            .div => |b| {
                const av = try self.emitExpr(b.a, env);
                const bv = try self.emitExpr(b.b, env);
                const t = try self.fresh();
                try w.print("  %{s} =w div {s}, {s}\n", .{ t, av, bv });
                return std.fmt.allocPrint(self.alloc, "%{s}", .{t});
            },
            .lt => |b| {
                const av = try self.emitExpr(b.a, env);
                const bv = try self.emitExpr(b.b, env);
                const t = try self.fresh();
                try w.print("  %{s} =w csltw {s}, {s}\n", .{ t, av, bv });
                return std.fmt.allocPrint(self.alloc, "%{s}", .{t});
            },
            .gt => |b| {
                const av = try self.emitExpr(b.a, env);
                const bv = try self.emitExpr(b.b, env);
                const t = try self.fresh();
                try w.print("  %{s} =w csgtw {s}, {s}\n", .{ t, av, bv });
                return std.fmt.allocPrint(self.alloc, "%{s}", .{t});
            },
            .eq => |b| {
                const av = try self.emitExpr(b.a, env);
                const bv = try self.emitExpr(b.b, env);
                const t = try self.fresh();
                try w.print("  %{s} =w ceqw {s}, {s}\n", .{ t, av, bv });
                return std.fmt.allocPrint(self.alloc, "%{s}", .{t});
            },
            .alloc => |size_expr| {
                const sv = try self.emitExpr(size_expr, env);
                const t = try self.fresh();
                try w.print("  %{s} =l alloc8 {s}\n", .{ t, sv });
                return std.fmt.allocPrint(self.alloc, "%{s}", .{t});
            },
            .named => |name| {
                const val: i64 = if (std.mem.eql(u8, name, "READ"))
                    0
                else if (std.mem.eql(u8, name, "WRITE"))
                    1
                else
                    return error.UnknownNamedConstant;
                const t = try self.fresh();
                try w.print("  %{s} =w copy {d}\n", .{ t, val });
                return std.fmt.allocPrint(self.alloc, "%{s}", .{t});
            },
            .struct_lit => |sl| {
                const fields = self.structs.get(sl.name) orelse return error.UnknownStruct;
                const size = fields.len * 8;
                const ptr = try self.fresh();
                try w.print("  %{s} =l alloc8 {d}\n", .{ ptr, size });
                for (fields, 0..) |fd, i| {
                    const offset = i * 8;
                    var fval: ?*lexer.Expr = null;
                    for (sl.fields.items) |fi| {
                        if (std.mem.eql(u8, fi.name, fd.name)) {
                            fval = fi.expr;
                            break;
                        }
                    }
                    const v = try self.emitExpr(fval orelse return error.MissingField, env);
                    const fptr = try self.fresh();
                    try w.print("  %{s} =l add %{s}, {d}\n", .{ fptr, ptr, offset });
                    try w.print("  storel {s}, %{s}\n", .{ v, fptr });
                }
                return std.fmt.allocPrint(self.alloc, "%{s}", .{ptr});
            },
            .call => |c| return self.emitCallExpr(c.name, c.args.items, env),
        }
    }

    fn isPtr(v: []const u8) bool {
        return std.mem.startsWith(u8, v, "$str");
    }

    fn buildArgsStr(self: *Emitter, arg_exprs: []*lexer.Expr, env: [][]const u8) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        const bw = buf.writer(self.alloc);
        for (arg_exprs, 0..) |a, i| {
            const v = try self.emitExpr(a, env);
            const ty: []const u8 = if (isPtr(v)) "l" else "w";
            if (i > 0) try bw.writeAll(", ");
            try bw.print("{s} {s}", .{ ty, v });
        }
        return buf.toOwnedSlice(self.alloc);
    }

    fn emitCallExpr(self: *Emitter, name: []const u8, arg_exprs: []*lexer.Expr, env: [][]const u8) ![]const u8 {
        const w = self.out.writer(self.alloc);
        const args_str = try self.buildArgsStr(arg_exprs, env);
        const ret_ty: []const u8 = if (std.mem.eql(u8, name, "open") or
            std.mem.eql(u8, name, "read") or
            std.mem.eql(u8, name, "write")) "l" else "w";
        const t = try self.fresh();
        try w.print("  %{s} ={s} call ${s}({s})\n", .{ t, ret_ty, name, args_str });
        return std.fmt.allocPrint(self.alloc, "%{s}", .{t});
    }

    fn emitCallStmt(self: *Emitter, name: []const u8, arg_exprs: []*lexer.Expr, env: [][]const u8) !void {
        const w = self.out.writer(self.alloc);
        const args_str = try self.buildArgsStr(arg_exprs, env);
        try w.print("  call ${s}({s})\n", .{ name, args_str });
    }

    fn emitStmt(self: *Emitter, stmt: *const lexer.Stmt, env: [][]const u8) !void {
        const w = self.out.writer(self.alloc);
        switch (stmt.*) {
            .assign => |a| {
                const v = try self.emitExpr(a.expr, env);
                env[a.reg] = v;
            },
            .set_field => |sf| {
                const base = env[sf.reg];
                const offset = try self.fieldOffset(sf.field);
                const v = try self.emitExpr(sf.expr, env);
                const fptr = try self.fresh();
                try w.print("  %{s} =l add {s}, {d}\n", .{ fptr, base, offset });
                try w.print("  storel {s}, %{s}\n", .{ v, fptr });
            },
            .call => |c| try self.emitCallStmt(c.name, c.args.items, env),
            .ret => |e| {
                const v = try self.emitExpr(e, env);
                try w.print("  ret {s}\n", .{v});
            },
            .while_ => |wh| {
                const lc = self.loop_ctr;
                self.loop_ctr += 1;
                try w.print("@loop{d}\n", .{lc});
                const cv = try self.emitExpr(wh.cond, env);
                try w.print("  jnz {s}, @lbody{d}, @lend{d}\n", .{ cv, lc, lc });
                try w.print("@lbody{d}\n", .{lc});
                for (wh.body.items) |*s| try self.emitStmt(s, env);
                try w.print("  jmp @loop{d}\n", .{lc});
                try w.print("@lend{d}\n", .{lc});
            },
        }
    }

    fn emitFunction(self: *Emitter, func: *const lexer.Function) !void {
        const w = self.out.writer(self.alloc);
        const ret = qbeRetTy(func.ret_ty);
        if (ret.len > 0) {
            try w.print("export function {s} ${s}(", .{ ret, func.name });
        } else {
            try w.print("export function ${s}(", .{func.name});
        }
        for (func.params.items, 0..) |p, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("{s} %{s}", .{ qbeTy(p.ty), p.name });
        }
        try w.writeAll(") {\n@start\n");

        const env = try self.alloc.alloc([]const u8, func.n_regs);
        defer self.alloc.free(env);
        for (env) |*e| e.* = "";
        for (func.params.items) |p| {
            env[p.idx] = try std.fmt.allocPrint(self.alloc, "%{s}", .{p.name});
        }

        const body_start = self.out.items.len;
        for (func.body.items) |*s| try self.emitStmt(s, env);
        const body_text = self.out.items[body_start..];

        if (std.mem.indexOf(u8, body_text, "\n  ret ") == null and
            !std.mem.endsWith(u8, std.mem.trimRight(u8, body_text, "\n"), "  ret"))
        {
            if (func.ret_ty == .void_) {
                try w.writeAll("  ret\n");
            } else {
                try w.writeAll("  ret 0\n");
            }
        }

        try w.writeAll("}\n\n");
    }

    fn emitDataSection(self: *Emitter) !void {
        const w = self.out.writer(self.alloc);
        for (self.strings.items) |e| {
            try w.writeAll("data $");
            try w.writeAll(e.label);
            try w.writeAll(" = { b \"");
            for (e.content) |ch| {
                switch (ch) {
                    '\n' => try w.writeAll("\\n"),
                    '"' => try w.writeAll("\\\""),
                    '\\' => try w.writeAll("\\\\"),
                    else => try w.writeByte(ch),
                }
            }
            try w.writeAll("\", b 0 }\n");
        }
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

        try self.emitDataSection();
        try self.out.append(self.alloc, '\n');
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
