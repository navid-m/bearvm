const std = @import("std");
const Io = std.Io;
const File = Io.File;

var stdout_buf: [65536]u8 = undefined;
var stdout_pos: usize = 0;
fn writeFileSingleThreaded(f: std.Io.File, buf: []const u8) !void {
    var io = std.Io.Threaded.init_single_threaded;
    defer io.deinit();
    try f.writeStreamingAll(io.io(), buf);
}
pub inline fn flushStdout() void {
    writeFileSingleThreaded(File.stdout(), stdout_buf[0..stdout_pos]) catch {};
    stdout_pos = 0;
}

pub inline fn writeStdout(s: []const u8) void {
    const remaining = stdout_buf.len - stdout_pos;
    if (s.len > remaining) {
        if (stdout_pos > 0) flushStdout();
        if (s.len > stdout_buf.len) {
            _ = writeFileSingleThreaded(File.stdout(), s) catch {};
            return;
        }
    }
    @memcpy(stdout_buf[stdout_pos..][0..s.len], s);
    stdout_pos += s.len;
}
