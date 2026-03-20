//! Emit LLVM IR (textual .ll) from a Bear program.
//! LLVM IR reference: https://llvm.org/docs/LangRef.html

const std = @import("std");
const lexer = @import("lexer.zig");

const TmpId = u32;

const Slot = union(enum) {
    tmp: TmpId,
    param: []const u8,
    undef,
};

const StringEntry = struct { content: []const u8, idx: usize, byte_len: usize };

const Emitter = struct {
    alloc: std.mem.Allocator,
    out: std.ArrayListUnmanaged(u8),
    strings: std.ArrayListUnmanaged(StringEntry),
    str_count: usize,
    tmp: TmpId,
    loop_ctr: u32,
    structs: std.StringHashMapUnmanaged([]const lexer.StructField),

    fn init(alloc: std.mem.Allocator) Emitter {
        return .{
            .alloc = alloc,
            .out = .empty,
            .strings = .empty,
            .str_count = 0,
            .tmp = 0,
            .loop_ctr = 0,
            .structs = .empty,
        };
    }

    fn deinit(self: *Emitter) void {
        self.strings.deinit(self.alloc);
        self.structs.deinit(self.alloc);
        self.out.deinit(self.alloc);
    }

    inline fn fresh(self: *Emitter) TmpId {
        const id = self.tmp;
        self.tmp += 1;
        return id;
    }

    inline fn writeTmp(self: *Emitter, id: TmpId) !void {
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "%t{d}", .{id}) catch unreachable;
        try self.out.appendSlice(self.alloc, s);
    }

    inline fn writeSlot(self: *Emitter, slot: Slot) !void {
        switch (slot) {
            .tmp => |id| try self.writeTmp(id),
            .param => |name| {
                try self.out.append(self.alloc, '%');
                try self.out.appendSlice(self.alloc, name);
            },
            .undef => try self.out.appendSlice(self.alloc, "undef"),
        }
    }

    fn internStr(self: *Emitter, s: []const u8) !usize {
        for (self.strings.items) |e| {
            if (std.mem.eql(u8, e.content, s)) return e.idx;
        }
        const idx = self.str_count;
        self.str_count += 1;
        try self.strings.append(self.alloc, .{ .content = s, .idx = idx, .byte_len = s.len + 1 });
        return idx;
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

    fn emitExpr(self: *Emitter, expr: *lexer.Expr, env: []Slot) !Slot {
        switch (expr.*) {
            .int => |n| {
                const t = self.fresh();
                try self.out.appendSlice(self.alloc, "  ");
                try self.writeTmp(t);
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, " = add i64 0, {d}\n", .{n}) catch unreachable;
                try self.out.appendSlice(self.alloc, s);
                return .{ .tmp = t };
            },
            .str => |s| {
                const idx = try self.internStr(s);
                const t = self.fresh();
                try self.out.appendSlice(self.alloc, "  ");
                try self.writeTmp(t);
                var buf: [64]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, " = getelementptr inbounds [{d} x i8], ptr @.str{d}, i64 0, i64 0\n", .{ s.len + 1, idx }) catch unreachable;
                try self.out.appendSlice(self.alloc, line);
                return .{ .tmp = t };
            },
            .reg => |r| return env[r],
            .field => |f| {
                const base = env[f.reg];
                const idx = try self.fieldOffset(f.field);
                const gep = self.fresh();
                try self.out.appendSlice(self.alloc, "  ");
                try self.writeTmp(gep);
                try self.out.appendSlice(self.alloc, " = getelementptr inbounds i64, ptr ");
                try self.writeSlot(base);
                var buf: [24]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, ", i64 {d}\n", .{idx}) catch unreachable;
                try self.out.appendSlice(self.alloc, s);
                const val = self.fresh();
                try self.out.appendSlice(self.alloc, "  ");
                try self.writeTmp(val);
                try self.out.appendSlice(self.alloc, " = load i64, ptr ");
                try self.writeTmp(gep);
                try self.out.append(self.alloc, '\n');
                return .{ .tmp = val };
            },
            .const_ => |inner| return self.emitExpr(inner, env),
            .add => |b| return self.emitBinOp(b, env, " = add i64 "),
            .sub => |b| return self.emitBinOp(b, env, " = sub i64 "),
            .mul => |b| return self.emitBinOp(b, env, " = mul i64 "),
            .div => |b| return self.emitBinOp(b, env, " = sdiv i64 "),
            .lt => |b| return self.emitCmp(b, env, "slt"),
            .gt => |b| return self.emitCmp(b, env, "sgt"),
            .le => |b| return self.emitCmp(b, env, "sle"),
            .ge => |b| return self.emitCmp(b, env, "sge"),
            .eq => |b| return self.emitCmp(b, env, "eq"),
            .alloc => |size_expr| {
                const sv = try self.emitExpr(size_expr, env);
                const t = self.fresh();
                try self.out.appendSlice(self.alloc, "  ");
                try self.writeTmp(t);
                try self.out.appendSlice(self.alloc, " = alloca i8, i64 ");
                try self.writeSlot(sv);
                try self.out.appendSlice(self.alloc, ", align 8\n");
                return .{ .tmp = t };
            },
            .named => |name| {
                const val: i64 = if (name.len > 0 and name[0] == 'R') 0 else if (name.len > 0 and name[0] == 'W') 1 else return error.UnknownNamedConstant;
                const t = self.fresh();
                try self.out.appendSlice(self.alloc, "  ");
                try self.writeTmp(t);
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, " = add i64 0, {d}\n", .{val}) catch unreachable;
                try self.out.appendSlice(self.alloc, s);
                return .{ .tmp = t };
            },
            .struct_lit => |sl| {
                const fields = self.structs.get(sl.name) orelse return error.UnknownStruct;
                const size = fields.len * 8;
                const ptr = self.fresh();
                try self.out.appendSlice(self.alloc, "  ");
                try self.writeTmp(ptr);
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, " = alloca i8, i64 {d}, align 8\n", .{size}) catch unreachable;
                try self.out.appendSlice(self.alloc, s);
                for (fields, 0..) |fd, i| {
                    var fval: ?*lexer.Expr = null;
                    for (sl.fields.items) |fi| {
                        if (std.mem.eql(u8, fi.name, fd.name)) {
                            fval = fi.expr;
                            break;
                        }
                    }
                    const v = try self.emitExpr(fval orelse return error.MissingField, env);
                    const gep = self.fresh();
                    try self.out.appendSlice(self.alloc, "  ");
                    try self.writeTmp(gep);
                    try self.out.appendSlice(self.alloc, " = getelementptr inbounds i64, ptr ");
                    try self.writeTmp(ptr);
                    const off = std.fmt.bufPrint(&buf, ", i64 {d}\n", .{i}) catch unreachable;
                    try self.out.appendSlice(self.alloc, off);
                    try self.out.appendSlice(self.alloc, "  store i64 ");
                    try self.writeSlot(v);
                    try self.out.appendSlice(self.alloc, ", ptr ");
                    try self.writeTmp(gep);
                    try self.out.append(self.alloc, '\n');
                }
                return .{ .tmp = ptr };
            },
            .call => |c| return self.emitCallExpr(c.name, c.args.items, env),
            // spawn/sync: not supported in LLVM backend, treat spawn as a plain call
            .spawn => |sp| return self.emitCallExpr(sp.name, sp.args.items, env),
            .sync => |r| return env[r],
            .phi => |arms| {
                const t = self.fresh();
                try self.out.appendSlice(self.alloc, "  ");
                try self.writeTmp(t);
                try self.out.appendSlice(self.alloc, " = phi i64");
                for (arms.items, 0..) |arm, i| {
                    if (i > 0) try self.out.append(self.alloc, ',');
                    try self.out.appendSlice(self.alloc, " [ ");
                    try self.writeSlot(env[arm.reg]);
                    try self.out.appendSlice(self.alloc, ", %");
                    try self.out.appendSlice(self.alloc, arm.label);
                    try self.out.appendSlice(self.alloc, " ]");
                }
                try self.out.append(self.alloc, '\n');
                return .{ .tmp = t };
            },
            .free, .arena_create, .arena_alloc,
            .alloc_type, .alloc_array, .load, .get_field_ref, .get_index_ref => return error.UnsupportedExpr,
        }
    }

    fn emitBinOp(self: *Emitter, b: lexer.BinOp, env: []Slot, comptime op: []const u8) anyerror!Slot {
        const av = try self.emitExpr(b.a, env);
        const bv = try self.emitExpr(b.b, env);
        const t = self.fresh();
        try self.out.appendSlice(self.alloc, "  ");
        try self.writeTmp(t);
        try self.out.appendSlice(self.alloc, op);
        try self.writeSlot(av);
        try self.out.appendSlice(self.alloc, ", ");
        try self.writeSlot(bv);
        try self.out.append(self.alloc, '\n');
        return .{ .tmp = t };
    }

    fn emitCmp(self: *Emitter, b: lexer.BinOp, env: []Slot, comptime pred: []const u8) !Slot {
        const av = try self.emitExpr(b.a, env);
        const bv = try self.emitExpr(b.b, env);
        const cmp = self.fresh();
        try self.out.appendSlice(self.alloc, "  ");
        try self.writeTmp(cmp);
        try self.out.appendSlice(self.alloc, " = icmp " ++ pred ++ " i64 ");
        try self.writeSlot(av);
        try self.out.appendSlice(self.alloc, ", ");
        try self.writeSlot(bv);
        try self.out.append(self.alloc, '\n');
        const t = self.fresh();
        try self.out.appendSlice(self.alloc, "  ");
        try self.writeTmp(t);
        try self.out.appendSlice(self.alloc, " = zext i1 ");
        try self.writeTmp(cmp);
        try self.out.appendSlice(self.alloc, " to i64\n");
        return .{ .tmp = t };
    }

    fn emitCallExpr(self: *Emitter, name: []const u8, arg_exprs: []*lexer.Expr, env: []Slot) !Slot {
        var slots_buf: [16]Slot = undefined;
        var is_ptr_buf: [16]bool = undefined;
        const argc = arg_exprs.len;
        for (arg_exprs, 0..) |a, i| {
            slots_buf[i] = try self.emitExpr(a, env);
            is_ptr_buf[i] = switch (a.*) {
                .str => true,
                .reg => |r| switch (env[r]) {
                    .param => true,
                    else => false,
                },
                else => false,
            } or (std.mem.eql(u8, name, "puts") and i == 0);
        }
        const ret_ty: []const u8 = if (std.mem.eql(u8, name, "puts")) "i32" else "i64";
        const t = self.fresh();
        try self.out.appendSlice(self.alloc, "  ");
        try self.writeTmp(t);
        try self.out.appendSlice(self.alloc, " = call ");
        try self.out.appendSlice(self.alloc, ret_ty);
        try self.out.appendSlice(self.alloc, " @");
        try self.out.appendSlice(self.alloc, name);
        try self.out.append(self.alloc, '(');
        for (0..argc) |i| {
            if (i > 0) try self.out.appendSlice(self.alloc, ", ");
            try self.out.appendSlice(self.alloc, if (is_ptr_buf[i]) "ptr " else "i64 ");
            try self.writeSlot(slots_buf[i]);
        }
        try self.out.appendSlice(self.alloc, ")\n");
        return .{ .tmp = t };
    }

    fn emitCallStmt(self: *Emitter, name: []const u8, arg_exprs: []*lexer.Expr, env: []Slot) !void {
        var slots_buf: [16]Slot = undefined;
        var is_ptr_buf: [16]bool = undefined;
        const argc = arg_exprs.len;
        for (arg_exprs, 0..) |a, i| {
            slots_buf[i] = try self.emitExpr(a, env);
            is_ptr_buf[i] = switch (a.*) {
                .str => true,
                .reg => |r| switch (env[r]) {
                    .param => true,
                    else => false,
                },
                else => false,
            } or (std.mem.eql(u8, name, "puts") and i == 0);
        }
        const ret_ty: []const u8 = if (std.mem.eql(u8, name, "puts")) "i32" else "i64";
        const t = self.fresh();
        try self.out.appendSlice(self.alloc, "  ");
        try self.writeTmp(t);
        try self.out.appendSlice(self.alloc, " = call ");
        try self.out.appendSlice(self.alloc, ret_ty);
        try self.out.appendSlice(self.alloc, " @");
        try self.out.appendSlice(self.alloc, name);
        try self.out.append(self.alloc, '(');
        for (0..argc) |i| {
            if (i > 0) try self.out.appendSlice(self.alloc, ", ");
            try self.out.appendSlice(self.alloc, if (is_ptr_buf[i]) "ptr " else "i64 ");
            try self.writeSlot(slots_buf[i]);
        }
        try self.out.appendSlice(self.alloc, ")\n");
    }

    fn emitStmt(self: *Emitter, stmt: *const lexer.Stmt, env: []Slot, func_name: []const u8) !void {
        switch (stmt.*) {
            .assign => |a| env[a.reg] = try self.emitExpr(a.expr, env),
            .set_field => |sf| {
                const base = env[sf.reg];
                const idx = try self.fieldOffset(sf.field);
                const v = try self.emitExpr(sf.expr, env);
                const gep = self.fresh();
                try self.out.appendSlice(self.alloc, "  ");
                try self.writeTmp(gep);
                try self.out.appendSlice(self.alloc, " = getelementptr inbounds i64, ptr ");
                try self.writeSlot(base);
                var buf: [24]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, ", i64 {d}\n", .{idx}) catch unreachable;
                try self.out.appendSlice(self.alloc, s);
                try self.out.appendSlice(self.alloc, "  store i64 ");
                try self.writeSlot(v);
                try self.out.appendSlice(self.alloc, ", ptr ");
                try self.writeTmp(gep);
                try self.out.append(self.alloc, '\n');
            },
            .call => |c| try self.emitCallStmt(c.name, c.args.items, env),
            .ret => |e| {
                const v = try self.emitExpr(e, env);
                try self.out.appendSlice(self.alloc, "  ret i64 ");
                try self.writeSlot(v);
                try self.out.append(self.alloc, '\n');
            },
            .while_ => |wh| {
                const lc = self.loop_ctr;
                self.loop_ctr += 1;
                var lbuf: [128]u8 = undefined;
                const lcheck = std.fmt.bufPrint(&lbuf, "{s}.loop{d}.check", .{ func_name, lc }) catch unreachable;
                const lcheck_owned = try self.alloc.dupe(u8, lcheck);
                defer self.alloc.free(lcheck_owned);
                var lbuf2: [128]u8 = undefined;
                const lbody = std.fmt.bufPrint(&lbuf2, "{s}.loop{d}.body", .{ func_name, lc }) catch unreachable;
                const lbody_owned = try self.alloc.dupe(u8, lbody);
                defer self.alloc.free(lbody_owned);
                var lbuf3: [128]u8 = undefined;
                const lend = std.fmt.bufPrint(&lbuf3, "{s}.loop{d}.end", .{ func_name, lc }) catch unreachable;
                const lend_owned = try self.alloc.dupe(u8, lend);
                defer self.alloc.free(lend_owned);

                try self.out.appendSlice(self.alloc, "  br label %");
                try self.out.appendSlice(self.alloc, lcheck_owned);
                try self.out.append(self.alloc, '\n');
                try self.out.appendSlice(self.alloc, lcheck_owned);
                try self.out.appendSlice(self.alloc, ":\n");
                const cv = try self.emitExpr(wh.cond, env);
                const cond1 = self.fresh();
                try self.out.appendSlice(self.alloc, "  ");
                try self.writeTmp(cond1);
                try self.out.appendSlice(self.alloc, " = icmp ne i64 ");
                try self.writeSlot(cv);
                try self.out.appendSlice(self.alloc, ", 0\n  br i1 ");
                try self.writeTmp(cond1);
                try self.out.appendSlice(self.alloc, ", label %");
                try self.out.appendSlice(self.alloc, lbody_owned);
                try self.out.appendSlice(self.alloc, ", label %");
                try self.out.appendSlice(self.alloc, lend_owned);
                try self.out.append(self.alloc, '\n');
                try self.out.appendSlice(self.alloc, lbody_owned);
                try self.out.appendSlice(self.alloc, ":\n");
                for (wh.body.items) |*s| try self.emitStmt(s, env, func_name);
                try self.out.appendSlice(self.alloc, "  br label %");
                try self.out.appendSlice(self.alloc, lcheck_owned);
                try self.out.append(self.alloc, '\n');
                try self.out.appendSlice(self.alloc, lend_owned);
                try self.out.appendSlice(self.alloc, ":\n");
            },
            .label => |name| {
                try self.out.appendSlice(self.alloc, name);
                try self.out.appendSlice(self.alloc, ":\n");
            },
            .jmp => |target| {
                try self.out.appendSlice(self.alloc, "  br label %");
                try self.out.appendSlice(self.alloc, target);
                try self.out.append(self.alloc, '\n');
            },
            .br_if => |br| {
                const cond1 = self.fresh();
                try self.out.appendSlice(self.alloc, "  ");
                try self.writeTmp(cond1);
                try self.out.appendSlice(self.alloc, " = icmp ne i64 ");
                try self.writeSlot(env[br.cond]);
                try self.out.appendSlice(self.alloc, ", 0\n  br i1 ");
                try self.writeTmp(cond1);
                try self.out.appendSlice(self.alloc, ", label %");
                try self.out.appendSlice(self.alloc, br.true_label);
                try self.out.appendSlice(self.alloc, ", label %");
                try self.out.appendSlice(self.alloc, br.false_label);
                try self.out.append(self.alloc, '\n');
            },
            .store => return error.UnsupportedStmt,
            .free => |ptr_reg| {
                try self.out.appendSlice(self.alloc, "  call void @free(ptr ");
                try self.writeSlot(env[ptr_reg]);
                try self.out.appendSlice(self.alloc, ")\n");
            },
            .arena_destroy => |arena_reg| {
                try self.out.appendSlice(self.alloc, "  call void @bear_arena_destroy(ptr ");
                try self.writeSlot(env[arena_reg]);
                try self.out.appendSlice(self.alloc, ")\n");
            },
        }
    }

    fn emitFunction(self: *Emitter, func: *const lexer.Function) !void {
        const ret = if (func.ret_ty == .void_) "void" else "i64";
        try self.out.appendSlice(self.alloc, "define ");
        try self.out.appendSlice(self.alloc, ret);
        try self.out.appendSlice(self.alloc, " @");
        try self.out.appendSlice(self.alloc, func.name);
        try self.out.append(self.alloc, '(');
        for (func.params.items, 0..) |p, i| {
            if (i > 0) try self.out.appendSlice(self.alloc, ", ");
            const pty: []const u8 = switch (p.ty) {
                .str, .named => "ptr",
                .bool_ => "i1",
                else => "i64",
            };
            try self.out.appendSlice(self.alloc, pty);
            try self.out.appendSlice(self.alloc, " %");
            try self.out.appendSlice(self.alloc, p.name);
        }
        try self.out.appendSlice(self.alloc, ") {\nentry:\n");

        const env = try self.alloc.alloc(Slot, func.n_regs);
        defer self.alloc.free(env);
        @memset(env, .undef);
        for (func.params.items) |p| env[p.idx] = .{ .param = p.name };

        const body_start = self.out.items.len;
        for (func.body.items) |*s| try self.emitStmt(s, env, func.name);

        const body_text = self.out.items[body_start..];
        const needs_ret = std.mem.indexOf(u8, body_text, "\n  ret ") == null and
            !std.mem.endsWith(u8, std.mem.trimRight(u8, body_text, "\n"), "  ret void") and
            !std.mem.endsWith(u8, std.mem.trimRight(u8, body_text, "\n"), "  ret i64");
        if (needs_ret) {
            if (func.ret_ty == .void_) {
                try self.out.appendSlice(self.alloc, "  ret void\n");
            } else {
                try self.out.appendSlice(self.alloc, "  ret i64 0\n");
            }
        }

        try self.out.appendSlice(self.alloc, "}\n\n");
    }

    fn emitDeclarations(self: *Emitter) !void {
        try self.out.appendSlice(self.alloc,
            \\declare i32 @puts(ptr)
            \\declare i64 @open(ptr, i64)
            \\declare i64 @read(i64, ptr, i64)
            \\declare i64 @write(i64, ptr, i64)
            \\declare i64 @close(i64)
            \\
        );
    }

    fn emitDataSection(self: *Emitter) !void {
        for (self.strings.items) |e| {
            var buf: [32]u8 = undefined;
            const hdr = std.fmt.bufPrint(&buf, "@.str{d} = private unnamed_addr constant [{d} x i8] c\"", .{ e.idx, e.byte_len }) catch unreachable;
            try self.out.appendSlice(self.alloc, hdr);
            for (e.content) |ch| {
                switch (ch) {
                    '\n' => try self.out.appendSlice(self.alloc, "\\0A"),
                    '"' => try self.out.appendSlice(self.alloc, "\\22"),
                    '\\' => try self.out.appendSlice(self.alloc, "\\5C"),
                    else => try self.out.append(self.alloc, ch),
                }
            }
            try self.out.appendSlice(self.alloc, "\\00\"\n");
        }
        if (self.strings.items.len > 0) try self.out.append(self.alloc, '\n');
    }

    pub fn emitProgram(self: *Emitter, program: *const lexer.Program) ![]const u8 {
        var stmt_count: usize = 0;
        for (program.functions.items) |*f| stmt_count += f.body.items.len;
        try self.out.ensureTotalCapacity(self.alloc, stmt_count * 80 + 512);

        for (program.structs.items) |*s| {
            try self.structs.put(self.alloc, s.name, s.fields.items);
        }

        const func_start = self.out.items.len;
        for (program.functions.items) |*f| try self.emitFunction(f);
        const func_text = try self.alloc.dupe(u8, self.out.items[func_start..]);
        defer self.alloc.free(func_text);
        self.out.items.len = func_start;

        try self.out.appendSlice(self.alloc, "; Bear LLVM IR\ntarget triple = \"x86_64-unknown-linux-gnu\"\n\n");
        try self.emitDeclarations();
        try self.emitDataSection();
        try self.out.appendSlice(self.alloc, func_text);

        return try self.out.toOwnedSlice(self.alloc);
    }
};

pub fn emit(program: *const lexer.Program, alloc: std.mem.Allocator) ![]const u8 {
    var e = Emitter.init(alloc);
    defer e.deinit();
    return e.emitProgram(program);
}
