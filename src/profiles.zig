const std = @import("std");
const compat = @import("compat");
const config = @import("config");

/// A named set of indexer IDs that should be enabled (all others disabled).
pub const Profile = struct {
    name: []u8,
    indexers: std.ArrayList([]u8),

    fn deinit(self: *Profile, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.indexers.items) |id| allocator.free(id);
        self.indexers.deinit(allocator);
        self.* = undefined;
    }
};

/// In-memory store of tracker profiles plus the currently-active profile name.
/// Insertion order of profiles is preserved.
pub const ProfileStore = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(Profile),
    active: ?[]u8,

    pub fn init(allocator: std.mem.Allocator) ProfileStore {
        return .{
            .allocator = allocator,
            .list = .empty,
            .active = null,
        };
    }

    pub fn deinit(self: *ProfileStore) void {
        for (self.list.items) |*p| p.deinit(self.allocator);
        self.list.deinit(self.allocator);
        if (self.active) |a| self.allocator.free(a);
        self.active = null;
    }

    pub fn count(self: *const ProfileStore) usize {
        return self.list.items.len;
    }

    /// Returns a pointer to the profile named `name`, or null. The pointer is
    /// invalidated by any subsequent `upsert`/`remove` that mutates the list.
    pub fn get(self: *const ProfileStore, name: []const u8) ?*Profile {
        for (self.list.items) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    /// Creates or overwrites the profile named `name` with `ids`. All strings
    /// are duplicated into the store's allocator.
    pub fn upsert(self: *ProfileStore, name: []const u8, ids: []const []const u8) !void {
        if (self.get(name)) |p| {
            for (p.indexers.items) |id| self.allocator.free(id);
            p.indexers.clearRetainingCapacity();
            for (ids) |id| {
                const dup = try self.allocator.dupe(u8, id);
                errdefer self.allocator.free(dup);
                try p.indexers.append(self.allocator, dup);
            }
            return;
        }

        var profile = Profile{
            .name = try self.allocator.dupe(u8, name),
            .indexers = .empty,
        };
        errdefer profile.deinit(self.allocator);
        for (ids) |id| {
            const dup = try self.allocator.dupe(u8, id);
            errdefer self.allocator.free(dup);
            try profile.indexers.append(self.allocator, dup);
        }
        try self.list.append(self.allocator, profile);
    }

    /// Removes the profile named `name` (no-op if absent). Clears the active
    /// profile if it was the removed one.
    pub fn remove(self: *ProfileStore, name: []const u8) void {
        for (self.list.items, 0..) |*p, i| {
            if (std.mem.eql(u8, p.name, name)) {
                if (self.active) |a| {
                    if (std.mem.eql(u8, a, name)) {
                        self.allocator.free(a);
                        self.active = null;
                    }
                }
                var removed = self.list.orderedRemove(i);
                removed.deinit(self.allocator);
                return;
            }
        }
    }

    pub fn setActive(self: *ProfileStore, name: ?[]const u8) !void {
        const new_active = if (name) |n| try self.allocator.dupe(u8, n) else null;
        if (self.active) |a| self.allocator.free(a);
        self.active = new_active;
    }

    /// Returns the profile names in insertion order. The outer slice is owned
    /// by the caller (free it); each name slice is borrowed from the store.
    pub fn names(self: *const ProfileStore, allocator: std.mem.Allocator) ![][]const u8 {
        const out = try allocator.alloc([]const u8, self.list.items.len);
        for (self.list.items, 0..) |p, i| out[i] = p.name;
        return out;
    }
};

/// Order-independent equality of two ID sets (assumes no duplicates within a set).
pub fn setsEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a) |x| {
        if (!contains(b, x)) return false;
    }
    return true;
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

/// The set of toggles needed to make Jackett's enabled set match a profile.
/// String slices are borrowed from the inputs; the caller must keep
/// `profile_ids`/`enabled_ids` alive while using the plan.
pub const ApplyPlan = struct {
    to_enable: [][]const u8,
    to_disable: [][]const u8,

    pub fn deinit(self: *ApplyPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.to_enable);
        allocator.free(self.to_disable);
        self.* = undefined;
    }
};

pub fn applyPlan(
    allocator: std.mem.Allocator,
    profile_ids: []const []const u8,
    enabled_ids: []const []const u8,
) !ApplyPlan {
    var enable_list: std.ArrayList([]const u8) = .empty;
    errdefer enable_list.deinit(allocator);
    var disable_list: std.ArrayList([]const u8) = .empty;
    errdefer disable_list.deinit(allocator);

    for (profile_ids) |id| {
        if (!contains(enabled_ids, id)) try enable_list.append(allocator, id);
    }
    for (enabled_ids) |id| {
        if (!contains(profile_ids, id)) try disable_list.append(allocator, id);
    }

    return .{
        .to_enable = try enable_list.toOwnedSlice(allocator),
        .to_disable = try disable_list.toOwnedSlice(allocator),
    };
}

pub fn defaultProfilesPath(allocator: std.mem.Allocator) ![]u8 {
    const config_dir = try config.getConfigDir(allocator);
    defer allocator.free(config_dir);
    return std.fs.path.join(allocator, &.{ config_dir, "supersearchr", "profiles.json" });
}

const ProfilesJson = struct {
    active: ?[]const u8 = null,
    profiles: std.json.ArrayHashMap([]const []const u8) = .{},
};

/// Loads the store from disk. A missing file or any parse failure yields an
/// empty store so a corrupt profiles.json never blocks the screens.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !ProfileStore {
    var store = ProfileStore.init(allocator);
    errdefer store.deinit();

    const io = compat.io();
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return store;
    defer compat.closeFile(file);

    var file_reader = file.reader(io, &.{});
    const contents = file_reader.interface.allocRemaining(allocator, .unlimited) catch return store;
    defer allocator.free(contents);

    var parsed = std.json.parseFromSlice(ProfilesJson, allocator, contents, .{ .ignore_unknown_fields = true }) catch return store;
    defer parsed.deinit();

    var it = parsed.value.profiles.map.iterator();
    while (it.next()) |entry| {
        store.upsert(entry.key_ptr.*, entry.value_ptr.*) catch continue;
    }

    if (parsed.value.active) |active_name| {
        if (store.get(active_name) != null) {
            store.setActive(active_name) catch {};
        }
    }

    return store;
}

pub fn save(allocator: std.mem.Allocator, path: []const u8, store: *const ProfileStore) !void {
    var hashmap: std.json.ArrayHashMap([]const []const u8) = .{};
    defer hashmap.map.deinit(allocator);

    for (store.list.items) |*p| {
        try hashmap.map.put(allocator, p.name, p.indexers.items);
    }

    const root = ProfilesJson{ .active = store.active, .profiles = hashmap };
    const json = try std.json.Stringify.valueAlloc(allocator, root, .{ .whitespace = .indent_2 });
    defer allocator.free(json);

    const dir = std.fs.path.dirname(path) orelse ".";
    const io = compat.io();
    try std.Io.Dir.cwd().createDirPath(io, dir);

    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer compat.closeFile(file);
    try compat.writeFileAll(file, json);
}

fn tmpProfilesPath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const dir_abs = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(dir_abs);
    return std.fs.path.join(allocator, &.{ dir_abs, "profiles.json" });
}

test "upsert creates and overwrites profiles" {
    var store = ProfileStore.init(std.testing.allocator);
    defer store.deinit();

    try store.upsert("Anime", &.{ "nyaa", "anidex" });
    try std.testing.expectEqual(@as(usize, 1), store.count());

    const p = store.get("Anime").?;
    try std.testing.expectEqual(@as(usize, 2), p.indexers.items.len);
    try std.testing.expectEqualStrings("nyaa", p.indexers.items[0]);

    try store.upsert("Anime", &.{"nyaa"});
    try std.testing.expectEqual(@as(usize, 1), store.count());
    try std.testing.expectEqual(@as(usize, 1), store.get("Anime").?.indexers.items.len);
}

test "remove deletes and clears active when it was removed" {
    var store = ProfileStore.init(std.testing.allocator);
    defer store.deinit();

    try store.upsert("A", &.{"x"});
    try store.upsert("B", &.{"y"});
    try store.setActive("A");

    store.remove("A");
    try std.testing.expectEqual(@as(usize, 1), store.count());
    try std.testing.expect(store.active == null);
    try std.testing.expect(store.get("A") == null);

    store.remove("B");
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "remove of non-active profile keeps active" {
    var store = ProfileStore.init(std.testing.allocator);
    defer store.deinit();

    try store.upsert("A", &.{"x"});
    try store.upsert("B", &.{"y"});
    try store.setActive("A");

    store.remove("B");
    try std.testing.expect(store.active != null);
    try std.testing.expectEqualStrings("A", store.active.?);
}

test "setActive replaces and clears" {
    var store = ProfileStore.init(std.testing.allocator);
    defer store.deinit();

    try store.setActive("A");
    try std.testing.expectEqualStrings("A", store.active.?);
    try store.setActive("B");
    try std.testing.expectEqualStrings("B", store.active.?);
    try store.setActive(null);
    try std.testing.expect(store.active == null);
}

test "names returns insertion order" {
    var store = ProfileStore.init(std.testing.allocator);
    defer store.deinit();

    try store.upsert("First", &.{});
    try store.upsert("Second", &.{});

    const ns = try store.names(std.testing.allocator);
    defer std.testing.allocator.free(ns);
    try std.testing.expectEqual(@as(usize, 2), ns.len);
    try std.testing.expectEqualStrings("First", ns[0]);
    try std.testing.expectEqualStrings("Second", ns[1]);
}

test "setsEqual is order independent" {
    try std.testing.expect(setsEqual(&.{ "a", "b" }, &.{ "b", "a" }));
    try std.testing.expect(setsEqual(&.{}, &.{}));
    try std.testing.expect(!setsEqual(&.{"a"}, &.{ "a", "b" }));
    try std.testing.expect(!setsEqual(&.{ "a", "c" }, &.{ "a", "b" }));
}

test "applyPlan computes enable and disable deltas" {
    var plan = try applyPlan(std.testing.allocator, &.{ "a", "b", "c" }, &.{ "b", "d" });
    defer plan.deinit(std.testing.allocator);

    // Enable: in profile but not enabled -> a, c
    try std.testing.expectEqual(@as(usize, 2), plan.to_enable.len);
    try std.testing.expectEqualStrings("a", plan.to_enable[0]);
    try std.testing.expectEqualStrings("c", plan.to_enable[1]);

    // Disable: enabled but not in profile -> d
    try std.testing.expectEqual(@as(usize, 1), plan.to_disable.len);
    try std.testing.expectEqualStrings("d", plan.to_disable[0]);
}

test "applyPlan empty when sets already match" {
    var plan = try applyPlan(std.testing.allocator, &.{ "a", "b" }, &.{ "b", "a" });
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), plan.to_enable.len);
    try std.testing.expectEqual(@as(usize, 0), plan.to_disable.len);
}

test "save then load round-trips profiles and active" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpProfilesPath(allocator, &tmp);
    defer allocator.free(path);

    {
        var store = ProfileStore.init(allocator);
        defer store.deinit();
        try store.upsert("Anime", &.{"nyaa"});
        try store.upsert("Movies", &.{ "1337x", "yts" });
        try store.setActive("Anime");
        try save(allocator, path, &store);
    }

    var loaded = try load(allocator, path);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.count());
    try std.testing.expectEqualStrings("Anime", loaded.active.?);
    try std.testing.expectEqualStrings("nyaa", loaded.get("Anime").?.indexers.items[0]);
    const movies = loaded.get("Movies").?;
    try std.testing.expectEqual(@as(usize, 2), movies.indexers.items.len);
}

test "load tolerates a missing file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpProfilesPath(allocator, &tmp);
    defer allocator.free(path);

    var store = try load(allocator, path);
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "load tolerates corrupt JSON" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpProfilesPath(allocator, &tmp);
    defer allocator.free(path);

    const io = compat.io();
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    try compat.writeFileAll(file, "{ not valid json ]");
    compat.closeFile(file);

    var store = try load(allocator, path);
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "load drops active that references a missing profile" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpProfilesPath(allocator, &tmp);
    defer allocator.free(path);

    const io = compat.io();
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    try compat.writeFileAll(file, "{\"active\":\"Ghost\",\"profiles\":{\"Real\":[\"x\"]}}");
    compat.closeFile(file);

    var store = try load(allocator, path);
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, 1), store.count());
    try std.testing.expect(store.active == null);
}
