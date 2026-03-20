//! Unicode tree printer for the Bear AST with ANSI color coding by scope depth.

const std = @import("std");
const lexer = @import("lexer.zig");

const colors = [_][]const u8{
    "\x1b[1;36m",
    "\x1b[1;33m",
    "\x1b[1;32m",
    "\x1b[1;35m",
    "\x1b[1;34m",
    "\x1b[1;31m",
};
const reset = "\x1b[0m";

fn color(depth: usize) []const u8 {
    return colors[depth % colors.len];
}

const BRANCH = "├── ";
const LAST = "└── ";
const PIPE = "│   ";
const SPACE = "    ";

const Printer = struct {
    fn node(_: Printer, prefix: []const u8, is_last: bool, depth: usize, label: []const u8) void {
        const connector = if (is_last) LAST else BRANCH;
        std.debug.print("{s}{s}{s}{s}{s}\n", .{ prefix, connector, color(depth), label, reset });
    }

    fn childPrefix(alloc: std.mem.Allocator, prefix: []const u8, is_last: bool) ![]u8 {
        const ext = if (is_last) SPACE else PIPE;
        return std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, ext });
    }

    fn printExpr(self: Printer, alloc: std.mem.Allocator, e: *const lexer.Expr, prefix: []const u8, is_last: bool, depth: usize) !void {
        switch (e.*) {
            .int => |n| {
                var buf: [32]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "int({d})", .{n});
                self.node(prefix, is_last, depth, s);
            },
            .str => |s| {
                const label = try std.fmt.allocPrint(alloc, "str(\"{s}\")", .{s});
                defer alloc.free(label);
                self.node(prefix, is_last, depth, label);
            },
            .reg => |idx| {
                var buf: [32]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "reg(%{d})", .{idx});
                self.node(prefix, is_last, depth, s);
            },
            .named => |name| {
                const label = try std.fmt.allocPrint(alloc, "named({s})", .{name});
                defer alloc.free(label);
                self.node(prefix, is_last, depth, label);
            },
            .field => |f| {
                var buf: [64]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "field(%{d}.{s})", .{ f.reg, f.field });
                self.node(prefix, is_last, depth, s);
            },
            .const_ => |inner| {
                self.node(prefix, is_last, depth, "const");
                const cp = try childPrefix(alloc, prefix, is_last);
                defer alloc.free(cp);
                try self.printExpr(alloc, inner, cp, true, depth + 1);
            },
            .alloc => |inner| {
                self.node(prefix, is_last, depth, "alloc");
                const cp = try childPrefix(alloc, prefix, is_last);
                defer alloc.free(cp);
                try self.printExpr(alloc, inner, cp, true, depth + 1);
            },
            .add => |b| try self.printBinOp(alloc, "add", b, prefix, is_last, depth),
            .sub => |b| try self.printBinOp(alloc, "sub", b, prefix, is_last, depth),
            .mul => |b| try self.printBinOp(alloc, "mul", b, prefix, is_last, depth),
            .div => |b| try self.printBinOp(alloc, "div", b, prefix, is_last, depth),
            .lt => |b| try self.printBinOp(alloc, "lt", b, prefix, is_last, depth),
            .gt => |b| try self.printBinOp(alloc, "gt", b, prefix, is_last, depth),
            .le => |b| try self.printBinOp(alloc, "le", b, prefix, is_last, depth),
            .ge => |b| try self.printBinOp(alloc, "ge", b, prefix, is_last, depth),
            .eq => |b| try self.printBinOp(alloc, "eq", b, prefix, is_last, depth),
            .call => |c| {
                const label = try std.fmt.allocPrint(alloc, "call({s})", .{c.name});
                defer alloc.free(label);
                self.node(prefix, is_last, depth, label);
                const cp = try childPrefix(alloc, prefix, is_last);
                defer alloc.free(cp);
                for (c.args.items, 0..) |arg, i| {
                    const last = i == c.args.items.len - 1;
                    try self.printExpr(alloc, arg, cp, last, depth + 1);
                }
            },
            .struct_lit => |sl| {
                const label = try std.fmt.allocPrint(alloc, "struct_lit({s})", .{sl.name});
                defer alloc.free(label);
                self.node(prefix, is_last, depth, label);
                const cp = try childPrefix(alloc, prefix, is_last);
                defer alloc.free(cp);
                for (sl.fields.items, 0..) |fi, i| {
                    const last = i == sl.fields.items.len - 1;
                    const flabel = try std.fmt.allocPrint(alloc, "field_init({s})", .{fi.name});
                    defer alloc.free(flabel);
                    self.node(cp, last, depth + 1, flabel);
                    const fcp = try childPrefix(alloc, cp, last);
                    defer alloc.free(fcp);
                    try self.printExpr(alloc, fi.expr, fcp, true, depth + 2);
                }
            },
            .spawn => |s| {
                const label = try std.fmt.allocPrint(alloc, "spawn({s})", .{s.name});
                defer alloc.free(label);
                self.node(prefix, is_last, depth, label);
                const cp = try childPrefix(alloc, prefix, is_last);
                defer alloc.free(cp);
                for (s.args.items, 0..) |arg, i| {
                    const last = i == s.args.items.len - 1;
                    try self.printExpr(alloc, arg, cp, last, depth + 1);
                }
            },
            .sync => |reg| {
                var buf: [32]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "sync(%{d})", .{reg});
                self.node(prefix, is_last, depth, s);
            },
            .free => |reg| {
                var buf: [32]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "free(%{d})", .{reg});
                self.node(prefix, is_last, depth, s);
            },
            .arena_create => {
                self.node(prefix, is_last, depth, "arena_create");
            },
            .arena_alloc => |aa| {
                var buf: [48]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "arena_alloc(%{d})", .{aa.arena});
                self.node(prefix, is_last, depth, s);
                const cp = try childPrefix(alloc, prefix, is_last);
                defer alloc.free(cp);
                try self.printExpr(alloc, aa.size, cp, true, depth + 1);
            },
            .phi => |arms| {
                self.node(prefix, is_last, depth, "phi");
                const cp = try childPrefix(alloc, prefix, is_last);
                defer alloc.free(cp);
                for (arms.items, 0..) |arm, i| {
                    const last = i == arms.items.len - 1;
                    const lbl = try std.fmt.allocPrint(alloc, "{s}: %{d}", .{ arm.label, arm.reg });
                    defer alloc.free(lbl);
                    self.node(cp, last, depth + 1, lbl);
                }
            },
            .alloc_type => |name| {
                const label = try std.fmt.allocPrint(alloc, "alloc_type({s})", .{name});
                defer alloc.free(label);
                self.node(prefix, is_last, depth, label);
            },
            .alloc_array => |aa| {
                var buf: [64]u8 = undefined;
                const label = try std.fmt.bufPrint(&buf, "alloc_array({s})", .{@tagName(aa.elem_ty)});
                self.node(prefix, is_last, depth, label);
                const cp = try childPrefix(alloc, prefix, is_last);
                defer alloc.free(cp);
                try self.printExpr(alloc, aa.count, cp, true, depth + 1);
            },
            .load => |reg| {
                var buf: [32]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "load(%{d})", .{reg});
                self.node(prefix, is_last, depth, s);
            },
            .get_field_ref => |gfr| {
                var buf: [64]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "get_field_ref(%{d}, {s})", .{ gfr.ptr, gfr.field });
                self.node(prefix, is_last, depth, s);
            },
            .get_index_ref => |gir| {
                var buf: [32]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "get_index_ref(%{d})", .{gir.arr});
                self.node(prefix, is_last, depth, s);
                const cp = try childPrefix(alloc, prefix, is_last);
                defer alloc.free(cp);
                try self.printExpr(alloc, gir.idx, cp, true, depth + 1);
            },
        }
    }

    fn printBinOp(self: Printer, alloc: std.mem.Allocator, op: []const u8, b: lexer.BinOp, prefix: []const u8, is_last: bool, depth: usize) anyerror!void {
        self.node(prefix, is_last, depth, op);
        const cp = try childPrefix(alloc, prefix, is_last);
        defer alloc.free(cp);
        try self.printExpr(alloc, b.a, cp, false, depth + 1);
        try self.printExpr(alloc, b.b, cp, true, depth + 1);
    }

    fn printStmt(self: Printer, alloc: std.mem.Allocator, s: *const lexer.Stmt, prefix: []const u8, is_last: bool, depth: usize) !void {
        switch (s.*) {
            .assign => |a| {
                var buf: [32]u8 = undefined;
                const label = try std.fmt.bufPrint(&buf, "assign(%{d})", .{a.reg});
                self.node(prefix, is_last, depth, label);
                const cp = try childPrefix(alloc, prefix, is_last);
                defer alloc.free(cp);
                try self.printExpr(alloc, a.expr, cp, true, depth + 1);
            },
            .set_field => |sf| {
                var buf: [64]u8 = undefined;
                const label = try std.fmt.bufPrint(&buf, "set_field(%{d}.{s})", .{ sf.reg, sf.field });
                self.node(prefix, is_last, depth, label);
                const cp = try childPrefix(alloc, prefix, is_last);
                defer alloc.free(cp);
                try self.printExpr(alloc, sf.expr, cp, true, depth + 1);
            },
            .call => |c| {
                const label = try std.fmt.allocPrint(alloc, "call({s})", .{c.name});
                defer alloc.free(label);
                self.node(prefix, is_last, depth, label);
                const cp = try childPrefix(alloc, prefix, is_last);
                defer alloc.free(cp);
                for (c.args.items, 0..) |arg, i| {
                    const last = i == c.args.items.len - 1;
                    try self.printExpr(alloc, arg, cp, last, depth + 1);
                }
            },
            .ret => |e| {
                self.node(prefix, is_last, depth, "ret");
                const cp = try childPrefix(alloc, prefix, is_last);
                defer alloc.free(cp);
                try self.printExpr(alloc, e, cp, true, depth + 1);
            },
            .while_ => |w| {
                self.node(prefix, is_last, depth, "while");
                const cp = try childPrefix(alloc, prefix, is_last);
                defer alloc.free(cp);
                self.node(cp, w.body.items.len == 0, depth + 1, "cond");
                const condp = try childPrefix(alloc, cp, w.body.items.len == 0);
                defer alloc.free(condp);
                try self.printExpr(alloc, w.cond, condp, true, depth + 2);
                if (w.body.items.len > 0) {
                    self.node(cp, true, depth + 1, "body");
                    const bodyp = try childPrefix(alloc, cp, true);
                    defer alloc.free(bodyp);
                    for (w.body.items, 0..) |*stmt, i| {
                        const last = i == w.body.items.len - 1;
                        try self.printStmt(alloc, stmt, bodyp, last, depth + 2);
                    }
                }
            },
            .label => |name| {
                const label = try std.fmt.allocPrint(alloc, "label({s}:)", .{name});
                defer alloc.free(label);
                self.node(prefix, is_last, depth, label);
            },
            .jmp => |target| {
                const label = try std.fmt.allocPrint(alloc, "jmp({s})", .{target});
                defer alloc.free(label);
                self.node(prefix, is_last, depth, label);
            },
            .br_if => |br| {
                const label = try std.fmt.allocPrint(alloc, "br_if(%{d}, {s}, {s})", .{ br.cond, br.true_label, br.false_label });
                defer alloc.free(label);
                self.node(prefix, is_last, depth, label);
            },
            .store => |st| {
                var buf: [32]u8 = undefined;
                const label = try std.fmt.bufPrint(&buf, "store(%{d})", .{st.ptr});
                self.node(prefix, is_last, depth, label);
                const cp = try childPrefix(alloc, prefix, is_last);
                defer alloc.free(cp);
                try self.printExpr(alloc, st.expr, cp, true, depth + 1);
            },
            .free => |reg| {
                var buf: [32]u8 = undefined;
                const label = try std.fmt.bufPrint(&buf, "free(%{d})", .{reg});
                self.node(prefix, is_last, depth, label);
            },
            .arena_destroy => |reg| {
                var buf: [48]u8 = undefined;
                const label = try std.fmt.bufPrint(&buf, "arena_destroy(%{d})", .{reg});
                self.node(prefix, is_last, depth, label);
            },
        }
    }

    fn printFunction(self: Printer, alloc: std.mem.Allocator, f: *const lexer.Function, prefix: []const u8, is_last: bool) !void {
        const label = try std.fmt.allocPrint(alloc, "fn(@{s}): {s}", .{ f.name, tyName(f.ret_ty) });
        defer alloc.free(label);
        self.node(prefix, is_last, 1, label);
        const cp = try childPrefix(alloc, prefix, is_last);
        defer alloc.free(cp);

        if (f.params.items.len > 0) {
            const has_body = f.body.items.len > 0;
            self.node(cp, !has_body, 2, "params");
            const pp = try childPrefix(alloc, cp, !has_body);
            defer alloc.free(pp);
            for (f.params.items, 0..) |p, i| {
                const last = i == f.params.items.len - 1;
                const plabel = try std.fmt.allocPrint(alloc, "param(%{s}: {s})", .{ p.name, tyName(p.ty) });
                defer alloc.free(plabel);
                self.node(pp, last, 3, plabel);
            }
        }

        for (f.body.items, 0..) |*stmt, i| {
            const last = i == f.body.items.len - 1;
            try self.printStmt(alloc, stmt, cp, last, 2);
        }
    }

    fn printStruct(self: Printer, alloc: std.mem.Allocator, s: *const lexer.StructDef, prefix: []const u8, is_last: bool) !void {
        const label = try std.fmt.allocPrint(alloc, "struct({s})", .{s.name});
        defer alloc.free(label);
        self.node(prefix, is_last, 1, label);
        const cp = try childPrefix(alloc, prefix, is_last);
        defer alloc.free(cp);
        for (s.fields.items, 0..) |f, i| {
            const last = i == s.fields.items.len - 1;
            const flabel = try std.fmt.allocPrint(alloc, "field({s}: {s})", .{ f.name, tyName(f.ty) });
            defer alloc.free(flabel);
            self.node(cp, last, 2, flabel);
        }
    }
};

fn tyName(ty: lexer.Ty) []const u8 {
    return switch (ty) {
        .int => "int",
        .void_ => "void",
        .str => "string",
        .bool_ => "bool",
        .named => "named",
    };
}

pub fn printAst(program: *const lexer.Program, alloc: std.mem.Allocator) !void {
    const p = Printer{};
    std.debug.print("{s}program{s}\n", .{ color(0), reset });

    const total = program.structs.items.len + program.functions.items.len;
    var idx: usize = 0;

    for (program.structs.items) |*s| {
        const last = idx == total - 1;
        try p.printStruct(alloc, s, "", last);
        idx += 1;
    }
    for (program.functions.items) |*f| {
        const last = idx == total - 1;
        try p.printFunction(alloc, f, "", last);
        idx += 1;
    }
}
