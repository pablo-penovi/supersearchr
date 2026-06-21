const std = @import("std");
const compat = @import("compat");
const debug_log = @import("debug_log");

pub const HttpExecError = error{
    InvalidUrl,
    ConnectionRefused,
    RequestCreateFailed,
    RequestSendFailed,
    ResponseHeadReadFailed,
    ResponseReadFailed,
    OutOfMemory,
};

pub const HeaderPair = std.http.Header;

pub const RequestSpec = struct {
    method: std.http.Method = .GET,
    extra_headers: []const HeaderPair = &.{},
    body: ?[]const u8 = null,
};

pub const RawResponse = struct {
    status: std.http.Status,
    body: []u8 = &.{},
    response_headers: []HeaderPair = &.{},
};

fn mapToHttpExecError(err: anyerror, fallback: HttpExecError) HttpExecError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ConnectionRefused => error.ConnectionRefused,
        else => fallback,
    };
}

pub fn freeHeaderPairs(allocator: std.mem.Allocator, headers: []HeaderPair) void {
    for (headers) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
    }
    if (headers.len != 0) allocator.free(headers);
}

/// Sends a single HTTP request and returns its raw status/body/headers
/// without interpreting them. Decompresses the response body
/// (gzip/deflate/zstd) transparently. Callers decide how to interpret a
/// non-OK status and which response headers (if any) matter to them.
pub fn execute(
    allocator: std.mem.Allocator,
    url: []const u8,
    spec: RequestSpec,
    log_tag: []const u8,
) HttpExecError!RawResponse {
    var http_client = std.http.Client{ .allocator = allocator, .io = compat.io() };
    defer http_client.deinit();

    const uri = std.Uri.parse(url) catch |err| {
        debug_log.writef(
            allocator,
            log_tag,
            "Failed to parse URL err={s} url=\"{s}\"",
            .{ @errorName(err), url },
        );
        return error.InvalidUrl;
    };

    var request = http_client.request(spec.method, uri, .{
        .extra_headers = spec.extra_headers,
        .headers = if (spec.body != null) .{ .content_type = .{ .override = "application/json" } } else .{},
    }) catch |err| {
        debug_log.writef(
            allocator,
            log_tag,
            "Failed to create request err={s} url=\"{s}\"",
            .{ @errorName(err), url },
        );
        return mapToHttpExecError(err, error.RequestCreateFailed);
    };
    defer request.deinit();

    if (spec.body) |body| {
        request.sendBodyComplete(@constCast(body)) catch |err| {
            debug_log.writef(
                allocator,
                log_tag,
                "Failed to send request body err={s} url=\"{s}\"",
                .{ @errorName(err), url },
            );
            return mapToHttpExecError(err, error.RequestSendFailed);
        };
    } else {
        request.sendBodiless() catch |err| {
            debug_log.writef(
                allocator,
                log_tag,
                "Failed to send request err={s} url=\"{s}\"",
                .{ @errorName(err), url },
            );
            return mapToHttpExecError(err, error.RequestSendFailed);
        };
    }

    var header_buf: [8192]u8 = undefined;
    var response = request.receiveHead(&header_buf) catch |err| {
        debug_log.writef(
            allocator,
            log_tag,
            "Failed to receive response head err={s} url=\"{s}\"",
            .{ @errorName(err), url },
        );
        return mapToHttpExecError(err, error.ResponseHeadReadFailed);
    };

    const status = response.head.status;

    var headers_list: std.ArrayList(HeaderPair) = .empty;
    errdefer freeHeaderPairs(allocator, headers_list.items);
    errdefer headers_list.deinit(allocator);

    var header_it = response.head.iterateHeaders();
    while (header_it.next()) |h| {
        const name_dup = allocator.dupe(u8, h.name) catch return error.OutOfMemory;
        errdefer allocator.free(name_dup);
        const value_dup = allocator.dupe(u8, h.value) catch return error.OutOfMemory;
        try headers_list.append(allocator, .{ .name = name_dup, .value = value_dup });
    }

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => allocator.alloc(u8, std.compress.zstd.default_window_len) catch |err| {
            debug_log.writef(
                allocator,
                log_tag,
                "Failed to allocate decompression buffer err={s} url=\"{s}\"",
                .{ @errorName(err), url },
            );
            return error.OutOfMemory;
        },
        .deflate, .gzip => allocator.alloc(u8, std.compress.flate.max_window_len) catch |err| {
            debug_log.writef(
                allocator,
                log_tag,
                "Failed to allocate decompression buffer err={s} url=\"{s}\"",
                .{ @errorName(err), url },
            );
            return error.OutOfMemory;
        },
        .compress => {
            debug_log.writef(
                allocator,
                log_tag,
                "Unsupported content encoding url=\"{s}\"",
                .{url},
            );
            return error.ResponseReadFailed;
        },
    };
    defer if (decompress_buffer.len != 0) allocator.free(decompress_buffer);

    var read_buf: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&read_buf, &decompress, decompress_buffer);
    const body = reader.allocRemaining(allocator, .unlimited) catch |err| {
        debug_log.writef(
            allocator,
            log_tag,
            "Failed to read response body err={s} url=\"{s}\"",
            .{ @errorName(err), url },
        );
        return mapToHttpExecError(err, error.ResponseReadFailed);
    };

    return .{
        .status = status,
        .body = body,
        .response_headers = try headers_list.toOwnedSlice(allocator),
    };
}

const TestRequestCapture = struct {
    head: std.ArrayList(u8) = .empty,
    body: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestRequestCapture, allocator: std.mem.Allocator) void {
        self.head.deinit(allocator);
        self.body.deinit(allocator);
    }
};

const TestHttpServer = struct {
    allocator: std.mem.Allocator,
    response: []const u8,
    capture: *TestRequestCapture,

    fn serve(self: *const TestHttpServer, server: *std.Io.net.Server) !void {
        const io = compat.io();
        var stream = try server.accept(io);
        defer stream.close(io);

        var read_buf: [1]u8 = undefined;
        var reader = stream.reader(io, &read_buf);

        while (!std.mem.endsWith(u8, self.capture.head.items, "\r\n\r\n")) {
            const byte = reader.interface.takeByte() catch break;
            self.capture.head.append(self.allocator, byte) catch {};
        }

        var content_length: usize = 0;
        var line_it = std.mem.splitSequence(u8, self.capture.head.items, "\r\n");
        while (line_it.next()) |line| {
            if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                const value = std.mem.trim(u8, line["content-length:".len..], " ");
                content_length = std.fmt.parseInt(usize, value, 10) catch 0;
            }
        }

        var remaining = content_length;
        while (remaining > 0) {
            const byte = reader.interface.takeByte() catch break;
            self.capture.body.append(self.allocator, byte) catch {};
            remaining -= 1;
        }

        var write_buf: [4096]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        try writer.interface.writeAll(self.response);
        try writer.interface.flush();
    }
};

fn startTestServer(
    allocator: std.mem.Allocator,
    response: []const u8,
    capture: *TestRequestCapture,
) !struct { server: *std.Io.net.Server, thread: std.Thread, port: u16, handler: *TestHttpServer } {
    const io = compat.io();
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);

    const server = try allocator.create(std.Io.net.Server);
    server.* = try std.Io.net.IpAddress.listen(&address, io, .{ .reuse_address = true });
    const port = server.socket.address.getPort();

    const handler = try allocator.create(TestHttpServer);
    handler.* = .{ .allocator = allocator, .response = response, .capture = capture };

    const thread = try std.Thread.spawn(.{}, TestHttpServer.serve, .{ handler, server });
    return .{ .server = server, .thread = thread, .port = port, .handler = handler };
}

test "execute sends GET with no body and returns status/body" {
    const allocator = std.testing.allocator;
    var capture: TestRequestCapture = .{};
    defer capture.deinit(allocator);

    var started = try startTestServer(allocator, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello", &capture);
    defer {
        started.server.deinit(compat.io());
        allocator.destroy(started.server);
    }

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/path", .{started.port});
    defer allocator.free(url);

    const raw = try execute(allocator, url, .{}, "test");
    defer allocator.free(raw.body);
    defer freeHeaderPairs(allocator, raw.response_headers);
    started.thread.join();
    allocator.destroy(started.handler);

    try std.testing.expectEqual(std.http.Status.ok, raw.status);
    try std.testing.expectEqualStrings("hello", raw.body);
    try std.testing.expect(std.mem.startsWith(u8, capture.head.items, "GET /path HTTP/1.1"));
}

test "execute attaches extra_headers to the outgoing request" {
    const allocator = std.testing.allocator;
    var capture: TestRequestCapture = .{};
    defer capture.deinit(allocator);

    var started = try startTestServer(allocator, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", &capture);
    defer {
        started.server.deinit(compat.io());
        allocator.destroy(started.server);
    }

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/path", .{started.port});
    defer allocator.free(url);

    const raw = try execute(allocator, url, .{
        .extra_headers = &.{.{ .name = "Cookie", .value = "Jackett=abc123" }},
    }, "test");
    defer allocator.free(raw.body);
    defer freeHeaderPairs(allocator, raw.response_headers);
    started.thread.join();
    allocator.destroy(started.handler);

    try std.testing.expect(std.mem.indexOf(u8, capture.head.items, "Cookie: Jackett=abc123") != null);
}

test "execute sends POST with body and Content-Type header" {
    const allocator = std.testing.allocator;
    var capture: TestRequestCapture = .{};
    defer capture.deinit(allocator);

    var started = try startTestServer(allocator, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", &capture);
    defer {
        started.server.deinit(compat.io());
        allocator.destroy(started.server);
    }

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/path", .{started.port});
    defer allocator.free(url);

    const raw = try execute(allocator, url, .{
        .method = .POST,
        .body = "{\"enabled\":true}",
    }, "test");
    defer allocator.free(raw.body);
    defer freeHeaderPairs(allocator, raw.response_headers);
    started.thread.join();
    allocator.destroy(started.handler);

    try std.testing.expect(std.mem.startsWith(u8, capture.head.items, "POST /path HTTP/1.1"));
    try std.testing.expect(std.mem.indexOf(u8, capture.head.items, "content-type: application/json") != null);
    try std.testing.expectEqualStrings("{\"enabled\":true}", capture.body.items);
}

test "execute captures Set-Cookie from the response" {
    const allocator = std.testing.allocator;
    var capture: TestRequestCapture = .{};
    defer capture.deinit(allocator);

    var started = try startTestServer(allocator, "HTTP/1.1 200 OK\r\nSet-Cookie: Jackett=xyz789; Path=/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", &capture);
    defer {
        started.server.deinit(compat.io());
        allocator.destroy(started.server);
    }

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/path", .{started.port});
    defer allocator.free(url);

    const raw = try execute(allocator, url, .{}, "test");
    defer allocator.free(raw.body);
    defer freeHeaderPairs(allocator, raw.response_headers);
    started.thread.join();
    allocator.destroy(started.handler);

    var found = false;
    for (raw.response_headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Set-Cookie")) {
            try std.testing.expect(std.mem.startsWith(u8, h.value, "Jackett=xyz789"));
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "execute does not throw on non-OK status" {
    const allocator = std.testing.allocator;
    var capture: TestRequestCapture = .{};
    defer capture.deinit(allocator);

    var started = try startTestServer(allocator, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", &capture);
    defer {
        started.server.deinit(compat.io());
        allocator.destroy(started.server);
    }

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/path", .{started.port});
    defer allocator.free(url);

    const raw = try execute(allocator, url, .{}, "test");
    defer allocator.free(raw.body);
    defer freeHeaderPairs(allocator, raw.response_headers);
    started.thread.join();
    allocator.destroy(started.handler);

    try std.testing.expectEqual(std.http.Status.not_found, raw.status);
}

test "execute surfaces InvalidUrl for malformed URL" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidUrl, execute(allocator, "not a url ::", .{}, "test"));
}

fn gzipStoredBody(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    if (body.len > std.math.maxInt(u16)) return error.OutOfMemory;

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, std.compress.flate.Container.header(.gzip));
    try result.append(allocator, 0x01);

    var bits16: [2]u8 = undefined;
    const len: u16 = @intCast(body.len);
    std.mem.writeInt(u16, &bits16, len, .little);
    try result.appendSlice(allocator, &bits16);
    std.mem.writeInt(u16, &bits16, ~len, .little);
    try result.appendSlice(allocator, &bits16);
    try result.appendSlice(allocator, body);

    var crc: std.hash.Crc32 = .init();
    crc.update(body);

    var bits32: [4]u8 = undefined;
    std.mem.writeInt(u32, &bits32, crc.final(), .little);
    try result.appendSlice(allocator, &bits32);
    std.mem.writeInt(u32, &bits32, @intCast(body.len), .little);
    try result.appendSlice(allocator, &bits32);

    return result.toOwnedSlice(allocator);
}

test "execute decompresses gzip response body" {
    const allocator = std.testing.allocator;
    const xml = "<indexers><indexer id=\"alpha\"></indexer></indexers>";

    const gzipped = try gzipStoredBody(allocator, xml);
    defer allocator.free(gzipped);

    var capture: TestRequestCapture = .{};
    defer capture.deinit(allocator);

    const response = try std.fmt.allocPrint(
        allocator,
        "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ gzipped.len, gzipped },
    );
    defer allocator.free(response);

    var started = try startTestServer(allocator, response, &capture);
    defer {
        started.server.deinit(compat.io());
        allocator.destroy(started.server);
    }

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/path", .{started.port});
    defer allocator.free(url);

    const raw = try execute(allocator, url, .{}, "test");
    defer allocator.free(raw.body);
    defer freeHeaderPairs(allocator, raw.response_headers);
    started.thread.join();
    allocator.destroy(started.handler);

    try std.testing.expectEqualStrings(xml, raw.body);
}
