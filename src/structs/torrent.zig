const std = @import("std");

pub const Torrent = struct {
    title: []const u8,
    seeders: u32,
    leechers: u32,
    size_bytes: ?u64 = null,
    pub_date: ?i64 = null,
    link: []const u8,
};

test "Torrent stores torrent metadata" {
    const torrent = Torrent{
        .title = "Ubuntu ISO",
        .seeders = 42,
        .leechers = 7,
        .link = "magnet:?xt=urn:btih:abc",
    };

    try std.testing.expectEqualStrings("Ubuntu ISO", torrent.title);
    try std.testing.expectEqual(@as(u32, 42), torrent.seeders);
    try std.testing.expectEqual(@as(u32, 7), torrent.leechers);
    try std.testing.expectEqual(@as(?u64, null), torrent.size_bytes);
    try std.testing.expectEqualStrings("magnet:?xt=urn:btih:abc", torrent.link);
}
