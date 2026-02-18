const std = @import("std");

pub const AddLinkError = error{
    InvalidLink,
    SuperseedrNotFound,
    SuperseedrFailed,
};

pub const Executor = fn (allocator: std.mem.Allocator, argv: []const []const u8) anyerror!void;

pub fn defaultExecutor(allocator: std.mem.Allocator, argv: []const []const u8) anyerror!void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    }) catch return error.SuperseedrNotFound;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    if (result.term != .Exited or result.term.Exited != 0) {
        return error.SuperseedrFailed;
    }
}

pub fn addLink(allocator: std.mem.Allocator, link: []const u8) AddLinkError!void {
    return addLinkWithExecutor(allocator, link, defaultExecutor);
}

pub fn addLinkWithExecutor(allocator: std.mem.Allocator, link: []const u8, executor: Executor) AddLinkError!void {
    const is_magnet = std.mem.startsWith(u8, link, "magnet:");
    const is_torrent = std.mem.endsWith(u8, link, ".torrent");

    if (!is_magnet and !is_torrent) {
        return error.InvalidLink;
    }

    executor(allocator, &.{ "superseedr", "add", link }) catch |err| {
        switch (err) {
            error.SuperseedrNotFound => return error.SuperseedrNotFound,
            error.SuperseedrFailed => return error.SuperseedrFailed,
            else => return error.SuperseedrFailed,
        }
    };
}

test "valid magnet URL is accepted" {
    var argv_captured: ?[]const []const u8 = null;
    const mock = struct {
        var captured: *?[]const []const u8 = undefined;
        fn exec(_: std.mem.Allocator, argv: []const []const u8) anyerror!void {
            captured.* = argv;
        }
    };
    mock.captured = &argv_captured;

    try addLinkWithExecutor(std.testing.allocator, "magnet:?xt=urn:btih:1234567890", mock.exec);
    try std.testing.expect(argv_captured != null);
    try std.testing.expectEqualStrings("superseedr", argv_captured.?[0]);
    try std.testing.expectEqualStrings("add", argv_captured.?[1]);
    try std.testing.expect(std.mem.startsWith(u8, argv_captured.?[2], "magnet:"));
}

test "valid torrent URL is accepted" {
    var argv_captured: ?[]const []const u8 = null;
    const mock = struct {
        var captured: *?[]const []const u8 = undefined;
        fn exec(_: std.mem.Allocator, argv: []const []const u8) anyerror!void {
            captured.* = argv;
        }
    };
    mock.captured = &argv_captured;

    try addLinkWithExecutor(std.testing.allocator, "https://example.com/file.torrent", mock.exec);
    try std.testing.expect(argv_captured != null);
    try std.testing.expectEqualStrings("superseedr", argv_captured.?[0]);
    try std.testing.expectEqualStrings("add", argv_captured.?[1]);
    try std.testing.expect(std.mem.endsWith(u8, argv_captured.?[2], ".torrent"));
}

test "invalid URL returns error" {
    const mock = struct {
        fn exec(_: std.mem.Allocator, argv: []const []const u8) anyerror!void {
            _ = argv;
            unreachable;
        }
    }.exec;

    try std.testing.expectError(error.InvalidLink, addLinkWithExecutor(std.testing.allocator, "https://example.com/file.txt", mock));
}

test "empty URL returns error" {
    const mock = struct {
        fn exec(_: std.mem.Allocator, argv: []const []const u8) anyerror!void {
            _ = argv;
            unreachable;
        }
    }.exec;

    try std.testing.expectError(error.InvalidLink, addLinkWithExecutor(std.testing.allocator, "", mock));
}
