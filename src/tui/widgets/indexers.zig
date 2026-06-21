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

    pub const SourceRow = struct {
        id: []const u8,
        name: []const u8,
        configured: bool,
    };

    pub const Row = struct {
        id: []u8,
        name: []u8,
        saved_active: bool,
        pending_active: ?bool,
        save_state: enum { none, failed } = .none,

        fn deinit(self: *Row, allocator: std.mem.Allocator) void {
            allocator.free(self.id);
            allocator.free(self.name);
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
        };
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
            try new_rows.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, info.id),
                .name = try self.allocator.dupe(u8, info.name),
                .saved_active = info.configured,
                .pending_active = null,
                .save_state = .none,
            });
        }

        self.freeRows();
        self.rows = try new_rows.toOwnedSlice(self.allocator);
        self.cursor = 0;
        self.scroll_offset = 0;
        self.force_full_redraw = true;
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
        self.force_full_redraw = true;
    }

    pub fn markSaved(self: *IndexersWidget, idx: usize) void {
        self.rows[idx].saved_active = self.rows[idx].pending_active.?;
        self.rows[idx].pending_active = null;
        self.rows[idx].save_state = .none;
        self.force_full_redraw = true;
    }

    pub fn markFailed(self: *IndexersWidget, idx: usize) void {
        self.rows[idx].save_state = .failed;
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
        self.force_selected_redraw = true;
    }

    pub fn handleEvent(self: *IndexersWidget, event: term.Event) IndexersAction {
        switch (event.key) {
            .arrow_down => {
                if (list_nav.moveDown(&self.cursor, self.rows.len)) {
                    list_nav.adjustScroll(self.cursor, &self.scroll_offset, self.display_count);
                }
                return .continue_browsing;
            },
            .arrow_up => {
                if (list_nav.moveUp(&self.cursor)) {
                    list_nav.adjustScroll(self.cursor, &self.scroll_offset, self.display_count);
                }
                return .continue_browsing;
            },
            .shift_arrow_down => {
                _ = list_nav.movePageDown(&self.cursor, self.rows.len, self.display_count);
                list_nav.adjustScroll(self.cursor, &self.scroll_offset, self.display_count);
                return .continue_browsing;
            },
            .shift_arrow_up => {
                _ = list_nav.movePageUp(&self.cursor, self.display_count);
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
                    if (self.hasPendingChanges()) {
                        stdout.writeAll("  \xe2\x86\x91\xe2\x86\x93 move | shift+\xe2\x86\x91\xe2\x86\x93 page | SPACE toggle | ENTER save | ESC revert") catch {};
                    } else {
                        stdout.writeAll("  \xe2\x86\x91\xe2\x86\x93 move | shift+\xe2\x86\x91\xe2\x86\x93 page | SPACE toggle | ESC back") catch {};
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

const RenderSnapshot = list_nav.BaseSnapshot;

const TableLayout = struct {
    name_col_width: usize,
    active_col_width: usize,
    name_to_active_gap: usize,

    const fixed_active_width: usize = 8;
    const fixed_gap: usize = 2;
    const fixed_left_padding: usize = 1;
    const fixed_right_padding: usize = 1;

    fn forInnerWidth(inner_width: usize) TableLayout {
        const fixed_suffix = fixed_left_padding + fixed_gap + fixed_active_width + fixed_right_padding;
        const name_width = if (inner_width > fixed_suffix) inner_width - fixed_suffix else 1;
        return .{
            .name_col_width = name_width,
            .active_col_width = fixed_active_width,
            .name_to_active_gap = fixed_gap,
        };
    }

    fn compactFallback() TableLayout {
        return .{
            .name_col_width = 0,
            .active_col_width = fixed_active_width,
            .name_to_active_gap = fixed_gap,
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
    try writeSpaces(stdout, layout.name_to_active_gap);
    try theme.writePadded(stdout, "Active", layout.active_col_width);
    try stdout.writeAll(" ");

    const used = 1 + layout.name_col_width + layout.name_to_active_gap + layout.active_col_width + 1;
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
    const active = row.pending_active orelse row.saved_active;
    const content = buildDataCells(&cell_buf, inner_width, layout, row.name, active);

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

fn buildDataCells(
    buf: []u8,
    inner_width: usize,
    layout: TableLayout,
    name: []const u8,
    active: bool,
) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);

    writer.writeAll(" ") catch return "";
    var name_buf: [512]u8 = undefined;
    const truncated_name = theme.truncateWithEllipsis(name, layout.name_col_width, &name_buf);
    theme.writePadded(&writer, truncated_name, layout.name_col_width) catch return "";
    writeSpaces(&writer, layout.name_to_active_gap) catch return "";

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
    const status = formatStatusText(&status_buf, self.scroll_offset, end_idx, self.rows.len);
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

fn formatStatusText(buf: []u8, scroll_offset: usize, end_idx: usize, total_count: usize) []const u8 {
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
        term.setFg256(colors.panel_title);
        var status_buf: [128]u8 = undefined;
        const status = formatStatusText(&status_buf, self.scroll_offset, @min(self.scroll_offset + self.display_count, self.rows.len), self.rows.len);
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

test "setIndexers populates rows from configured state" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();

    try widget.setIndexers(testSources());

    try std.testing.expectEqual(@as(usize, 3), widget.rows.len);
    try std.testing.expectEqualStrings("1337x", widget.rows[0].id);
    try std.testing.expectEqualStrings("1337x", widget.rows[0].name);
    try std.testing.expect(widget.rows[0].saved_active);
    try std.testing.expect(widget.rows[0].pending_active == null);
    try std.testing.expectEqualStrings("The Pirate Bay", widget.rows[1].name);
    try std.testing.expect(!widget.rows[1].saved_active);
    try std.testing.expectEqual(@as(usize, 0), widget.cursor);
    try std.testing.expectEqual(@as(usize, 0), widget.scroll_offset);
}

test "toggleCursorRow sets pending to opposite of saved, toggling back clears pending" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setIndexers(testSources());

    widget.toggleCursorRow();
    try std.testing.expect(widget.rows[0].pending_active != null);
    try std.testing.expect(!widget.rows[0].pending_active.?);

    widget.toggleCursorRow();
    try std.testing.expect(widget.rows[0].pending_active == null);
}

test "handleEvent Space toggles only the cursor row" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setIndexers(testSources());
    widget.cursor = 1;

    const action = widget.handleEvent(.{ .key = .char, .value = ' ' });
    try std.testing.expectEqual(IndexersWidget.IndexersAction.continue_browsing, action);
    try std.testing.expect(widget.rows[1].pending_active != null);
    try std.testing.expect(widget.rows[0].pending_active == null);
    try std.testing.expect(widget.rows[2].pending_active == null);
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

    widget.toggleCursorRow();
    widget.markSaved(0);

    try std.testing.expect(!widget.rows[0].saved_active);
    try std.testing.expect(widget.rows[0].pending_active == null);
    try std.testing.expect(widget.rows[0].save_state == .none);
}

test "markFailed sets save_state and leaves pending_active untouched for retry" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setIndexers(testSources());

    widget.toggleCursorRow();
    widget.markFailed(0);

    try std.testing.expect(widget.rows[0].save_state == .failed);
    try std.testing.expect(widget.rows[0].pending_active != null);
}

test "revertPending clears all pending changes and failure markers" {
    var widget = IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setIndexers(testSources());

    widget.cursor = 0;
    widget.toggleCursorRow();
    widget.cursor = 1;
    widget.toggleCursorRow();
    widget.rows[1].save_state = .failed;

    widget.revertPending();

    for (widget.rows) |row| {
        try std.testing.expect(row.pending_active == null);
        try std.testing.expect(row.save_state == .none);
    }
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
