const bear_main = @import("bear.zig");
const std = @import("std");

pub fn flushStdout() void {
    if (bear_main.stdout_pos == 0) return;
    _ = std.fs.File.stdout().writeAll(bear_main.stdout_buf[0..bear_main.stdout_pos]) catch {};
    bear_main.stdout_pos = 0;
}

pub fn writeStdout(s: []const u8) void {
    if (bear_main.stdout_pos + s.len > bear_main.stdout_buf.len) flushStdout();
    if (s.len > bear_main.stdout_buf.len) {
        _ = std.fs.File.stdout().writeAll(s) catch {};
        return;
    }
    @memcpy(bear_main.stdout_buf[bear_main.stdout_pos..][0..s.len], s);
    bear_main.stdout_pos += s.len;
}
