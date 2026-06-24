const std = @import("std");
const compat = @import("compat");
const config = @import("config");

/// In-memory store of the most recent commit outcome per indexer. Each value
/// is `true` (the last enable/disable attempt succeeded) or `false` (it
/// failed). An absent key means no commit has ever been attempted, so the
/// Indexers screen leaves the Last Status column blank.
pub const StatusStore = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(bool),

    pub fn init(allocator: std.mem.Allocator) StatusStore {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(bool).init(allocator),
        };
    }

    pub fn deinit(self: *StatusStore) void {
        var it = self.map.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.map.deinit();
    }

    /// Returns the last recorded outcome for `indexer_id`, or `null` if no
    /// commit has ever been attempted for it.
    pub fn get(self: *const StatusStore, indexer_id: []const u8) ?bool {
        return self.map.get(indexer_id);
    }

    /// Records the latest commit outcome for `indexer_id`, overwriting any
    /// previous value.
    pub fn set(self: *StatusStore, indexer_id: []const u8, success: bool) !void {
        if (self.map.getPtr(indexer_id)) |value| {
            value.* = success;
            return;
        }
        const key_copy = try self.allocator.dupe(u8, indexer_id);
        errdefer self.allocator.free(key_copy);
        try self.map.put(key_copy, success);
    }
};

pub fn defaultStatusPath(allocator: std.mem.Allocator) ![]u8 {
    const config_dir = try config.getConfigDir(allocator);
    defer allocator.free(config_dir);
    return std.fs.path.join(allocator, &.{ config_dir, "supersearchr", "last_status.json" });
}

/// Loads the store from disk. A missing file or any parse failure yields an
/// empty store so a corrupt last_status.json never blocks the Indexers screen.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !StatusStore {
    var store = StatusStore.init(allocator);
    errdefer store.deinit();

    const io = compat.io();
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return store;
    defer compat.closeFile(file);

    var file_reader = file.reader(io, &.{});
    const contents = file_reader.interface.allocRemaining(allocator, .unlimited) catch return store;
    defer allocator.free(contents);

    var parsed = std.json.parseFromSlice(std.json.ArrayHashMap(bool), allocator, contents, .{}) catch return store;
    defer parsed.deinit();

    var it = parsed.value.map.iterator();
    while (it.next()) |entry| {
        store.set(entry.key_ptr.*, entry.value_ptr.*) catch continue;
    }

    return store;
}

pub fn save(allocator: std.mem.Allocator, path: []const u8, store: *const StatusStore) !void {
    var hashmap: std.json.ArrayHashMap(bool) = .{};
    defer hashmap.map.deinit(allocator);

    var it = store.map.iterator();
    while (it.next()) |entry| {
        try hashmap.map.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    }

    const json = try std.json.Stringify.valueAlloc(allocator, hashmap, .{ .whitespace = .indent_2 });
    defer allocator.free(json);

    const dir = std.fs.path.dirname(path) orelse ".";
    const io = compat.io();
    try std.Io.Dir.cwd().createDirPath(io, dir);

    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer compat.closeFile(file);
    try compat.writeFileAll(file, json);
}

/// Loads, records the latest outcome for each succeeded/failed indexer id,
/// saves, and cleans up. Intended to be called best-effort after a commit.
pub fn updateAfterCommit(
    allocator: std.mem.Allocator,
    path: []const u8,
    succeeded: []const []const u8,
    failed: []const []const u8,
) !void {
    var store = load(allocator, path) catch StatusStore.init(allocator);
    defer store.deinit();

    for (succeeded) |id| try store.set(id, true);
    for (failed) |id| try store.set(id, false);

    try save(allocator, path, &store);
}

fn tmpStatusPath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const dir_abs = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(dir_abs);
    return std.fs.path.join(allocator, &.{ dir_abs, "last_status.json" });
}

test "set then get returns the latest outcome" {
    var store = StatusStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(?bool, null), store.get("a"));

    try store.set("a", true);
    try std.testing.expectEqual(@as(?bool, true), store.get("a"));

    try store.set("a", false);
    try std.testing.expectEqual(@as(?bool, false), store.get("a"));
}

test "get on unknown id returns null" {
    var store = StatusStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(?bool, null), store.get("missing"));
}

test "save then load round-trips entries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpStatusPath(allocator, &tmp);
    defer allocator.free(path);

    {
        var store = StatusStore.init(allocator);
        defer store.deinit();
        try store.set("alpha", true);
        try store.set("beta", false);
        try save(allocator, path, &store);
    }

    var loaded = try load(allocator, path);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(?bool, true), loaded.get("alpha"));
    try std.testing.expectEqual(@as(?bool, false), loaded.get("beta"));
    try std.testing.expectEqual(@as(?bool, null), loaded.get("gamma"));
}

test "load tolerates a missing file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpStatusPath(allocator, &tmp);
    defer allocator.free(path);

    var store = try load(allocator, path);
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, 0), store.map.count());
}

test "load tolerates corrupt JSON" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpStatusPath(allocator, &tmp);
    defer allocator.free(path);

    const io = compat.io();
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    try compat.writeFileAll(file, "{ this is not json ]");
    compat.closeFile(file);

    var store = try load(allocator, path);
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, 0), store.map.count());
}

test "updateAfterCommit records succeeded and failed ids, latest wins" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpStatusPath(allocator, &tmp);
    defer allocator.free(path);

    try updateAfterCommit(allocator, path, &.{"ok"}, &.{"bad"});
    // A later commit flips "bad" to success and "ok" to failure.
    try updateAfterCommit(allocator, path, &.{"bad"}, &.{"ok"});

    var store = try load(allocator, path);
    defer store.deinit();
    try std.testing.expectEqual(@as(?bool, false), store.get("ok"));
    try std.testing.expectEqual(@as(?bool, true), store.get("bad"));
}
