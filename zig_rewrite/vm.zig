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
        try self.tasks.append(self.alloc, .{ .thread = undefined, .state = .running, .result = .void_, .err = null });
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
    const main_idx = vm.func_index.get("main") orelse return error.NoMainFunction;
    _ = try vm.callFuncByIdx(main_idx, &.{});
}

pub const Value = union(enum) {
    int: i64,
    float_: f64,
    double_: f64,
    str: []const u8,
    bool_: bool,
    ptr: []u8,
    arena_ptr: []u8,
    ref: *HeapCell,
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

    pub inline fn asInt(self: Value) i64 {
        return self.int;
    }

    pub inline fn asBool(self: Value) bool {
        return switch (self) {
            .bool_ => |b| b,
            .int => |n| n != 0,
            else => unreachable,
        };
    }

    pub inline fn isInt(self: Value) bool {
        return self == .int;
    }
};

pub const HeapCell = struct { value: Value };

pub const HeapStruct = struct {
    name: []const u8,
    fields: std.StringArrayHashMap(HeapCell),

    pub fn deinit(self: *HeapStruct, alloc: std.mem.Allocator) void {
        var it = self.fields.iterator();
        while (it.next()) |entry| entry.value_ptr.value.deinit(alloc);
        self.fields.deinit();
    }
};

pub const HeapArray = struct {
    cells: []HeapCell,
    alloc: std.mem.Allocator,
    pub fn deinit(self: *HeapArray) void {
        for (self.cells) |*c| c.value.deinit(self.alloc);
        self.alloc.free(self.cells);
    }
};

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

const StructVal = struct { name: []const u8, fields: std.StringArrayHashMap(Value) };
const BuiltinTag = enum(u8) { puts, open, read, write, close, flush, putf };
const builtin_map = std.StaticStringMap(BuiltinTag).initComptime(.{
    .{ "puts", .puts },   .{ "open", .open },   .{ "read", .read },
    .{ "write", .write }, .{ "close", .close }, .{ "flush", .flush },
    .{ "putf", .putf },
});

const FileHandle = union(enum) { read: std.fs.File, write: std.fs.File };
const CallTarget = union(enum) { builtin: BuiltinTag, user: u32 };

pub const Op = enum(u8) {
    load_int,
    load_str,
    load_float,
    move,
    load_named,
    add,
    sub,
    mul,
    div,
    lt,
    gt,
    le,
    ge,
    eq_val,
    jmp,
    br_if,
    ret,
    ret_void,
    set_label,
    phi,
    call_user,
    call_builtin,
    call_user_void,
    call_builtin_void,
    alloc_bytes,
    alloc_type,
    alloc_array,
    load_ref,
    store_ref,
    get_field_ref,
    get_index_ref,
    free_reg,
    arena_create,
    arena_alloc,
    arena_destroy,
    struct_lit,
    set_field,
    get_field,
    spawn,
    sync_task,
    cast,
};

pub const Instr = packed struct {
    op: Op,
    flag: u8,
    dst: u16,
    a: u16,
    b: u16,
};

pub const ArgRange = struct { start: u32, len: u16 };
pub const PhiEntry = struct { pred_label_idx: u16, src_reg: u16 };

pub const CompiledFn = struct {
    /// The register count.
    n_regs: u16,

    /// The instruction list.
    code: []Instr,

    /// The int pool for VM storage.
    int_pool: []i64,

    /// The float pool for VM storage.
    float_pool: []f64,

    /// The string pool for VM storage.
    str_pool: [][]const u8,

    /// The argument registers.
    arg_regs: []u16,

    /// The argument ranges.
    arg_ranges: []ArgRange,

    /// The phi tables.
    phi_tables: [][]PhiEntry,

    /// True when this function never allocates heap Values (ptr/ref/struct/arena).
    /// Lets callFuncByIdx skip the deinit loop entirely.
    pure_int: bool,

    /// Number of parameter registers that must be pre-zeroed before execution.
    n_param_regs: u16,

    pub fn deinit(self: *CompiledFn, alloc: std.mem.Allocator) void {
        alloc.free(self.code);
        alloc.free(self.int_pool);
        alloc.free(self.float_pool);
        alloc.free(self.str_pool);
        alloc.free(self.arg_regs);
        alloc.free(self.arg_ranges);
        for (self.phi_tables) |pt| alloc.free(pt);
        alloc.free(self.phi_tables);
    }
};

const CALL_STACK_SLOTS: usize = 1 << 20;

const CallStack = struct {
    buf: []Value,
    top: usize,
    fn init(alloc: std.mem.Allocator) !CallStack {
        return .{ .buf = try alloc.alloc(Value, CALL_STACK_SLOTS), .top = 0 };
    }
    fn deinit(self: *CallStack, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
    }
    inline fn push(self: *CallStack, n: usize) ![]Value {
        const s = self.top;
        const e = s + n;
        if (e > self.buf.len) return error.CallStackOverflow;
        self.top = e;
        return self.buf[s..e];
    }
    inline fn pop(self: *CallStack, n: usize) void {
        self.top -= n;
    }
};

const INT_STACK_SLOTS: usize = 1 << 21;

const IntStack = struct {
    buf: []i64,
    top: usize,

    fn init(alloc: std.mem.Allocator) !IntStack {
        return .{ .buf = try alloc.alloc(i64, INT_STACK_SLOTS), .top = 0 };
    }

    fn deinit(self: *IntStack, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
    }

    inline fn push(self: *IntStack, n: usize) ![]i64 {
        const s = self.top;
        const e = s + n;
        if (e > self.buf.len) return error.IntStackOverflow;
        self.top = e;
        return self.buf[s..e];
    }

    inline fn pop(self: *IntStack, n: usize) void {
        self.top -= n;
    }
};

const Compiler = struct {
    alloc: std.mem.Allocator,
    code: std.ArrayListUnmanaged(Instr),
    int_pool: std.ArrayListUnmanaged(i64),
    float_pool: std.ArrayListUnmanaged(f64),
    str_pool: std.ArrayListUnmanaged([]const u8),
    arg_regs: std.ArrayListUnmanaged(u16),
    arg_ranges: std.ArrayListUnmanaged(ArgRange),
    phi_tables: std.ArrayListUnmanaged([]PhiEntry),
    label_pcs: std.StringHashMapUnmanaged(u32),
    label_idx: std.StringHashMapUnmanaged(u16),
    patches: std.ArrayListUnmanaged(Patch),
    call_cache: *const std.StringHashMapUnmanaged(CallTarget),
    max_reg: u16,

    const Patch = struct { pc: u32, field: enum { a, b }, label: []const u8 };

    fn init(alloc: std.mem.Allocator, cc: *const std.StringHashMapUnmanaged(CallTarget)) Compiler {
        return .{
            .alloc = alloc,
            .code = .empty,
            .int_pool = .empty,
            .float_pool = .empty,
            .str_pool = .empty,
            .arg_regs = .empty,
            .arg_ranges = .empty,
            .phi_tables = .empty,
            .label_pcs = .{},
            .label_idx = .{},
            .patches = .empty,
            .call_cache = cc,
            .max_reg = 0,
        };
    }

    fn deinit(self: *Compiler) void {
        self.code.deinit(self.alloc);
        self.int_pool.deinit(self.alloc);
        self.float_pool.deinit(self.alloc);
        self.str_pool.deinit(self.alloc);
        self.arg_regs.deinit(self.alloc);
        self.arg_ranges.deinit(self.alloc);
        for (self.phi_tables.items) |pt| self.alloc.free(pt);
        self.phi_tables.deinit(self.alloc);
        self.label_pcs.deinit(self.alloc);
        self.label_idx.deinit(self.alloc);
        self.patches.deinit(self.alloc);
    }

    fn intIdx(self: *Compiler, n: i64) !u16 {
        for (self.int_pool.items, 0..) |v, i| if (v == n) return @intCast(i);
        const idx: u16 = @intCast(self.int_pool.items.len);
        try self.int_pool.append(self.alloc, n);
        return idx;
    }

    fn floatIdx(self: *Compiler, f: f64) !u16 {
        const idx: u16 = @intCast(self.float_pool.items.len);
        try self.float_pool.append(self.alloc, f);
        return idx;
    }

    fn strIdx(self: *Compiler, s: []const u8) !u16 {
        for (self.str_pool.items, 0..) |v, i| if (std.mem.eql(u8, v, s)) return @intCast(i);
        const idx: u16 = @intCast(self.str_pool.items.len);
        try self.str_pool.append(self.alloc, s);
        return idx;
    }

    fn emit(self: *Compiler, ins: Instr) !u32 {
        const pc: u32 = @intCast(self.code.items.len);
        try self.code.append(self.alloc, ins);
        if (ins.dst > self.max_reg) self.max_reg = ins.dst;
        return pc;
    }

    fn compileExpr(self: *Compiler, expr: *const lexer.Expr, scratch: u16) anyerror!u16 {
        switch (expr.*) {
            .reg => |r| return r,
            .const_ => |inner| return self.compileExpr(inner, scratch),
            .int => |n| {
                const idx = try self.intIdx(n);
                _ = try self.emit(.{ .op = .load_int, .flag = 0, .dst = scratch, .a = idx, .b = 0 });
                return scratch;
            },
            .float_lit => |f| {
                const idx = try self.floatIdx(f);
                _ = try self.emit(.{ .op = .load_float, .flag = 0, .dst = scratch, .a = idx, .b = 0 });
                return scratch;
            },
            .str => |s| {
                const idx = try self.strIdx(s);
                _ = try self.emit(.{ .op = .load_str, .flag = 0, .dst = scratch, .a = idx, .b = 0 });
                return scratch;
            },
            .named => |name| {
                const idx = try self.strIdx(name);
                _ = try self.emit(.{ .op = .load_named, .flag = 0, .dst = scratch, .a = idx, .b = 0 });
                return scratch;
            },
            .add, .sub, .mul, .div, .lt, .gt, .le, .ge => return self.compileBinOp(expr, scratch),
            .eq => |op| {
                const ra = try self.compileExpr(op.a, scratch);
                const rb = try self.compileExpr(op.b, if (ra == scratch) scratch +% 1 else scratch);
                _ = try self.emit(.{ .op = .eq_val, .flag = 0, .dst = scratch, .a = ra, .b = rb });
                return scratch;
            },
            .call => |c| {
                const ar_idx = try self.buildArgRange(c.args.items, scratch);
                const target = self.call_cache.get(c.name) orelse return error.UndefinedFunction;
                switch (target) {
                    .builtin => |tag| _ = try self.emit(.{ .op = .call_builtin, .flag = 0, .dst = scratch, .a = @intFromEnum(tag), .b = ar_idx }),
                    .user => |idx| _ = try self.emit(.{ .op = .call_user, .flag = 0, .dst = scratch, .a = @intCast(idx), .b = ar_idx }),
                }
                return scratch;
            },
            .field => |f| {
                const idx = try self.strIdx(f.field);
                _ = try self.emit(.{ .op = .get_field, .flag = 0, .dst = scratch, .a = f.reg, .b = idx });
                return scratch;
            },
            .alloc => |size_expr| {
                const ra = try self.compileExpr(size_expr, scratch);
                _ = try self.emit(.{ .op = .alloc_bytes, .flag = 0, .dst = scratch, .a = ra, .b = 0 });
                return scratch;
            },
            .alloc_type => |name| {
                const idx = try self.strIdx(name);
                _ = try self.emit(.{ .op = .alloc_type, .flag = 0, .dst = scratch, .a = idx, .b = 0 });
                return scratch;
            },
            .alloc_array => |aa| {
                const ra = try self.compileExpr(aa.count, scratch);
                _ = try self.emit(.{ .op = .alloc_array, .flag = @intFromEnum(aa.elem_ty), .dst = scratch, .a = ra, .b = 0 });
                return scratch;
            },
            .load => |ptr_reg| {
                _ = try self.emit(.{ .op = .load_ref, .flag = 0, .dst = scratch, .a = ptr_reg, .b = 0 });
                return scratch;
            },
            .get_field_ref => |gfr| {
                const idx = try self.strIdx(gfr.field);
                _ = try self.emit(.{ .op = .get_field_ref, .flag = 0, .dst = scratch, .a = gfr.ptr, .b = idx });
                return scratch;
            },
            .get_index_ref => |gir| {
                const rb = try self.compileExpr(gir.idx, scratch +% 1);
                _ = try self.emit(.{ .op = .get_index_ref, .flag = 0, .dst = scratch, .a = gir.arr, .b = rb });
                return scratch;
            },
            .struct_lit => |sl| {
                const name_idx = try self.strIdx(sl.name);
                const ar_start: u32 = @intCast(self.arg_regs.items.len);
                for (sl.fields.items, 0..) |fi, i| {
                    const fn_idx = try self.strIdx(fi.name);
                    const r = try self.compileExpr(fi.expr, scratch +% 1 +% @as(u16, @intCast(i)));
                    try self.arg_regs.append(self.alloc, fn_idx);
                    try self.arg_regs.append(self.alloc, r);
                }
                const ar_idx: u16 = @intCast(self.arg_ranges.items.len);
                try self.arg_ranges.append(self.alloc, .{ .start = ar_start, .len = @intCast(sl.fields.items.len) });
                _ = try self.emit(.{ .op = .struct_lit, .flag = 0, .dst = scratch, .a = name_idx, .b = ar_idx });
                return scratch;
            },
            .arena_create => {
                _ = try self.emit(.{ .op = .arena_create, .flag = 0, .dst = scratch, .a = 0, .b = 0 });
                return scratch;
            },
            .arena_alloc => |aa| {
                const rs = try self.compileExpr(aa.size, scratch +% 1);
                _ = try self.emit(.{ .op = .arena_alloc, .flag = 0, .dst = scratch, .a = aa.arena, .b = rs });
                return scratch;
            },
            .phi => |arms| {
                var entries = try self.alloc.alloc(PhiEntry, arms.items.len);
                for (arms.items, 0..) |arm, i| {
                    const pred_idx = self.label_idx.get(arm.label) orelse 0;
                    entries[i] = .{ .pred_label_idx = @intCast(pred_idx), .src_reg = arm.reg };
                }
                const pt_idx: u16 = @intCast(self.phi_tables.items.len);
                try self.phi_tables.append(self.alloc, entries);
                _ = try self.emit(.{ .op = .phi, .flag = 0, .dst = scratch, .a = pt_idx, .b = 0 });
                return scratch;
            },
            .spawn => |s| {
                const ar_idx = try self.buildArgRange(s.args.items, scratch);
                const name_idx = try self.strIdx(s.name);
                _ = try self.emit(.{ .op = .spawn, .flag = 0, .dst = scratch, .a = name_idx, .b = ar_idx });
                return scratch;
            },
            .sync => |reg| {
                _ = try self.emit(.{ .op = .sync_task, .flag = 0, .dst = scratch, .a = reg, .b = 0 });
                return scratch;
            },
            .free => |ptr_reg| {
                _ = try self.emit(.{ .op = .free_reg, .flag = 0, .dst = ptr_reg, .a = 0, .b = 0 });
                return scratch;
            },
            .cast => |c| {
                const ra = try self.compileExpr(c.expr, scratch);
                _ = try self.emit(.{ .op = .cast, .flag = @intFromEnum(c.ty), .dst = scratch, .a = ra, .b = 0 });
                return scratch;
            },
        }
    }

    fn compileBinOp(self: *Compiler, expr: *const lexer.Expr, dst: u16) !u16 {
        const op_tag: Op, const bop: lexer.BinOp = switch (expr.*) {
            .add => |b| .{ .add, b },
            .sub => |b| .{ .sub, b },
            .mul => |b| .{ .mul, b },
            .div => |b| .{ .div, b },
            .lt => |b| .{ .lt, b },
            .gt => |b| .{ .gt, b },
            .le => |b| .{ .le, b },
            .ge => |b| .{ .ge, b },
            else => unreachable,
        };

        const ae = if (bop.a.* == .const_) bop.a.const_ else bop.a;
        const be = if (bop.b.* == .const_) bop.b.const_ else bop.b;

        var flag: u8 = 0;
        var a_val: u16 = undefined;
        var b_val: u16 = undefined;

        if (ae.* == .int) {
            a_val = try self.intIdx(ae.int);
            flag |= 0x01;
        } else if (ae.* == .reg) {
            a_val = ae.reg;
        } else {
            a_val = try self.compileExpr(bop.a, dst);
        }

        if (be.* == .int) {
            b_val = try self.intIdx(be.int);
            flag |= 0x02;
        } else if (be.* == .reg) {
            b_val = be.reg;
        } else {
            const scratch_b: u16 = if ((flag & 0x01 == 0) and a_val == dst) dst +% 1 else dst;
            b_val = try self.compileExpr(bop.b, scratch_b);
        }

        _ = try self.emit(.{ .op = op_tag, .flag = flag, .dst = dst, .a = a_val, .b = b_val });
        return dst;
    }

    fn buildArgRange(self: *Compiler, arg_exprs: []*lexer.Expr, base_scratch: u16) !u16 {
        const ar_start: u32 = @intCast(self.arg_regs.items.len);
        for (arg_exprs, 0..) |ae, i| {
            const r = try self.compileExpr(ae, base_scratch +% @as(u16, @intCast(i)));
            try self.arg_regs.append(self.alloc, r);
        }
        const ar_idx: u16 = @intCast(self.arg_ranges.items.len);
        try self.arg_ranges.append(self.alloc, .{ .start = ar_start, .len = @intCast(arg_exprs.len) });
        return ar_idx;
    }

    fn compileStmts(self: *Compiler, stmts: []const lexer.Stmt) !void {
        for (stmts) |*s| try self.compileStmt(s);
    }

    fn compileStmt(self: *Compiler, s: *const lexer.Stmt) anyerror!void {
        switch (s.*) {
            .label => |name| {
                const pc: u32 = @intCast(self.code.items.len);
                try self.label_pcs.put(self.alloc, name, pc);
                const idx = self.label_idx.get(name) orelse 0;
                _ = try self.emit(.{ .op = .set_label, .flag = 0, .dst = idx, .a = 0, .b = 0 });
            },

            .assign => |a| {
                const r = try self.compileExpr(a.expr, a.reg);
                if (r != a.reg)
                    _ = try self.emit(.{ .op = .move, .flag = 0, .dst = a.reg, .a = r, .b = 0 });
            },

            .set_field => |sf| {
                const field_idx = try self.strIdx(sf.field);
                const r = try self.compileExpr(sf.expr, sf.reg +% 1);
                _ = try self.emit(.{ .op = .set_field, .flag = 0, .dst = sf.reg, .a = field_idx, .b = r });
            },

            .store => |st| {
                const r = try self.compileExpr(st.expr, st.ptr +% 1);
                _ = try self.emit(.{ .op = .store_ref, .flag = 0, .dst = st.ptr, .a = r, .b = 0 });
            },

            .free => |ptr_reg| {
                _ = try self.emit(.{ .op = .free_reg, .flag = 0, .dst = ptr_reg, .a = 0, .b = 0 });
            },

            .arena_destroy => |arena_reg| {
                _ = try self.emit(.{ .op = .arena_destroy, .flag = 0, .dst = arena_reg, .a = 0, .b = 0 });
            },

            .call => |c| {
                const ar_idx = try self.buildArgRange(c.args.items, self.max_reg +% 1);
                const target = self.call_cache.get(c.name) orelse return error.UndefinedFunction;
                switch (target) {
                    .builtin => |tag| _ = try self.emit(.{ .op = .call_builtin_void, .flag = 0, .dst = 0, .a = @intFromEnum(tag), .b = ar_idx }),
                    .user => |idx| _ = try self.emit(.{ .op = .call_user_void, .flag = 0, .dst = 0, .a = @intCast(idx), .b = ar_idx }),
                }
            },

            .ret => |e| {
                const r = try self.compileExpr(e, self.max_reg +% 1);
                _ = try self.emit(.{ .op = .ret, .flag = 0, .dst = r, .a = 0, .b = 0 });
            },

            .jmp => |target| {
                const patch_pc: u32 = @intCast(self.code.items.len);
                _ = try self.emit(.{ .op = .jmp, .flag = 0, .dst = 0, .a = 0, .b = 0 });
                try self.patches.append(self.alloc, .{ .pc = patch_pc, .field = .a, .label = target });
            },

            .br_if => |br| {
                const patch_pc: u32 = @intCast(self.code.items.len);
                _ = try self.emit(.{ .op = .br_if, .flag = 0, .dst = br.cond, .a = 0, .b = 0 });
                try self.patches.append(self.alloc, .{ .pc = patch_pc, .field = .a, .label = br.true_label });
                try self.patches.append(self.alloc, .{ .pc = patch_pc, .field = .b, .label = br.false_label });
            },

            .while_ => |*w| {
                const cond_pc: u32 = @intCast(self.code.items.len);
                const cond_scratch: u16 = self.max_reg +% 1;
                const cond_r = try self.compileExpr(w.cond, cond_scratch);
                const br_pc: u32 = @intCast(self.code.items.len);
                _ = try self.emit(.{ .op = .br_if, .flag = 0, .dst = cond_r, .a = 0, .b = 0 });
                try self.compileStmts(w.body.items);
                _ = try self.emit(.{ .op = .jmp, .flag = 0, .dst = 0, .a = @intCast(cond_pc), .b = 0 });
                const after_pc: u32 = @intCast(self.code.items.len);
                self.code.items[br_pc].a = @intCast(br_pc + 1);
                self.code.items[br_pc].b = @intCast(after_pc);
            },
        }
    }

    fn applyPatches(self: *Compiler) !void {
        for (self.patches.items) |p| {
            const tpc = self.label_pcs.get(p.label) orelse return error.UndefinedLabel;
            switch (p.field) {
                .a => self.code.items[p.pc].a = @intCast(tpc),
                .b => self.code.items[p.pc].b = @intCast(tpc),
            }
        }
    }

    fn finish(self: *Compiler, n_regs: u16, n_param_regs: u16) !CompiledFn {
        const actual_n_regs: u16 = @max(n_regs, if (self.code.items.len == 0) 0 else self.max_reg + 1);

        var pure_int = true;
        for (self.code.items) |ins| {
            switch (ins.op) {
                .alloc_bytes,
                .alloc_type,
                .alloc_array,
                .arena_create,
                .arena_alloc,
                .load_str,
                .load_named,
                .struct_lit,
                .load_ref,
                .store_ref,
                .get_field_ref,
                .get_index_ref,
                .get_field,
                .set_field,
                .free_reg,
                .arena_destroy,
                .spawn,
                .sync_task,
                .call_builtin,
                .call_builtin_void,
                .load_float,
                .cast,
                => {
                    pure_int = false;
                    break;
                },
                else => {},
            }
        }

        return .{
            .n_regs = actual_n_regs,
            .code = try self.code.toOwnedSlice(self.alloc),
            .int_pool = try self.int_pool.toOwnedSlice(self.alloc),
            .float_pool = try self.float_pool.toOwnedSlice(self.alloc),
            .str_pool = try self.str_pool.toOwnedSlice(self.alloc),
            .arg_regs = try self.arg_regs.toOwnedSlice(self.alloc),
            .arg_ranges = try self.arg_ranges.toOwnedSlice(self.alloc),
            .phi_tables = try self.phi_tables.toOwnedSlice(self.alloc),
            .pure_int = pure_int,
            .n_param_regs = n_param_regs,
        };
    }
};

fn compileFunction(
    func: *const lexer.Function,
    call_cache: *const std.StringHashMapUnmanaged(CallTarget),
    alloc: std.mem.Allocator,
) !CompiledFn {
    var c = Compiler.init(alloc, call_cache);
    defer c.deinit();

    var label_counter: u16 = 0;
    for (func.body.items) |*st| {
        if (st.* == .label) {
            try c.label_idx.put(alloc, st.label, label_counter);
            label_counter += 1;
        }
    }

    try c.compileStmts(func.body.items);

    if (c.code.items.len == 0 or
        (c.code.items[c.code.items.len - 1].op != .ret and
            c.code.items[c.code.items.len - 1].op != .ret_void))
    {
        _ = try c.emit(.{ .op = .ret_void, .flag = 0, .dst = 0, .a = 0, .b = 0 });
    }

    try c.applyPatches();

    const n_param_regs: u16 = @intCast(func.params.items.len);
    return c.finish(func.n_regs, n_param_regs);
}

/// Propagate purity: A call_user to a non-pure callee taints the caller.
fn propagatePurity(compiled: []CompiledFn) void {
    var changed = true;
    while (changed) {
        changed = false;
        for (compiled) |*cf| {
            if (!cf.pure_int) continue;
            for (cf.code) |ins| {
                if (ins.op == .call_user or ins.op == .call_user_void) {
                    if (!compiled[ins.a].pure_int) {
                        cf.pure_int = false;
                        changed = true;
                        break;
                    }
                }
            }
        }
    }
}

pub const Vm = struct {
    program: *const lexer.Program,
    func_index: std.StringHashMapUnmanaged(u32),
    call_cache: std.StringHashMapUnmanaged(CallTarget),
    compiled: []CompiledFn,
    files: std.ArrayListUnmanaged(?FileHandle),
    heap_structs: std.ArrayListUnmanaged(*HeapStruct),
    heap_arrays: std.ArrayListUnmanaged(*HeapArray),
    arenas: std.ArrayListUnmanaged(?*BearArena),
    alloc: std.mem.Allocator,
    tasks: ?*TaskTable,
    call_stack: CallStack,
    int_stack: IntStack,

    pub fn init(program: *const lexer.Program, alloc: std.mem.Allocator) !Vm {
        const n = program.functions.items.len;

        var func_index = std.StringHashMapUnmanaged(u32){};
        try func_index.ensureTotalCapacity(alloc, @intCast(n));
        for (program.functions.items, 0..) |*f, i|
            func_index.putAssumeCapacity(f.name, @intCast(i));

        var call_cache = std.StringHashMapUnmanaged(CallTarget){};
        try call_cache.ensureTotalCapacity(alloc, @intCast(n + builtin_map.keys().len));
        for (builtin_map.keys(), builtin_map.values()) |k, v|
            call_cache.putAssumeCapacity(k, .{ .builtin = v });
        for (program.functions.items, 0..) |*f, i|
            call_cache.putAssumeCapacity(f.name, .{ .user = @intCast(i) });

        const compiled = try alloc.alloc(CompiledFn, n);
        for (program.functions.items, 0..) |*f, i|
            compiled[i] = try compileFunction(f, &call_cache, alloc);

        propagatePurity(compiled);

        return .{
            .program = program,
            .func_index = func_index,
            .call_cache = call_cache,
            .compiled = compiled,
            .files = .empty,
            .heap_structs = .empty,
            .heap_arrays = .empty,
            .arenas = .empty,
            .alloc = alloc,
            .tasks = null,
            .call_stack = try CallStack.init(alloc),
            .int_stack = try IntStack.init(alloc),
        };
    }

    pub fn deinit(self: *Vm) void {
        self.func_index.deinit(self.alloc);
        self.call_cache.deinit(self.alloc);
        for (self.compiled) |*cf| cf.deinit(self.alloc);
        self.alloc.free(self.compiled);
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
        for (self.arenas.items) |maybe| {
            if (maybe) |a| {
                a.deinit();
                self.alloc.destroy(a);
            }
        }
        self.arenas.deinit(self.alloc);
        self.call_stack.deinit(self.alloc);
        self.int_stack.deinit(self.alloc);
    }

    pub fn findFunc(self: *Vm, name: []const u8) ?*const lexer.Function {
        const idx = self.func_index.get(name) orelse return null;
        return &self.program.functions.items[idx];
    }

    fn allocFile(self: *Vm, handle: FileHandle) !i64 {
        for (self.files.items, 0..) |slot, i|
            if (slot == null) {
                self.files.items[i] = handle;
                return @intCast(i);
            };
        try self.files.append(self.alloc, handle);
        return @intCast(self.files.items.len - 1);
    }

    pub fn callFuncWithValues(self: *Vm, name: []const u8, args: []Value) anyerror!Value {
        const target = self.call_cache.get(name) orelse return error.UndefinedFunction;
        return switch (target) {
            .builtin => |tag| self.execBuiltin(tag, args),
            .user => |idx| self.callFuncByIdx(idx, args),
        };
    }

    fn callFuncByIdxInt(self: *Vm, idx: u32, args_i64: []const i64) anyerror!Value {
        const cf = &self.compiled[idx];
        const func = &self.program.functions.items[idx];
        const n = cf.n_regs;

        const env = try self.int_stack.push(n);
        defer self.int_stack.pop(n);

        for (func.params.items, 0..) |param, i|
            env[param.idx] = args_i64[i];

        return self.execCompiledInt(cf, env);
    }

    pub fn callFuncByIdx(self: *Vm, idx: u32, args: []Value) anyerror!Value {
        const cf = &self.compiled[idx];

        if (cf.pure_int) {
            var args_i64: [32]i64 = undefined;
            for (args, 0..) |v, i| args_i64[i] = switch (v) {
                .int => |n| n,
                .bool_ => |b| if (b) 1 else 0,
                else => return error.TypeMismatch,
            };
            return try self.callFuncByIdxInt(idx, args_i64[0..args.len]);
        }

        const func = &self.program.functions.items[idx];
        const n = cf.n_regs;

        var used_slab = true;
        const env = self.call_stack.push(n) catch blk: {
            used_slab = false;
            break :blk try self.alloc.alloc(Value, n);
        };
        defer {
            for (env) |*v| v.deinit(self.alloc);
            if (used_slab) self.call_stack.pop(n) else self.alloc.free(env);
        }

        @memset(env, .void_);
        for (func.params.items, 0..) |param, i|
            env[param.idx] = args[i];

        return self.execCompiled(cf, env);
    }

    fn execCompiledInt(self: *Vm, cf: *const CompiledFn, env: []i64) anyerror!Value {
        const code = cf.code;
        const int_pool = cf.int_pool;
        const arg_regs = cf.arg_regs;
        const arg_ranges = cf.arg_ranges;
        const phi_tables = cf.phi_tables;

        var pc: usize = 0;
        var cur_label_idx: u16 = std.math.maxInt(u16);
        var prev_label_idx: u16 = std.math.maxInt(u16);
        var bool_regs: u64 = 0;

        while (true) {
            const ins = code[pc];
            switch (ins.op) {
                .load_int => {
                    env[ins.dst] = int_pool[ins.a];
                    if (ins.dst < 64) bool_regs &= ~(@as(u64, 1) << @intCast(ins.dst));
                    pc += 1;
                },
                .move => {
                    env[ins.dst] = env[ins.a];
                    if (ins.dst < 64 and ins.a < 64) {
                        const src_bit = (bool_regs >> @intCast(ins.a)) & 1;
                        bool_regs = (bool_regs & ~(@as(u64, 1) << @intCast(ins.dst))) |
                            (src_bit << @intCast(ins.dst));
                    } else if (ins.dst < 64) {
                        bool_regs &= ~(@as(u64, 1) << @intCast(ins.dst));
                    }
                    pc += 1;
                },
                .add => {
                    const a = if (ins.flag & 0x01 != 0) int_pool[ins.a] else env[ins.a];
                    const b = if (ins.flag & 0x02 != 0) int_pool[ins.b] else env[ins.b];
                    env[ins.dst] = a +% b;
                    if (ins.dst < 64) bool_regs &= ~(@as(u64, 1) << @intCast(ins.dst));
                    pc += 1;
                },
                .sub => {
                    const a = if (ins.flag & 0x01 != 0) int_pool[ins.a] else env[ins.a];
                    const b = if (ins.flag & 0x02 != 0) int_pool[ins.b] else env[ins.b];
                    env[ins.dst] = a -% b;
                    if (ins.dst < 64) bool_regs &= ~(@as(u64, 1) << @intCast(ins.dst));
                    pc += 1;
                },
                .mul => {
                    const a = if (ins.flag & 0x01 != 0) int_pool[ins.a] else env[ins.a];
                    const b = if (ins.flag & 0x02 != 0) int_pool[ins.b] else env[ins.b];
                    env[ins.dst] = a *% b;
                    if (ins.dst < 64) bool_regs &= ~(@as(u64, 1) << @intCast(ins.dst));
                    pc += 1;
                },
                .div => {
                    const a = if (ins.flag & 0x01 != 0) int_pool[ins.a] else env[ins.a];
                    const b = if (ins.flag & 0x02 != 0) int_pool[ins.b] else env[ins.b];
                    if (b == 0) return error.DivisionByZero;
                    env[ins.dst] = @divTrunc(a, b);
                    if (ins.dst < 64) bool_regs &= ~(@as(u64, 1) << @intCast(ins.dst));
                    pc += 1;
                },
                .lt => {
                    const a = if (ins.flag & 0x01 != 0) int_pool[ins.a] else env[ins.a];
                    const b = if (ins.flag & 0x02 != 0) int_pool[ins.b] else env[ins.b];
                    env[ins.dst] = if (a < b) 1 else 0;
                    if (ins.dst < 64) bool_regs |= (@as(u64, 1) << @intCast(ins.dst));
                    pc += 1;
                },
                .gt => {
                    const a = if (ins.flag & 0x01 != 0) int_pool[ins.a] else env[ins.a];
                    const b = if (ins.flag & 0x02 != 0) int_pool[ins.b] else env[ins.b];
                    env[ins.dst] = if (a > b) 1 else 0;
                    if (ins.dst < 64) bool_regs |= (@as(u64, 1) << @intCast(ins.dst));
                    pc += 1;
                },
                .le => {
                    const a = if (ins.flag & 0x01 != 0) int_pool[ins.a] else env[ins.a];
                    const b = if (ins.flag & 0x02 != 0) int_pool[ins.b] else env[ins.b];
                    env[ins.dst] = if (a <= b) 1 else 0;
                    if (ins.dst < 64) bool_regs |= (@as(u64, 1) << @intCast(ins.dst));
                    pc += 1;
                },
                .ge => {
                    const a = if (ins.flag & 0x01 != 0) int_pool[ins.a] else env[ins.a];
                    const b = if (ins.flag & 0x02 != 0) int_pool[ins.b] else env[ins.b];
                    env[ins.dst] = if (a >= b) 1 else 0;
                    if (ins.dst < 64) bool_regs |= (@as(u64, 1) << @intCast(ins.dst));
                    pc += 1;
                },
                .eq_val => {
                    env[ins.dst] = if (env[ins.a] == env[ins.b]) 1 else 0;
                    if (ins.dst < 64) bool_regs |= (@as(u64, 1) << @intCast(ins.dst));
                    pc += 1;
                },
                .set_label => {
                    cur_label_idx = ins.dst;
                    pc += 1;
                },
                .jmp => {
                    prev_label_idx = cur_label_idx;
                    pc = ins.a;
                },
                .br_if => {
                    prev_label_idx = cur_label_idx;
                    pc = if (env[ins.dst] != 0) ins.a else ins.b;
                },
                .ret => {
                    const raw = env[ins.dst];
                    const is_bool = ins.dst < 64 and (bool_regs >> @intCast(ins.dst)) & 1 != 0;
                    return if (is_bool) .{ .bool_ = raw != 0 } else .{ .int = raw };
                },
                .ret_void => return .void_,
                .phi => {
                    const entries = phi_tables[ins.a];
                    var found = false;
                    for (entries) |e| {
                        if (e.pred_label_idx == prev_label_idx) {
                            env[ins.dst] = env[e.src_reg];
                            // Propagate bool tag through phi.
                            if (ins.dst < 64 and e.src_reg < 64) {
                                const src_bit = (bool_regs >> @intCast(e.src_reg)) & 1;
                                bool_regs = (bool_regs & ~(@as(u64, 1) << @intCast(ins.dst))) |
                                    (src_bit << @intCast(ins.dst));
                            }
                            found = true;
                            break;
                        }
                    }
                    if (!found) return error.PhiNoMatchingArm;
                    pc += 1;
                },
                .call_user, .call_user_void => {
                    const ar = arg_ranges[ins.b];
                    var buf: [32]i64 = undefined;
                    for (0..ar.len) |i| buf[i] = env[arg_regs[ar.start + i]];
                    const result = try self.callFuncByIdxInt(ins.a, buf[0..ar.len]);
                    if (ins.op == .call_user) {
                        switch (result) {
                            .int => |n| {
                                env[ins.dst] = n;
                                if (ins.dst < 64) bool_regs &= ~(@as(u64, 1) << @intCast(ins.dst));
                            },
                            .bool_ => |b| {
                                env[ins.dst] = if (b) 1 else 0;
                                if (ins.dst < 64) bool_regs |= (@as(u64, 1) << @intCast(ins.dst));
                            },
                            .void_ => {
                                env[ins.dst] = 0;
                                if (ins.dst < 64) bool_regs &= ~(@as(u64, 1) << @intCast(ins.dst));
                            },
                            else => return error.NotPureInt,
                        }
                    }
                    pc += 1;
                },
                // Anything else shouldn't appear in a pure_int function.
                else => return error.NotPureInt,
            }
        }
    }

    fn execCompiled(self: *Vm, cf: *const CompiledFn, env: []Value) anyerror!Value {
        const code = cf.code;
        const int_pool = cf.int_pool;
        const float_pool = cf.float_pool;
        const str_pool = cf.str_pool;
        const arg_regs = cf.arg_regs;
        const arg_ranges = cf.arg_ranges;
        const phi_tables = cf.phi_tables;

        var pc: usize = 0;
        var cur_label_idx: u16 = std.math.maxInt(u16);
        var prev_label_idx: u16 = std.math.maxInt(u16);

        while (true) {
            const ins = code[pc];
            switch (ins.op) {
                .load_int => {
                    env[ins.dst] = .{ .int = int_pool[ins.a] };
                    pc += 1;
                },
                .load_float => {
                    env[ins.dst] = .{ .float_ = float_pool[ins.a] };
                    pc += 1;
                },
                .load_str => {
                    env[ins.dst] = .{ .str = str_pool[ins.a] };
                    pc += 1;
                },
                .move => {
                    env[ins.dst] = env[ins.a];
                    pc += 1;
                },
                .load_named => {
                    const name = str_pool[ins.a];
                    env[ins.dst] = if (name.len > 0 and name[0] == 'W') .{ .int = 1 } else .{ .int = 0 };
                    pc += 1;
                },

                .add => {
                    const a = if (ins.flag & 0x01 != 0) int_pool[ins.a] else env[ins.a].int;
                    const b = if (ins.flag & 0x02 != 0) int_pool[ins.b] else env[ins.b].int;
                    env[ins.dst] = .{ .int = a +% b };
                    pc += 1;
                },
                .sub => {
                    const a = if (ins.flag & 0x01 != 0) int_pool[ins.a] else env[ins.a].int;
                    const b = if (ins.flag & 0x02 != 0) int_pool[ins.b] else env[ins.b].int;
                    env[ins.dst] = .{ .int = a -% b };
                    pc += 1;
                },
                .mul => {
                    const a = if (ins.flag & 0x01 != 0) int_pool[ins.a] else env[ins.a].int;
                    const b = if (ins.flag & 0x02 != 0) int_pool[ins.b] else env[ins.b].int;
                    env[ins.dst] = .{ .int = a *% b };
                    pc += 1;
                },
                .div => {
                    const a = if (ins.flag & 0x01 != 0) int_pool[ins.a] else env[ins.a].int;
                    const b = if (ins.flag & 0x02 != 0) int_pool[ins.b] else env[ins.b].int;
                    if (b == 0) return error.DivisionByZero;
                    env[ins.dst] = .{ .int = @divTrunc(a, b) };
                    pc += 1;
                },
                .lt => {
                    const a = if (ins.flag & 0x01 != 0) int_pool[ins.a] else env[ins.a].int;
                    const b = if (ins.flag & 0x02 != 0) int_pool[ins.b] else env[ins.b].int;
                    env[ins.dst] = .{ .bool_ = a < b };
                    pc += 1;
                },
                .gt => {
                    const a = if (ins.flag & 0x01 != 0) int_pool[ins.a] else env[ins.a].int;
                    const b = if (ins.flag & 0x02 != 0) int_pool[ins.b] else env[ins.b].int;
                    env[ins.dst] = .{ .bool_ = a > b };
                    pc += 1;
                },
                .le => {
                    const a = if (ins.flag & 0x01 != 0) int_pool[ins.a] else env[ins.a].int;
                    const b = if (ins.flag & 0x02 != 0) int_pool[ins.b] else env[ins.b].int;
                    env[ins.dst] = .{ .bool_ = a <= b };
                    pc += 1;
                },
                .ge => {
                    const a = if (ins.flag & 0x01 != 0) int_pool[ins.a] else env[ins.a].int;
                    const b = if (ins.flag & 0x02 != 0) int_pool[ins.b] else env[ins.b].int;
                    env[ins.dst] = .{ .bool_ = a >= b };
                    pc += 1;
                },
                .eq_val => {
                    const av = env[ins.a];
                    const bv = env[ins.b];
                    env[ins.dst] = switch (av) {
                        .int => |x| .{ .bool_ = x == bv.int },
                        .str => |x| .{ .bool_ = std.mem.eql(u8, x, bv.str) },
                        else => return error.TypeMismatch,
                    };
                    pc += 1;
                },

                .set_label => {
                    cur_label_idx = ins.dst;
                    pc += 1;
                },
                .jmp => {
                    prev_label_idx = cur_label_idx;
                    pc = ins.a;
                },
                .br_if => {
                    const taken = switch (env[ins.dst]) {
                        .bool_ => |b| b,
                        .int => |n| n != 0,
                        else => return error.TypeMismatch,
                    };
                    prev_label_idx = cur_label_idx;
                    pc = if (taken) ins.a else ins.b;
                },
                .ret => return env[ins.dst],
                .ret_void => return .void_,

                .phi => {
                    const entries = phi_tables[ins.a];
                    var found = false;
                    for (entries) |e| {
                        if (e.pred_label_idx == prev_label_idx) {
                            env[ins.dst] = env[e.src_reg];
                            found = true;
                            break;
                        }
                    }
                    if (!found) return error.PhiNoMatchingArm;
                    pc += 1;
                },

                .call_user, .call_user_void => {
                    const ar = arg_ranges[ins.b];
                    var buf: [32]Value = undefined;
                    for (0..ar.len) |i| buf[i] = env[arg_regs[ar.start + i]];
                    const result = try self.callFuncByIdx(ins.a, buf[0..ar.len]);
                    if (ins.op == .call_user) env[ins.dst] = result;
                    pc += 1;
                },
                .call_builtin, .call_builtin_void => {
                    const ar = arg_ranges[ins.b];
                    var buf: [32]Value = undefined;
                    for (0..ar.len) |i| buf[i] = env[arg_regs[ar.start + i]];
                    const tag: BuiltinTag = @enumFromInt(ins.a);
                    const result = try self.execBuiltin(tag, buf[0..ar.len]);
                    if (ins.op == .call_builtin) env[ins.dst] = result;
                    pc += 1;
                },

                .alloc_bytes => {
                    const n: usize = @intCast(env[ins.a].int);
                    const buf = try self.alloc.alloc(u8, n);
                    @memset(buf, 0);
                    env[ins.dst] = .{ .ptr = buf };
                    pc += 1;
                },
                .alloc_type => {
                    const type_name = str_pool[ins.a];
                    const struct_def = blk: {
                        for (self.program.structs.items) |*sd|
                            if (std.mem.eql(u8, sd.name, type_name)) break :blk sd;
                        return error.UnknownType;
                    };
                    const hs = try self.alloc.create(HeapStruct);
                    hs.* = .{ .name = struct_def.name, .fields = std.StringArrayHashMap(HeapCell).init(self.alloc) };
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
                    env[ins.dst] = .{ .ref = &ha.cells[0] };
                    pc += 1;
                },
                .alloc_array => {
                    const count: usize = @intCast(env[ins.a].int);
                    const elem_ty: lexer.Ty = @enumFromInt(ins.flag);
                    const ha = try self.alloc.create(HeapArray);
                    ha.* = .{ .cells = try self.alloc.alloc(HeapCell, count), .alloc = self.alloc };
                    for (ha.cells) |*cell| cell.* = .{ .value = switch (elem_ty) {
                        .int => .{ .int = 0 },
                        .bool_ => .{ .bool_ = false },
                        .str => .{ .str = "" },
                        else => .void_,
                    } };
                    try self.heap_arrays.append(self.alloc, ha);
                    env[ins.dst] = .{ .ref = &ha.cells[0] };
                    pc += 1;
                },
                .load_ref => {
                    env[ins.dst] = switch (env[ins.a]) {
                        .ref => |r| r.value,
                        else => return error.NotAPointer,
                    };
                    pc += 1;
                },
                .store_ref => {
                    const cell = switch (env[ins.dst]) {
                        .ref => |r| r,
                        else => return error.NotAPointer,
                    };
                    const val = env[ins.a];
                    const is_sentinel = blk: {
                        for (self.heap_arrays.items) |ha| {
                            if (ha.cells.len == 1 and &ha.cells[0] == cell) {
                                const hs: *HeapStruct = @ptrFromInt(@as(usize, @intCast(cell.value.int)));
                                switch (val) {
                                    .struct_ => |sv| {
                                        var it = sv.fields.iterator();
                                        while (it.next()) |entry| {
                                            if (hs.fields.getPtr(entry.key_ptr.*)) |fc| fc.value = entry.value_ptr.* else try hs.fields.put(entry.key_ptr.*, .{ .value = entry.value_ptr.* });
                                        }
                                    },
                                    else => return error.TypeMismatch,
                                }
                                break :blk true;
                            }
                        }
                        break :blk false;
                    };
                    if (!is_sentinel) cell.value = val;
                    pc += 1;
                },
                .get_field_ref => {
                    const cell = switch (env[ins.a]) {
                        .ref => |r| r,
                        else => return error.NotAPointer,
                    };
                    const hs: *HeapStruct = @ptrFromInt(@as(usize, @intCast(cell.value.int)));
                    const fc = hs.fields.getPtr(str_pool[ins.b]) orelse return error.NoSuchField;
                    env[ins.dst] = .{ .ref = fc };
                    pc += 1;
                },
                .get_index_ref => {
                    const base = switch (env[ins.a]) {
                        .ref => |r| r,
                        else => return error.NotAPointer,
                    };
                    const idx: usize = @intCast(env[ins.b].int);
                    const ha = blk: {
                        for (self.heap_arrays.items) |ha|
                            if (ha.cells.len > 0 and &ha.cells[0] == base) break :blk ha;
                        return error.InvalidArrayPointer;
                    };
                    if (idx >= ha.cells.len) return error.IndexOutOfBounds;
                    env[ins.dst] = .{ .ref = &ha.cells[idx] };
                    pc += 1;
                },
                .free_reg => {
                    switch (env[ins.dst]) {
                        .ptr => |p| {
                            self.alloc.free(p);
                            env[ins.dst] = .void_;
                        },
                        .ref => |r| {
                            for (self.heap_arrays.items, 0..) |ha, i| {
                                if (ha.cells.len > 0 and &ha.cells[0] == r) {
                                    ha.deinit();
                                    self.alloc.destroy(ha);
                                    self.heap_arrays.items[i] = self.heap_arrays.items[self.heap_arrays.items.len - 1];
                                    self.heap_arrays.items.len -= 1;
                                    env[ins.dst] = .void_;
                                    break;
                                }
                            }
                        },
                        else => return error.InvalidFree,
                    }
                    pc += 1;
                },
                .arena_create => {
                    const arena = try self.alloc.create(BearArena);
                    arena.* = BearArena.init(self.alloc);
                    var placed = false;
                    for (self.arenas.items, 0..) |slot, i| {
                        if (slot == null) {
                            self.arenas.items[i] = arena;
                            env[ins.dst] = .{ .int = @intCast(i) };
                            placed = true;
                            break;
                        }
                    }
                    if (!placed) {
                        try self.arenas.append(self.alloc, arena);
                        env[ins.dst] = .{ .int = @intCast(self.arenas.items.len - 1) };
                    }
                    pc += 1;
                },
                .arena_alloc => {
                    const arena_id: usize = @intCast(env[ins.a].int);
                    if (arena_id >= self.arenas.items.len) return error.InvalidArena;
                    const arena = self.arenas.items[arena_id] orelse return error.InvalidArena;
                    const n: usize = @intCast(env[ins.b].int);
                    const buf = try arena.allocator().alloc(u8, n);
                    @memset(buf, 0);
                    env[ins.dst] = .{ .arena_ptr = buf };
                    pc += 1;
                },
                .arena_destroy => {
                    const arena_id: usize = @intCast(env[ins.dst].int);
                    if (arena_id < self.arenas.items.len) {
                        if (self.arenas.items[arena_id]) |arena| {
                            arena.deinit();
                            self.alloc.destroy(arena);
                            self.arenas.items[arena_id] = null;
                        }
                    }
                    env[ins.dst] = .void_;
                    pc += 1;
                },

                .struct_lit => {
                    const name = str_pool[ins.a];
                    const ar = arg_ranges[ins.b];
                    var fields = std.StringArrayHashMap(Value).init(self.alloc);
                    var i: usize = 0;
                    while (i < ar.len) : (i += 1) {
                        const fn_idx = arg_regs[ar.start + i * 2];
                        const val_reg = arg_regs[ar.start + i * 2 + 1];
                        try fields.put(str_pool[fn_idx], env[val_reg]);
                    }
                    env[ins.dst] = .{ .struct_ = .{ .name = name, .fields = fields } };
                    pc += 1;
                },
                .set_field => {
                    try env[ins.dst].struct_.fields.put(str_pool[ins.a], env[ins.b]);
                    pc += 1;
                },
                .get_field => {
                    env[ins.dst] = switch (env[ins.a]) {
                        .struct_ => |sv| sv.fields.get(str_pool[ins.b]) orelse return error.NoSuchField,
                        else => return error.NotAStruct,
                    };
                    pc += 1;
                },

                .spawn => {
                    const task_table = self.tasks orelse return error.NoTaskTable;
                    const ar = arg_ranges[ins.b];
                    if (ar.len > 32) return error.TooManyArguments;
                    var buf: [32]Value = undefined;
                    for (0..ar.len) |i| buf[i] = env[arg_regs[ar.start + i]];
                    const func_name = str_pool[ins.a];
                    const args_heap = try self.alloc.alloc(Value, ar.len);
                    @memcpy(args_heap, buf[0..ar.len]);
                    const task_id = try task_table.reserve();
                    const sa = try self.alloc.create(SpawnArgs);
                    sa.* = .{ .program = self.program, .func_name = func_name, .args = args_heap, .task_id = task_id, .tasks = task_table, .alloc = self.alloc };
                    const thread = try std.Thread.spawn(.{}, spawnEntry, .{sa});
                    task_table.setThread(task_id, thread);
                    env[ins.dst] = .{ .int = @intCast(task_id) };
                    pc += 1;
                },
                .sync_task => {
                    const task_table = self.tasks orelse return error.NoTaskTable;
                    env[ins.dst] = try task_table.join(@intCast(env[ins.a].int));
                    pc += 1;
                },

                .cast => {
                    const v = env[ins.a];
                    const ty: lexer.Ty = @enumFromInt(ins.flag);
                    env[ins.dst] = switch (ty) {
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
                    pc += 1;
                },
            }
        }
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
                    break :inner try self.allocFile(.{ .read = try std.fs.cwd().openFile(path, .{}) });
                } else inner: {
                    break :inner try self.allocFile(.{ .write = try std.fs.cwd().createFile(path, .{ .truncate = true }) });
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
                if (fd < self.files.items.len) if (self.files.items[fd]) |fh| {
                    switch (fh) {
                        .read => |f| f.close(),
                        .write => |f| f.close(),
                    }
                    self.files.items[fd] = null;
                };
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

    pub fn execBody(self: *Vm, _: []const lexer.Stmt, _: []Value, func_idx: u32) anyerror!?Value {
        return try self.callFuncByIdx(func_idx, &.{});
    }
};
