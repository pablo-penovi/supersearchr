const std = @import("std");
const builtin = @import("builtin");
const debug_log = @import("debug_log");

pub const AddLinkError = error{
    InvalidLink,
    SuperseedrNotFound,
    SuperseedrFailed,
    SuperseedrLaunchFailed,
};

pub const Executor = *const fn (allocator: std.mem.Allocator, argv: []const []const u8) anyerror!void;

/// Returns true if superseedr is already running.
pub const ProcessChecker = *const fn (allocator: std.mem.Allocator) anyerror!bool;

/// Spawns superseedr in the background (does not wait for it to exit).
pub const Spawner = *const fn (allocator: std.mem.Allocator, terminal: []const u8) anyerror!void;

pub fn defaultExecutor(allocator: std.mem.Allocator, argv: []const []const u8) anyerror!void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    }) catch |err| {
        debug_log.writef(
            allocator,
            "superseedr",
            "Failed to invoke command err={s} cmd=\"{s}\"",
            .{ @errorName(err), argv[0] },
        );
        return error.SuperseedrNotFound;
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    if (result.term != .Exited or result.term.Exited != 0) {
        debug_log.writef(
            allocator,
            "superseedr",
            "Command failed term={any} stderr=\"{s}\"",
            .{ result.term, result.stderr },
        );
        return error.SuperseedrFailed;
    }
}

pub fn defaultProcessChecker(allocator: std.mem.Allocator) anyerror!bool {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{ "tasklist", "/FI", "IMAGENAME eq superseedr.exe" },
        else => &.{ "pgrep", "-x", "superseedr" },
    };

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    }) catch return false;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (builtin.os.tag == .windows) {
        if (!(result.term == .Exited and result.term.Exited == 0)) return false;
        return std.mem.indexOf(u8, result.stdout, "superseedr.exe") != null;
    }
    return result.term == .Exited and result.term.Exited == 0;
}

pub fn defaultSpawner(allocator: std.mem.Allocator, terminal: []const u8) anyerror!void {
    var argv = try buildSpawnArgv(allocator, terminal);
    defer argv.deinit(allocator);

    var child = std.process.Child.init(argv.items, allocator);
    configureSpawnerChild(&child);
    try child.spawn();
    const reaper = try std.Thread.spawn(.{}, reapChildWhenDone, .{child});
    reaper.detach();
    std.Thread.sleep(500 * std.time.ns_per_ms);
}

fn configureSpawnerChild(child: *std.process.Child) void {
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        // Put the launcher in a separate process group to avoid parent-terminal HUP propagation.
        child.pgid = 0;
    }
}

fn reapChildWhenDone(child: std.process.Child) void {
    var mutable_child = child;
    _ = mutable_child.wait() catch {};
}

fn buildSpawnArgv(allocator: std.mem.Allocator, terminal: []const u8) !std.ArrayList([]const u8) {
    var argv: std.ArrayList([]const u8) = .{};
    errdefer argv.deinit(allocator);

    switch (builtin.os.tag) {
        .windows => {
            if (std.mem.eql(u8, terminal, "wt")) {
                try argv.append(allocator, "wt");
                try argv.append(allocator, "-w");
                try argv.append(allocator, "new");
                try argv.append(allocator, "new-tab");
                try argv.append(allocator, "superseedr");
                return argv;
            }

            try argv.append(allocator, "cmd");
            try argv.append(allocator, "/c");
            try argv.append(allocator, "start");
            try argv.append(allocator, "");
            try argv.append(allocator, terminal);
            try argv.append(allocator, "superseedr");
            return argv;
        },
        .macos => {
            if (std.mem.eql(u8, terminal, "Terminal")) {
                try argv.append(allocator, "osascript");
                try argv.append(allocator, "-e");
                try argv.append(allocator, "tell application \"Terminal\" to do script \"superseedr\"");
                try argv.append(allocator, "-e");
                try argv.append(allocator, "tell application \"Terminal\" to activate");
                return argv;
            }
        },
        else => {},
    }

    try argv.append(allocator, terminal);
    if (std.mem.eql(u8, terminal, "gnome-terminal")) {
        try argv.append(allocator, "--");
    } else {
        try argv.append(allocator, "-e");
    }
    try argv.append(allocator, "superseedr");
    return argv;
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

    const running = checker(allocator) catch |err| blk: {
        debug_log.writef(
            allocator,
            "superseedr",
            "Failed to check running process err={s}; assuming not running",
            .{@errorName(err)},
        );
        break :blk false;
    };
    if (!running) {
        spawner(allocator, terminal) catch |err| {
            debug_log.writef(
                allocator,
                "superseedr",
                "Failed to spawn superseedr err={s} terminal=\"{s}\"",
                .{ @errorName(err), terminal },
            );
            return error.SuperseedrLaunchFailed;
        };
    }

    executor(allocator, &.{ "superseedr", "add", link }) catch |err| switch (err) {
        error.SuperseedrNotFound => {
            debug_log.writef(
                allocator,
                "superseedr",
                "superseedr add failed err={s} link=\"{s}\"",
                .{ @errorName(err), link },
            );
            return error.SuperseedrNotFound;
        },
        error.SuperseedrFailed => {
            debug_log.writef(
                allocator,
                "superseedr",
                "superseedr add failed err={s} link=\"{s}\"",
                .{ @errorName(err), link },
            );
            return error.SuperseedrFailed;
        },
        else => {
            debug_log.writef(
                allocator,
                "superseedr",
                "superseedr add failed with unexpected error err={s} link=\"{s}\"",
                .{ @errorName(err), link },
            );
            return error.SuperseedrFailed;
        },
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

test "buildSpawnArgv uses standard -e mode on unix terminals" {
    if (builtin.os.tag == .windows or builtin.os.tag == .macos) return error.SkipZigTest;

    var argv = try buildSpawnArgv(std.testing.allocator, "ghostty");
    defer argv.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), argv.items.len);
    try std.testing.expectEqualStrings("ghostty", argv.items[0]);
    try std.testing.expectEqualStrings("-e", argv.items[1]);
    try std.testing.expectEqualStrings("superseedr", argv.items[2]);
}

test "buildSpawnArgv uses -- mode for gnome-terminal" {
    if (builtin.os.tag == .windows or builtin.os.tag == .macos) return error.SkipZigTest;

    var argv = try buildSpawnArgv(std.testing.allocator, "gnome-terminal");
    defer argv.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), argv.items.len);
    try std.testing.expectEqualStrings("gnome-terminal", argv.items[0]);
    try std.testing.expectEqualStrings("--", argv.items[1]);
    try std.testing.expectEqualStrings("superseedr", argv.items[2]);
}

test "configureSpawnerChild sets detached spawn behaviors" {
    var child = std.process.Child.init(&.{"superseedr"}, std.testing.allocator);
    configureSpawnerChild(&child);

    try std.testing.expect(child.stdin_behavior == .Ignore);
    try std.testing.expect(child.stdout_behavior == .Ignore);
    try std.testing.expect(child.stderr_behavior == .Ignore);
    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        try std.testing.expect(child.pgid != null);
        try std.testing.expectEqual(@as(std.posix.pid_t, 0), child.pgid.?);
    }
}
