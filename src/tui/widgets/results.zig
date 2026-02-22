const std = @import("std");
const term = @import("term");
const Torrent = @import("torrent").Torrent;

pub const ResultsWidget = struct {
    allocator: std.mem.Allocator,
    torrents: []const Torrent,
    input_buffer: std.ArrayList(u8),
    total_count: usize,
    scroll_offset: usize,

    pub fn init(allocator: std.mem.Allocator) ResultsWidget {
        return .{
            .allocator = allocator,
            .torrents = &.{},
            .input_buffer = .{},
            .total_count = 0,
            .scroll_offset = 0,
        };
    }

    pub fn deinit(self: *ResultsWidget) void {
        self.input_buffer.deinit(self.allocator);
    }

    pub fn setTorrents(self: *ResultsWidget, torrents: []const Torrent, total: usize) void {
        self.torrents = torrents;
        self.total_count = total;
        self.input_buffer.clearRetainingCapacity();
        self.scroll_offset = 0;
    }

    pub fn render(self: *ResultsWidget, max_rows: u16) void {
        term.moveCursor(1, 1);
        term.clearScreen();

        const display_count = @min(@as(usize, @intCast(max_rows - 5)), self.torrents.len);
        const end_idx = @min(self.scroll_offset + display_count, self.torrents.len);

        {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Results ({d} found)\r\n", .{self.total_count}) catch return;
            std.fs.File.stdout().writeAll(msg) catch {};
        }

        for (self.torrents[self.scroll_offset..end_idx], self.scroll_offset + 1..) |torrent, idx| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{d}. {s} [S:{d} L:{d}]\r\n", .{ idx, torrent.title, torrent.seeders, torrent.leechers }) catch continue;
            std.fs.File.stdout().writeAll(msg) catch {};
        }

        if (self.torrents.len > display_count) {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "(showing {d}-{d} of {d}, j/k to scroll)\r\n", .{ self.scroll_offset + 1, end_idx, self.torrents.len }) catch return;
            std.fs.File.stdout().writeAll(msg) catch {};
        } else if (self.torrents.len < self.total_count) {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "(showing first {d} of {d})\r\n", .{ self.torrents.len, self.total_count }) catch return;
            std.fs.File.stdout().writeAll(msg) catch {};
        }

        term.moveCursor(max_rows - 1, 1);
        std.fs.File.stdout().writeAll("[Select #, Enter to confirm, ESC exit, n new search, j/k scroll]: ") catch {};
        if (self.input_buffer.items.len > 0) {
            std.fs.File.stdout().writeAll(self.input_buffer.items) catch {};
        }
    }

    pub fn handleEvent(self: *ResultsWidget, event: term.Event, max_rows: u16) ResultsAction {
        const display_count = if (max_rows >= 5) @min(@as(usize, @intCast(max_rows - 5)), self.torrents.len) else self.torrents.len;
        const max_scroll = if (self.torrents.len > display_count) self.torrents.len - display_count else 0;

        switch (event.key) {
            .char => {
                if (event.value == 'j') {
                    if (self.scroll_offset < max_scroll) {
                        self.scroll_offset += 1;
                    }
                    return .continue_browsing;
                }
                if (event.value == 'k') {
                    if (self.scroll_offset > 0) {
                        self.scroll_offset -= 1;
                    }
                    return .continue_browsing;
                }
                if (event.value == 'n' or event.value == 'N') {
                    return .new_search;
                }
                return .continue_browsing;
            },
            .digit => {
                self.input_buffer.append(self.allocator, event.value) catch return .continue_browsing;
                return .continue_browsing;
            },
            .backspace => {
                if (self.input_buffer.items.len > 0) {
                    _ = self.input_buffer.pop();
                }
                return .continue_browsing;
            },
            .enter => {
                if (self.input_buffer.items.len == 0) {
                    return .continue_browsing;
                }
                const idx = std.fmt.parseInt(usize, self.input_buffer.items, 10) catch {
                    self.input_buffer.clearRetainingCapacity();
                    return .continue_browsing;
                };
                if (idx == 0 or idx > self.torrents.len) {
                    self.input_buffer.clearRetainingCapacity();
                    return .continue_browsing;
                }
                self.input_buffer.clearRetainingCapacity();
                return .{ .select = idx - 1 };
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

test "ResultsWidget handleEvent digit appends to input" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const torrents = &[_]Torrent{
        .{ .title = "Test", .seeders = 1, .leechers = 0, .link = "magnet:1" },
    };
    widget.setTorrents(torrents, 1);

    const event = term.Event{ .key = .digit, .value = '1' };
    const action = widget.handleEvent(event, 20);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqualStrings("1", widget.input_buffer.items);
}

test "ResultsWidget handleEvent char n returns new_search" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const event = term.Event{ .key = .char, .value = 'n' };
    const action = widget.handleEvent(event, 20);

    try std.testing.expectEqual(ResultsAction.new_search, action);
}

test "ResultsWidget handleEvent enter with valid index returns select" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const torrents = &[_]Torrent{
        .{ .title = "Test", .seeders = 1, .leechers = 0, .link = "magnet:1" },
    };
    widget.setTorrents(torrents, 1);

    try widget.input_buffer.append(allocator, '1');

    const event = term.Event{ .key = .enter, .value = 0 };
    const action = widget.handleEvent(event, 20);

    try std.testing.expectEqual(ResultsAction{ .select = 0 }, action);
}

test "ResultsWidget handleEvent enter with invalid index continues" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const torrents = &[_]Torrent{
        .{ .title = "Test", .seeders = 1, .leechers = 0, .link = "magnet:1" },
    };
    widget.setTorrents(torrents, 1);

    try widget.input_buffer.append(allocator, '9');

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

test "ResultsWidget handleEvent backspace removes last digit" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    try widget.input_buffer.append(allocator, '1');
    try widget.input_buffer.append(allocator, '2');

    const event = term.Event{ .key = .backspace, .value = 0 };
    const action = widget.handleEvent(event, 20);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqualStrings("1", widget.input_buffer.items);
}

test "ResultsWidget handleEvent j increments scroll_offset" {
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

    try std.testing.expectEqual(@as(usize, 0), widget.scroll_offset);

    const event = term.Event{ .key = .char, .value = 'j' };
    const action = widget.handleEvent(event, 10);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqual(@as(usize, 1), widget.scroll_offset);
}

test "ResultsWidget handleEvent k decrements scroll_offset" {
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
    widget.scroll_offset = 1;

    const event = term.Event{ .key = .char, .value = 'k' };
    const action = widget.handleEvent(event, 10);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqual(@as(usize, 0), widget.scroll_offset);
}

test "ResultsWidget handleEvent j at max scroll does nothing" {
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
    widget.scroll_offset = 1;

    const event = term.Event{ .key = .char, .value = 'j' };
    const action = widget.handleEvent(event, 10);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqual(@as(usize, 1), widget.scroll_offset);
}

test "ResultsWidget handleEvent k at zero scroll does nothing" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const torrents = &[_]Torrent{
        .{ .title = "Test1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
    };
    widget.setTorrents(torrents, 1);

    try std.testing.expectEqual(@as(usize, 0), widget.scroll_offset);

    const event = term.Event{ .key = .char, .value = 'k' };
    const action = widget.handleEvent(event, 20);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqual(@as(usize, 0), widget.scroll_offset);
}

test "ResultsWidget scroll_offset resets on new search" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const torrents1 = &[_]Torrent{
        .{ .title = "Test1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
    };
    widget.setTorrents(torrents1, 1);
    widget.scroll_offset = 5;

    const torrents2 = &[_]Torrent{
        .{ .title = "Test2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
    };
    widget.setTorrents(torrents2, 1);

    try std.testing.expectEqual(@as(usize, 0), widget.scroll_offset);
}
