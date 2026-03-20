const std = @import("std");

var stdout_buf: [65536]u8 = undefined;
var stdout_pos: usize = 0;

pub inline fn flushStdout() void {
    if (stdout_pos == 0) return;
    _ = std.fs.File.stdout().writeAll(stdout_buf[0..stdout_pos]) catch {};
    stdout_pos = 0;
}

pub inline fn writeStdout(s: []const u8) void {
    const remaining = stdout_buf.len - stdout_pos;
    if (s.len > remaining) {
        if (stdout_pos > 0) flushStdout();
        if (s.len > stdout_buf.len) {
            _ = std.fs.File.stdout().writeAll(s) catch {};
            return;
        }
    }
    @memcpy(stdout_buf[stdout_pos..][0..s.len], s);
    stdout_pos += s.len;
}
