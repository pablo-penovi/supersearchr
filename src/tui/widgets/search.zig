const std = @import("std");
const term = @import("term");
const theme = @import("theme");

pub const SearchWidget = struct {
    allocator: std.mem.Allocator,
    query: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) SearchWidget {
        return .{
            .allocator = allocator,
            .query = .{},
        };
    }

    pub fn deinit(self: *SearchWidget) void {
        self.query.deinit(self.allocator);
    }

    pub fn render(self: *SearchWidget) void {
        const stdout = std.fs.File.stdout();
        const colors = theme.superseedr_like;
        const border = theme.chooseBorderCharset();
        const size = term.getTerminalSize() catch term.TerminalSize{ .rows = 24, .cols = 80 };

        term.moveCursor(1, 1);
        term.clearScreen();

        if (size.cols < 56 or size.rows < 12) {
            term.setFg256(colors.panel_title);
            term.setBold(true);
            stdout.writeAll("supersearchr\r\n") catch {};
            term.setBold(false);
            term.setFg256(colors.text);
            stdout.writeAll("> ") catch {};
            stdout.writeAll(self.query.items) catch {};
            stdout.writeAll("\r\n") catch {};
            term.setFg256(colors.muted);
            stdout.writeAll("ENTER search | ESC exit") catch {};
            term.resetColor();
            return;
        }

        const panel_width = @min(@as(usize, 74), @as(usize, @intCast(size.cols - 4)));
        const left_pad = (@as(usize, @intCast(size.cols)) - panel_width) / 2;
        const top_pad = @max(@as(usize, 2), (@as(usize, @intCast(size.rows)) - 8) / 2);

        term.moveCursor(@as(u16, @intCast(top_pad)), 1);
        writeSpaces(stdout, left_pad) catch {};
        theme.drawPanelTop(stdout, panel_width, border, colors) catch {};

        writeSpaces(stdout, left_pad) catch {};
        term.setFg256(colors.panel_border);
        stdout.writeAll(border.vertical) catch {};
        term.setFg256(colors.panel_title);
        term.setBold(true);
        theme.writePadded(stdout, " Search ", panel_width - 2) catch {};
        term.setBold(false);
        term.setFg256(colors.panel_border);
        stdout.writeAll(border.vertical) catch {};
        term.resetColor();
        stdout.writeAll("\r\n") catch {};

        writeSpaces(stdout, left_pad) catch {};
        theme.drawPanelRow(stdout, panel_width, "", border, colors) catch {};

        var trunc_buf: [512]u8 = undefined;
        var line_buf: [640]u8 = undefined;
        const shown = theme.truncateWithEllipsis(self.query.items, panel_width - 11, trunc_buf[0..]);
        const query_line = std.fmt.bufPrint(&line_buf, " Query: {s}", .{shown}) catch " Query:";
        writeSpaces(stdout, left_pad) catch {};
        theme.drawPanelRow(stdout, panel_width, query_line, border, colors) catch {};

        writeSpaces(stdout, left_pad) catch {};
        term.setFg256(colors.panel_border);
        stdout.writeAll(border.vertical) catch {};
        term.setFg256(colors.muted);
        theme.writePadded(stdout, " ENTER submit | ESC quit ", panel_width - 2) catch {};
        term.setFg256(colors.panel_border);
        stdout.writeAll(border.vertical) catch {};
        term.resetColor();
        stdout.writeAll("\r\n") catch {};

        writeSpaces(stdout, left_pad) catch {};
        theme.drawPanelBottom(stdout, panel_width, border, colors) catch {};
    }

    pub fn handleEvent(self: *SearchWidget, event: term.Event) SearchAction {
        switch (event.key) {
            .char, .digit => {
                self.query.append(self.allocator, event.value) catch return .continue_search;
                return .continue_search;
            },
            .backspace => {
                if (self.query.items.len > 0) {
                    _ = self.query.pop();
                }
                return .continue_search;
            },
            .enter => {
                if (self.query.items.len > 0) {
                    return .submit;
                }
                return .continue_search;
            },
            .escape => {
                return .cancel;
            },
            else => {
                return .continue_search;
            },
        }
    }

    pub fn getQuery(self: *SearchWidget) []const u8 {
        return self.query.items;
    }

    pub fn clear(self: *SearchWidget) void {
        self.query.clearRetainingCapacity();
    }
};

fn writeSpaces(writer: anytype, count: usize) !void {
    for (0..count) |_| try writer.writeAll(" ");
}

pub const SearchAction = enum {
    continue_search,
    submit,
    cancel,
};

test "SearchWidget handleEvent char adds to query" {
    const allocator = std.testing.allocator;
    var widget = SearchWidget.init(allocator);
    defer widget.deinit();

    const event = term.Event{ .key = .char, .value = 'h' };
    const action = widget.handleEvent(event);

    try std.testing.expectEqual(SearchAction.continue_search, action);
    try std.testing.expectEqualStrings("h", widget.query.items);
}

test "SearchWidget handleEvent backspace removes last char" {
    const allocator = std.testing.allocator;
    var widget = SearchWidget.init(allocator);
    defer widget.deinit();

    try widget.query.append(allocator, 'h');
    try widget.query.append(allocator, 'i');

    const event = term.Event{ .key = .backspace, .value = 0 };
    const action = widget.handleEvent(event);

    try std.testing.expectEqual(SearchAction.continue_search, action);
    try std.testing.expectEqualStrings("h", widget.query.items);
}

test "SearchWidget handleEvent enter submits non-empty query" {
    const allocator = std.testing.allocator;
    var widget = SearchWidget.init(allocator);
    defer widget.deinit();

    try widget.query.append(allocator, 't');

    const event = term.Event{ .key = .enter, .value = 0 };
    const action = widget.handleEvent(event);

    try std.testing.expectEqual(SearchAction.submit, action);
}

test "SearchWidget handleEvent enter on empty query continues" {
    const allocator = std.testing.allocator;
    var widget = SearchWidget.init(allocator);
    defer widget.deinit();

    const event = term.Event{ .key = .enter, .value = 0 };
    const action = widget.handleEvent(event);

    try std.testing.expectEqual(SearchAction.continue_search, action);
}

test "SearchWidget handleEvent escape returns cancel" {
    const allocator = std.testing.allocator;
    var widget = SearchWidget.init(allocator);
    defer widget.deinit();

    const event = term.Event{ .key = .escape, .value = 0 };
    const action = widget.handleEvent(event);

    try std.testing.expectEqual(SearchAction.cancel, action);
}

test "SearchWidget clear empties query" {
    const allocator = std.testing.allocator;
    var widget = SearchWidget.init(allocator);
    defer widget.deinit();

    try widget.query.append(allocator, 't');
    try widget.query.append(allocator, 'e');
    try widget.query.append(allocator, 's');
    try widget.query.append(allocator, 't');

    widget.clear();

    try std.testing.expectEqual(@as(usize, 0), widget.query.items.len);
}
