const std = @import("std");

pub const Torrent = struct {
    title: []const u8,
    seeders: u32,
    leechers: u32,
    link: []const u8,
};
