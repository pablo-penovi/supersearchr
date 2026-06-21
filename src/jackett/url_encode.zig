const std = @import("std");

pub fn percentEncode(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
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

test "percentEncode leaves unreserved characters untouched" {
    const allocator = std.testing.allocator;
    const encoded = try percentEncode(allocator, "abc-XYZ_123.~");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("abc-XYZ_123.~", encoded);
}

test "percentEncode escapes reserved characters" {
    const allocator = std.testing.allocator;
    const encoded = try percentEncode(allocator, "a b/c?d=e");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("a%20b%2Fc%3Fd%3De", encoded);
}
