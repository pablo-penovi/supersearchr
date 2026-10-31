const std = @import("std");
const term = @import("term");
const theme = @import("theme");
const build_options = @import("build_options");
const compat = @import("compat");
const hints = @import("hints");

/// Key hints shown under the query. Both are wider than the narrowest
/// supported terminal, so they scroll rather than wrap onto the next row.
const panel_hints_text = " ENTER submit | ESC quit | Ctrl-BS clear | F1 indexers | F2 profiles ";
const compact_hints_text = "ENTER search | ESC exit | Ctrl-BS clear | F1 indexers | F2 profiles";

pub const SearchWidget = struct {
    allocator: std.mem.Allocator,
    query: std.ArrayList(u8),
    latest_version: ?[]const u8,
    /// Name of the active indexer profile (borrowed), shown next to the title.
    active_profile: ?[]const u8,
    /// True when the live indexer set is known to differ from the active profile.
    active_profile_modified: bool,
    has_drawn_once: bool,
    last_size: ?term.TerminalSize,
    hints_marquee: hints.HintsMarquee,

    pub fn init(allocator: std.mem.Allocator) SearchWidget {
        return .{
            .allocator = allocator,
            .query = .empty,
            .latest_version = null,
            .active_profile = null,
            .active_profile_modified = false,
            .has_drawn_once = false,
            .last_size = null,
            .hints_marquee = .{},
        };
    }

    pub fn deinit(self: *SearchWidget) void {
        self.query.deinit(self.allocator);
    }

    pub fn render(self: *SearchWidget) void {
        const stdout = compat.stdoutWriter();
        const colors = theme.superseedr_like;
        const border = theme.unicode_border;
        const size = term.getTerminalSize() catch term.TerminalSize{ .rows = 24, .cols = 80 };
        const redraw_mode = computeRedrawMode(self.has_drawn_once, self.last_size, size);
        term.hideCursor();

        if (theme.isCompactViewport(size.rows, size.cols)) {
            switch (redraw_mode) {
                .full => drawCompactFull(stdout, colors, self, size),
                .partial => {
                    drawCompactInputLine(stdout, size, colors, self.query.items);
                    if (self.hints_marquee.dirty) drawCompactHintsRow(stdout, size, colors, &self.hints_marquee);
                },
            }
        } else {
            const layout = computePanelLayout(size);
            switch (redraw_mode) {
                .full => drawPanelFrame(stdout, colors, border, layout, self),
                .partial => {
                    if (self.hints_marquee.dirty) drawPanelHintsRow(stdout, size, colors, border, layout, &self.hints_marquee);
                },
            }
            drawPanelQueryRow(stdout, size, colors, border, layout, self.query.items);
        }

        const cursor = computeSearchCursorPosition(size, self.query.items.len);
        term.moveCursor(cursor.row, cursor.col);
        term.showCursor();
        self.has_drawn_once = true;
        self.last_size = size;
    }

    /// Scrolls the key hints when they are wider than the space under the
    /// query. Returns true when the row needs a repaint.
    pub fn advanceHintsMarquee(self: *SearchWidget) bool {
        const size = term.getTerminalSize() catch term.TerminalSize{ .rows = 24, .cols = 80 };
        if (theme.isCompactViewport(size.rows, size.cols)) {
            return self.hints_marquee.advance(compact_hints_text, size.cols, hints.compact_indent_cols);
        }
        return self.hints_marquee.advanceIn(panel_hints_text, computePanelLayout(size).panel_width - 2);
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
            .shift_backspace => {
                self.clear();
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

    pub fn setQuery(self: *SearchWidget, query: []const u8) !void {
        self.query.clearRetainingCapacity();
        try self.query.appendSlice(self.allocator, query);
    }

    pub fn setLatestVersion(self: *SearchWidget, latest_version: ?[]const u8) void {
        self.latest_version = latest_version;
    }

    /// Sets the active profile shown beside the title (`null` hides it). The
    /// name is borrowed and must outlive the widget's renders.
    pub fn setActiveProfile(self: *SearchWidget, name: ?[]const u8, modified: bool) void {
        self.active_profile = name;
        self.active_profile_modified = modified;
        self.has_drawn_once = false;
    }
};

/// Formats the "Profile: <name>" label to fit within `max_cols`, truncating
/// the name (never the prefix or the "(modified)" marker). Returns an empty
/// slice when even a one-column name would not fit.
fn formatProfileLabel(buf: []u8, name: []const u8, modified: bool, max_cols: usize) []const u8 {
    const prefix = "Profile: ";
    const suffix = if (modified) " (modified)" else "";
    const fixed = prefix.len + suffix.len;
    if (max_cols <= fixed) return "";
    var trunc_buf: [256]u8 = undefined;
    const shown = theme.truncateWithEllipsis(name, @min(max_cols - fixed, trunc_buf.len), &trunc_buf);
    return std.mem.print(buf, "{s}{s}{s}", .{ prefix, shown, suffix }) catch "";
}

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

fn drawCompactFull(
    stdout: compat.FileWriter,
    colors: theme.Theme,
    widget: *SearchWidget,
    size: term.TerminalSize,
) void {
    const title = "supersearchr";
    const separator = "  ";
    term.moveCursor(1, 1);
    term.clearScreen();
    term.setFg256(colors.panel_title);
    term.setBold(true);
    stdout.writeAll(title) catch {};
    term.setBold(false);
    if (widget.active_profile) |name| {
        const cols: usize = size.cols;
        if (cols > title.len + separator.len) {
            var label_buf: [320]u8 = undefined;
            const label = formatProfileLabel(&label_buf, name, widget.active_profile_modified, cols - title.len - separator.len);
            if (label.len > 0) {
                term.setFg256(colors.muted);
                stdout.writeAll(separator) catch {};
                stdout.writeAll(label) catch {};
            }
        }
    }
    stdout.writeAll("\r\n") catch {};
    term.setFg256(colors.text);
    stdout.writeAll("> ") catch {};
    stdout.writeAll(widget.query.items) catch {};
    stdout.writeAll("\r\n") catch {};
    term.setFg256(colors.muted);
    widget.hints_marquee.draw(stdout, compact_hints_text, size.cols, hints.compact_indent_cols);
    stdout.writeAll("\r\n") catch {};
    writeVersionLine(stdout, colors, widget.latest_version);
}

fn drawCompactInputLine(stdout: compat.FileWriter, size: term.TerminalSize, colors: theme.Theme, query: []const u8) void {
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

fn drawPanelFrame(
    stdout: compat.FileWriter,
    colors: theme.Theme,
    border: theme.BorderChars,
    layout: PanelLayout,
    widget: *SearchWidget,
) void {
    const latest_version = widget.latest_version;
    const hints_marquee = &widget.hints_marquee;
    term.moveCursor(1, 1);
    term.clearScreen();
    term.moveCursor(@as(u16, @intCast(layout.top_pad)), 1);
    writeSpaces(stdout, layout.left_pad) catch {};
    theme.drawPanelTop(stdout, layout.panel_width, border, colors) catch {};

    writeSpaces(stdout, layout.left_pad) catch {};
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    drawPanelTitleCells(stdout, colors, layout.panel_width - 2, widget.active_profile, widget.active_profile_modified);
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
    hints_marquee.drawPaddedIn(stdout, panel_hints_text, layout.panel_width - 2);
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.resetColor();
    stdout.writeAll("\r\n") catch {};

    writeSpaces(stdout, layout.left_pad) catch {};
    theme.drawPanelBottom(stdout, layout.panel_width, border, colors) catch {};

    term.moveCursor(@as(u16, @intCast(layout.top_pad + 6)), @as(u16, @intCast(layout.left_pad + 2)));
    writeVersionLine(stdout, colors, latest_version);
}

/// Title row contents: " Search" on the left and, when a profile is active,
/// "Profile: <name> " right-aligned in the muted color.
fn drawPanelTitleCells(
    stdout: compat.FileWriter,
    colors: theme.Theme,
    inner_width: usize,
    active_profile: ?[]const u8,
    modified: bool,
) void {
    const title = " Search ";
    var label_buf: [320]u8 = undefined;
    const label = if (active_profile) |name|
        (if (inner_width > title.len + 1) formatProfileLabel(&label_buf, name, modified, inner_width - title.len - 1) else "")
    else
        "";
    const label_cols = theme.displayWidthOfText(label);
    const trailing_gap: usize = if (label_cols > 0) 1 else 0;

    term.setFg256(colors.panel_title);
    term.setBold(true);
    theme.writePadded(stdout, title, inner_width - label_cols - trailing_gap) catch {};
    term.setBold(false);
    if (label_cols > 0) {
        term.setFg256(if (modified) colors.warn else colors.muted);
        stdout.writeAll(label) catch {};
        stdout.writeAll(" ") catch {};
    }
}

fn writeVersionLine(stdout: compat.FileWriter, colors: theme.Theme, latest_version: ?[]const u8) void {
    term.setFg256(colors.muted);
    if (latest_version) |latest| {
        term.setStrikethrough(true);
        stdout.writeAll("v" ++ build_options.version) catch {};
        term.setStrikethrough(false);
        stdout.writeAll(" ") catch {};
        term.setFg256(colors.warn);
        term.setBold(true);
        stdout.writeAll("v") catch {};
        stdout.writeAll(latest) catch {};
        stdout.writeAll(" New available!") catch {};
        term.setBold(false);
    } else {
        stdout.writeAll("v" ++ build_options.version) catch {};
    }
    term.resetColor();
}

/// Repaints only the hints row inside the panel, for marquee steps.
fn drawPanelHintsRow(
    stdout: compat.FileWriter,
    size: term.TerminalSize,
    colors: theme.Theme,
    border: theme.BorderChars,
    layout: PanelLayout,
    hints_marquee: *hints.HintsMarquee,
) void {
    const hints_row = clampCursorCoord(size.rows, layout.top_pad + 4);
    term.moveCursor(hints_row, @as(u16, @intCast(layout.left_pad + 1)));
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.setFg256(colors.muted);
    hints_marquee.drawPaddedIn(stdout, panel_hints_text, layout.panel_width - 2);
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.resetColor();
}

/// Repaints only the hints row of the compact layout, for marquee steps.
fn drawCompactHintsRow(
    stdout: compat.FileWriter,
    size: term.TerminalSize,
    colors: theme.Theme,
    hints_marquee: *hints.HintsMarquee,
) void {
    term.moveCursor(clampCursorCoord(size.rows, 3), 1);
    term.setFg256(colors.muted);
    // Padded rather than cleared to the end of the screen: the version line
    // sits on the row below.
    hints_marquee.drawPaddedIn(stdout, compact_hints_text, hints.availableCols(size.cols, hints.compact_indent_cols));
    term.resetColor();
}

fn drawPanelQueryRow(stdout: compat.FileWriter, size: term.TerminalSize, colors: theme.Theme, border: theme.BorderChars, layout: PanelLayout, query: []const u8) void {
    const query_row = clampCursorCoord(size.rows, layout.top_pad + 3);
    term.moveCursor(query_row, @as(u16, @intCast(layout.left_pad + 1)));

    var trunc_buf: [512]u8 = undefined;
    var line_buf: [640]u8 = undefined;
    const shown = theme.truncateWithEllipsis(query, layout.panel_width - 11, trunc_buf[0..]);
    const query_line = std.mem.print(&line_buf, " Query: {s}", .{shown}) catch " Query:";

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

test "SearchWidget setLatestVersion stores update info" {
    const allocator = std.testing.allocator;
    var widget = SearchWidget.init(allocator);
    defer widget.deinit();

    widget.setLatestVersion("0.3.7");
    try std.testing.expect(widget.latest_version != null);
    try std.testing.expectEqualStrings("0.3.7", widget.latest_version.?);
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
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const ascii_border = theme.BorderChars{
        .top_left = "+",
        .top_right = "+",
        .bottom_left = "+",
        .bottom_right = "+",
        .horizontal = "-",
        .vertical = "|",
    };

    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    try writePanelRowNoNewline(&writer.writer, 10, " Query:", ascii_border, theme.superseedr_like, false);
    try writer.writer.flush();
    out = writer.toArrayList();
    try std.testing.expect(std.mem.find(u8, out.items, "\r\n") == null);
}

test "writePanelRowNoNewline fills to width with borders" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const ascii_border = theme.BorderChars{
        .top_left = "+",
        .top_right = "+",
        .bottom_left = "+",
        .bottom_right = "+",
        .horizontal = "-",
        .vertical = "|",
    };

    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    try writePanelRowNoNewline(&writer.writer, 12, " Query: x", ascii_border, theme.superseedr_like, false);
    try writer.writer.flush();
    out = writer.toArrayList();
    try std.testing.expect(std.mem.find(u8, out.items, "\r\n") == null);
    try std.testing.expectEqual(@as(usize, 12), out.items.len);
}

test "SearchWidget handleEvent shift_backspace clears query" {
    const allocator = std.testing.allocator;
    var widget = SearchWidget.init(allocator);
    defer widget.deinit();

    try widget.query.append(allocator, 'h');
    try widget.query.append(allocator, 'i');

    const event = term.Event{ .key = .shift_backspace, .value = 0 };
    const action = widget.handleEvent(event);

    try std.testing.expectEqual(SearchAction.continue_search, action);
    try std.testing.expectEqual(@as(usize, 0), widget.query.items.len);
}

test "SearchWidget setQuery populates query" {
    const allocator = std.testing.allocator;
    var widget = SearchWidget.init(allocator);
    defer widget.deinit();

    try widget.setQuery("test query");
    try std.testing.expectEqualStrings("test query", widget.query.items);
}

test "SearchWidget setActiveProfile stores the name and forces a full redraw" {
    const allocator = std.testing.allocator;
    var widget = SearchWidget.init(allocator);
    defer widget.deinit();
    widget.has_drawn_once = true;

    widget.setActiveProfile("Movies", true);
    try std.testing.expectEqualStrings("Movies", widget.active_profile.?);
    try std.testing.expect(widget.active_profile_modified);
    try std.testing.expect(!widget.has_drawn_once);
}

test "formatProfileLabel includes the name and modified marker" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Profile: Movies", formatProfileLabel(&buf, "Movies", false, 40));
    try std.testing.expectEqualStrings("Profile: Movies (modified)", formatProfileLabel(&buf, "Movies", true, 40));
}

test "formatProfileLabel truncates the name to fit and keeps the marker" {
    var buf: [128]u8 = undefined;
    const label = formatProfileLabel(&buf, "A very long profile name indeed", true, 30);
    try std.testing.expect(theme.displayWidthOfText(label) <= 30);
    try std.testing.expect(std.mem.startsWith(u8, label, "Profile: "));
    try std.testing.expect(std.mem.endsWith(u8, label, " (modified)"));
}

test "formatProfileLabel is empty when there is no room for the name" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", formatProfileLabel(&buf, "Movies", false, 9));
}

test "search hints advertise both F1 and F2 in every layout" {
    for ([_][]const u8{ panel_hints_text, compact_hints_text }) |text| {
        try std.testing.expect(std.mem.find(u8, text, "F1 indexers") != null);
        try std.testing.expect(std.mem.find(u8, text, "F2 ") != null);
    }
}
