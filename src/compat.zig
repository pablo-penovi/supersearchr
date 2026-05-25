const std = @import("std");
const builtin = @import("builtin");

pub fn io() std.Io {
    if (builtin.is_test) return std.testing.io;
    if (std.Options.debug_threaded_io) |threaded| return threaded.io();
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const environ = if (builtin.is_test)
        std.testing.environ
    else if (std.Options.debug_threaded_io) |threaded|
        threaded.environ.process_environ
    else
        std.process.Environ.empty;

    return environ.getAlloc(allocator, name);
}

pub fn sleepMillis(milliseconds: i64) void {
    std.Io.sleep(io(), .fromMilliseconds(milliseconds), .awake) catch {};
}

pub fn sleepNanos(nanoseconds: i96) void {
    std.Io.sleep(io(), .fromNanoseconds(nanoseconds), .awake) catch {};
}

pub fn readFile(file: std.Io.File, buffer: []u8) !usize {
    return file.readStreaming(io(), &.{buffer}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => |e| return e,
    };
}

pub fn writeFileAll(file: std.Io.File, bytes: []const u8) !void {
    try file.writeStreamingAll(io(), bytes);
}

pub fn stdoutWriteAll(bytes: []const u8) void {
    writeFileAll(.stdout(), bytes) catch {};
}

pub const FileWriter = struct {
    file: std.Io.File,

    pub fn writeAll(self: FileWriter, bytes: []const u8) !void {
        try writeFileAll(self.file, bytes);
    }
};

pub fn stdoutWriter() FileWriter {
    return .{ .file = .stdout() };
}

pub fn closeFile(file: std.Io.File) void {
    file.close(io());
}

pub fn appendFileAll(file: std.Io.File, bytes: []const u8) !void {
    const stat = try file.stat(io());
    try file.writePositionalAll(io(), bytes, stat.size);
}

pub fn milliTimestamp() i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(io()).nanoseconds, 1_000_000));
}

pub fn timestamp() i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(io()).nanoseconds, 1_000_000_000));
}
