//! BearVM JIT - AArch64 (Apple Silicon) native code generation.
//!
//! Register allocation convention (caller-saved, so free across our own calls):
//!
//!  - X9..X15  - scratch / expression temporaries
//!  - X19..X28 - VM registers (callee-saved; we save them in the prologue)

const std = @import("std");
const lexer = @import("lexer.zig");

extern fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: i64) ?*anyopaque;
extern fn munmap(addr: *anyopaque, len: usize) c_int;
extern fn pthread_jit_write_protect_np(enabled: c_int) void;
extern fn sys_icache_invalidate(start: *anyopaque, len: usize) void;

const PROT_RWX: c_int = 0x07;
const MAP_PRIVATE: c_int = 0x0002;
const MAP_ANON: c_int = 0x1000;
const MAP_JIT: c_int = 0x0800;

const CodeBuf = struct {
    mem: [*]align(4) u32,
    cap: usize,
    len: usize,

    fn init(cap: usize) !CodeBuf {
        const raw = mmap(null, cap * 4, PROT_RWX, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0) orelse return error.MmapFailed;
        pthread_jit_write_protect_np(0);
        return .{ .mem = @ptrCast(@alignCast(raw)), .cap = cap, .len = 0 };
    }

    fn deinit(self: *CodeBuf) void {
        _ = munmap(@ptrCast(self.mem), self.cap * 4);
    }

    fn emit(self: *CodeBuf, w: u32) void {
        std.debug.assert(self.len < self.cap);
        self.mem[self.len] = w;
        self.len += 1;
    }

    /// Return current emit position (word index), useful for branch sources/targets.
    fn here(self: *const CodeBuf) u32 {
        return @intCast(self.len);
    }

    /// Patch a previously emitted word (used to fix up forward branches).
    fn patch(self: *CodeBuf, idx: u32, w: u32) void {
        self.mem[idx] = w;
    }

    fn finalize(self: *CodeBuf) void {
        pthread_jit_write_protect_np(1);
        sys_icache_invalidate(@ptrCast(self.mem), self.len * 4);
    }
};

fn stp_fp_lr_pre16() u32 {
    return 0xa9bf7bfd;
}

fn ldp_fp_lr_post16() u32 {
    return 0xa8c17bfd;
}

fn mov_fp_sp() u32 {
    return 0x910003fd;
}

fn ret_() u32 {
    return 0xd65f03c0;
}

/// Save/restore callee-saved pair  STP Xn, Xm, [SP, #imm7*8]!  (pre-index)
/// imm7 is signed; -N encodes as ((-N) & 0x7f).
fn stp_pre(xn: u5, xm: u5, imm7: i7) u32 {
    const i: u7 = @bitCast(imm7);
    return 0xa9800000 |
        (@as(u32, i) << 15) |
        (@as(u32, xm) << 10) |
        (@as(u32, 29) << 5) |
        @as(u32, xn);
}

/// STP Xn, Xm, [SP, #-frame_size]! — push pair onto stack
/// We use a dedicated helper that encodes correctly.
fn stp_callee(xn: u5, xm: u5, slot: u6) u32 {
    const off: u7 = @intCast(slot * 2);
    return (0b1010_1001_00 << 22) | (@as(u32, off) << 15) |
        (@as(u32, xm) << 10) | (31 << 5) | @as(u32, xn);
}

/// LDP Xn, Xm, [SP, #slot*16]
fn ldp_callee(xn: u5, xm: u5, slot: u6) u32 {
    const off: u7 = @intCast(slot * 2);
    return (0b1010_1001_01 << 22) | (@as(u32, off) << 15) |
        (@as(u32, xm) << 10) | (31 << 5) | @as(u32, xn);
}

/// SUB SP, SP, #imm12 (shift=0)
fn sub_sp_imm(imm12: u12) u32 {
    return 0xd1000000 | (@as(u32, imm12) << 10) | (31 << 5) | 31;
}

/// ADD SP, SP, #imm12
fn add_sp_imm(imm12: u12) u32 {
    return 0x91000000 | (@as(u32, imm12) << 10) | (31 << 5) | 31;
}

/// Data-processing (register, 64-bit)
fn add_r(xd: u5, xn: u5, xm: u5) u32 {
    return 0x8b000000 | (@as(u32, xm) << 16) | (@as(u32, xn) << 5) | @as(u32, xd);
}

fn sub_r(xd: u5, xn: u5, xm: u5) u32 {
    return 0xcb000000 | (@as(u32, xm) << 16) | (@as(u32, xn) << 5) | @as(u32, xd);
}

fn mul_r(xd: u5, xn: u5, xm: u5) u32 {
    return 0x9b000000 | (@as(u32, xm) << 16) | (31 << 10) |
        (@as(u32, xn) << 5) | @as(u32, xd);
}

fn sdiv_r(xd: u5, xn: u5, xm: u5) u32 {
    return 0x9ac00c00 | (@as(u32, xm) << 16) | (@as(u32, xn) << 5) | @as(u32, xd);
}

/// MOV Xd, Xn  (alias: ORR Xd, XZR, Xn)
fn mov_r(xd: u5, xn: u5) u32 {
    return 0xaa000000 | (@as(u32, xn) << 16) | (31 << 5) | @as(u32, xd);
}

fn movz(xd: u5, imm16: u16, shift: u2) u32 {
    return (0b110100101 << 23) | (@as(u32, shift) << 21) |
        (@as(u32, imm16) << 5) | @as(u32, xd);
}

fn movk(xd: u5, imm16: u16, shift: u2) u32 {
    return (0b111100101 << 23) | (@as(u32, shift) << 21) |
        (@as(u32, imm16) << 5) | @as(u32, xd);
}

/// Load any 64-bit value into Xd using MOVZ + up to 3 MOVK.
fn emitImm64(buf: *CodeBuf, xd: u5, val: u64) void {
    buf.emit(movz(xd, @truncate(val), 0));
    if (@as(u16, @truncate(val >> 16)) != 0) buf.emit(movk(xd, @truncate(val >> 16), 1));
    if (@as(u16, @truncate(val >> 32)) != 0) buf.emit(movk(xd, @truncate(val >> 32), 2));
    if (@as(u16, @truncate(val >> 48)) != 0) buf.emit(movk(xd, @truncate(val >> 48), 3));
}

/// CMP Xn, Xm (SUBS XZR, Xn, Xm)
fn cmp_r(xn: u5, xm: u5) u32 {
    return 0xeb000000 | (@as(u32, xm) << 16) | (@as(u32, xn) << 5) | 31;
}

/// CSET Xd, cond — set Xd=1 if cond, else 0
/// Condition codes: EQ=0, NE=1, LT(signed)=0xb, GT(signed)=0xc, LE=0xd, GE=0xa
fn cset(xd: u5, cond: u4) u32 {
    const inv_cond: u4 = cond ^ 1;
    return 0x9a9f0000 | (@as(u32, inv_cond) << 12) | (31 << 5) | @as(u32, xd);
}

const COND_EQ: u4 = 0x0;
const COND_LT: u4 = 0xb;
const COND_GT: u4 = 0xc;

fn blr(xn: u5) u32 {
    return 0xd63f0000 | (@as(u32, xn) << 5);
}

fn bl_rel(offset_words: i26) u32 {
    const enc: u26 = @bitCast(offset_words);
    return 0x94000000 | @as(u32, enc);
}

fn cbz(xn: u5, offset_words: i19) u32 {
    const enc: u19 = @bitCast(offset_words);
    return 0xb4000000 | (@as(u32, enc) << 5) | @as(u32, xn);
}

fn cbnz(xn: u5, offset_words: i19) u32 {
    const enc: u19 = @bitCast(offset_words);
    return 0xb5000000 | (@as(u32, enc) << 5) | @as(u32, xn);
}

fn b_rel(offset_words: i26) u32 {
    const enc: u26 = @bitCast(offset_words);
    return 0x14000000 | @as(u32, enc);
}

fn bear_puts(ptr: [*]const u8, len: usize) callconv(.{ .aarch64_aapcs_darwin = .{} }) void {
    const stdout = std.fs.File{ .handle = 1 };
    stdout.writeAll(ptr[0..len]) catch {};
    stdout.writeAll("\n") catch {};
}

const VM_REG_BASE: u5 = 19;
const MAX_VM_REGS: u5 = 10;

fn vmReg(idx: u32) u5 {
    std.debug.assert(idx < MAX_VM_REGS);
    return @intCast(VM_REG_BASE + idx);
}

const SCRATCH_A: u5 = 9;
const SCRATCH_B: u5 = 10;
const SCRATCH_C: u5 = 11;

/// One forward-branch that needs its offset filled in once the
/// target label position is known.
const Patch = struct {
    /// Word index of the branch instruction in CodeBuf.mem.
    instr_idx: u32,

    /// The label name this branch targets.
    label: []const u8,

    /// The kind of patch.
    kind: enum { cbz, cbnz, b },

    /// For cbz/cbnz we need to know which register to test.
    reg: u5,
};

const Compiler = struct {
    buf: *CodeBuf,
    func: *const lexer.Function,
    program: *const lexer.Program,
    labels: std.StringHashMapUnmanaged(u32),
    patches: std.ArrayListUnmanaged(Patch),
    alloc: std.mem.Allocator,
    func_offs: *const std.StringHashMapUnmanaged(u32),

    fn init(
        buf: *CodeBuf,
        func: *const lexer.Function,
        program: *const lexer.Program,
        func_offs: *const std.StringHashMapUnmanaged(u32),
        alloc: std.mem.Allocator,
    ) Compiler {
        return .{
            .buf = buf,
            .func = func,
            .program = program,
            .labels = .{},
            .patches = .{},
            .alloc = alloc,
            .func_offs = func_offs,
        };
    }

    fn deinit(self: *Compiler) void {
        self.labels.deinit(self.alloc);
        self.patches.deinit(self.alloc);
    }

    fn evalExpr(self: *Compiler, expr: *const lexer.Expr, dst: u5) anyerror!void {
        switch (expr.*) {
            .int => |n| emitImm64(self.buf, dst, @bitCast(n)),
            .str => |s| {
                emitImm64(self.buf, dst, @intFromPtr(s.ptr));
                emitImm64(self.buf, dst + 1, s.len);
            },

            .reg => |idx| {
                self.buf.emit(mov_r(dst, vmReg(idx)));
            },

            .add => |op| {
                try self.evalExpr(op.a, SCRATCH_A);
                try self.evalExpr(op.b, SCRATCH_B);
                self.buf.emit(add_r(dst, SCRATCH_A, SCRATCH_B));
            },
            .sub => |op| {
                try self.evalExpr(op.a, SCRATCH_A);
                try self.evalExpr(op.b, SCRATCH_B);
                self.buf.emit(sub_r(dst, SCRATCH_A, SCRATCH_B));
            },
            .mul => |op| {
                try self.evalExpr(op.a, SCRATCH_A);
                try self.evalExpr(op.b, SCRATCH_B);
                self.buf.emit(mul_r(dst, SCRATCH_A, SCRATCH_B));
            },
            .div => |op| {
                try self.evalExpr(op.a, SCRATCH_A);
                try self.evalExpr(op.b, SCRATCH_B);
                self.buf.emit(sdiv_r(dst, SCRATCH_A, SCRATCH_B));
            },

            .lt => |op| {
                try self.evalExpr(op.a, SCRATCH_A);
                try self.evalExpr(op.b, SCRATCH_B);
                self.buf.emit(cmp_r(SCRATCH_A, SCRATCH_B));
                self.buf.emit(cset(dst, COND_LT));
            },
            .gt => |op| {
                try self.evalExpr(op.a, SCRATCH_A);
                try self.evalExpr(op.b, SCRATCH_B);
                self.buf.emit(cmp_r(SCRATCH_A, SCRATCH_B));
                self.buf.emit(cset(dst, COND_GT));
            },
            .eq => |op| {
                try self.evalExpr(op.a, SCRATCH_A);
                try self.evalExpr(op.b, SCRATCH_B);
                self.buf.emit(cmp_r(SCRATCH_A, SCRATCH_B));
                self.buf.emit(cset(dst, COND_EQ));
            },

            .call => |c| try self.emitCall(c.name, c.args.items, dst),

            else => return error.UnsupportedExpr,
        }
    }

    fn emitCall(self: *Compiler, name: []const u8, arg_exprs: []*lexer.Expr, dst: u5) !void {
        if (std.mem.eql(u8, name, "puts")) {
            if (arg_exprs.len == 1) {
                const arg = arg_exprs[0];
                switch (arg.*) {
                    .str => |s| {
                        emitImm64(self.buf, 0, @intFromPtr(s.ptr));
                        emitImm64(self.buf, 1, s.len);
                    },
                    .reg => |idx| {
                        // TODO: For now mirror vm.zig: load register, call with value in X0.
                        self.buf.emit(mov_r(0, vmReg(idx)));
                        self.buf.emit(movz(1, 0, 0));
                    },
                    else => {
                        try self.evalExpr(arg, 0);
                        self.buf.emit(movz(1, 0, 0));
                    },
                }
                emitImm64(self.buf, SCRATCH_C, @intFromPtr(&bear_puts));
                self.buf.emit(blr(SCRATCH_C));
            }
            if (dst != 0) self.buf.emit(movz(dst, 0, 0));
            return;
        }

        const argc = arg_exprs.len;
        if (argc > 8) return error.TooManyArguments;
        for (arg_exprs, 0..) |a, i| {
            try self.evalExpr(a, @intCast(i));
        }

        if (self.func_offs.get(name)) |target_word| {
            const here_word = self.buf.here();
            const off: i64 = @as(i64, target_word) - @as(i64, here_word);
            if (off >= -(1 << 25) and off < (1 << 25)) {
                self.buf.emit(bl_rel(@intCast(off)));
            } else {
                emitImm64(self.buf, SCRATCH_C, @intFromPtr(&self.buf.mem[target_word]));
                self.buf.emit(blr(SCRATCH_C));
            }
        } else {
            const instr_idx = self.buf.here();
            self.buf.emit(0x94000000);
            try self.patches.append(self.alloc, .{
                .instr_idx = instr_idx,
                .label = name,
                .kind = .b,
                .reg = 0,
            });
        }

        if (dst != 0) self.buf.emit(mov_r(dst, 0));
    }

    fn compileStmts(self: *Compiler, stmts: []const lexer.Stmt) anyerror!void {
        for (stmts, 0..) |*stmt, si| {
            _ = si;
            switch (stmt.*) {
                .label => |lbl| {
                    try self.labels.put(self.alloc, lbl, self.buf.here());
                },

                .assign => |a| {
                    const dst = vmReg(a.reg);
                    try self.evalExpr(a.expr, dst);
                },

                .call => |c| {
                    try self.emitCall(c.name, c.args.items, 0);
                },

                .ret => |e| {
                    try self.evalExpr(e, 0);
                    self.emitEpilogue();
                },

                .while_ => |w| {
                    const loop_top = self.buf.here();

                    try self.evalExpr(w.cond, SCRATCH_A);

                    const cbz_idx = self.buf.here();
                    self.buf.emit(0xb4000000 | @as(u32, SCRATCH_A));

                    try self.compileStmts(w.body.items);

                    const back_off: i64 = @as(i64, loop_top) - @as(i64, self.buf.here());
                    self.buf.emit(b_rel(@intCast(back_off)));

                    const loop_end = self.buf.here();
                    const fwd_off: i64 = @as(i64, loop_end) - @as(i64, cbz_idx);
                    self.buf.patch(cbz_idx, cbz(SCRATCH_A, @intCast(fwd_off)));
                },

                .br_if => |br| {
                    const reg = vmReg(br.cond);

                    const cbnz_idx = self.buf.here();
                    self.buf.emit(0);
                    try self.patches.append(self.alloc, .{
                        .instr_idx = cbnz_idx,
                        .label = br.true_label,
                        .kind = .cbnz,
                        .reg = reg,
                    });

                    const b_idx = self.buf.here();
                    self.buf.emit(0);
                    try self.patches.append(self.alloc, .{
                        .instr_idx = b_idx,
                        .label = br.false_label,
                        .kind = .b,
                        .reg = 0,
                    });
                },

                .jmp => |target| {
                    const jmp_idx = self.buf.here();
                    self.buf.emit(0);
                    try self.patches.append(self.alloc, .{
                        .instr_idx = jmp_idx,
                        .label = target,
                        .kind = .b,
                        .reg = 0,
                    });
                },

                .set_field => return error.UnsupportedStmt,
                .store => return error.UnsupportedStmt,
                .free => return error.UnsupportedStmt,
                .arena_destroy => return error.UnsupportedStmt,
            }
        }
    }

    fn emitPrologue(self: *Compiler) void {
        self.buf.emit(stp_fp_lr_pre16());
        self.buf.emit(mov_fp_sp());
        const frame: u12 = (@as(u12, MAX_VM_REGS) / 2) * 16;
        self.buf.emit(sub_sp_imm(frame));
        var pair: u6 = 0;
        while (pair * 2 < MAX_VM_REGS) : (pair += 1) {
            const xn: u5 = @intCast(VM_REG_BASE + pair * 2);
            const xm: u5 = @intCast(VM_REG_BASE + pair * 2 + 1);
            self.buf.emit(stp_callee(xn, xm, pair));
        }
        var r: u5 = 0;
        while (r < MAX_VM_REGS) : (r += 1) {
            self.buf.emit(movz(vmReg(r), 0, 0));
        }
        for (self.func.params.items, 0..) |param, i| {
            if (i >= 8) break;
            self.buf.emit(mov_r(vmReg(param.idx), @intCast(i)));
        }
    }

    fn emitEpilogue(self: *Compiler) void {
        const frame: u12 = (@as(u12, MAX_VM_REGS) / 2) * 16;
        var pair: u6 = 0;
        while (pair * 2 < MAX_VM_REGS) : (pair += 1) {
            const xn: u5 = @intCast(VM_REG_BASE + pair * 2);
            const xm: u5 = @intCast(VM_REG_BASE + pair * 2 + 1);
            self.buf.emit(ldp_callee(xn, xm, pair));
        }
        self.buf.emit(add_sp_imm(frame));
        self.buf.emit(ldp_fp_lr_post16());
        self.buf.emit(ret_());
    }

    fn applyPatches(self: *Compiler) !void {
        for (self.patches.items) |p| {
            const target = self.labels.get(p.label) orelse return error.UndefinedLabel;
            const off: i64 = @as(i64, target) - @as(i64, p.instr_idx);
            const instr: u32 = switch (p.kind) {
                .cbz => cbz(p.reg, @intCast(off)),
                .cbnz => cbnz(p.reg, @intCast(off)),
                .b => b_rel(@intCast(off)),
            };
            self.buf.patch(p.instr_idx, instr);
        }
    }

    fn compile(self: *Compiler) !void {
        self.emitPrologue();
        try self.compileStmts(self.func.body.items);
        self.buf.emit(movz(0, 0, 0));
        self.emitEpilogue();
        try self.applyPatches();
    }
};

pub fn run(program: *const lexer.Program, alloc: std.mem.Allocator) !void {
    var buf = try CodeBuf.init(4096);
    defer buf.deinit();

    var func_offs: std.StringHashMapUnmanaged(u32) = .{};
    defer func_offs.deinit(alloc);

    const CallPatch = struct { instr_idx: u32, name: []const u8 };
    var call_patches: std.ArrayListUnmanaged(CallPatch) = .{};
    defer call_patches.deinit(alloc);

    for (program.functions.items) |*func| {
        const start = buf.here();
        try func_offs.put(alloc, func.name, start);

        var c = Compiler.init(&buf, func, program, &func_offs, alloc);
        defer c.deinit();
        try c.compile();

        for (c.patches.items) |p| {
            if (p.kind != .b) continue;
            if (c.labels.contains(p.label)) continue;
            try call_patches.append(alloc, .{ .instr_idx = p.instr_idx, .name = p.label });
        }
    }

    for (call_patches.items) |p| {
        const target = func_offs.get(p.name) orelse return error.UndefinedFunction;
        const off: i64 = @as(i64, target) - @as(i64, p.instr_idx);
        buf.patch(p.instr_idx, bl_rel(@intCast(off)));
    }

    buf.finalize();

    const main_start = func_offs.get("main") orelse return error.NoMainFunction;
    const MainFn = *const fn () callconv(.{ .aarch64_aapcs_darwin = .{} }) i64;
    const fn_ptr: MainFn = @ptrCast(&buf.mem[main_start]);
    _ = fn_ptr();
}
