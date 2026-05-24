const std = @import("std");
const term = @import("term");
const theme = @import("theme");
const Torrent = @import("torrent").Torrent;
const compat = @import("compat");

const spinner_frames = [_][]const u8{
    "⣎⡇",
    "⣇⡇",
    "⣏⡆",
    "⣏⡅",
    "⣏⡃",
    "⣏⠇",
    "⡏⡇",
    "⢏⡇",
    "⣋⡇",
    "⣍⡇",
};

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
    sent_torrents: std.ArrayList(SentTorrent),
    failed_indexers: std.ArrayList([]const u8),
    live_status: LiveStatus,
    spinner_frame: usize,

    const marquee_edge_hold_ticks: u8 = 2;

    pub const SendState = enum {
        none,
        success,
        failed,
    };

    pub const SentTorrent = struct {
        link: []const u8,
        state: SendState,
    };

    pub const LivePhase = enum {
        discovering,
        querying,
        done,
    };

    pub const LiveStatus = struct {
        phase: LivePhase = .done,
        completed: usize = 0,
        total: usize = 0,
        failed: usize = 0,
    };

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
            .sent_torrents = .empty,
            .failed_indexers = .empty,
            .live_status = .{},
            .spinner_frame = 0,
        };
    }

    pub fn deinit(self: *ResultsWidget) void {
        self.sent_torrents.deinit(self.allocator);
        for (self.failed_indexers.items) |name| {
            self.allocator.free(name);
        }
        self.failed_indexers.deinit(self.allocator);
    }

    pub fn addFailedIndexer(self: *ResultsWidget, name: []const u8) !void {
        for (self.failed_indexers.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }
        const cloned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(cloned);
        try self.failed_indexers.append(self.allocator, cloned);
    }

    pub fn advanceSpinner(self: *ResultsWidget) bool {
        if (self.live_status.phase == .done) return false;
        self.spinner_frame = (self.spinner_frame + 1) % spinner_frames.len;
        return true;
    }

    pub fn setTorrents(self: *ResultsWidget, torrents: []const Torrent, total: usize) void {
        self.torrents = torrents;
        self.total_count = total;
        self.cursor = 0;
        self.scroll_offset = 0;
        self.force_full_redraw = true;
        self.resetMarqueeState();
        self.sent_torrents.clearRetainingCapacity();
    }

    pub fn updateTorrents(self: *ResultsWidget, torrents: []const Torrent, total: usize, previous_cursor_link: ?[]const u8) void {
        self.torrents = torrents;
        self.total_count = total;

        const previous_cursor = self.cursor;
        if (previous_cursor_link) |link| {
            self.cursor = findTorrentByLink(torrents, link) orelse @min(self.cursor, if (torrents.len == 0) 0 else torrents.len - 1);
        } else {
            self.cursor = if (torrents.len == 0) 0 else @min(self.cursor, torrents.len - 1);
        }
        if (torrents.len == 0) {
            self.scroll_offset = 0;
        } else {
            self.adjustScroll();
        }
        if (self.cursor != previous_cursor) {
            self.resetMarqueeState();
        }
        self.force_full_redraw = true;
    }

    pub fn setLiveStatus(self: *ResultsWidget, status: LiveStatus) void {
        if (std.meta.eql(self.live_status, status)) return;
        self.live_status = status;
        self.force_full_redraw = true;
    }

    pub fn setSendState(self: *ResultsWidget, idx: usize, state: SendState) void {
        if (idx >= self.torrents.len) return;
        const link = self.torrents[idx].link;
        for (self.sent_torrents.items) |*sent| {
            if (std.mem.eql(u8, sent.link, link)) {
                sent.state = state;
                self.force_selected_redraw = true;
                return;
            }
        }
        self.sent_torrents.append(self.allocator, .{ .link = link, .state = state }) catch {};
        self.force_selected_redraw = true;
    }

    fn getSendState(self: *ResultsWidget, idx: usize) SendState {
        if (idx >= self.torrents.len) return .none;
        const link = self.torrents[idx].link;
        for (self.sent_torrents.items) |sent| {
            if (std.mem.eql(u8, sent.link, link)) {
                return sent.state;
            }
        }
        return .none;
    }

    pub fn render(self: *ResultsWidget, max_rows: u16, max_cols: u16) void {
        const stdout = compat.stdoutWriter();
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
            .live_status = self.live_status,
            .spinner_frame = self.spinner_frame,
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
                    drawCompact(
                        stdout,
                        colors,
                        border,
                        self,
                        max_cols,
                        self.getSendState(self.cursor),
                        end_idx,
                    );
                } else {
                    term.moveCursor(1, 1);
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
                    drawStatusRow(stdout, panel_width, border, colors, self, end_idx) catch {};
                    writeSpaces(stdout, 1) catch {};
                    theme.drawPanelBottom(stdout, panel_width, border, colors) catch {};

                    term.setFg256(colors.muted);
                    stdout.writeAll("  ENTER select | n search | ESC exit | j/k line down/up | J/K page down/up") catch {};
                    term.resetColor();
                    term.clearBelow();
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
                drawStatusRow(stdout, panel_width, border, colors, self, end_idx) catch {};
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
        const stdout = compat.stdoutWriter();
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
                    if (event.value == 'e' or event.value == 'E') {
                        if (self.live_status.phase == .done and self.live_status.failed > 0) return .review_failures;
                    }
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
                if (event.value == 'e' or event.value == 'E') {
                    if (self.live_status.phase == .done and self.live_status.failed > 0) return .review_failures;
                }
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
    live_status: ResultsWidget.LiveStatus,
    spinner_frame: usize = 0,
};

const TableLayout = struct {
    title_col_width: usize,
    seeders_width: usize,
    leechers_width: usize,
    size_width: usize,
    title_to_seeders_gap: usize,
    between_stats_gap: usize,

    const fixed_seeders_width: usize = 4;
    const fixed_leechers_width: usize = 4;
    const fixed_size_width: usize = 9;
    const fixed_title_to_seeders_gap: usize = 2;
    const fixed_between_stats_gap: usize = 2;
    const fixed_left_padding: usize = 1;
    const fixed_right_padding: usize = 1;

    fn forInnerWidth(inner_width: usize) TableLayout {
        const fixed_suffix = fixed_left_padding + fixed_title_to_seeders_gap + fixed_seeders_width + fixed_between_stats_gap + fixed_leechers_width + fixed_between_stats_gap + fixed_size_width + fixed_right_padding;
        const title_width = if (inner_width > fixed_suffix) inner_width - fixed_suffix else 1;
        return .{
            .title_col_width = title_width,
            .seeders_width = fixed_seeders_width,
            .leechers_width = fixed_leechers_width,
            .size_width = fixed_size_width,
            .title_to_seeders_gap = fixed_title_to_seeders_gap,
            .between_stats_gap = fixed_between_stats_gap,
        };
    }

    fn compactFallback() TableLayout {
        return .{
            .title_col_width = 0,
            .seeders_width = fixed_seeders_width,
            .leechers_width = fixed_leechers_width,
            .size_width = fixed_size_width,
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
    if (!std.meta.eql(prev.live_status, current.live_status)) return .partial_window;
    if (prev.spinner_frame != current.spinner_frame) return .partial_window;

    if (prev.scroll_offset != current.scroll_offset) return .partial_window;
    if (prev.cursor != current.cursor) return .partial_cursor;
    return .none;
}

fn computeDisplayCount(max_rows: u16, torrents_len: usize) usize {
    _ = torrents_len;
    return if (max_rows > 7) @as(usize, @intCast(max_rows - 7)) else 1;
}

fn findTorrentByLink(torrents: []const Torrent, link: []const u8) ?usize {
    for (torrents, 0..) |torrent, idx| {
        if (std.mem.eql(u8, torrent.link, link)) return idx;
    }
    return null;
}

fn drawCompact(
    stdout: compat.FileWriter,
    colors: theme.Theme,
    border: theme.BorderChars,
    self: *ResultsWidget,
    max_cols: u16,
    selected_send_state: ResultsWidget.SendState,
    end_idx: usize,
) void {
    term.moveCursor(1, 1);
    term.setFg256(colors.panel_title);
    term.setBold(true);
    stdout.writeAll("Results\r\n") catch {};
    term.setBold(false);
    drawCompactDivider(stdout, colors, border, max_cols);
    term.setFg256(colorForSendState(colors, selected_send_state));
    if (self.torrents.len == 0) {
        var status_buf: [128]u8 = undefined;
        const status = formatStatusText(&status_buf, self.scroll_offset, end_idx, self.total_count, self.torrents.len, self.live_status, self.spinner_frame);
        stdout.writeAll(status) catch {};
        stdout.writeAll("\r\n") catch {};
    } else {
        const current = self.torrents[self.cursor];
        var trunc_buf: [512]u8 = undefined;
        const shown = theme.truncateWithEllipsis(current.title, compactTitleWidth(max_cols), trunc_buf[0..]);
        stdout.writeAll("> ") catch {};
        stdout.writeAll(shown) catch {};
        stdout.writeAll("\r\n") catch {};
        term.setFg256(colors.panel_title);
        var status_buf: [128]u8 = undefined;
        const status = formatStatusText(&status_buf, self.scroll_offset, end_idx, self.total_count, self.torrents.len, self.live_status, self.spinner_frame);
        stdout.writeAll(status) catch {};
        stdout.writeAll("\r\n") catch {};
    }
    drawCompactDivider(stdout, colors, border, max_cols);
    term.setFg256(colors.muted);
    stdout.writeAll("ENTER select | n search | ESC exit | j/k line down/up") catch {};
    term.resetColor();
    term.clearBelow();
}

fn drawCompactDivider(stdout: compat.FileWriter, colors: theme.Theme, border: theme.BorderChars, max_cols: u16) void {
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
    stdout: compat.FileWriter,
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
    stdout: compat.FileWriter,
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
    stdout: compat.FileWriter,
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
    const row = buildDataCells(&cell_buf, inner_width, layout, row_title, torrent.seeders, torrent.leechers, torrent.size_bytes);

    if (abs_idx == selected_idx) {
        term.setBg256(colors.selected_bg);
        term.setFg256(selectedColorForSendState(colors, widget.getSendState(abs_idx)));
        term.setBold(true);
        try theme.writePadded(stdout, row, inner_width);
        term.resetColor();
        term.setBold(false);
    } else {
        term.setFg256(colorForSendState(colors, widget.getSendState(abs_idx)));
        try theme.writePadded(stdout, row, inner_width);
    }

    term.setFg256(colors.panel_border);
    try stdout.writeAll(border.vertical);
    term.resetColor();
    try stdout.writeAll("\r\n");
}

fn colorForSendState(colors: theme.Theme, state: ResultsWidget.SendState) u8 {
    return switch (state) {
        .none => colors.text,
        .success => colors.ok,
        .failed => colors.err,
    };
}

fn selectedColorForSendState(colors: theme.Theme, state: ResultsWidget.SendState) u8 {
    return switch (state) {
        .none => colors.selected_fg,
        // Darker tones improve legibility against selected_bg.
        .success => 22,
        .failed => 88,
    };
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

fn writeHeaderCells(stdout: compat.FileWriter, inner_width: usize, layout: TableLayout) !void {
    var buf: [256]u8 = undefined;
    const header = buildHeaderCells(&buf, inner_width, layout);
    try stdout.writeAll(header);
}

fn buildHeaderCells(buf: []u8, inner_width: usize, layout: TableLayout) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);

    writer.writeAll(" ") catch return "";
    theme.writePadded(&writer, "Title", layout.title_col_width) catch return "";
    writeSpaces(&writer, layout.title_to_seeders_gap) catch return "";
    writeRightAligned(&writer, "S", layout.seeders_width) catch return "";
    writeSpaces(&writer, layout.between_stats_gap) catch return "";
    writeRightAligned(&writer, "L", layout.leechers_width) catch return "";
    writeSpaces(&writer, layout.between_stats_gap) catch return "";
    writeRightAligned(&writer, "Size", layout.size_width) catch return "";
    writer.writeAll(" ") catch return "";

    const used = writer.buffered().len;
    if (used < inner_width) {
        writeSpaces(&writer, inner_width - used) catch {};
    }
    return writer.buffered();
}

fn buildDataCells(
    buf: []u8,
    inner_width: usize,
    layout: TableLayout,
    title: []const u8,
    seeders: u32,
    leechers: u32,
    size_bytes: ?u64,
) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);

    writer.writeAll(" ") catch return "";
    theme.writePadded(&writer, title, layout.title_col_width) catch return "";
    writeSpaces(&writer, layout.title_to_seeders_gap) catch return "";

    var sbuf: [16]u8 = undefined;
    const seeders_text = std.fmt.bufPrint(&sbuf, "{d}", .{seeders}) catch "";
    writeRightAligned(&writer, seeders_text, layout.seeders_width) catch return "";
    writeSpaces(&writer, layout.between_stats_gap) catch return "";

    var lbuf: [16]u8 = undefined;
    const leechers_text = std.fmt.bufPrint(&lbuf, "{d}", .{leechers}) catch "";
    writeRightAligned(&writer, leechers_text, layout.leechers_width) catch return "";
    writeSpaces(&writer, layout.between_stats_gap) catch return "";

    var size_buf: [16]u8 = undefined;
    const size_text = formatSizeBytes(&size_buf, size_bytes);
    writeRightAligned(&writer, size_text, layout.size_width) catch return "";
    writer.writeAll(" ") catch return "";

    const used = writer.buffered().len;
    if (used < inner_width) {
        writeSpaces(&writer, inner_width - used) catch {};
    }
    return writer.buffered();
}

fn formatSizeBytes(buf: []u8, size_bytes: ?u64) []const u8 {
    const bytes = size_bytes orelse return "-";
    const mib: u128 = 1024 * 1024;
    const gib: u128 = mib * 1024;
    const divisor = if (bytes >= gib) gib else mib;
    const unit = if (bytes >= gib) "GB" else "MB";
    const tenths = (@as(u128, bytes) * 10 + divisor / 2) / divisor;
    if (tenths % 10 == 0) {
        return std.fmt.bufPrint(buf, "{d} {s}", .{ tenths / 10, unit }) catch "-";
    }
    return std.fmt.bufPrint(buf, "{d}.{d} {s}", .{ tenths / 10, tenths % 10, unit }) catch "-";
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
    stdout: compat.FileWriter,
    panel_width: usize,
    border: theme.BorderChars,
    colors: theme.Theme,
    self: *ResultsWidget,
    end_idx: usize,
) !void {
    var status_buf: [128]u8 = undefined;
    const status = formatStatusText(&status_buf, self.scroll_offset, end_idx, self.total_count, self.torrents.len, self.live_status, self.spinner_frame);
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

fn formatStatusText(
    buf: []u8,
    scroll_offset: usize,
    end_idx: usize,
    total_count: usize,
    torrents_len: usize,
    live_status: ResultsWidget.LiveStatus,
    spinner_frame: usize,
) []const u8 {
    const base = switch (live_status.phase) {
        .discovering => if (torrents_len == 0)
            std.fmt.bufPrint(buf, "No results yet | Discovering indexers... {s}", .{spinner_frames[spinner_frame % spinner_frames.len]}) catch "No results yet"
        else
            formatShowing(buf, scroll_offset, end_idx, total_count),
        .querying => querying: {
            const spinner = spinner_frames[spinner_frame % spinner_frames.len];
            if (torrents_len == 0) {
                if (live_status.failed == 0) {
                    break :querying std.fmt.bufPrint(buf, "No results yet | Searching {d}/{d} {s}", .{ live_status.completed, live_status.total, spinner }) catch "No results yet";
                }
                break :querying std.fmt.bufPrint(
                    buf,
                    "No results yet | Searching {d}/{d}, {d} failed {s}",
                    .{ live_status.completed, live_status.total, live_status.failed, spinner },
                ) catch "No results yet";
            }
            if (live_status.failed == 0) {
                break :querying std.fmt.bufPrint(
                    buf,
                    "Showing {d}-{d} of {d} | Searching {d}/{d} {s}",
                    .{ scroll_offset + 1, end_idx, total_count, live_status.completed, live_status.total, spinner },
                ) catch "Showing";
            }
            break :querying std.fmt.bufPrint(
                buf,
                "Showing {d}-{d} of {d} | Searching {d}/{d}, {d} failed {s}",
                .{ scroll_offset + 1, end_idx, total_count, live_status.completed, live_status.total, live_status.failed, spinner },
            ) catch "Showing";
        },
        .done => done: {
            if (live_status.failed == 0) {
                if (torrents_len == 0) {
                    break :done std.fmt.bufPrint(
                        buf,
                        "No results found | All indexers successful",
                        .{},
                    ) catch "No results found";
                }
                break :done std.fmt.bufPrint(
                    buf,
                    "Showing {d}-{d} of {d} | All indexers successful",
                    .{ scroll_offset + 1, end_idx, total_count },
                ) catch "Showing";
            } else {
                if (torrents_len == 0) {
                    break :done std.fmt.bufPrint(
                        buf,
                        "No results found | {d} indexers failed ('e' to review)",
                        .{ live_status.failed },
                    ) catch "No results found";
                }
                break :done std.fmt.bufPrint(
                    buf,
                    "Showing {d}-{d} of {d} | {d} indexers failed ('e' to review)",
                    .{ scroll_offset + 1, end_idx, total_count, live_status.failed },
                ) catch "Showing";
            }
        },
    };
    return base;
}

fn formatShowing(buf: []u8, scroll_offset: usize, end_idx: usize, total_count: usize) []const u8 {
    return std.fmt.bufPrint(buf, "Showing {d}-{d} of {d}", .{ scroll_offset + 1, end_idx, total_count }) catch "Showing";
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
    review_failures,
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
        .live_status = .{},
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
        .live_status = .{},
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
        .live_status = .{},
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
        .live_status = .{},
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
        .live_status = .{},
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
        .live_status = .{},
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
        .live_status = .{},
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
        .live_status = .{},
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
        .live_status = .{},
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
        .live_status = .{},
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
        .live_status = .{},
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
    const row = buildDataCells(&rbuf, inner_width, layout, "Voyager", 7, 42, 512 * 1024 * 1024);

    const s_header = std.mem.indexOfScalar(u8, header, 'S') orelse return error.TestUnexpectedResult;
    const l_header = std.mem.indexOfScalar(u8, header, 'L') orelse return error.TestUnexpectedResult;
    const size_header = std.mem.indexOf(u8, header, "Size") orelse return error.TestUnexpectedResult;
    const s_row = (std.mem.indexOf(u8, row, "   7") orelse return error.TestUnexpectedResult) + 3;
    const l_row = (std.mem.indexOf(u8, row, "  42") orelse return error.TestUnexpectedResult) + 3;
    const size_row = std.mem.indexOf(u8, row, "512 MB") orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(s_header, s_row);
    try std.testing.expectEqual(l_header, l_row);
    try std.testing.expectEqual(size_header + 3, size_row + 5);
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
    const row = buildDataCells(&rbuf, inner_width, layout, shown_title, 999, 1000, 12 * 1024 * 1024 * 1024 + 410 * 1024 * 1024);

    const s_header = std.mem.indexOfScalar(u8, header, 'S') orelse return error.TestUnexpectedResult;
    const l_header = std.mem.indexOfScalar(u8, header, 'L') orelse return error.TestUnexpectedResult;
    const size_header = std.mem.indexOf(u8, header, "Size") orelse return error.TestUnexpectedResult;
    const s_row = (std.mem.indexOf(u8, row, " 999") orelse return error.TestUnexpectedResult) + 3;
    const l_row = (std.mem.indexOf(u8, row, "1000") orelse return error.TestUnexpectedResult) + 3;
    const size_row = std.mem.indexOf(u8, row, "12.4 GB") orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(s_header, s_row);
    try std.testing.expectEqual(l_header, l_row);
    try std.testing.expectEqual(size_header, size_row + 3);
}

test "formatSizeBytes renders missing megabytes and gigabytes" {
    var buf: [16]u8 = undefined;

    try std.testing.expectEqualStrings("-", formatSizeBytes(&buf, null));
    try std.testing.expectEqualStrings("12 MB", formatSizeBytes(&buf, 12 * 1024 * 1024));
    try std.testing.expectEqualStrings("512 MB", formatSizeBytes(&buf, 512 * 1024 * 1024));
    try std.testing.expectEqualStrings("1 GB", formatSizeBytes(&buf, 1024 * 1024 * 1024));
    try std.testing.expectEqualStrings("12 GB", formatSizeBytes(&buf, 12 * 1024 * 1024 * 1024));
    try std.testing.expectEqualStrings("12.4 GB", formatSizeBytes(&buf, 12 * 1024 * 1024 * 1024 + 410 * 1024 * 1024));
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

test "ResultsWidget handleEvent unsupported key does nothing" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const torrents = &[_]Torrent{
        .{ .title = "Test1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "Test2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
    };
    widget.setTorrents(torrents, 2);

    const event = term.Event{ .key = .unknown, .value = 0 };
    const action = widget.handleEvent(event, 20);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqual(@as(usize, 0), widget.cursor);
    try std.testing.expectEqual(@as(usize, 0), widget.scroll_offset);
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

test "ResultsWidget send state persists and resets on new results" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const torrents1 = &[_]Torrent{
        .{ .title = "Test1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "Test2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
    };
    widget.setTorrents(torrents1, 2);
    widget.setSendState(1, .success);

    try std.testing.expectEqual(ResultsWidget.SendState.success, widget.getSendState(1));

    const torrents2 = &[_]Torrent{
        .{ .title = "Test3", .seeders = 3, .leechers = 0, .link = "magnet:3" },
    };
    widget.setTorrents(torrents2, 1);

    try std.testing.expectEqual(ResultsWidget.SendState.none, widget.getSendState(0));
}

test "ResultsWidget updateTorrents preserves cursor and send state by link" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const torrents1 = &[_]Torrent{
        .{ .title = "Low", .seeders = 1, .leechers = 0, .link = "magnet:low" },
        .{ .title = "Selected", .seeders = 5, .leechers = 0, .link = "magnet:selected" },
    };
    widget.setTorrents(torrents1, 2);
    widget.cursor = 1;
    widget.setSendState(1, .success);

    const torrents2 = &[_]Torrent{
        .{ .title = "New High", .seeders = 50, .leechers = 0, .link = "magnet:new" },
        .{ .title = "Selected", .seeders = 5, .leechers = 0, .link = "magnet:selected" },
        .{ .title = "Low", .seeders = 1, .leechers = 0, .link = "magnet:low" },
    };
    const previous_cursor_link = if (widget.cursor < widget.torrents.len) widget.torrents[widget.cursor].link else null;
    widget.updateTorrents(torrents2, 3, previous_cursor_link);

    try std.testing.expectEqual(@as(usize, 1), widget.cursor);
    try std.testing.expectEqual(ResultsWidget.SendState.none, widget.getSendState(0));
    try std.testing.expectEqual(ResultsWidget.SendState.success, widget.getSendState(1));
}

test "formatStatusText renders live search phases" {
    var buf: [128]u8 = undefined;

    try std.testing.expectEqualStrings(
        "No results yet | Discovering indexers... ⣎⡇",
        formatStatusText(&buf, 0, 0, 0, 0, .{ .phase = .discovering }, 0),
    );
    try std.testing.expectEqualStrings(
        "Showing 1-10 of 42 | Searching 3/8 ⣎⡇",
        formatStatusText(&buf, 0, 10, 42, 42, .{ .phase = .querying, .completed = 3, .total = 8 }, 0),
    );
    try std.testing.expectEqualStrings(
        "Showing 1-10 of 42 | Searching 3/8, 1 failed ⣇⡇",
        formatStatusText(&buf, 0, 10, 42, 42, .{ .phase = .querying, .completed = 3, .total = 8, .failed = 1 }, 1),
    );
    try std.testing.expectEqualStrings(
        "Showing 1-10 of 42 | All indexers successful",
        formatStatusText(&buf, 0, 10, 42, 42, .{ .phase = .done }, 0),
    );
    try std.testing.expectEqualStrings(
        "Showing 1-10 of 42 | 1 indexers failed ('e' to review)",
        formatStatusText(&buf, 0, 10, 42, 42, .{ .phase = .done, .completed = 4, .total = 4, .failed = 1 }, 0),
    );
    try std.testing.expectEqualStrings(
        "No results found | All indexers successful",
        formatStatusText(&buf, 0, 0, 0, 0, .{ .phase = .done }, 0),
    );
}

test "ResultsWidget advanceSpinner ticks frame correctly" {
    var widget = ResultsWidget.init(std.testing.allocator);
    defer widget.deinit();

    // done phase: should not tick
    widget.live_status = .{ .phase = .done };
    try std.testing.expect(!widget.advanceSpinner());
    try std.testing.expectEqual(@as(usize, 0), widget.spinner_frame);

    // querying phase: should tick and wrap around spinner_frames
    widget.live_status = .{ .phase = .querying };
    try std.testing.expect(widget.advanceSpinner());
    try std.testing.expectEqual(@as(usize, 1), widget.spinner_frame);

    for (0..8) |_| {
        try std.testing.expect(widget.advanceSpinner());
    }
    try std.testing.expectEqual(@as(usize, 9), widget.spinner_frame);

    // 10th tick should wrap around to 0
    try std.testing.expect(widget.advanceSpinner());
    try std.testing.expectEqual(@as(usize, 0), widget.spinner_frame);
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
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    try writeRightAligned(&writer.writer, "123456", 4);
    try writer.writer.flush();
    out = writer.toArrayList();
    try std.testing.expectEqualStrings("3456", out.items);
}

test "selectedColorForSendState uses darker tones for selected rows" {
    const colors = theme.superseedr_like;
    try std.testing.expectEqual(colors.selected_fg, selectedColorForSendState(colors, .none));
    try std.testing.expectEqual(@as(u8, 22), selectedColorForSendState(colors, .success));
    try std.testing.expectEqual(@as(u8, 88), selectedColorForSendState(colors, .failed));
}
