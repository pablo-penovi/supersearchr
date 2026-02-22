const std = @import("std");
const term = @import("term");
const Torrent = @import("torrent").Torrent;

pub const ResultsWidget = struct {
    allocator: std.mem.Allocator,
    torrents: []const Torrent,
    total_count: usize,
    scroll_offset: usize,
    cursor: usize,
    display_count: usize,

    pub fn init(allocator: std.mem.Allocator) ResultsWidget {
        return .{
            .allocator = allocator,
            .torrents = &.{},
            .total_count = 0,
            .scroll_offset = 0,
            .cursor = 0,
            .display_count = 0,
        };
    }

    pub fn deinit(_: *ResultsWidget) void {}

    pub fn setTorrents(self: *ResultsWidget, torrents: []const Torrent, total: usize) void {
        self.torrents = torrents;
        self.total_count = total;
        self.cursor = 0;
        self.scroll_offset = 0;
    }

    pub fn render(self: *ResultsWidget, max_rows: u16, max_cols: u16) void {
        const stdout = std.fs.File.stdout();
        term.moveCursor(1, 1);

        if (max_cols < 10) {
            stdout.writeAll("Terminal too narrow\r\n") catch {};
            return;
        }

        const inner_width = @as(usize, @intCast(max_cols - 9));
        const title_col_width = inner_width - 15;

        if (self.torrents.len == 0) {
            drawBorder('=', max_cols);

            stdout.writeAll("||") catch {};
            centerText(stdout, "Results (0 found)", inner_width) catch {};
            stdout.writeAll("     ||\r\n") catch {};
            drawBorder('=', max_cols);

            stdout.writeAll("||") catch {};
            centerText(stdout, "No results found", inner_width) catch {};
            stdout.writeAll("     ||\r\n") catch {};

            drawBorder('=', max_cols);
            term.moveCursor(max_rows, 1);
            stdout.writeAll("[n\xe2\x86\x92search  ESC\xe2\x86\x92exit]") catch {};
            return;
        }

        self.display_count = @min(@as(usize, @intCast(max_rows - 9)), self.torrents.len);
        const end_idx = @min(self.scroll_offset + self.display_count, self.torrents.len);

        drawBorder('=', max_cols);

        stdout.writeAll("||") catch {};
        {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Results ({d} found)", .{self.total_count}) catch return;
            centerText(stdout, msg, inner_width) catch {};
        }
        stdout.writeAll("     ||\r\n") catch {};
        drawBorder('=', max_cols);

        for (self.torrents[self.scroll_offset..end_idx], self.scroll_offset..) |torrent, abs_idx| {
            stdout.writeAll("|| ") catch {};
            if (abs_idx == self.cursor) {
                term.reverseVideo(stdout) catch {};
            }
            var buf: [256]u8 = undefined;
            const title_len = @min(torrent.title.len, title_col_width);
            const msg = std.fmt.bufPrint(&buf, "{s}", .{torrent.title[0..title_len]}) catch continue;
            stdout.writeAll(msg) catch {};
            const padding_len = title_col_width - title_len;
            for (0..padding_len) |_| stdout.writeAll(" ") catch {};
            stdout.writeAll(" | S:") catch {};
            {
                var num_buf: [5]u8 = undefined;
                const num_msg = std.fmt.bufPrint(&num_buf, "{d:>4}", .{torrent.seeders}) catch continue;
                stdout.writeAll(num_msg) catch {};
            }
            stdout.writeAll(" | L:") catch {};
            {
                var num_buf: [5]u8 = undefined;
                const num_msg = std.fmt.bufPrint(&num_buf, "{d:>4}", .{torrent.leechers}) catch continue;
                stdout.writeAll(num_msg) catch {};
            }
            stdout.writeAll(" ||") catch {};
            if (abs_idx == self.cursor) {
                term.reverseVideoOff(stdout) catch {};
                term.resetColor();
            }
            stdout.writeAll("\r\n") catch {};
        }

        drawBorder('=', max_cols);

        stdout.writeAll("||") catch {};
        {
            var buf: [80]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Showing {d}-{d} of {d}", .{ self.scroll_offset + 1, end_idx, self.total_count }) catch return;
            centerText(stdout, msg, inner_width) catch {};
        }
        stdout.writeAll("     ||\r\n") catch {};

        drawBorder('=', max_cols);

        term.moveCursor(max_rows - 2, 1);
        stdout.writeAll("[ENTER\xe2\x86\x92select  n\xe2\x86\x92search  ESC\xe2\x86\x92exit  j/k\xe2\x86\x92\xe2\x86\x91/\xe2\x86\x93  J/K\xe2\x86\x92page]") catch {};
    }

    fn drawBorder(char: u8, width: u16) void {
        const stdout = std.fs.File.stdout();
        const buf: [1]u8 = .{char};
        for (0..@as(usize, @intCast(width))) |_| {
            stdout.writeAll(&buf) catch {};
        }
        stdout.writeAll("\r\n") catch {};
    }

    fn centerText(writer: anytype, text: []const u8, width: usize) !void {
        if (text.len >= width) {
            try writer.writeAll(text[0..width]);
            return;
        }
        const padding = width - text.len;
        const left_pad = padding / 2;
        const right_pad = padding - left_pad;
        for (0..left_pad) |_| try writer.writeAll(" ");
        try writer.writeAll(text);
        for (0..right_pad) |_| try writer.writeAll(" ");
    }

    fn adjustScroll(self: *ResultsWidget) void {
        if (self.display_count == 0) return;
        if (self.cursor < self.scroll_offset) {
            self.scroll_offset = self.cursor;
        } else if (self.cursor >= self.scroll_offset + self.display_count) {
            self.scroll_offset = self.cursor - self.display_count + 1;
        }
    }

    pub fn handleEvent(self: *ResultsWidget, event: term.Event, max_rows: u16) ResultsAction {
        if (self.torrents.len == 0) {
            switch (event.key) {
                .char => {
                    if (event.value == 'n' or event.value == 'N') return .new_search;
                    return .continue_browsing;
                },
                .escape => return .cancel,
                else => return .continue_browsing,
            }
        }

        const dc = if (max_rows >= 9) @min(@as(usize, @intCast(max_rows - 9)), self.torrents.len) else self.torrents.len;
        self.display_count = dc;

        switch (event.key) {
            .char => {
                if (event.value == 'j') {
                    if (self.cursor < self.torrents.len - 1) {
                        self.cursor += 1;
                        self.adjustScroll();
                    }
                    return .continue_browsing;
                }
                if (event.value == 'k') {
                    if (self.cursor > 0) {
                        self.cursor -= 1;
                        self.adjustScroll();
                    }
                    return .continue_browsing;
                }
                if (event.value == 'J') {
                    const step = @min(self.display_count, self.torrents.len - 1 - self.cursor);
                    self.cursor += step;
                    self.adjustScroll();
                    return .continue_browsing;
                }
                if (event.value == 'K') {
                    const step = @min(self.display_count, self.cursor);
                    self.cursor -= step;
                    self.adjustScroll();
                    return .continue_browsing;
                }
                if (event.value == 'n' or event.value == 'N') {
                    return .new_search;
                }
                return .continue_browsing;
            },
            .enter => {
                return .{ .select = self.cursor };
            },
            .escape => {
                return .cancel;
            },
            else => {
                return .continue_browsing;
            },
        }
    }

    pub fn getSelectedIndex(_: *ResultsWidget) ?usize {
        return null;
    }
};

pub const ResultsAction = union(enum) {
    continue_browsing,
    select: usize,
    new_search,
    cancel,
};

test "ResultsWidget handleEvent j moves cursor down" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const torrents = &[_]Torrent{
        .{ .title = "Test1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "Test2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
        .{ .title = "Test3", .seeders = 3, .leechers = 0, .link = "magnet:3" },
        .{ .title = "Test4", .seeders = 4, .leechers = 0, .link = "magnet:4" },
        .{ .title = "Test5", .seeders = 5, .leechers = 0, .link = "magnet:5" },
        .{ .title = "Test6", .seeders = 6, .leechers = 0, .link = "magnet:6" },
    };
    widget.setTorrents(torrents, 6);

    try std.testing.expectEqual(@as(usize, 0), widget.cursor);

    const event = term.Event{ .key = .char, .value = 'j' };
    const action = widget.handleEvent(event, 10);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqual(@as(usize, 1), widget.cursor);
    try std.testing.expectEqual(@as(usize, 1), widget.scroll_offset);
}

test "ResultsWidget handleEvent char n returns new_search" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const event = term.Event{ .key = .char, .value = 'n' };
    const action = widget.handleEvent(event, 20);

    try std.testing.expectEqual(ResultsAction.new_search, action);
}

test "ResultsWidget handleEvent enter returns select with cursor" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const torrents = &[_]Torrent{
        .{ .title = "Test1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "Test2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
    };
    widget.setTorrents(torrents, 2);
    widget.cursor = 1;

    const event = term.Event{ .key = .enter, .value = 0 };
    const action = widget.handleEvent(event, 20);

    try std.testing.expectEqual(ResultsAction{ .select = 1 }, action);
}

test "ResultsWidget handleEvent enter with no torrents continues" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const event = term.Event{ .key = .enter, .value = 0 };
    const action = widget.handleEvent(event, 20);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
}

test "ResultsWidget handleEvent escape returns cancel" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const event = term.Event{ .key = .escape, .value = 0 };
    const action = widget.handleEvent(event, 20);

    try std.testing.expectEqual(ResultsAction.cancel, action);
}

test "ResultsWidget handleEvent j adjusts scroll when cursor leaves window" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const torrents = &[_]Torrent{
        .{ .title = "T1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "T2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
        .{ .title = "T3", .seeders = 3, .leechers = 0, .link = "magnet:3" },
        .{ .title = "T4", .seeders = 4, .leechers = 0, .link = "magnet:4" },
        .{ .title = "T5", .seeders = 5, .leechers = 0, .link = "magnet:5" },
        .{ .title = "T6", .seeders = 6, .leechers = 0, .link = "magnet:6" },
    };
    widget.setTorrents(torrents, 6);
    // max_rows=10, display_count=1. cursor at 0 (last visible), j pushes it to 1.
    widget.cursor = 0;

    const event = term.Event{ .key = .char, .value = 'j' };
    const action = widget.handleEvent(event, 10);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqual(@as(usize, 1), widget.cursor);
    try std.testing.expectEqual(@as(usize, 1), widget.scroll_offset);
}

test "ResultsWidget handleEvent k moves cursor up" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const torrents = &[_]Torrent{
        .{ .title = "Test1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "Test2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
        .{ .title = "Test3", .seeders = 3, .leechers = 0, .link = "magnet:3" },
        .{ .title = "Test4", .seeders = 4, .leechers = 0, .link = "magnet:4" },
        .{ .title = "Test5", .seeders = 5, .leechers = 0, .link = "magnet:5" },
        .{ .title = "Test6", .seeders = 6, .leechers = 0, .link = "magnet:6" },
    };
    widget.setTorrents(torrents, 6);
    widget.cursor = 1;

    const event = term.Event{ .key = .char, .value = 'k' };
    const action = widget.handleEvent(event, 10);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqual(@as(usize, 0), widget.cursor);
}

test "ResultsWidget handleEvent j at last torrent does nothing" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const torrents = &[_]Torrent{
        .{ .title = "Test1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "Test2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
        .{ .title = "Test3", .seeders = 3, .leechers = 0, .link = "magnet:3" },
        .{ .title = "Test4", .seeders = 4, .leechers = 0, .link = "magnet:4" },
        .{ .title = "Test5", .seeders = 5, .leechers = 0, .link = "magnet:5" },
        .{ .title = "Test6", .seeders = 6, .leechers = 0, .link = "magnet:6" },
    };
    widget.setTorrents(torrents, 6);
    widget.cursor = 5; // last torrent

    const event = term.Event{ .key = .char, .value = 'j' };
    const action = widget.handleEvent(event, 10);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqual(@as(usize, 5), widget.cursor);
}

test "ResultsWidget handleEvent k at cursor 0 does nothing" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const torrents = &[_]Torrent{
        .{ .title = "Test1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
    };
    widget.setTorrents(torrents, 1);

    try std.testing.expectEqual(@as(usize, 0), widget.cursor);

    const event = term.Event{ .key = .char, .value = 'k' };
    const action = widget.handleEvent(event, 20);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqual(@as(usize, 0), widget.cursor);
}

test "ResultsWidget handleEvent J moves cursor by display_count" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const torrents = &[_]Torrent{
        .{ .title = "T1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "T2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
        .{ .title = "T3", .seeders = 3, .leechers = 0, .link = "magnet:3" },
        .{ .title = "T4", .seeders = 4, .leechers = 0, .link = "magnet:4" },
        .{ .title = "T5", .seeders = 5, .leechers = 0, .link = "magnet:5" },
        .{ .title = "T6", .seeders = 6, .leechers = 0, .link = "magnet:6" },
        .{ .title = "T7", .seeders = 7, .leechers = 0, .link = "magnet:7" },
        .{ .title = "T8", .seeders = 8, .leechers = 0, .link = "magnet:8" },
    };
    widget.setTorrents(torrents, 8);
    // max_rows=10, display_count=1, cursor=0 -> J moves cursor to 1
    const event = term.Event{ .key = .char, .value = 'J' };
    const action = widget.handleEvent(event, 10);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqual(@as(usize, 1), widget.cursor);
    try std.testing.expectEqual(@as(usize, 1), widget.scroll_offset);
}

test "ResultsWidget handleEvent K retreats cursor by display_count" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const torrents = &[_]Torrent{
        .{ .title = "T1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "T2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
        .{ .title = "T3", .seeders = 3, .leechers = 0, .link = "magnet:3" },
        .{ .title = "T4", .seeders = 4, .leechers = 0, .link = "magnet:4" },
        .{ .title = "T5", .seeders = 5, .leechers = 0, .link = "magnet:5" },
        .{ .title = "T6", .seeders = 6, .leechers = 0, .link = "magnet:6" },
        .{ .title = "T7", .seeders = 7, .leechers = 0, .link = "magnet:7" },
        .{ .title = "T8", .seeders = 8, .leechers = 0, .link = "magnet:8" },
    };
    widget.setTorrents(torrents, 8);
    widget.cursor = 1;
    widget.scroll_offset = 0;
    // max_rows=10, display_count=1, cursor=1 -> K moves cursor to 0
    const event = term.Event{ .key = .char, .value = 'K' };
    const action = widget.handleEvent(event, 10);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqual(@as(usize, 0), widget.cursor);
    try std.testing.expectEqual(@as(usize, 0), widget.scroll_offset);
}

test "ResultsWidget handleEvent J at last torrent does nothing" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const torrents = &[_]Torrent{
        .{ .title = "T1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "T2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
        .{ .title = "T3", .seeders = 3, .leechers = 0, .link = "magnet:3" },
        .{ .title = "T4", .seeders = 4, .leechers = 0, .link = "magnet:4" },
        .{ .title = "T5", .seeders = 5, .leechers = 0, .link = "magnet:5" },
        .{ .title = "T6", .seeders = 6, .leechers = 0, .link = "magnet:6" },
        .{ .title = "T7", .seeders = 7, .leechers = 0, .link = "magnet:7" },
        .{ .title = "T8", .seeders = 8, .leechers = 0, .link = "magnet:8" },
    };
    widget.setTorrents(torrents, 8);
    widget.cursor = 7; // last torrent
    widget.scroll_offset = 7;
    const event = term.Event{ .key = .char, .value = 'J' };
    const action = widget.handleEvent(event, 10);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqual(@as(usize, 7), widget.cursor);
    try std.testing.expectEqual(@as(usize, 7), widget.scroll_offset);
}

test "ResultsWidget handleEvent K at cursor 0 does nothing" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const torrents = &[_]Torrent{
        .{ .title = "T1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "T2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
        .{ .title = "T3", .seeders = 3, .leechers = 0, .link = "magnet:3" },
        .{ .title = "T4", .seeders = 4, .leechers = 0, .link = "magnet:4" },
    };
    widget.setTorrents(torrents, 4);
    // cursor starts at 0
    const event = term.Event{ .key = .char, .value = 'K' };
    const action = widget.handleEvent(event, 10);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqual(@as(usize, 0), widget.cursor);
    try std.testing.expectEqual(@as(usize, 0), widget.scroll_offset);
}

test "ResultsWidget cursor resets on new search" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const torrents1 = &[_]Torrent{
        .{ .title = "Test1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "Test2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
        .{ .title = "Test3", .seeders = 3, .leechers = 0, .link = "magnet:3" },
    };
    widget.setTorrents(torrents1, 3);
    widget.cursor = 2;
    widget.scroll_offset = 1;

    const torrents2 = &[_]Torrent{
        .{ .title = "Test4", .seeders = 4, .leechers = 0, .link = "magnet:4" },
    };
    widget.setTorrents(torrents2, 1);

    try std.testing.expectEqual(@as(usize, 0), widget.cursor);
    try std.testing.expectEqual(@as(usize, 0), widget.scroll_offset);
}
