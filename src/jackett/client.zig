const std = @import("std");

pub const Torrent = struct {
    title: []const u8,
    seeders: u32,
    leechers: u32,
    link: []const u8,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    api_key: []const u8,
    http_client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8, api_key: []const u8) Client {
        return .{
            .allocator = allocator,
            .base_url = base_url,
            .api_key = api_key,
            .http_client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
    }

    pub fn search(self: *Client, query: []const u8) ![]Torrent {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/api/v2.0/indexers/all/results/torznab/api?apikey={s}&q={s}",
            .{ self.base_url, self.api_key, query },
        );
        defer self.allocator.free(url);

        const uri = try std.Uri.parse(url);
        var request = try self.http_client.open(.GET, uri, .{});
        defer request.deinit();

        request.send() catch |err| {
            if (err == error.ConnectionRefused) {
                return error.ConnectionRefused;
            }
            return err;
        };
        request.wait() catch |err| {
            if (err == error.ConnectionRefused) {
                return error.ConnectionRefused;
            }
            return err;
        };

        const status = request.response.status;
        if (status != .ok) {
            return error.HttpError;
        }

        const body = try request.reader().readAllAlloc(self.allocator, std.math.maxInt(usize));
        defer self.allocator.free(body);

        return parseTorrents(self.allocator, body);
    }
};

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
        if (std.mem.startsWith(u8, xml[i..], "<item>")) {
            i += 6;
            var title: ?[]const u8 = null;
            var link: ?[]const u8 = null;
            var seeders: u32 = 0;
            var peers: u32 = 0;

            while (i < xml.len) {
                if (std.mem.startsWith(u8, xml[i..], "</item>")) {
                    i += 7;
                    break;
                }

                if (std.mem.startsWith(u8, xml[i..], "<title>")) {
                    const start = i + 7;
                    const end = std.mem.indexOfScalarPos(u8, xml, start, '<') orelse xml.len;
                    title = xml[start..end];
                    i = end;
                } else if (std.mem.startsWith(u8, xml[i..], "<link>")) {
                    const start = i + 6;
                    const end = std.mem.indexOfScalarPos(u8, xml, start, '<') orelse xml.len;
                    link = xml[start..end];
                    i = end;
                } else if (std.mem.startsWith(u8, xml[i..], "<torznab:attr name=\"seeders\">")) {
                    const start = i + 29;
                    const end = std.mem.indexOfScalarPos(u8, xml, start, '<') orelse xml.len;
                    seeders = std.fmt.parseInt(u32, xml[start..end], 10) catch 0;
                    i = end;
                } else if (std.mem.startsWith(u8, xml[i..], "<torznab:attr name=\"peers\">")) {
                    const start = i + 27;
                    const end = std.mem.indexOfScalarPos(u8, xml, start, '<') orelse xml.len;
                    peers = std.fmt.parseInt(u32, xml[start..end], 10) catch 0;
                    i = end;
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

    const xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><rss version=\"1.0\"><channel><item><title>Movie.2024.1080p.WEB.h264</title><link>magnet:?xt=urn:btih:abc123</link><torznab:attr name=\"seeders\">100</torznab:attr><torznab:attr name=\"peers\">50</torznab:attr></item><item><title>Movie.2024.720p.WEB.h264</title><link>magnet:?xt=urn:btih:def456</link><torznab:attr name=\"seeders\">200</torznab:attr><torznab:attr name=\"peers\">75</torznab:attr></item></channel></rss>";

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

    const xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><rss version=\"1.0\"><channel><item><title>With Magnet</title><link>magnet:?xt=urn:btih:abc123</link><torznab:attr name=\"seeders\">100</torznab:attr></item><item><title>With Torrent Link</title><link>https://example.com/torrent.torrent</link><torznab:attr name=\"seeders\">200</torznab:attr></item><item><title>No Link</title></item></channel></rss>";

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

    const xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><rss version=\"1.0\"><channel><item><title>Low Seeders</title><link>magnet:?xt=urn:btih:aaa</link><torznab:attr name=\"seeders\">10</torznab:attr></item><item><title>High Seeders</title><link>magnet:?xt=urn:btih:bbb</link><torznab:attr name=\"seeders\">1000</torznab:attr></item><item><title>Medium Seeders</title><link>magnet:?xt=urn:btih:ccc</link><torznab:attr name=\"seeders\">100</torznab:attr></item></channel></rss>";

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
