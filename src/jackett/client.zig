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
    .link = "<link>",
    .enclosure = "<enclosure ",
    .magneturl_attr_name = "name=\"magneturl\"",
    .attr_value = "value=\"",
    .enclosure_url = "url=\"",
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

    fn fetchConfiguredIndexers(self: *Client, executor: BodyExecutor) JackettError![]Indexer {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/api/v2.0/indexers/all/results/torznab/api?apikey={s}&t=indexers&configured=true",
            .{ self.base_url, self.api_key },
        );
        defer self.allocator.free(url);

        const body = try executor(self.allocator, url);
        defer self.allocator.free(body);

        return parseIndexers(self.allocator, body) catch |err| mapAnyToJackettError(err, error.ParseFailed);
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

            while (i < xml.len) {
                if (extractStringField(xml, i, xml_tags.item_end)) |_| {
                    break;
                }
                if (extractStringField(xml, i, xml_tags.title)) |result| {
                    title = result.value;
                    i = result.end;
                } else if (extractMagnetUrlAttr(xml, i)) |result| {
                    if (link_priority < 2) {
                        link = result.value;
                        link_priority = 2;
                        link_source = "torznab:attr magneturl";
                    }
                    i = result.end;
                } else if (extractStringField(xml, i, xml_tags.link)) |result| {
                    if (link_priority < 1) {
                        link = result.value;
                        link_priority = 1;
                        link_source = "link";
                    }
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
