const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");

const default_log_filename = "supersearchr-debug.log";

fn parseEnabled(raw: []const u8) bool {
    return std.ascii.eqlIgnoreCase(raw, "1") or
        std.ascii.eqlIgnoreCase(raw, "true") or
        std.ascii.eqlIgnoreCase(raw, "yes") or
        std.ascii.eqlIgnoreCase(raw, "on");
}

pub fn isEnabled(allocator: std.mem.Allocator) bool {
    const value = compat.getEnvVarOwned(allocator, "SUPERSEARCHR_DEBUG") catch return false;
    defer allocator.free(value);
    return parseEnabled(value);
}

fn getLogPath(allocator: std.mem.Allocator) ![]const u8 {
    const value = compat.getEnvVarOwned(allocator, "SUPERSEARCHR_DEBUG_PATH") catch {
        return defaultLogPath(allocator);
    };
    if (value.len == 0) {
        allocator.free(value);
        return defaultLogPath(allocator);
    }
    return value;
}

fn defaultLogPath(allocator: std.mem.Allocator) ![]const u8 {
    const temp_dir = try getTempDir(allocator);
    defer allocator.free(temp_dir);
    return std.fs.path.join(allocator, &.{ temp_dir, default_log_filename });
}

fn getTempDir(allocator: std.mem.Allocator) ![]const u8 {
    if (compat.getEnvVarOwned(allocator, "TMPDIR")) |value| {
        if (value.len > 0) return value;
        allocator.free(value);
    } else |_| {}

    if (builtin.os.tag == .windows) {
        if (compat.getEnvVarOwned(allocator, "TEMP")) |value| {
            if (value.len > 0) return value;
            allocator.free(value);
        } else |_| {}
        if (compat.getEnvVarOwned(allocator, "TMP")) |value| {
            if (value.len > 0) return value;
            allocator.free(value);
        } else |_| {}
        if (compat.getEnvVarOwned(allocator, "LOCALAPPDATA")) |value| {
            if (value.len > 0) return value;
            allocator.free(value);
        } else |_| {}
    }

    return allocator.dupe(u8, "/tmp");
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

    const io = compat.io();
    const file = std.Io.Dir.openFileAbsolute(io, log_path, .{ .mode = .read_write }) catch
        std.Io.Dir.createFileAbsolute(io, log_path, .{ .read = true, .truncate = false }) catch return;
    defer compat.closeFile(file);

    var msg_buf: [2048]u8 = undefined;
    const message = std.fmt.bufPrint(&msg_buf, fmt, args) catch return;

    var line_buf: [2304]u8 = undefined;
    const line = std.fmt.bufPrint(
        &line_buf,
        "[{d}] {s}: {s}\n",
        .{ @as(i64, @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, 1_000_000_000))), scope, message },
    ) catch return;

    compat.appendFileAll(file, line) catch return;
}
