const std = @import("std");
const lexer = @import("lexer.zig");
const bear_io = @import("io.zig");

pub const Value = union(enum) {
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

pub const Vm = struct {
    program: *const lexer.Program,
    func_index: std.StringHashMapUnmanaged(u32),
    files: std.ArrayListUnmanaged(?FileHandle),
    alloc: std.mem.Allocator,

    pub fn init(program: *const lexer.Program, alloc: std.mem.Allocator) !Vm {
        var func_index = std.StringHashMapUnmanaged(u32){};
        try func_index.ensureTotalCapacity(alloc, @intCast(program.functions.items.len));
        for (program.functions.items, 0..) |*f, i|
            func_index.putAssumeCapacity(f.name, @intCast(i));
        return .{
            .program = program,
            .func_index = func_index,
            .files = .empty,
            .alloc = alloc,
        };
    }

    pub fn findFunc(self: *Vm, name: []const u8) ?*const lexer.Function {
        const idx = self.func_index.get(name) orelse return null;
        return &self.program.functions.items[idx];
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
        var cur = expr;
        while (true) {
            switch (cur.*) {
                .int => |n| return .{ .int = n },
                .str => |s| return .{ .str = s },
                .reg => |r| return env[r],
                .field => |f| return switch (env[f.reg]) {
                    .struct_ => |sv| sv.fields.get(f.field) orelse return error.NoSuchField,
                    else => error.NotAStruct,
                },
                .const_ => |inner| {
                    cur = inner;
                    continue;
                },
                .add => |op| return .{ .int = (try self.evalExpr(op.a, env)).int +% (try self.evalExpr(op.b, env)).int },
                .sub => |op| return .{ .int = (try self.evalExpr(op.a, env)).int -% (try self.evalExpr(op.b, env)).int },
                .mul => |op| return .{ .int = (try self.evalExpr(op.a, env)).int *% (try self.evalExpr(op.b, env)).int },
                .div => |op| {
                    const b = (try self.evalExpr(op.b, env)).int;
                    if (b == 0) return error.DivisionByZero;
                    return .{ .int = @divTrunc((try self.evalExpr(op.a, env)).int, b) };
                },
                .lt => |op| return .{ .bool_ = (try self.evalExpr(op.a, env)).int < (try self.evalExpr(op.b, env)).int },
                .gt => |op| return .{ .bool_ = (try self.evalExpr(op.a, env)).int > (try self.evalExpr(op.b, env)).int },
                .eq => |op| {
                    const a = try self.evalExpr(op.a, env);
                    const b = try self.evalExpr(op.b, env);
                    return switch (a) {
                        .int => |x| .{ .bool_ = x == b.int },
                        .str => |x| .{ .bool_ = std.mem.eql(u8, x, b.str) },
                        else => error.TypeMismatch,
                    };
                },
                .alloc => |size_expr| {
                    const n: usize = @intCast((try self.evalExpr(size_expr, env)).int);
                    const buf = try self.alloc.alloc(u8, n);
                    @memset(buf, 0);
                    return .{ .ptr = buf };
                },
                .struct_lit => |sl| {
                    var fields = std.StringArrayHashMap(Value).init(self.alloc);
                    for (sl.fields.items) |fi|
                        try fields.put(fi.name, try self.evalExpr(fi.expr, env));
                    return .{ .struct_ = .{ .name = sl.name, .fields = fields } };
                },
                .named => |name| {
                    if (name.len > 0) {
                        if (name[0] == 'R') return .{ .int = 0 };
                        if (name[0] == 'W') return .{ .int = 1 };
                    }
                    return error.UnknownNamedConstant;
                },
                .call => |c| return try self.callFunc(c.name, c.args.items, env),
            }
        }
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

        const idx = self.func_index.get(name) orelse return error.UndefinedFunction;
        const func = &self.program.functions.items[idx];
        var stack_env: [32]Value = undefined;
        const new_env: []Value = if (func.n_regs <= 32) blk: {
            @memset(stack_env[0..func.n_regs], .void_);
            break :blk stack_env[0..func.n_regs];
        } else blk: {
            const e = try self.alloc.alloc(Value, func.n_regs);
            @memset(e, .void_);
            break :blk e;
        };

        for (func.params.items, 0..) |param, i|
            new_env[param.idx] = args[i];

        return (try self.execBody(func.body.items, new_env)) orelse .void_;
    }

    pub fn execBody(self: *Vm, stmts: []const lexer.Stmt, env: []Value) anyerror!?Value {
        for (stmts) |*stmt| {
            switch (stmt.*) {
                .assign => |a| env[a.reg] = try self.evalExpr(a.expr, env),
                .set_field => |sf| {
                    const val = try self.evalExpr(sf.expr, env);
                    try env[sf.reg].struct_.fields.put(sf.field, val);
                },
                .call => |c| _ = try self.callFunc(c.name, c.args.items, env),
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
        }
        return null;
    }
};
