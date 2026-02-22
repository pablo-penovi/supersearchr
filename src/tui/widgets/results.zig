const std = @import("std");
const term = @import("term");
const theme = @import("theme");
const Torrent = @import("torrent").Torrent;

pub const ResultsWidget = struct {
    allocator: std.mem.Allocator,
    torrents: []const Torrent,
    total_count: usize,
    scroll_offset: usize,
    cursor: usize,
    display_count: usize,
    has_drawn_once: bool,
    force_full_redraw: bool,
    last_snapshot: ?RenderSnapshot,

    pub fn init(allocator: std.mem.Allocator) ResultsWidget {
        return .{
            .allocator = allocator,
            .torrents = &.{},
            .total_count = 0,
            .scroll_offset = 0,
            .cursor = 0,
            .display_count = 0,
            .has_drawn_once = false,
            .force_full_redraw = true,
            .last_snapshot = null,
        };
    }

    pub fn deinit(_: *ResultsWidget) void {}

    pub fn setTorrents(self: *ResultsWidget, torrents: []const Torrent, total: usize) void {
        self.torrents = torrents;
        self.total_count = total;
        self.cursor = 0;
        self.scroll_offset = 0;
        self.force_full_redraw = true;
    }

    pub fn render(self: *ResultsWidget, max_rows: u16, max_cols: u16) void {
        const stdout = std.fs.File.stdout();
        const colors = theme.superseedr_like;
        const border = theme.unicode_border;
        const compact = max_cols < 48 or max_rows < 10;
        const panel_width = if (compact) @as(usize, 0) else @as(usize, @intCast(max_cols - 2));
        const inner_width = if (compact) @as(usize, 0) else panel_width - 2;
        const row_fixed_width: usize = 16; // " " + "  {seeders:>5}  {leechers:>5} "
        const title_col_width = if (compact) @as(usize, 0) else if (inner_width > row_fixed_width) inner_width - row_fixed_width else 8;
        const content_rows: usize = if (max_rows > 9) @as(usize, @intCast(max_rows - 9)) else 1;
        self.display_count = @max(@as(usize, 1), @min(content_rows, self.torrents.len));
        const end_idx = @min(self.scroll_offset + self.display_count, self.torrents.len);
        const snapshot = RenderSnapshot{
            .rows = max_rows,
            .cols = max_cols,
            .is_compact = compact,
            .cursor = self.cursor,
            .scroll_offset = self.scroll_offset,
            .display_count = self.display_count,
            .torrents_len = self.torrents.len,
            .total_count = self.total_count,
        };
        const redraw_mode = computeRedrawMode(
            self.has_drawn_once,
            self.force_full_redraw,
            self.last_snapshot,
            snapshot,
        );

        switch (redraw_mode) {
            .full => {
                if (compact) {
                    drawCompact(stdout, colors, self.torrents, self.cursor);
                } else {
                    term.moveCursor(1, 1);
                    term.clearScreen();
                    drawPanelFrame(stdout, panel_width, inner_width, border, colors, self.total_count);
                    for (0..self.display_count) |rel_idx| {
                        const abs_idx = self.scroll_offset + rel_idx;
                        if (abs_idx < end_idx) {
                            drawContentRow(
                                stdout,
                                panel_width,
                                inner_width,
                                title_col_width,
                                border,
                                colors,
                                self.torrents,
                                abs_idx,
                                self.cursor,
                            ) catch {};
                        } else {
                            writeSpaces(stdout, 1) catch {};
                            theme.drawPanelRow(stdout, panel_width, "", border, colors) catch {};
                        }
                    }
                    drawStatusRow(stdout, panel_width, border, colors, self.scroll_offset, end_idx, self.total_count, self.torrents.len) catch {};
                    writeSpaces(stdout, 1) catch {};
                    theme.drawPanelBottom(stdout, panel_width, border, colors) catch {};

                    term.setFg256(colors.muted);
                    stdout.writeAll("  ENTER select | n search | ESC exit | j/k move | J/K page") catch {};
                    term.resetColor();
                }
            },
            .partial_window => {
                term.moveCursor(4, 1);
                for (0..self.display_count) |rel_idx| {
                    const abs_idx = self.scroll_offset + rel_idx;
                    if (abs_idx < end_idx) {
                        drawContentRow(
                            stdout,
                            panel_width,
                            inner_width,
                            title_col_width,
                            border,
                            colors,
                            self.torrents,
                            abs_idx,
                            self.cursor,
                        ) catch {};
                    } else {
                        writeSpaces(stdout, 1) catch {};
                        theme.drawPanelRow(stdout, panel_width, "", border, colors) catch {};
                    }
                }
                drawStatusRow(stdout, panel_width, border, colors, self.scroll_offset, end_idx, self.total_count, self.torrents.len) catch {};
            },
            .partial_cursor => {
                const prev = self.last_snapshot orelse snapshot;
                const prev_rel = prev.cursor - self.scroll_offset;
                const curr_rel = self.cursor - self.scroll_offset;

                term.moveCursor(contentRowFromRelative(prev_rel), 1);
                drawContentRow(
                    stdout,
                    panel_width,
                    inner_width,
                    title_col_width,
                    border,
                    colors,
                    self.torrents,
                    prev.cursor,
                    self.cursor,
                ) catch {};

                term.moveCursor(contentRowFromRelative(curr_rel), 1);
                drawContentRow(
                    stdout,
                    panel_width,
                    inner_width,
                    title_col_width,
                    border,
                    colors,
                    self.torrents,
                    self.cursor,
                    self.cursor,
                ) catch {};
            },
            .none => {},
        }

        self.has_drawn_once = true;
        self.force_full_redraw = false;
        self.last_snapshot = snapshot;
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

const RenderMode = enum {
    full,
    partial_window,
    partial_cursor,
    none,
};

const RenderSnapshot = struct {
    rows: u16,
    cols: u16,
    is_compact: bool,
    cursor: usize,
    scroll_offset: usize,
    display_count: usize,
    torrents_len: usize,
    total_count: usize,
};

fn computeRedrawMode(
    has_drawn_once: bool,
    force_full_redraw: bool,
    last_snapshot: ?RenderSnapshot,
    current: RenderSnapshot,
) RenderMode {
    if (!has_drawn_once or force_full_redraw) return .full;
    const prev = last_snapshot orelse return .full;

    if (current.is_compact or prev.is_compact) return .full;

    if (prev.rows != current.rows or prev.cols != current.cols) return .full;
    if (prev.display_count != current.display_count) return .full;
    if (prev.torrents_len != current.torrents_len) return .full;
    if (prev.total_count != current.total_count) return .full;

    if (prev.scroll_offset != current.scroll_offset) return .partial_window;
    if (prev.cursor != current.cursor) return .partial_cursor;
    return .none;
}

fn drawCompact(stdout: std.fs.File, colors: theme.Theme, torrents: []const Torrent, cursor: usize) void {
    term.moveCursor(1, 1);
    term.clearScreen();
    term.setFg256(colors.panel_title);
    term.setBold(true);
    stdout.writeAll("Results\r\n") catch {};
    term.setBold(false);
    term.setFg256(colors.text);
    if (torrents.len == 0) {
        stdout.writeAll("No results found\r\n") catch {};
    } else {
        const current = torrents[cursor];
        var trunc_buf: [96]u8 = undefined;
        const shown = theme.truncateWithEllipsis(current.title, 78, trunc_buf[0..]);
        stdout.writeAll("> ") catch {};
        stdout.writeAll(shown) catch {};
        stdout.writeAll("\r\n") catch {};
    }
    term.setFg256(colors.muted);
    stdout.writeAll("ENTER select | n search | ESC exit | j/k move") catch {};
    term.resetColor();
}

fn drawPanelFrame(
    stdout: std.fs.File,
    panel_width: usize,
    inner_width: usize,
    border: theme.BorderChars,
    colors: theme.Theme,
    total_count: usize,
) void {
    writeSpaces(stdout, 1) catch {};
    theme.drawPanelTop(stdout, panel_width, border, colors) catch {};

    writeSpaces(stdout, 1) catch {};
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.setFg256(colors.panel_title);
    term.setBold(true);
    var title_buf: [96]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, " Results ({d} found) ", .{total_count}) catch " Results ";
    theme.writePadded(stdout, title, inner_width) catch {};
    term.setBold(false);
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.resetColor();
    stdout.writeAll("\r\n") catch {};

    writeSpaces(stdout, 1) catch {};
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.setFg256(colors.muted);
    theme.writePadded(stdout, " Title                                             S      L ", inner_width) catch {};
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.resetColor();
    stdout.writeAll("\r\n") catch {};
}

fn drawContentRow(
    stdout: std.fs.File,
    panel_width: usize,
    inner_width: usize,
    title_col_width: usize,
    border: theme.BorderChars,
    colors: theme.Theme,
    torrents: []const Torrent,
    abs_idx: usize,
    selected_idx: usize,
) !void {
    if (abs_idx >= torrents.len) {
        try writeSpaces(stdout, 1);
        try theme.drawPanelRow(stdout, panel_width, "", border, colors);
        return;
    }

    try writeSpaces(stdout, 1);
    term.setFg256(colors.panel_border);
    try stdout.writeAll(border.vertical);

    var trunc_buf: [512]u8 = undefined;
    var row_buf: [640]u8 = undefined;
    const torrent = torrents[abs_idx];
    const row_title = theme.truncateWithEllipsis(torrent.title, title_col_width, trunc_buf[0..]);
    const row = std.fmt.bufPrint(
        &row_buf,
        " {s}  {d:>5}  {d:>5} ",
        .{ row_title, torrent.seeders, torrent.leechers },
    ) catch "";

    if (abs_idx == selected_idx) {
        term.setBg256(colors.selected_bg);
        term.setFg256(colors.selected_fg);
        term.setBold(true);
        try theme.writePadded(stdout, row, inner_width);
        term.resetColor();
        term.setBold(false);
    } else {
        term.setFg256(colors.text);
        try theme.writePadded(stdout, row, inner_width);
    }

    term.setFg256(colors.panel_border);
    try stdout.writeAll(border.vertical);
    term.resetColor();
    try stdout.writeAll("\r\n");
}

fn drawStatusRow(
    stdout: std.fs.File,
    panel_width: usize,
    border: theme.BorderChars,
    colors: theme.Theme,
    scroll_offset: usize,
    end_idx: usize,
    total_count: usize,
    torrents_len: usize,
) !void {
    var status_buf: [96]u8 = undefined;
    const showing_start = if (torrents_len == 0) @as(usize, 0) else scroll_offset + 1;
    const showing_end = if (torrents_len == 0) @as(usize, 0) else end_idx;
    const status = std.fmt.bufPrint(
        &status_buf,
        " Showing {d}-{d} of {d} ",
        .{ showing_start, showing_end, total_count },
    ) catch " Showing ";
    try writeSpaces(stdout, 1);
    try theme.drawPanelRow(stdout, panel_width, status, border, colors);
}

fn contentRowFromRelative(rel_idx: usize) u16 {
    const row = 4 + rel_idx;
    return @as(u16, @intCast(row));
}

fn writeSpaces(writer: anytype, count: usize) !void {
    for (0..count) |_| try writer.writeAll(" ");
}

pub const ResultsAction = union(enum) {
    continue_browsing,
    select: usize,
    new_search,
    cancel,
};

test "computeRedrawMode uses full on first draw" {
    const current = RenderSnapshot{
        .rows = 24,
        .cols = 80,
        .is_compact = false,
        .cursor = 0,
        .scroll_offset = 0,
        .display_count = 10,
        .torrents_len = 20,
        .total_count = 20,
    };
    try std.testing.expectEqual(
        RenderMode.full,
        computeRedrawMode(false, false, null, current),
    );
}

test "computeRedrawMode returns partial_cursor on cursor movement" {
    const prev = RenderSnapshot{
        .rows = 24,
        .cols = 80,
        .is_compact = false,
        .cursor = 3,
        .scroll_offset = 2,
        .display_count = 10,
        .torrents_len = 20,
        .total_count = 20,
    };
    const current = RenderSnapshot{
        .rows = 24,
        .cols = 80,
        .is_compact = false,
        .cursor = 4,
        .scroll_offset = 2,
        .display_count = 10,
        .torrents_len = 20,
        .total_count = 20,
    };
    try std.testing.expectEqual(
        RenderMode.partial_cursor,
        computeRedrawMode(true, false, prev, current),
    );
}

test "computeRedrawMode returns partial_window on scroll movement" {
    const prev = RenderSnapshot{
        .rows = 24,
        .cols = 80,
        .is_compact = false,
        .cursor = 10,
        .scroll_offset = 4,
        .display_count = 10,
        .torrents_len = 30,
        .total_count = 30,
    };
    const current = RenderSnapshot{
        .rows = 24,
        .cols = 80,
        .is_compact = false,
        .cursor = 11,
        .scroll_offset = 5,
        .display_count = 10,
        .torrents_len = 30,
        .total_count = 30,
    };
    try std.testing.expectEqual(
        RenderMode.partial_window,
        computeRedrawMode(true, false, prev, current),
    );
}

test "computeRedrawMode uses full on size change" {
    const prev = RenderSnapshot{
        .rows = 24,
        .cols = 80,
        .is_compact = false,
        .cursor = 2,
        .scroll_offset = 0,
        .display_count = 10,
        .torrents_len = 20,
        .total_count = 20,
    };
    const current = RenderSnapshot{
        .rows = 30,
        .cols = 80,
        .is_compact = false,
        .cursor = 2,
        .scroll_offset = 0,
        .display_count = 10,
        .torrents_len = 20,
        .total_count = 20,
    };
    try std.testing.expectEqual(
        RenderMode.full,
        computeRedrawMode(true, false, prev, current),
    );
}

test "computeRedrawMode uses full when forced" {
    const prev = RenderSnapshot{
        .rows = 24,
        .cols = 80,
        .is_compact = false,
        .cursor = 2,
        .scroll_offset = 0,
        .display_count = 10,
        .torrents_len = 20,
        .total_count = 20,
    };
    const current = RenderSnapshot{
        .rows = 24,
        .cols = 80,
        .is_compact = false,
        .cursor = 2,
        .scroll_offset = 0,
        .display_count = 10,
        .torrents_len = 20,
        .total_count = 20,
    };
    try std.testing.expectEqual(
        RenderMode.full,
        computeRedrawMode(true, true, prev, current),
    );
}

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
