const std = @import("std");
const Torrent = @import("torrent").Torrent;
const debug_log = @import("debug_log");

pub const JackettError = error{
    InvalidUrl,
    ConnectionRefused,
    RequestCreateFailed,
    RequestSendFailed,
    ResponseHeadReadFailed,
    HttpError,
    ResponseReadFailed,
    ParseFailed,
    OutOfMemory,
};

const xml_tags = .{
    .item = "<item>",
    .item_end = "</item>",
    .indexer = "<indexer ",
    .indexer_end = "</indexer>",
    .indexer_id = "id=\"",
    .title = "<title>",
    .size = "<size>",
    .link = "<link>",
    .enclosure = "<enclosure ",
    .magneturl_attr_name = "name=\"magneturl\"",
    .size_attr_name = "name=\"size\"",
    .attr_value = "value=\"",
    .enclosure_url = "url=\"",
    .enclosure_length = "length=\"",
    .seeders_attr = "<torznab:attr name=\"seeders\" value=\"",
    .peers_attr = "<torznab:attr name=\"peers\" value=\"",
};

fn extractStringField(xml: []const u8, i: usize, tag: []const u8) ?struct { value: []const u8, end: usize } {
    if (std.mem.startsWith(u8, xml[i..], tag)) {
        const start = i + tag.len;
        const end = std.mem.indexOfScalarPos(u8, xml, start, '<') orelse xml.len;
        return .{ .value = xml[start..end], .end = end };
    }
    return null;
}

fn extractIntField(xml: []const u8, i: usize, tag: []const u8, default: u32) ?struct { value: u32, end: usize } {
    if (std.mem.startsWith(u8, xml[i..], tag)) {
        const start = i + tag.len;
        const end = std.mem.indexOfScalarPos(u8, xml, start, '"') orelse xml.len;
        return .{ .value = std.fmt.parseInt(u32, xml[start..end], 10) catch default, .end = end };
    }
    return null;
}

fn extractOptionalU64Element(xml: []const u8, i: usize, tag: []const u8) ?struct { value: ?u64, end: usize } {
    if (std.mem.startsWith(u8, xml[i..], tag)) {
        const start = i + tag.len;
        const end = std.mem.indexOfScalarPos(u8, xml, start, '<') orelse xml.len;
        const trimmed = std.mem.trim(u8, xml[start..end], " \t\r\n");
        return .{ .value = std.fmt.parseInt(u64, trimmed, 10) catch null, .end = end };
    }
    return null;
}

fn extractTorznabSizeAttr(xml: []const u8, i: usize) ?struct { value: ?u64, end: usize } {
    const attr_tag = "<torznab:attr ";
    if (!std.mem.startsWith(u8, xml[i..], attr_tag)) return null;

    const tag_end = std.mem.indexOfScalarPos(u8, xml, i, '>') orelse return null;
    const tag = xml[i .. tag_end + 1];

    if (std.mem.indexOf(u8, tag, xml_tags.size_attr_name) == null) return null;

    const value_pos = std.mem.indexOf(u8, tag, xml_tags.attr_value) orelse return null;
    const value_start = i + value_pos + xml_tags.attr_value.len;
    const value_end = std.mem.indexOfScalarPos(u8, xml, value_start, '"') orelse return null;
    return .{
        .value = std.fmt.parseInt(u64, xml[value_start..value_end], 10) catch null,
        .end = tag_end + 1,
    };
}

fn extractMagnetUrlAttr(xml: []const u8, i: usize) ?struct { value: []const u8, end: usize } {
    const attr_tag = "<torznab:attr ";
    if (!std.mem.startsWith(u8, xml[i..], attr_tag)) return null;

    const tag_end = std.mem.indexOfScalarPos(u8, xml, i, '>') orelse return null;
    const tag = xml[i .. tag_end + 1];

    if (std.mem.indexOf(u8, tag, xml_tags.magneturl_attr_name) == null) return null;

    const value_pos = std.mem.indexOf(u8, tag, xml_tags.attr_value) orelse return null;
    const value_start = i + value_pos + xml_tags.attr_value.len;
    const value_end = std.mem.indexOfScalarPos(u8, xml, value_start, '"') orelse return null;
    return .{ .value = xml[value_start..value_end], .end = tag_end + 1 };
}

fn extractEnclosureUrl(xml: []const u8, i: usize) ?struct { value: []const u8, end: usize } {
    if (!std.mem.startsWith(u8, xml[i..], xml_tags.enclosure)) return null;

    const tag_end = std.mem.indexOfScalarPos(u8, xml, i, '>') orelse return null;
    const tag = xml[i .. tag_end + 1];
    const url_pos = std.mem.indexOf(u8, tag, xml_tags.enclosure_url) orelse return null;
    const url_start = i + url_pos + xml_tags.enclosure_url.len;
    const url_end = std.mem.indexOfScalarPos(u8, xml, url_start, '"') orelse return null;
    return .{ .value = xml[url_start..url_end], .end = tag_end + 1 };
}

fn extractEnclosureInfo(xml: []const u8, i: usize) ?struct { url: ?[]const u8, length: ?u64, end: usize } {
    if (!std.mem.startsWith(u8, xml[i..], xml_tags.enclosure)) return null;

    const tag_end = std.mem.indexOfScalarPos(u8, xml, i, '>') orelse return null;
    const tag = xml[i .. tag_end + 1];
    const url = if (std.mem.indexOf(u8, tag, xml_tags.enclosure_url)) |url_pos| url: {
        const url_start = i + url_pos + xml_tags.enclosure_url.len;
        const url_end = std.mem.indexOfScalarPos(u8, xml, url_start, '"') orelse break :url null;
        break :url xml[url_start..url_end];
    } else null;
    const length = if (std.mem.indexOf(u8, tag, xml_tags.enclosure_length)) |length_pos| length: {
        const length_start = i + length_pos + xml_tags.enclosure_length.len;
        const length_end = std.mem.indexOfScalarPos(u8, xml, length_start, '"') orelse break :length null;
        break :length std.fmt.parseInt(u64, xml[length_start..length_end], 10) catch null;
    } else null;
    return .{
        .url = url,
        .length = length,
        .end = tag_end + 1,
    };
}

fn normalizeLink(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < trimmed.len) {
        if (std.mem.startsWith(u8, trimmed[i..], "&amp;")) {
            try out.append(allocator, '&');
            i += 5;
        } else if (std.mem.startsWith(u8, trimmed[i..], "&lt;")) {
            try out.append(allocator, '<');
            i += 4;
        } else if (std.mem.startsWith(u8, trimmed[i..], "&gt;")) {
            try out.append(allocator, '>');
            i += 4;
        } else if (std.mem.startsWith(u8, trimmed[i..], "&quot;")) {
            try out.append(allocator, '"');
            i += 6;
        } else if (std.mem.startsWith(u8, trimmed[i..], "&apos;")) {
            try out.append(allocator, '\'');
            i += 6;
        } else if (trimmed[i] == '&' and i + 3 < trimmed.len and trimmed[i + 1] == '#') {
            if (decodeNumericEntity(trimmed[i..])) |decoded| {
                var utf8_buf: [4]u8 = undefined;
                const utf8_len = std.unicode.utf8Encode(decoded.codepoint, utf8_buf[0..]) catch {
                    try out.append(allocator, trimmed[i]);
                    i += 1;
                    continue;
                };
                try out.appendSlice(allocator, utf8_buf[0..utf8_len]);
                i += decoded.consumed;
            } else {
                try out.append(allocator, trimmed[i]);
                i += 1;
            }
        } else {
            try out.append(allocator, trimmed[i]);
            i += 1;
        }
    }

    return out.toOwnedSlice(allocator);
}

fn decodeNumericEntity(input: []const u8) ?struct { codepoint: u21, consumed: usize } {
    if (input.len < 4) return null;
    if (input[0] != '&' or input[1] != '#') return null;

    const semicolon_idx = std.mem.indexOfScalar(u8, input, ';') orelse return null;
    if (semicolon_idx < 3) return null;

    const number_slice = input[2..semicolon_idx];
    if (number_slice.len == 0) return null;

    const parsed: u21 = if ((number_slice[0] == 'x' or number_slice[0] == 'X') and number_slice.len > 1)
        std.fmt.parseInt(u21, number_slice[1..], 16) catch return null
    else
        std.fmt.parseInt(u21, number_slice, 10) catch return null;

    return .{
        .codepoint = parsed,
        .consumed = semicolon_idx + 1,
    };
}

fn mapAnyToJackettError(err: anyerror, fallback: JackettError) JackettError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ConnectionRefused => error.ConnectionRefused,
        else => fallback,
    };
}

fn mapAnyToLinkResolveError(err: anyerror, fallback: LinkResolveError) LinkResolveError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => fallback,
    };
}

pub const ProgressPhase = enum(u8) {
    discovering = 0,
    querying = 1,
    done = 2,
};

pub const SearchProgressSnapshot = struct {
    phase: ProgressPhase,
    completed: usize,
    total: usize,
    failed: usize,
};

pub const SearchProgress = struct {
    phase: std.atomic.Value(u8),
    completed: std.atomic.Value(usize),
    total: std.atomic.Value(usize),
    failed: std.atomic.Value(usize),

    pub fn init() SearchProgress {
        return .{
            .phase = std.atomic.Value(u8).init(@intFromEnum(ProgressPhase.discovering)),
            .completed = std.atomic.Value(usize).init(0),
            .total = std.atomic.Value(usize).init(0),
            .failed = std.atomic.Value(usize).init(0),
        };
    }

    pub fn setPhase(self: *SearchProgress, phase: ProgressPhase) void {
        self.phase.store(@intFromEnum(phase), .release);
    }

    pub fn setTotal(self: *SearchProgress, total: usize) void {
        self.total.store(total, .release);
    }

    pub fn recordCompleted(self: *SearchProgress) void {
        _ = self.completed.fetchAdd(1, .release);
    }

    pub fn recordFailed(self: *SearchProgress) void {
        _ = self.failed.fetchAdd(1, .release);
    }

    pub fn snapshot(self: *SearchProgress) SearchProgressSnapshot {
        const phase_value = self.phase.load(.acquire);
        const phase: ProgressPhase = switch (phase_value) {
            @intFromEnum(ProgressPhase.querying) => .querying,
            @intFromEnum(ProgressPhase.done) => .done,
            else => .discovering,
        };
        return .{
            .phase = phase,
            .completed = self.completed.load(.acquire),
            .total = self.total.load(.acquire),
            .failed = self.failed.load(.acquire),
        };
    }
};

pub const BodyExecutor = *const fn (allocator: std.mem.Allocator, url: []const u8) JackettError![]u8;

pub const LinkResolveError = error{
    InvalidLink,
    InvalidUrl,
    RequestCreateFailed,
    RequestSendFailed,
    ResponseHeadReadFailed,
    HttpError,
    ResponseReadFailed,
    UnresolvableLink,
    TempFileCreateFailed,
    TempFileWriteFailed,
    OutOfMemory,
};

pub const ResolvedLinkKind = enum {
    direct,
    magnet_redirect,
    torrent_file,
};

pub const ResolvedLink = struct {
    value: []u8,
    kind: ResolvedLinkKind,

    pub fn deinit(self: *ResolvedLink, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
        self.* = undefined;
    }
};

pub const LinkFetchResponse = struct {
    status: std.http.Status,
    location: ?[]u8 = null,
    body: []u8 = &.{},

    pub fn deinit(self: *LinkFetchResponse, allocator: std.mem.Allocator) void {
        if (self.location) |location| allocator.free(location);
        if (self.body.len != 0) allocator.free(self.body);
        self.* = undefined;
    }
};

pub const LinkFetchExecutor = *const fn (allocator: std.mem.Allocator, url: []const u8) LinkResolveError!LinkFetchResponse;

fn isHttpLink(link: []const u8) bool {
    return std.mem.startsWith(u8, link, "http://") or std.mem.startsWith(u8, link, "https://");
}

fn isRedirectStatus(status: std.http.Status) bool {
    const code = @intFromEnum(status);
    return code >= 300 and code < 400;
}

pub fn resolveDownloadLink(
    allocator: std.mem.Allocator,
    link: []const u8,
    fetcher: LinkFetchExecutor,
) LinkResolveError!ResolvedLink {
    if (std.mem.startsWith(u8, link, "magnet:") or (!isHttpLink(link) and std.mem.endsWith(u8, link, ".torrent"))) {
        debug_log.writef(
            allocator,
            "jackett",
            "Selected link used directly kind=direct",
            .{},
        );
        return .{
            .value = try allocator.dupe(u8, link),
            .kind = .direct,
        };
    }

    if (!isHttpLink(link)) {
        debug_log.writef(
            allocator,
            "jackett",
            "Selected link rejected before resolve",
            .{},
        );
        return error.InvalidLink;
    }

    var response = try fetcher(allocator, link);
    defer response.deinit(allocator);

    if (isRedirectStatus(response.status)) {
        const location = response.location orelse {
            debug_log.writef(
                allocator,
                "jackett",
                "HTTP link redirect had no location status={d}",
                .{@intFromEnum(response.status)},
            );
            return error.UnresolvableLink;
        };
        if (!std.mem.startsWith(u8, location, "magnet:")) {
            debug_log.writef(
                allocator,
                "jackett",
                "HTTP link redirected to non-magnet status={d}",
                .{@intFromEnum(response.status)},
            );
            return error.UnresolvableLink;
        }
        debug_log.writef(
            allocator,
            "jackett",
            "HTTP link resolved to magnet redirect status={d}",
            .{@intFromEnum(response.status)},
        );
        return .{
            .value = try allocator.dupe(u8, location),
            .kind = .magnet_redirect,
        };
    }

    if (response.status != .ok) {
        debug_log.writef(
            allocator,
            "jackett",
            "HTTP link returned non-OK status={d}",
            .{@intFromEnum(response.status)},
        );
        return error.HttpError;
    }

    if (response.body.len == 0) {
        debug_log.writef(
            allocator,
            "jackett",
            "HTTP link returned empty torrent body",
            .{},
        );
        return error.UnresolvableLink;
    }

    const path = try writeTempTorrentFile(allocator, response.body);
    debug_log.writef(
        allocator,
        "jackett",
        "HTTP link downloaded to temp torrent",
        .{},
    );
    return .{
        .value = path,
        .kind = .torrent_file,
    };
}

fn writeTempTorrentFile(allocator: std.mem.Allocator, bytes: []const u8) LinkResolveError![]u8 {
    const temp_dir = try getTempDir(allocator);
    defer allocator.free(temp_dir);

    var random_bytes: [12]u8 = undefined;
    var hex_buf: [24]u8 = undefined;

    var attempts: usize = 0;
    while (attempts < 8) : (attempts += 1) {
        std.crypto.random.bytes(&random_bytes);
        const hex = std.fmt.bytesToHex(random_bytes, .lower);
        @memcpy(hex_buf[0..], hex[0..]);

        const filename = try std.fmt.allocPrint(allocator, "supersearchr-{s}.torrent", .{hex_buf[0..]});
        defer allocator.free(filename);
        const path = try std.fs.path.join(allocator, &.{ temp_dir, filename });
        errdefer allocator.free(path);

        const file = std.fs.createFileAbsolute(path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => return error.TempFileCreateFailed,
        };
        defer file.close();

        file.writeAll(bytes) catch |err| switch (err) {
            else => return error.TempFileWriteFailed,
        };

        return path;
    }

    return error.TempFileCreateFailed;
}

fn getTempDir(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "TMPDIR")) |value| {
        if (value.len > 0) return value;
        allocator.free(value);
    } else |_| {}

    return allocator.dupe(u8, "/tmp");
}

pub fn defaultLinkFetchExecutor(allocator: std.mem.Allocator, url: []const u8) LinkResolveError!LinkFetchResponse {
    var http_client = std.http.Client{ .allocator = allocator };
    defer http_client.deinit();

    const uri = std.Uri.parse(url) catch |err| {
        debug_log.writef(
            allocator,
            "jackett",
            "Failed to parse Jackett download URL err={s}",
            .{@errorName(err)},
        );
        return error.InvalidUrl;
    };
    var request = http_client.request(.GET, uri, .{ .redirect_behavior = .unhandled }) catch |err| {
        debug_log.writef(
            allocator,
            "jackett",
            "Failed to create Jackett download request err={s}",
            .{@errorName(err)},
        );
        return mapAnyToLinkResolveError(err, error.RequestCreateFailed);
    };
    defer request.deinit();

    request.sendBodiless() catch |err| {
        debug_log.writef(
            allocator,
            "jackett",
            "Failed to send Jackett download request err={s}",
            .{@errorName(err)},
        );
        return mapAnyToLinkResolveError(err, error.RequestSendFailed);
    };
    var header_buf: [64 * 1024]u8 = undefined;
    var response = request.receiveHead(&header_buf) catch |err| {
        debug_log.writef(
            allocator,
            "jackett",
            "Failed to receive Jackett download response head err={s}",
            .{@errorName(err)},
        );
        return mapAnyToLinkResolveError(err, error.ResponseHeadReadFailed);
    };

    const location = if (response.head.location) |raw_location|
        allocator.dupe(u8, raw_location) catch return error.OutOfMemory
    else
        null;
    errdefer if (location) |owned_location| allocator.free(owned_location);

    if (response.head.status != .ok) {
        return .{
            .status = response.head.status,
            .location = location,
        };
    }

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => allocator.alloc(u8, std.compress.zstd.default_window_len) catch return error.OutOfMemory,
        .deflate, .gzip => allocator.alloc(u8, std.compress.flate.max_window_len) catch return error.OutOfMemory,
        .compress => return error.ResponseReadFailed,
    };
    defer if (decompress_buffer.len != 0) allocator.free(decompress_buffer);

    var read_buf: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&read_buf, &decompress, decompress_buffer);
    const body = reader.allocRemaining(allocator, .unlimited) catch |err| {
        if (location) |owned_location| allocator.free(owned_location);
        return mapAnyToLinkResolveError(err, error.ResponseReadFailed);
    };

    return .{
        .status = response.head.status,
        .location = location,
        .body = body,
    };
}

pub fn defaultBodyExecutor(allocator: std.mem.Allocator, url: []const u8) JackettError![]u8 {
    var http_client = std.http.Client{ .allocator = allocator };
    defer http_client.deinit();

    const uri = std.Uri.parse(url) catch |err| {
        debug_log.writef(
            allocator,
            "jackett",
            "Failed to parse Jackett URL err={s} url=\"{s}\"",
            .{ @errorName(err), url },
        );
        return error.InvalidUrl;
    };
    var request = http_client.request(.GET, uri, .{}) catch |err| {
        debug_log.writef(
            allocator,
            "jackett",
            "Failed to create Jackett request err={s} url=\"{s}\"",
            .{ @errorName(err), url },
        );
        return mapAnyToJackettError(err, error.RequestCreateFailed);
    };
    defer request.deinit();

    request.sendBodiless() catch |err| {
        debug_log.writef(
            allocator,
            "jackett",
            "Failed to send Jackett request err={s} url=\"{s}\"",
            .{ @errorName(err), url },
        );
        return mapAnyToJackettError(err, error.RequestSendFailed);
    };
    var header_buf: [1024]u8 = undefined;
    var response = request.receiveHead(&header_buf) catch |err| {
        debug_log.writef(
            allocator,
            "jackett",
            "Failed to receive Jackett response head err={s} url=\"{s}\"",
            .{ @errorName(err), url },
        );
        return mapAnyToJackettError(err, error.ResponseHeadReadFailed);
    };

    const status = response.head.status;
    if (status != .ok) {
        debug_log.writef(
            allocator,
            "jackett",
            "Jackett returned non-OK status status={s} url=\"{s}\"",
            .{ @tagName(status), url },
        );
        return error.HttpError;
    }

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => allocator.alloc(u8, std.compress.zstd.default_window_len) catch |err| {
            debug_log.writef(
                allocator,
                "jackett",
                "Failed to allocate Jackett decompression buffer err={s} url=\"{s}\"",
                .{ @errorName(err), url },
            );
            return error.OutOfMemory;
        },
        .deflate, .gzip => allocator.alloc(u8, std.compress.flate.max_window_len) catch |err| {
            debug_log.writef(
                allocator,
                "jackett",
                "Failed to allocate Jackett decompression buffer err={s} url=\"{s}\"",
                .{ @errorName(err), url },
            );
            return error.OutOfMemory;
        },
        .compress => {
            debug_log.writef(
                allocator,
                "jackett",
                "Jackett returned unsupported content encoding url=\"{s}\"",
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
            "jackett",
            "Failed to read Jackett response body err={s} url=\"{s}\"",
            .{ @errorName(err), url },
        );
        return mapAnyToJackettError(err, error.ResponseReadFailed);
    };

    return body;
}

pub const Indexer = struct {
    id: []u8,
};

const ParallelSearchContext = struct {
    allocator: std.mem.Allocator,
    executor: BodyExecutor,
    base_url: []const u8,
    api_key: []const u8,
    encoded_query: []const u8,
    indexers: []const Indexer,
    next_index: std.atomic.Value(usize),
    progress: *SearchProgress,
    results: std.ArrayList(Torrent),
    mutex: std.Thread.Mutex,
    first_error: ?JackettError,
    failures: usize,
};

pub const SearchBatch = struct {
    torrents: []Torrent,

    pub fn deinit(self: *SearchBatch, allocator: std.mem.Allocator) void {
        for (self.torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(self.torrents);
        self.* = undefined;
    }
};

const StreamingSearchContext = struct {
    allocator: std.mem.Allocator,
    executor: BodyExecutor,
    base_url: []const u8,
    api_key: []const u8,
    encoded_query: []const u8,
    indexers: []const Indexer,
    next_index: std.atomic.Value(usize),
    progress: *SearchProgress,
    queue: *SearchBatchQueue,
};

const SearchBatchQueue = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    batches: std.ArrayList(SearchBatch) = .{},
    first_error: ?JackettError = null,
    failures: usize = 0,

    fn push(self: *SearchBatchQueue, batch: SearchBatch) JackettError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.batches.append(self.allocator, batch) catch return error.OutOfMemory;
    }

    fn pop(self: *SearchBatchQueue) ?SearchBatch {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.batches.items.len == 0) return null;
        return self.batches.orderedRemove(0);
    }

    fn recordFailure(self: *SearchBatchQueue, err: JackettError) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.first_error == null) self.first_error = err;
        self.failures += 1;
    }

    fn setFatal(self: *SearchBatchQueue, err: JackettError) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.first_error = err;
    }

    fn fatalError(self: *SearchBatchQueue) ?JackettError {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.first_error;
    }

    fn deinit(self: *SearchBatchQueue) void {
        for (self.batches.items) |*batch| {
            batch.deinit(self.allocator);
        }
        self.batches.deinit(self.allocator);
    }
};

pub const SearchSession = struct {
    thread_safe_allocator: std.heap.ThreadSafeAllocator,
    executor: BodyExecutor,
    base_url: []u8,
    api_key: []u8,
    query: []u8,
    max_parallel: usize,
    progress: SearchProgress,
    queue: SearchBatchQueue,
    coordinator_thread: ?std.Thread = null,
    done: std.atomic.Value(bool),
    fatal_discovery_error: std.atomic.Value(bool),

    fn allocator(self: *SearchSession) std.mem.Allocator {
        return self.thread_safe_allocator.allocator();
    }

    pub fn snapshot(self: *SearchSession) SearchProgressSnapshot {
        return self.progress.snapshot();
    }

    pub fn fatalError(self: *SearchSession) ?JackettError {
        if (!self.fatal_discovery_error.load(.acquire)) return null;
        return self.queue.fatalError();
    }

    pub fn isDone(self: *SearchSession) bool {
        return self.done.load(.acquire);
    }

    pub fn drainInto(self: *SearchSession, dst_allocator: std.mem.Allocator, dst: *std.ArrayList(Torrent)) JackettError!bool {
        var changed = false;
        while (self.queue.pop()) |batch_value| {
            var batch = batch_value;
            defer batch.deinit(self.allocator());
            for (batch.torrents) |torrent| {
                const cloned = try cloneTorrent(dst_allocator, torrent);
                errdefer {
                    dst_allocator.free(cloned.title);
                    dst_allocator.free(cloned.link);
                }
                try dst.append(dst_allocator, cloned);
            }
            changed = true;
        }
        if (changed) sortTorrents(dst.items);
        return changed;
    }

    pub fn abandon(self: *SearchSession) void {
        if (self.coordinator_thread) |thread| {
            thread.detach();
            self.coordinator_thread = null;
        }
    }

    pub fn deinit(self: *SearchSession) void {
        if (self.coordinator_thread) |thread| {
            thread.join();
            self.coordinator_thread = null;
        }
        self.destroy();
    }

    fn destroy(self: *SearchSession) void {
        const allocator_value = self.allocator();
        self.queue.deinit();
        allocator_value.free(self.base_url);
        allocator_value.free(self.api_key);
        allocator_value.free(self.query);
        std.heap.page_allocator.destroy(self);
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    api_key: []const u8,

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8, api_key: []const u8) Client {
        return .{
            .allocator = allocator,
            .base_url = base_url,
            .api_key = api_key,
        };
    }

    pub fn deinit(self: *Client) void {
        _ = self;
    }

    pub fn searchIndexersInParallel(
        self: *Client,
        query: []const u8,
        executor: BodyExecutor,
        progress: *SearchProgress,
        max_parallel: usize,
    ) JackettError![]Torrent {
        progress.setPhase(.discovering);

        const indexers = try self.fetchConfiguredIndexers(executor);
        defer freeIndexers(self.allocator, indexers);

        progress.setTotal(indexers.len);
        progress.setPhase(.querying);

        if (indexers.len == 0) {
            progress.setPhase(.done);
            return try self.allocator.alloc(Torrent, 0);
        }

        const encoded_query = try percentEncode(self.allocator, query);
        defer self.allocator.free(encoded_query);

        var thread_safe_allocator = std.heap.ThreadSafeAllocator{ .child_allocator = self.allocator };
        const allocator = thread_safe_allocator.allocator();

        var ctx = ParallelSearchContext{
            .allocator = allocator,
            .executor = executor,
            .base_url = self.base_url,
            .api_key = self.api_key,
            .encoded_query = encoded_query,
            .indexers = indexers,
            .next_index = std.atomic.Value(usize).init(0),
            .progress = progress,
            .results = .{},
            .mutex = .{},
            .first_error = null,
            .failures = 0,
        };
        errdefer {
            for (ctx.results.items) |t| {
                allocator.free(t.title);
                allocator.free(t.link);
            }
            ctx.results.deinit(allocator);
        }

        const worker_count = @min(@max(max_parallel, @as(usize, 1)), indexers.len);
        var threads = try self.allocator.alloc(std.Thread, worker_count);
        defer self.allocator.free(threads);

        var spawned: usize = 0;
        errdefer {
            for (threads[0..spawned]) |thread| {
                thread.join();
            }
        }

        while (spawned < worker_count) : (spawned += 1) {
            threads[spawned] = std.Thread.spawn(.{}, parallelSearchWorker, .{&ctx}) catch return error.RequestSendFailed;
        }

        for (threads) |thread| {
            thread.join();
        }

        progress.setPhase(.done);

        if (ctx.results.items.len == 0 and ctx.failures == indexers.len) {
            return ctx.first_error orelse error.ParseFailed;
        }

        sortTorrents(ctx.results.items);
        return ctx.results.toOwnedSlice(allocator);
    }

    pub fn startStreamingSearch(
        self: *Client,
        query: []const u8,
        executor: BodyExecutor,
        max_parallel: usize,
    ) JackettError!*SearchSession {
        const session = std.heap.page_allocator.create(SearchSession) catch return error.OutOfMemory;
        session.* = .{
            .thread_safe_allocator = .{ .child_allocator = std.heap.page_allocator },
            .executor = executor,
            .base_url = &.{},
            .api_key = &.{},
            .query = &.{},
            .max_parallel = max_parallel,
            .progress = SearchProgress.init(),
            .queue = undefined,
            .done = std.atomic.Value(bool).init(false),
            .fatal_discovery_error = std.atomic.Value(bool).init(false),
        };
        const allocator = session.allocator();
        session.queue = .{ .allocator = allocator };
        errdefer std.heap.page_allocator.destroy(session);
        session.base_url = allocator.dupe(u8, self.base_url) catch return error.OutOfMemory;
        errdefer allocator.free(session.base_url);
        session.api_key = allocator.dupe(u8, self.api_key) catch return error.OutOfMemory;
        errdefer allocator.free(session.api_key);
        session.query = allocator.dupe(u8, query) catch return error.OutOfMemory;
        errdefer {
            allocator.free(session.query);
            session.queue.deinit();
        }

        session.coordinator_thread = std.Thread.spawn(.{}, streamingCoordinator, .{session}) catch return error.RequestSendFailed;
        return session;
    }

    fn fetchConfiguredIndexers(self: *Client, executor: BodyExecutor) JackettError![]Indexer {
        return fetchConfiguredIndexersOwned(self.allocator, self.base_url, self.api_key, executor);
    }
};

fn percentEncode(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);
    for (raw) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => {
                try result.append(allocator, c);
            },
            else => {
                var buf: [3]u8 = undefined;
                const encoded = std.fmt.bufPrint(&buf, "%{X:0>2}", .{c}) catch unreachable;
                try result.appendSlice(allocator, encoded);
            },
        }
    }
    return result.toOwnedSlice(allocator);
}

fn parallelSearchWorker(ctx: *ParallelSearchContext) void {
    while (true) {
        const idx = ctx.next_index.fetchAdd(1, .monotonic);
        if (idx >= ctx.indexers.len) return;

        searchSingleIndexer(ctx, ctx.indexers[idx].id) catch |err| {
            ctx.mutex.lock();
            if (ctx.first_error == null) ctx.first_error = err;
            ctx.failures += 1;
            ctx.mutex.unlock();
            ctx.progress.recordFailed();
        };
        ctx.progress.recordCompleted();
    }
}

fn streamingCoordinator(session: *SearchSession) void {
    const allocator = session.allocator();
    session.progress.setPhase(.discovering);

    const indexers = fetchConfiguredIndexersOwned(
        allocator,
        session.base_url,
        session.api_key,
        session.executor,
    ) catch |err| {
        session.queue.setFatal(err);
        session.fatal_discovery_error.store(true, .release);
        session.progress.setPhase(.done);
        session.done.store(true, .release);
        return;
    };
    defer freeIndexers(allocator, indexers);

    session.progress.setTotal(indexers.len);
    session.progress.setPhase(.querying);

    if (indexers.len == 0) {
        session.progress.setPhase(.done);
        session.done.store(true, .release);
        return;
    }

    const encoded_query = percentEncode(allocator, session.query) catch {
        session.queue.setFatal(error.OutOfMemory);
        session.fatal_discovery_error.store(true, .release);
        session.progress.setPhase(.done);
        session.done.store(true, .release);
        return;
    };
    defer allocator.free(encoded_query);

    var ctx = StreamingSearchContext{
        .allocator = allocator,
        .executor = session.executor,
        .base_url = session.base_url,
        .api_key = session.api_key,
        .encoded_query = encoded_query,
        .indexers = indexers,
        .next_index = std.atomic.Value(usize).init(0),
        .progress = &session.progress,
        .queue = &session.queue,
    };

    const worker_count = @min(@max(session.max_parallel, @as(usize, 1)), indexers.len);
    const threads = allocator.alloc(std.Thread, worker_count) catch {
        session.queue.setFatal(error.OutOfMemory);
        session.fatal_discovery_error.store(true, .release);
        session.progress.setPhase(.done);
        session.done.store(true, .release);
        return;
    };
    defer allocator.free(threads);

    var spawned: usize = 0;
    while (spawned < worker_count) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, streamingSearchWorker, .{&ctx}) catch {
            session.queue.setFatal(error.RequestSendFailed);
            session.fatal_discovery_error.store(true, .release);
            break;
        };
    }

    for (threads[0..spawned]) |thread| {
        thread.join();
    }

    session.progress.setPhase(.done);
    session.done.store(true, .release);
}

fn streamingSearchWorker(ctx: *StreamingSearchContext) void {
    while (true) {
        const idx = ctx.next_index.fetchAdd(1, .monotonic);
        if (idx >= ctx.indexers.len) return;

        searchSingleIndexerStreaming(ctx, ctx.indexers[idx].id) catch |err| {
            ctx.queue.recordFailure(err);
            ctx.progress.recordFailed();
        };
        ctx.progress.recordCompleted();
    }
}

fn searchSingleIndexer(ctx: *ParallelSearchContext, indexer_id: []const u8) JackettError!void {
    const encoded_indexer = try percentEncode(ctx.allocator, indexer_id);
    defer ctx.allocator.free(encoded_indexer);

    const url = try std.fmt.allocPrint(
        ctx.allocator,
        "{s}/api/v2.0/indexers/{s}/results/torznab/api?apikey={s}&t=search&q={s}",
        .{ ctx.base_url, encoded_indexer, ctx.api_key, ctx.encoded_query },
    );
    defer ctx.allocator.free(url);

    const body = try ctx.executor(ctx.allocator, url);
    defer ctx.allocator.free(body);

    const torrents = parseTorrents(ctx.allocator, body) catch |err| return mapAnyToJackettError(err, error.ParseFailed);
    defer ctx.allocator.free(torrents);

    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    ctx.results.appendSlice(ctx.allocator, torrents) catch {
        for (torrents) |t| {
            ctx.allocator.free(t.title);
            ctx.allocator.free(t.link);
        }
        return error.OutOfMemory;
    };
}

fn searchSingleIndexerStreaming(ctx: *StreamingSearchContext, indexer_id: []const u8) JackettError!void {
    const encoded_indexer = try percentEncode(ctx.allocator, indexer_id);
    defer ctx.allocator.free(encoded_indexer);

    const url = try std.fmt.allocPrint(
        ctx.allocator,
        "{s}/api/v2.0/indexers/{s}/results/torznab/api?apikey={s}&t=search&q={s}",
        .{ ctx.base_url, encoded_indexer, ctx.api_key, ctx.encoded_query },
    );
    defer ctx.allocator.free(url);

    const body = try ctx.executor(ctx.allocator, url);
    defer ctx.allocator.free(body);

    const torrents = parseTorrents(ctx.allocator, body) catch |err| return mapAnyToJackettError(err, error.ParseFailed);
    errdefer {
        for (torrents) |t| {
            ctx.allocator.free(t.title);
            ctx.allocator.free(t.link);
        }
        ctx.allocator.free(torrents);
    }

    try ctx.queue.push(.{ .torrents = torrents });
}

fn fetchConfiguredIndexersOwned(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    api_key: []const u8,
    executor: BodyExecutor,
) JackettError![]Indexer {
    const url = try std.fmt.allocPrint(
        allocator,
        "{s}/api/v2.0/indexers/all/results/torznab/api?apikey={s}&t=indexers&configured=true",
        .{ base_url, api_key },
    );
    defer allocator.free(url);

    const body = try executor(allocator, url);
    defer allocator.free(body);

    return parseIndexers(allocator, body) catch |err| mapAnyToJackettError(err, error.ParseFailed);
}

fn parseIndexers(allocator: std.mem.Allocator, xml: []const u8) ![]Indexer {
    if (std.mem.indexOf(u8, xml, "<indexers") == null) return error.ParseFailed;

    var indexers: std.ArrayList(Indexer) = .{};
    errdefer {
        for (indexers.items) |indexer| {
            allocator.free(indexer.id);
        }
        indexers.deinit(allocator);
    }

    var i: usize = 0;
    while (i < xml.len) {
        if (!std.mem.startsWith(u8, xml[i..], xml_tags.indexer)) {
            i += 1;
            continue;
        }

        const tag_end = std.mem.indexOfScalarPos(u8, xml, i, '>') orelse break;
        const tag = xml[i .. tag_end + 1];
        const id_pos = std.mem.indexOf(u8, tag, xml_tags.indexer_id) orelse {
            i = tag_end + 1;
            continue;
        };
        const id_start = i + id_pos + xml_tags.indexer_id.len;
        const id_end = std.mem.indexOfScalarPos(u8, xml, id_start, '"') orelse {
            i = tag_end + 1;
            continue;
        };

        try indexers.append(allocator, .{
            .id = try allocator.dupe(u8, xml[id_start..id_end]),
        });

        if (std.mem.indexOfPos(u8, xml, tag_end + 1, xml_tags.indexer_end)) |end_pos| {
            i = end_pos + xml_tags.indexer_end.len;
        } else {
            i = tag_end + 1;
        }
    }

    return indexers.toOwnedSlice(allocator);
}

fn freeIndexers(allocator: std.mem.Allocator, indexers: []Indexer) void {
    for (indexers) |indexer| {
        allocator.free(indexer.id);
    }
    allocator.free(indexers);
}

fn sortTorrents(torrents: []Torrent) void {
    std.mem.sort(Torrent, torrents, {}, struct {
        fn lessThan(_: void, a: Torrent, b: Torrent) bool {
            return a.seeders > b.seeders;
        }
    }.lessThan);
}

fn cloneTorrent(allocator: std.mem.Allocator, torrent: Torrent) !Torrent {
    const title = try allocator.dupe(u8, torrent.title);
    errdefer allocator.free(title);
    const link = try allocator.dupe(u8, torrent.link);
    return .{
        .title = title,
        .seeders = torrent.seeders,
        .leechers = torrent.leechers,
        .size_bytes = torrent.size_bytes,
        .link = link,
    };
}

fn parseTorrents(allocator: std.mem.Allocator, xml: []const u8) ![]Torrent {
    var torrents: std.ArrayList(Torrent) = .{};
    errdefer {
        for (torrents.items) |*t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        torrents.deinit(allocator);
    }

    var i: usize = 0;
    while (i < xml.len) {
        if (std.mem.startsWith(u8, xml[i..], xml_tags.item)) {
            i += xml_tags.item.len;
            var title: ?[]const u8 = null;
            var link: ?[]const u8 = null;
            var link_priority: u8 = 0;
            var link_source: []const u8 = "none";
            var seeders: u32 = 0;
            var peers: u32 = 0;
            var size_bytes: ?u64 = null;
            var explicit_size_seen = false;
            var enclosure_size_bytes: ?u64 = null;

            while (i < xml.len) {
                if (extractStringField(xml, i, xml_tags.item_end)) |_| {
                    break;
                }
                if (extractStringField(xml, i, xml_tags.title)) |result| {
                    title = result.value;
                    i = result.end;
                } else if (extractOptionalU64Element(xml, i, xml_tags.size)) |result| {
                    explicit_size_seen = true;
                    size_bytes = result.value;
                    i = result.end;
                } else if (extractMagnetUrlAttr(xml, i)) |result| {
                    if (link_priority < 2) {
                        link = result.value;
                        link_priority = 2;
                        link_source = "torznab:attr magneturl";
                    }
                    i = result.end;
                } else if (extractTorznabSizeAttr(xml, i)) |result| {
                    explicit_size_seen = true;
                    size_bytes = result.value;
                    i = result.end;
                } else if (extractStringField(xml, i, xml_tags.link)) |result| {
                    if (link_priority < 1) {
                        link = result.value;
                        link_priority = 1;
                        link_source = "link";
                    }
                    i = result.end;
                } else if (extractEnclosureInfo(xml, i)) |result| {
                    if (result.url) |url| {
                        if (link_priority < 3) {
                            link = url;
                            link_priority = 3;
                            link_source = "enclosure url";
                        }
                    }
                    enclosure_size_bytes = result.length;
                    i = result.end;
                } else if (extractEnclosureUrl(xml, i)) |result| {
                    if (link_priority < 3) {
                        link = result.value;
                        link_priority = 3;
                        link_source = "enclosure url";
                    }
                    i = result.end;
                } else if (extractIntField(xml, i, xml_tags.seeders_attr, 0)) |result| {
                    seeders = result.value;
                    i = result.end;
                } else if (extractIntField(xml, i, xml_tags.peers_attr, 0)) |result| {
                    peers = result.value;
                    i = result.end;
                } else {
                    i += 1;
                }
            }

            if (title != null and link != null) {
                const title_copy = try allocator.dupe(u8, title.?);
                const link_copy = try normalizeLink(allocator, link.?);
                if (link_copy.len == 0) {
                    allocator.free(title_copy);
                    allocator.free(link_copy);
                    debug_log.writef(
                        allocator,
                        "jackett",
                        "Skipping torrent with empty normalized link title=\"{s}\" source={s}",
                        .{ title.?, link_source },
                    );
                    continue;
                }
                try torrents.append(allocator, .{
                    .title = title_copy,
                    .seeders = seeders,
                    .leechers = peers,
                    .size_bytes = if (explicit_size_seen) size_bytes else enclosure_size_bytes,
                    .link = link_copy,
                });
                debug_log.writef(
                    allocator,
                    "jackett",
                    "Parsed torrent title=\"{s}\" source={s} link=\"{s}\"",
                    .{ title.?, link_source, link_copy },
                );
            } else if (title != null) {
                debug_log.writef(
                    allocator,
                    "jackett",
                    "Skipping torrent without link title=\"{s}\"",
                    .{title.?},
                );
            }
        } else {
            i += 1;
        }
    }

    sortTorrents(torrents.items);

    return torrents.toOwnedSlice(allocator);
}

test "parse XML with valid response" {
    const allocator = std.testing.allocator;

    const xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><rss version=\"1.0\"><channel><item><title>Movie.2024.1080p.WEB.h264</title><link>magnet:?xt=urn:btih:abc123</link><torznab:attr name=\"seeders\" value=\"100\"/><torznab:attr name=\"peers\" value=\"50\"/></item><item><title>Movie.2024.720p.WEB.h264</title><link>magnet:?xt=urn:btih:def456</link><torznab:attr name=\"seeders\" value=\"200\"/><torznab:attr name=\"peers\" value=\"75\"/></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(usize, 2), torrents.len);
    try std.testing.expectEqualStrings("Movie.2024.720p.WEB.h264", torrents[0].title);
    try std.testing.expectEqual(@as(u32, 200), torrents[0].seeders);
    try std.testing.expectEqual(@as(u32, 75), torrents[0].leechers);
    try std.testing.expectEqualStrings("Movie.2024.1080p.WEB.h264", torrents[1].title);
    try std.testing.expectEqual(@as(u32, 100), torrents[1].seeders);
}

test "parse torrent size from size element" {
    const allocator = std.testing.allocator;

    const xml = "<rss><channel><item><title>Has Size</title><size>536870912</size><link>magnet:?xt=urn:btih:size</link><torznab:attr name=\"seeders\" value=\"1\"/></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(usize, 1), torrents.len);
    try std.testing.expectEqual(@as(?u64, 536870912), torrents[0].size_bytes);
}

test "parse torrent size from torznab size attr" {
    const allocator = std.testing.allocator;

    const xml = "<rss><channel><item><title>Has Attr Size</title><link>magnet:?xt=urn:btih:sizeattr</link><torznab:attr name=\"size\" value=\"1073741824\"/></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(usize, 1), torrents.len);
    try std.testing.expectEqual(@as(?u64, 1073741824), torrents[0].size_bytes);
}

test "parse torrent size from enclosure length fallback" {
    const allocator = std.testing.allocator;

    const xml = "<rss><channel><item><title>Has Enclosure Length</title><enclosure length=\"2147483648\" url=\"https://example.com/size.torrent\" type=\"application/x-bittorrent\"/></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(usize, 1), torrents.len);
    try std.testing.expectEqualStrings("https://example.com/size.torrent", torrents[0].link);
    try std.testing.expectEqual(@as(?u64, 2147483648), torrents[0].size_bytes);
}

test "parse missing and invalid torrent sizes as null" {
    const allocator = std.testing.allocator;

    const xml = "<rss><channel><item><title>Missing Size</title><link>magnet:?xt=urn:btih:missing</link><torznab:attr name=\"seeders\" value=\"2\"/></item><item><title>Invalid Size</title><size>not-bytes</size><link>magnet:?xt=urn:btih:invalid</link><enclosure length=\"1073741824\" url=\"magnet:?xt=urn:btih:ignored\"/></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(usize, 2), torrents.len);
    try std.testing.expectEqualStrings("Missing Size", torrents[0].title);
    try std.testing.expectEqual(@as(?u64, null), torrents[0].size_bytes);
    try std.testing.expectEqualStrings("Invalid Size", torrents[1].title);
    try std.testing.expectEqual(@as(?u64, null), torrents[1].size_bytes);
}

test "parse configured indexers from Jackett indexer response" {
    const allocator = std.testing.allocator;

    const xml = "<indexers><indexer id=\"1337x\"><title>1337x</title></indexer><indexer id=\"thepiratebay\"><title>The Pirate Bay</title></indexer></indexers>";

    const indexers = try parseIndexers(allocator, xml);
    defer freeIndexers(allocator, indexers);

    try std.testing.expectEqual(@as(usize, 2), indexers.len);
    try std.testing.expectEqualStrings("1337x", indexers[0].id);
    try std.testing.expectEqualStrings("thepiratebay", indexers[1].id);
}

fn gzipStoredBody(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    if (body.len > std.math.maxInt(u16)) return error.OutOfMemory;

    var result: std.ArrayList(u8) = .{};
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

const GzipHttpServer = struct {
    body: []const u8,

    fn serve(self: *const GzipHttpServer, server: *std.net.Server) !void {
        const connection = try server.accept();
        defer connection.stream.close();

        var request_buf: [1024]u8 = undefined;
        _ = try connection.stream.read(&request_buf);

        var response_head: [256]u8 = undefined;
        const head = try std.fmt.bufPrint(
            &response_head,
            "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{self.body.len},
        );
        try connection.stream.writeAll(head);
        try connection.stream.writeAll(self.body);
    }
};

test "default body executor decompresses gzip indexer discovery response" {
    const allocator = std.testing.allocator;
    const xml = "<indexers><indexer id=\"alpha\"><title>Alpha</title></indexer><indexer id=\"beta\"><title>Beta</title></indexer></indexers>";

    const gzipped = try gzipStoredBody(allocator, xml);
    defer allocator.free(gzipped);

    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    const handler = GzipHttpServer{ .body = gzipped };
    const thread = try std.Thread.spawn(.{}, GzipHttpServer.serve, .{ &handler, &server });

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/api/v2.0/indexers/all/results/torznab/api?apikey=test&t=indexers&configured=true", .{server.listen_address.getPort()});
    defer allocator.free(url);

    const body = try defaultBodyExecutor(allocator, url);
    defer allocator.free(body);
    thread.join();

    try std.testing.expectEqualStrings(xml, body);

    const indexers = try parseIndexers(allocator, body);
    defer freeIndexers(allocator, indexers);
    try std.testing.expectEqual(@as(usize, 2), indexers.len);
    try std.testing.expectEqualStrings("alpha", indexers[0].id);
    try std.testing.expectEqualStrings("beta", indexers[1].id);
}

test "parse configured indexers rejects non-indexer response" {
    try std.testing.expectError(error.ParseFailed, parseIndexers(std.testing.allocator, "\x1f\x8b compressed or html"));
}

test "parallel indexer search merges sorted results and updates progress" {
    const state = struct {
        var indexer_calls = std.atomic.Value(usize).init(0);
        var alpha_calls = std.atomic.Value(usize).init(0);
        var beta_calls = std.atomic.Value(usize).init(0);

        fn exec(allocator: std.mem.Allocator, url: []const u8) JackettError![]u8 {
            if (std.mem.indexOf(u8, url, "t=indexers&configured=true") != null) {
                _ = indexer_calls.fetchAdd(1, .monotonic);
                return allocator.dupe(u8, "<indexers><indexer id=\"alpha\"><title>Alpha</title></indexer><indexer id=\"beta\"><title>Beta</title></indexer></indexers>") catch error.OutOfMemory;
            }
            if (std.mem.indexOf(u8, url, "/indexers/alpha/") != null) {
                _ = alpha_calls.fetchAdd(1, .monotonic);
                std.Thread.sleep(10 * std.time.ns_per_ms);
                return allocator.dupe(u8, "<rss><channel><item><title>Alpha Result</title><link>magnet:?xt=urn:btih:alpha</link><torznab:attr name=\"seeders\" value=\"10\"/></item></channel></rss>") catch error.OutOfMemory;
            }
            if (std.mem.indexOf(u8, url, "/indexers/beta/") != null) {
                _ = beta_calls.fetchAdd(1, .monotonic);
                return allocator.dupe(u8, "<rss><channel><item><title>Beta Result</title><link>magnet:?xt=urn:btih:beta</link><torznab:attr name=\"seeders\" value=\"50\"/></item></channel></rss>") catch error.OutOfMemory;
            }
            return error.InvalidUrl;
        }
    };
    state.indexer_calls.store(0, .monotonic);
    state.alpha_calls.store(0, .monotonic);
    state.beta_calls.store(0, .monotonic);

    var client = Client.init(std.testing.allocator, "http://localhost:9117", "test-key");
    var progress = SearchProgress.init();
    const torrents = try client.searchIndexersInParallel("ubuntu", state.exec, &progress, 2);
    defer {
        for (torrents) |t| {
            std.testing.allocator.free(t.title);
            std.testing.allocator.free(t.link);
        }
        std.testing.allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(usize, 1), state.indexer_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), state.alpha_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), state.beta_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 2), torrents.len);
    try std.testing.expectEqualStrings("Beta Result", torrents[0].title);
    try std.testing.expectEqualStrings("Alpha Result", torrents[1].title);

    const snapshot = progress.snapshot();
    try std.testing.expectEqual(ProgressPhase.done, snapshot.phase);
    try std.testing.expectEqual(@as(usize, 2), snapshot.total);
    try std.testing.expectEqual(@as(usize, 2), snapshot.completed);
    try std.testing.expectEqual(@as(usize, 0), snapshot.failed);
}

test "parallel indexer search returns empty when at least one empty indexer succeeds" {
    const state = struct {
        fn exec(allocator: std.mem.Allocator, url: []const u8) JackettError![]u8 {
            if (std.mem.indexOf(u8, url, "t=indexers&configured=true") != null) {
                return allocator.dupe(u8, "<indexers><indexer id=\"empty\"><title>Empty</title></indexer><indexer id=\"failing\"><title>Failing</title></indexer></indexers>") catch error.OutOfMemory;
            }
            if (std.mem.indexOf(u8, url, "/indexers/empty/") != null) {
                return allocator.dupe(u8, "<rss><channel></channel></rss>") catch error.OutOfMemory;
            }
            return error.HttpError;
        }
    };

    var client = Client.init(std.testing.allocator, "http://localhost:9117", "test-key");
    var progress = SearchProgress.init();
    const torrents = try client.searchIndexersInParallel("ubuntu", state.exec, &progress, 2);
    defer std.testing.allocator.free(torrents);

    try std.testing.expectEqual(@as(usize, 0), torrents.len);
    const snapshot = progress.snapshot();
    try std.testing.expectEqual(@as(usize, 2), snapshot.completed);
    try std.testing.expectEqual(@as(usize, 1), snapshot.failed);
}

test "streaming search publishes batches as indexers complete" {
    const state = struct {
        fn exec(allocator: std.mem.Allocator, url: []const u8) JackettError![]u8 {
            if (std.mem.indexOf(u8, url, "t=indexers&configured=true") != null) {
                return allocator.dupe(u8, "<indexers><indexer id=\"slow\"><title>Slow</title></indexer><indexer id=\"fast\"><title>Fast</title></indexer></indexers>") catch error.OutOfMemory;
            }
            if (std.mem.indexOf(u8, url, "/indexers/slow/") != null) {
                std.Thread.sleep(20 * std.time.ns_per_ms);
                return allocator.dupe(u8, "<rss><channel><item><title>Slow Result</title><link>magnet:?xt=urn:btih:slow</link><torznab:attr name=\"seeders\" value=\"10\"/></item></channel></rss>") catch error.OutOfMemory;
            }
            if (std.mem.indexOf(u8, url, "/indexers/fast/") != null) {
                return allocator.dupe(u8, "<rss><channel><item><title>Fast Result</title><link>magnet:?xt=urn:btih:fast</link><torznab:attr name=\"seeders\" value=\"50\"/></item></channel></rss>") catch error.OutOfMemory;
            }
            return error.InvalidUrl;
        }
    };

    var client = Client.init(std.testing.allocator, "http://localhost:9117", "test-key");
    const session = try client.startStreamingSearch("ubuntu", state.exec, 2);
    defer session.deinit();

    var results: std.ArrayList(Torrent) = .{};
    defer {
        for (results.items) |t| {
            std.testing.allocator.free(t.title);
            std.testing.allocator.free(t.link);
        }
        results.deinit(std.testing.allocator);
    }

    var saw_first_batch = false;
    var attempts: usize = 0;
    while (attempts < 200 and !session.isDone()) : (attempts += 1) {
        if (try session.drainInto(std.testing.allocator, &results)) {
            saw_first_batch = true;
            if (results.items.len == 1) break;
        }
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(saw_first_batch);
    try std.testing.expect(results.items.len >= 1);

    while (!session.isDone()) {
        _ = try session.drainInto(std.testing.allocator, &results);
        std.Thread.sleep(std.time.ns_per_ms);
    }
    _ = try session.drainInto(std.testing.allocator, &results);

    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expectEqualStrings("Fast Result", results.items[0].title);
    try std.testing.expectEqualStrings("Slow Result", results.items[1].title);

    const snapshot = session.snapshot();
    try std.testing.expectEqual(ProgressPhase.done, snapshot.phase);
    try std.testing.expectEqual(@as(usize, 2), snapshot.total);
    try std.testing.expectEqual(@as(usize, 2), snapshot.completed);
    try std.testing.expectEqual(@as(usize, 0), snapshot.failed);
}

test "streaming search keeps successful results when one indexer fails" {
    const state = struct {
        fn exec(allocator: std.mem.Allocator, url: []const u8) JackettError![]u8 {
            if (std.mem.indexOf(u8, url, "t=indexers&configured=true") != null) {
                return allocator.dupe(u8, "<indexers><indexer id=\"ok\"><title>OK</title></indexer><indexer id=\"bad\"><title>Bad</title></indexer></indexers>") catch error.OutOfMemory;
            }
            if (std.mem.indexOf(u8, url, "/indexers/ok/") != null) {
                return allocator.dupe(u8, "<rss><channel><item><title>OK Result</title><link>magnet:?xt=urn:btih:ok</link><torznab:attr name=\"seeders\" value=\"5\"/></item></channel></rss>") catch error.OutOfMemory;
            }
            return error.HttpError;
        }
    };

    var client = Client.init(std.testing.allocator, "http://localhost:9117", "test-key");
    const session = try client.startStreamingSearch("ubuntu", state.exec, 2);
    defer session.deinit();

    var results: std.ArrayList(Torrent) = .{};
    defer {
        for (results.items) |t| {
            std.testing.allocator.free(t.title);
            std.testing.allocator.free(t.link);
        }
        results.deinit(std.testing.allocator);
    }

    while (!session.isDone()) {
        _ = try session.drainInto(std.testing.allocator, &results);
        std.Thread.sleep(std.time.ns_per_ms);
    }
    _ = try session.drainInto(std.testing.allocator, &results);

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("OK Result", results.items[0].title);
    try std.testing.expect(session.fatalError() == null);

    const snapshot = session.snapshot();
    try std.testing.expectEqual(@as(usize, 2), snapshot.completed);
    try std.testing.expectEqual(@as(usize, 1), snapshot.failed);
}

test "streaming search reports discovery failure as fatal" {
    const state = struct {
        fn exec(_: std.mem.Allocator, _: []const u8) JackettError![]u8 {
            return error.ConnectionRefused;
        }
    };

    var client = Client.init(std.testing.allocator, "http://localhost:9117", "test-key");
    const session = try client.startStreamingSearch("ubuntu", state.exec, 2);
    defer session.deinit();

    while (!session.isDone()) {
        std.Thread.sleep(std.time.ns_per_ms);
    }

    try std.testing.expectEqual(@as(?JackettError, error.ConnectionRefused), session.fatalError());
    const snapshot = session.snapshot();
    try std.testing.expectEqual(ProgressPhase.done, snapshot.phase);
}

test "include non-magnet links" {
    const allocator = std.testing.allocator;

    const xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><rss version=\"1.0\"><channel><item><title>With Magnet</title><link>magnet:?xt=urn:btih:abc123</link><torznab:attr name=\"seeders\" value=\"100\"/></item><item><title>With Torrent Link</title><link>https://example.com/torrent.torrent</link><torznab:attr name=\"seeders\" value=\"200\"/></item><item><title>No Link</title></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(usize, 2), torrents.len);
    try std.testing.expectEqualStrings("With Torrent Link", torrents[0].title);
    try std.testing.expectEqual(@as(u32, 200), torrents[0].seeders);
    try std.testing.expectEqualStrings("With Magnet", torrents[1].title);
    try std.testing.expectEqual(@as(u32, 100), torrents[1].seeders);
}

test "resolve Jackett HTTP link to magnet redirect" {
    const mock = struct {
        fn fetch(allocator: std.mem.Allocator, url: []const u8) LinkResolveError!LinkFetchResponse {
            if (!std.mem.eql(u8, "https://jackett.local/dl/test", url)) return error.UnresolvableLink;
            return .{
                .status = @enumFromInt(302),
                .location = try allocator.dupe(u8, "magnet:?xt=urn:btih:redirected"),
            };
        }
    };

    var resolved = try resolveDownloadLink(std.testing.allocator, "https://jackett.local/dl/test", mock.fetch);
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqual(.magnet_redirect, resolved.kind);
    try std.testing.expectEqualStrings("magnet:?xt=urn:btih:redirected", resolved.value);
}

test "resolve Jackett HTTP link to temp torrent file" {
    const torrent_bytes = "d8:announce13:http://tracker4:info0:e";
    const mock = struct {
        fn fetch(allocator: std.mem.Allocator, url: []const u8) LinkResolveError!LinkFetchResponse {
            if (!std.mem.eql(u8, "https://jackett.local/dl/file", url)) return error.UnresolvableLink;
            return .{
                .status = .ok,
                .body = try allocator.dupe(u8, torrent_bytes),
            };
        }
    };

    var resolved = try resolveDownloadLink(std.testing.allocator, "https://jackett.local/dl/file", mock.fetch);
    defer resolved.deinit(std.testing.allocator);
    defer std.fs.deleteFileAbsolute(resolved.value) catch {};

    try std.testing.expectEqual(.torrent_file, resolved.kind);
    try std.testing.expect(std.mem.endsWith(u8, resolved.value, ".torrent"));

    const written = try std.fs.cwd().readFileAlloc(std.testing.allocator, resolved.value, 1024);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings(torrent_bytes, written);
}

test "resolve direct magnet passthrough" {
    const mock = struct {
        fn fetch(_: std.mem.Allocator, _: []const u8) LinkResolveError!LinkFetchResponse {
            unreachable;
        }
    };

    var resolved = try resolveDownloadLink(std.testing.allocator, "magnet:?xt=urn:btih:direct", mock.fetch);
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqual(.direct, resolved.kind);
    try std.testing.expectEqualStrings("magnet:?xt=urn:btih:direct", resolved.value);
}

test "resolve invalid HTTP link returns clear error" {
    const mock = struct {
        fn fetch(_: std.mem.Allocator, _: []const u8) LinkResolveError!LinkFetchResponse {
            return .{
                .status = @enumFromInt(302),
                .location = null,
            };
        }
    };

    try std.testing.expectError(
        error.UnresolvableLink,
        resolveDownloadLink(std.testing.allocator, "https://jackett.local/dl/missing-location", mock.fetch),
    );
}

test "sort by seeders descending" {
    const allocator = std.testing.allocator;

    const xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><rss version=\"1.0\"><channel><item><title>Low Seeders</title><link>magnet:?xt=urn:btih:aaa</link><torznab:attr name=\"seeders\" value=\"10\"/></item><item><title>High Seeders</title><link>magnet:?xt=urn:btih:bbb</link><torznab:attr name=\"seeders\" value=\"1000\"/></item><item><title>Medium Seeders</title><link>magnet:?xt=urn:btih:ccc</link><torznab:attr name=\"seeders\" value=\"100\"/></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(u32, 1000), torrents[0].seeders);
    try std.testing.expectEqual(@as(u32, 100), torrents[1].seeders);
    try std.testing.expectEqual(@as(u32, 10), torrents[2].seeders);
}

test "prefer enclosure over torznab magneturl and link" {
    const allocator = std.testing.allocator;

    const xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><rss version=\"1.0\"><channel><item><title>Has All Links</title><link>https://example.com/download.php?id=42</link><torznab:attr name=\"magneturl\" value=\"magnet:?xt=urn:btih:abc123&amp;dn=Test\"/><enclosure url=\"magnet:?xt=urn:btih:enclosure&amp;dn=Preferred\" type=\"application/x-bittorrent;x-scheme-handler/magnet\"/></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(usize, 1), torrents.len);
    try std.testing.expectEqualStrings("magnet:?xt=urn:btih:enclosure&dn=Preferred", torrents[0].link);
}

test "prefer torznab magneturl over link and decode entities" {
    const allocator = std.testing.allocator;

    const xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><rss version=\"1.0\"><channel><item><title>Has Magnet Attr</title><link>https://example.com/download.php?id=42</link><torznab:attr name=\"magneturl\" value=\"magnet:?xt=urn:btih:abc123&amp;dn=Test\"/></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(usize, 1), torrents.len);
    try std.testing.expectEqualStrings("magnet:?xt=urn:btih:abc123&dn=Test", torrents[0].link);
}

test "parse enclosure url when link tag is absent" {
    const allocator = std.testing.allocator;

    const xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><rss version=\"1.0\"><channel><item><title>Enclosure Only</title><enclosure url=\"https://example.com/download.php?id=987\" type=\"application/x-bittorrent\"/></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(usize, 1), torrents.len);
    try std.testing.expectEqualStrings("https://example.com/download.php?id=987", torrents[0].link);
}

test "decode numeric entities in links" {
    const allocator = std.testing.allocator;

    const xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><rss version=\"1.0\"><channel><item><title>Numeric Entities</title><link>magnet:?xt=urn:btih:abc123&#x26;dn=Hex&#38;tr=Dec</link></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(usize, 1), torrents.len);
    try std.testing.expectEqualStrings("magnet:?xt=urn:btih:abc123&dn=Hex&tr=Dec", torrents[0].link);
}

test "parse tolerates malformed or partial xml entries without failing" {
    const allocator = std.testing.allocator;

    const xml = "<rss><channel><item><title>Broken One<title><link>magnet:?xt=urn:btih:broken</link></item><item><title>Good One</title><link>magnet:?xt=urn:btih:good</link></item><item><title>No End";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expect(torrents.len >= 1);

    var saw_good = false;
    for (torrents) |t| {
        if (std.mem.eql(u8, t.title, "Good One")) saw_good = true;
    }
    try std.testing.expect(saw_good);
}

test "parse works with mixed field ordering inside item" {
    const allocator = std.testing.allocator;

    const xml = "<?xml version=\"1.0\"?><rss><channel><item><torznab:attr name=\"peers\" value=\"3\"/><link>magnet:?xt=urn:btih:first</link><title>First</title><torznab:attr name=\"seeders\" value=\"2\"/></item><item><torznab:attr name=\"seeders\" value=\"40\"/><title>Second</title><enclosure type=\"application/x-bittorrent\" url=\"https://example.com/second.torrent\"/><torznab:attr name=\"peers\" value=\"11\"/></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(usize, 2), torrents.len);
    try std.testing.expectEqualStrings("Second", torrents[0].title);
    try std.testing.expectEqual(@as(u32, 40), torrents[0].seeders);
    try std.testing.expectEqual(@as(u32, 11), torrents[0].leechers);
    try std.testing.expectEqualStrings("https://example.com/second.torrent", torrents[0].link);
    try std.testing.expectEqualStrings("First", torrents[1].title);
    try std.testing.expectEqual(@as(u32, 2), torrents[1].seeders);
    try std.testing.expectEqual(@as(u32, 3), torrents[1].leechers);
}
