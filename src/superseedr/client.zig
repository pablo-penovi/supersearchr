const std = @import("std");
const debug_log = @import("debug_log");

pub const AddLinkError = error{
    InvalidLink,
    SuperseedrNotFound,
    SuperseedrFailed,
    SuperseedrLaunchFailed,
};

pub const Executor = fn (allocator: std.mem.Allocator, argv: []const []const u8) anyerror!void;

/// Returns true if superseedr is already running.
pub const ProcessChecker = fn (allocator: std.mem.Allocator) anyerror!bool;

/// Spawns superseedr in the background (does not wait for it to exit).
pub const Spawner = fn (allocator: std.mem.Allocator, terminal: []const u8) anyerror!void;

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

pub fn defaultProcessChecker(allocator: std.mem.Allocator) anyerror!bool {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "pgrep", "-x", "superseedr" },
    }) catch return false;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return result.term == .Exited and result.term.Exited == 0;
}

pub fn defaultSpawner(allocator: std.mem.Allocator, terminal: []const u8) anyerror!void {
    var child = std.process.Child.init(&.{ terminal, "-e", "superseedr" }, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    std.Thread.sleep(500 * std.time.ns_per_ms);
}

pub fn addLinkWithAllDeps(
    allocator: std.mem.Allocator,
    link: []const u8,
    terminal: []const u8,
    executor: Executor,
    checker: ProcessChecker,
    spawner: Spawner,
) AddLinkError!void {
    const is_magnet = std.mem.startsWith(u8, link, "magnet:");
    const is_http = std.mem.startsWith(u8, link, "http://") or std.mem.startsWith(u8, link, "https://");
    const is_torrent = std.mem.endsWith(u8, link, ".torrent");
    if (!is_magnet and !is_http and !is_torrent) {
        debug_log.writef(
            allocator,
            "superseedr",
            "Invalid link rejected link=\"{s}\" magnet={any} http={any} torrent_ext={any}",
            .{ link, is_magnet, is_http, is_torrent },
        );
        return error.InvalidLink;
    }

    const running = checker(allocator) catch false;
    if (!running) {
        spawner(allocator, terminal) catch return error.SuperseedrLaunchFailed;
    }

    executor(allocator, &.{ "superseedr", "add", link }) catch |err| switch (err) {
        error.SuperseedrNotFound => return error.SuperseedrNotFound,
        error.SuperseedrFailed => return error.SuperseedrFailed,
        else => return error.SuperseedrFailed,
    };
}

pub fn addLink(allocator: std.mem.Allocator, link: []const u8, terminal: []const u8) AddLinkError!void {
    return addLinkWithAllDeps(allocator, link, terminal, defaultExecutor, defaultProcessChecker, defaultSpawner);
}

pub fn addLinkWithExecutor(allocator: std.mem.Allocator, link: []const u8, terminal: []const u8, executor: Executor) AddLinkError!void {
    return addLinkWithAllDeps(allocator, link, terminal, executor, defaultProcessChecker, defaultSpawner);
}

test "valid magnet URL is accepted" {
    var argv_captured: ?[]const []const u8 = null;
    const mock = struct {
        var captured: *?[]const []const u8 = undefined;
        fn exec(_: std.mem.Allocator, argv: []const []const u8) anyerror!void {
            captured.* = argv;
        }
        fn checker(_: std.mem.Allocator) anyerror!bool {
            return true;
        }
        fn spawner(_: std.mem.Allocator, _: []const u8) anyerror!void {
            unreachable;
        }
    };
    mock.captured = &argv_captured;

    try addLinkWithAllDeps(std.testing.allocator, "magnet:?xt=urn:btih:1234567890", "ghostty", mock.exec, mock.checker, mock.spawner);
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
        fn checker(_: std.mem.Allocator) anyerror!bool {
            return true;
        }
        fn spawner(_: std.mem.Allocator, _: []const u8) anyerror!void {
            unreachable;
        }
    };
    mock.captured = &argv_captured;

    try addLinkWithAllDeps(std.testing.allocator, "https://example.com/file.torrent", "ghostty", mock.exec, mock.checker, mock.spawner);
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
        fn checker(_: std.mem.Allocator) anyerror!bool {
            return true;
        }
        fn spawner(_: std.mem.Allocator, _: []const u8) anyerror!void {
            unreachable;
        }
    };

    try std.testing.expectError(error.InvalidLink, addLinkWithAllDeps(std.testing.allocator, "ftp://example.com/file.txt", "ghostty", mock.exec, mock.checker, mock.spawner));
}

test "empty URL returns error" {
    const mock = struct {
        fn exec(_: std.mem.Allocator, argv: []const []const u8) anyerror!void {
            _ = argv;
            unreachable;
        }
        fn checker(_: std.mem.Allocator) anyerror!bool {
            return true;
        }
        fn spawner(_: std.mem.Allocator, _: []const u8) anyerror!void {
            unreachable;
        }
    };

    try std.testing.expectError(error.InvalidLink, addLinkWithAllDeps(std.testing.allocator, "", "ghostty", mock.exec, mock.checker, mock.spawner));
}

test "valid HTTP URL is accepted" {
    var argv_captured: ?[]const []const u8 = null;
    const mock = struct {
        var captured: *?[]const []const u8 = undefined;
        fn exec(_: std.mem.Allocator, argv: []const []const u8) anyerror!void {
            captured.* = argv;
        }
        fn checker(_: std.mem.Allocator) anyerror!bool {
            return true;
        }
        fn spawner(_: std.mem.Allocator, _: []const u8) anyerror!void {
            unreachable;
        }
    };
    mock.captured = &argv_captured;

    try addLinkWithAllDeps(std.testing.allocator, "https://example.com/download.php?id=7", "ghostty", mock.exec, mock.checker, mock.spawner);
    try std.testing.expect(argv_captured != null);
    try std.testing.expectEqualStrings("https://example.com/download.php?id=7", argv_captured.?[2]);
}

test "superseedr already running - no spawn called" {
    const mock = struct {
        fn exec(_: std.mem.Allocator, argv: []const []const u8) anyerror!void {
            _ = argv;
        }
        fn checker(_: std.mem.Allocator) anyerror!bool {
            return true;
        }
        fn spawner(_: std.mem.Allocator, _: []const u8) anyerror!void {
            unreachable; // must not be called
        }
    };

    try addLinkWithAllDeps(std.testing.allocator, "magnet:?xt=urn:btih:abc", "ghostty", mock.exec, mock.checker, mock.spawner);
}

test "superseedr not running - spawned then add called" {
    const state = struct {
        var spawned: bool = false;
        var added: bool = false;
    };
    state.spawned = false;
    state.added = false;

    const mock = struct {
        fn exec(_: std.mem.Allocator, argv: []const []const u8) anyerror!void {
            _ = argv;
            state.added = true;
        }
        fn checker(_: std.mem.Allocator) anyerror!bool {
            return false;
        }
        fn spawner(_: std.mem.Allocator, _: []const u8) anyerror!void {
            state.spawned = true;
        }
    };

    try addLinkWithAllDeps(std.testing.allocator, "magnet:?xt=urn:btih:abc", "ghostty", mock.exec, mock.checker, mock.spawner);
    try std.testing.expect(state.spawned);
    try std.testing.expect(state.added);
}

test "spawner failure returns SuperseedrLaunchFailed" {
    const mock = struct {
        fn exec(_: std.mem.Allocator, argv: []const []const u8) anyerror!void {
            _ = argv;
            unreachable;
        }
        fn checker(_: std.mem.Allocator) anyerror!bool {
            return false;
        }
        fn spawner(_: std.mem.Allocator, _: []const u8) anyerror!void {
            return error.SomeLaunchError;
        }
    };

    try std.testing.expectError(error.SuperseedrLaunchFailed, addLinkWithAllDeps(std.testing.allocator, "magnet:?xt=urn:btih:abc", "ghostty", mock.exec, mock.checker, mock.spawner));
}
