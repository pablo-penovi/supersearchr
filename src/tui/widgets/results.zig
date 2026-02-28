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
    force_selected_redraw: bool,
    last_snapshot: ?RenderSnapshot,
    marquee_offset_cols: usize,
    marquee_moving_right: bool,
    marquee_edge_hold: u8,
    marquee_target_set: bool,
    marquee_cursor: usize,
    marquee_title_col_width: usize,

    const marquee_edge_hold_ticks: u8 = 2;

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
            .force_selected_redraw = false,
            .last_snapshot = null,
            .marquee_offset_cols = 0,
            .marquee_moving_right = true,
            .marquee_edge_hold = 0,
            .marquee_target_set = false,
            .marquee_cursor = 0,
            .marquee_title_col_width = 0,
        };
    }

    pub fn deinit(_: *ResultsWidget) void {}

    pub fn setTorrents(self: *ResultsWidget, torrents: []const Torrent, total: usize) void {
        self.torrents = torrents;
        self.total_count = total;
        self.cursor = 0;
        self.scroll_offset = 0;
        self.force_full_redraw = true;
        self.resetMarqueeState();
    }

    pub fn render(self: *ResultsWidget, max_rows: u16, max_cols: u16) void {
        const stdout = std.fs.File.stdout();
        const colors = theme.superseedr_like;
        const border = theme.unicode_border;
        const compact = theme.isCompactViewport(max_rows, max_cols);
        const panel_width = if (compact) @as(usize, 0) else @as(usize, @intCast(max_cols - 2));
        const inner_width = if (compact) @as(usize, 0) else panel_width - 2;
        const layout = if (compact) TableLayout.compactFallback() else TableLayout.forInnerWidth(inner_width);
        self.display_count = computeDisplayCount(max_rows, self.torrents.len);
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
            self.force_selected_redraw,
            self.last_snapshot,
            snapshot,
        );

        switch (redraw_mode) {
            .full => {
                if (compact) {
                    drawCompact(stdout, colors, border, self.torrents, self.cursor, max_cols);
                } else {
                    term.moveCursor(1, 1);
                    term.clearScreen();
                    drawPanelFrame(stdout, panel_width, inner_width, border, colors, layout);
                    drawPanelDivider(stdout, panel_width, border, colors) catch {};
                    for (0..self.display_count) |rel_idx| {
                        const abs_idx = self.scroll_offset + rel_idx;
                        if (abs_idx < end_idx) {
                            drawContentRow(
                                stdout,
                                panel_width,
                                inner_width,
                                layout,
                                border,
                                colors,
                                self,
                                self.torrents,
                                abs_idx,
                                self.cursor,
                            ) catch {};
                        } else {
                            writeSpaces(stdout, 1) catch {};
                            theme.drawPanelRow(stdout, panel_width, "", border, colors) catch {};
                        }
                    }
                    drawPanelDivider(stdout, panel_width, border, colors) catch {};
                    drawStatusRow(stdout, panel_width, border, colors, self.scroll_offset, end_idx, self.total_count, self.torrents.len) catch {};
                    writeSpaces(stdout, 1) catch {};
                    theme.drawPanelBottom(stdout, panel_width, border, colors) catch {};

                    term.setFg256(colors.muted);
                    stdout.writeAll("  ENTER select | n search | ESC exit | j/k line down/up | J/K page down/up") catch {};
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
                            layout,
                            border,
                            colors,
                            self,
                            self.torrents,
                            abs_idx,
                            self.cursor,
                        ) catch {};
                    } else {
                        writeSpaces(stdout, 1) catch {};
                        theme.drawPanelRow(stdout, panel_width, "", border, colors) catch {};
                    }
                }
                drawPanelDivider(stdout, panel_width, border, colors) catch {};
                drawStatusRow(stdout, panel_width, border, colors, self.scroll_offset, end_idx, self.total_count, self.torrents.len) catch {};
            },
            .partial_cursor => {
                const prev = self.last_snapshot orelse snapshot;
                const prev_rel = prev.cursor - self.scroll_offset;
                const curr_rel = self.cursor - self.scroll_offset;

                if (prev.cursor == self.cursor) {
                    term.moveCursor(contentRowFromRelative(curr_rel), 1);
                    drawContentRow(
                        stdout,
                        panel_width,
                        inner_width,
                        layout,
                        border,
                        colors,
                        self,
                        self.torrents,
                        self.cursor,
                        self.cursor,
                    ) catch {};
                } else {
                    term.moveCursor(contentRowFromRelative(prev_rel), 1);
                    drawContentRow(
                        stdout,
                        panel_width,
                        inner_width,
                        layout,
                        border,
                        colors,
                        self,
                        self.torrents,
                        prev.cursor,
                        self.cursor,
                    ) catch {};

                    term.moveCursor(contentRowFromRelative(curr_rel), 1);
                    drawContentRow(
                        stdout,
                        panel_width,
                        inner_width,
                        layout,
                        border,
                        colors,
                        self,
                        self.torrents,
                        self.cursor,
                        self.cursor,
                    ) catch {};
                }
            },
            .none => {},
        }

        self.has_drawn_once = true;
        self.force_full_redraw = false;
        self.force_selected_redraw = false;
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

        self.display_count = computeDisplayCount(max_rows, self.torrents.len);

        switch (event.key) {
            .char => {
                if (event.value == 'j') {
                    if (self.cursor < self.torrents.len - 1) {
                        self.cursor += 1;
                        self.adjustScroll();
                        self.resetMarqueeState();
                    }
                    return .continue_browsing;
                }
                if (event.value == 'k') {
                    if (self.cursor > 0) {
                        self.cursor -= 1;
                        self.adjustScroll();
                        self.resetMarqueeState();
                    }
                    return .continue_browsing;
                }
                if (event.value == 'J') {
                    const step = @min(self.display_count, self.torrents.len - 1 - self.cursor);
                    self.cursor += step;
                    self.adjustScroll();
                    if (step > 0) self.resetMarqueeState();
                    return .continue_browsing;
                }
                if (event.value == 'K') {
                    const step = @min(self.display_count, self.cursor);
                    self.cursor -= step;
                    self.adjustScroll();
                    if (step > 0) self.resetMarqueeState();
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

    pub fn advanceMarquee(self: *ResultsWidget, max_rows: u16, max_cols: u16) bool {
        if (self.torrents.len == 0) return false;
        if (self.cursor >= self.torrents.len) return false;

        self.display_count = computeDisplayCount(max_rows, self.torrents.len);
        const compact = theme.isCompactViewport(max_rows, max_cols);
        if (compact) return false;

        const panel_width = @as(usize, @intCast(max_cols - 2));
        const inner_width = panel_width - 2;
        const layout = TableLayout.forInnerWidth(inner_width);
        if (layout.title_col_width == 0) return false;

        self.ensureMarqueeTarget(layout.title_col_width);

        const title = self.torrents[self.cursor].title;
        const title_cols = theme.displayWidthOfText(title);
        if (title_cols <= layout.title_col_width) return false;

        const overflow = title_cols - layout.title_col_width;
        if (self.marquee_offset_cols > overflow) {
            self.marquee_offset_cols = overflow;
            self.force_selected_redraw = true;
            return true;
        }

        if (stepMarqueeState(
            &self.marquee_offset_cols,
            &self.marquee_moving_right,
            &self.marquee_edge_hold,
            overflow,
            marquee_edge_hold_ticks,
        )) {
            self.force_selected_redraw = true;
            return true;
        }
        return false;
    }

    fn ensureMarqueeTarget(self: *ResultsWidget, title_col_width: usize) void {
        if (self.marquee_target_set and self.marquee_cursor == self.cursor and self.marquee_title_col_width == title_col_width) {
            return;
        }
        self.marquee_target_set = true;
        self.marquee_cursor = self.cursor;
        self.marquee_title_col_width = title_col_width;
        self.marquee_offset_cols = 0;
        self.marquee_moving_right = true;
        self.marquee_edge_hold = marquee_edge_hold_ticks;
    }

    fn resetMarqueeState(self: *ResultsWidget) void {
        self.marquee_target_set = false;
        self.marquee_offset_cols = 0;
        self.marquee_moving_right = true;
        self.marquee_edge_hold = 0;
        self.marquee_cursor = 0;
        self.marquee_title_col_width = 0;
        self.force_selected_redraw = false;
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

const TableLayout = struct {
    title_col_width: usize,
    seeders_width: usize,
    leechers_width: usize,
    title_to_seeders_gap: usize,
    between_stats_gap: usize,

    const fixed_seeders_width: usize = 4;
    const fixed_leechers_width: usize = 4;
    const fixed_title_to_seeders_gap: usize = 2;
    const fixed_between_stats_gap: usize = 2;
    const fixed_left_padding: usize = 1;
    const fixed_right_padding: usize = 1;

    fn forInnerWidth(inner_width: usize) TableLayout {
        const fixed_suffix = fixed_left_padding + fixed_title_to_seeders_gap + fixed_seeders_width + fixed_between_stats_gap + fixed_leechers_width + fixed_right_padding;
        const title_width = if (inner_width > fixed_suffix) inner_width - fixed_suffix else 1;
        return .{
            .title_col_width = title_width,
            .seeders_width = fixed_seeders_width,
            .leechers_width = fixed_leechers_width,
            .title_to_seeders_gap = fixed_title_to_seeders_gap,
            .between_stats_gap = fixed_between_stats_gap,
        };
    }

    fn compactFallback() TableLayout {
        return .{
            .title_col_width = 0,
            .seeders_width = fixed_seeders_width,
            .leechers_width = fixed_leechers_width,
            .title_to_seeders_gap = fixed_title_to_seeders_gap,
            .between_stats_gap = fixed_between_stats_gap,
        };
    }
};

fn computeRedrawMode(
    has_drawn_once: bool,
    force_full_redraw: bool,
    force_selected_redraw: bool,
    last_snapshot: ?RenderSnapshot,
    current: RenderSnapshot,
) RenderMode {
    if (!has_drawn_once or force_full_redraw) return .full;
    if (force_selected_redraw) return .partial_cursor;
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

fn computeDisplayCount(max_rows: u16, torrents_len: usize) usize {
    if (torrents_len == 0) return 1;

    const content_rows: usize = if (max_rows > 7) @as(usize, @intCast(max_rows - 7)) else 1;
    return @max(@as(usize, 1), @min(content_rows, torrents_len));
}

fn drawCompact(
    stdout: std.fs.File,
    colors: theme.Theme,
    border: theme.BorderChars,
    torrents: []const Torrent,
    cursor: usize,
    max_cols: u16,
) void {
    term.moveCursor(1, 1);
    term.clearScreen();
    term.setFg256(colors.panel_title);
    term.setBold(true);
    stdout.writeAll("Results\r\n") catch {};
    term.setBold(false);
    drawCompactDivider(stdout, colors, border, max_cols);
    term.setFg256(colors.text);
    if (torrents.len == 0) {
        stdout.writeAll("No results found\r\n") catch {};
    } else {
        const current = torrents[cursor];
        var trunc_buf: [512]u8 = undefined;
        const shown = theme.truncateWithEllipsis(current.title, compactTitleWidth(max_cols), trunc_buf[0..]);
        stdout.writeAll("> ") catch {};
        stdout.writeAll(shown) catch {};
        stdout.writeAll("\r\n") catch {};
    }
    drawCompactDivider(stdout, colors, border, max_cols);
    term.setFg256(colors.muted);
    stdout.writeAll("ENTER select | n search | ESC exit | j/k line down/up") catch {};
    term.resetColor();
}

fn drawCompactDivider(stdout: std.fs.File, colors: theme.Theme, border: theme.BorderChars, max_cols: u16) void {
    const cols: usize = @max(@as(usize, 1), @as(usize, @intCast(max_cols)));
    term.setFg256(colors.panel_border);
    for (0..cols) |_| {
        stdout.writeAll(border.horizontal) catch {};
    }
    term.resetColor();
    stdout.writeAll("\r\n") catch {};
}

fn compactTitleWidth(max_cols: u16) usize {
    const cols: usize = @max(@as(usize, 1), @as(usize, @intCast(max_cols)));
    if (cols <= 2) return 1;
    return cols - 2;
}

fn drawPanelFrame(
    stdout: std.fs.File,
    panel_width: usize,
    inner_width: usize,
    border: theme.BorderChars,
    colors: theme.Theme,
    layout: TableLayout,
) void {
    writeSpaces(stdout, 1) catch {};
    theme.drawPanelTop(stdout, panel_width, border, colors) catch {};

    writeSpaces(stdout, 1) catch {};
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.setFg256(colors.muted);
    writeHeaderCells(stdout, inner_width, layout) catch {};
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.resetColor();
    stdout.writeAll("\r\n") catch {};
}

fn drawPanelDivider(
    stdout: std.fs.File,
    panel_width: usize,
    border: theme.BorderChars,
    colors: theme.Theme,
) !void {
    if (panel_width < 2) return;
    try writeSpaces(stdout, 1);
    term.setFg256(colors.panel_border);
    try stdout.writeAll(border.vertical);
    try theme.writeRepeat(stdout, border.horizontal, panel_width - 2);
    try stdout.writeAll(border.vertical);
    term.resetColor();
    try stdout.writeAll("\r\n");
}

fn drawContentRow(
    stdout: std.fs.File,
    panel_width: usize,
    inner_width: usize,
    layout: TableLayout,
    border: theme.BorderChars,
    colors: theme.Theme,
    widget: *ResultsWidget,
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
    var marquee_buf: [768]u8 = undefined;
    var cell_buf: [768]u8 = undefined;
    const torrent = torrents[abs_idx];
    const row_title = if (abs_idx == selected_idx)
        selectedTitleForRender(widget, torrent.title, layout.title_col_width, trunc_buf[0..], marquee_buf[0..])
    else
        theme.truncateWithEllipsis(torrent.title, layout.title_col_width, trunc_buf[0..]);
    const row = buildDataCells(&cell_buf, inner_width, layout, row_title, torrent.seeders, torrent.leechers);

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

fn selectedTitleForRender(
    widget: *ResultsWidget,
    title: []const u8,
    title_col_width: usize,
    trunc_buf: []u8,
    marquee_buf: []u8,
) []const u8 {
    if (title_col_width == 0) return "";

    const title_cols = theme.displayWidthOfText(title);
    if (title_cols <= title_col_width) {
        return theme.truncateWithEllipsis(title, title_col_width, trunc_buf);
    }

    const overflow = title_cols - title_col_width;
    widget.ensureMarqueeTarget(title_col_width);
    const offset_cols = @min(widget.marquee_offset_cols, overflow);
    return theme.sliceByDisplayColumns(title, offset_cols, title_col_width, marquee_buf);
}

fn stepMarqueeState(
    offset_cols: *usize,
    moving_right: *bool,
    edge_hold: *u8,
    max_offset: usize,
    hold_ticks: u8,
) bool {
    if (max_offset == 0) return false;

    if (edge_hold.* > 0) {
        edge_hold.* -= 1;
        return false;
    }

    if (moving_right.*) {
        if (offset_cols.* < max_offset) {
            offset_cols.* += 1;
            return true;
        }
        moving_right.* = false;
        edge_hold.* = hold_ticks;
        return false;
    }

    if (offset_cols.* > 0) {
        offset_cols.* -= 1;
        return true;
    }

    moving_right.* = true;
    edge_hold.* = hold_ticks;
    return false;
}

fn writeHeaderCells(stdout: std.fs.File, inner_width: usize, layout: TableLayout) !void {
    var buf: [256]u8 = undefined;
    const header = buildHeaderCells(&buf, inner_width, layout);
    try stdout.writeAll(header);
}

fn buildHeaderCells(buf: []u8, inner_width: usize, layout: TableLayout) []const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    writer.writeAll(" ") catch return "";
    theme.writePadded(writer, "Title", layout.title_col_width) catch return "";
    writeSpaces(writer, layout.title_to_seeders_gap) catch return "";
    writeRightAligned(writer, "S", layout.seeders_width) catch return "";
    writeSpaces(writer, layout.between_stats_gap) catch return "";
    writeRightAligned(writer, "L", layout.leechers_width) catch return "";
    writer.writeAll(" ") catch return "";

    const used = stream.getWritten().len;
    if (used < inner_width) {
        writeSpaces(writer, inner_width - used) catch {};
    }
    return stream.getWritten();
}

fn buildDataCells(
    buf: []u8,
    inner_width: usize,
    layout: TableLayout,
    title: []const u8,
    seeders: u32,
    leechers: u32,
) []const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    writer.writeAll(" ") catch return "";
    theme.writePadded(writer, title, layout.title_col_width) catch return "";
    writeSpaces(writer, layout.title_to_seeders_gap) catch return "";

    var sbuf: [16]u8 = undefined;
    const seeders_text = std.fmt.bufPrint(&sbuf, "{d}", .{seeders}) catch "";
    writeRightAligned(writer, seeders_text, layout.seeders_width) catch return "";
    writeSpaces(writer, layout.between_stats_gap) catch return "";

    var lbuf: [16]u8 = undefined;
    const leechers_text = std.fmt.bufPrint(&lbuf, "{d}", .{leechers}) catch "";
    writeRightAligned(writer, leechers_text, layout.leechers_width) catch return "";
    writer.writeAll(" ") catch return "";

    const used = stream.getWritten().len;
    if (used < inner_width) {
        writeSpaces(writer, inner_width - used) catch {};
    }
    return stream.getWritten();
}

fn writeRightAligned(writer: anytype, text: []const u8, width: usize) !void {
    if (width == 0) return;
    if (text.len >= width) {
        try writer.writeAll(text[text.len - width ..]);
        return;
    }

    try writeSpaces(writer, width - text.len);
    try writer.writeAll(text);
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
    const inner_width = panel_width - 2;
    term.setFg256(colors.panel_border);
    try stdout.writeAll(border.vertical);
    term.setFg256(colors.panel_title);
    try theme.writePadded(stdout, status, inner_width);
    term.setFg256(colors.panel_border);
    try stdout.writeAll(border.vertical);
    term.resetColor();
    try stdout.writeAll("\r\n");
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
        computeRedrawMode(false, false, false, null, current),
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
        computeRedrawMode(true, false, false, prev, current),
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
        computeRedrawMode(true, false, false, prev, current),
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
        computeRedrawMode(true, false, false, prev, current),
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
        computeRedrawMode(true, true, false, prev, current),
    );
}

test "computeRedrawMode returns partial_cursor when selected row redraw is forced" {
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
        RenderMode.partial_cursor,
        computeRedrawMode(true, false, true, prev, current),
    );
}

test "header and data cells align stats columns for short title" {
    const inner_width: usize = 56;
    const layout = TableLayout.forInnerWidth(inner_width);

    var hbuf: [256]u8 = undefined;
    const header = buildHeaderCells(&hbuf, inner_width, layout);

    var rbuf: [256]u8 = undefined;
    const row = buildDataCells(&rbuf, inner_width, layout, "Voyager", 7, 42);

    const s_header = std.mem.indexOfScalar(u8, header, 'S') orelse return error.TestUnexpectedResult;
    const l_header = std.mem.indexOfScalar(u8, header, 'L') orelse return error.TestUnexpectedResult;
    const s_row = std.mem.lastIndexOfScalar(u8, row, '7') orelse return error.TestUnexpectedResult;
    const l_row = std.mem.lastIndexOfScalar(u8, row, '2') orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(s_header, s_row);
    try std.testing.expectEqual(l_header, l_row);
}

test "stats columns stay aligned when title is truncated" {
    const inner_width: usize = 56;
    const layout = TableLayout.forInnerWidth(inner_width);

    var hbuf: [256]u8 = undefined;
    const header = buildHeaderCells(&hbuf, inner_width, layout);

    var trunc_buf: [128]u8 = undefined;
    const long_title = "A very very very long title that must truncate";
    const shown_title = theme.truncateWithEllipsis(long_title, layout.title_col_width, trunc_buf[0..]);

    var rbuf: [256]u8 = undefined;
    const row = buildDataCells(&rbuf, inner_width, layout, shown_title, 999, 1000);

    const s_header = std.mem.indexOfScalar(u8, header, 'S') orelse return error.TestUnexpectedResult;
    const l_header = std.mem.indexOfScalar(u8, header, 'L') orelse return error.TestUnexpectedResult;
    const s_row = std.mem.lastIndexOfScalar(u8, row, '9') orelse return error.TestUnexpectedResult;
    const l_row = std.mem.lastIndexOfScalar(u8, row, '0') orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(s_header, s_row);
    try std.testing.expectEqual(l_header, l_row);
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
    const action = widget.handleEvent(event, 8);

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
    // max_rows=8, display_count=1. cursor at 0 (last visible), j pushes it to 1 and scrolls.
    widget.cursor = 0;

    const event = term.Event{ .key = .char, .value = 'j' };
    const action = widget.handleEvent(event, 8);

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
    // max_rows=8, display_count=1, cursor=0 -> J moves cursor to 1
    const event = term.Event{ .key = .char, .value = 'J' };
    const action = widget.handleEvent(event, 8);

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
    // max_rows=8, display_count=1, cursor=1 -> K moves cursor to 0
    const event = term.Event{ .key = .char, .value = 'K' };
    const action = widget.handleEvent(event, 8);

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

test "stepMarqueeState bounces and flips direction" {
    var offset: usize = 0;
    var moving_right = true;
    var hold: u8 = 0;
    const max_offset: usize = 2;

    try std.testing.expect(stepMarqueeState(&offset, &moving_right, &hold, max_offset, 0));
    try std.testing.expectEqual(@as(usize, 1), offset);
    try std.testing.expectEqual(true, moving_right);

    try std.testing.expect(stepMarqueeState(&offset, &moving_right, &hold, max_offset, 0));
    try std.testing.expectEqual(@as(usize, 2), offset);
    try std.testing.expectEqual(true, moving_right);

    try std.testing.expect(!stepMarqueeState(&offset, &moving_right, &hold, max_offset, 0));
    try std.testing.expectEqual(@as(usize, 2), offset);
    try std.testing.expectEqual(false, moving_right);

    try std.testing.expect(stepMarqueeState(&offset, &moving_right, &hold, max_offset, 0));
    try std.testing.expectEqual(@as(usize, 1), offset);
    try std.testing.expectEqual(false, moving_right);

    try std.testing.expect(stepMarqueeState(&offset, &moving_right, &hold, max_offset, 0));
    try std.testing.expectEqual(@as(usize, 0), offset);
    try std.testing.expectEqual(false, moving_right);

    try std.testing.expect(!stepMarqueeState(&offset, &moving_right, &hold, max_offset, 0));
    try std.testing.expectEqual(@as(usize, 0), offset);
    try std.testing.expectEqual(true, moving_right);
}

test "advanceMarquee does not animate when title fits" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const torrents = &[_]Torrent{
        .{ .title = "Short", .seeders = 1, .leechers = 0, .link = "magnet:1" },
    };
    widget.setTorrents(torrents, 1);
    widget.cursor = 0;

    try std.testing.expectEqual(false, widget.advanceMarquee(24, 120));
    try std.testing.expectEqual(@as(usize, 0), widget.marquee_offset_cols);
}

test "compactTitleWidth follows terminal width safely" {
    try std.testing.expectEqual(@as(usize, 1), compactTitleWidth(1));
    try std.testing.expectEqual(@as(usize, 1), compactTitleWidth(2));
    try std.testing.expectEqual(@as(usize, 8), compactTitleWidth(10));
}

test "writeRightAligned clips overflowing values to preserve column width" {
    const allocator = std.testing.allocator;
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try writeRightAligned(out.writer(allocator), "123456", 4);
    try std.testing.expectEqualStrings("3456", out.items);
}
