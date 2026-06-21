const std = @import("std");
const compat = @import("compat");
const config = @import("config");
const http_exec = @import("http_exec");
const url_encode = @import("url_encode");
const debug_log = @import("debug_log");

pub const AdminError = error{
    InvalidUrl,
    ConnectionRefused,
    RequestCreateFailed,
    RequestSendFailed,
    ResponseHeadReadFailed,
    HttpError,
    ResponseReadFailed,
    ParseFailed,
    LoginFailed,
    NoSessionCookie,
    OutOfMemory,
};

pub const HttpMethod = enum { get, post, delete };

pub const Header = http_exec.HeaderPair;

pub const AdminRequest = struct {
    method: HttpMethod,
    url: []const u8,
    headers: []const Header = &.{},
    body: ?[]const u8 = null,
    content_type: []const u8 = "application/json",
};

pub const AdminResponse = struct {
    status: std.http.Status,
    body: []u8 = &.{},
    set_cookie: ?[]u8 = null,

    pub fn deinit(self: *AdminResponse, allocator: std.mem.Allocator) void {
        if (self.body.len != 0) allocator.free(self.body);
        if (self.set_cookie) |c| allocator.free(c);
        self.* = undefined;
    }
};

pub const AdminExecutor = *const fn (
    allocator: std.mem.Allocator,
    request: AdminRequest,
) AdminError!AdminResponse;

pub fn defaultAdminExecutor(allocator: std.mem.Allocator, request: AdminRequest) AdminError!AdminResponse {
    const method: std.http.Method = switch (request.method) {
        .get => .GET,
        .post => .POST,
        .delete => .DELETE,
    };

    const raw = try http_exec.execute(allocator, request.url, .{
        .method = method,
        .extra_headers = request.headers,
        .body = request.body,
        .content_type = request.content_type,
        // Jackett's login endpoints always respond with a 3xx (success or
        // failure) and the HTTP client has no cookie jar, so blindly
        // following redirects strands us on an unrelated endpoint several
        // hops away. The admin layer needs to inspect each response itself.
        .follow_redirects = false,
    }, "jackett-admin");

    var set_cookie: ?[]u8 = null;
    for (raw.response_headers) |h| {
        if (set_cookie == null and std.ascii.eqlIgnoreCase(h.name, "Set-Cookie")) {
            set_cookie = allocator.dupe(u8, h.value) catch |err| {
                http_exec.freeHeaderPairs(allocator, raw.response_headers);
                allocator.free(raw.body);
                return err;
            };
        }
    }
    http_exec.freeHeaderPairs(allocator, raw.response_headers);

    return .{ .status = raw.status, .body = raw.body, .set_cookie = set_cookie };
}

pub const AdminSession = struct {
    cookie: []u8,

    pub fn deinit(self: *AdminSession, allocator: std.mem.Allocator) void {
        allocator.free(self.cookie);
        self.* = undefined;
    }
};

fn firstCookiePair(raw: []const u8) []const u8 {
    const semi = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
    return std.mem.trim(u8, raw[0..semi], " ");
}

pub fn login(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    admin_password: []const u8,
    executor: AdminExecutor,
) AdminError!AdminSession {
    if (admin_password.len == 0) {
        return loginPasswordless(allocator, base_url, executor);
    }
    return loginWithPassword(allocator, base_url, admin_password, executor);
}

/// Jackett's `POST /UI/Dashboard` (see `WebUIController.Dashboard`) always
/// responds with a 302 to `/UI/Dashboard` regardless of outcome: on a
/// correct password it signs in first (Set-Cookie: Jackett=...) and then
/// redirects; on a wrong password it just redirects. So success/failure is
/// determined purely by whether a Set-Cookie came back, not by status code.
fn loginWithPassword(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    admin_password: []const u8,
    executor: AdminExecutor,
) AdminError!AdminSession {
    const encoded_password = try url_encode.percentEncode(allocator, admin_password);
    defer allocator.free(encoded_password);
    const body = try std.fmt.allocPrint(allocator, "password={s}", .{encoded_password});
    defer allocator.free(body);
    const url = try std.fmt.allocPrint(allocator, "{s}/UI/Dashboard", .{base_url});
    defer allocator.free(url);

    const response = try executor(allocator, .{
        .method = .post,
        .url = url,
        .body = body,
        .content_type = "application/x-www-form-urlencoded",
    });
    defer allocator.free(response.body);

    const raw_cookie = response.set_cookie orelse {
        if (response.status.class() == .server_error) {
            debug_log.writef(allocator, "jackett-admin", "login: server error status={d} body=\"{s}\"", .{ @intFromEnum(response.status), bodySnippet(response.body) });
            return error.HttpError;
        }
        debug_log.writef(allocator, "jackett-admin", "login: rejected (no Set-Cookie) status={d} body=\"{s}\"", .{ @intFromEnum(response.status), bodySnippet(response.body) });
        return error.LoginFailed;
    };
    defer allocator.free(raw_cookie);

    return .{ .cookie = try allocator.dupe(u8, firstCookiePair(raw_cookie)) };
}

/// Jackett's passwordless auto-sign-in requires a 3-step "TestCookie"
/// handshake (see `WebUIController.Login`/`TestCookie`): a plain
/// `GET /UI/Login` only sets a TestCookie and redirects; the client must
/// resend that cookie to `GET /UI/TestCookie` to prove cookies work, which
/// redirects back to `/UI/Login?cookiesChecked=1` where the server finally
/// signs in and sets the real session cookie.
fn loginPasswordless(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    executor: AdminExecutor,
) AdminError!AdminSession {
    const login_url = try std.fmt.allocPrint(allocator, "{s}/UI/Login", .{base_url});
    defer allocator.free(login_url);

    const login_response = try executor(allocator, .{ .method = .get, .url = login_url });
    defer allocator.free(login_response.body);

    const raw_test_cookie = login_response.set_cookie orelse {
        debug_log.writef(allocator, "jackett-admin", "login: GET /UI/Login returned no Set-Cookie status={d} body=\"{s}\"", .{ @intFromEnum(login_response.status), bodySnippet(login_response.body) });
        return error.NoSessionCookie;
    };
    defer allocator.free(raw_test_cookie);
    const test_cookie = firstCookiePair(raw_test_cookie);

    const test_cookie_url = try std.fmt.allocPrint(allocator, "{s}/UI/TestCookie", .{base_url});
    defer allocator.free(test_cookie_url);

    const test_response = try executor(allocator, .{
        .method = .get,
        .url = test_cookie_url,
        .headers = &.{.{ .name = "Cookie", .value = test_cookie }},
    });
    defer allocator.free(test_response.body);
    defer if (test_response.set_cookie) |c| allocator.free(c);

    if (test_response.status.class() != .redirect) {
        debug_log.writef(allocator, "jackett-admin", "login: GET /UI/TestCookie rejected status={d} body=\"{s}\"", .{ @intFromEnum(test_response.status), bodySnippet(test_response.body) });
        return error.NoSessionCookie;
    }

    const confirm_url = try std.fmt.allocPrint(allocator, "{s}/UI/Login?cookiesChecked=1", .{base_url});
    defer allocator.free(confirm_url);

    const confirm_response = try executor(allocator, .{ .method = .get, .url = confirm_url });
    defer allocator.free(confirm_response.body);

    const raw_auth_cookie = confirm_response.set_cookie orelse {
        debug_log.writef(allocator, "jackett-admin", "login: GET /UI/Login?cookiesChecked=1 returned no Set-Cookie status={d} body=\"{s}\"", .{ @intFromEnum(confirm_response.status), bodySnippet(confirm_response.body) });
        return error.NoSessionCookie;
    };
    defer allocator.free(raw_auth_cookie);

    return .{ .cookie = try allocator.dupe(u8, firstCookiePair(raw_auth_cookie)) };
}

fn bodySnippet(body: []const u8) []const u8 {
    return body[0..@min(body.len, 300)];
}

pub const IndexerInfo = struct {
    id: []u8,
    name: []u8,
    configured: bool,

    pub fn deinit(self: *IndexerInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub fn freeIndexerInfos(allocator: std.mem.Allocator, infos: []IndexerInfo) void {
    for (infos) |*info| info.deinit(allocator);
    allocator.free(infos);
}

const IndexerInfoJson = struct {
    id: []const u8,
    name: []const u8,
    configured: bool,
};

fn parseIndexerInfos(allocator: std.mem.Allocator, json_body: []const u8) AdminError![]IndexerInfo {
    var parsed = std.json.parseFromSlice([]const IndexerInfoJson, allocator, json_body, .{ .ignore_unknown_fields = true }) catch |err| {
        debug_log.writef(allocator, "jackett-admin", "parseIndexerInfos: failed err={s} body=\"{s}\"", .{ @errorName(err), bodySnippet(json_body) });
        return error.ParseFailed;
    };
    defer parsed.deinit();

    var result: std.ArrayList(IndexerInfo) = .empty;
    errdefer {
        for (result.items) |*item| item.deinit(allocator);
        result.deinit(allocator);
    }

    for (parsed.value) |item| {
        try result.append(allocator, .{
            .id = try allocator.dupe(u8, item.id),
            .name = try allocator.dupe(u8, item.name),
            .configured = item.configured,
        });
    }

    return result.toOwnedSlice(allocator);
}

pub fn listAllIndexers(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    session: *const AdminSession,
    executor: AdminExecutor,
) AdminError![]IndexerInfo {
    const url = try std.fmt.allocPrint(allocator, "{s}/api/v2.0/indexers", .{base_url});
    defer allocator.free(url);

    const response = try executor(allocator, .{
        .method = .get,
        .url = url,
        .headers = &.{.{ .name = "Cookie", .value = session.cookie }},
    });
    defer allocator.free(response.body);
    defer if (response.set_cookie) |c| allocator.free(c);

    if (response.status != .ok) {
        debug_log.writef(allocator, "jackett-admin", "listAllIndexers: unexpected status={d} body=\"{s}\"", .{ @intFromEnum(response.status), bodySnippet(response.body) });
        return error.HttpError;
    }

    return parseIndexerInfos(allocator, response.body);
}

pub fn getIndexerConfig(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    indexer_id: []const u8,
    session: *const AdminSession,
    executor: AdminExecutor,
) AdminError![]u8 {
    const encoded_id = try url_encode.percentEncode(allocator, indexer_id);
    defer allocator.free(encoded_id);
    const url = try std.fmt.allocPrint(allocator, "{s}/api/v2.0/indexers/{s}/Config", .{ base_url, encoded_id });
    defer allocator.free(url);

    const response = try executor(allocator, .{
        .method = .get,
        .url = url,
        .headers = &.{.{ .name = "Cookie", .value = session.cookie }},
    });
    defer if (response.set_cookie) |c| allocator.free(c);

    if (response.status != .ok) {
        debug_log.writef(allocator, "jackett-admin", "getIndexerConfig: unexpected status={d} body=\"{s}\"", .{ @intFromEnum(response.status), bodySnippet(response.body) });
        allocator.free(response.body);
        return error.HttpError;
    }

    return response.body;
}

pub fn setIndexerConfig(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    indexer_id: []const u8,
    config_json: []const u8,
    session: *const AdminSession,
    executor: AdminExecutor,
) AdminError!void {
    const encoded_id = try url_encode.percentEncode(allocator, indexer_id);
    defer allocator.free(encoded_id);
    const url = try std.fmt.allocPrint(allocator, "{s}/api/v2.0/indexers/{s}/Config", .{ base_url, encoded_id });
    defer allocator.free(url);

    const response = try executor(allocator, .{
        .method = .post,
        .url = url,
        .headers = &.{.{ .name = "Cookie", .value = session.cookie }},
        .body = config_json,
    });
    defer allocator.free(response.body);
    defer if (response.set_cookie) |c| allocator.free(c);

    if (response.status != .ok) {
        debug_log.writef(allocator, "jackett-admin", "setIndexerConfig: unexpected status={d} body=\"{s}\"", .{ @intFromEnum(response.status), bodySnippet(response.body) });
        return error.HttpError;
    }
}

pub fn deleteIndexer(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    indexer_id: []const u8,
    session: *const AdminSession,
    executor: AdminExecutor,
) AdminError!void {
    const encoded_id = try url_encode.percentEncode(allocator, indexer_id);
    defer allocator.free(encoded_id);
    const url = try std.fmt.allocPrint(allocator, "{s}/api/v2.0/indexers/{s}", .{ base_url, encoded_id });
    defer allocator.free(url);

    const response = try executor(allocator, .{
        .method = .delete,
        .url = url,
        .headers = &.{.{ .name = "Cookie", .value = session.cookie }},
    });
    defer allocator.free(response.body);
    defer if (response.set_cookie) |c| allocator.free(c);

    if (response.status != .ok) {
        debug_log.writef(allocator, "jackett-admin", "deleteIndexer: unexpected status={d} body=\"{s}\"", .{ @intFromEnum(response.status), bodySnippet(response.body) });
        return error.HttpError;
    }
}

/// Resolves the production indexer config cache directory
/// (`~/.config/supersearchr/indexer_cache/`, XDG-style). Callers pass the
/// result into the cache functions below as `cache_dir`, which keeps those
/// functions independently testable against a tmp directory.
pub fn defaultIndexerCacheDir(allocator: std.mem.Allocator) ![]u8 {
    const config_dir = try config.getConfigDir(allocator);
    defer allocator.free(config_dir);
    return std.fs.path.join(allocator, &.{ config_dir, "supersearchr", "indexer_cache" });
}

fn indexerCachePath(allocator: std.mem.Allocator, cache_dir: []const u8, indexer_id: []const u8) ![]u8 {
    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{indexer_id});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ cache_dir, filename });
}

pub fn cacheIndexerConfig(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    indexer_id: []const u8,
    config_json: []const u8,
) !void {
    const io = compat.io();
    try std.Io.Dir.cwd().createDirPath(io, cache_dir);

    const path = try indexerCachePath(allocator, cache_dir, indexer_id);
    defer allocator.free(path);

    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer compat.closeFile(file);
    try compat.writeFileAll(file, config_json);
}

pub fn readCachedIndexerConfig(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    indexer_id: []const u8,
) !?[]u8 {
    const path = try indexerCachePath(allocator, cache_dir, indexer_id);
    defer allocator.free(path);

    const io = compat.io();
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer compat.closeFile(file);

    var file_reader = file.reader(io, &.{});
    return try file_reader.interface.allocRemaining(allocator, .unlimited);
}

pub fn clearCachedIndexerConfig(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    indexer_id: []const u8,
) void {
    const path = indexerCachePath(allocator, cache_dir, indexer_id) catch return;
    defer allocator.free(path);
    std.Io.Dir.deleteFileAbsolute(compat.io(), path) catch {};
}

test "login with empty password completes the TestCookie handshake and reads the final Set-Cookie" {
    const allocator = std.testing.allocator;
    const mock = struct {
        fn exec(alloc: std.mem.Allocator, request: AdminRequest) AdminError!AdminResponse {
            if (request.method == .get and std.mem.endsWith(u8, request.url, "/UI/Login")) {
                return .{ .status = .found, .set_cookie = try alloc.dupe(u8, "TestCookie=1; Path=/") };
            }
            if (request.method == .get and std.mem.endsWith(u8, request.url, "/UI/TestCookie")) {
                var found = false;
                for (request.headers) |h| {
                    if (std.mem.eql(u8, h.name, "Cookie") and std.mem.eql(u8, h.value, "TestCookie=1")) found = true;
                }
                if (!found) return error.HttpError;
                return .{ .status = .found };
            }
            if (request.method == .get and std.mem.endsWith(u8, request.url, "/UI/Login?cookiesChecked=1")) {
                return .{ .status = .found, .set_cookie = try alloc.dupe(u8, "Jackett=abc123; Path=/; HttpOnly") };
            }
            return error.HttpError;
        }
    };

    var session = try login(allocator, "http://localhost:9117", "", mock.exec);
    defer session.deinit(allocator);

    try std.testing.expectEqualStrings("Jackett=abc123", session.cookie);
}

test "login surfaces NoSessionCookie when GET /UI/Login returns no Set-Cookie" {
    const allocator = std.testing.allocator;
    const mock = struct {
        fn exec(_: std.mem.Allocator, _: AdminRequest) AdminError!AdminResponse {
            return .{ .status = .found };
        }
    };

    try std.testing.expectError(error.NoSessionCookie, login(allocator, "http://localhost:9117", "", mock.exec));
}

test "login surfaces NoSessionCookie when GET /UI/TestCookie rejects the resent cookie" {
    const allocator = std.testing.allocator;
    const mock = struct {
        fn exec(alloc: std.mem.Allocator, request: AdminRequest) AdminError!AdminResponse {
            if (request.method == .get and std.mem.endsWith(u8, request.url, "/UI/Login")) {
                return .{ .status = .found, .set_cookie = try alloc.dupe(u8, "TestCookie=1; Path=/") };
            }
            // Simulates Jackett's WebUIController.TestCookie returning 400 "Cookies required".
            return .{ .status = .bad_request };
        }
    };

    try std.testing.expectError(error.NoSessionCookie, login(allocator, "http://localhost:9117", "", mock.exec));
}

test "login surfaces NoSessionCookie when the final passwordless step returns no Set-Cookie" {
    const allocator = std.testing.allocator;
    const mock = struct {
        fn exec(alloc: std.mem.Allocator, request: AdminRequest) AdminError!AdminResponse {
            if (request.method == .get and std.mem.endsWith(u8, request.url, "/UI/Login")) {
                return .{ .status = .found, .set_cookie = try alloc.dupe(u8, "TestCookie=1; Path=/") };
            }
            if (request.method == .get and std.mem.endsWith(u8, request.url, "/UI/TestCookie")) {
                return .{ .status = .found };
            }
            return .{ .status = .found };
        }
    };

    try std.testing.expectError(error.NoSessionCookie, login(allocator, "http://localhost:9117", "", mock.exec));
}

var test_observed_login_request_ok: bool = false;

test "login with password POSTs form-encoded body to /UI/Dashboard and reads cookie" {
    test_observed_login_request_ok = false;
    const allocator = std.testing.allocator;
    const mock = struct {
        fn exec(alloc: std.mem.Allocator, request: AdminRequest) AdminError!AdminResponse {
            if (request.method == .post and std.mem.endsWith(u8, request.url, "/UI/Dashboard")) {
                test_observed_login_request_ok = std.mem.eql(u8, request.body orelse "", "password=my%20secret") and
                    std.mem.eql(u8, request.content_type, "application/x-www-form-urlencoded");
                // Real Jackett always redirects from this endpoint, win or lose.
                return .{ .status = .found, .set_cookie = try alloc.dupe(u8, "Jackett=xyz789; Path=/") };
            }
            return error.HttpError;
        }
    };

    var session = try login(allocator, "http://localhost:9117", "my secret", mock.exec);
    defer session.deinit(allocator);

    try std.testing.expectEqualStrings("Jackett=xyz789", session.cookie);
    try std.testing.expect(test_observed_login_request_ok);
}

test "login surfaces LoginFailed when redirected back with no cookie (wrong password)" {
    const allocator = std.testing.allocator;
    const mock = struct {
        fn exec(_: std.mem.Allocator, _: AdminRequest) AdminError!AdminResponse {
            return .{ .status = .found };
        }
    };

    try std.testing.expectError(error.LoginFailed, login(allocator, "http://localhost:9117", "wrongpass", mock.exec));
}

test "login surfaces HttpError on a genuine server error" {
    const allocator = std.testing.allocator;
    const mock = struct {
        fn exec(_: std.mem.Allocator, _: AdminRequest) AdminError!AdminResponse {
            return .{ .status = .internal_server_error };
        }
    };

    try std.testing.expectError(error.HttpError, login(allocator, "http://localhost:9117", "wrongpass", mock.exec));
}

var test_observed_cookie_header: bool = false;

test "listAllIndexers sends Cookie header and parses JSON ignoring unknown fields" {
    test_observed_cookie_header = false;
    const allocator = std.testing.allocator;
    const mock = struct {
        fn exec(alloc: std.mem.Allocator, request: AdminRequest) AdminError!AdminResponse {
            if (request.method == .get and std.mem.endsWith(u8, request.url, "/api/v2.0/indexers")) {
                for (request.headers) |h| {
                    if (std.mem.eql(u8, h.name, "Cookie") and std.mem.eql(u8, h.value, "Jackett=abc123")) {
                        test_observed_cookie_header = true;
                    }
                }
                return .{ .status = .ok, .body = try alloc.dupe(u8, "[{\"id\":\"1337x\",\"name\":\"1337x\",\"configured\":true,\"description\":\"ignored\"},{\"id\":\"tpb\",\"name\":\"The Pirate Bay\",\"configured\":false}]") };
            }
            return error.HttpError;
        }
    };

    var session = AdminSession{ .cookie = try allocator.dupe(u8, "Jackett=abc123") };
    defer session.deinit(allocator);

    const infos = try listAllIndexers(allocator, "http://localhost:9117", &session, mock.exec);
    defer freeIndexerInfos(allocator, infos);

    try std.testing.expect(test_observed_cookie_header);
    try std.testing.expectEqual(@as(usize, 2), infos.len);
    try std.testing.expectEqualStrings("1337x", infos[0].id);
    try std.testing.expectEqualStrings("1337x", infos[0].name);
    try std.testing.expect(infos[0].configured);
    try std.testing.expectEqualStrings("tpb", infos[1].id);
    try std.testing.expectEqualStrings("The Pirate Bay", infos[1].name);
    try std.testing.expect(!infos[1].configured);
}

test "getIndexerConfig returns body on success and HttpError on non-ok status" {
    const allocator = std.testing.allocator;
    const mock = struct {
        fn exec(alloc: std.mem.Allocator, request: AdminRequest) AdminError!AdminResponse {
            if (std.mem.indexOf(u8, request.url, "/api/v2.0/indexers/1337x/Config") != null) {
                return .{ .status = .ok, .body = try alloc.dupe(u8, "{\"field\":\"value\"}") };
            }
            if (std.mem.indexOf(u8, request.url, "/api/v2.0/indexers/missing/Config") != null) {
                return .{ .status = .not_found, .body = try alloc.dupe(u8, "") };
            }
            return error.HttpError;
        }
    };

    var session = AdminSession{ .cookie = try allocator.dupe(u8, "Jackett=abc123") };
    defer session.deinit(allocator);

    const body = try getIndexerConfig(allocator, "http://localhost:9117", "1337x", &session, mock.exec);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("{\"field\":\"value\"}", body);

    try std.testing.expectError(error.HttpError, getIndexerConfig(allocator, "http://localhost:9117", "missing", &session, mock.exec));
}

var test_observed_set_config_request_ok: bool = false;

test "setIndexerConfig sends POST with Cookie header and body" {
    test_observed_set_config_request_ok = false;
    const allocator = std.testing.allocator;
    const mock = struct {
        fn exec(alloc: std.mem.Allocator, request: AdminRequest) AdminError!AdminResponse {
            var found_cookie = false;
            for (request.headers) |h| {
                if (std.mem.eql(u8, h.name, "Cookie")) found_cookie = true;
            }
            test_observed_set_config_request_ok = request.method == .post and
                std.mem.indexOf(u8, request.url, "/api/v2.0/indexers/1337x/Config") != null and
                std.mem.eql(u8, request.body orelse "", "{\"field\":\"value\"}") and
                found_cookie;
            return .{ .status = .ok, .body = try alloc.dupe(u8, "") };
        }
    };

    var session = AdminSession{ .cookie = try allocator.dupe(u8, "Jackett=abc123") };
    defer session.deinit(allocator);

    try setIndexerConfig(allocator, "http://localhost:9117", "1337x", "{\"field\":\"value\"}", &session, mock.exec);
    try std.testing.expect(test_observed_set_config_request_ok);
}

var test_observed_delete_request_ok: bool = false;

test "deleteIndexer sends DELETE with Cookie header" {
    test_observed_delete_request_ok = false;
    const allocator = std.testing.allocator;
    const mock = struct {
        fn exec(alloc: std.mem.Allocator, request: AdminRequest) AdminError!AdminResponse {
            test_observed_delete_request_ok = request.method == .delete and
                std.mem.indexOf(u8, request.url, "/api/v2.0/indexers/1337x") != null;
            return .{ .status = .ok, .body = try alloc.dupe(u8, "") };
        }
    };

    var session = AdminSession{ .cookie = try allocator.dupe(u8, "Jackett=abc123") };
    defer session.deinit(allocator);

    try deleteIndexer(allocator, "http://localhost:9117", "1337x", &session, mock.exec);
    try std.testing.expect(test_observed_delete_request_ok);
}

test "indexer config cache writes, reads, and clears" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_abs = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(dir_abs);
    const cache_dir = try std.fs.path.join(allocator, &.{ dir_abs, "indexer_cache" });
    defer allocator.free(cache_dir);

    try cacheIndexerConfig(allocator, cache_dir, "1337x", "{\"field\":\"value\"}");

    const read_back = try readCachedIndexerConfig(allocator, cache_dir, "1337x");
    defer if (read_back) |b| allocator.free(b);
    try std.testing.expect(read_back != null);
    try std.testing.expectEqualStrings("{\"field\":\"value\"}", read_back.?);

    clearCachedIndexerConfig(allocator, cache_dir, "1337x");
    const after_clear = try readCachedIndexerConfig(allocator, cache_dir, "1337x");
    try std.testing.expect(after_clear == null);

    clearCachedIndexerConfig(allocator, cache_dir, "1337x");
}

test "readCachedIndexerConfig returns null when no cache file exists" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_abs = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(dir_abs);
    const cache_dir = try std.fs.path.join(allocator, &.{ dir_abs, "indexer_cache" });
    defer allocator.free(cache_dir);

    const result = try readCachedIndexerConfig(allocator, cache_dir, "never-disabled");
    try std.testing.expect(result == null);
}

test "cacheIndexerConfig overwrites an existing cache file" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_abs = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(dir_abs);
    const cache_dir = try std.fs.path.join(allocator, &.{ dir_abs, "indexer_cache" });
    defer allocator.free(cache_dir);

    try cacheIndexerConfig(allocator, cache_dir, "1337x", "{\"version\":1}");
    try cacheIndexerConfig(allocator, cache_dir, "1337x", "{\"version\":2}");

    const read_back = try readCachedIndexerConfig(allocator, cache_dir, "1337x");
    defer if (read_back) |b| allocator.free(b);
    try std.testing.expectEqualStrings("{\"version\":2}", read_back.?);
}
