const std = @import("std");
const term = @import("term");
const Torrent = @import("torrent").Torrent;

pub const ResultsWidget = struct {
    allocator: std.mem.Allocator,
    torrents: []const Torrent,
    input_buffer: std.ArrayList(u8),
    total_count: usize,

    pub fn init(allocator: std.mem.Allocator) ResultsWidget {
        return .{
            .allocator = allocator,
            .torrents = &.{},
            .input_buffer = .{},
            .total_count = 0,
        };
    }

    pub fn deinit(self: *ResultsWidget) void {
        self.input_buffer.deinit(self.allocator);
    }

    pub fn setTorrents(self: *ResultsWidget, torrents: []const Torrent, total: usize) void {
        self.torrents = torrents;
        self.total_count = total;
        self.input_buffer.clearRetainingCapacity();
    }

    pub fn render(self: *ResultsWidget, max_rows: u16) void {
        term.moveCursor(1, 1);
        term.clearScreen();

        const display_count = @min(@as(usize, @intCast(max_rows - 5)), self.torrents.len);

        {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Results ({d} found)\r\n", .{self.total_count}) catch return;
            std.fs.File.stdout().writeAll(msg) catch {};
        }

        for (self.torrents[0..display_count], 1..) |torrent, idx| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{d}. {s} [S:{d} L:{d}]\r\n", .{ idx, torrent.title, torrent.seeders, torrent.leechers }) catch continue;
            std.fs.File.stdout().writeAll(msg) catch {};
        }

        if (self.torrents.len < self.total_count) {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "(showing first {d} of {d})\r\n", .{ self.torrents.len, self.total_count }) catch return;
            std.fs.File.stdout().writeAll(msg) catch {};
        }

        term.moveCursor(max_rows - 2, 1);
        std.fs.File.stdout().writeAll("[Enter to confirm, ESC exit, n new search]\r\n") catch {};

        term.moveCursor(max_rows - 1, 1);
        std.fs.File.stdout().writeAll("Select #: ") catch {};
        if (self.input_buffer.items.len > 0) {
            std.fs.File.stdout().writeAll(self.input_buffer.items) catch {};
        }
        term.setColor(.cyan);
        std.fs.File.stdout().writeAll("█") catch {};
        term.resetColor();
    }

    pub fn handleEvent(self: *ResultsWidget, event: term.Event) ResultsAction {
        switch (event.key) {
            .digit => {
                self.input_buffer.append(self.allocator, event.value) catch return .continue_browsing;
                return .continue_browsing;
            },
            .char => {
                if (event.value == 'n' or event.value == 'N') {
                    return .new_search;
                }
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
    const action = widget.handleEvent(event);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqualStrings("1", widget.input_buffer.items);
}

test "ResultsWidget handleEvent char n returns new_search" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const event = term.Event{ .key = .char, .value = 'n' };
    const action = widget.handleEvent(event);

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
    const action = widget.handleEvent(event);

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
    const action = widget.handleEvent(event);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
}

test "ResultsWidget handleEvent escape returns cancel" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const event = term.Event{ .key = .escape, .value = 0 };
    const action = widget.handleEvent(event);

    try std.testing.expectEqual(ResultsAction.cancel, action);
}

test "ResultsWidget handleEvent backspace removes last digit" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    try widget.input_buffer.append(allocator, '1');
    try widget.input_buffer.append(allocator, '2');

    const event = term.Event{ .key = .backspace, .value = 0 };
    const action = widget.handleEvent(event);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqualStrings("1", widget.input_buffer.items);
}
