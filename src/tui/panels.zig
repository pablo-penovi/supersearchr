const std = @import("std");
const term = @import("term");
const theme = @import("theme");
const results_widget = @import("results");

pub const RefreshTerminalSizeFn = *const fn (term_rows: *u16, term_cols: *u16) bool;

pub const NoticePanelLayout = struct {
    compact: bool,
    panel_width: usize,
    panel_col: u16,
    top_row: u16,
};

pub fn computeNoticePanelLayout(size: term.TerminalSize) NoticePanelLayout {
    if (theme.isCompactViewport(size.rows, size.cols)) {
        return .{
            .compact = true,
            .panel_width = 0,
            .panel_col = 1,
            .top_row = 1,
        };
    }

    const panel_width = @min(@as(usize, 72), @as(usize, @intCast(size.cols - 4)));
    const left_pad = (@as(usize, @intCast(size.cols)) - panel_width) / 2;
    const top_pad = @max(@as(usize, 2), (@as(usize, @intCast(size.rows)) - 7) / 2);
    return .{
        .compact = false,
        .panel_width = panel_width,
        .panel_col = @as(u16, @intCast(left_pad + 1)),
        .top_row = @as(u16, @intCast(top_pad)),
    };
}

pub fn formatCompactNoticeLine(
    title: []const u8,
    message: []const u8,
    max_cols: usize,
    compact_buf: []u8,
    trunc_buf: []u8,
) []const u8 {
    const compact_line = std.fmt.bufPrint(compact_buf, "{s}: {s}", .{ title, message }) catch title;
    return theme.truncateWithEllipsis(compact_line, @max(@as(usize, 1), max_cols), trunc_buf);
}

pub fn renderResultNoticeOverlay(
    term_rows: *u16,
    term_cols: *u16,
    refresh_terminal_size: RefreshTerminalSizeFn,
    widget: *results_widget.ResultsWidget,
    title: []const u8,
    message: []const u8,
    title_color: u8,
) void {
    term.discardPendingInput();
    var needs_render = true;
    const input_poll_ms: i32 = 80;

    while (true) {
        if (refresh_terminal_size(term_rows, term_cols)) {
            needs_render = true;
        }

        if (needs_render) {
            term.setDimPersistent(true);
            widget.force_full_redraw = true;
            widget.render(term_rows.*, term_cols.*);
            term.setDimPersistent(false);
            renderNoticePanel(title, message, title_color, false);
            needs_render = false;
        }

        const maybe_event = term.readKeyWithTimeout(input_poll_ms) catch return;
        if (maybe_event != null) {
            term.discardPendingInput();
            return;
        }
    }
}

pub fn renderResultErrorOverlay(
    term_rows: *u16,
    term_cols: *u16,
    refresh_terminal_size: RefreshTerminalSizeFn,
    widget: *results_widget.ResultsWidget,
    message: []const u8,
) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Error: {s}", .{message}) catch "Error";
    renderResultNoticeOverlay(term_rows, term_cols, refresh_terminal_size, widget, "Error", msg, theme.superseedr_like.err);
}

pub fn renderError(message: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Error: {s}", .{message}) catch "Error";
    renderNoticePanel("Error", msg, theme.superseedr_like.err, true);
}

pub fn renderNoticePanel(title: []const u8, message: []const u8, title_color: u8, clear_backdrop: bool) void {
    const stdout = std.fs.File.stdout();
    const colors = theme.superseedr_like;
    const border = theme.unicode_border;
    const size = term.getTerminalSize() catch term.TerminalSize{ .rows = 24, .cols = 80 };
    const layout = computeNoticePanelLayout(size);

    if (layout.compact) {
        if (clear_backdrop) {
            term.moveCursor(1, 1);
            term.clearScreen();
        }
        term.moveCursor(1, 1);
        var compact_buf: [256]u8 = undefined;
        var trunc_buf: [256]u8 = undefined;
        const shown = formatCompactNoticeLine(
            title,
            message,
            @as(usize, @intCast(size.cols)),
            compact_buf[0..],
            trunc_buf[0..],
        );
        term.setFg256(title_color);
        term.setBold(true);
        stdout.writeAll(shown) catch {};
        term.setBold(false);
        stdout.writeAll("\r\n") catch {};
        term.setFg256(colors.muted);
        stdout.writeAll("Press any key to continue...") catch {};
        term.resetColor();
        return;
    }

    var trunc_buf: [320]u8 = undefined;
    const shown = theme.truncateWithEllipsis(message, layout.panel_width - 4, trunc_buf[0..]);

    if (clear_backdrop) {
        term.moveCursor(1, 1);
        term.clearScreen();
    }

    term.moveCursor(layout.top_row, layout.panel_col);
    theme.drawPanelTop(stdout, layout.panel_width, border, colors) catch {};

    term.moveCursor(layout.top_row + 1, layout.panel_col);
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.setFg256(title_color);
    term.setBold(true);
    var title_buf: [64]u8 = undefined;
    const title_line = std.fmt.bufPrint(&title_buf, " {s} ", .{title}) catch title;
    theme.writePadded(stdout, title_line, layout.panel_width - 2) catch {};
    term.setBold(false);
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.resetColor();
    stdout.writeAll("\r\n") catch {};

    term.moveCursor(layout.top_row + 2, layout.panel_col);
    var msg_buf: [352]u8 = undefined;
    const message_line = std.fmt.bufPrint(&msg_buf, " {s}", .{shown}) catch shown;
    theme.drawPanelRow(stdout, layout.panel_width, message_line, border, colors) catch {};

    term.moveCursor(layout.top_row + 3, layout.panel_col);
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.setFg256(colors.muted);
    theme.writePadded(stdout, " Press any key to continue... ", layout.panel_width - 2) catch {};
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.resetColor();
    stdout.writeAll("\r\n") catch {};

    term.moveCursor(layout.top_row + 4, layout.panel_col);
    theme.drawPanelBottom(stdout, layout.panel_width, border, colors) catch {};
}

test "computeNoticePanelLayout uses compact mode below breakpoint" {
    const compact = computeNoticePanelLayout(.{ .rows = 9, .cols = 80 });
    try std.testing.expect(compact.compact);
    try std.testing.expectEqual(@as(u16, 1), compact.panel_col);
    try std.testing.expectEqual(@as(u16, 1), compact.top_row);
}

test "computeNoticePanelLayout centers panel in regular mode" {
    const regular = computeNoticePanelLayout(.{ .rows = 24, .cols = 80 });
    try std.testing.expect(!regular.compact);
    try std.testing.expectEqual(@as(usize, 72), regular.panel_width);
    try std.testing.expectEqual(@as(u16, 5), regular.panel_col);
    try std.testing.expectEqual(@as(u16, 8), regular.top_row);
}

test "formatCompactNoticeLine truncates with ellipsis when needed" {
    var compact_buf: [256]u8 = undefined;
    var trunc_buf: [256]u8 = undefined;
    const shown = formatCompactNoticeLine(
        "Error",
        "superseedr not found in PATH",
        20,
        compact_buf[0..],
        trunc_buf[0..],
    );
    try std.testing.expectEqualStrings("Error: superseedr...", shown);
}
