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

pub const SearchExecutor = *const fn (allocator: std.mem.Allocator, url: []const u8) JackettError![]Torrent;

pub fn defaultSearchExecutor(allocator: std.mem.Allocator, url: []const u8) JackettError![]Torrent {
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

    var read_buf: [4096]u8 = undefined;
    const reader = response.reader(&read_buf);
    const body = reader.allocRemaining(allocator, .unlimited) catch |err| {
        debug_log.writef(
            allocator,
            "jackett",
            "Failed to read Jackett response body err={s} url=\"{s}\"",
            .{ @errorName(err), url },
        );
        return mapAnyToJackettError(err, error.ResponseReadFailed);
    };
    defer allocator.free(body);

    const torrents = parseTorrents(allocator, body) catch |err| {
        debug_log.writef(
            allocator,
            "jackett",
            "Failed to parse Jackett response err={s} url=\"{s}\"",
            .{ @errorName(err), url },
        );
        return mapAnyToJackettError(err, error.ParseFailed);
    };

    return torrents;
}

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

    pub fn search(self: *Client, query: []const u8) JackettError![]Torrent {
        return self.searchWithExecutor(query, defaultSearchExecutor);
    }

    pub fn searchWithExecutor(self: *Client, query: []const u8, executor: SearchExecutor) JackettError![]Torrent {
        const encoded_query = try percentEncode(self.allocator, query);
        defer self.allocator.free(encoded_query);

        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/api/v2.0/indexers/all/results/torznab/api?apikey={s}&q={s}",
            .{ self.base_url, self.api_key, encoded_query },
        );
        defer self.allocator.free(url);

        return try executor(self.allocator, url);
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
                    link = result.value;
                    link_source = "torznab:attr magneturl";
                    i = result.end;
                } else if (extractStringField(xml, i, xml_tags.link)) |result| {
                    if (link == null) {
                        link = result.value;
                        link_source = "link";
                    }
                    i = result.end;
                } else if (extractEnclosureUrl(xml, i)) |result| {
                    if (link == null) {
                        link = result.value;
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

    std.mem.sort(Torrent, torrents.items, {}, struct {
        fn lessThan(_: void, a: Torrent, b: Torrent) bool {
            return a.seeders > b.seeders;
        }
    }.lessThan);

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
