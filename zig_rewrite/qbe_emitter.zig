//! Emit QBE IL from a Bear program.
//! QBE IL reference: https://c9x.me/compile/doc/il.html
//!
//! Performance notes:
//!   - All output goes through a single growing ArrayList(u8); no intermediate buffers.
//!   - Temp names are never heap-allocated: we write "%tN" inline via a stack buffer.
//!   - The env[] array stores TmpId (u32 index) rather than heap strings, so register
//!     reads are a free array lookup + inline format.
//!   - String interning uses a flat slice scan (programs have few unique strings).
//!   - Data section is emitted first in a separate pre-pass so we avoid the
//!     save/restore out-buffer swap.

const std = @import("std");
const lexer = @import("lexer.zig");

/// A temp variable is just its sequential index.  We format "%tN" inline.
const TmpId = u32;
/// Sentinel meaning "this register holds a parameter, use its name directly".
const PARAM_BASE: TmpId = 0x8000_0000;

/// Compact representation of what a register slot holds.
const Slot = union(enum) {
    /// Result of a temp: write "%tN"
    tmp: TmpId,
    /// Function parameter: write "%<name>"
    param: []const u8,
    /// Unset
    undef,
};

const StringEntry = struct { content: []const u8, idx: usize };

const Emitter = struct {
    alloc: std.mem.Allocator,
    out: std.ArrayList(u8),
    strings: std.ArrayListUnmanaged(StringEntry),
    str_count: usize,
    tmp: TmpId,
    loop_ctr: u32,
    structs: std.StringHashMapUnmanaged([]const lexer.StructField),

    fn init(alloc: std.mem.Allocator) Emitter {
        return .{
            .alloc = alloc,
            .out = std.ArrayList(u8).init(alloc),
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
        self.out.deinit();
    }

    /// Allocate the next temp index (does NOT allocate memory).
    inline fn fresh(self: *Emitter) TmpId {
        const id = self.tmp;
        self.tmp += 1;
        return id;
    }

    /// Write "%tN" for a temp into the output buffer.
    inline fn writeTmp(self: *Emitter, id: TmpId) !void {
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "%t{d}", .{id}) catch unreachable;
        try self.out.appendSlice(s);
    }

    /// Write the slot value ("%tN" or "%param") into the output buffer.
    inline fn writeSlot(self: *Emitter, slot: Slot) !void {
        switch (slot) {
            .tmp => |id| try self.writeTmp(id),
            .param => |name| {
                try self.out.append('%');
                try self.out.appendSlice(name);
            },
            .undef => try self.out.appendSlice("undef"),
        }
    }

    fn internStr(self: *Emitter, s: []const u8) !usize {
        for (self.strings.items) |e| {
            if (std.mem.eql(u8, e.content, s)) return e.idx;
        }
        const idx = self.str_count;
        self.str_count += 1;
        try self.strings.append(self.alloc, .{ .content = s, .idx = idx });
        return idx;
    }

    fn qbeTy(ty: lexer.Ty) u8 {
        return switch (ty) {
            .int, .bool_ => 'w',
            .str, .named => 'l',
            .void_ => 0,
        };
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

    /// Emit an expression, returning the Slot that holds its result.
    /// All output is written directly to self.out — no heap string for the name.
    fn emitExpr(self: *Emitter, expr: *const lexer.Expr, env: []Slot) !Slot {
        switch (expr.*) {
            .int => |n| {
                const t = self.fresh();
                try self.out.appendSlice("  ");
                try self.writeTmp(t);
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, " =w copy {d}\n", .{n}) catch unreachable;
                try self.out.appendSlice(s);
                return .{ .tmp = t };
            },
            .str => |s| {
                const idx = try self.internStr(s);
                const t = self.fresh();
                try self.out.appendSlice("  ");
                try self.writeTmp(t);
                var buf: [32]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, " =l copy $str{d}\n", .{idx}) catch unreachable;
                try self.out.appendSlice(line);
                return .{ .tmp = t };
            },
            .reg => |r| return env[r],
            .field => |f| {
                const base = env[f.reg];
                const offset = try self.fieldOffset(f.field);
                const ptr = self.fresh();
                try self.out.appendSlice("  ");
                try self.writeTmp(ptr);
                try self.out.appendSlice(" =l add ");
                try self.writeSlot(base);
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, ", {d}\n", .{offset}) catch unreachable;
                try self.out.appendSlice(s);
                const val = self.fresh();
                try self.out.appendSlice("  ");
                try self.writeTmp(val);
                try self.out.appendSlice(" =l loadl ");
                try self.writeTmp(ptr);
                try self.out.append('\n');
                return .{ .tmp = val };
            },
            .const_ => |inner| return self.emitExpr(inner, env),
            .add => |b| return self.emitBinOp(b, env, " =w add "),
            .sub => |b| return self.emitBinOp(b, env, " =w sub "),
            .mul => |b| return self.emitBinOp(b, env, " =w mul "),
            .div => |b| return self.emitBinOp(b, env, " =w div "),
            .lt  => |b| return self.emitBinOp(b, env, " =w csltw "),
            .gt  => |b| return self.emitBinOp(b, env, " =w csgtw "),
            .eq  => |b| return self.emitBinOp(b, env, " =w ceqw "),
            .alloc => |size_expr| {
                const sv = try self.emitExpr(size_expr, env);
                const t = self.fresh();
                try self.out.appendSlice("  ");
                try self.writeTmp(t);
                try self.out.appendSlice(" =l alloc8 ");
                try self.writeSlot(sv);
                try self.out.append('\n');
                return .{ .tmp = t };
            },
            .named => |name| {
                const val: i64 = if (name.len > 0 and name[0] == 'R') 0
                    else if (name.len > 0 and name[0] == 'W') 1
                    else return error.UnknownNamedConstant;
                const t = self.fresh();
                try self.out.appendSlice("  ");
                try self.writeTmp(t);
                var buf: [24]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, " =w copy {d}\n", .{val}) catch unreachable;
                try self.out.appendSlice(s);
                return .{ .tmp = t };
            },
            .struct_lit => |sl| {
                const fields = self.structs.get(sl.name) orelse return error.UnknownStruct;
                const size = fields.len * 8;
                const ptr = self.fresh();
                try self.out.appendSlice("  ");
                try self.writeTmp(ptr);
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, " =l alloc8 {d}\n", .{size}) catch unreachable;
                try self.out.appendSlice(s);
                for (fields, 0..) |fd, i| {
                    var fval: ?*const lexer.Expr = null;
                    for (sl.fields.items) |fi| {
                        if (std.mem.eql(u8, fi.name, fd.name)) { fval = fi.expr; break; }
                    }
                    const v = try self.emitExpr(fval orelse return error.MissingField, env);
                    const fptr = self.fresh();
                    try self.out.appendSlice("  ");
                    try self.writeTmp(fptr);
                    const line = std.fmt.bufPrint(&buf, " =l add ", .{}) catch unreachable;
                    try self.out.appendSlice(line);
                    try self.writeTmp(ptr);
                    const off = std.fmt.bufPrint(&buf, ", {d}\n", .{i * 8}) catch unreachable;
                    try self.out.appendSlice(off);
                    try self.out.appendSlice("  storel ");
                    try self.writeSlot(v);
                    try self.out.appendSlice(", ");
                    try self.writeTmp(fptr);
                    try self.out.append('\n');
                }
                return .{ .tmp = ptr };
            },
            .call => |c| return self.emitCallExpr(c.name, c.args.items, env),
        }
    }

    inline fn emitBinOp(self: *Emitter, b: lexer.BinOp, env: []Slot, comptime op: []const u8) !Slot {
        const av = try self.emitExpr(b.a, env);
        const bv = try self.emitExpr(b.b, env);
        const t = self.fresh();
        try self.out.appendSlice("  ");
        try self.writeTmp(t);
        try self.out.appendSlice(op);
        try self.writeSlot(av);
        try self.out.appendSlice(", ");
        try self.writeSlot(bv);
        try self.out.append('\n');
        return .{ .tmp = t };
    }

    fn isLongSlot(slot: Slot) bool {
        // Heuristic: param slots that came from string-typed params are long.
        // For simplicity we check if the slot is a tmp whose origin was a str expr —
        // but we don't track that here. Instead callers pass the expr for type info.
        _ = slot;
        return false;
    }

    fn emitArgs(self: *Emitter, arg_exprs: []*const lexer.Expr, env: []Slot) !void {
        for (arg_exprs, 0..) |a, i| {
            const v = try self.emitExpr(a, env);
            if (i > 0) try self.out.appendSlice(", ");
            // Determine QBE type: strings/ptrs are 'l', everything else 'w'
            const is_long = switch (a.*) {
                .str => true,
                .reg => |r| switch (env[r]) { .param => true, else => false },
                else => false,
            };
            try self.out.appendSlice(if (is_long) "l " else "w ");
            try self.writeSlot(v);
        }
    }

    fn emitCallExpr(self: *Emitter, name: []const u8, arg_exprs: []*const lexer.Expr, env: []Slot) !Slot {
        // Emit arg expressions first (they write to self.out), then the call line.
        // We need to collect arg slots before writing the call instruction.
        // Use a small stack buffer for up to 16 args.
        var slots_buf: [16]Slot = undefined;
        var long_buf: [16]bool = undefined;
        const argc = arg_exprs.len;
        for (arg_exprs, 0..) |a, i| {
            slots_buf[i] = try self.emitExpr(a, env);
            long_buf[i] = switch (a.*) {
                .str => true,
                .reg => |r| switch (env[r]) { .param => true, else => false },
                else => false,
            };
        }
        const is_long_ret = std.mem.eql(u8, name, "open") or
            std.mem.eql(u8, name, "read") or
            std.mem.eql(u8, name, "write");
        const t = self.fresh();
        try self.out.appendSlice("  ");
        try self.writeTmp(t);
        try self.out.appendSlice(if (is_long_ret) " =l call $" else " =w call $");
        try self.out.appendSlice(name);
        try self.out.append('(');
        for (0..argc) |i| {
            if (i > 0) try self.out.appendSlice(", ");
            try self.out.appendSlice(if (long_buf[i]) "l " else "w ");
            try self.writeSlot(slots_buf[i]);
        }
        try self.out.appendSlice(")\n");
        return .{ .tmp = t };
    }

    fn emitCallStmt(self: *Emitter, name: []const u8, arg_exprs: []*const lexer.Expr, env: []Slot) !void {
        var slots_buf: [16]Slot = undefined;
        var long_buf: [16]bool = undefined;
        const argc = arg_exprs.len;
        for (arg_exprs, 0..) |a, i| {
            slots_buf[i] = try self.emitExpr(a, env);
            long_buf[i] = switch (a.*) {
                .str => true,
                .reg => |r| switch (env[r]) { .param => true, else => false },
                else => false,
            };
        }
        try self.out.appendSlice("  call $");
        try self.out.appendSlice(name);
        try self.out.append('(');
        for (0..argc) |i| {
            if (i > 0) try self.out.appendSlice(", ");
            try self.out.appendSlice(if (long_buf[i]) "l " else "w ");
            try self.writeSlot(slots_buf[i]);
        }
        try self.out.appendSlice(")\n");
    }

    fn emitStmt(self: *Emitter, stmt: *const lexer.Stmt, env: []Slot) !void {
        switch (stmt.*) {
            .assign => |a| {
                env[a.reg] = try self.emitExpr(a.expr, env);
            },
            .set_field => |sf| {
                const base = env[sf.reg];
                const offset = try self.fieldOffset(sf.field);
                const v = try self.emitExpr(sf.expr, env);
                const fptr = self.fresh();
                try self.out.appendSlice("  ");
                try self.writeTmp(fptr);
                try self.out.appendSlice(" =l add ");
                try self.writeSlot(base);
                var buf: [24]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, ", {d}\n", .{offset}) catch unreachable;
                try self.out.appendSlice(s);
                try self.out.appendSlice("  storel ");
                try self.writeSlot(v);
                try self.out.appendSlice(", ");
                try self.writeTmp(fptr);
                try self.out.append('\n');
            },
            .call => |c| try self.emitCallStmt(c.name, c.args.items, env),
            .ret => |e| {
                const v = try self.emitExpr(e, env);
                try self.out.appendSlice("  ret ");
                try self.writeSlot(v);
                try self.out.append('\n');
            },
            .while_ => |wh| {
                const lc = self.loop_ctr;
                self.loop_ctr += 1;
                var buf: [48]u8 = undefined;
                const loop_lbl = std.fmt.bufPrint(&buf, "@loop{d}\n", .{lc}) catch unreachable;
                try self.out.appendSlice(loop_lbl);
                const cv = try self.emitExpr(wh.cond, env);
                try self.out.appendSlice("  jnz ");
                try self.writeSlot(cv);
                const jmp = std.fmt.bufPrint(&buf, ", @lbody{d}, @lend{d}\n@lbody{d}\n", .{ lc, lc, lc }) catch unreachable;
                try self.out.appendSlice(jmp);
                for (wh.body.items) |*s| try self.emitStmt(s, env);
                const tail = std.fmt.bufPrint(&buf, "  jmp @loop{d}\n@lend{d}\n", .{ lc, lc }) catch unreachable;
                try self.out.appendSlice(tail);
            },
            .label => |name| {
                try self.out.append('@');
                try self.out.appendSlice(name);
                try self.out.append('\n');
            },
            .jmp => |target| {
                try self.out.appendSlice("  jmp @");
                try self.out.appendSlice(target);
                try self.out.append('\n');
            },
            .br_if => |br| {
                try self.out.appendSlice("  jnz ");
                try self.writeSlot(env[br.cond]);
                try self.out.appendSlice(", @");
                try self.out.appendSlice(br.true_label);
                try self.out.appendSlice(", @");
                try self.out.appendSlice(br.false_label);
                try self.out.append('\n');
            },
        }
    }

    fn emitFunction(self: *Emitter, func: *const lexer.Function) !void {
        const ret_ty = qbeTy(func.ret_ty);
        if (ret_ty != 0) {
            try self.out.appendSlice("export function ");
            try self.out.append(ret_ty);
            try self.out.appendSlice(" $");
        } else {
            try self.out.appendSlice("export function $");
        }
        try self.out.appendSlice(func.name);
        try self.out.append('(');
        for (func.params.items, 0..) |p, i| {
            if (i > 0) try self.out.appendSlice(", ");
            try self.out.append(qbeTy(p.ty));
            try self.out.appendSlice(" %");
            try self.out.appendSlice(p.name);
        }
        try self.out.appendSlice(") {\n@start\n");

        // env: one Slot per register index
        const env = try self.alloc.alloc(Slot, func.n_regs);
        defer self.alloc.free(env);
        @memset(env, .undef);
        for (func.params.items) |p| env[p.idx] = .{ .param = p.name };

        for (func.body.items) |*s| try self.emitStmt(s, env);

        // Implicit return if the last instruction wasn't a ret/jmp
        const last = std.mem.trimRight(u8, self.out.items, "\n");
        const needs_ret = !std.mem.endsWith(u8, last, "ret") and
            !std.mem.endsWith(u8, last, "}") and
            std.mem.lastIndexOf(u8, last, "\n  ret ") == null;
        if (needs_ret) {
            if (func.ret_ty == .void_) {
                try self.out.appendSlice("  ret\n");
            } else {
                try self.out.appendSlice("  ret 0\n");
            }
        }

        try self.out.appendSlice("}\n\n");
    }

    fn emitDataSection(self: *Emitter) !void {
        for (self.strings.items) |e| {
            try self.out.appendSlice("data $str");
            var buf: [16]u8 = undefined;
            const idx_s = std.fmt.bufPrint(&buf, "{d}", .{e.idx}) catch unreachable;
            try self.out.appendSlice(idx_s);
            try self.out.appendSlice(" = { b \"");
            for (e.content) |ch| {
                switch (ch) {
                    '\n' => try self.out.appendSlice("\\n"),
                    '"'  => try self.out.appendSlice("\\\""),
                    '\\' => try self.out.appendSlice("\\\\"),
                    else => try self.out.append(ch),
                }
            }
            try self.out.appendSlice("\", b 0 }\n");
        }
    }

    pub fn emitProgram(self: *Emitter, program: *const lexer.Program) ![]const u8 {
        // Pre-size the output buffer to avoid repeated reallocations.
        // Rough heuristic: ~64 bytes per statement.
        var stmt_count: usize = 0;
        for (program.functions.items) |*f| stmt_count += f.body.items.len;
        try self.out.ensureTotalCapacity(stmt_count * 64 + 256);

        for (program.structs.items) |*s| {
            try self.structs.put(self.alloc, s.name, s.fields.items);
        }

        // First pass: collect string literals by doing a dry scan of the AST,
        // then emit data section, then emit functions — all into one buffer.
        // (We do a single forward pass; strings discovered during function emit
        //  are appended to self.strings and written at the end via a second small pass.)
        //
        // Simpler approach that avoids the buffer-swap: emit functions into a
        // temporary slice, prepend data section, then append functions.
        // We keep the two-phase approach but avoid allocating a second ArrayList —
        // instead we record the split point after the data section.

        // Phase 1: emit all functions (strings get interned as we go)
        const func_start = self.out.items.len;
        for (program.functions.items) |*f| try self.emitFunction(f);
        const func_end = self.out.items.len;

        // Phase 2: build data section into a temp buffer, then insert before functions
        const func_text = try self.alloc.dupe(u8, self.out.items[func_start..func_end]);
        defer self.alloc.free(func_text);
        self.out.items.len = func_start; // truncate, keep capacity

        try self.emitDataSection();
        if (self.strings.items.len > 0) try self.out.append('\n');
        try self.out.appendSlice(func_text);

        return try self.out.toOwnedSlice();
    }
};

pub fn emit(program: *const lexer.Program, alloc: std.mem.Allocator) ![]const u8 {
    var e = Emitter.init(alloc);
    defer e.deinit();
    return e.emitProgram(program);
}
