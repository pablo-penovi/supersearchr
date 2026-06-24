const std = @import("std");
const term = @import("term");
const theme = @import("theme");
const compat = @import("compat");
const list_nav = @import("list_nav");

/// Scrollable list of saved tracker profiles. Used by the F2 "Load Tracker
/// Profile" screen. Mirrors the structure of `indexers.zig` (panel frame +
/// header + content rows + status + footer) but without toggles or marquee.
pub const ProfilesWidget = struct {
    allocator: std.mem.Allocator,
    rows: []Row,
    scroll_offset: usize,
    cursor: usize,
    display_count: usize,
    has_drawn_once: bool,
    force_full_redraw: bool,
    last_snapshot: ?RenderSnapshot,

    pub const SourceRow = struct {
        name: []const u8,
        count: usize,
        active: bool = false,
    };

    pub const Row = struct {
        name: []u8,
        count: usize,
        active: bool,

        fn deinit(self: *Row, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            self.* = undefined;
        }
    };

    pub const ProfilesAction = union(enum) {
        continue_browsing,
        load: usize,
        delete: usize,
        close,
    };

    pub fn init(allocator: std.mem.Allocator) ProfilesWidget {
        return .{
            .allocator = allocator,
            .rows = &.{},
            .scroll_offset = 0,
            .cursor = 0,
            .display_count = 0,
            .has_drawn_once = false,
            .force_full_redraw = true,
            .last_snapshot = null,
        };
    }

    pub fn deinit(self: *ProfilesWidget) void {
        self.freeRows();
    }

    fn freeRows(self: *ProfilesWidget) void {
        for (self.rows) |*row| row.deinit(self.allocator);
        if (self.rows.len != 0) self.allocator.free(self.rows);
        self.rows = &.{};
    }

    pub fn setProfiles(self: *ProfilesWidget, infos: []const SourceRow) !void {
        var new_rows: std.ArrayList(Row) = .empty;
        errdefer {
            for (new_rows.items) |*row| row.deinit(self.allocator);
            new_rows.deinit(self.allocator);
        }
        for (infos) |info| {
            const row: Row = .{
                .name = try self.allocator.dupe(u8, info.name),
                .count = info.count,
                .active = info.active,
            };
            try new_rows.append(self.allocator, row);
        }

        self.freeRows();
        self.rows = try new_rows.toOwnedSlice(self.allocator);
        if (self.cursor >= self.rows.len) self.cursor = if (self.rows.len == 0) 0 else self.rows.len - 1;
        list_nav.adjustScroll(self.cursor, &self.scroll_offset, self.display_count);
        self.force_full_redraw = true;
    }

    pub fn handleEvent(self: *ProfilesWidget, event: term.Event) ProfilesAction {
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
            .enter => {
                if (self.rows.len == 0) return .close;
                return .{ .load = self.cursor };
            },
            .delete => {
                if (self.rows.len == 0) return .close;
                return .{ .delete = self.cursor };
            },
            .escape => return .close,
            else => return .continue_browsing,
        }
    }

    pub fn render(self: *ProfilesWidget, max_rows: u16, max_cols: u16) void {
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
            false,
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
                    stdout.writeAll("  \xe2\x86\x91\xe2\x86\x93 move | shift+\xe2\x86\x91\xe2\x86\x93 page | ENTER load | Del delete | ESC back") catch {};
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
        self.last_snapshot = snapshot;
    }
};

const RenderSnapshot = list_nav.BaseSnapshot;

const TableLayout = struct {
    name_col_width: usize,
    count_col_width: usize,
    column_gap: usize,

    const fixed_count_width: usize = 10;
    const fixed_gap: usize = 2;
    const fixed_left_padding: usize = 1;
    const fixed_right_padding: usize = 1;

    fn forInnerWidth(inner_width: usize) TableLayout {
        const fixed_suffix = fixed_left_padding + fixed_gap + fixed_count_width + fixed_right_padding;
        const name_width = if (inner_width > fixed_suffix) inner_width - fixed_suffix else 1;
        return .{
            .name_col_width = name_width,
            .count_col_width = fixed_count_width,
            .column_gap = fixed_gap,
        };
    }

    fn compactFallback() TableLayout {
        return .{
            .name_col_width = 0,
            .count_col_width = fixed_count_width,
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
    try theme.writePadded(stdout, "Profile", layout.name_col_width);
    try writeSpaces(stdout, layout.column_gap);
    try theme.writePadded(stdout, "Trackers", layout.count_col_width);
    try stdout.writeAll(" ");

    const used = 1 + layout.name_col_width + layout.column_gap + layout.count_col_width + 1;
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

fn drawContentRow(
    stdout: compat.FileWriter,
    panel_width: usize,
    inner_width: usize,
    layout: TableLayout,
    border: theme.BorderChars,
    colors: theme.Theme,
    widget: *ProfilesWidget,
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
    const content = buildDataCells(&cell_buf, inner_width, layout, row.name, row.count, row.active);

    const is_selected = abs_idx == selected_idx;
    if (is_selected) {
        term.setBg256(colors.selected_bg);
        term.setFg256(colors.selected_fg);
        term.setBold(true);
        try theme.writePadded(stdout, content, inner_width);
        term.resetColor();
        term.setBold(false);
    } else {
        term.setFg256(colors.text);
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
    trackers: usize,
    active: bool,
) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);

    writer.writeAll(" ") catch return "";

    var name_buf: [512]u8 = undefined;
    var label_buf: [544]u8 = undefined;
    const label = if (active)
        std.fmt.bufPrint(&label_buf, "{s} *", .{name}) catch name
    else
        name;
    const truncated_name = theme.truncateWithEllipsis(label, layout.name_col_width, &name_buf);
    theme.writePadded(&writer, truncated_name, layout.name_col_width) catch return "";
    writeSpaces(&writer, layout.column_gap) catch return "";

    var count_buf: [32]u8 = undefined;
    const count_text = std.fmt.bufPrint(&count_buf, "{d}", .{trackers}) catch "?";
    theme.writePadded(&writer, count_text, layout.count_col_width) catch return "";
    writer.writeAll(" ") catch return "";

    const used = writer.buffered().len;
    if (used < inner_width) {
        writeSpaces(&writer, inner_width - used) catch {};
    }
    return writer.buffered();
}

fn drawStatusRow(
    stdout: compat.FileWriter,
    panel_width: usize,
    border: theme.BorderChars,
    colors: theme.Theme,
    self: *ProfilesWidget,
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
    if (total_count == 0) return "No profiles saved";
    return std.fmt.bufPrint(buf, "Showing {d}-{d} of {d}", .{ scroll_offset + 1, end_idx, total_count }) catch "Showing";
}

fn drawCompact(
    stdout: compat.FileWriter,
    colors: theme.Theme,
    border: theme.BorderChars,
    self: *ProfilesWidget,
    max_cols: u16,
) void {
    term.moveCursor(1, 1);
    term.setFg256(colors.panel_title);
    term.setBold(true);
    stdout.writeAll("Load Tracker Profile\r\n") catch {};
    term.setBold(false);
    drawCompactDivider(stdout, colors, border, max_cols);

    if (self.rows.len == 0) {
        term.setFg256(colors.text);
        stdout.writeAll("No profiles saved\r\n") catch {};
    } else {
        const row = self.rows[self.cursor];
        term.setFg256(colors.text);
        stdout.writeAll("> ") catch {};
        var trunc_buf: [512]u8 = undefined;
        const shown = theme.truncateWithEllipsis(row.name, compactNameWidth(max_cols), trunc_buf[0..]);
        stdout.writeAll(shown) catch {};
        var count_buf: [48]u8 = undefined;
        const count_line = std.fmt.bufPrint(&count_buf, " ({d} trackers)\r\n", .{row.count}) catch "\r\n";
        stdout.writeAll(count_line) catch {};
        term.setFg256(colors.panel_title);
        var status_buf: [128]u8 = undefined;
        const status = formatStatusText(&status_buf, self.scroll_offset, @min(self.scroll_offset + self.display_count, self.rows.len), self.rows.len);
        stdout.writeAll(status) catch {};
        stdout.writeAll("\r\n") catch {};
    }

    drawCompactDivider(stdout, colors, border, max_cols);
    term.setFg256(colors.muted);
    stdout.writeAll("ENTER load | Del delete | ESC back") catch {};
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

fn testSources() []const ProfilesWidget.SourceRow {
    return &.{
        .{ .name = "Anime", .count = 2, .active = true },
        .{ .name = "Movies", .count = 5 },
        .{ .name = "Books", .count = 1 },
    };
}

test "setProfiles preserves insertion order and counts" {
    var widget = ProfilesWidget.init(std.testing.allocator);
    defer widget.deinit();

    try widget.setProfiles(testSources());
    try std.testing.expectEqual(@as(usize, 3), widget.rows.len);
    try std.testing.expectEqualStrings("Anime", widget.rows[0].name);
    try std.testing.expect(widget.rows[0].active);
    try std.testing.expectEqual(@as(usize, 5), widget.rows[1].count);
    try std.testing.expectEqualStrings("Books", widget.rows[2].name);
}

test "setProfiles clamps cursor when list shrinks" {
    var widget = ProfilesWidget.init(std.testing.allocator);
    defer widget.deinit();

    try widget.setProfiles(testSources());
    widget.cursor = 2;
    try widget.setProfiles(testSources()[0..1]);
    try std.testing.expectEqual(@as(usize, 0), widget.cursor);
}

test "handleEvent navigation moves cursor" {
    var widget = ProfilesWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setProfiles(testSources());
    widget.display_count = 2;

    _ = widget.handleEvent(.{ .key = .arrow_down, .value = 0 });
    try std.testing.expectEqual(@as(usize, 1), widget.cursor);
    _ = widget.handleEvent(.{ .key = .arrow_up, .value = 0 });
    try std.testing.expectEqual(@as(usize, 0), widget.cursor);
}

test "handleEvent Enter returns load with cursor index" {
    var widget = ProfilesWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setProfiles(testSources());
    widget.cursor = 1;

    const action = widget.handleEvent(.{ .key = .enter, .value = 0 });
    switch (action) {
        .load => |idx| try std.testing.expectEqual(@as(usize, 1), idx),
        else => return error.UnexpectedAction,
    }
}

test "handleEvent Delete returns delete with cursor index" {
    var widget = ProfilesWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setProfiles(testSources());
    widget.cursor = 2;

    const action = widget.handleEvent(.{ .key = .delete, .value = 0 });
    switch (action) {
        .delete => |idx| try std.testing.expectEqual(@as(usize, 2), idx),
        else => return error.UnexpectedAction,
    }
}

test "handleEvent Escape closes" {
    var widget = ProfilesWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setProfiles(testSources());

    try std.testing.expectEqual(ProfilesWidget.ProfilesAction.close, widget.handleEvent(.{ .key = .escape, .value = 0 }));
}

test "handleEvent Enter on empty list closes" {
    var widget = ProfilesWidget.init(std.testing.allocator);
    defer widget.deinit();

    try std.testing.expectEqual(ProfilesWidget.ProfilesAction.close, widget.handleEvent(.{ .key = .enter, .value = 0 }));
}
