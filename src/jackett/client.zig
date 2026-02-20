const std = @import("std");
const Torrent = @import("torrent").Torrent;

const xml_tags = .{
    .item = "<item>",
    .item_end = "</item>",
    .title = "<title>",
    .link = "<link>",
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

pub const SearchExecutor = fn (allocator: std.mem.Allocator, url: []const u8) anyerror![]Torrent;

pub fn defaultSearchExecutor(allocator: std.mem.Allocator, url: []const u8) anyerror![]Torrent {
    var http_client = std.http.Client{ .allocator = allocator };
    defer http_client.deinit();

    const uri = try std.Uri.parse(url);
    var request = try http_client.request(.GET, uri, .{});
    defer request.deinit();

    try request.sendBodiless();
    var header_buf: [1024]u8 = undefined;
    var response = try request.receiveHead(&header_buf);

    const status = response.head.status;
    if (status != .ok) {
        return error.HttpError;
    }

    var read_buf: [4096]u8 = undefined;
    const reader = response.reader(&read_buf);
    const body = try reader.allocRemaining(allocator, .unlimited);
    defer allocator.free(body);

    return try parseTorrents(allocator, body);
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

    pub fn search(self: *Client, query: []const u8) ![]Torrent {
        return self.searchWithExecutor(query, defaultSearchExecutor);
    }

    pub fn searchWithExecutor(self: *Client, query: []const u8, executor: SearchExecutor) ![]Torrent {
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
            var seeders: u32 = 0;
            var peers: u32 = 0;

            while (i < xml.len) {
                if (extractStringField(xml, i, xml_tags.item_end)) |_| {
                    break;
                }
                if (extractStringField(xml, i, xml_tags.title)) |result| {
                    title = result.value;
                    i = result.end;
                } else if (extractStringField(xml, i, xml_tags.link)) |result| {
                    link = result.value;
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
                const link_copy = try allocator.dupe(u8, link.?);
                try torrents.append(allocator, .{
                    .title = title_copy,
                    .seeders = seeders,
                    .leechers = peers,
                    .link = link_copy,
                });
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
