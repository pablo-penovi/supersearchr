const std = @import("std");
const term = @import("term");
const theme = @import("theme");
const build_options = @import("build_options");

pub const SearchWidget = struct {
    allocator: std.mem.Allocator,
    query: std.ArrayList(u8),
    has_drawn_once: bool,
    last_size: ?term.TerminalSize,

    pub fn init(allocator: std.mem.Allocator) SearchWidget {
        return .{
            .allocator = allocator,
            .query = .{},
            .has_drawn_once = false,
            .last_size = null,
        };
    }

    pub fn deinit(self: *SearchWidget) void {
        self.query.deinit(self.allocator);
    }

    pub fn render(self: *SearchWidget) void {
        const stdout = std.fs.File.stdout();
        const colors = theme.superseedr_like;
        const border = theme.unicode_border;
        const size = term.getTerminalSize() catch term.TerminalSize{ .rows = 24, .cols = 80 };
        const redraw_mode = computeRedrawMode(self.has_drawn_once, self.last_size, size);
        term.hideCursor();

        if (theme.isCompactViewport(size.rows, size.cols)) {
            switch (redraw_mode) {
                .full => drawCompactFull(stdout, colors, self.query.items),
                .partial => drawCompactInputLine(stdout, size, colors, self.query.items),
            }
        } else {
            const layout = computePanelLayout(size);
            switch (redraw_mode) {
                .full => drawPanelFrame(stdout, colors, border, layout),
                .partial => {},
            }
            drawPanelQueryRow(stdout, size, colors, border, layout, self.query.items);
        }

        const cursor = computeSearchCursorPosition(size, self.query.items.len);
        term.moveCursor(cursor.row, cursor.col);
        term.showCursor();
        self.has_drawn_once = true;
        self.last_size = size;
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

const CursorPosition = struct {
    row: u16,
    col: u16,
};

const PanelLayout = struct {
    panel_width: usize,
    left_pad: usize,
    top_pad: usize,
};

const RedrawMode = enum {
    full,
    partial,
};

fn computeRedrawMode(has_drawn_once: bool, last_size: ?term.TerminalSize, size: term.TerminalSize) RedrawMode {
    if (!has_drawn_once) return .full;
    const prev = last_size orelse return .full;
    if (prev.rows != size.rows or prev.cols != size.cols) return .full;
    return .partial;
}

fn computePanelLayout(size: term.TerminalSize) PanelLayout {
    const panel_width = @min(@as(usize, 74), @as(usize, @intCast(size.cols - 4)));
    const left_pad = (@as(usize, @intCast(size.cols)) - panel_width) / 2;
    const top_pad = @max(@as(usize, 2), (@as(usize, @intCast(size.rows)) - 8) / 2);
    return .{ .panel_width = panel_width, .left_pad = left_pad, .top_pad = top_pad };
}

fn drawCompactFull(stdout: std.fs.File, colors: theme.Theme, query: []const u8) void {
    term.moveCursor(1, 1);
    term.clearScreen();
    term.setFg256(colors.panel_title);
    term.setBold(true);
    stdout.writeAll("supersearchr\r\n") catch {};
    term.setBold(false);
    term.setFg256(colors.text);
    stdout.writeAll("> ") catch {};
    stdout.writeAll(query) catch {};
    stdout.writeAll("\r\n") catch {};
    term.setFg256(colors.muted);
    stdout.writeAll("ENTER search | ESC exit\r\n") catch {};
    stdout.writeAll("v" ++ build_options.version) catch {};
    term.resetColor();
}

fn drawCompactInputLine(stdout: std.fs.File, size: term.TerminalSize, colors: theme.Theme, query: []const u8) void {
    term.moveCursor(clampCursorCoord(size.rows, 2), 1);

    var trunc_buf: [512]u8 = undefined;
    const usable = if (size.cols <= 2) @as(usize, 0) else @as(usize, @intCast(size.cols - 2));
    const shown = theme.truncateWithEllipsis(query, usable, trunc_buf[0..]);

    term.setFg256(colors.text);
    stdout.writeAll("> ") catch {};
    stdout.writeAll(shown) catch {};
    const fill = usable - shown.len;
    writeSpaces(stdout, fill) catch {};
    term.resetColor();
}

fn drawPanelFrame(stdout: std.fs.File, colors: theme.Theme, border: theme.BorderChars, layout: PanelLayout) void {
    term.moveCursor(1, 1);
    term.clearScreen();
    term.moveCursor(@as(u16, @intCast(layout.top_pad)), 1);
    writeSpaces(stdout, layout.left_pad) catch {};
    theme.drawPanelTop(stdout, layout.panel_width, border, colors) catch {};

    writeSpaces(stdout, layout.left_pad) catch {};
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.setFg256(colors.panel_title);
    term.setBold(true);
    theme.writePadded(stdout, " Search ", layout.panel_width - 2) catch {};
    term.setBold(false);
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.resetColor();
    stdout.writeAll("\r\n") catch {};

    writeSpaces(stdout, layout.left_pad) catch {};
    theme.drawPanelRow(stdout, layout.panel_width, "", border, colors) catch {};
    writeSpaces(stdout, layout.left_pad) catch {};
    theme.drawPanelRow(stdout, layout.panel_width, "", border, colors) catch {};

    writeSpaces(stdout, layout.left_pad) catch {};
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.setFg256(colors.muted);
    theme.writePadded(stdout, " ENTER submit | ESC quit ", layout.panel_width - 2) catch {};
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.resetColor();
    stdout.writeAll("\r\n") catch {};

    writeSpaces(stdout, layout.left_pad) catch {};
    theme.drawPanelBottom(stdout, layout.panel_width, border, colors) catch {};

    term.moveCursor(@as(u16, @intCast(layout.top_pad + 6)), @as(u16, @intCast(layout.left_pad + 2)));
    term.setFg256(colors.muted);
    stdout.writeAll("v" ++ build_options.version) catch {};
    term.resetColor();
}

fn drawPanelQueryRow(stdout: std.fs.File, size: term.TerminalSize, colors: theme.Theme, border: theme.BorderChars, layout: PanelLayout, query: []const u8) void {
    const query_row = clampCursorCoord(size.rows, layout.top_pad + 3);
    term.moveCursor(query_row, @as(u16, @intCast(layout.left_pad + 1)));

    var trunc_buf: [512]u8 = undefined;
    var line_buf: [640]u8 = undefined;
    const shown = theme.truncateWithEllipsis(query, layout.panel_width - 11, trunc_buf[0..]);
    const query_line = std.fmt.bufPrint(&line_buf, " Query: {s}", .{shown}) catch " Query:";

    writePanelRowNoNewline(stdout, layout.panel_width, query_line, border, colors, true) catch {};
}

fn writePanelRowNoNewline(writer: anytype, width: usize, content: []const u8, border: theme.BorderChars, colors: theme.Theme, emit_colors: bool) !void {
    if (width < 2) return;
    const inner = width - 2;
    if (emit_colors) term.setFg256(colors.panel_border);
    try writer.writeAll(border.vertical);
    if (emit_colors) term.setFg256(colors.text);
    try theme.writePadded(writer, content, inner);
    if (emit_colors) term.setFg256(colors.panel_border);
    try writer.writeAll(border.vertical);
    if (emit_colors) term.resetColor();
}

fn clampCursorCoord(max: u16, value: usize) u16 {
    if (max == 0) return 1;
    const clamped = @max(@as(usize, 1), @min(value, @as(usize, @intCast(max))));
    return @as(u16, @intCast(clamped));
}

fn computeSearchCursorPosition(size: term.TerminalSize, query_len: usize) CursorPosition {
    if (theme.isCompactViewport(size.rows, size.cols)) {
        return .{
            .row = clampCursorCoord(size.rows, 2),
            .col = clampCursorCoord(size.cols, 3 + query_len),
        };
    }

    const layout = computePanelLayout(size);
    const visible_query_len = @min(query_len, layout.panel_width - 11);

    return .{
        .row = clampCursorCoord(size.rows, layout.top_pad + 3),
        .col = clampCursorCoord(size.cols, layout.left_pad + 10 + visible_query_len),
    };
}

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

test "computeSearchCursorPosition compact layout places cursor after query" {
    const size = term.TerminalSize{ .rows = 10, .cols = 40 };
    const pos = computeSearchCursorPosition(size, 3);

    try std.testing.expectEqual(@as(u16, 2), pos.row);
    try std.testing.expectEqual(@as(u16, 6), pos.col);
}

test "computeSearchCursorPosition panel layout places cursor after query" {
    const size = term.TerminalSize{ .rows = 24, .cols = 80 };
    const pos = computeSearchCursorPosition(size, 4);

    try std.testing.expectEqual(@as(u16, 11), pos.row);
    try std.testing.expectEqual(@as(u16, 17), pos.col);
}

test "computeSearchCursorPosition panel layout clamps to visible query width" {
    const size = term.TerminalSize{ .rows = 24, .cols = 80 };
    const pos = computeSearchCursorPosition(size, 200);

    try std.testing.expectEqual(@as(u16, 11), pos.row);
    try std.testing.expectEqual(@as(u16, 76), pos.col);
}

test "computeSearchCursorPosition clamps on tiny terminals" {
    const size = term.TerminalSize{ .rows = 1, .cols = 2 };
    const pos = computeSearchCursorPosition(size, 5);

    try std.testing.expectEqual(@as(u16, 1), pos.row);
    try std.testing.expectEqual(@as(u16, 2), pos.col);
}

test "computeRedrawMode first render is full" {
    const mode = computeRedrawMode(false, null, .{ .rows = 24, .cols = 80 });
    try std.testing.expectEqual(RedrawMode.full, mode);
}

test "computeRedrawMode unchanged size is partial" {
    const mode = computeRedrawMode(true, .{ .rows = 24, .cols = 80 }, .{ .rows = 24, .cols = 80 });
    try std.testing.expectEqual(RedrawMode.partial, mode);
}

test "computeRedrawMode resize is full" {
    const mode = computeRedrawMode(true, .{ .rows = 24, .cols = 80 }, .{ .rows = 30, .cols = 100 });
    try std.testing.expectEqual(RedrawMode.full, mode);
}

test "writePanelRowNoNewline writes row without CRLF" {
    const allocator = std.testing.allocator;
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    const ascii_border = theme.BorderChars{
        .top_left = "+",
        .top_right = "+",
        .bottom_left = "+",
        .bottom_right = "+",
        .horizontal = "-",
        .vertical = "|",
    };

    try writePanelRowNoNewline(out.writer(allocator), 10, " Query:", ascii_border, theme.superseedr_like, false);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\r\n") == null);
}

test "writePanelRowNoNewline fills to width with borders" {
    const allocator = std.testing.allocator;
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    const ascii_border = theme.BorderChars{
        .top_left = "+",
        .top_right = "+",
        .bottom_left = "+",
        .bottom_right = "+",
        .horizontal = "-",
        .vertical = "|",
    };

    try writePanelRowNoNewline(out.writer(allocator), 12, " Query: x", ascii_border, theme.superseedr_like, false);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\r\n") == null);
    try std.testing.expectEqual(@as(usize, 12), out.items.len);
}
