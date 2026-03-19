//! BearVM JIT — minimal AArch64 (Apple Silicon) native code generation.
//!
//! All instruction encodings verified against `as -arch arm64`.

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
        self.mem[self.len] = w;
        self.len += 1;
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

fn blr(xn: u5) u32 {
    return 0xd63f0000 | (@as(u32, xn) << 5);
}

fn movz(xd: u5, imm16: u16, shift: u2) u32 {
    return (0b110100101 << 23) | (@as(u32, shift) << 21) | (@as(u32, imm16) << 5) | @as(u32, xd);
}

fn movk(xd: u5, imm16: u16, shift: u2) u32 {
    return (0b111100101 << 23) | (@as(u32, shift) << 21) | (@as(u32, imm16) << 5) | @as(u32, xd);
}

/// Load any 64-bit value into xd using movz + up to 3 movk
fn emitImm64(buf: *CodeBuf, xd: u5, val: u64) void {
    const lo: u16 = @truncate(val);
    const h1: u16 = @truncate(val >> 16);
    const h2: u16 = @truncate(val >> 32);
    const h3: u16 = @truncate(val >> 48);
    buf.emit(movz(xd, lo, 0));
    if (h1 != 0) buf.emit(movk(xd, h1, 1));
    if (h2 != 0) buf.emit(movk(xd, h2, 2));
    if (h3 != 0) buf.emit(movk(xd, h3, 3));
}

fn bear_puts(ptr: [*]const u8, len: usize) callconv(.{ .aarch64_aapcs_darwin = .{} }) void {
    const stdout = std.fs.File{ .handle = 1 };
    stdout.writeAll(ptr[0..len]) catch {};
    stdout.writeAll("\n") catch {};
}

fn compileFunc(buf: *CodeBuf, func: *const lexer.Function) !void {
    buf.emit(stp_fp_lr_pre16());
    buf.emit(mov_fp_sp());

    for (func.body.items) |*stmt| {
        switch (stmt.*) {
            .call => |c| {
                if (std.mem.eql(u8, c.name, "puts") and c.args.items.len == 1) {
                    const arg = c.args.items[0];
                    switch (arg.*) {
                        .str => |s| {
                            emitImm64(buf, 0, @intFromPtr(s.ptr));
                            emitImm64(buf, 1, s.len);
                        },
                        else => {
                            buf.emit(movz(0, 0, 0));
                            buf.emit(movz(1, 0, 0));
                        },
                    }
                    emitImm64(buf, 8, @intFromPtr(&bear_puts));
                    buf.emit(blr(8));
                }
            },
            .ret => |e| {
                switch (e.*) {
                    .int => |n| emitImm64(buf, 0, @bitCast(n)),
                    .reg => buf.emit(movz(0, 0, 0)),
                    else => buf.emit(movz(0, 0, 0)),
                }
                buf.emit(ldp_fp_lr_post16());
                buf.emit(ret_());
                return;
            },
            else => {},
        }
    }

    buf.emit(movz(0, 0, 0));
    buf.emit(ldp_fp_lr_post16());
    buf.emit(ret_());
}

pub fn run(program: *const lexer.Program, alloc: std.mem.Allocator) !void {
    _ = alloc;

    var buf = try CodeBuf.init(1024);
    defer buf.deinit();

    var main_func: ?*const lexer.Function = null;
    for (program.functions.items) |*f| {
        if (std.mem.eql(u8, f.name, "main")) {
            main_func = f;
            break;
        }
    }

    const func = main_func orelse return error.NoMainFunction;
    const start = buf.len;

    try compileFunc(&buf, func);
    buf.finalize();

    const MainFn = *const fn () callconv(.{ .aarch64_aapcs_darwin = .{} }) i64;
    const fn_ptr: MainFn = @ptrCast(&buf.mem[start]);
    _ = fn_ptr();
}
