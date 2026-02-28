const std = @import("std");

const default_log_path = "/tmp/supersearchr-debug.log";

fn parseEnabled(raw: []const u8) bool {
    return std.ascii.eqlIgnoreCase(raw, "1") or
        std.ascii.eqlIgnoreCase(raw, "true") or
        std.ascii.eqlIgnoreCase(raw, "yes") or
        std.ascii.eqlIgnoreCase(raw, "on");
}

pub fn isEnabled(allocator: std.mem.Allocator) bool {
    const value = std.process.getEnvVarOwned(allocator, "SUPERSEARCHR_DEBUG") catch return false;
    defer allocator.free(value);
    return parseEnabled(value);
}

fn getLogPath(allocator: std.mem.Allocator) ![]const u8 {
    const value = std.process.getEnvVarOwned(allocator, "SUPERSEARCHR_DEBUG_PATH") catch {
        return allocator.dupe(u8, default_log_path);
    };
    if (value.len == 0) {
        allocator.free(value);
        return allocator.dupe(u8, default_log_path);
    }
    return value;
}

pub fn writef(
    allocator: std.mem.Allocator,
    scope: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (!isEnabled(allocator)) return;

    const log_path = getLogPath(allocator) catch return;
    defer allocator.free(log_path);

    const file = std.fs.openFileAbsolute(log_path, .{ .mode = .read_write }) catch
        std.fs.createFileAbsolute(log_path, .{ .read = true, .truncate = false }) catch return;
    defer file.close();

    file.seekFromEnd(0) catch return;

    var msg_buf: [2048]u8 = undefined;
    const message = std.fmt.bufPrint(&msg_buf, fmt, args) catch return;

    var line_buf: [2304]u8 = undefined;
    const line = std.fmt.bufPrint(
        &line_buf,
        "[{d}] {s}: {s}\n",
        .{ std.time.timestamp(), scope, message },
    ) catch return;

    file.writeAll(line) catch return;
}
