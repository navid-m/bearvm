//! Bear VM - Zig rewrite (Zig 0.15.2)

const std = @import("std");
const lexer = @import("lexer.zig");
const bear_io = @import("bear_io.zig");
const bear_parser = @import("parser.zig");

const List = std.ArrayList;

pub const Allocator = std.mem.Allocator;

pub var stdout_buf: [65536]u8 = undefined;
pub var stdout_pos: usize = 0;

const Value = union(enum) {
    int: i64,
    str: []const u8,
    bool_: bool,
    ptr: []u8,
    file: i64,
    void_,
    struct_: StructVal,
};

const StructVal = struct {
    name: []const u8,
    fields: std.StringArrayHashMap(Value),
};

const FileHandle = union(enum) { read: std.fs.File, write: std.fs.File };
const BuiltinTag = enum { puts, open, read, write, close };
const builtin_map = std.StaticStringMap(BuiltinTag).initComptime(.{
    .{ "puts", .puts },
    .{ "open", .open },
    .{ "read", .read },
    .{ "write", .write },
    .{ "close", .close },
});

const Vm = struct {
    program: *const lexer.Program,
    files: List(?FileHandle),
    alloc: Allocator,

    fn init(program: *const lexer.Program, alloc: Allocator) Vm {
        return .{ .program = program, .files = .empty, .alloc = alloc };
    }

    fn findFunc(self: *Vm, name: []const u8) ?*const lexer.Function {
        for (self.program.functions.items) |*f|
            if (std.mem.eql(u8, f.name, name)) return f;
        return null;
    }

    fn allocFile(self: *Vm, handle: FileHandle) !i64 {
        for (self.files.items, 0..) |slot, i| {
            if (slot == null) {
                self.files.items[i] = handle;
                return @intCast(i);
            }
        }
        try self.files.append(self.alloc, handle);
        return @intCast(self.files.items.len - 1);
    }

    fn evalExpr(self: *Vm, expr: *const lexer.Expr, env: []Value) anyerror!Value {
        return switch (expr.*) {
            .int => |n| .{ .int = n },
            .str => |s| .{ .str = s },
            .reg => |r| env[r],
            .field => |f| switch (env[f.reg]) {
                .struct_ => |sv| sv.fields.get(f.field) orelse return error.NoSuchField,
                else => return error.NotAStruct,
            },
            .const_ => |inner| try self.evalExpr(inner, env),
            .add => |op| .{ .int = (try self.evalExpr(op.a, env)).int +% (try self.evalExpr(op.b, env)).int },
            .sub => |op| .{ .int = (try self.evalExpr(op.a, env)).int -% (try self.evalExpr(op.b, env)).int },
            .mul => |op| .{ .int = (try self.evalExpr(op.a, env)).int *% (try self.evalExpr(op.b, env)).int },
            .div => |op| blk: {
                const b = (try self.evalExpr(op.b, env)).int;
                if (b == 0) return error.DivisionByZero;
                break :blk .{ .int = @divTrunc((try self.evalExpr(op.a, env)).int, b) };
            },
            .lt => |op| .{ .bool_ = (try self.evalExpr(op.a, env)).int < (try self.evalExpr(op.b, env)).int },
            .gt => |op| .{ .bool_ = (try self.evalExpr(op.a, env)).int > (try self.evalExpr(op.b, env)).int },
            .eq => |op| blk: {
                const a = try self.evalExpr(op.a, env);
                const b = try self.evalExpr(op.b, env);
                break :blk switch (a) {
                    .int => |x| .{ .bool_ = x == b.int },
                    .str => |x| .{ .bool_ = std.mem.eql(u8, x, b.str) },
                    else => return error.TypeMismatch,
                };
            },
            .alloc => |size_expr| blk: {
                const n: usize = @intCast((try self.evalExpr(size_expr, env)).int);
                const buf = try self.alloc.alloc(u8, n);
                @memset(buf, 0);
                break :blk .{ .ptr = buf };
            },
            .struct_lit => |sl| blk: {
                var fields = std.StringArrayHashMap(Value).init(self.alloc);
                for (sl.fields.items) |fi|
                    try fields.put(fi.name, try self.evalExpr(fi.expr, env));
                break :blk .{ .struct_ = .{ .name = sl.name, .fields = fields } };
            },
            .named => |name| if (std.mem.eql(u8, name, "READ")) .{ .int = 0 } else if (std.mem.eql(u8, name, "WRITE")) .{ .int = 1 } else return error.UnknownNamedConstant,
            .call => |c| try self.callFunc(c.name, c.args.items, env),
        };
    }

    fn printValue(_: *Vm, val: Value) void {
        var tmp: [64]u8 = undefined;
        switch (val) {
            .int => |n| bear_io.writeStdout(std.fmt.bufPrint(&tmp, "{d}\n", .{n}) catch return),
            .str => |s| {
                bear_io.writeStdout(s);
                bear_io.writeStdout("\n");
            },
            .bool_ => |b| bear_io.writeStdout(if (b) "true\n" else "false\n"),
            .ptr => bear_io.writeStdout("<ptr>\n"),
            .file => |fd| bear_io.writeStdout(std.fmt.bufPrint(&tmp, "<fd:{d}>\n", .{fd}) catch return),
            .void_ => {},
            .struct_ => |sv| {
                bear_io.writeStdout(sv.name);
                bear_io.writeStdout(" { ... }\n");
            },
        }
    }

    fn callFunc(self: *Vm, name: []const u8, arg_exprs: []*lexer.Expr, env: []Value) anyerror!Value {
        var args_buf: [32]Value = undefined;
        const argc = arg_exprs.len;
        if (argc > 32) return error.TooManyArguments;
        for (arg_exprs, 0..) |a, i|
            args_buf[i] = try self.evalExpr(a, env);
        const args = args_buf[0..argc];

        if (builtin_map.get(name)) |tag| {
            return switch (tag) {
                .puts => blk: {
                    for (args) |a| self.printValue(a);
                    bear_io.flushStdout();
                    break :blk .void_;
                },
                .open => blk: {
                    const path = args[0].str;
                    const mode = args[1].int;
                    const fd = if (mode == 0) inner: {
                        const f = try std.fs.cwd().openFile(path, .{});
                        break :inner try self.allocFile(.{ .read = f });
                    } else inner: {
                        const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
                        break :inner try self.allocFile(.{ .write = f });
                    };
                    break :blk .{ .file = fd };
                },
                .read => blk: {
                    const fd: usize = @intCast(args[0].file);
                    const size: usize = @intCast(args[2].int);
                    const buf = try self.alloc.alloc(u8, size);
                    const n = switch (self.files.items[fd].?) {
                        .read => |f| try f.read(buf),
                        else => return error.InvalidFileHandle,
                    };
                    break :blk .{ .str = buf[0..n] };
                },
                .write => blk: {
                    const fd: usize = @intCast(args[0].file);
                    const data: []const u8 = switch (args[1]) {
                        .str => |s| s,
                        .ptr => |p| p,
                        else => return error.TypeMismatch,
                    };
                    switch (self.files.items[fd].?) {
                        .write => |f| try f.writeAll(data),
                        else => return error.InvalidFileHandle,
                    }
                    break :blk .{ .int = @intCast(data.len) };
                },
                .close => blk: {
                    const fd: usize = @intCast(args[0].file);
                    if (fd < self.files.items.len) {
                        if (self.files.items[fd]) |fh| {
                            switch (fh) {
                                .read => |f| f.close(),
                                .write => |f| f.close(),
                            }
                            self.files.items[fd] = null;
                        }
                    }
                    break :blk .void_;
                },
            };
        }

        const func = self.findFunc(name) orelse return error.UndefinedFunction;
        const new_env = try self.alloc.alloc(Value, func.n_regs);

        @memset(new_env, .void_);

        for (func.params.items, 0..) |param, i|
            new_env[param.idx] = args[i];

        return (try self.execBody(func.body.items, new_env)) orelse .void_;
    }

    fn execBody(self: *Vm, stmts: []const lexer.Stmt, env: []Value) anyerror!?Value {
        for (stmts) |*stmt|
            if (try self.execStmt(stmt, env)) |v| return v;
        return null;
    }

    fn execStmt(self: *Vm, stmt: *const lexer.Stmt, env: []Value) anyerror!?Value {
        switch (stmt.*) {
            .assign => |a| {
                env[a.reg] = try self.evalExpr(a.expr, env);
            },
            .set_field => |sf| {
                const val = try self.evalExpr(sf.expr, env);
                try env[sf.reg].struct_.fields.put(sf.field, val);
            },
            .call => |c| {
                _ = try self.callFunc(c.name, c.args.items, env);
            },
            .ret => |e| return try self.evalExpr(e, env),
            .while_ => |w| {
                while (true) {
                    const keep = switch (try self.evalExpr(w.cond, env)) {
                        .bool_ => |b| b,
                        .int => |n| n != 0,
                        else => return error.TypeMismatch,
                    };
                    if (!keep) break;
                    if (try self.execBody(w.body.items, env)) |v| return v;
                }
            },
        }
        return null;
    }
};

fn run(program: *const lexer.Program, alloc: Allocator) !void {
    var vm = Vm.init(program, alloc);
    const main_fn = vm.findFunc("main") orelse return error.NoMainFunction;
    const env = try alloc.alloc(Value, main_fn.n_regs);
    @memset(env, .void_);
    _ = try vm.execBody(main_fn.body.items, env);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const argv = try std.process.argsAlloc(alloc);

    if (argv.len < 2) {
        std.debug.print("Usage: bear <file.bear>\n", .{});
        std.process.exit(1);
    }

    const src = std.fs.cwd().readFileAlloc(alloc, argv[1], 10 * 1024 * 1024) catch |e| {
        std.debug.print("Error reading {s}: {}\n", .{ argv[1], e });
        std.process.exit(1);
    };

    var tokens = lexer.tokenize(src, alloc) catch |e| {
        std.debug.print("Lex error: {}\n", .{e});
        std.process.exit(1);
    };
    _ = &tokens;

    const program = bear_parser.parse(tokens.items, alloc) catch |e| {
        std.debug.print("Parse error: {}\n", .{e});
        std.process.exit(1);
    };

    run(&program, alloc) catch |e| {
        std.debug.print("Runtime error: {}\n", .{e});
        std.process.exit(1);
    };
}

fn testLex(src: []const u8, alloc: Allocator) ![]lexer.Token {
    var list = try lexer.tokenize(src, alloc);
    return list.toOwnedSlice(alloc);
}

fn testParse(src: []const u8, alloc: Allocator) !lexer.Program {
    const list = try lexer.tokenize(src, alloc);
    return bear_parser.parse(list.items, alloc);
}

fn evalMain(src: []const u8, alloc: Allocator) !Value {
    const list = try lexer.tokenize(src, alloc);
    const prog = try bear_parser.parse(list.items, alloc);
    var vm = Vm.init(&prog, alloc);
    const main_fn = vm.findFunc("main") orelse return error.NoMainFunction;
    const env = try alloc.alloc(Value, main_fn.n_regs);
    @memset(env, .void_);
    return (try vm.execBody(main_fn.body.items, env)) orelse .void_;
}

test "lexer: empty input yields only eof" {
    const alloc = std.testing.allocator;
    const toks = try testLex("", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(@as(usize, 1), toks.len);
    try std.testing.expectEqual(lexer.TokenTag.eof, std.meta.activeTag(toks[0]));
}

test "lexer: keywords" {
    const alloc = std.testing.allocator;
    const toks = try testLex("const add sub mul div lt gt eq ret call while alloc set struct", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(lexer.TokenTag.kw_const, std.meta.activeTag(toks[0]));
    try std.testing.expectEqual(lexer.TokenTag.kw_add, std.meta.activeTag(toks[1]));
    try std.testing.expectEqual(lexer.TokenTag.kw_sub, std.meta.activeTag(toks[2]));
    try std.testing.expectEqual(lexer.TokenTag.kw_mul, std.meta.activeTag(toks[3]));
    try std.testing.expectEqual(lexer.TokenTag.kw_div, std.meta.activeTag(toks[4]));
    try std.testing.expectEqual(lexer.TokenTag.kw_lt, std.meta.activeTag(toks[5]));
    try std.testing.expectEqual(lexer.TokenTag.kw_gt, std.meta.activeTag(toks[6]));
    try std.testing.expectEqual(lexer.TokenTag.kw_eq, std.meta.activeTag(toks[7]));
    try std.testing.expectEqual(lexer.TokenTag.kw_ret, std.meta.activeTag(toks[8]));
    try std.testing.expectEqual(lexer.TokenTag.kw_call, std.meta.activeTag(toks[9]));
    try std.testing.expectEqual(lexer.TokenTag.kw_while, std.meta.activeTag(toks[10]));
    try std.testing.expectEqual(lexer.TokenTag.kw_alloc, std.meta.activeTag(toks[11]));
    try std.testing.expectEqual(lexer.TokenTag.kw_set, std.meta.activeTag(toks[12]));
    try std.testing.expectEqual(lexer.TokenTag.kw_struct, std.meta.activeTag(toks[13]));
}

test "lexer: type keywords" {
    const alloc = std.testing.allocator;
    const toks = try testLex("int void string bool", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(lexer.TokenTag.ty_int, std.meta.activeTag(toks[0]));
    try std.testing.expectEqual(lexer.TokenTag.ty_void, std.meta.activeTag(toks[1]));
    try std.testing.expectEqual(lexer.TokenTag.ty_string, std.meta.activeTag(toks[2]));
    try std.testing.expectEqual(lexer.TokenTag.ty_bool, std.meta.activeTag(toks[3]));
}

test "lexer: punctuation" {
    const alloc = std.testing.allocator;
    const toks = try testLex("{ } ( ) : , . =", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(lexer.TokenTag.lbrace, std.meta.activeTag(toks[0]));
    try std.testing.expectEqual(lexer.TokenTag.rbrace, std.meta.activeTag(toks[1]));
    try std.testing.expectEqual(lexer.TokenTag.lparen, std.meta.activeTag(toks[2]));
    try std.testing.expectEqual(lexer.TokenTag.rparen, std.meta.activeTag(toks[3]));
    try std.testing.expectEqual(lexer.TokenTag.colon, std.meta.activeTag(toks[4]));
    try std.testing.expectEqual(lexer.TokenTag.comma, std.meta.activeTag(toks[5]));
    try std.testing.expectEqual(lexer.TokenTag.dot, std.meta.activeTag(toks[6]));
    try std.testing.expectEqual(lexer.TokenTag.assign, std.meta.activeTag(toks[7]));
}

test "lexer: integer literals" {
    const alloc = std.testing.allocator;
    const toks = try testLex("0 42 -7", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(@as(i64, 0), toks[0].int);
    try std.testing.expectEqual(@as(i64, 42), toks[1].int);
    try std.testing.expectEqual(@as(i64, -7), toks[2].int);
}

test "lexer: string literal" {
    const alloc = std.testing.allocator;
    const toks = try testLex("\"hello world\"", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqualStrings("hello world", toks[0].str);
}

test "lexer: string escape sequences" {
    const alloc = std.testing.allocator;
    const toks = try testLex("\"line1\\nline2\"", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqualStrings("line1\nline2", toks[0].str);
}

test "lexer: register and func sigils" {
    const alloc = std.testing.allocator;
    const toks = try testLex("%my_reg @my_func", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(lexer.TokenTag.reg, std.meta.activeTag(toks[0]));
    try std.testing.expectEqualStrings("my_reg", toks[0].reg);
    try std.testing.expectEqual(lexer.TokenTag.func, std.meta.activeTag(toks[1]));
    try std.testing.expectEqualStrings("my_func", toks[1].func);
}

test "lexer: identifier" {
    const alloc = std.testing.allocator;
    const toks = try testLex("puts other_func", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(lexer.TokenTag.ident, std.meta.activeTag(toks[0]));
    try std.testing.expectEqualStrings("puts", toks[0].ident);
    try std.testing.expectEqualStrings("other_func", toks[1].ident);
}

test "lexer: line comment is skipped" {
    const alloc = std.testing.allocator;
    const toks = try testLex("; this is a comment\n42", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(@as(i64, 42), toks[0].int);
}

test "lexer: unterminated string is error" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.UnterminatedString, testLex("\"oops", alloc));
}

test "lexer: unexpected char is error" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedChar, testLex("^", alloc));
}

test "parser: minimal void function" {
    const alloc = std.testing.allocator;
    const prog = try testParse("@other_func: void { ret 0 }", alloc);
    try std.testing.expectEqual(@as(usize, 1), prog.functions.items.len);
    try std.testing.expectEqualStrings("other_func", prog.functions.items[0].name);
    try std.testing.expectEqual(lexer.Ty.void_, prog.functions.items[0].ret_ty);
    try std.testing.expectEqual(@as(usize, 0), prog.functions.items[0].params.items.len);
}

test "parser: function with empty parens and return type" {
    const alloc = std.testing.allocator;
    const prog = try testParse("@main(): int { ret 0 }", alloc);
    try std.testing.expectEqual(lexer.Ty.int, prog.functions.items[0].ret_ty);
}

test "parser: call without args" {
    const alloc = std.testing.allocator;
    const prog = try testParse("@main(): int { call other_func ret 0 }", alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expectEqualStrings("other_func", stmt.call.name);
    try std.testing.expectEqual(@as(usize, 0), stmt.call.args.items.len);
}

test "parser: call with args" {
    const alloc = std.testing.allocator;
    const prog = try testParse("@main(): int { call puts(\"hi\") ret 0 }", alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expectEqualStrings("puts", stmt.call.name);
    try std.testing.expectEqual(@as(usize, 1), stmt.call.args.items.len);
}

test "parser: assign const int" {
    const alloc = std.testing.allocator;
    const prog = try testParse("@main(): int { %x = const 42 ret 0 }", alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expectEqual(@as(lexer.RegIdx, 0), stmt.assign.reg);
}

test "parser: assign add expr" {
    const alloc = std.testing.allocator;
    const prog = try testParse("@main(): int { %r = add %a, %b ret 0 }", alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expect(std.meta.activeTag(stmt.assign.expr.*) == .add);
}

test "parser: while loop" {
    const alloc = std.testing.allocator;
    const prog = try testParse("@main(): int { while (lt %i, 10) { call puts(\"x\") } ret 0 }", alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expect(std.meta.activeTag(stmt) == .while_);
}

test "parser: set field" {
    const alloc = std.testing.allocator;
    const prog = try testParse("@main(): int { set %p.age = const 1 ret 0 }", alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expectEqualStrings("age", stmt.set_field.field);
}

test "parser: field access expr" {
    const alloc = std.testing.allocator;
    const prog = try testParse("@main(): int { %v = %p.name ret 0 }", alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expect(std.meta.activeTag(stmt.assign.expr.*) == .field);
    try std.testing.expectEqualStrings("name", stmt.assign.expr.field.field);
}

test "parser: alloc expr" {
    const alloc = std.testing.allocator;
    const prog = try testParse("@main(): int { %buf = alloc 1024 ret 0 }", alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expect(std.meta.activeTag(stmt.assign.expr.*) == .alloc);
}

test "parser: struct definition" {
    const alloc = std.testing.allocator;
    const prog = try testParse("struct Person { name: string age: int }", alloc);
    try std.testing.expectEqual(@as(usize, 1), prog.structs.items.len);
    try std.testing.expectEqualStrings("Person", prog.structs.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), prog.structs.items[0].fields.items.len);
}

test "parser: struct literal in assign" {
    const alloc = std.testing.allocator;
    const prog = try testParse("@main(): int { %p = Person { name: \"Alice\" age: 25 } ret 0 }", alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expect(std.meta.activeTag(stmt.assign.expr.*) == .struct_lit);
}

test "parser: named constant" {
    const alloc = std.testing.allocator;
    const prog = try testParse("@main(): int { %m = READ ret 0 }", alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expect(std.meta.activeTag(stmt.assign.expr.*) == .named);
    try std.testing.expectEqualStrings("READ", stmt.assign.expr.named);
}

test "parser: unknown top-level token is error" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedTopLevel, testParse("42", alloc));
}

test "interpreter: ret integer" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { ret 42 }", alloc);
    try std.testing.expectEqual(@as(i64, 42), v.int);
}

test "interpreter: const and ret" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %x = const 7 ret %x }", alloc);
    try std.testing.expectEqual(@as(i64, 7), v.int);
}

test "interpreter: arithmetic add" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %r = add 3, 4 ret %r }", alloc);
    try std.testing.expectEqual(@as(i64, 7), v.int);
}

test "interpreter: arithmetic sub" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %r = sub 10, 3 ret %r }", alloc);
    try std.testing.expectEqual(@as(i64, 7), v.int);
}

test "interpreter: arithmetic mul" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %r = mul 3, 4 ret %r }", alloc);
    try std.testing.expectEqual(@as(i64, 12), v.int);
}

test "interpreter: arithmetic div" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %r = div 12, 4 ret %r }", alloc);
    try std.testing.expectEqual(@as(i64, 3), v.int);
}

test "interpreter: div by zero is error" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.DivisionByZero, evalMain("@main(): int { %r = div 1, 0 ret %r }", alloc));
}

test "interpreter: comparison lt true" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %r = lt 3, 5 ret %r }", alloc);
    try std.testing.expectEqual(true, v.bool_);
}

test "interpreter: comparison lt false" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %r = lt 5, 3 ret %r }", alloc);
    try std.testing.expectEqual(false, v.bool_);
}

test "interpreter: comparison gt" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %r = gt 5, 3 ret %r }", alloc);
    try std.testing.expectEqual(true, v.bool_);
}

test "interpreter: comparison eq ints" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %r = eq 4, 4 ret %r }", alloc);
    try std.testing.expectEqual(true, v.bool_);
}

test "interpreter: while loop counts" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %i = const 0 while (lt %i, 5) { %i = add %i, 1 } ret %i }", alloc);
    try std.testing.expectEqual(@as(i64, 5), v.int);
}

test "interpreter: user function call" {
    const alloc = std.testing.allocator;
    const src =
        \\@double(%x: int): int { ret mul %x, 2 }
        \\@main(): int { %r = call double(21) ret %r }
    ;
    const v = try evalMain(src, alloc);
    try std.testing.expectEqual(@as(i64, 42), v.int);
}

test "interpreter: struct field access" {
    const alloc = std.testing.allocator;
    const src =
        \\struct Point { x: int y: int }
        \\@main(): int { %p = Point { x: 10 y: 20 } %v = %p.x ret %v }
    ;
    const v = try evalMain(src, alloc);
    try std.testing.expectEqual(@as(i64, 10), v.int);
}

test "interpreter: struct set field" {
    const alloc = std.testing.allocator;
    const src =
        \\struct Point { x: int y: int }
        \\@main(): int { %p = Point { x: 1 y: 2 } set %p.x = const 99 %v = %p.x ret %v }
    ;
    const v = try evalMain(src, alloc);
    try std.testing.expectEqual(@as(i64, 99), v.int);
}

test "interpreter: named constant READ" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %m = READ ret %m }", alloc);
    try std.testing.expectEqual(@as(i64, 0), v.int);
}

test "interpreter: named constant WRITE" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %m = WRITE ret %m }", alloc);
    try std.testing.expectEqual(@as(i64, 1), v.int);
}

test "interpreter: alloc returns ptr" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %buf = alloc 64 ret 0 }", alloc);
    try std.testing.expectEqual(@as(i64, 0), v.int);
}

test "interpreter: no main is error" {
    const alloc = std.testing.allocator;
    const list = try lexer.tokenize("@other: void { ret 0 }", alloc);
    const prog = try bear_parser.parse(list.items, alloc);
    var vm = Vm.init(&prog, alloc);
    try std.testing.expect(vm.findFunc("main") == null);
}

test "interpreter: undefined register is error" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.NotAStruct,
        evalMain("@main(): int { %v = %nope.field ret 0 }", alloc),
    );
}
