const std = @import("std");

pub const Repo = struct {
    owner: []const u8,
    name: []const u8,
};

pub const UpdateError = error{
    InvalidUrl,
    RequestCreateFailed,
    RequestSendFailed,
    ResponseHeadReadFailed,
    HttpError,
    ResponseReadFailed,
    ParseFailed,
    InvalidVersion,
    OutOfMemory,
};

pub const LatestVersionExecutor = *const fn (allocator: std.mem.Allocator, url: []const u8) UpdateError![]u8;

const Version = struct {
    major: u64,
    minor: u64,
    patch: u64,
};

pub fn defaultLatestVersionExecutor(allocator: std.mem.Allocator, url: []const u8) UpdateError![]u8 {
    var http_client = std.http.Client{ .allocator = allocator };
    defer http_client.deinit();

    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var request = http_client.request(.GET, uri, .{
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "user-agent", .value = "supersearchr" },
            .{ .name = "accept", .value = "application/vnd.github+json" },
        },
    }) catch |err| {
        return mapAnyToUpdateError(err, error.RequestCreateFailed);
    };
    defer request.deinit();

    request.sendBodiless() catch |err| {
        return mapAnyToUpdateError(err, error.RequestSendFailed);
    };

    var header_buf: [1024]u8 = undefined;
    var response = request.receiveHead(&header_buf) catch |err| {
        return mapAnyToUpdateError(err, error.ResponseHeadReadFailed);
    };

    const status = response.head.status;
    if (status != .ok) return error.HttpError;

    var read_buf: [4096]u8 = undefined;
    const reader = response.reader(&read_buf);
    const body = reader.allocRemaining(allocator, .limited(64 * 1024)) catch |err| {
        return mapAnyToUpdateError(err, error.ResponseReadFailed);
    };
    return body;
}

pub fn checkLatestVersion(
    allocator: std.mem.Allocator,
    current_version: []const u8,
    repo: Repo,
    executor: LatestVersionExecutor,
) UpdateError!?[]u8 {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/{s}/releases/latest",
        .{ repo.owner, repo.name },
    );
    defer allocator.free(url);

    const body = try executor(allocator, url);
    defer allocator.free(body);

    const latest_tag = try parseLatestTag(allocator, body);
    errdefer allocator.free(latest_tag);

    const latest_version = try normalizeVersionTag(allocator, latest_tag);
    allocator.free(latest_tag);
    errdefer allocator.free(latest_version);

    if (!try isRemoteNewer(current_version, latest_version)) {
        allocator.free(latest_version);
        return null;
    }

    return latest_version;
}

fn parseLatestTag(allocator: std.mem.Allocator, body: []const u8) UpdateError![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ParseFailed;
    defer parsed.deinit();

    if (parsed.value != .object) return error.ParseFailed;

    const tag_value = parsed.value.object.get("tag_name") orelse return error.ParseFailed;
    const tag = switch (tag_value) {
        .string => |v| v,
        else => return error.ParseFailed,
    };

    return allocator.dupe(u8, tag) catch return error.OutOfMemory;
}

fn normalizeVersionTag(allocator: std.mem.Allocator, raw: []const u8) UpdateError![]u8 {
    var trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidVersion;

    if (trimmed[0] == 'v' or trimmed[0] == 'V') {
        trimmed = trimmed[1..];
    }

    if (trimmed.len == 0) return error.InvalidVersion;
    _ = try parseVersion(trimmed);

    return allocator.dupe(u8, trimmed) catch return error.OutOfMemory;
}

pub fn isRemoteNewer(current: []const u8, remote: []const u8) UpdateError!bool {
    const current_v = try parseVersion(current);
    const remote_v = try parseVersion(remote);

    if (remote_v.major != current_v.major) return remote_v.major > current_v.major;
    if (remote_v.minor != current_v.minor) return remote_v.minor > current_v.minor;
    return remote_v.patch > current_v.patch;
}

fn parseVersion(raw: []const u8) UpdateError!Version {
    var trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidVersion;

    if (trimmed[0] == 'v' or trimmed[0] == 'V') {
        trimmed = trimmed[1..];
    }

    const end = std.mem.indexOfAny(u8, trimmed, "-+") orelse trimmed.len;
    const core = trimmed[0..end];

    var it = std.mem.tokenizeScalar(u8, core, '.');
    const major_s = it.next() orelse return error.InvalidVersion;
    const minor_s = it.next() orelse return error.InvalidVersion;
    const patch_s = it.next() orelse return error.InvalidVersion;
    if (it.next() != null) return error.InvalidVersion;

    const major = std.fmt.parseInt(u64, major_s, 10) catch return error.InvalidVersion;
    const minor = std.fmt.parseInt(u64, minor_s, 10) catch return error.InvalidVersion;
    const patch = std.fmt.parseInt(u64, patch_s, 10) catch return error.InvalidVersion;

    return .{ .major = major, .minor = minor, .patch = patch };
}

fn mapAnyToUpdateError(err: anyerror, fallback: UpdateError) UpdateError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => fallback,
    };
}

test "isRemoteNewer compares semantic versions" {
    try std.testing.expect(try isRemoteNewer("0.3.6", "0.3.7"));
    try std.testing.expect(try isRemoteNewer("0.3.6", "0.4.0"));
    try std.testing.expect(try isRemoteNewer("0.3.6", "1.0.0"));
    try std.testing.expect(!(try isRemoteNewer("0.3.6", "0.3.6")));
    try std.testing.expect(!(try isRemoteNewer("0.3.6", "0.3.5")));
}

test "isRemoteNewer accepts leading v and prerelease metadata" {
    try std.testing.expect(try isRemoteNewer("v0.3.6", "v0.3.7"));
    try std.testing.expect(!(try isRemoteNewer("0.3.6", "v0.3.6-rc1")));
    try std.testing.expect(try isRemoteNewer("0.3.6", "v0.3.7+build.1"));
}

test "checkLatestVersion returns latest when newer" {
    const mock = struct {
        fn exec(allocator: std.mem.Allocator, url: []const u8) UpdateError![]u8 {
            if (!std.mem.eql(
                u8,
                url,
                "https://api.github.com/repos/pablo-penovi/supersearchr/releases/latest",
            )) return error.ParseFailed;
            return allocator.dupe(u8, "{\"tag_name\":\"v0.3.7\"}") catch return error.OutOfMemory;
        }
    };

    const latest = try checkLatestVersion(
        std.testing.allocator,
        "0.3.6",
        .{ .owner = "pablo-penovi", .name = "supersearchr" },
        mock.exec,
    );
    defer if (latest != null) std.testing.allocator.free(latest.?);

    try std.testing.expect(latest != null);
    try std.testing.expectEqualStrings("0.3.7", latest.?);
}

test "checkLatestVersion returns null when equal" {
    const mock = struct {
        fn exec(allocator: std.mem.Allocator, _: []const u8) UpdateError![]u8 {
            return allocator.dupe(u8, "{\"tag_name\":\"0.3.6\"}") catch return error.OutOfMemory;
        }
    };

    const latest = try checkLatestVersion(
        std.testing.allocator,
        "0.3.6",
        .{ .owner = "pablo-penovi", .name = "supersearchr" },
        mock.exec,
    );
    try std.testing.expect(latest == null);
}

test "checkLatestVersion returns parse error for malformed payload" {
    const mock = struct {
        fn exec(allocator: std.mem.Allocator, _: []const u8) UpdateError![]u8 {
            return allocator.dupe(u8, "{}") catch return error.OutOfMemory;
        }
    };

    try std.testing.expectError(
        error.ParseFailed,
        checkLatestVersion(
            std.testing.allocator,
            "0.3.6",
            .{ .owner = "pablo-penovi", .name = "supersearchr" },
            mock.exec,
        ),
    );
}
