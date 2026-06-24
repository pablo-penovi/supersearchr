const std = @import("std");
const term = @import("term");
const theme = @import("theme");
const Torrent = @import("torrent").Torrent;
const compat = @import("compat");
const list_nav = @import("list_nav");

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

pub const SortColumn = enum {
    age,
    seeders,
    leechers,
    size,
};

pub const SortOrder = enum {
    asc,
    desc,
};

pub const ResultsWidget = struct {
    allocator: std.mem.Allocator,
    torrents: []Torrent,
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
    sort_column: SortColumn,
    sort_order: SortOrder,
    header_cursor: SortColumn,
    list_search_query: ?[]const u8,
    list_search_active: bool,

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
            .sort_column = .seeders,
            .sort_order = .desc,
            .header_cursor = .seeders,
            .list_search_query = null,
            .list_search_active = false,
        };
    }

    pub fn deinit(self: *ResultsWidget) void {
        self.sent_torrents.deinit(self.allocator);
        for (self.failed_indexers.items) |name| {
            self.allocator.free(name);
        }
        self.failed_indexers.deinit(self.allocator);
        if (self.list_search_query) |q| {
            self.allocator.free(q);
        }
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

    pub fn setTorrents(self: *ResultsWidget, torrents: []Torrent, total: usize) void {
        sortTorrentsBy(torrents, self.sort_column, self.sort_order);
        self.torrents = torrents;
        self.total_count = total;
        self.cursor = 0;
        self.scroll_offset = 0;
        self.force_full_redraw = true;
        self.resetMarqueeState();
        self.sent_torrents.clearRetainingCapacity();
    }

    pub fn updateTorrents(self: *ResultsWidget, torrents: []Torrent, total: usize, previous_cursor_link: ?[]const u8) void {
        sortTorrentsBy(torrents, self.sort_column, self.sort_order);
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
        self.display_count = list_nav.computeDisplayCount(max_rows);
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
                    drawPanelFrame(stdout, panel_width, inner_width, border, colors, layout, self);
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
                    if (self.live_status.phase == .done) {
                        stdout.writeAll("  ENTER select | s search | r refresh | ESC exit | \xe2\x86\x91\xe2\x86\x93 line | shift+\xe2\x86\x91\xe2\x86\x93 page | \xe2\x86\x90\xe2\x86\x92 move sort | TAB apply sort | F2 load profile") catch {};
                    } else {
                        stdout.writeAll("  ENTER select | s search | ESC exit | \xe2\x86\x91\xe2\x86\x93 line | shift+\xe2\x86\x91\xe2\x86\x93 page | \xe2\x86\x90\xe2\x86\x92 move sort | TAB apply sort | F2 load profile") catch {};
                    }
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

    pub fn renderStatusOnly(self: *ResultsWidget, max_rows: u16, max_cols: u16) bool {
        const compact = theme.isCompactViewport(max_rows, max_cols);
        if (compact) return false;

        const stdout = compat.stdoutWriter();
        const colors = theme.superseedr_like;
        const border = theme.unicode_border;
        const panel_width = @as(usize, @intCast(max_cols - 2));
        self.display_count = list_nav.computeDisplayCount(max_rows);
        const end_idx = @min(self.scroll_offset + self.display_count, self.torrents.len);

        term.moveCursor(statusRowFromDisplayCount(self.display_count), 1);
        drawStatusRow(stdout, panel_width, border, colors, self, end_idx) catch {};
        return true;
    }

    fn adjustScroll(self: *ResultsWidget) void {
        list_nav.adjustScroll(self.cursor, &self.scroll_offset, self.display_count);
    }

    pub fn handleEvent(self: *ResultsWidget, event: term.Event, max_rows: u16) ResultsAction {
        switch (event.key) {
            .arrow_left => {
                switch (self.header_cursor) {
                    .age => {},
                    .seeders => {
                        self.header_cursor = .age;
                        self.force_full_redraw = true;
                    },
                    .leechers => {
                        self.header_cursor = .seeders;
                        self.force_full_redraw = true;
                    },
                    .size => {
                        self.header_cursor = .leechers;
                        self.force_full_redraw = true;
                    },
                }
                return .continue_browsing;
            },
            .arrow_right => {
                switch (self.header_cursor) {
                    .age => {
                        self.header_cursor = .seeders;
                        self.force_full_redraw = true;
                    },
                    .seeders => {
                        self.header_cursor = .leechers;
                        self.force_full_redraw = true;
                    },
                    .leechers => {
                        self.header_cursor = .size;
                        self.force_full_redraw = true;
                    },
                    .size => {},
                }
                return .continue_browsing;
            },
            .tab => {
                if (self.sort_column == self.header_cursor) {
                    self.sort_order = switch (self.sort_order) {
                        .asc => .desc,
                        .desc => .asc,
                    };
                } else {
                    self.sort_column = self.header_cursor;
                    self.sort_order = .asc;
                }

                if (self.torrents.len > 0) {
                    const mutable_torrents = @constCast(self.torrents);
                    sortTorrentsBy(mutable_torrents, self.sort_column, self.sort_order);

                    self.cursor = 0;
                    self.scroll_offset = 0;
                    self.resetMarqueeState();
                }
                self.force_full_redraw = true;
                return .continue_browsing;
            },
            else => {},
        }

        if (self.torrents.len == 0) {
            switch (event.key) {
                .char => {
                    if (event.value == 'e' or event.value == 'E') {
                        if (self.live_status.phase == .done and self.live_status.failed > 0) return .review_failures;
                    }
                    if (event.value == 's' or event.value == 'S') return .new_search;
                    if (event.value == 'r' or event.value == 'R') {
                        if (self.live_status.phase == .done) return .refresh;
                    }
                    return .continue_browsing;
                },
                .escape => return .cancel,
                else => return .continue_browsing,
            }
        }

        self.display_count = list_nav.computeDisplayCount(max_rows);

        switch (event.key) {
            .char => {
                if (event.value == 'e' or event.value == 'E') {
                    if (self.live_status.phase == .done and self.live_status.failed > 0) return .review_failures;
                }
                if (event.value == 's' or event.value == 'S') {
                    return .new_search;
                }
                if (event.value == 'r' or event.value == 'R') {
                    if (self.live_status.phase == .done) return .refresh;
                }
                if (event.value == '/') {
                    return .open_list_search;
                }
                if (event.value == 'n') {
                    if (self.list_search_active and self.list_search_query != null) {
                        self.moveNextMatch();
                    }
                    return .continue_browsing;
                }
                if (event.value == 'N') {
                    if (self.list_search_active and self.list_search_query != null) {
                        self.movePrevMatch();
                    }
                    return .continue_browsing;
                }
                return .continue_browsing;
            },
            .arrow_down => return self.moveCursorDown(),
            .arrow_up => return self.moveCursorUp(),
            .shift_arrow_down => return self.moveCursorPageDown(),
            .shift_arrow_up => return self.moveCursorPageUp(),
            .enter => {
                return .{ .select = self.cursor };
            },
            .escape => {
                if (self.list_search_active) {
                    self.clearListSearch();
                    return .continue_browsing;
                }
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

        self.display_count = list_nav.computeDisplayCount(max_rows);
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

        if (list_nav.stepMarqueeState(
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

    fn moveCursorDown(self: *ResultsWidget) ResultsAction {
        if (list_nav.moveDown(&self.cursor, self.torrents.len)) {
            self.adjustScroll();
            self.resetMarqueeState();
        }
        return .continue_browsing;
    }

    fn moveCursorUp(self: *ResultsWidget) ResultsAction {
        if (list_nav.moveUp(&self.cursor)) {
            self.adjustScroll();
            self.resetMarqueeState();
        }
        return .continue_browsing;
    }

    fn moveCursorPageDown(self: *ResultsWidget) ResultsAction {
        if (list_nav.movePageDown(&self.cursor, self.torrents.len, self.display_count)) {
            self.adjustScroll();
            self.resetMarqueeState();
        } else {
            self.adjustScroll();
        }
        return .continue_browsing;
    }

    fn moveCursorPageUp(self: *ResultsWidget) ResultsAction {
        if (list_nav.movePageUp(&self.cursor, self.display_count)) {
            self.adjustScroll();
            self.resetMarqueeState();
        } else {
            self.adjustScroll();
        }
        return .continue_browsing;
    }

    pub fn applyListSearch(self: *ResultsWidget, query: []const u8) !void {
        if (self.list_search_query) |existing| {
            self.allocator.free(existing);
        }
        self.list_search_query = try self.allocator.dupe(u8, query);
        self.list_search_active = true;
        self.force_full_redraw = true;

        // Jump to the first match starting from current cursor (inclusive)
        if (self.torrents.len > 0) {
            var i: usize = 0;
            while (i < self.torrents.len) : (i += 1) {
                const idx = (self.cursor + i) % self.torrents.len;
                if (titleContains(self.torrents[idx].title, query)) {
                    self.cursor = idx;
                    self.adjustScroll();
                    break;
                }
            }
        }
    }

    pub fn clearListSearch(self: *ResultsWidget) void {
        if (self.list_search_query) |existing| {
            self.allocator.free(existing);
            self.list_search_query = null;
        }
        self.list_search_active = false;
        self.force_full_redraw = true;
    }

    pub fn moveNextMatch(self: *ResultsWidget) void {
        const query = self.list_search_query orelse return;
        if (self.torrents.len == 0) return;

        var i: usize = 1;
        while (i <= self.torrents.len) : (i += 1) {
            const idx = (self.cursor + i) % self.torrents.len;
            if (titleContains(self.torrents[idx].title, query)) {
                self.cursor = idx;
                self.adjustScroll();
                self.force_full_redraw = true;
                return;
            }
        }
    }

    pub fn movePrevMatch(self: *ResultsWidget) void {
        const query = self.list_search_query orelse return;
        if (self.torrents.len == 0) return;

        var i: usize = 1;
        while (i <= self.torrents.len) : (i += 1) {
            const idx = (self.cursor + self.torrents.len * i - i) % self.torrents.len;
            if (titleContains(self.torrents[idx].title, query)) {
                self.cursor = idx;
                self.adjustScroll();
                self.force_full_redraw = true;
                return;
            }
        }
    }
};

const RenderMode = list_nav.RenderMode;

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
    age_width: usize,
    seeders_width: usize,
    leechers_width: usize,
    size_width: usize,
    title_to_age_gap: usize,
    age_to_seeders_gap: usize,
    between_stats_gap: usize,

    const fixed_age_width: usize = 6;
    const fixed_seeders_width: usize = 4;
    const fixed_leechers_width: usize = 4;
    const fixed_size_width: usize = 9;
    const fixed_title_to_age_gap: usize = 2;
    const fixed_age_to_seeders_gap: usize = 2;
    const fixed_between_stats_gap: usize = 2;
    const fixed_left_padding: usize = 1;
    const fixed_right_padding: usize = 1;

    fn forInnerWidth(inner_width: usize) TableLayout {
        const fixed_suffix = fixed_left_padding + fixed_title_to_age_gap + fixed_age_width + fixed_age_to_seeders_gap + fixed_seeders_width + fixed_between_stats_gap + fixed_leechers_width + fixed_between_stats_gap + fixed_size_width + fixed_right_padding;
        const title_width = if (inner_width > fixed_suffix) inner_width - fixed_suffix else 1;
        return .{
            .title_col_width = title_width,
            .age_width = fixed_age_width,
            .seeders_width = fixed_seeders_width,
            .leechers_width = fixed_leechers_width,
            .size_width = fixed_size_width,
            .title_to_age_gap = fixed_title_to_age_gap,
            .age_to_seeders_gap = fixed_age_to_seeders_gap,
            .between_stats_gap = fixed_between_stats_gap,
        };
    }

    fn compactFallback() TableLayout {
        return .{
            .title_col_width = 0,
            .age_width = fixed_age_width,
            .seeders_width = fixed_seeders_width,
            .leechers_width = fixed_leechers_width,
            .size_width = fixed_size_width,
            .title_to_age_gap = fixed_title_to_age_gap,
            .age_to_seeders_gap = fixed_age_to_seeders_gap,
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
    const prev = last_snapshot;

    const base_current = list_nav.BaseSnapshot{
        .rows = current.rows,
        .cols = current.cols,
        .is_compact = current.is_compact,
        .cursor = current.cursor,
        .scroll_offset = current.scroll_offset,
        .display_count = current.display_count,
        .item_count = current.torrents_len,
    };
    const base_prev: ?list_nav.BaseSnapshot = if (prev) |p| .{
        .rows = p.rows,
        .cols = p.cols,
        .is_compact = p.is_compact,
        .cursor = p.cursor,
        .scroll_offset = p.scroll_offset,
        .display_count = p.display_count,
        .item_count = p.torrents_len,
    } else null;

    const extra_full_tier_changed = if (prev) |p| p.total_count != current.total_count else false;
    const extra_window_tier_changed = if (prev) |p|
        !std.meta.eql(p.live_status, current.live_status) or p.spinner_frame != current.spinner_frame
    else
        false;

    return list_nav.computeRedrawMode(
        has_drawn_once,
        force_full_redraw,
        force_selected_redraw,
        base_prev,
        base_current,
        extra_full_tier_changed,
        extra_window_tier_changed,
    );
}

fn titleContains(title: []const u8, query: []const u8) bool {
    if (query.len == 0) return false;
    if (title.len < query.len) return false;

    var i: usize = 0;
    while (i <= title.len - query.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(title[i .. i + query.len], query)) {
            return true;
        }
    }
    return false;
}

fn padTitle(buf: []u8, text: []const u8, width: usize) []const u8 {
    if (width == 0) return "";
    const disp_width = theme.displayWidthOfText(text);
    if (disp_width >= width) return text;
    if (text.len >= buf.len) return text;

    @memcpy(buf[0..text.len], text);
    var idx = text.len;
    for (0..(width - disp_width)) |_| {
        if (idx >= buf.len) break;
        buf[idx] = ' ';
        idx += 1;
    }
    return buf[0..idx];
}

fn highlightSearchTerm(
    dest: []u8,
    title: []const u8,
    search_term: []const u8,
    is_selected: bool,
    colors: theme.Theme,
    send_state: ResultsWidget.SendState,
) []const u8 {
    if (search_term.len == 0 or title.len == 0) return title;

    var writer: std.Io.Writer = .fixed(dest);

    var i: usize = 0;
    while (i < title.len) {
        if (i + search_term.len <= title.len and
            std.ascii.eqlIgnoreCase(title[i .. i + search_term.len], search_term))
        {
            // Match found! Write highlight ANSI sequence.
            writer.writeAll("\x1b[48;5;220m\x1b[38;5;16m\x1b[1m") catch break;
            writer.writeAll(title[i .. i + search_term.len]) catch break;

            // Restore styling:
            writer.writeAll("\x1b[0m") catch break;
            if (is_selected) {
                var buf: [64]u8 = undefined;
                const fg = selectedColorForSendState(colors, send_state);
                const style = std.fmt.bufPrint(&buf, "\x1b[48;5;{d}m\x1b[38;5;{d}m\x1b[1m", .{ colors.selected_bg, fg }) catch "";
                writer.writeAll(style) catch break;
            } else {
                var buf: [32]u8 = undefined;
                const fg = colorForSendState(colors, send_state);
                const style = std.fmt.bufPrint(&buf, "\x1b[38;5;{d}m", .{fg}) catch "";
                writer.writeAll(style) catch break;
            }

            i += search_term.len;
        } else {
            writer.writeByte(title[i]) catch break;
            i += 1;
        }
    }

    return writer.buffered();
}

fn findTorrentByLink(torrents: []const Torrent, link: []const u8) ?usize {
    for (torrents, 0..) |torrent, idx| {
        if (std.mem.eql(u8, torrent.link, link)) return idx;
    }
    return null;
}

fn sortTorrentsBy(torrents: []Torrent, col: SortColumn, order: SortOrder) void {
    const Context = struct {
        col: SortColumn,
        order: SortOrder,

        fn lessThan(ctx: @This(), a: Torrent, b: Torrent) bool {
            switch (ctx.col) {
                .age => {
                    const a_age = a.pub_date orelse 0;
                    const b_age = b.pub_date orelse 0;
                    return switch (ctx.order) {
                        .asc => a_age < b_age,
                        .desc => a_age > b_age,
                    };
                },
                .seeders => {
                    return switch (ctx.order) {
                        .asc => a.seeders < b.seeders,
                        .desc => a.seeders > b.seeders,
                    };
                },
                .leechers => {
                    return switch (ctx.order) {
                        .asc => a.leechers < b.leechers,
                        .desc => a.leechers > b.leechers,
                    };
                },
                .size => {
                    const a_size = a.size_bytes orelse 0;
                    const b_size = b.size_bytes orelse 0;
                    return switch (ctx.order) {
                        .asc => a_size < b_size,
                        .desc => a_size > b_size,
                    };
                },
            }
        }
    };

    std.mem.sort(Torrent, torrents, Context{ .col = col, .order = order }, Context.lessThan);
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
        var highlight_buf: [1024]u8 = undefined;
        const shown = theme.truncateWithEllipsis(current.title, compactTitleWidth(max_cols), trunc_buf[0..]);
        const final_shown = if (self.list_search_active and self.list_search_query != null)
            highlightSearchTerm(
                highlight_buf[0..],
                shown,
                self.list_search_query.?,
                true,
                colors,
                selected_send_state,
            )
        else
            shown;
        stdout.writeAll("> ") catch {};
        stdout.writeAll(final_shown) catch {};
        stdout.writeAll("\r\n") catch {};
        term.setFg256(colors.panel_title);
        var status_buf: [128]u8 = undefined;
        const status = formatStatusText(&status_buf, self.scroll_offset, end_idx, self.total_count, self.torrents.len, self.live_status, self.spinner_frame);
        stdout.writeAll(status) catch {};
        stdout.writeAll("\r\n") catch {};
    }
    drawCompactDivider(stdout, colors, border, max_cols);
    term.setFg256(colors.muted);
    if (self.live_status.phase == .done) {
        stdout.writeAll("ENTER select | s search | r refresh | ESC exit | \xe2\x86\x91\xe2\x86\x93 line") catch {};
    } else {
        stdout.writeAll("ENTER select | s search | ESC exit | \xe2\x86\x91\xe2\x86\x93 line") catch {};
    }
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
    widget: *ResultsWidget,
) void {
    writeSpaces(stdout, 1) catch {};
    theme.drawPanelTop(stdout, panel_width, border, colors) catch {};

    writeSpaces(stdout, 1) catch {};
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    writeHeaderCells(stdout, inner_width, layout, colors, widget) catch {};
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
    var pad_buf: [512]u8 = undefined;
    var highlight_buf: [1024]u8 = undefined;

    const torrent = torrents[abs_idx];
    const row_title = if (abs_idx == selected_idx)
        selectedTitleForRender(widget, torrent.title, layout.title_col_width, trunc_buf[0..], marquee_buf[0..])
    else
        theme.truncateWithEllipsis(torrent.title, layout.title_col_width, trunc_buf[0..]);

    const is_selected = (abs_idx == selected_idx);
    const final_title = if (widget.list_search_active and widget.list_search_query != null) final_title: {
        const padded = padTitle(pad_buf[0..], row_title, layout.title_col_width);
        break :final_title highlightSearchTerm(
            highlight_buf[0..],
            padded,
            widget.list_search_query.?,
            is_selected,
            colors,
            widget.getSendState(abs_idx),
        );
    } else row_title;

    const current_time = compat.timestamp();
    const row = buildDataCells(&cell_buf, inner_width, layout, final_title, torrent.seeders, torrent.leechers, torrent.size_bytes, torrent.pub_date, current_time);

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

fn formatColumnHeader(
    buf: []u8,
    col: SortColumn,
    active_col: SortColumn,
    order: SortOrder,
    cursor_col: SortColumn,
) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);

    const has_cursor = (col == cursor_col);
    const is_active = (col == active_col);

    switch (col) {
        .age => {
            if (has_cursor and is_active) {
                const arrow = if (order == .asc) "↑" else "↓";
                writer.writeAll("<Age") catch {};
                writer.writeAll(arrow) catch {};
                writer.writeAll(">") catch {};
            } else if (has_cursor and !is_active) {
                writer.writeAll("<Age> ") catch {};
            } else if (!has_cursor and is_active) {
                const arrow = if (order == .asc) "↑" else "↓";
                writer.writeAll(" Age") catch {};
                writer.writeAll(arrow) catch {};
                writer.writeAll(" ") catch {};
            } else {
                writer.writeAll(" Age  ") catch {};
            }
        },
        .seeders => {
            if (has_cursor and is_active) {
                const arrow = if (order == .asc) "↑" else "↓";
                writer.writeAll("<S") catch {};
                writer.writeAll(arrow) catch {};
                writer.writeAll(">") catch {};
            } else if (has_cursor and !is_active) {
                writer.writeAll("<S> ") catch {};
            } else if (!has_cursor and is_active) {
                const arrow = if (order == .asc) "↑" else "↓";
                writer.writeAll(" S") catch {};
                writer.writeAll(arrow) catch {};
                writer.writeAll(" ") catch {};
            } else {
                writer.writeAll(" S  ") catch {};
            }
        },
        .leechers => {
            if (has_cursor and is_active) {
                const arrow = if (order == .asc) "↑" else "↓";
                writer.writeAll("<L") catch {};
                writer.writeAll(arrow) catch {};
                writer.writeAll(">") catch {};
            } else if (has_cursor and !is_active) {
                writer.writeAll("<L> ") catch {};
            } else if (!has_cursor and is_active) {
                const arrow = if (order == .asc) "↑" else "↓";
                writer.writeAll(" L") catch {};
                writer.writeAll(arrow) catch {};
                writer.writeAll(" ") catch {};
            } else {
                writer.writeAll(" L  ") catch {};
            }
        },
        .size => {
            if (has_cursor and is_active) {
                const arrow = if (order == .asc) "↑" else "↓";
                writer.writeAll(" <Size") catch {};
                writer.writeAll(arrow) catch {};
                writer.writeAll("> ") catch {};
            } else if (has_cursor and !is_active) {
                writer.writeAll(" <Size>  ") catch {};
            } else if (!has_cursor and is_active) {
                const arrow = if (order == .asc) "↑" else "↓";
                writer.writeAll("  Size") catch {};
                writer.writeAll(arrow) catch {};
                writer.writeAll("  ") catch {};
            } else {
                writer.writeAll("  Size   ") catch {};
            }
        },
    }

    return writer.buffered();
}

fn writeHeaderCells(
    stdout: compat.FileWriter,
    inner_width: usize,
    layout: TableLayout,
    colors: theme.Theme,
    widget: *ResultsWidget,
) !void {
    try stdout.writeAll(" ");
    term.setFg256(colors.muted);
    try theme.writePadded(stdout, "Title", layout.title_col_width);
    try writeSpaces(stdout, layout.title_to_age_gap);

    // Age column
    var age_buf: [32]u8 = undefined;
    const age_text = formatColumnHeader(&age_buf, .age, widget.sort_column, widget.sort_order, widget.header_cursor);
    if (widget.sort_column == .age) {
        term.setFg256(colors.accent);
        term.setBold(true);
    } else if (widget.header_cursor == .age) {
        term.setFg256(colors.text);
        term.setBold(true);
    } else {
        term.setFg256(colors.muted);
    }
    try stdout.writeAll(age_text);
    term.setBold(false);

    term.setFg256(colors.muted);
    try writeSpaces(stdout, layout.age_to_seeders_gap);

    // S column
    var s_buf: [32]u8 = undefined;
    const s_text = formatColumnHeader(&s_buf, .seeders, widget.sort_column, widget.sort_order, widget.header_cursor);
    if (widget.sort_column == .seeders) {
        term.setFg256(colors.accent);
        term.setBold(true);
    } else if (widget.header_cursor == .seeders) {
        term.setFg256(colors.text);
        term.setBold(true);
    } else {
        term.setFg256(colors.muted);
    }
    try stdout.writeAll(s_text);
    term.setBold(false);

    term.setFg256(colors.muted);
    try writeSpaces(stdout, layout.between_stats_gap);

    // L column
    var l_buf: [32]u8 = undefined;
    const l_text = formatColumnHeader(&l_buf, .leechers, widget.sort_column, widget.sort_order, widget.header_cursor);
    if (widget.sort_column == .leechers) {
        term.setFg256(colors.accent);
        term.setBold(true);
    } else if (widget.header_cursor == .leechers) {
        term.setFg256(colors.text);
        term.setBold(true);
    } else {
        term.setFg256(colors.muted);
    }
    try stdout.writeAll(l_text);
    term.setBold(false);

    term.setFg256(colors.muted);
    try writeSpaces(stdout, layout.between_stats_gap);

    // Size column
    var size_buf: [32]u8 = undefined;
    const size_text = formatColumnHeader(&size_buf, .size, widget.sort_column, widget.sort_order, widget.header_cursor);
    if (widget.sort_column == .size) {
        term.setFg256(colors.accent);
        term.setBold(true);
    } else if (widget.header_cursor == .size) {
        term.setFg256(colors.text);
        term.setBold(true);
    } else {
        term.setFg256(colors.muted);
    }
    try stdout.writeAll(size_text);
    term.setBold(false);

    term.setFg256(colors.muted);
    try stdout.writeAll(" ");

    const used = 1 + layout.title_col_width + layout.title_to_age_gap + layout.age_width + layout.age_to_seeders_gap + layout.seeders_width + layout.between_stats_gap + layout.leechers_width + layout.between_stats_gap + layout.size_width + 1;
    if (used < inner_width) {
        try writeSpaces(stdout, inner_width - used);
    }
}

fn formatAgeText(buf: []u8, pub_date: ?i64, current_time: i64) []const u8 {
    const timestamp = pub_date orelse return "N/A";
    const diff = current_time - timestamp;
    const age = @max(diff, 0);

    if (age < 60) {
        return std.fmt.bufPrint(buf, "{d}s", .{age}) catch "N/A";
    } else if (age < 3600) {
        return std.fmt.bufPrint(buf, "{d}mi", .{age / 60}) catch "N/A";
    } else if (age < 86400) {
        return std.fmt.bufPrint(buf, "{d}h", .{age / 3600}) catch "N/A";
    } else if (age < 30 * 86400) {
        return std.fmt.bufPrint(buf, "{d}d", .{age / 86400}) catch "N/A";
    } else if (age < 365 * 86400) {
        return std.fmt.bufPrint(buf, "{d}mo", .{age / (30 * 86400)}) catch "N/A";
    } else {
        return std.fmt.bufPrint(buf, "{d}y", .{age / (365 * 86400)}) catch "N/A";
    }
}

fn buildDataCells(
    buf: []u8,
    inner_width: usize,
    layout: TableLayout,
    title: []const u8,
    seeders: u32,
    leechers: u32,
    size_bytes: ?u64,
    pub_date: ?i64,
    current_time: i64,
) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);

    writer.writeAll(" ") catch return "";
    theme.writePadded(&writer, title, layout.title_col_width) catch return "";
    writeSpaces(&writer, layout.title_to_age_gap) catch return "";

    var abuf: [16]u8 = undefined;
    const age_text = formatAgeText(&abuf, pub_date, current_time);
    writeRightAligned(&writer, age_text, layout.age_width) catch return "";
    writeSpaces(&writer, layout.age_to_seeders_gap) catch return "";

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
                        .{live_status.failed},
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

fn statusRowFromDisplayCount(display_count: usize) u16 {
    const row = 5 + display_count;
    return @as(u16, @intCast(row));
}

fn writeSpaces(writer: anytype, count: usize) !void {
    for (0..count) |_| try writer.writeAll(" ");
}

pub const ResultsAction = union(enum) {
    continue_browsing,
    select: usize,
    new_search,
    refresh,
    cancel,
    review_failures,
    open_list_search,
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

test "buildDataCells places stats columns at fixed layout offsets" {
    const inner_width: usize = 56;
    const layout = TableLayout.forInnerWidth(inner_width);

    const age_start = 1 + layout.title_col_width + layout.title_to_age_gap;
    const seeders_start = age_start + layout.age_width + layout.age_to_seeders_gap;
    const leechers_start = seeders_start + layout.seeders_width + layout.between_stats_gap;
    const size_start = leechers_start + layout.leechers_width + layout.between_stats_gap;

    var rbuf: [256]u8 = undefined;
    const row = buildDataCells(&rbuf, inner_width, layout, "Voyager", 7, 42, 512 * 1024 * 1024, null, 0);

    try std.testing.expectEqualStrings("   7", row[seeders_start .. seeders_start + layout.seeders_width]);
    try std.testing.expectEqualStrings("  42", row[leechers_start .. leechers_start + layout.leechers_width]);
    try std.testing.expectEqualStrings("512 MB", std.mem.trim(u8, row[size_start .. size_start + layout.size_width], " "));
}

test "buildDataCells stats columns stay at fixed offsets when title is truncated" {
    const inner_width: usize = 56;
    const layout = TableLayout.forInnerWidth(inner_width);

    const age_start = 1 + layout.title_col_width + layout.title_to_age_gap;
    const seeders_start = age_start + layout.age_width + layout.age_to_seeders_gap;
    const leechers_start = seeders_start + layout.seeders_width + layout.between_stats_gap;
    const size_start = leechers_start + layout.leechers_width + layout.between_stats_gap;

    var trunc_buf: [128]u8 = undefined;
    const long_title = "A very very very long title that must truncate";
    const shown_title = theme.truncateWithEllipsis(long_title, layout.title_col_width, trunc_buf[0..]);

    var rbuf: [256]u8 = undefined;
    const row = buildDataCells(&rbuf, inner_width, layout, shown_title, 999, 1000, 12 * 1024 * 1024 * 1024 + 410 * 1024 * 1024, null, 0);

    try std.testing.expectEqualStrings(" 999", row[seeders_start .. seeders_start + layout.seeders_width]);
    try std.testing.expectEqualStrings("1000", row[leechers_start .. leechers_start + layout.leechers_width]);
    try std.testing.expectEqualStrings("12.4 GB", std.mem.trim(u8, row[size_start .. size_start + layout.size_width], " "));
}

test "formatColumnHeader always returns the column's fixed display width" {
    const Case = struct { col: SortColumn, width: usize };
    const cases = [_]Case{
        .{ .col = .age, .width = TableLayout.fixed_age_width },
        .{ .col = .seeders, .width = TableLayout.fixed_seeders_width },
        .{ .col = .leechers, .width = TableLayout.fixed_leechers_width },
        .{ .col = .size, .width = TableLayout.fixed_size_width },
    };
    const columns = [_]SortColumn{ .age, .seeders, .leechers, .size };
    const orders = [_]SortOrder{ .asc, .desc };

    for (cases) |case| {
        for (columns) |active| {
            for (columns) |cursor| {
                for (orders) |order| {
                    var buf: [32]u8 = undefined;
                    const text = formatColumnHeader(&buf, case.col, active, order, cursor);
                    try std.testing.expectEqual(case.width, theme.displayWidthOfText(text));
                }
            }
        }
    }
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

test "ResultsWidget handleEvent arrow_down moves cursor down" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    var torrents = [_]Torrent{
        .{ .title = "Test1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "Test2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
        .{ .title = "Test3", .seeders = 3, .leechers = 0, .link = "magnet:3" },
        .{ .title = "Test4", .seeders = 4, .leechers = 0, .link = "magnet:4" },
        .{ .title = "Test5", .seeders = 5, .leechers = 0, .link = "magnet:5" },
        .{ .title = "Test6", .seeders = 6, .leechers = 0, .link = "magnet:6" },
    };
    widget.setTorrents(&torrents, 6);

    try std.testing.expectEqual(@as(usize, 0), widget.cursor);

    const event = term.Event{ .key = .arrow_down, .value = 0 };
    const action = widget.handleEvent(event, 8);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqual(@as(usize, 1), widget.cursor);
    try std.testing.expectEqual(@as(usize, 1), widget.scroll_offset);
}

test "ResultsWidget handleEvent char s returns new_search" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    const event = term.Event{ .key = .char, .value = 's' };
    const action = widget.handleEvent(event, 20);

    try std.testing.expectEqual(ResultsAction.new_search, action);
}

test "ResultsWidget handleEvent char r returns refresh only when search is done" {
    const allocator = std.testing.allocator;

    // Case 1: Empty torrents list
    {
        var widget = ResultsWidget.init(allocator);
        defer widget.deinit();

        // When search is done
        widget.live_status.phase = .done;
        const event_r = term.Event{ .key = .char, .value = 'r' };
        const action_r = widget.handleEvent(event_r, 20);
        try std.testing.expectEqual(ResultsAction.refresh, action_r);

        const event_R = term.Event{ .key = .char, .value = 'R' };
        const action_R = widget.handleEvent(event_R, 20);
        try std.testing.expectEqual(ResultsAction.refresh, action_R);

        // When search is in progress
        widget.live_status.phase = .querying;
        const action_r_prog = widget.handleEvent(event_r, 20);
        try std.testing.expectEqual(ResultsAction.continue_browsing, action_r_prog);
    }

    // Case 2: Non-empty torrents list
    {
        var widget = ResultsWidget.init(allocator);
        defer widget.deinit();

        var torrents = std.ArrayList(Torrent).empty;
        defer torrents.deinit(allocator);
        try torrents.append(allocator, .{
            .title = "Ubuntu ISO",
            .seeders = 10,
            .leechers = 2,
            .link = "magnet:?xt=urn:btih:123",
        });
        widget.setTorrents(torrents.items, torrents.items.len);

        // When search is done
        widget.live_status.phase = .done;
        const event_r = term.Event{ .key = .char, .value = 'r' };
        const action_r = widget.handleEvent(event_r, 20);
        try std.testing.expectEqual(ResultsAction.refresh, action_r);

        const event_R = term.Event{ .key = .char, .value = 'R' };
        const action_R = widget.handleEvent(event_R, 20);
        try std.testing.expectEqual(ResultsAction.refresh, action_R);

        // When search is in progress
        widget.live_status.phase = .querying;
        const action_r_prog = widget.handleEvent(event_r, 20);
        try std.testing.expectEqual(ResultsAction.continue_browsing, action_r_prog);
    }
}

test "ResultsWidget handleEvent char / returns open_list_search" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    var torrents = std.ArrayList(Torrent).empty;
    defer torrents.deinit(allocator);
    try torrents.append(allocator, .{
        .title = "Ubuntu ISO",
        .seeders = 10,
        .leechers = 2,
        .link = "magnet:?xt=urn:btih:123",
    });
    widget.setTorrents(torrents.items, torrents.items.len);

    const event = term.Event{ .key = .char, .value = '/' };
    const action = widget.handleEvent(event, 20);

    try std.testing.expectEqual(ResultsAction.open_list_search, action);
}

test "ResultsWidget list search apply, navigation and clear" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    var torrents = std.ArrayList(Torrent).empty;
    defer torrents.deinit(allocator);
    try torrents.append(allocator, .{
        .title = "Ubuntu ISO",
        .seeders = 10,
        .leechers = 2,
        .link = "magnet:?xt=urn:btih:1",
    });
    try torrents.append(allocator, .{
        .title = "Debian ISO",
        .seeders = 5,
        .leechers = 1,
        .link = "magnet:?xt=urn:btih:2",
    });
    try torrents.append(allocator, .{
        .title = "Ubuntu Netinstaller",
        .seeders = 8,
        .leechers = 3,
        .link = "magnet:?xt=urn:btih:3",
    });
    widget.setTorrents(torrents.items, torrents.items.len);

    // Apply list search for "Ubuntu"
    try widget.applyListSearch("Ubuntu");
    try std.testing.expect(widget.list_search_active);
    try std.testing.expectEqualStrings("Ubuntu", widget.list_search_query.?);

    // Since Debian is at index 1 and Ubuntu is at index 0 and 2,
    // when we sort (by default seeders desc):
    // seeders: Ubuntu ISO (10) -> Ubuntu Netinstaller (8) -> Debian ISO (5)
    // So torrents[0] is Ubuntu ISO, torrents[1] is Ubuntu Netinstaller, torrents[2] is Debian ISO.
    // Initial cursor should be at 0 (Ubuntu ISO).
    try std.testing.expectEqual(@as(usize, 0), widget.cursor);

    // Press 'n' to go to next match (index 1: Ubuntu Netinstaller)
    const next_event = term.Event{ .key = .char, .value = 'n' };
    _ = widget.handleEvent(next_event, 20);
    try std.testing.expectEqual(@as(usize, 1), widget.cursor);

    // Press 'n' again. Since Debian doesn't match, it wraps around to Ubuntu ISO (index 0)
    _ = widget.handleEvent(next_event, 20);
    try std.testing.expectEqual(@as(usize, 0), widget.cursor);

    // Press 'N' to go to previous match (index 1: Ubuntu Netinstaller)
    const prev_event = term.Event{ .key = .char, .value = 'N' };
    _ = widget.handleEvent(prev_event, 20);
    try std.testing.expectEqual(@as(usize, 1), widget.cursor);

    // Escape clears the search and continues browsing
    const esc_event = term.Event{ .key = .escape, .value = 0 };
    const esc_action = widget.handleEvent(esc_event, 20);
    try std.testing.expectEqual(ResultsAction.continue_browsing, esc_action);
    try std.testing.expect(!widget.list_search_active);
    try std.testing.expect(widget.list_search_query == null);
}

test "ResultsWidget handleEvent enter returns select with cursor" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    var torrents = [_]Torrent{
        .{ .title = "Test1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "Test2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
    };
    widget.setTorrents(&torrents, 2);
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

    var torrents = [_]Torrent{
        .{ .title = "Test1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "Test2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
    };
    widget.setTorrents(&torrents, 2);

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

test "ResultsWidget handleEvent arrow_down adjusts scroll when cursor leaves window" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    var torrents = [_]Torrent{
        .{ .title = "T1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "T2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
        .{ .title = "T3", .seeders = 3, .leechers = 0, .link = "magnet:3" },
        .{ .title = "T4", .seeders = 4, .leechers = 0, .link = "magnet:4" },
        .{ .title = "T5", .seeders = 5, .leechers = 0, .link = "magnet:5" },
        .{ .title = "T6", .seeders = 6, .leechers = 0, .link = "magnet:6" },
    };
    widget.setTorrents(&torrents, 6);
    // max_rows=8, display_count=1. cursor at 0 (last visible), arrow_down pushes it to 1 and scrolls.
    widget.cursor = 0;

    const event = term.Event{ .key = .arrow_down, .value = 0 };
    const action = widget.handleEvent(event, 8);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqual(@as(usize, 1), widget.cursor);
    try std.testing.expectEqual(@as(usize, 1), widget.scroll_offset);
}

test "ResultsWidget handleEvent arrow_up moves cursor up" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    var torrents = [_]Torrent{
        .{ .title = "Test1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "Test2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
        .{ .title = "Test3", .seeders = 3, .leechers = 0, .link = "magnet:3" },
        .{ .title = "Test4", .seeders = 4, .leechers = 0, .link = "magnet:4" },
        .{ .title = "Test5", .seeders = 5, .leechers = 0, .link = "magnet:5" },
        .{ .title = "Test6", .seeders = 6, .leechers = 0, .link = "magnet:6" },
    };
    widget.setTorrents(&torrents, 6);
    widget.cursor = 1;

    const event = term.Event{ .key = .arrow_up, .value = 0 };
    const action = widget.handleEvent(event, 10);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqual(@as(usize, 0), widget.cursor);
}

test "ResultsWidget handleEvent arrow_down at last torrent does nothing" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    var torrents = [_]Torrent{
        .{ .title = "Test1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "Test2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
        .{ .title = "Test3", .seeders = 3, .leechers = 0, .link = "magnet:3" },
        .{ .title = "Test4", .seeders = 4, .leechers = 0, .link = "magnet:4" },
        .{ .title = "Test5", .seeders = 5, .leechers = 0, .link = "magnet:5" },
        .{ .title = "Test6", .seeders = 6, .leechers = 0, .link = "magnet:6" },
    };
    widget.setTorrents(&torrents, 6);
    widget.cursor = 5; // last torrent

    const event = term.Event{ .key = .arrow_down, .value = 0 };
    const action = widget.handleEvent(event, 10);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqual(@as(usize, 5), widget.cursor);
}

test "ResultsWidget handleEvent arrow_up at cursor 0 does nothing" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    var torrents = [_]Torrent{
        .{ .title = "Test1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
    };
    widget.setTorrents(&torrents, 1);

    try std.testing.expectEqual(@as(usize, 0), widget.cursor);

    const event = term.Event{ .key = .arrow_up, .value = 0 };
    const action = widget.handleEvent(event, 20);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqual(@as(usize, 0), widget.cursor);
}

test "ResultsWidget handleEvent shift_arrow_down moves cursor by display_count" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    var torrents = [_]Torrent{
        .{ .title = "T1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "T2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
        .{ .title = "T3", .seeders = 3, .leechers = 0, .link = "magnet:3" },
        .{ .title = "T4", .seeders = 4, .leechers = 0, .link = "magnet:4" },
        .{ .title = "T5", .seeders = 5, .leechers = 0, .link = "magnet:5" },
        .{ .title = "T6", .seeders = 6, .leechers = 0, .link = "magnet:6" },
        .{ .title = "T7", .seeders = 7, .leechers = 0, .link = "magnet:7" },
        .{ .title = "T8", .seeders = 8, .leechers = 0, .link = "magnet:8" },
    };
    widget.setTorrents(&torrents, 8);
    // max_rows=8, display_count=1, cursor=0 -> shift_arrow_down moves cursor to 1
    const event = term.Event{ .key = .shift_arrow_down, .value = 0 };
    const action = widget.handleEvent(event, 8);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqual(@as(usize, 1), widget.cursor);
    try std.testing.expectEqual(@as(usize, 1), widget.scroll_offset);
}

test "ResultsWidget handleEvent shift_arrow_up retreats cursor by display_count" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    var torrents = [_]Torrent{
        .{ .title = "T1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "T2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
        .{ .title = "T3", .seeders = 3, .leechers = 0, .link = "magnet:3" },
        .{ .title = "T4", .seeders = 4, .leechers = 0, .link = "magnet:4" },
        .{ .title = "T5", .seeders = 5, .leechers = 0, .link = "magnet:5" },
        .{ .title = "T6", .seeders = 6, .leechers = 0, .link = "magnet:6" },
        .{ .title = "T7", .seeders = 7, .leechers = 0, .link = "magnet:7" },
        .{ .title = "T8", .seeders = 8, .leechers = 0, .link = "magnet:8" },
    };
    widget.setTorrents(&torrents, 8);
    widget.cursor = 1;
    widget.scroll_offset = 0;
    // max_rows=8, display_count=1, cursor=1 -> shift_arrow_up moves cursor to 0
    const event = term.Event{ .key = .shift_arrow_up, .value = 0 };
    const action = widget.handleEvent(event, 8);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqual(@as(usize, 0), widget.cursor);
    try std.testing.expectEqual(@as(usize, 0), widget.scroll_offset);
}

test "ResultsWidget handleEvent shift_arrow_down at last torrent does nothing" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    var torrents = [_]Torrent{
        .{ .title = "T1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "T2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
        .{ .title = "T3", .seeders = 3, .leechers = 0, .link = "magnet:3" },
        .{ .title = "T4", .seeders = 4, .leechers = 0, .link = "magnet:4" },
        .{ .title = "T5", .seeders = 5, .leechers = 0, .link = "magnet:5" },
        .{ .title = "T6", .seeders = 6, .leechers = 0, .link = "magnet:6" },
        .{ .title = "T7", .seeders = 7, .leechers = 0, .link = "magnet:7" },
        .{ .title = "T8", .seeders = 8, .leechers = 0, .link = "magnet:8" },
    };
    widget.setTorrents(&torrents, 8);
    widget.cursor = 7; // last torrent
    widget.scroll_offset = 7;
    const event = term.Event{ .key = .shift_arrow_down, .value = 0 };
    const action = widget.handleEvent(event, 10);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqual(@as(usize, 7), widget.cursor);
    try std.testing.expectEqual(@as(usize, 7), widget.scroll_offset);
}

test "ResultsWidget handleEvent shift_arrow_up at cursor 0 does nothing" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    var torrents = [_]Torrent{
        .{ .title = "T1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "T2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
        .{ .title = "T3", .seeders = 3, .leechers = 0, .link = "magnet:3" },
        .{ .title = "T4", .seeders = 4, .leechers = 0, .link = "magnet:4" },
    };
    widget.setTorrents(&torrents, 4);
    // cursor starts at 0
    const event = term.Event{ .key = .shift_arrow_up, .value = 0 };
    const action = widget.handleEvent(event, 10);

    try std.testing.expectEqual(ResultsAction.continue_browsing, action);
    try std.testing.expectEqual(@as(usize, 0), widget.cursor);
    try std.testing.expectEqual(@as(usize, 0), widget.scroll_offset);
}

test "ResultsWidget handleEvent ignores j/k/J/K chars" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    var torrents = [_]Torrent{
        .{ .title = "Test1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "Test2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
    };
    widget.setTorrents(&torrents, 2);

    for ([_]u8{ 'j', 'k', 'J', 'K' }) |c| {
        const action = widget.handleEvent(.{ .key = .char, .value = c }, 20);
        try std.testing.expectEqual(ResultsAction.continue_browsing, action);
        try std.testing.expectEqual(@as(usize, 0), widget.cursor);
    }
}

test "ResultsWidget cursor resets on new search" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    var torrents1 = [_]Torrent{
        .{ .title = "Test1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "Test2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
        .{ .title = "Test3", .seeders = 3, .leechers = 0, .link = "magnet:3" },
    };
    widget.setTorrents(&torrents1, 3);
    widget.cursor = 2;
    widget.scroll_offset = 1;

    var torrents2 = [_]Torrent{
        .{ .title = "Test4", .seeders = 4, .leechers = 0, .link = "magnet:4" },
    };
    widget.setTorrents(&torrents2, 1);

    try std.testing.expectEqual(@as(usize, 0), widget.cursor);
    try std.testing.expectEqual(@as(usize, 0), widget.scroll_offset);
}

test "ResultsWidget send state persists and resets on new results" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    var torrents1 = [_]Torrent{
        .{ .title = "Test1", .seeders = 1, .leechers = 0, .link = "magnet:1" },
        .{ .title = "Test2", .seeders = 2, .leechers = 0, .link = "magnet:2" },
    };
    widget.setTorrents(&torrents1, 2);
    widget.setSendState(1, .success);

    try std.testing.expectEqual(ResultsWidget.SendState.success, widget.getSendState(1));

    var torrents2 = [_]Torrent{
        .{ .title = "Test3", .seeders = 3, .leechers = 0, .link = "magnet:3" },
    };
    widget.setTorrents(&torrents2, 1);

    try std.testing.expectEqual(ResultsWidget.SendState.none, widget.getSendState(0));
}

test "ResultsWidget updateTorrents preserves cursor and send state by link" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    var torrents1 = [_]Torrent{
        .{ .title = "Selected", .seeders = 5, .leechers = 0, .link = "magnet:selected" },
        .{ .title = "Low", .seeders = 1, .leechers = 0, .link = "magnet:low" },
    };
    widget.setTorrents(&torrents1, 2);
    widget.cursor = 0;
    widget.setSendState(0, .success);

    var torrents2 = [_]Torrent{
        .{ .title = "New High", .seeders = 50, .leechers = 0, .link = "magnet:new" },
        .{ .title = "Selected", .seeders = 5, .leechers = 0, .link = "magnet:selected" },
        .{ .title = "Low", .seeders = 1, .leechers = 0, .link = "magnet:low" },
    };
    const previous_cursor_link = if (widget.cursor < widget.torrents.len) widget.torrents[widget.cursor].link else null;
    widget.updateTorrents(&torrents2, 3, previous_cursor_link);

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

test "advanceMarquee does not animate when title fits" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    var torrents = [_]Torrent{
        .{ .title = "Short", .seeders = 1, .leechers = 0, .link = "magnet:1" },
    };
    widget.setTorrents(&torrents, 1);
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

test "ResultsWidget sorting header cursor movement" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    try std.testing.expectEqual(SortColumn.seeders, widget.header_cursor);

    // Press left -> goes to age
    _ = widget.handleEvent(.{ .key = .arrow_left, .value = 0 }, 10);
    try std.testing.expectEqual(SortColumn.age, widget.header_cursor);

    // Press left at boundary -> stays age
    _ = widget.handleEvent(.{ .key = .arrow_left, .value = 0 }, 10);
    try std.testing.expectEqual(SortColumn.age, widget.header_cursor);

    // Press right -> goes to seeders
    _ = widget.handleEvent(.{ .key = .arrow_right, .value = 0 }, 10);
    try std.testing.expectEqual(SortColumn.seeders, widget.header_cursor);

    // Press right -> goes to leechers
    _ = widget.handleEvent(.{ .key = .arrow_right, .value = 0 }, 10);
    try std.testing.expectEqual(SortColumn.leechers, widget.header_cursor);

    // Press right -> goes to size
    _ = widget.handleEvent(.{ .key = .arrow_right, .value = 0 }, 10);
    try std.testing.expectEqual(SortColumn.size, widget.header_cursor);

    // Press right at boundary -> stays size (no wrap)
    _ = widget.handleEvent(.{ .key = .arrow_right, .value = 0 }, 10);
    try std.testing.expectEqual(SortColumn.size, widget.header_cursor);

    // Press left -> goes to leechers
    _ = widget.handleEvent(.{ .key = .arrow_left, .value = 0 }, 10);
    try std.testing.expectEqual(SortColumn.leechers, widget.header_cursor);

    // Press left -> goes to seeders
    _ = widget.handleEvent(.{ .key = .arrow_left, .value = 0 }, 10);
    try std.testing.expectEqual(SortColumn.seeders, widget.header_cursor);
}

test "ResultsWidget TAB key triggers sorting and toggles order" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    var torrents = [_]Torrent{
        .{ .title = "Test Low", .seeders = 1, .leechers = 10, .size_bytes = 100, .pub_date = 1000, .link = "magnet:low" },
        .{ .title = "Test Mid", .seeders = 5, .leechers = 2, .size_bytes = 500, .pub_date = 5000, .link = "magnet:mid" },
        .{ .title = "Test High", .seeders = 10, .leechers = 5, .size_bytes = 1000, .pub_date = 10000, .link = "magnet:high" },
    };
    widget.setTorrents(&torrents, 3);

    // By default, sorted by seeders descending: High, Mid, Low
    try std.testing.expectEqualStrings("Test High", widget.torrents[0].title);
    try std.testing.expectEqualStrings("Test Mid", widget.torrents[1].title);
    try std.testing.expectEqualStrings("Test Low", widget.torrents[2].title);

    // Move cursor to Age (left once) and sort (TAB) -> sorts by age ascending (older first)
    _ = widget.handleEvent(.{ .key = .arrow_left, .value = 0 }, 10); // cursor at age
    _ = widget.handleEvent(.{ .key = .tab, .value = 0 }, 10);
    try std.testing.expectEqual(SortColumn.age, widget.sort_column);
    try std.testing.expectEqual(SortOrder.asc, widget.sort_order);

    // Age ascending (older first): Low (1000), Mid (5000), High (10000)
    try std.testing.expectEqualStrings("Test Low", widget.torrents[0].title);
    try std.testing.expectEqualStrings("Test Mid", widget.torrents[1].title);
    try std.testing.expectEqualStrings("Test High", widget.torrents[2].title);

    // TAB again on same column -> toggles to descending (newer first)
    _ = widget.handleEvent(.{ .key = .tab, .value = 0 }, 10);
    try std.testing.expectEqual(SortOrder.desc, widget.sort_order);

    // Age descending (newer first): High (10000), Mid (5000), Low (1000)
    try std.testing.expectEqualStrings("Test High", widget.torrents[0].title);
    try std.testing.expectEqualStrings("Test Mid", widget.torrents[1].title);
    try std.testing.expectEqualStrings("Test Low", widget.torrents[2].title);

    // Move cursor to Leechers (right twice: age -> seeders -> leechers) and sort (TAB)
    _ = widget.handleEvent(.{ .key = .arrow_right, .value = 0 }, 10); // cursor at seeders
    _ = widget.handleEvent(.{ .key = .arrow_right, .value = 0 }, 10); // cursor at leechers
    _ = widget.handleEvent(.{ .key = .tab, .value = 0 }, 10); // TAB -> sorts by leechers ascending
    try std.testing.expectEqual(SortColumn.leechers, widget.sort_column);
    try std.testing.expectEqual(SortOrder.asc, widget.sort_order);

    // Leechers ascending: Mid (2), High (5), Low (10)
    try std.testing.expectEqualStrings("Test Mid", widget.torrents[0].title);
    try std.testing.expectEqualStrings("Test High", widget.torrents[1].title);
    try std.testing.expectEqualStrings("Test Low", widget.torrents[2].title);

    // TAB again on same column -> toggles to descending
    _ = widget.handleEvent(.{ .key = .tab, .value = 0 }, 10);
    try std.testing.expectEqual(SortOrder.desc, widget.sort_order);

    // Leechers descending: Low (10), High (5), Mid (2)
    try std.testing.expectEqualStrings("Test Low", widget.torrents[0].title);
    try std.testing.expectEqualStrings("Test High", widget.torrents[1].title);
    try std.testing.expectEqualStrings("Test Mid", widget.torrents[2].title);

    // Move to Size (right once) and sort (TAB) -> sorts by size ascending
    _ = widget.handleEvent(.{ .key = .arrow_right, .value = 0 }, 10); // cursor at size
    _ = widget.handleEvent(.{ .key = .tab, .value = 0 }, 10);
    try std.testing.expectEqual(SortColumn.size, widget.sort_column);
    try std.testing.expectEqual(SortOrder.asc, widget.sort_order);

    // Size ascending: Low (100), Mid (500), High (1000)
    try std.testing.expectEqualStrings("Test Low", widget.torrents[0].title);
    try std.testing.expectEqualStrings("Test Mid", widget.torrents[1].title);
    try std.testing.expectEqualStrings("Test High", widget.torrents[2].title);
}

test "ResultsWidget TAB resets selection cursor" {
    const allocator = std.testing.allocator;
    var widget = ResultsWidget.init(allocator);
    defer widget.deinit();

    var torrents = [_]Torrent{
        .{ .title = "Low", .seeders = 1, .leechers = 10, .size_bytes = 100, .link = "magnet:low" },
        .{ .title = "Mid", .seeders = 5, .leechers = 2, .size_bytes = 500, .link = "magnet:mid" },
        .{ .title = "High", .seeders = 10, .leechers = 5, .size_bytes = 1000, .link = "magnet:high" },
    };
    widget.setTorrents(&torrents, 3); // Defaults sorted: High (0), Mid (1), Low (2)

    // Select "Mid" (at index 1)
    widget.cursor = 1;
    widget.scroll_offset = 1;

    // Move cursor to Size and sort (TAB)
    _ = widget.handleEvent(.{ .key = .arrow_right, .value = 0 }, 10); // cursor to leechers
    _ = widget.handleEvent(.{ .key = .arrow_right, .value = 0 }, 10); // cursor to size
    _ = widget.handleEvent(.{ .key = .tab, .value = 0 }, 10); // sorts ascending: Low (0), Mid (1), High (2)

    // Cursor and scroll should reset to 0!
    try std.testing.expectEqual(@as(usize, 0), widget.cursor);
    try std.testing.expectEqual(@as(usize, 0), widget.scroll_offset);

    // Select index 2
    widget.cursor = 2;

    // Toggle sort order by tabbing again on Size -> sorts descending: High (0), Mid (1), Low (2)
    _ = widget.handleEvent(.{ .key = .tab, .value = 0 }, 10);

    // Cursor should reset to 0!
    try std.testing.expectEqual(@as(usize, 0), widget.cursor);
}
