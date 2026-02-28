const std = @import("std");

pub const Config = struct {
    api_key: []const u8,
    api_url: []const u8,
    api_port: u16,
    terminal: []const u8,
};

pub fn loadConfig(allocator: std.mem.Allocator) !Config {
    const config_path = try getConfigPath(allocator);
    defer allocator.free(config_path);

    const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            try createConfigFile(config_path);
            return error.ConfigCreated;
        }
        return err;
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(contents);

    const patched = try patchMissingDefaults(allocator, config_path, contents);
    const effective_contents = patched orelse contents;
    defer if (patched != null) allocator.free(patched.?);

    return try parseConfig(allocator, effective_contents);
}

fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            return error.HomeNotFound;
        }
        return err;
    };
    defer allocator.free(home);

    return std.fmt.allocPrint(allocator, "{s}/.config/supersearchr/config.json", .{home});
}

fn createConfigFile(config_path: []const u8) !void {
    const config_dir = std.fs.path.dirname(config_path) orelse ".";
    try std.fs.cwd().makePath(config_dir);

    const placeholder =
        \\{
        \\  "apiKey": "YOUR_JACKETT_API_KEY",
        \\  "apiUrl": "YOUR_JACKET_URL",
        \\  "apiPort": 9117,
        \\  "terminal": "ghostty"
        \\}
    ;

    const file = try std.fs.createFileAbsolute(config_path, .{});
    defer file.close();

    try file.writeAll(placeholder);

    std.debug.print("Config created at {s}. Please add your Jackett API key, URL and port.\n", .{config_path});
}

fn patchMissingDefaults(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    contents: []const u8,
) !?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    var config_obj = &parsed.value.object;
    var did_patch = false;

    if (config_obj.get("terminal") == null) {
        try config_obj.put("terminal", .{ .string = "ghostty" });
        did_patch = true;
    }

    if (!did_patch) return null;

    const patched = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });

    const file = try std.fs.createFileAbsolute(config_path, .{});
    defer file.close();
    try file.writeAll(patched);

    return patched;
}

fn parseConfig(allocator: std.mem.Allocator, contents: []const u8) !Config {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch {
        return error.InvalidConfig;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    const api_key = obj.get("apiKey") orelse {
        return error.MissingApiKey;
    };
    const api_url = obj.get("apiUrl") orelse {
        return error.MissingApiUrl;
    };
    const api_port = obj.get("apiPort") orelse {
        return error.MissingApiPort;
    };
    const terminal = obj.get("terminal") orelse {
        return error.MissingTerminal;
    };

    const api_key_str = switch (api_key) {
        .string => |s| s,
        else => return error.InvalidApiKey,
    };

    const api_url_str = switch (api_url) {
        .string => |s| s,
        else => return error.InvalidApiUrl,
    };

    const api_port_num = switch (api_port) {
        .integer => |n| n,
        else => return error.InvalidApiPort,
    };

    const terminal_str = switch (terminal) {
        .string => |s| s,
        else => return error.InvalidTerminal,
    };

    if (api_key_str.len == 0 or std.mem.eql(u8, api_key_str, "YOUR_JACKETT_API_KEY")) {
        return error.EmptyApiKey;
    }

    if (api_url_str.len == 0 or std.mem.eql(u8, api_url_str, "YOUR_JACKET_URL")) {
        return error.EmptyApiUrl;
    }

    if (api_port_num == 0) {
        return error.EmptyApiPort;
    }
    if (api_port_num < 1 or api_port_num > std.math.maxInt(u16)) {
        return error.InvalidApiPort;
    }

    if (terminal_str.len == 0) {
        return error.EmptyTerminal;
    }

    return .{
        .api_key = try allocator.dupe(u8, api_key_str),
        .api_url = try allocator.dupe(u8, api_url_str),
        .api_port = @intCast(api_port_num),
        .terminal = try allocator.dupe(u8, terminal_str),
    };
}

test "parse valid config JSON" {
    const allocator = std.testing.allocator;

    const valid_json =
        \\{
        \\  "apiKey": "test_api_key",
        \\  "apiUrl": "http://localhost",
        \\  "apiPort": 9117,
        \\  "terminal": "ghostty"
        \\}
    ;

    const config = try parseConfig(allocator, valid_json);
    defer {
        allocator.free(config.api_key);
        allocator.free(config.api_url);
        allocator.free(config.terminal);
    }

    try std.testing.expectEqualStrings("test_api_key", config.api_key);
    try std.testing.expectEqualStrings("http://localhost", config.api_url);
    try std.testing.expectEqual(@as(u16, 9117), config.api_port);
    try std.testing.expectEqualStrings("ghostty", config.terminal);
}

test "missing apiKey returns error" {
    const allocator = std.testing.allocator;

    const json_no_key =
        \\{
        \\  "apiUrl": "http://localhost",
        \\  "apiPort": 9117,
        \\  "terminal": "ghostty"
        \\}
    ;

    try std.testing.expectError(error.MissingApiKey, parseConfig(allocator, json_no_key));
}

test "missing apiUrl returns error" {
    const allocator = std.testing.allocator;

    const json_no_url =
        \\{
        \\  "apiKey": "test_key",
        \\  "apiPort": 9117,
        \\  "terminal": "ghostty"
        \\}
    ;

    try std.testing.expectError(error.MissingApiUrl, parseConfig(allocator, json_no_url));
}

test "missing apiPort returns error" {
    const allocator = std.testing.allocator;

    const json_no_port =
        \\{
        \\  "apiKey": "test_key",
        \\  "apiUrl": "http://localhost",
        \\  "terminal": "ghostty"
        \\}
    ;

    try std.testing.expectError(error.MissingApiPort, parseConfig(allocator, json_no_port));
}

test "default apiKey value returns error" {
    const allocator = std.testing.allocator;

    const json_default_key =
        \\{
        \\  "apiKey": "YOUR_JACKETT_API_KEY",
        \\  "apiUrl": "http://localhost",
        \\  "apiPort": 9117,
        \\  "terminal": "ghostty"
        \\}
    ;

    try std.testing.expectError(error.EmptyApiKey, parseConfig(allocator, json_default_key));
}

test "default apiUrl value returns error" {
    const allocator = std.testing.allocator;

    const json_default_url =
        \\{
        \\  "apiKey": "test_key",
        \\  "apiUrl": "YOUR_JACKET_URL",
        \\  "apiPort": 9117,
        \\  "terminal": "ghostty"
        \\}
    ;

    try std.testing.expectError(error.EmptyApiUrl, parseConfig(allocator, json_default_url));
}

test "empty apiKey returns error" {
    const allocator = std.testing.allocator;

    const json_empty_key =
        \\{
        \\  "apiKey": "",
        \\  "apiUrl": "http://localhost",
        \\  "apiPort": 9117,
        \\  "terminal": "ghostty"
        \\}
    ;

    try std.testing.expectError(error.EmptyApiKey, parseConfig(allocator, json_empty_key));
}

test "missing terminal returns error" {
    const allocator = std.testing.allocator;

    const json_no_terminal =
        \\{
        \\  "apiKey": "test_key",
        \\  "apiUrl": "http://localhost",
        \\  "apiPort": 9117
        \\}
    ;

    try std.testing.expectError(error.MissingTerminal, parseConfig(allocator, json_no_terminal));
}

test "empty terminal returns error" {
    const allocator = std.testing.allocator;

    const json_empty_terminal =
        \\{
        \\  "apiKey": "test_key",
        \\  "apiUrl": "http://localhost",
        \\  "apiPort": 9117,
        \\  "terminal": ""
        \\}
    ;

    try std.testing.expectError(error.EmptyTerminal, parseConfig(allocator, json_empty_terminal));
}

test "apiPort above 65535 returns error" {
    const allocator = std.testing.allocator;

    const json_bad_port =
        \\{
        \\  "apiKey": "test_key",
        \\  "apiUrl": "http://localhost",
        \\  "apiPort": 65536,
        \\  "terminal": "ghostty"
        \\}
    ;

    try std.testing.expectError(error.InvalidApiPort, parseConfig(allocator, json_bad_port));
}

test "apiPort below 1 returns error" {
    const allocator = std.testing.allocator;

    const json_bad_port =
        \\{
        \\  "apiKey": "test_key",
        \\  "apiUrl": "http://localhost",
        \\  "apiPort": -1,
        \\  "terminal": "ghostty"
        \\}
    ;

    try std.testing.expectError(error.InvalidApiPort, parseConfig(allocator, json_bad_port));
}

test "patchMissingDefaults adds terminal by mutating object and reserializing" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_abs = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_abs);

    const config_path = try std.fs.path.join(allocator, &.{ dir_abs, "config.json" });
    defer allocator.free(config_path);

    const original =
        \\{
        \\  "apiKey": "test_key",
        \\  "apiUrl": "http://localhost",
        \\  "apiPort": 9117
        \\}
    ;

    const patched = try patchMissingDefaults(allocator, config_path, original);
    defer if (patched != null) allocator.free(patched.?);

    try std.testing.expect(patched != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, patched.?, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("terminal") != null);
}
