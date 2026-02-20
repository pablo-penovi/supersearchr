const std = @import("std");

pub const Config = struct {
    api_key: []const u8,
    api_url: []const u8,
    api_port: u16,
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

    return try parseConfig(allocator, contents);
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
    try std.fs.makeDirAbsolute(config_dir);

    const placeholder =
        \\{
        \\  "apiKey": "YOUR_JACKETT_API_KEY",
        \\  "apiUrl": "YOUR_JACKET_URL",
        \\  "apiPort": 9117
        \\}
    ;

    const file = try std.fs.createFileAbsolute(config_path, .{});
    defer file.close();

    try file.writeAll(placeholder);

    std.debug.print("Config created at {s}. Please add your Jackett API key, URL and port.\n", .{config_path});
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

    if (api_key_str.len == 0 or std.mem.eql(u8, api_key_str, "YOUR_JACKETT_API_KEY")) {
        return error.EmptyApiKey;
    }

    if (api_url_str.len == 0 or std.mem.eql(u8, api_url_str, "YOUR_JACKET_URL")) {
        return error.EmptyApiUrl;
    }

    if (api_port_num == 0) {
        return error.EmptyApiPort;
    }

    return .{
        .api_key = try allocator.dupe(u8, api_key_str),
        .api_url = try allocator.dupe(u8, api_url_str),
        .api_port = @intCast(api_port_num),
    };
}

test "parse valid config JSON" {
    const allocator = std.testing.allocator;

    const valid_json =
        \\{
        \\  "apiKey": "test_api_key",
        \\  "apiUrl": "http://localhost",
        \\  "apiPort": 9117
        \\}
    ;

    const config = try parseConfig(allocator, valid_json);
    defer {
        allocator.free(config.api_key);
        allocator.free(config.api_url);
    }

    try std.testing.expectEqualStrings("test_api_key", config.api_key);
    try std.testing.expectEqualStrings("http://localhost", config.api_url);
    try std.testing.expectEqual(@as(u16, 9117), config.api_port);
}

test "missing apiKey returns error" {
    const allocator = std.testing.allocator;

    const json_no_key =
        \\{
        \\  "apiUrl": "http://localhost",
        \\  "apiPort": 9117
        \\}
    ;

    try std.testing.expectError(error.MissingApiKey, parseConfig(allocator, json_no_key));
}

test "missing apiUrl returns error" {
    const allocator = std.testing.allocator;

    const json_no_url =
        \\{
        \\  "apiKey": "test_key",
        \\  "apiPort": 9117
        \\}
    ;

    try std.testing.expectError(error.MissingApiUrl, parseConfig(allocator, json_no_url));
}

test "missing apiPort returns error" {
    const allocator = std.testing.allocator;

    const json_no_port =
        \\{
        \\  "apiKey": "test_key",
        \\  "apiUrl": "http://localhost"
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
        \\  "apiPort": 9117
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
        \\  "apiPort": 9117
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
        \\  "apiPort": 9117
        \\}
    ;

    try std.testing.expectError(error.EmptyApiKey, parseConfig(allocator, json_empty_key));
}
