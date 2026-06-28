const std = @import("std");
const term = @import("term");
const theme = @import("theme");
const compat = @import("compat");
const list_nav = @import("list_nav");

pub const IndexersWidget = struct {
    allocator: std.mem.Allocator,
    rows: []Row,
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
    marquee_categories_col_width: usize,
    commit_progress: ?CommitProgress,

    const marquee_edge_hold_ticks: u8 = 2;

    /// Live progress of an in-flight commit, shown in the footer in place of
    /// the key hints. `null` when no commit is running.
    pub const CommitProgress = struct {
        completed: usize,
        total: usize,
        failed: usize,
        spinner_frame: usize,
        /// True once ESC has been pressed: the worker finishes the in-flight
        /// tracker then stops. Drives the "Finishing current…" footer hint.
        canceling: bool = false,
    };

    pub const SourceRow = struct {
        id: []const u8,
        name: []const u8,
        configured: bool,
        categories: []const u8 = "",
        // Transient 0/1 outcome bytes, oldest-first, length 0-5. Not owned.
        record: []const u8 = &.{},
        // Last commit outcome: true = succeeded, false = failed, null = unknown.
        last_status: ?bool = null,
    };

    pub const Row = struct {
        id: []u8,
        name: []u8,
        categories: []u8,
        saved_active: bool,
        pending_active: ?bool,
        save_state: enum { none, failed } = .none,
        record: [5]bool = undefined,
        record_len: u8 = 0,
        last_status: ?bool = null,

        fn deinit(self: *Row, allocator: std.mem.Allocator) void {
            allocator.free(self.id);
            allocator.free(self.name);
            allocator.free(self.categories);
            self.* = undefined;
        }
    };

    pub const IndexersAction = union(enum) {
        continue_browsing,
        save,
        revert,
        exit_to_previous,
    };

    pub fn init(allocator: std.mem.Allocator) IndexersWidget {
        return .{
            .allocator = allocator,
            .rows = &.{},
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
            .marquee_categories_col_width = 0,
            .commit_progress = null,
        };
    }

    /// Sets (or clears) the in-flight commit progress shown in the footer.
    /// Forces a full redraw when the displayed value changes so the spinner
    /// and counts animate.
    pub fn setCommitProgress(self: *IndexersWidget, progress: ?CommitProgress) void {
        if (std.meta.eql(self.commit_progress, progress)) return;
        self.commit_progress = progress;
        self.force_full_redraw = true;
    }

    pub fn deinit(self: *IndexersWidget) void {
        self.freeRows();
    }

    fn freeRows(self: *IndexersWidget) void {
        for (self.rows) |*row| row.deinit(self.allocator);
        if (self.rows.len != 0) self.allocator.free(self.rows);
        self.rows = &.{};
    }

    pub fn setIndexers(self: *IndexersWidget, infos: []const SourceRow) !void {
        var new_rows: std.ArrayList(Row) = .empty;
        errdefer {
            for (new_rows.items) |*row| row.deinit(self.allocator);
            new_rows.deinit(self.allocator);
        }
        for (infos) |info| {
            var row: Row = .{
                .id = try self.allocator.dupe(u8, info.id),
                .name = try self.allocator.dupe(u8, info.name),
                .categories = try self.allocator.dupe(u8, info.categories),
                .saved_active = info.configured,
                .pending_active = null,
                .save_state = .none,
                .last_status = info.last_status,
            };
            const record_len: u8 = @intCast(@min(info.record.len, row.record.len));
            for (info.record[0..record_len], 0..) |byte, i| row.record[i] = byte != 0;
            row.record_len = record_len;
            try new_rows.append(self.allocator, row);
        }

        std.mem.sort(Row, new_rows.items, {}, lessThanRow);

        self.freeRows();
        self.rows = try new_rows.toOwnedSlice(self.allocator);
        self.cursor = 0;
        self.scroll_offset = 0;
        self.force_full_redraw = true;
        self.resetMarqueeState();
    }

    pub fn hasPendingChanges(self: *const IndexersWidget) bool {
        for (self.rows) |row| {
            if (row.pending_active != null) return true;
        }
        return false;
    }

    pub fn revertPending(self: *IndexersWidget) void {
        for (self.rows) |*row| {
            row.pending_active = null;
            row.save_state = .none;
        }
        self.sortRows();
        self.force_full_redraw = true;
    }

    pub fn markSaved(self: *IndexersWidget, idx: usize) void {
        self.rows[idx].saved_active = self.rows[idx].pending_active.?;
        self.rows[idx].pending_active = null;
        self.rows[idx].save_state = .none;
        self.rows[idx].last_status = true;
        self.force_full_redraw = true;
    }

    pub fn markFailed(self: *IndexersWidget, idx: usize) void {
        self.rows[idx].save_state = .failed;
        self.rows[idx].last_status = false;
        self.force_full_redraw = true;
    }

    fn toggleCursorRow(self: *IndexersWidget) void {
        if (self.rows.len == 0) return;
        const row = &self.rows[self.cursor];
        const current_effective = row.pending_active orelse row.saved_active;
        const next = !current_effective;
        if (next == row.saved_active) {
            row.pending_active = null;
        } else {
            row.pending_active = next;
        }
        row.save_state = .none;
        self.sortRows();
        self.force_full_redraw = true;
    }

    fn sortRows(self: *IndexersWidget) void {
        std.mem.sort(Row, self.rows, {}, lessThanRow);
        self.resetMarqueeState();
    }

    pub fn handleEvent(self: *IndexersWidget, event: term.Event) IndexersAction {
        switch (event.key) {
            .arrow_down => {
                if (list_nav.moveDown(&self.cursor, self.rows.len)) {
                    list_nav.adjustScroll(self.cursor, &self.scroll_offset, self.display_count);
                    self.resetMarqueeState();
                }
                return .continue_browsing;
            },
            .arrow_up => {
                if (list_nav.moveUp(&self.cursor)) {
                    list_nav.adjustScroll(self.cursor, &self.scroll_offset, self.display_count);
                    self.resetMarqueeState();
                }
                return .continue_browsing;
            },
            .shift_arrow_down => {
                if (list_nav.movePageDown(&self.cursor, self.rows.len, self.display_count)) {
                    self.resetMarqueeState();
                }
                list_nav.adjustScroll(self.cursor, &self.scroll_offset, self.display_count);
                return .continue_browsing;
            },
            .shift_arrow_up => {
                if (list_nav.movePageUp(&self.cursor, self.display_count)) {
                    self.resetMarqueeState();
                }
                list_nav.adjustScroll(self.cursor, &self.scroll_offset, self.display_count);
                return .continue_browsing;
            },
            .char => {
                if (event.value == ' ') self.toggleCursorRow();
                return .continue_browsing;
            },
            .enter => {
                if (self.hasPendingChanges()) return .save;
                return .continue_browsing;
            },
            .escape => {
                if (self.hasPendingChanges()) return .revert;
                return .exit_to_previous;
            },
            else => return .continue_browsing,
        }
    }

    /// Navigation-only handling for use while a commit is in flight: arrow keys
    /// move the cursor/scroll, everything else (toggle/save/exit) is ignored so
    /// the user can browse but not mutate or leave mid-commit. Returns true when
    /// the view changed and should be re-rendered.
    pub fn handleNavigationOnly(self: *IndexersWidget, event: term.Event) bool {
        switch (event.key) {
            .arrow_down => {
                if (!list_nav.moveDown(&self.cursor, self.rows.len)) return false;
                list_nav.adjustScroll(self.cursor, &self.scroll_offset, self.display_count);
                self.resetMarqueeState();
                return true;
            },
            .arrow_up => {
                if (!list_nav.moveUp(&self.cursor)) return false;
                list_nav.adjustScroll(self.cursor, &self.scroll_offset, self.display_count);
                self.resetMarqueeState();
                return true;
            },
            .shift_arrow_down => {
                const moved = list_nav.movePageDown(&self.cursor, self.rows.len, self.display_count);
                if (moved) self.resetMarqueeState();
                list_nav.adjustScroll(self.cursor, &self.scroll_offset, self.display_count);
                return moved;
            },
            .shift_arrow_up => {
                const moved = list_nav.movePageUp(&self.cursor, self.display_count);
                if (moved) self.resetMarqueeState();
                list_nav.adjustScroll(self.cursor, &self.scroll_offset, self.display_count);
                return moved;
            },
            else => return false,
        }
    }

    pub fn advanceMarquee(self: *IndexersWidget, max_rows: u16, max_cols: u16) bool {
        if (self.rows.len == 0) return false;
        if (self.cursor >= self.rows.len) return false;

        const compact = theme.isCompactViewport(max_rows, max_cols);
        if (compact) return false;

        const panel_width = @as(usize, @intCast(max_cols - 2));
        const inner_width = panel_width - 2;
        const layout = TableLayout.forInnerWidth(inner_width);
        if (layout.categories_col_width == 0) return false;

        self.ensureMarqueeTarget(layout.categories_col_width);

        const categories = self.rows[self.cursor].categories;
        const categories_cols = theme.displayWidthOfText(categories);
        if (categories_cols <= layout.categories_col_width) return false;

        const overflow = categories_cols - layout.categories_col_width;
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

    fn ensureMarqueeTarget(self: *IndexersWidget, categories_col_width: usize) void {
        if (self.marquee_target_set and self.marquee_cursor == self.cursor and self.marquee_categories_col_width == categories_col_width) {
            return;
        }
        self.marquee_target_set = true;
        self.marquee_cursor = self.cursor;
        self.marquee_categories_col_width = categories_col_width;
        self.marquee_offset_cols = 0;
        self.marquee_moving_right = true;
        self.marquee_edge_hold = marquee_edge_hold_ticks;
    }

    fn resetMarqueeState(self: *IndexersWidget) void {
        self.marquee_target_set = false;
        self.marquee_offset_cols = 0;
        self.marquee_moving_right = true;
        self.marquee_edge_hold = 0;
        self.marquee_cursor = 0;
        self.marquee_categories_col_width = 0;
        self.force_selected_redraw = false;
    }

    pub fn render(self: *IndexersWidget, max_rows: u16, max_cols: u16) void {
        const stdout = compat.stdoutWriter();
        const colors = theme.superseedr_like;
        const border = theme.unicode_border;
        const compact = theme.isCompactViewport(max_rows, max_cols);
        const panel_width = if (compact) @as(usize, 0) else @as(usize, @intCast(max_cols - 2));
        const inner_width = if (compact) @as(usize, 0) else panel_width - 2;
        const layout = if (compact) TableLayout.compactFallback() else TableLayout.forInnerWidth(inner_width);
        self.display_count = list_nav.computeDisplayCount(max_rows);
        const end_idx = @min(self.scroll_offset + self.display_count, self.rows.len);

        const snapshot = RenderSnapshot{
            .rows = max_rows,
            .cols = max_cols,
            .is_compact = compact,
            .cursor = self.cursor,
            .scroll_offset = self.scroll_offset,
            .display_count = self.display_count,
            .item_count = self.rows.len,
        };
        const redraw_mode = list_nav.computeRedrawMode(
            self.has_drawn_once,
            self.force_full_redraw,
            self.force_selected_redraw,
            self.last_snapshot,
            snapshot,
            false,
            false,
        );

        switch (redraw_mode) {
            .full => {
                if (compact) {
                    drawCompact(stdout, colors, border, self, max_cols);
                } else {
                    term.moveCursor(1, 1);
                    drawPanelFrame(stdout, panel_width, inner_width, border, colors, layout);
                    drawPanelDivider(stdout, panel_width, border, colors) catch {};
                    for (0..self.display_count) |rel_idx| {
                        const abs_idx = self.scroll_offset + rel_idx;
                        drawContentRow(stdout, panel_width, inner_width, layout, border, colors, self, abs_idx, self.cursor) catch {};
                    }
                    drawPanelDivider(stdout, panel_width, border, colors) catch {};
                    drawStatusRow(stdout, panel_width, border, colors, self, end_idx) catch {};
                    writeSpaces(stdout, 1) catch {};
                    theme.drawPanelBottom(stdout, panel_width, border, colors) catch {};

                    term.setFg256(colors.muted);
                    if (self.commit_progress) |progress| {
                        if (progress.canceling) {
                            stdout.writeAll("  Finishing current tracker\xe2\x80\xa6") catch {};
                        } else {
                            stdout.writeAll("  \xe2\x86\x91\xe2\x86\x93 move | shift+\xe2\x86\x91\xe2\x86\x93 page | ESC stop after current") catch {};
                        }
                    } else if (self.hasPendingChanges()) {
                        stdout.writeAll("  \xe2\x86\x91\xe2\x86\x93 move | shift+\xe2\x86\x91\xe2\x86\x93 page | SPACE toggle | ENTER save | ESC revert | F3 save profile") catch {};
                    } else {
                        stdout.writeAll("  \xe2\x86\x91\xe2\x86\x93 move | shift+\xe2\x86\x91\xe2\x86\x93 page | SPACE toggle | ESC back | F3 save profile") catch {};
                    }
                    term.resetColor();
                    term.clearBelow();
                }
            },
            .partial_window => {
                term.moveCursor(4, 1);
                for (0..self.display_count) |rel_idx| {
                    const abs_idx = self.scroll_offset + rel_idx;
                    drawContentRow(stdout, panel_width, inner_width, layout, border, colors, self, abs_idx, self.cursor) catch {};
                }
                drawPanelDivider(stdout, panel_width, border, colors) catch {};
                drawStatusRow(stdout, panel_width, border, colors, self, end_idx) catch {};
            },
            .partial_cursor => {
                const prev = self.last_snapshot orelse snapshot;
                const prev_rel = prev.cursor -| self.scroll_offset;
                const curr_rel = self.cursor -| self.scroll_offset;

                if (prev.cursor == self.cursor) {
                    term.moveCursor(contentRowFromRelative(curr_rel), 1);
                    drawContentRow(stdout, panel_width, inner_width, layout, border, colors, self, self.cursor, self.cursor) catch {};
                } else {
                    term.moveCursor(contentRowFromRelative(prev_rel), 1);
                    drawContentRow(stdout, panel_width, inner_width, layout, border, colors, self, prev.cursor, self.cursor) catch {};

                    term.moveCursor(contentRowFromRelative(curr_rel), 1);
                    drawContentRow(stdout, panel_width, inner_width, layout, border, colors, self, self.cursor, self.cursor) catch {};
                }
            },
            .none => {},
        }

        self.has_drawn_once = true;
        self.force_full_redraw = false;
        self.force_selected_redraw = false;
        self.last_snapshot = snapshot;
    }
};

fn lessThanRow(_: void, a: IndexersWidget.Row, b: IndexersWidget.Row) bool {
    const a_active = a.pending_active orelse a.saved_active;
    const b_active = b.pending_active orelse b.saved_active;
    if (a_active != b_active) return a_active;
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

const RenderSnapshot = list_nav.BaseSnapshot;

const TableLayout = struct {
    name_col_width: usize,
    categories_col_width: usize,
    record_col_width: usize,
    last_status_col_width: usize,
    active_col_width: usize,
    column_gap: usize,

    const fixed_active_width: usize = 8;
    const fixed_record_width: usize = 8;
    // Wide enough to print the "Last Status" header without truncation.
    const fixed_last_status_width: usize = 11;
    const fixed_categories_width: usize = 33;
    const fixed_gap: usize = 2;
    const fixed_left_padding: usize = 1;
    const fixed_right_padding: usize = 1;

    fn forInnerWidth(inner_width: usize) TableLayout {
        const fixed_suffix = fixed_left_padding + fixed_gap + fixed_categories_width + fixed_gap + fixed_record_width + fixed_gap + fixed_last_status_width + fixed_gap + fixed_active_width + fixed_right_padding;
        const name_width = if (inner_width > fixed_suffix) inner_width - fixed_suffix else 1;
        return .{
            .name_col_width = name_width,
            .categories_col_width = fixed_categories_width,
            .record_col_width = fixed_record_width,
            .last_status_col_width = fixed_last_status_width,
            .active_col_width = fixed_active_width,
            .column_gap = fixed_gap,
        };
    }

    fn compactFallback() TableLayout {
        return .{
            .name_col_width = 0,
            .categories_col_width = 0,
            .record_col_width = fixed_record_width,
            .last_status_col_width = fixed_last_status_width,
            .active_col_width = fixed_active_width,
            .column_gap = fixed_gap,
        };
    }
};

fn writeSpaces(writer: anytype, count: usize) !void {
    for (0..count) |_| try writer.writeAll(" ");
}

fn contentRowFromRelative(rel_idx: usize) u16 {
    const row = 4 + rel_idx;
    return @as(u16, @intCast(row));
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
    writeHeaderCells(stdout, inner_width, layout, colors) catch {};
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.resetColor();
    stdout.writeAll("\r\n") catch {};
}

fn writeHeaderCells(
    stdout: compat.FileWriter,
    inner_width: usize,
    layout: TableLayout,
    colors: theme.Theme,
) !void {
    try stdout.writeAll(" ");
    term.setFg256(colors.muted);
    try theme.writePadded(stdout, "Indexer", layout.name_col_width);
    try writeSpaces(stdout, layout.column_gap);
    try theme.writePadded(stdout, "Categories", layout.categories_col_width);
    try writeSpaces(stdout, layout.column_gap);
    try theme.writePadded(stdout, "Record", layout.record_col_width);
    try writeSpaces(stdout, layout.column_gap);
    try theme.writePadded(stdout, "Last Status", layout.last_status_col_width);
    try writeSpaces(stdout, layout.column_gap);
    try theme.writePadded(stdout, "Active", layout.active_col_width);
    try stdout.writeAll(" ");

    const used = 1 + layout.name_col_width + layout.column_gap + layout.categories_col_width + layout.column_gap + layout.record_col_width + layout.column_gap + layout.last_status_col_width + layout.column_gap + layout.active_col_width + 1;
    if (used < inner_width) {
        try writeSpaces(stdout, inner_width - used);
    }
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

fn rowColor(colors: theme.Theme, row: IndexersWidget.Row) u8 {
    if (row.save_state == .failed) return colors.err;
    if (row.pending_active != null) return colors.warn;
    return colors.text;
}

fn selectedRowColor(colors: theme.Theme, row: IndexersWidget.Row) u8 {
    if (row.save_state == .failed) return colors.err;
    if (row.pending_active != null) return colors.warn;
    return colors.selected_fg;
}

fn drawContentRow(
    stdout: compat.FileWriter,
    panel_width: usize,
    inner_width: usize,
    layout: TableLayout,
    border: theme.BorderChars,
    colors: theme.Theme,
    widget: *IndexersWidget,
    abs_idx: usize,
    selected_idx: usize,
) !void {
    if (abs_idx >= widget.rows.len) {
        try writeSpaces(stdout, 1);
        try theme.drawPanelRow(stdout, panel_width, "", border, colors);
        return;
    }

    try writeSpaces(stdout, 1);
    term.setFg256(colors.panel_border);
    try stdout.writeAll(border.vertical);

    const row = widget.rows[abs_idx];
    var cell_buf: [768]u8 = undefined;
    var categories_trunc_buf: [512]u8 = undefined;
    var categories_marquee_buf: [768]u8 = undefined;
    const active = row.pending_active orelse row.saved_active;
    const shown_categories = if (row.categories.len == 0) "-" else row.categories;
    const categories_cell = if (abs_idx == selected_idx)
        selectedCategoriesForRender(widget, shown_categories, layout.categories_col_width, &categories_trunc_buf, &categories_marquee_buf)
    else
        theme.truncateWithEllipsis(shown_categories, layout.categories_col_width, &categories_trunc_buf);
    const content = buildDataCells(&cell_buf, inner_width, layout, row.name, categories_cell, row.record[0..row.record_len], row.last_status, active);

    const is_selected = abs_idx == selected_idx;
    if (is_selected) {
        term.setBg256(colors.selected_bg);
        term.setFg256(selectedRowColor(colors, row));
        term.setBold(true);
        try theme.writePadded(stdout, content, inner_width);
        term.resetColor();
        term.setBold(false);
    } else {
        term.setFg256(rowColor(colors, row));
        try theme.writePadded(stdout, content, inner_width);
    }

    term.setFg256(colors.panel_border);
    try stdout.writeAll(border.vertical);
    term.resetColor();
    try stdout.writeAll("\r\n");
}

fn selectedCategoriesForRender(
    widget: *IndexersWidget,
    categories: []const u8,
    categories_col_width: usize,
    trunc_buf: []u8,
    marquee_buf: []u8,
) []const u8 {
    if (categories_col_width == 0) return "";

    const categories_cols = theme.displayWidthOfText(categories);
    if (categories_cols <= categories_col_width) {
        return theme.truncateWithEllipsis(categories, categories_col_width, trunc_buf);
    }

    const overflow = categories_cols - categories_col_width;
    widget.ensureMarqueeTarget(categories_col_width);
    const offset_cols = @min(widget.marquee_offset_cols, overflow);
    return theme.sliceByDisplayColumns(categories, offset_cols, categories_col_width, marquee_buf);
}

fn buildDataCells(
    buf: []u8,
    inner_width: usize,
    layout: TableLayout,
    name: []const u8,
    categories: []const u8,
    record: []const bool,
    last_status: ?bool,
    active: bool,
) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);

    writer.writeAll(" ") catch return "";
    var name_buf: [512]u8 = undefined;
    const truncated_name = theme.truncateWithEllipsis(name, layout.name_col_width, &name_buf);
    theme.writePadded(&writer, truncated_name, layout.name_col_width) catch return "";
    writeSpaces(&writer, layout.column_gap) catch return "";

    theme.writePadded(&writer, categories, layout.categories_col_width) catch return "";
    writeSpaces(&writer, layout.column_gap) catch return "";

    // Up to 5 glyphs (3 bytes each): ✓ for success, ✗ for failure.
    var record_buf: [5 * 3]u8 = undefined;
    var record_writer: std.Io.Writer = .fixed(&record_buf);
    for (record) |ok| {
        record_writer.writeAll(if (ok) "\xe2\x9c\x93" else "\xe2\x9c\x97") catch break;
    }
    writeCenterAligned(&writer, record_writer.buffered(), layout.record_col_width) catch return "";
    writeSpaces(&writer, layout.column_gap) catch return "";

    // ✓ if the last commit succeeded, ✗ if it failed, blank if never attempted.
    const last_status_text = if (last_status) |ok| (if (ok) "\xe2\x9c\x93" else "\xe2\x9c\x97") else "";
    writeCenterAligned(&writer, last_status_text, layout.last_status_col_width) catch return "";
    writeSpaces(&writer, layout.column_gap) catch return "";

    const active_text = if (active) "\xe2\x9c\x93" else "\xe2\x9c\x97";
    writeCenterAligned(&writer, active_text, layout.active_col_width) catch return "";
    writer.writeAll(" ") catch return "";

    const used = writer.buffered().len;
    if (used < inner_width) {
        writeSpaces(&writer, inner_width - used) catch {};
    }
    return writer.buffered();
}

fn writeCenterAligned(writer: anytype, text: []const u8, width: usize) !void {
    if (width == 0) return;
    const text_width = theme.displayWidthOfText(text);
    if (text_width >= width) {
        try writer.writeAll(text);
        return;
    }
    const left_pad = (width - text_width) / 2;
    const right_pad = width - text_width - left_pad;
    try writeSpaces(writer, left_pad);
    try writer.writeAll(text);
    try writeSpaces(writer, right_pad);
}

fn drawStatusRow(
    stdout: compat.FileWriter,
    panel_width: usize,
    border: theme.BorderChars,
    colors: theme.Theme,
    self: *IndexersWidget,
    end_idx: usize,
) !void {
    var status_buf: [128]u8 = undefined;
    const status = formatStatusText(&status_buf, self.scroll_offset, end_idx, self.rows.len, self.commit_progress);
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

/// Status row text. While a commit is in flight, mirrors the results screen's
/// in-panel search-progress row ("Showing 1-12 of 80 | Committing 2/4 ⣏⡆",
/// plus a failed tally) so both screens read identically.
fn formatStatusText(
    buf: []u8,
    scroll_offset: usize,
    end_idx: usize,
    total_count: usize,
    commit_progress: ?IndexersWidget.CommitProgress,
) []const u8 {
    if (commit_progress) |progress| {
        const spinner = theme.spinnerGlyph(progress.spinner_frame);
        if (progress.failed == 0) {
            return std.fmt.bufPrint(
                buf,
                "Showing {d}-{d} of {d} | Committing {d}/{d} {s}",
                .{ scroll_offset + 1, end_idx, total_count, progress.completed, progress.total, spinner },
            ) catch "Committing";
        }
        return std.fmt.bufPrint(
            buf,
            "Showing {d}-{d} of {d} | Committing {d}/{d}, {d} failed {s}",
            .{ scroll_offset + 1, end_idx, total_count, progress.completed, progress.total, progress.failed, spinner },
        ) catch "Committing";
    }
    if (total_count == 0) return "No indexers found";
    return std.fmt.bufPrint(buf, "Showing {d}-{d} of {d}", .{ scroll_offset + 1, end_idx, total_count }) catch "Showing";
}

fn drawCompact(
    stdout: compat.FileWriter,
    colors: theme.Theme,
    border: theme.BorderChars,
    self: *IndexersWidget,
    max_cols: u16,
) void {
    term.moveCursor(1, 1);
    term.setFg256(colors.panel_title);
    term.setBold(true);
    stdout.writeAll("Indexers\r\n") catch {};
    term.setBold(false);
    drawCompactDivider(stdout, colors, border, max_cols);

    if (self.rows.len == 0) {
        term.setFg256(colors.text);
        stdout.writeAll("No indexers found\r\n") catch {};
    } else {
        const row = self.rows[self.cursor];
        const active = row.pending_active orelse row.saved_active;
        term.setFg256(rowColor(colors, row));
        stdout.writeAll("> ") catch {};
        var trunc_buf: [512]u8 = undefined;
        const shown = theme.truncateWithEllipsis(row.name, compactNameWidth(max_cols), trunc_buf[0..]);
        stdout.writeAll(shown) catch {};
        stdout.writeAll(if (active) " [active]\r\n" else " [inactive]\r\n") catch {};
        if (row.categories.len != 0) {
            term.setFg256(colors.muted);
            var cat_buf: [512]u8 = undefined;
            const shown_categories = theme.truncateWithEllipsis(row.categories, compactNameWidth(max_cols), &cat_buf);
            stdout.writeAll(shown_categories) catch {};
            stdout.writeAll("\r\n") catch {};
        }
        term.setFg256(colors.panel_title);
        var status_buf: [128]u8 = undefined;
        const status = formatStatusText(&status_buf, self.scroll_offset, @min(self.scroll_offset + self.display_count, self.rows.len), self.rows.len, self.commit_progress);
        stdout.writeAll(status) catch {};
        stdout.writeAll("\r\n") catch {};
    }

    drawCompactDivider(stdout, colors, border, max_cols);
    term.setFg256(colors.muted);
    if (self.hasPendingChanges()) {
        stdout.writeAll("SPACE toggle | ENTER save | ESC revert") catch {};
    } else {
        stdout.writeAll("SPACE toggle | ESC back") catch {};
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

fn compactNameWidth(max_cols: u16) usize {
    const cols: usize = @max(@as(usize, 1), @as(usize, @intCast(max_cols)));
    if (cols <= 12) return 1;
    return cols - 12;
}

fn testSources() []const IndexersWidget.SourceRow {
    return &.{
        .{ .id = "1337x", .name = "1337x", .configured = true },
        .{ .id = "tpb", .name = "The Pirate Bay", .configured = false },
        .{ .id = "linuxtracker", .name = "LinuxTracker", .configured = true },
    };
}

fn reorderTestSources() []const IndexersWidget.SourceRow {
    return &.{
        .{ .id = "alpha", .name = "Alpha", .configured = true },
        .{ .id = "zeta", .name = "Zeta", .configured = true },
        .{ .id = "mike", .name = "Mike", .configured = false },
    };
}

fn findRowIndex(widget: *const IndexersWidget, id: []const u8) usize {
    for (widget.rows, 0..) |row, idx| {
        if (std.mem.eql(u8, row.id, id)) return idx;
    }
    unreachable;
}

test "setIndexers sorts rows: enabled group alphabetically, then disabled group alphabetically" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();

    try widget.setIndexers(testSources());

    try std.testing.expectEqual(@as(usize, 3), widget.rows.len);
    try std.testing.expectEqualStrings("1337x", widget.rows[0].name);
    try std.testing.expect(widget.rows[0].saved_active);
    try std.testing.expect(widget.rows[0].pending_active == null);
    try std.testing.expectEqualStrings("LinuxTracker", widget.rows[1].name);
    try std.testing.expect(widget.rows[1].saved_active);
    try std.testing.expectEqualStrings("The Pirate Bay", widget.rows[2].name);
    try std.testing.expect(!widget.rows[2].saved_active);
    try std.testing.expectEqual(@as(usize, 0), widget.cursor);
    try std.testing.expectEqual(@as(usize, 0), widget.scroll_offset);
}

test "setIndexers maps record bytes into fixed Row array, clamped to 5" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();

    const sources = [_]IndexersWidget.SourceRow{
        .{ .id = "none", .name = "None", .configured = true, .record = &.{} },
        .{ .id = "few", .name = "Few", .configured = true, .record = &.{ 1, 0, 1 } },
        .{ .id = "full", .name = "Full", .configured = true, .record = &.{ 1, 1, 0, 0, 1 } },
        .{ .id = "over", .name = "Over", .configured = true, .record = &.{ 1, 0, 1, 0, 1, 0, 1 } },
    };
    try widget.setIndexers(&sources);

    const none = &widget.rows[findRowIndex(&widget, "none")];
    try std.testing.expectEqual(@as(u8, 0), none.record_len);

    const few = &widget.rows[findRowIndex(&widget, "few")];
    try std.testing.expectEqual(@as(u8, 3), few.record_len);
    try std.testing.expectEqual(true, few.record[0]);
    try std.testing.expectEqual(false, few.record[1]);
    try std.testing.expectEqual(true, few.record[2]);

    const full = &widget.rows[findRowIndex(&widget, "full")];
    try std.testing.expectEqual(@as(u8, 5), full.record_len);
    try std.testing.expectEqualSlices(bool, &.{ true, true, false, false, true }, full.record[0..full.record_len]);

    const over = &widget.rows[findRowIndex(&widget, "over")];
    try std.testing.expectEqual(@as(u8, 5), over.record_len);
}

test "formatStatusText folds commit progress into the showing row" {
    var buf: [128]u8 = undefined;

    const idle = formatStatusText(&buf, 0, 12, 80, null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "Showing 1-12 of 80") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "Committing") == null);

    const without_failed = formatStatusText(&buf, 0, 12, 80, .{ .completed = 2, .total = 4, .failed = 0, .spinner_frame = 0 });
    try std.testing.expect(std.mem.indexOf(u8, without_failed, "Showing 1-12 of 80 | Committing 2/4") != null);
    try std.testing.expect(std.mem.indexOf(u8, without_failed, "failed") == null);

    const with_failed = formatStatusText(&buf, 0, 12, 80, .{ .completed = 3, .total = 4, .failed = 1, .spinner_frame = 0 });
    try std.testing.expect(std.mem.indexOf(u8, with_failed, "Committing 3/4, 1 failed") != null);
}

test "setCommitProgress only forces a redraw when the value changes" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();
    widget.force_full_redraw = false;

    widget.setCommitProgress(.{ .completed = 1, .total = 4, .failed = 0, .spinner_frame = 0 });
    try std.testing.expect(widget.force_full_redraw);
    try std.testing.expect(widget.commit_progress != null);

    widget.force_full_redraw = false;
    widget.setCommitProgress(.{ .completed = 1, .total = 4, .failed = 0, .spinner_frame = 0 });
    try std.testing.expect(!widget.force_full_redraw);

    widget.setCommitProgress(null);
    try std.testing.expect(widget.force_full_redraw);
    try std.testing.expect(widget.commit_progress == null);
}

test "setIndexers carries last_status through, defaulting to null" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();

    const sources = [_]IndexersWidget.SourceRow{
        .{ .id = "ok", .name = "Ok", .configured = true, .last_status = true },
        .{ .id = "bad", .name = "Bad", .configured = true, .last_status = false },
        .{ .id = "unknown", .name = "Unknown", .configured = true },
    };
    try widget.setIndexers(&sources);

    try std.testing.expectEqual(@as(?bool, true), widget.rows[findRowIndex(&widget, "ok")].last_status);
    try std.testing.expectEqual(@as(?bool, false), widget.rows[findRowIndex(&widget, "bad")].last_status);
    try std.testing.expectEqual(@as(?bool, null), widget.rows[findRowIndex(&widget, "unknown")].last_status);
}

test "toggleCursorRow sets pending to opposite of saved, toggling back clears pending" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setIndexers(testSources());

    widget.cursor = findRowIndex(&widget, "1337x");
    widget.toggleCursorRow();

    const after_first = findRowIndex(&widget, "1337x");
    try std.testing.expect(widget.rows[after_first].pending_active != null);
    try std.testing.expect(!widget.rows[after_first].pending_active.?);

    widget.cursor = after_first;
    widget.toggleCursorRow();

    try std.testing.expect(widget.rows[findRowIndex(&widget, "1337x")].pending_active == null);
}

test "handleEvent Space toggles only the targeted row" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setIndexers(testSources());
    widget.cursor = findRowIndex(&widget, "tpb");

    const action = widget.handleEvent(.{ .key = .char, .value = ' ' });
    try std.testing.expectEqual(IndexersWidget.IndexersAction.continue_browsing, action);
    try std.testing.expect(widget.rows[findRowIndex(&widget, "tpb")].pending_active != null);
    try std.testing.expect(widget.rows[findRowIndex(&widget, "1337x")].pending_active == null);
    try std.testing.expect(widget.rows[findRowIndex(&widget, "linuxtracker")].pending_active == null);
}

test "toggleCursorRow inserts a newly enabled row into alphabetical order within the enabled group" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setIndexers(reorderTestSources());

    try std.testing.expectEqualStrings("Alpha", widget.rows[0].name);
    try std.testing.expectEqualStrings("Zeta", widget.rows[1].name);
    try std.testing.expectEqualStrings("Mike", widget.rows[2].name);

    widget.cursor = findRowIndex(&widget, "mike");
    widget.toggleCursorRow();

    try std.testing.expectEqualStrings("Alpha", widget.rows[0].name);
    try std.testing.expectEqualStrings("Mike", widget.rows[1].name);
    try std.testing.expectEqualStrings("Zeta", widget.rows[2].name);
    try std.testing.expect(widget.rows[1].pending_active != null);
    try std.testing.expect(widget.rows[1].pending_active.?);
}

test "toggleCursorRow moves a disabled row back into alphabetical order within the disabled group" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setIndexers(reorderTestSources());

    widget.cursor = findRowIndex(&widget, "alpha");
    widget.toggleCursorRow();

    try std.testing.expectEqualStrings("Zeta", widget.rows[0].name);
    try std.testing.expectEqualStrings("Alpha", widget.rows[1].name);
    try std.testing.expectEqualStrings("Mike", widget.rows[2].name);
    try std.testing.expect(widget.rows[1].pending_active != null);
    try std.testing.expect(!widget.rows[1].pending_active.?);
}

test "handleEvent moves cursor with arrows and shift+arrows" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setIndexers(testSources());
    widget.display_count = 2;

    _ = widget.handleEvent(.{ .key = .arrow_down, .value = 0 });
    try std.testing.expectEqual(@as(usize, 1), widget.cursor);

    _ = widget.handleEvent(.{ .key = .arrow_up, .value = 0 });
    try std.testing.expectEqual(@as(usize, 0), widget.cursor);

    _ = widget.handleEvent(.{ .key = .shift_arrow_down, .value = 0 });
    try std.testing.expectEqual(@as(usize, 2), widget.cursor);

    _ = widget.handleEvent(.{ .key = .shift_arrow_up, .value = 0 });
    try std.testing.expectEqual(@as(usize, 0), widget.cursor);
}

test "handleEvent ignores j/k/J/K chars" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setIndexers(testSources());

    for ([_]u8{ 'j', 'k', 'J', 'K' }) |c| {
        const action = widget.handleEvent(.{ .key = .char, .value = c });
        try std.testing.expectEqual(IndexersWidget.IndexersAction.continue_browsing, action);
        try std.testing.expectEqual(@as(usize, 0), widget.cursor);
    }
}

test "handleEvent Enter returns save only when there are pending changes" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setIndexers(testSources());

    try std.testing.expectEqual(IndexersWidget.IndexersAction.continue_browsing, widget.handleEvent(.{ .key = .enter, .value = 0 }));

    widget.toggleCursorRow();
    try std.testing.expectEqual(IndexersWidget.IndexersAction.save, widget.handleEvent(.{ .key = .enter, .value = 0 }));
}

test "handleEvent Escape reverts when pending, exits when not" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setIndexers(testSources());

    try std.testing.expectEqual(IndexersWidget.IndexersAction.exit_to_previous, widget.handleEvent(.{ .key = .escape, .value = 0 }));

    widget.toggleCursorRow();
    try std.testing.expectEqual(IndexersWidget.IndexersAction.revert, widget.handleEvent(.{ .key = .escape, .value = 0 }));
}

test "markSaved clears pending and updates saved_active" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setIndexers(testSources());

    widget.cursor = findRowIndex(&widget, "1337x");
    widget.toggleCursorRow();
    const idx = findRowIndex(&widget, "1337x");
    widget.markSaved(idx);

    try std.testing.expect(!widget.rows[idx].saved_active);
    try std.testing.expect(widget.rows[idx].pending_active == null);
    try std.testing.expect(widget.rows[idx].save_state == .none);
    try std.testing.expectEqual(@as(?bool, true), widget.rows[idx].last_status);
}

test "markFailed sets save_state and leaves pending_active untouched for retry" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setIndexers(testSources());

    widget.cursor = findRowIndex(&widget, "1337x");
    widget.toggleCursorRow();
    const idx = findRowIndex(&widget, "1337x");
    widget.markFailed(idx);

    try std.testing.expect(widget.rows[idx].save_state == .failed);
    try std.testing.expect(widget.rows[idx].pending_active != null);
    try std.testing.expectEqual(@as(?bool, false), widget.rows[idx].last_status);
}

test "revertPending clears all pending changes and failure markers, restoring saved-state order" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setIndexers(reorderTestSources());

    widget.cursor = findRowIndex(&widget, "mike");
    widget.toggleCursorRow();
    widget.cursor = findRowIndex(&widget, "alpha");
    widget.toggleCursorRow();
    widget.rows[findRowIndex(&widget, "mike")].save_state = .failed;

    widget.revertPending();

    for (widget.rows) |row| {
        try std.testing.expect(row.pending_active == null);
        try std.testing.expect(row.save_state == .none);
    }
    try std.testing.expectEqualStrings("Alpha", widget.rows[0].name);
    try std.testing.expectEqualStrings("Zeta", widget.rows[1].name);
    try std.testing.expectEqualStrings("Mike", widget.rows[2].name);
}

test "hasPendingChanges reflects toggled rows" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setIndexers(testSources());

    try std.testing.expect(!widget.hasPendingChanges());
    widget.toggleCursorRow();
    try std.testing.expect(widget.hasPendingChanges());
}

test "setIndexers replacing existing rows frees the old ones" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setIndexers(testSources());
    try widget.setIndexers(testSources()[0..1]);

    try std.testing.expectEqual(@as(usize, 1), widget.rows.len);
}

fn categoriesOverflowSources() []const IndexersWidget.SourceRow {
    return &.{
        .{ .id = "long", .name = "Long Categories Tracker", .configured = true, .categories = "Movies, TV, Audio, PC, Books, Console, Other, XXX, Documentary" },
        .{ .id = "short", .name = "Short Categories Tracker", .configured = true, .categories = "Movies" },
    };
}

test "advanceMarquee does not animate when categories fit the column" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setIndexers(testSources());
    widget.cursor = findRowIndex(&widget, "1337x");

    try std.testing.expectEqual(false, widget.advanceMarquee(24, 120));
    try std.testing.expectEqual(@as(usize, 0), widget.marquee_offset_cols);
}

test "advanceMarquee bounces categories offset back and forth when overflowing" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setIndexers(categoriesOverflowSources());
    widget.cursor = 0;

    var advanced = false;
    for (0..200) |_| {
        if (widget.advanceMarquee(24, 80)) advanced = true;
        if (widget.marquee_offset_cols > 0) break;
    }
    try std.testing.expect(advanced);
    try std.testing.expect(widget.marquee_offset_cols > 0);

    var saw_decrease = false;
    var previous = widget.marquee_offset_cols;
    for (0..400) |_| {
        _ = widget.advanceMarquee(24, 80);
        if (widget.marquee_offset_cols < previous) {
            saw_decrease = true;
            break;
        }
        previous = widget.marquee_offset_cols;
    }
    try std.testing.expect(saw_decrease);
}

test "moving the cursor resets the categories marquee" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setIndexers(categoriesOverflowSources());
    widget.cursor = 0;

    for (0..10) |_| _ = widget.advanceMarquee(24, 80);
    try std.testing.expect(widget.marquee_offset_cols > 0);

    _ = widget.handleEvent(.{ .key = .arrow_down, .value = 0 });
    try std.testing.expectEqual(@as(usize, 0), widget.marquee_offset_cols);
    try std.testing.expectEqual(false, widget.marquee_target_set);
}
