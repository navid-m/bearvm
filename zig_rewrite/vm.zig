const std = @import("std");
const lexer = @import("lexer.zig");
const bear_io = @import("io.zig");

// --- Task table for spawn/sync ---

const TaskState = enum { running, done };

const Task = struct {
    thread: std.Thread,
    state: TaskState,
    result: Value,
    err: ?anyerror,
};

pub const TaskTable = struct {
    mutex: std.Thread.Mutex,
    tasks: std.ArrayListUnmanaged(Task),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) TaskTable {
        return .{ .mutex = .{}, .tasks = .empty, .alloc = alloc };
    }

    pub fn deinit(self: *TaskTable) void {
        self.tasks.deinit(self.alloc);
    }

    /// Reserve a slot and return its ID (index). Caller fills in the thread after spawning.
    pub fn reserve(self: *TaskTable) !u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const id: u32 = @intCast(self.tasks.items.len);
        try self.tasks.append(self.alloc, .{
            .thread = undefined,
            .state = .running,
            .result = .void_,
            .err = null,
        });
        return id;
    }

    pub fn setThread(self: *TaskTable, id: u32, thread: std.Thread) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.tasks.items[id].thread = thread;
    }

    pub fn complete(self: *TaskTable, id: u32, result: Value, err: ?anyerror) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Simple values (int, bool, void) are safe to copy directly.
        // For this VM, spawned tasks return numeric results (fib returns int).
        self.tasks.items[id].result = result;
        self.tasks.items[id].err = err;
        self.tasks.items[id].state = .done;
    }

    /// Join the thread and return the result (blocks until done).
    pub fn join(self: *TaskTable, id: u32) !Value {
        // Grab the thread handle (it's set before we can call join)
        self.mutex.lock();
        const thread = self.tasks.items[id].thread;
        self.mutex.unlock();
        thread.join();
        self.mutex.lock();
        defer self.mutex.unlock();
        const task = &self.tasks.items[id];
        if (task.err) |e| return e;
        return task.result;
    }
};

// --- Thread entry point ---

const SpawnArgs = struct {
    program: *const lexer.Program,
    func_name: []const u8,
    args: []Value,
    task_id: u32,
    tasks: *TaskTable,
    alloc: std.mem.Allocator,
};

fn spawnEntry(sa: *SpawnArgs) void {
    // Each spawned task gets its own arena so allocations are thread-safe
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    defer sa.alloc.destroy(sa);
    var vm = Vm.init(sa.program, alloc) catch |e| {
        sa.tasks.complete(sa.task_id, .void_, e);
        sa.alloc.free(sa.args);
        return;
    };
    defer vm.deinit();
    vm.tasks = sa.tasks;

    const result = vm.callFuncWithValues(sa.func_name, sa.args) catch |e| {
        sa.tasks.complete(sa.task_id, .void_, e);
        sa.alloc.free(sa.args);
        return;
    };
    sa.alloc.free(sa.args);
    sa.tasks.complete(sa.task_id, result, null);
}

pub fn run(program: *const lexer.Program, alloc: std.mem.Allocator) !void {
    var tasks = TaskTable.init(alloc);
    defer tasks.deinit();

    var vm = try Vm.init(program, alloc);
    defer vm.deinit();
    vm.tasks = &tasks;

    const main_fn = vm.findFunc("main") orelse return error.NoMainFunction;
    const env = try alloc.alloc(Value, main_fn.n_regs);
    defer {
        for (env) |*v| v.deinit(alloc);
        alloc.free(env);
    }
    @memset(env, .void_);
    _ = try vm.execBody(main_fn.body.items, env);
}

pub const Value = union(enum) {
    int: i64,
    str: []const u8,
    bool_: bool,
    ptr: []u8,
    file: i64,
    void_,
    struct_: StructVal,

    pub fn deinit(self: *Value, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .ptr => |p| alloc.free(p),
            .struct_ => |*sv| {
                var it = sv.fields.iterator();
                while (it.next()) |entry| entry.value_ptr.deinit(alloc);
                sv.fields.deinit();
            },
            else => {},
        }
    }
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
    tasks: ?*TaskTable,

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
            .tasks = null,
        };
    }

    pub fn deinit(self: *Vm) void {
        self.func_index.deinit(self.alloc);
        self.files.deinit(self.alloc);
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
                .le => |op| return .{ .bool_ = (try self.evalExpr(op.a, env)).int <= (try self.evalExpr(op.b, env)).int },
                .ge => |op| return .{ .bool_ = (try self.evalExpr(op.a, env)).int >= (try self.evalExpr(op.b, env)).int },
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
                .spawn => |s| {
                    const task_table = self.tasks orelse return error.NoTaskTable;
                    // Evaluate args in the current thread
                    var args_buf: [32]Value = undefined;
                    const argc = s.args.items.len;
                    if (argc > 32) return error.TooManyArguments;
                    for (s.args.items, 0..) |a, i|
                        args_buf[i] = try self.evalExpr(a, env);
                    // Copy args to heap for the new thread
                    const args_heap = try self.alloc.alloc(Value, argc);
                    @memcpy(args_heap, args_buf[0..argc]);

                    const task_id = try task_table.reserve();

                    const sa = try self.alloc.create(SpawnArgs);
                    sa.* = .{
                        .program = self.program,
                        .func_name = s.name,
                        .args = args_heap,
                        .task_id = task_id,
                        .tasks = task_table,
                        .alloc = self.alloc,
                    };
                    const thread = try std.Thread.spawn(.{}, spawnEntry, .{sa});
                    task_table.setThread(task_id, thread);
                    return .{ .int = @intCast(task_id) };
                },
                .sync => |reg| {
                    const task_table = self.tasks orelse return error.NoTaskTable;
                    const task_id: u32 = @intCast(env[reg].int);
                    return try task_table.join(task_id);
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
        return self.callFuncWithValues(name, args);
    }

    pub fn callFuncWithValues(self: *Vm, name: []const u8, args: []Value) anyerror!Value {

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
        defer if (func.n_regs > 32) {
            for (new_env) |*v| v.deinit(self.alloc);
            self.alloc.free(new_env);
        };

        for (func.params.items, 0..) |param, i|
            new_env[param.idx] = args[i];

        return (try self.execBody(func.body.items, new_env)) orelse .void_;
    }

    pub fn execBody(self: *Vm, stmts: []const lexer.Stmt, env: []Value) anyerror!?Value {
        var label_map = std.StringHashMap(usize).init(self.alloc);
        defer label_map.deinit();
        for (stmts, 0..) |*stmt, i| {
            if (stmt.* == .label) try label_map.put(stmt.label, i);
        }

        var pc: usize = 0;
        while (pc < stmts.len) {
            const stmt = &stmts[pc];
            switch (stmt.*) {
                .assign => |a| {
                    env[a.reg] = try self.evalExpr(a.expr, env);
                    pc += 1;
                },
                .set_field => |sf| {
                    const val = try self.evalExpr(sf.expr, env);
                    try env[sf.reg].struct_.fields.put(sf.field, val);
                    pc += 1;
                },
                .call => |c| {
                    _ = try self.callFunc(c.name, c.args.items, env);
                    pc += 1;
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
                    pc += 1;
                },
                .label => pc += 1,
                .jmp => |target| {
                    pc = label_map.get(target) orelse return error.UndefinedLabel;
                },
                .br_if => |br| {
                    const cond_val = env[br.cond];
                    const taken = switch (cond_val) {
                        .bool_ => |b| b,
                        .int => |n| n != 0,
                        else => return error.TypeMismatch,
                    };
                    const target = if (taken) br.true_label else br.false_label;
                    pc = label_map.get(target) orelse return error.UndefinedLabel;
                },
            }
        }
        return null;
    }
};
