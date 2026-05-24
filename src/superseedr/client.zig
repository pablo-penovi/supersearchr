const std = @import("std");
const builtin = @import("builtin");
const debug_log = @import("debug_log");
const compat = @import("compat");

pub const AddLinkError = error{
    InvalidLink,
    LinkResolveFailed,
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
    const result = std.process.run(allocator, compat.io(), .{
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
    if (result.term != .exited or result.term.exited != 0) {
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

    const result = std.process.run(allocator, compat.io(), .{
        .argv = argv,
    }) catch return false;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (builtin.os.tag == .windows) {
        if (!(result.term == .exited and result.term.exited == 0)) return false;
        return std.mem.indexOf(u8, result.stdout, "superseedr.exe") != null;
    }
    return result.term == .exited and result.term.exited == 0;
}

pub fn defaultSpawner(allocator: std.mem.Allocator, terminal: []const u8) anyerror!void {
    var argv = try buildSpawnArgv(allocator, terminal);
    defer argv.deinit(allocator);

    const io = compat.io();
    const child = try std.process.spawn(io, spawnerOptions(argv.items));
    const reaper = try std.Thread.spawn(.{}, reapChildWhenDone, .{ child, io });
    reaper.detach();
    compat.sleepMillis(500);
}

fn spawnerOptions(argv: []const []const u8) std.process.SpawnOptions {
    return .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        // Put the launcher in a separate process group to avoid parent-terminal HUP propagation.
        .pgid = if (builtin.os.tag != .windows and builtin.os.tag != .wasi) 0 else null,
    };
}

fn reapChildWhenDone(child: std.process.Child, io: std.Io) void {
    var mutable_child = child;
    _ = mutable_child.wait(io) catch {};
}

fn buildSpawnArgv(allocator: std.mem.Allocator, terminal: []const u8) !std.ArrayList([]const u8) {
    var argv: std.ArrayList([]const u8) = .empty;
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
    const is_torrent = std.mem.endsWith(u8, link, ".torrent");
    if (!is_magnet and !is_torrent) {
        debug_log.writef(
            allocator,
            "superseedr",
            "Invalid final link rejected magnet={any} torrent_ext={any}",
            .{ is_magnet, is_torrent },
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
    var argv_captured: [3][]const u8 = undefined;
    var argv_captured_len: usize = 0;
    const mock = struct {
        var captured: *[3][]const u8 = undefined;
        var captured_len: *usize = undefined;
        fn exec(_: std.mem.Allocator, argv: []const []const u8) anyerror!void {
            captured_len.* = @min(captured.len, argv.len);
            for (argv[0..captured_len.*], 0..) |arg, i| {
                captured.*[i] = arg;
            }
        }
        fn checker(_: std.mem.Allocator) anyerror!bool {
            return true;
        }
        fn spawner(_: std.mem.Allocator, _: []const u8) anyerror!void {
            unreachable;
        }
    };
    mock.captured = &argv_captured;
    mock.captured_len = &argv_captured_len;

    try addLinkWithAllDeps(std.testing.allocator, "magnet:?xt=urn:btih:1234567890", "ghostty", mock.exec, mock.checker, mock.spawner);
    try std.testing.expectEqual(@as(usize, 3), argv_captured_len);
    try std.testing.expectEqualStrings("superseedr", argv_captured[0]);
    try std.testing.expectEqualStrings("add", argv_captured[1]);
    try std.testing.expect(std.mem.startsWith(u8, argv_captured[2], "magnet:"));
}

test "valid torrent path is accepted" {
    var argv_captured: [3][]const u8 = undefined;
    var argv_captured_len: usize = 0;
    const mock = struct {
        var captured: *[3][]const u8 = undefined;
        var captured_len: *usize = undefined;
        fn exec(_: std.mem.Allocator, argv: []const []const u8) anyerror!void {
            captured_len.* = @min(captured.len, argv.len);
            for (argv[0..captured_len.*], 0..) |arg, i| {
                captured.*[i] = arg;
            }
        }
        fn checker(_: std.mem.Allocator) anyerror!bool {
            return true;
        }
        fn spawner(_: std.mem.Allocator, _: []const u8) anyerror!void {
            unreachable;
        }
    };
    mock.captured = &argv_captured;
    mock.captured_len = &argv_captured_len;

    try addLinkWithAllDeps(std.testing.allocator, "/tmp/file.torrent", "ghostty", mock.exec, mock.checker, mock.spawner);
    try std.testing.expectEqual(@as(usize, 3), argv_captured_len);
    try std.testing.expectEqualStrings("superseedr", argv_captured[0]);
    try std.testing.expectEqualStrings("add", argv_captured[1]);
    try std.testing.expect(std.mem.endsWith(u8, argv_captured[2], ".torrent"));
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

test "HTTP URL is rejected as final superseedr input" {
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

    try std.testing.expectError(error.InvalidLink, addLinkWithAllDeps(std.testing.allocator, "https://example.com/download.php?id=7", "ghostty", mock.exec, mock.checker, mock.spawner));
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
    const options = spawnerOptions(&.{"superseedr"});

    try std.testing.expect(options.stdin == .ignore);
    try std.testing.expect(options.stdout == .ignore);
    try std.testing.expect(options.stderr == .ignore);
    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        try std.testing.expect(options.pgid != null);
        try std.testing.expectEqual(@as(std.posix.pid_t, 0), options.pgid.?);
    }
}
