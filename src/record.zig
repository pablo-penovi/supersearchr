const std = @import("std");
const compat = @import("compat");
const config = @import("config");

/// Maximum number of search outcomes retained per indexer (oldest dropped first).
pub const max_entries: usize = 5;

/// In-memory store of per-indexer search outcomes. Each value is a list of
/// 0/1 bytes (0 = failed, 1 = succeeded), oldest-first, capped at `max_entries`.
pub const RecordStore = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(std.ArrayList(u8)),

    pub fn init(allocator: std.mem.Allocator) RecordStore {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(std.ArrayList(u8)).init(allocator),
        };
    }

    pub fn deinit(self: *RecordStore) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.map.deinit();
    }

    /// Returns the recorded outcomes for `indexer_id` (oldest-first), or an
    /// empty slice if the indexer has never been searched.
    pub fn get(self: *const RecordStore, indexer_id: []const u8) []const u8 {
        if (self.map.get(indexer_id)) |list| return list.items;
        return &.{};
    }

    /// Appends a new outcome for `indexer_id`. Evicts the oldest entry first
    /// when already at `max_entries` (FIFO).
    pub fn recordResult(self: *RecordStore, indexer_id: []const u8, success: bool) !void {
        const byte: u8 = if (success) 1 else 0;

        if (self.map.getPtr(indexer_id)) |list| {
            if (list.items.len >= max_entries) _ = list.orderedRemove(0);
            try list.append(self.allocator, byte);
            return;
        }

        const key_copy = try self.allocator.dupe(u8, indexer_id);
        errdefer self.allocator.free(key_copy);
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(self.allocator);
        try list.append(self.allocator, byte);
        try self.map.put(key_copy, list);
    }
};

pub fn defaultRecordPath(allocator: std.mem.Allocator) ![]u8 {
    const config_dir = try config.getConfigDir(allocator);
    defer allocator.free(config_dir);
    return std.fs.path.join(allocator, &.{ config_dir, "supersearchr", "record.json" });
}

/// Loads the store from disk. A missing file or any parse failure yields an
/// empty store so a corrupt record.json never blocks the Indexers screen.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !RecordStore {
    var store = RecordStore.init(allocator);
    errdefer store.deinit();

    const io = compat.io();
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return store;
    defer compat.closeFile(file);

    var file_reader = file.reader(io, &.{});
    const contents = file_reader.interface.allocRemaining(allocator, .unlimited) catch return store;
    defer allocator.free(contents);

    var parsed = std.json.parseFromSlice(std.json.ArrayHashMap([]const i64), allocator, contents, .{}) catch return store;
    defer parsed.deinit();

    var it = parsed.value.map.iterator();
    while (it.next()) |entry| {
        const values = entry.value_ptr.*;
        // Defensively keep only the most recent `max_entries` outcomes.
        const start: usize = if (values.len > max_entries) values.len - max_entries else 0;

        var list: std.ArrayList(u8) = .empty;
        var ok = true;
        for (values[start..]) |v| {
            const byte: u8 = if (v != 0) 1 else 0;
            list.append(allocator, byte) catch {
                ok = false;
                break;
            };
        }
        if (!ok) {
            list.deinit(allocator);
            continue;
        }

        const key_copy = allocator.dupe(u8, entry.key_ptr.*) catch {
            list.deinit(allocator);
            continue;
        };
        store.map.put(key_copy, list) catch {
            allocator.free(key_copy);
            list.deinit(allocator);
        };
    }

    return store;
}

pub fn save(allocator: std.mem.Allocator, path: []const u8, store: *const RecordStore) !void {
    var hashmap: std.json.ArrayHashMap([]const i64) = .{};
    defer {
        for (hashmap.map.values()) |arr| allocator.free(arr);
        hashmap.map.deinit(allocator);
    }

    var it = store.map.iterator();
    while (it.next()) |entry| {
        const items = entry.value_ptr.items;
        const arr = try allocator.alloc(i64, items.len);
        errdefer allocator.free(arr);
        for (items, 0..) |b, i| arr[i] = b;
        try hashmap.map.put(allocator, entry.key_ptr.*, arr);
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

/// Loads, records outcomes for each succeeded/failed indexer id, saves, and
/// cleans up. Intended to be called best-effort after a search completes.
pub fn updateAfterSearch(
    allocator: std.mem.Allocator,
    path: []const u8,
    succeeded: []const []const u8,
    failed: []const []const u8,
) !void {
    var store = load(allocator, path) catch RecordStore.init(allocator);
    defer store.deinit();

    for (succeeded) |id| try store.recordResult(id, true);
    for (failed) |id| try store.recordResult(id, false);

    try save(allocator, path, &store);
}

fn tmpRecordPath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const dir_abs = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(dir_abs);
    return std.fs.path.join(allocator, &.{ dir_abs, "record.json" });
}

test "recordResult appends under capacity, oldest-first" {
    var store = RecordStore.init(std.testing.allocator);
    defer store.deinit();

    try store.recordResult("a", true);
    try store.recordResult("a", false);
    try store.recordResult("a", true);

    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 1 }, store.get("a"));
}

test "recordResult evicts oldest at capacity (FIFO)" {
    var store = RecordStore.init(std.testing.allocator);
    defer store.deinit();

    // Fill to capacity with successes, then push two failures.
    var i: usize = 0;
    while (i < max_entries) : (i += 1) try store.recordResult("a", true);
    try store.recordResult("a", false);
    try store.recordResult("a", false);

    const items = store.get("a");
    try std.testing.expectEqual(max_entries, items.len);
    // Two oldest 1s dropped; newest two are 0s.
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1, 0, 0 }, items);
}

test "get on unknown id returns empty slice" {
    var store = RecordStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(usize, 0), store.get("missing").len);
}

test "save then load round-trips entries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpRecordPath(allocator, &tmp);
    defer allocator.free(path);

    {
        var store = RecordStore.init(allocator);
        defer store.deinit();
        try store.recordResult("alpha", true);
        try store.recordResult("alpha", false);
        try store.recordResult("beta", true);
        try save(allocator, path, &store);
    }

    var loaded = try load(allocator, path);
    defer loaded.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 1, 0 }, loaded.get("alpha"));
    try std.testing.expectEqualSlices(u8, &.{1}, loaded.get("beta"));
}

test "load tolerates a missing file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpRecordPath(allocator, &tmp);
    defer allocator.free(path);

    var store = try load(allocator, path);
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, 0), store.map.count());
}

test "load tolerates corrupt JSON" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpRecordPath(allocator, &tmp);
    defer allocator.free(path);

    const io = compat.io();
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    try compat.writeFileAll(file, "{ this is not json ]");
    compat.closeFile(file);

    var store = try load(allocator, path);
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, 0), store.map.count());
}

test "updateAfterSearch records succeeded and failed ids" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpRecordPath(allocator, &tmp);
    defer allocator.free(path);

    try updateAfterSearch(allocator, path, &.{ "ok1", "ok2" }, &.{"bad"});
    try updateAfterSearch(allocator, path, &.{"ok1"}, &.{"bad"});

    var store = try load(allocator, path);
    defer store.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 1, 1 }, store.get("ok1"));
    try std.testing.expectEqualSlices(u8, &.{1}, store.get("ok2"));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, store.get("bad"));
}
