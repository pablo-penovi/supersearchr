const std = @import("std");
const term = @import("term");
const theme = @import("theme");
const compat = @import("compat");
const list_nav = @import("list_nav");
const hints = @import("hints");

/// Scrollable list of saved indexer profiles. Used by the F2 "Load Indexer
/// Profile" screen. Mirrors the structure of `indexers.zig` (panel frame +
/// header + content rows + status + footer) but without toggles or a column
/// marquee; only the footer hints scroll when they outgrow the terminal.
///
/// On wide enough terminals a details panel beside the list previews the
/// selected profile: its indexers and what loading it would change.
pub const ProfilesWidget = struct {
    allocator: std.mem.Allocator,
    rows: []Row,
    scroll_offset: usize,
    cursor: usize,
    display_count: usize,
    has_drawn_once: bool,
    force_full_redraw: bool,
    last_snapshot: ?RenderSnapshot,
    hints_marquee: hints.HintsMarquee,
    apply_progress: ?CommitProgress,

    /// Live progress of an in-flight profile apply, shown in the status row.
    /// `null` when no apply is running.
    pub const CommitProgress = list_nav.CommitProgress;

    /// What loading a profile would do to one indexer.
    pub const Change = enum {
        /// In the profile and already enabled.
        keep,
        /// In the profile but currently disabled.
        enable,
        /// Enabled now but not in the profile.
        disable,
        /// In the profile but no longer known to Jackett.
        missing,
    };

    pub const DetailSource = struct {
        name: []const u8,
        change: Change,
    };

    pub const SourceRow = struct {
        name: []const u8,
        count: usize,
        active: bool = false,
        /// Rows for the details panel, in display order. Not owned.
        details: []const DetailSource = &.{},
    };

    pub const Detail = struct {
        name: []u8,
        change: Change,
    };

    pub const Row = struct {
        name: []u8,
        count: usize,
        active: bool,
        details: []Detail,

        fn deinit(self: *Row, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            for (self.details) |detail| allocator.free(detail.name);
            allocator.free(self.details);
            self.* = undefined;
        }
    };

    pub const ProfilesAction = union(enum) {
        continue_browsing,
        load: usize,
        delete: usize,
        rename: usize,
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
            .hints_marquee = .{},
            .apply_progress = null,
        };
    }

    /// Sets (or clears) the in-flight apply progress shown in the status row.
    /// Forces a full redraw when the displayed value changes so the spinner
    /// and counts animate.
    pub fn setCommitProgress(self: *ProfilesWidget, progress: ?CommitProgress) void {
        if (std.meta.eql(self.apply_progress, progress)) return;
        self.apply_progress = progress;
        self.force_full_redraw = true;
    }

    /// Navigation-only handling for use while a profile is being applied:
    /// arrow keys move the cursor, everything else (load/delete/close) is
    /// ignored. Returns true when the view changed and should be re-rendered.
    pub fn handleNavigationOnly(self: *ProfilesWidget, event: term.Event) bool {
        switch (event.key) {
            .arrow_down, .arrow_up, .shift_arrow_down, .shift_arrow_up => {
                const before = self.cursor;
                _ = self.handleEvent(event);
                return self.cursor != before;
            },
            else => return false,
        }
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
            const name = try self.allocator.dupe(u8, info.name);
            errdefer self.allocator.free(name);
            const details = try cloneDetails(self.allocator, info.details);
            errdefer {
                for (details) |detail| self.allocator.free(detail.name);
                self.allocator.free(details);
            }
            try new_rows.append(self.allocator, .{
                .name = name,
                .count = info.count,
                .active = info.active,
                .details = details,
            });
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
            .char => {
                if ((event.value == 'r' or event.value == 'R') and self.rows.len != 0) {
                    return .{ .rename = self.cursor };
                }
                return .continue_browsing;
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
        self.display_count = list_nav.computeDisplayCount(max_rows);

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

        // The details panel follows the cursor, so any change repaints the
        // whole screen rather than only the rows that moved.
        if (redraw_mode != .none) {
            if (compact) {
                drawCompact(stdout, colors, border, self, max_cols);
            } else {
                drawPanels(stdout, colors, border, self, max_cols);
            }
        }

        if (!compact and self.hints_marquee.dirty) {
            drawHintsRow(stdout, colors, self, max_rows, max_cols);
        }

        self.has_drawn_once = true;
        self.force_full_redraw = false;
        self.last_snapshot = snapshot;
    }

    /// Details-panel rows for the profile under the cursor.
    fn selectedDetails(self: *const ProfilesWidget) []const Detail {
        if (self.cursor >= self.rows.len) return &.{};
        return self.rows[self.cursor].details;
    }

    /// Scrolls the key-hints footer when it is wider than the terminal. In the
    /// compact layout the whole screen is repainted, so a step forces a full
    /// redraw; the panel layout repaints the footer row on its own.
    pub fn advanceMarquee(self: *ProfilesWidget, max_rows: u16, max_cols: u16) bool {
        const compact = theme.isCompactViewport(max_rows, max_cols);
        const indent = if (compact) hints.compact_indent_cols else hints.panel_indent_cols;
        if (!self.hints_marquee.advance(self.hintsText(compact), max_cols, indent)) return false;
        if (compact) self.force_full_redraw = true;
        return true;
    }

    /// Key hints for the current state, shown in the footer. The compact
    /// layout drops the navigation hints that do not fit alongside the
    /// shorter list.
    fn hintsText(self: *const ProfilesWidget, compact: bool) []const u8 {
        if (self.apply_progress) |progress| {
            if (progress.canceling) return "Finishing current indexer\xe2\x80\xa6";
            return if (compact)
                "ESC stop after current"
            else
                "\xe2\x86\x91\xe2\x86\x93 move | shift+\xe2\x86\x91\xe2\x86\x93 page | ESC stop after current";
        }
        return if (compact)
            "ENTER load | r rename | Del delete | F1 indexers | ESC back"
        else
            "\xe2\x86\x91\xe2\x86\x93 move | shift+\xe2\x86\x91\xe2\x86\x93 page | ENTER load | r rename | Del delete | F1 indexers | ESC back";
    }
};

/// Repaints just the hints footer, for marquee steps that leave the rest of the
/// screen untouched.
fn drawHintsRow(
    stdout: compat.FileWriter,
    colors: theme.Theme,
    widget: *ProfilesWidget,
    max_rows: u16,
    max_cols: u16,
) void {
    term.moveCursor(hints.rowFromDisplayCount(widget.display_count, max_rows), 1);
    term.setFg256(colors.muted);
    widget.hints_marquee.draw(stdout, widget.hintsText(false), max_cols, hints.panel_indent_cols);
    term.resetColor();
    term.clearBelow();
}

const RenderSnapshot = list_nav.BaseSnapshot;

fn cloneDetails(allocator: std.mem.Allocator, sources: []const ProfilesWidget.DetailSource) ![]ProfilesWidget.Detail {
    const out = try allocator.alloc(ProfilesWidget.Detail, sources.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |detail| allocator.free(detail.name);
        allocator.free(out);
    }
    for (sources, 0..) |source, i| {
        out[i] = .{ .name = try allocator.dupe(u8, source.name), .change = source.change };
        filled += 1;
    }
    return out;
}

/// Widths of the profiles list and the details panel beside it.
/// `details_width` is 0 when the terminal is too narrow for the details
/// panel, in which case the list spans the full width.
const PanelSplit = struct {
    list_width: usize,
    details_width: usize,

    const min_total_for_details: usize = 64;
    const min_list_width: usize = 28;
    const max_list_width: usize = 44;
    const gap: usize = 1;

    fn forTotalWidth(total: usize) PanelSplit {
        if (total < min_total_for_details) return .{ .list_width = total, .details_width = 0 };
        const list_width = std.math.clamp(total * 2 / 5, min_list_width, max_list_width);
        return .{ .list_width = list_width, .details_width = total - list_width - gap };
    }
};

/// Column layout of the details panel: indexer name and its "On load" change.
const DetailsLayout = struct {
    name_col_width: usize,
    change_col_width: usize,
    column_gap: usize,

    const fixed_change_width: usize = 10;
    const fixed_gap: usize = 2;
    const fixed_padding: usize = 2;

    fn forInnerWidth(inner_width: usize) DetailsLayout {
        const fixed = fixed_padding + fixed_gap + fixed_change_width;
        return .{
            .name_col_width = if (inner_width > fixed) inner_width - fixed else 1,
            .change_col_width = fixed_change_width,
            .column_gap = fixed_gap,
        };
    }
};

fn changeLabel(change: ProfilesWidget.Change) []const u8 {
    return switch (change) {
        .keep => "stays on",
        .enable => "+ enable",
        .disable => "- disable",
        .missing => "missing",
    };
}

fn changeColor(colors: theme.Theme, change: ProfilesWidget.Change) u8 {
    return switch (change) {
        .keep => colors.muted,
        .enable => colors.ok,
        .disable => colors.warn,
        .missing => colors.err,
    };
}

const ChangeCounts = struct {
    keep: usize = 0,
    enable: usize = 0,
    disable: usize = 0,
    missing: usize = 0,

    fn of(details: []const ProfilesWidget.Detail) ChangeCounts {
        var counts = ChangeCounts{};
        for (details) |detail| switch (detail.change) {
            .keep => counts.keep += 1,
            .enable => counts.enable += 1,
            .disable => counts.disable += 1,
            .missing => counts.missing += 1,
        };
        return counts;
    }

    fn members(self: ChangeCounts) usize {
        return self.keep + self.enable + self.missing;
    }
};

/// Status row of the details panel: profile size, what loading would change,
/// and how many rows did not fit.
fn formatDetailsSummary(buf: []u8, counts: ChangeCounts, hidden: usize) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    writer.print("{d} indexers", .{counts.members()}) catch return "";
    if (counts.enable == 0 and counts.disable == 0 and counts.missing == 0) {
        writer.writeAll(" | already loaded") catch {};
    } else {
        writer.print(" | +{d} enable | -{d} disable", .{ counts.enable, counts.disable }) catch {};
        if (counts.missing > 0) writer.print(" | {d} missing", .{counts.missing}) catch {};
    }
    if (hidden > 0) writer.print(" | {d} more below", .{hidden}) catch {};
    return writer.buffered();
}

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

fn endLine(stdout: compat.FileWriter) void {
    term.resetColor();
    stdout.writeAll("\r\n") catch {};
}

/// Top or bottom edge of one panel, without a line break.
fn writeEdge(stdout: compat.FileWriter, width: usize, left: []const u8, right: []const u8, border: theme.BorderChars, colors: theme.Theme) void {
    if (width < 2) return;
    term.setFg256(colors.panel_border);
    stdout.writeAll(left) catch {};
    theme.writeRepeat(stdout, border.horizontal, width - 2) catch {};
    stdout.writeAll(right) catch {};
    term.resetColor();
}

/// Horizontal divider inside one panel, without a line break.
fn writeDivider(stdout: compat.FileWriter, width: usize, border: theme.BorderChars, colors: theme.Theme) void {
    writeEdge(stdout, width, border.vertical, border.vertical, border, colors);
}

/// One bordered panel row of plain `content` in color `fg`, without a line break.
fn writeTextRow(stdout: compat.FileWriter, width: usize, content: []const u8, fg: u8, border: theme.BorderChars, colors: theme.Theme) void {
    if (width < 2) return;
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.setFg256(fg);
    var trunc_buf: [512]u8 = undefined;
    theme.writePadded(stdout, theme.truncateWithEllipsis(content, width - 2, &trunc_buf), width - 2) catch {};
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.resetColor();
}

/// Draws the list panel and, when it fits, the details panel beside it. Each
/// screen line carries one row of both panels.
fn drawPanels(
    stdout: compat.FileWriter,
    colors: theme.Theme,
    border: theme.BorderChars,
    self: *ProfilesWidget,
    max_cols: u16,
) void {
    const split = PanelSplit.forTotalWidth(@as(usize, max_cols) - 2);
    const has_details = split.details_width >= 2;
    const list_inner = split.list_width - 2;
    const list_layout = TableLayout.forInnerWidth(list_inner);
    const details_layout = DetailsLayout.forInnerWidth(if (has_details) split.details_width - 2 else 0);
    const details = self.selectedDetails();
    const shown_details = @min(details.len, self.display_count);
    const end_idx = @min(self.scroll_offset + self.display_count, self.rows.len);

    term.moveCursor(1, 1);

    // Top edges.
    writeSpaces(stdout, 1) catch {};
    writeEdge(stdout, split.list_width, border.top_left, border.top_right, border, colors);
    if (has_details) {
        writeSpaces(stdout, PanelSplit.gap) catch {};
        writeEdge(stdout, split.details_width, border.top_left, border.top_right, border, colors);
    }
    endLine(stdout);

    // Column headers.
    writeSpaces(stdout, 1) catch {};
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    writeHeaderCells(stdout, list_inner, list_layout, colors) catch {};
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    if (has_details) {
        writeSpaces(stdout, PanelSplit.gap) catch {};
        term.setFg256(colors.panel_border);
        stdout.writeAll(border.vertical) catch {};
        const profile_name = if (self.cursor < self.rows.len) self.rows[self.cursor].name else "";
        writeDetailsHeaderCells(stdout, details_layout, profile_name, colors) catch {};
        term.setFg256(colors.panel_border);
        stdout.writeAll(border.vertical) catch {};
    }
    endLine(stdout);

    writeSpaces(stdout, 1) catch {};
    writeDivider(stdout, split.list_width, border, colors);
    if (has_details) {
        writeSpaces(stdout, PanelSplit.gap) catch {};
        writeDivider(stdout, split.details_width, border, colors);
    }
    endLine(stdout);

    // Content rows.
    for (0..self.display_count) |rel_idx| {
        writeSpaces(stdout, 1) catch {};
        writeListRow(stdout, list_inner, list_layout, border, colors, self, self.scroll_offset + rel_idx) catch {};
        if (has_details) {
            writeSpaces(stdout, PanelSplit.gap) catch {};
            const detail: ?ProfilesWidget.Detail = if (rel_idx < shown_details) details[rel_idx] else null;
            writeDetailRow(stdout, details_layout, border, colors, detail) catch {};
        }
        endLine(stdout);
    }

    writeSpaces(stdout, 1) catch {};
    writeDivider(stdout, split.list_width, border, colors);
    if (has_details) {
        writeSpaces(stdout, PanelSplit.gap) catch {};
        writeDivider(stdout, split.details_width, border, colors);
    }
    endLine(stdout);

    // Status rows.
    var status_buf: [128]u8 = undefined;
    const status = formatStatusText(&status_buf, self.scroll_offset, end_idx, self.rows.len, self.apply_progress);
    writeSpaces(stdout, 1) catch {};
    writeTextRow(stdout, split.list_width, status, colors.panel_title, border, colors);
    if (has_details) {
        writeSpaces(stdout, PanelSplit.gap) catch {};
        var summary_buf: [160]u8 = undefined;
        const summary = if (self.rows.len == 0)
            ""
        else
            formatDetailsSummary(&summary_buf, ChangeCounts.of(details), details.len - shown_details);
        writeTextRow(stdout, split.details_width, summary, colors.panel_title, border, colors);
    }
    endLine(stdout);

    writeSpaces(stdout, 1) catch {};
    writeEdge(stdout, split.list_width, border.bottom_left, border.bottom_right, border, colors);
    if (has_details) {
        writeSpaces(stdout, PanelSplit.gap) catch {};
        writeEdge(stdout, split.details_width, border.bottom_left, border.bottom_right, border, colors);
    }
    endLine(stdout);

    term.setFg256(colors.muted);
    self.hints_marquee.draw(stdout, self.hintsText(false), max_cols, hints.panel_indent_cols);
    term.resetColor();
    term.clearBelow();
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
    try theme.writePadded(stdout, "Indexers", layout.count_col_width);
    try stdout.writeAll(" ");

    const used = 1 + layout.name_col_width + layout.column_gap + layout.count_col_width + 1;
    if (used < inner_width) {
        try writeSpaces(stdout, inner_width - used);
    }
}

fn writeDetailsHeaderCells(
    stdout: compat.FileWriter,
    layout: DetailsLayout,
    profile_name: []const u8,
    colors: theme.Theme,
) !void {
    var title_buf: [544]u8 = undefined;
    const title = if (profile_name.len == 0)
        "Indexers"
    else
        std.mem.print(&title_buf, "Indexers in {s}", .{profile_name}) catch "Indexers";
    var trunc_buf: [512]u8 = undefined;

    try stdout.writeAll(" ");
    term.setFg256(colors.muted);
    try theme.writePadded(stdout, theme.truncateWithEllipsis(title, layout.name_col_width, &trunc_buf), layout.name_col_width);
    try writeSpaces(stdout, layout.column_gap);
    try theme.writePadded(stdout, "On load", layout.change_col_width);
    try stdout.writeAll(" ");
}

fn writeListRow(
    stdout: compat.FileWriter,
    inner_width: usize,
    layout: TableLayout,
    border: theme.BorderChars,
    colors: theme.Theme,
    widget: *ProfilesWidget,
    abs_idx: usize,
) !void {
    term.setFg256(colors.panel_border);
    try stdout.writeAll(border.vertical);

    if (abs_idx >= widget.rows.len) {
        try writeSpaces(stdout, inner_width);
    } else {
        const row = widget.rows[abs_idx];
        var cell_buf: [768]u8 = undefined;
        const content = buildDataCells(&cell_buf, inner_width, layout, row.name, row.count, row.active);

        if (abs_idx == widget.cursor) {
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
    }

    term.setFg256(colors.panel_border);
    try stdout.writeAll(border.vertical);
    term.resetColor();
}

fn writeDetailRow(
    stdout: compat.FileWriter,
    layout: DetailsLayout,
    border: theme.BorderChars,
    colors: theme.Theme,
    detail: ?ProfilesWidget.Detail,
) !void {
    const inner_width = layout.name_col_width + layout.column_gap + layout.change_col_width + DetailsLayout.fixed_padding;
    term.setFg256(colors.panel_border);
    try stdout.writeAll(border.vertical);

    if (detail) |d| {
        var trunc_buf: [512]u8 = undefined;
        try stdout.writeAll(" ");
        term.setFg256(if (d.change == .disable) colors.muted else colors.text);
        try theme.writePadded(stdout, theme.truncateWithEllipsis(d.name, layout.name_col_width, &trunc_buf), layout.name_col_width);
        try writeSpaces(stdout, layout.column_gap);
        term.setFg256(changeColor(colors, d.change));
        try theme.writePadded(stdout, changeLabel(d.change), layout.change_col_width);
        try stdout.writeAll(" ");
    } else {
        try writeSpaces(stdout, inner_width);
    }

    term.setFg256(colors.panel_border);
    try stdout.writeAll(border.vertical);
    term.resetColor();
}

fn buildDataCells(
    buf: []u8,
    inner_width: usize,
    layout: TableLayout,
    name: []const u8,
    indexer_count: usize,
    active: bool,
) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);

    writer.writeAll(" ") catch return "";

    var name_buf: [512]u8 = undefined;
    var label_buf: [544]u8 = undefined;
    const label = if (active)
        std.mem.print(&label_buf, "{s} *", .{name}) catch name
    else
        name;
    const truncated_name = theme.truncateWithEllipsis(label, layout.name_col_width, &name_buf);
    theme.writePadded(&writer, truncated_name, layout.name_col_width) catch return "";
    writeSpaces(&writer, layout.column_gap) catch return "";

    var count_buf: [32]u8 = undefined;
    const count_text = std.mem.print(&count_buf, "{d}", .{indexer_count}) catch "?";
    theme.writePadded(&writer, count_text, layout.count_col_width) catch return "";
    writer.writeAll(" ") catch return "";

    const used = writer.buffered().len;
    if (used < inner_width) {
        writeSpaces(&writer, inner_width - used) catch {};
    }
    return writer.buffered();
}

/// Status row text. While a profile is being applied, mirrors the Indexers
/// screen's commit row ("Showing 1-3 of 3 | Applying 2/4 ⣏⡆", plus a failed
/// tally).
fn formatStatusText(
    buf: []u8,
    scroll_offset: usize,
    end_idx: usize,
    total_count: usize,
    apply_progress: ?ProfilesWidget.CommitProgress,
) []const u8 {
    if (apply_progress) |progress| {
        const spinner = theme.spinnerGlyph(progress.spinner_frame);
        if (progress.failed == 0) {
            return std.mem.print(
                buf,
                "Showing {d}-{d} of {d} | Applying {d}/{d} {s}",
                .{ scroll_offset + 1, end_idx, total_count, progress.completed, progress.total, spinner },
            ) catch "Applying";
        }
        return std.mem.print(
            buf,
            "Showing {d}-{d} of {d} | Applying {d}/{d}, {d} failed {s}",
            .{ scroll_offset + 1, end_idx, total_count, progress.completed, progress.total, progress.failed, spinner },
        ) catch "Applying";
    }
    if (total_count == 0) return "No profiles saved";
    return std.mem.print(buf, "Showing {d}-{d} of {d}", .{ scroll_offset + 1, end_idx, total_count }) catch "Showing";
}

fn drawCompact(
    stdout: compat.FileWriter,
    colors: theme.Theme,
    border: theme.BorderChars,
    self: *ProfilesWidget,
    max_cols: u16,
) void {
    term.moveCursor(1, 1);
    // Wipe whatever a previous screen or notice left on these lines.
    term.clearBelow();
    term.setFg256(colors.panel_title);
    term.setBold(true);
    stdout.writeAll("Load Indexer Profile\r\n") catch {};
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
        const count_line = std.mem.print(&count_buf, " ({d} indexers)\r\n", .{row.count}) catch "\r\n";
        stdout.writeAll(count_line) catch {};
        term.setFg256(colors.panel_title);
        var status_buf: [128]u8 = undefined;
        const status = formatStatusText(&status_buf, self.scroll_offset, @min(self.scroll_offset + self.display_count, self.rows.len), self.rows.len, self.apply_progress);
        stdout.writeAll(status) catch {};
        stdout.writeAll("\r\n") catch {};
    }

    drawCompactDivider(stdout, colors, border, max_cols);
    term.setFg256(colors.muted);
    self.hints_marquee.draw(stdout, self.hintsText(true), max_cols, hints.compact_indent_cols);
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

test "the hints footer scrolls when it outgrows the terminal" {
    var widget = ProfilesWidget.init(std.testing.allocator);
    defer widget.deinit();

    var moved = false;
    for (0..8) |_| {
        if (widget.advanceMarquee(24, 60)) moved = true;
    }
    try std.testing.expect(moved);
    try std.testing.expect(widget.hints_marquee.offset_cols > 0);
}

test "the hints footer stays inside the terminal width" {
    var widget = ProfilesWidget.init(std.testing.allocator);
    defer widget.deinit();

    var buf: [512]u8 = undefined;
    for ([_]u16{ 56, 80, 120 }) |cols| {
        var writer: std.Io.Writer = .fixed(&buf);
        widget.hints_marquee.reset();
        widget.hints_marquee.draw(&writer, widget.hintsText(false), cols, hints.panel_indent_cols);
        try std.testing.expect(theme.displayWidthOfText(writer.buffered()) < cols);
    }
}

test "setCommitProgress only forces a redraw when the value changes" {
    var widget = ProfilesWidget.init(std.testing.allocator);
    defer widget.deinit();
    widget.force_full_redraw = false;

    widget.setCommitProgress(.{ .completed = 1, .total = 3, .failed = 0, .spinner_frame = 0 });
    try std.testing.expect(widget.force_full_redraw);
    widget.force_full_redraw = false;
    widget.setCommitProgress(.{ .completed = 1, .total = 3, .failed = 0, .spinner_frame = 0 });
    try std.testing.expect(!widget.force_full_redraw);
    widget.setCommitProgress(null);
    try std.testing.expect(widget.force_full_redraw);
    try std.testing.expect(widget.apply_progress == null);
}

test "status row reports apply progress and failures" {
    var buf: [128]u8 = undefined;
    const running = formatStatusText(&buf, 0, 3, 3, .{ .completed = 2, .total = 4, .failed = 0, .spinner_frame = 0 });
    try std.testing.expect(std.mem.find(u8, running, "Applying 2/4") != null);
    const failing = formatStatusText(&buf, 0, 3, 3, .{ .completed = 3, .total = 4, .failed = 1, .spinner_frame = 0 });
    try std.testing.expect(std.mem.find(u8, failing, "Applying 3/4, 1 failed") != null);
    try std.testing.expectEqualStrings("Showing 1-3 of 3", formatStatusText(&buf, 0, 3, 3, null));
}

test "handleNavigationOnly moves the cursor but never loads, deletes or closes" {
    var widget = ProfilesWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setProfiles(testSources());
    widget.display_count = 3;

    try std.testing.expect(widget.handleNavigationOnly(.{ .key = .arrow_down, .value = 0 }));
    try std.testing.expectEqual(@as(usize, 1), widget.cursor);
    try std.testing.expect(!widget.handleNavigationOnly(.{ .key = .enter, .value = 0 }));
    try std.testing.expect(!widget.handleNavigationOnly(.{ .key = .delete, .value = 0 }));
    try std.testing.expect(!widget.handleNavigationOnly(.{ .key = .escape, .value = 0 }));
    try std.testing.expectEqual(@as(usize, 1), widget.cursor);
}

test "hints switch to the stop hint while a profile is being applied" {
    var widget = ProfilesWidget.init(std.testing.allocator);
    defer widget.deinit();

    try std.testing.expect(std.mem.find(u8, widget.hintsText(false), "ENTER load") != null);
    widget.setCommitProgress(.{ .completed = 0, .total = 2, .failed = 0, .spinner_frame = 0 });
    try std.testing.expect(std.mem.find(u8, widget.hintsText(false), "ESC stop after current") != null);
    try std.testing.expect(std.mem.find(u8, widget.hintsText(true), "ENTER load") == null);
    widget.setCommitProgress(.{ .completed = 0, .total = 2, .failed = 0, .spinner_frame = 0, .canceling = true });
    try std.testing.expect(std.mem.find(u8, widget.hintsText(false), "Finishing current indexer") != null);
}

test "handleEvent r returns rename with cursor index, but not on an empty list" {
    var widget = ProfilesWidget.init(std.testing.allocator);
    defer widget.deinit();

    try std.testing.expectEqual(ProfilesWidget.ProfilesAction.continue_browsing, widget.handleEvent(.{ .key = .char, .value = 'r' }));

    try widget.setProfiles(testSources());
    widget.cursor = 1;
    switch (widget.handleEvent(.{ .key = .char, .value = 'R' })) {
        .rename => |idx| try std.testing.expectEqual(@as(usize, 1), idx),
        else => return error.UnexpectedAction,
    }
}

test "setProfiles copies details and selectedDetails follows the cursor" {
    var widget = ProfilesWidget.init(std.testing.allocator);
    defer widget.deinit();

    const anime_details = [_]ProfilesWidget.DetailSource{
        .{ .name = "Nyaa", .change = .keep },
        .{ .name = "Tokyo Toshokan", .change = .enable },
        .{ .name = "1337x", .change = .disable },
    };
    try widget.setProfiles(&.{
        .{ .name = "Anime", .count = 2, .details = &anime_details },
        .{ .name = "Empty", .count = 0 },
    });

    const details = widget.selectedDetails();
    try std.testing.expectEqual(@as(usize, 3), details.len);
    try std.testing.expectEqualStrings("Tokyo Toshokan", details[1].name);
    try std.testing.expect(details[1].name.ptr != anime_details[1].name.ptr);
    try std.testing.expectEqual(ProfilesWidget.Change.disable, details[2].change);

    widget.cursor = 1;
    try std.testing.expectEqual(@as(usize, 0), widget.selectedDetails().len);
}

test "formatDetailsSummary describes the changes a load would make" {
    var buf: [160]u8 = undefined;
    try std.testing.expectEqualStrings(
        "2 indexers | already loaded",
        formatDetailsSummary(&buf, .{ .keep = 2 }, 0),
    );
    try std.testing.expectEqualStrings(
        "3 indexers | +1 enable | -2 disable",
        formatDetailsSummary(&buf, .{ .keep = 2, .enable = 1, .disable = 2 }, 0),
    );
    try std.testing.expectEqualStrings(
        "2 indexers | +0 enable | -0 disable | 1 missing | 4 more below",
        formatDetailsSummary(&buf, .{ .keep = 1, .missing = 1 }, 4),
    );
}

test "PanelSplit drops the details panel on narrow terminals and clamps the list" {
    const narrow = PanelSplit.forTotalWidth(60);
    try std.testing.expectEqual(@as(usize, 60), narrow.list_width);
    try std.testing.expectEqual(@as(usize, 0), narrow.details_width);

    const medium = PanelSplit.forTotalWidth(78);
    try std.testing.expectEqual(@as(usize, 31), medium.list_width);
    try std.testing.expectEqual(@as(usize, 78 - 31 - 1), medium.details_width);

    const wide = PanelSplit.forTotalWidth(200);
    try std.testing.expectEqual(@as(usize, 44), wide.list_width);
    try std.testing.expectEqual(@as(usize, 200 - 44 - 1), wide.details_width);
}
