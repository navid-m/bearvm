const std = @import("std");
const lexer = @import("lexer.zig");
const bear_io = @import("io.zig");

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
        self.tasks.items[id].result = result;
        self.tasks.items[id].err = err;
        self.tasks.items[id].state = .done;
    }

    pub fn join(self: *TaskTable, id: u32) !Value {
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

const SpawnArgs = struct {
    program: *const lexer.Program,
    func_name: []const u8,
    args: []Value,
    task_id: u32,
    tasks: *TaskTable,
    alloc: std.mem.Allocator,
};

fn spawnEntry(sa: *SpawnArgs) void {
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
    const main_idx = vm.func_index.get("main") orelse return error.NoMainFunction;
    const env = try alloc.alloc(Value, main_fn.n_regs);
    defer {
        for (env) |*v| v.deinit(alloc);
        alloc.free(env);
    }
    @memset(env, .void_);
    _ = try vm.execBody(main_fn.body.items, env, main_idx);
}

pub const Value = union(enum) {
    /// An integer value.
    int: i64,

    /// Float (single precision stored as f64 for simplicity)
    float_: f64,

    /// Double precision float
    double_: f64,

    /// Raw string value.
    str: []const u8,

    /// Boolean bit.
    bool_: bool,

    /// Heap-allocated raw buffer — owned by the VM, freed on deinit/free.
    ptr: []u8,

    /// Arena-allocated raw buffer — owned by a BearArena, NOT freed individually.
    arena_ptr: []u8,

    /// A typed pointer — references a heap-allocated Value cell.
    /// Used by get_field_ref / get_index_ref / alloc_type / alloc_array.
    ref: *HeapCell,

    /// File handle.
    file: i64,

    /// Nothing.
    void_,

    /// Structure value.
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

    /// Fast integer extraction — avoids a branch when we know it's int.
    pub inline fn asInt(self: Value) i64 {
        return self.int;
    }

    /// Fast bool extraction.
    pub inline fn asBool(self: Value) bool {
        return switch (self) {
            .bool_ => |b| b,
            .int => |n| n != 0,
            else => unreachable,
        };
    }

    /// Fast integer check
    pub inline fn isInt(self: Value) bool {
        return self == .int;
    }
};

/// A single heap-allocated value cell, used as the target of a `ref`.
/// Owned by a HeapStruct or HeapArray; the ref just borrows a pointer.
pub const HeapCell = struct {
    value: Value,
};

/// Heap-allocated struct — fields are HeapCells so we can take refs into them.
pub const HeapStruct = struct {
    name: []const u8,
    fields: std.StringArrayHashMap(HeapCell),

    pub fn deinit(self: *HeapStruct, alloc: std.mem.Allocator) void {
        var it = self.fields.iterator();
        while (it.next()) |entry| entry.value_ptr.value.deinit(alloc);
        self.fields.deinit();
    }
};

/// Heap-allocated array — elements are HeapCells so we can take refs into them.
pub const HeapArray = struct {
    cells: []HeapCell,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *HeapArray) void {
        for (self.cells) |*c| c.value.deinit(self.alloc);
        self.alloc.free(self.cells);
    }
};

/// Arena allocator — all allocations freed at once on arena_destroy.
pub const BearArena = struct {
    inner: std.heap.ArenaAllocator,

    pub fn init(backing: std.mem.Allocator) BearArena {
        return .{ .inner = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn allocator(self: *BearArena) std.mem.Allocator {
        return self.inner.allocator();
    }

    pub fn deinit(self: *BearArena) void {
        self.inner.deinit();
    }
};

const StructVal = struct {
    name: []const u8,
    fields: std.StringArrayHashMap(Value),
};

const FileHandle = union(enum) { read: std.fs.File, write: std.fs.File };
const BuiltinTag = enum(u8) { puts, open, read, write, close, flush, putf };
const builtin_map = std.StaticStringMap(BuiltinTag).initComptime(.{
    .{ "puts", .puts },
    .{ "open", .open },
    .{ "read", .read },
    .{ "write", .write },
    .{ "close", .close },
    .{ "flush", .flush },
    .{ "putf", .putf },
});

/// Pre-built label map for a function body (label name -> statement index).
const LabelMap = std.StringHashMapUnmanaged(usize);

/// Resolved call target — cached at parse time to avoid repeated hash lookups.
const CallTarget = union(enum) {
    builtin: BuiltinTag,
    user: u32,
};

/// Branch table entry: [true_pc, false_pc] for br_if, or [-1,-1] for non-branch stmts.
const BrEntry = [2]i32;

pub const Vm = struct {
    program: *const lexer.Program,

    /// Maps function name -> index in program.functions
    func_index: std.StringHashMapUnmanaged(u32),

    /// Pre-built label maps for each function (indexed same as func_index values)
    label_maps: []LabelMap,

    /// Pre-built pc-indexed jump tables for each function (pc -> target pc for jmp/br_if)
    jump_tables: [][]i32,

    /// Pre-built branch tables for br_if: per-function, per-pc -> [true_pc, false_pc]
    br_tables: [][]BrEntry,

    /// Unified call target cache: name -> CallTarget (builtins + user funcs)
    call_cache: std.StringHashMapUnmanaged(CallTarget),

    /// Per-function, per-pc pre-resolved call targets (null = not a call stmt/assign-call).
    /// Indexed as call_tables[func_idx][pc] — avoids hash lookup on every call site.
    call_tables: [][]?CallTarget,

    /// File handles table
    files: std.ArrayListUnmanaged(?FileHandle),

    /// Heap-allocated structs (owned here, freed on deinit)
    heap_structs: std.ArrayListUnmanaged(*HeapStruct),

    /// Heap-allocated arrays (owned here, freed on deinit)
    heap_arrays: std.ArrayListUnmanaged(*HeapArray),

    /// Arenas (owned here, freed on deinit or arena_destroy)
    arenas: std.ArrayListUnmanaged(?*BearArena),
    alloc: std.mem.Allocator,
    tasks: ?*TaskTable,

    pub fn init(program: *const lexer.Program, alloc: std.mem.Allocator) !Vm {
        const n = program.functions.items.len;

        var func_index = std.StringHashMapUnmanaged(u32){};
        try func_index.ensureTotalCapacity(alloc, @intCast(n));
        for (program.functions.items, 0..) |*f, i|
            func_index.putAssumeCapacity(f.name, @intCast(i));

        const label_maps = try alloc.alloc(LabelMap, n);
        for (label_maps) |*lm| lm.* = .{};
        for (program.functions.items, 0..) |*f, i| {
            try buildLabelMap(&label_maps[i], f.body.items, alloc);
        }

        const jump_tables = try alloc.alloc([]i32, n);
        const br_tables = try alloc.alloc([]BrEntry, n);
        for (program.functions.items, 0..) |*f, i| {
            const len = f.body.items.len;
            const jt = try alloc.alloc(i32, len);
            @memset(jt, -1);
            const bt = try alloc.alloc(BrEntry, len);
            @memset(bt, .{ -1, -1 });
            for (f.body.items, 0..) |*s, si| {
                switch (s.*) {
                    .jmp => |target| {
                        jt[si] = @intCast(label_maps[i].get(target) orelse continue);
                    },
                    .br_if => |br| {
                        const t: i32 = @intCast(label_maps[i].get(br.true_label) orelse continue);
                        const f2: i32 = @intCast(label_maps[i].get(br.false_label) orelse continue);
                        bt[si] = .{ t, f2 };
                    },
                    else => {},
                }
            }
            jump_tables[i] = jt;
            br_tables[i] = bt;
        }

        var call_cache = std.StringHashMapUnmanaged(CallTarget){};
        try call_cache.ensureTotalCapacity(alloc, @intCast(n + builtin_map.keys().len));
        for (builtin_map.keys(), builtin_map.values()) |k, v|
            call_cache.putAssumeCapacity(k, .{ .builtin = v });
        for (program.functions.items, 0..) |*f, i|
            call_cache.putAssumeCapacity(f.name, .{ .user = @intCast(i) });

        const call_tables = try alloc.alloc([]?CallTarget, n);
        for (program.functions.items, 0..) |*f, i| {
            const ct = try alloc.alloc(?CallTarget, f.body.items.len);
            @memset(ct, null);
            for (f.body.items, 0..) |*s, si| {
                switch (s.*) {
                    .call => |c| ct[si] = call_cache.get(c.name),
                    .assign => |a| if (a.expr.* == .call) {
                        ct[si] = call_cache.get(a.expr.call.name);
                    },
                    else => {},
                }
            }
            call_tables[i] = ct;
        }

        return .{
            .program = program,
            .func_index = func_index,
            .label_maps = label_maps,
            .jump_tables = jump_tables,
            .br_tables = br_tables,
            .call_cache = call_cache,
            .call_tables = call_tables,
            .files = .empty,
            .heap_structs = .empty,
            .heap_arrays = .empty,
            .arenas = .empty,
            .alloc = alloc,
            .tasks = null,
        };
    }

    pub fn deinit(self: *Vm) void {
        self.func_index.deinit(self.alloc);
        for (self.label_maps) |*lm| lm.deinit(self.alloc);
        self.alloc.free(self.label_maps);
        for (self.jump_tables) |jt| self.alloc.free(jt);
        self.alloc.free(self.jump_tables);
        for (self.br_tables) |bt| self.alloc.free(bt);
        self.alloc.free(self.br_tables);
        self.call_cache.deinit(self.alloc);
        for (self.call_tables) |ct| self.alloc.free(ct);
        self.alloc.free(self.call_tables);
        self.files.deinit(self.alloc);
        for (self.heap_structs.items) |hs| {
            hs.deinit(self.alloc);
            self.alloc.destroy(hs);
        }
        self.heap_structs.deinit(self.alloc);
        for (self.heap_arrays.items) |ha| {
            ha.deinit();
            self.alloc.destroy(ha);
        }
        self.heap_arrays.deinit(self.alloc);
        for (self.arenas.items) |maybe_arena| {
            if (maybe_arena) |arena| {
                arena.deinit();
                self.alloc.destroy(arena);
            }
        }
        self.arenas.deinit(self.alloc);
    }

    pub fn findFunc(self: *Vm, name: []const u8) ?*const lexer.Function {
        const idx = self.func_index.get(name) orelse return null;
        return &self.program.functions.items[idx];
    }

    pub fn getLabelMap(self: *Vm, name: []const u8) *const LabelMap {
        const idx = self.func_index.get(name) orelse unreachable;
        return &self.label_maps[idx];
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

    /// Evaluate an expression with predecessor label context (needed for phi).
    fn evalExprWithPrev(self: *Vm, expr: *const lexer.Expr, env: []Value, prev_label: ?[]const u8) anyerror!Value {
        if (expr.* == .phi) {
            const arms = expr.phi;
            const from = prev_label orelse return error.PhiWithNoPredecessor;
            for (arms.items) |arm| {
                if (std.mem.eql(u8, arm.label, from)) return env[arm.reg];
            }
            return error.PhiNoMatchingArm;
        }
        return self.evalExpr(expr, env);
    }

    /// Evaluate an expression. Hot path — keep it tight.
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
                .add => |op| {
                    const a = try self.evalExpr(op.a, env);
                    const b = try self.evalExpr(op.b, env);
                    if (a.isInt() and b.isInt()) {
                        return .{ .int = a.int +% b.int };
                    }
                    return switch (a) {
                        .float_ => |fa| .{ .float_ = fa + b.float_ },
                        .double_ => |fa| .{ .double_ = fa + b.double_ },
                        else => .{ .int = a.int +% b.int },
                    };
                },
                .sub => |op| {
                    const a = try self.evalExpr(op.a, env);
                    const b = try self.evalExpr(op.b, env);
                    return switch (a) {
                        .float_ => |fa| .{ .float_ = fa - b.float_ },
                        .double_ => |fa| .{ .double_ = fa - b.double_ },
                        else => .{ .int = a.int -% b.int },
                    };
                },
                .mul => |op| {
                    const a = try self.evalExpr(op.a, env);
                    const b = try self.evalExpr(op.b, env);
                    return switch (a) {
                        .float_ => |fa| .{ .float_ = fa * b.float_ },
                        .double_ => |fa| .{ .double_ = fa * b.double_ },
                        else => .{ .int = a.int *% b.int },
                    };
                },
                .div => |op| {
                    const a = try self.evalExpr(op.a, env);
                    const b = try self.evalExpr(op.b, env);
                    return switch (a) {
                        .float_ => |fa| .{ .float_ = fa / b.float_ },
                        .double_ => |fa| .{ .double_ = fa / b.double_ },
                        else => blk: {
                            if (b.int == 0) return error.DivisionByZero;
                            break :blk .{ .int = @divTrunc(a.int, b.int) };
                        },
                    };
                },
                .lt => |op| {
                    const a = try self.evalExprFast(op.a, env);
                    const b = try self.evalExprFast(op.b, env);
                    return .{ .bool_ = a < b };
                },
                .gt => |op| {
                    const a = try self.evalExprFast(op.a, env);
                    const b = try self.evalExprFast(op.b, env);
                    return .{ .bool_ = a > b };
                },
                .le => |op| {
                    const a = try self.evalExprFast(op.a, env);
                    const b = try self.evalExprFast(op.b, env);
                    return .{ .bool_ = a <= b };
                },
                .ge => |op| {
                    const a = try self.evalExprFast(op.a, env);
                    const b = try self.evalExprFast(op.b, env);
                    return .{ .bool_ = a >= b };
                },
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
                .alloc_type => |type_name| {
                    const struct_def = blk: {
                        for (self.program.structs.items) |*sd| {
                            if (std.mem.eql(u8, sd.name, type_name)) break :blk sd;
                        }
                        return error.UnknownType;
                    };
                    const hs = try self.alloc.create(HeapStruct);
                    hs.* = .{
                        .name = struct_def.name,
                        .fields = std.StringArrayHashMap(HeapCell).init(self.alloc),
                    };
                    for (struct_def.fields.items) |f| {
                        const zero: Value = switch (f.ty) {
                            .int => .{ .int = 0 },
                            .bool_ => .{ .bool_ = false },
                            .str => .{ .str = "" },
                            else => .void_,
                        };
                        try hs.fields.put(f.name, .{ .value = zero });
                    }
                    try self.heap_structs.append(self.alloc, hs);
                    const ha = try self.alloc.create(HeapArray);
                    ha.* = .{ .cells = try self.alloc.alloc(HeapCell, 1), .alloc = self.alloc };
                    ha.cells[0] = .{ .value = .{ .int = @as(i64, @bitCast(@intFromPtr(hs))) } };
                    try self.heap_arrays.append(self.alloc, ha);
                    return .{ .ref = &ha.cells[0] };
                },
                .alloc_array => |aa| {
                    const count: usize = @intCast((try self.evalExpr(aa.count, env)).int);
                    const ha = try self.alloc.create(HeapArray);
                    ha.* = .{ .cells = try self.alloc.alloc(HeapCell, count), .alloc = self.alloc };
                    for (ha.cells) |*cell| {
                        cell.* = .{ .value = switch (aa.elem_ty) {
                            .int => .{ .int = 0 },
                            .bool_ => .{ .bool_ = false },
                            .str => .{ .str = "" },
                            else => .void_,
                        } };
                    }
                    try self.heap_arrays.append(self.alloc, ha);
                    return .{ .ref = &ha.cells[0] };
                },
                .load => |ptr_reg| {
                    const cell = switch (env[ptr_reg]) {
                        .ref => |r| r,
                        else => return error.NotAPointer,
                    };
                    return cell.value;
                },
                .get_field_ref => |gfr| {
                    const cell = switch (env[gfr.ptr]) {
                        .ref => |r| r,
                        else => return error.NotAPointer,
                    };
                    const hs: *HeapStruct = @ptrFromInt(@as(usize, @intCast(cell.value.int)));
                    const field_cell = hs.fields.getPtr(gfr.field) orelse return error.NoSuchField;
                    return .{ .ref = field_cell };
                },
                .get_index_ref => |gir| {
                    const base_cell = switch (env[gir.arr]) {
                        .ref => |r| r,
                        else => return error.NotAPointer,
                    };
                    const idx: usize = @intCast((try self.evalExpr(gir.idx, env)).int);
                    const ha = blk: {
                        for (self.heap_arrays.items) |ha| {
                            if (ha.cells.len > 0 and &ha.cells[0] == base_cell) break :blk ha;
                        }
                        return error.InvalidArrayPointer;
                    };
                    if (idx >= ha.cells.len) return error.IndexOutOfBounds;
                    return .{ .ref = &ha.cells[idx] };
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
                    var args_buf: [32]Value = undefined;
                    const argc = s.args.items.len;
                    if (argc > 32) return error.TooManyArguments;
                    for (s.args.items, 0..) |a, i|
                        args_buf[i] = try self.evalExpr(a, env);
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
                .free => |ptr_reg| {
                    switch (env[ptr_reg]) {
                        .ptr => |p| {
                            self.alloc.free(p);
                            env[ptr_reg] = .void_;
                        },
                        .ref => |r| {
                            for (self.heap_arrays.items, 0..) |ha, i| {
                                if (ha.cells.len > 0 and &ha.cells[0] == r) {
                                    ha.deinit();
                                    self.alloc.destroy(ha);
                                    self.heap_arrays.items[i] = self.heap_arrays.items[self.heap_arrays.items.len - 1];
                                    self.heap_arrays.items.len -= 1;
                                    env[ptr_reg] = .void_;
                                    return .void_;
                                }
                            }
                            return error.InvalidFree;
                        },
                        else => return error.InvalidFree,
                    }
                    return .void_;
                },
                .arena_create => {
                    const arena = try self.alloc.create(BearArena);
                    arena.* = BearArena.init(self.alloc);
                    for (self.arenas.items, 0..) |slot, i| {
                        if (slot == null) {
                            self.arenas.items[i] = arena;
                            return .{ .int = @intCast(i) };
                        }
                    }
                    try self.arenas.append(self.alloc, arena);
                    return .{ .int = @intCast(self.arenas.items.len - 1) };
                },
                .arena_alloc => |aa| {
                    const arena_id: usize = @intCast(env[aa.arena].int);
                    if (arena_id >= self.arenas.items.len) return error.InvalidArena;
                    const arena = self.arenas.items[arena_id] orelse return error.InvalidArena;
                    const n: usize = @intCast((try self.evalExpr(aa.size, env)).int);
                    const buf = try arena.allocator().alloc(u8, n);
                    @memset(buf, 0);
                    return .{ .arena_ptr = buf };
                },
                .phi => return error.PhiWithNoPredecessor,
                .float_lit => |f| return .{ .float_ = f },
                .cast => |c| {
                    const v = try self.evalExpr(c.expr, env);
                    return switch (c.ty) {
                        .int => switch (v) {
                            .float_ => |f| .{ .int = @intFromFloat(f) },
                            .double_ => |f| .{ .int = @intFromFloat(f) },
                            .int => v,
                            else => return error.InvalidCast,
                        },
                        .float_ => switch (v) {
                            .int => |n| .{ .float_ = @floatFromInt(n) },
                            .float_ => v,
                            .double_ => |f| .{ .float_ = @floatCast(f) },
                            else => return error.InvalidCast,
                        },
                        .double_ => switch (v) {
                            .int => |n| .{ .double_ = @floatFromInt(n) },
                            .float_ => |f| .{ .double_ = @floatCast(f) },
                            .double_ => v,
                            else => return error.InvalidCast,
                        },
                        else => return error.InvalidCast,
                    };
                },
            }
        }
    }

    /// Fast path for expressions that are almost always .reg or .int literals.
    /// Returns the raw i64 directly, skipping Value boxing.
    inline fn evalExprFast(self: *Vm, expr: *const lexer.Expr, env: []Value) anyerror!i64 {
        return switch (expr.*) {
            .reg => |r| env[r].int,
            .int => |n| n,
            .const_ => |inner| switch (inner.*) {
                .int => |n| n,
                .reg => |r| env[r].int,
                else => (try self.evalExpr(expr, env)).int,
            },
            else => (try self.evalExpr(expr, env)).int,
        };
    }

    fn printValue(_: *Vm, val: Value) void {
        var tmp: [64]u8 = undefined;
        switch (val) {
            .int => |n| bear_io.writeStdout(std.fmt.bufPrint(&tmp, "{d}\n", .{n}) catch return),
            .float_ => |f| bear_io.writeStdout(std.fmt.bufPrint(&tmp, "{d}\n", .{f}) catch return),
            .double_ => |f| bear_io.writeStdout(std.fmt.bufPrint(&tmp, "{d}\n", .{f}) catch return),
            .str => |s| {
                bear_io.writeStdout(s);
                bear_io.writeStdout("\n");
            },
            .bool_ => |b| bear_io.writeStdout(if (b) "true\n" else "false\n"),
            .ptr => bear_io.writeStdout("<ptr>\n"),
            .arena_ptr => bear_io.writeStdout("<arena_ptr>\n"),
            .ref => bear_io.writeStdout("<ref>\n"),
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
        const target = self.call_cache.get(name) orelse return error.UndefinedFunction;
        return switch (target) {
            .builtin => |tag| self.execBuiltin(tag, args_buf[0..argc]),
            .user => |idx| self.callFuncByIdx(idx, args_buf[0..argc]),
        };
    }

    pub fn callFuncWithValues(self: *Vm, name: []const u8, args: []Value) anyerror!Value {
        const target = self.call_cache.get(name) orelse return error.UndefinedFunction;
        return switch (target) {
            .builtin => |tag| self.execBuiltin(tag, args),
            .user => |idx| self.callFuncByIdx(idx, args),
        };
    }

    /// Call a user function by its pre-resolved index. Avoids hash lookup on hot paths.
    fn callFuncByIdx(self: *Vm, idx: u32, args: []Value) anyerror!Value {
        const func = &self.program.functions.items[idx];

        var stack_env: [64]Value = undefined;
        const new_env: []Value = if (func.n_regs <= 64) blk: {
            break :blk stack_env[0..func.n_regs];
        } else blk: {
            const e = try self.alloc.alloc(Value, func.n_regs);
            break :blk e;
        };
        defer if (func.n_regs > 64) {
            for (new_env) |*v| v.deinit(self.alloc);
            self.alloc.free(new_env);
        };

        for (func.params.items, 0..) |param, i|
            new_env[param.idx] = args[i];

        return (try self.execBody(func.body.items, new_env, idx)) orelse .void_;
    }

    fn execBuiltin(self: *Vm, tag: BuiltinTag, args: []Value) anyerror!Value {
        return switch (tag) {
            .puts => blk: {
                for (args) |a| self.printValue(a);
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
                    .arena_ptr => |p| p,
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
            .flush => blk: {
                bear_io.flushStdout();
                break :blk .void_;
            },
            .putf => blk: {
                for (args) |a| self.printValue(a);
                break :blk .void_;
            },
        };
    }

    pub fn execBody(self: *Vm, stmts: []const lexer.Stmt, env: []Value, func_idx: u32) anyerror!?Value {
        const jump_table = self.jump_tables[func_idx];
        const br_table = self.br_tables[func_idx];
        const label_map = &self.label_maps[func_idx];
        const call_table = self.call_tables[func_idx];
        return self.execBodyWithTables(stmts, env, label_map, jump_table, br_table, call_table);
    }

    fn execBodyWithTables(self: *Vm, stmts: []const lexer.Stmt, env: []Value, label_map: *const LabelMap, jump_table: []const i32, br_table: []const BrEntry, call_table: []const ?CallTarget) anyerror!?Value {
        var pc: usize = 0;
        var prev_label: ?[]const u8 = null;
        var cur_label: ?[]const u8 = null;
        const len = stmts.len;
        while (pc < len) {
            switch (stmts[pc]) {
                .assign => |a| {
                    if (call_table[pc]) |target| {
                        const c = a.expr.call;
                        var args_buf: [32]Value = undefined;
                        const argc = c.args.items.len;
                        for (c.args.items, 0..) |arg, i|
                            args_buf[i] = try self.evalExpr(arg, env);
                        env[a.reg] = switch (target) {
                            .builtin => |tag| try self.execBuiltin(tag, args_buf[0..argc]),
                            .user => |idx| try self.callFuncByIdx(idx, args_buf[0..argc]),
                        };
                    } else {
                        env[a.reg] = try self.evalExprWithPrev(a.expr, env, prev_label);
                    }
                    pc += 1;
                },
                .set_field => |sf| {
                    const val = try self.evalExpr(sf.expr, env);
                    try env[sf.reg].struct_.fields.put(sf.field, val);
                    pc += 1;
                },
                .free => |ptr_reg| {
                    switch (env[ptr_reg]) {
                        .ptr => |p| {
                            self.alloc.free(p);
                            env[ptr_reg] = .void_;
                        },
                        .ref => |r| {
                            for (self.heap_arrays.items, 0..) |ha, i| {
                                if (ha.cells.len > 0 and &ha.cells[0] == r) {
                                    ha.deinit();
                                    self.alloc.destroy(ha);
                                    self.heap_arrays.items[i] = self.heap_arrays.items[self.heap_arrays.items.len - 1];
                                    self.heap_arrays.items.len -= 1;
                                    env[ptr_reg] = .void_;
                                    break;
                                }
                            }
                        },
                        else => return error.InvalidFree,
                    }
                    pc += 1;
                },
                .arena_destroy => |arena_reg| {
                    const arena_id: usize = @intCast(env[arena_reg].int);
                    if (arena_id < self.arenas.items.len) {
                        if (self.arenas.items[arena_id]) |arena| {
                            arena.deinit();
                            self.alloc.destroy(arena);
                            self.arenas.items[arena_id] = null;
                        }
                    }
                    env[arena_reg] = .void_;
                    pc += 1;
                },
                .store => |s| {
                    const cell = switch (env[s.ptr]) {
                        .ref => |r| r,
                        else => return error.NotAPointer,
                    };
                    const val = try self.evalExpr(s.expr, env);
                    const is_struct_sentinel = blk: {
                        for (self.heap_arrays.items) |ha| {
                            if (ha.cells.len == 1 and &ha.cells[0] == cell) {
                                const hs: *HeapStruct = @ptrFromInt(@as(usize, @intCast(cell.value.int)));
                                switch (val) {
                                    .struct_ => |sv| {
                                        var it = sv.fields.iterator();
                                        while (it.next()) |entry| {
                                            if (hs.fields.getPtr(entry.key_ptr.*)) |fc| {
                                                fc.value = entry.value_ptr.*;
                                            } else {
                                                try hs.fields.put(entry.key_ptr.*, .{ .value = entry.value_ptr.* });
                                            }
                                        }
                                    },
                                    else => return error.TypeMismatch,
                                }
                                break :blk true;
                            }
                        }
                        break :blk false;
                    };
                    if (!is_struct_sentinel) {
                        cell.value = val;
                    }
                    pc += 1;
                },
                .call => |c| {
                    if (call_table[pc]) |target| {
                        var args_buf: [32]Value = undefined;
                        const argc = c.args.items.len;
                        for (c.args.items, 0..) |arg, i|
                            args_buf[i] = try self.evalExpr(arg, env);
                        _ = switch (target) {
                            .builtin => |tag| try self.execBuiltin(tag, args_buf[0..argc]),
                            .user => |idx| try self.callFuncByIdx(idx, args_buf[0..argc]),
                        };
                    } else {
                        _ = try self.callFunc(c.name, c.args.items, env);
                    }
                    pc += 1;
                },
                .ret => |e| return try self.evalExpr(e, env),
                .while_ => |*w| {
                    var body_lm = LabelMap{};
                    defer body_lm.deinit(self.alloc);
                    try buildLabelMap(&body_lm, w.body.items, self.alloc);

                    const wlen = w.body.items.len;
                    const wjt = try self.alloc.alloc(i32, wlen);
                    defer self.alloc.free(wjt);
                    @memset(wjt, -1);
                    const wbt = try self.alloc.alloc(BrEntry, wlen);
                    defer self.alloc.free(wbt);
                    @memset(wbt, .{ -1, -1 });
                    const wct = try self.alloc.alloc(?CallTarget, wlen);
                    defer self.alloc.free(wct);
                    @memset(wct, null);
                    for (w.body.items, 0..) |*ws, wsi| {
                        switch (ws.*) {
                            .jmp => |t| { wjt[wsi] = @intCast(body_lm.get(t) orelse continue); },
                            .br_if => |br2| {
                                const t2: i32 = @intCast(body_lm.get(br2.true_label) orelse continue);
                                const f3: i32 = @intCast(body_lm.get(br2.false_label) orelse continue);
                                wbt[wsi] = .{ t2, f3 };
                            },
                            .call => |wc| wct[wsi] = self.call_cache.get(wc.name),
                            .assign => |wa| if (wa.expr.* == .call) {
                                wct[wsi] = self.call_cache.get(wa.expr.call.name);
                            },
                            else => {},
                        }
                    }

                    const body = w.body.items;
                    const cond = w.cond;

                    while (true) {
                        const keep = switch (try self.evalExpr(cond, env)) {
                            .bool_ => |b| b,
                            .int => |n| n != 0,
                            else => return error.TypeMismatch,
                        };
                        if (!keep) break;

                        if (try self.execBodyWithTables(body, env, &body_lm, wjt, wbt, wct)) |v| return v;
                    }
                    pc += 1;
                },
                .label => |name| {
                    cur_label = name;
                    pc += 1;
                },
                .jmp => |target| {
                    prev_label = cur_label;
                    const cached = jump_table[pc];
                    pc = if (cached >= 0) @intCast(cached) else label_map.get(target) orelse return error.UndefinedLabel;
                },
                .br_if => |br| {
                    const taken = switch (env[br.cond]) {
                        .bool_ => |b| b,
                        .int => |n| n != 0,
                        else => return error.TypeMismatch,
                    };
                    prev_label = cur_label;
                    const entry = br_table[pc];
                    if (taken) {
                        pc = if (entry[0] >= 0) @intCast(entry[0]) else label_map.get(br.true_label) orelse return error.UndefinedLabel;
                    } else {
                        pc = if (entry[1] >= 0) @intCast(entry[1]) else label_map.get(br.false_label) orelse return error.UndefinedLabel;
                    }
                },
            }
        }
        return null;
    }
};

/// Build a label->index map for a flat statement list.
fn buildLabelMap(lm: *LabelMap, stmts: []const lexer.Stmt, alloc: std.mem.Allocator) !void {
    for (stmts, 0..) |*s, i| {
        if (s.* == .label) try lm.put(alloc, s.label, i);
    }
}
