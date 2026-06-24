const std = @import("std");
const term = @import("term");
const theme = @import("theme");
const results_widget = @import("results");
const compat = @import("compat");

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
    const stdout = compat.stdoutWriter();
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

pub fn renderFailedIndexersOverlay(
    term_rows: *u16,
    term_cols: *u16,
    refresh_terminal_size: RefreshTerminalSizeFn,
    widget: *results_widget.ResultsWidget,
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

            drawFailedIndexersModal(widget.failed_indexers.items);
            needs_render = false;
        }

        const maybe_event = term.readKeyWithTimeout(input_poll_ms) catch return;
        if (maybe_event != null) {
            term.discardPendingInput();
            return;
        }
    }
}

fn drawFailedIndexersModal(failed_indexers: []const []const u8) void {
    drawNamedListModal("Failed Indexers", theme.superseedr_like.err, failed_indexers, "Press any key to close");
}

fn drawNamedListModal(title: []const u8, title_color: u8, names: []const []const u8, footer_text: []const u8) void {
    drawLinesModal(title, title_color, names, footer_text, true);
}

/// Draws a centered modal with a title, a list of body lines, and a footer
/// call-to-action. When `bullet` is true each line is prefixed with "• "
/// (used for name lists); otherwise lines are printed verbatim (used for
/// choice prompts).
fn drawLinesModal(
    title: []const u8,
    title_color: u8,
    lines: []const []const u8,
    footer_text: []const u8,
    bullet: bool,
) void {
    const stdout = compat.stdoutWriter();
    const colors = theme.superseedr_like;
    const border = theme.unicode_border;
    const size = term.getTerminalSize() catch term.TerminalSize{ .rows = 24, .cols = 80 };

    const is_compact = theme.isCompactViewport(size.rows, size.cols);
    if (is_compact) {
        term.moveCursor(1, 1);
        term.setFg256(title_color);
        term.setBold(true);
        var title_buf: [64]u8 = undefined;
        const title_line = std.fmt.bufPrint(&title_buf, "{s}:\r\n", .{title}) catch "List:\r\n";
        stdout.writeAll(title_line) catch {};
        term.setBold(false);
        for (lines) |line| {
            term.setFg256(colors.text);
            var item_buf: [160]u8 = undefined;
            const item_line = if (bullet)
                std.fmt.bufPrint(&item_buf, " • {s}\r\n", .{line}) catch line
            else
                std.fmt.bufPrint(&item_buf, "{s}\r\n", .{line}) catch line;
            stdout.writeAll(item_line) catch {};
        }
        term.setFg256(colors.accent);
        stdout.writeAll(footer_text) catch {};
        term.resetColor();
        return;
    }

    const panel_width = @min(@as(usize, 56), @as(usize, @intCast(size.cols - 4)));
    const left_pad = (@as(usize, @intCast(size.cols)) - panel_width) / 2;
    const panel_height = 5 + lines.len;
    const top_pad = @max(@as(usize, 2), (@as(usize, @intCast(size.rows)) - panel_height) / 2);
    const panel_col = @as(u16, @intCast(left_pad + 1));
    const top_row = @as(u16, @intCast(top_pad));

    // Top border
    term.moveCursor(top_row, panel_col);
    theme.drawPanelTop(stdout, panel_width, border, colors) catch {};

    // Title row
    term.moveCursor(top_row + 1, panel_col);
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.setFg256(title_color);
    term.setBold(true);
    var title_buf: [64]u8 = undefined;
    const title_line = std.fmt.bufPrint(&title_buf, " {s} ", .{title}) catch title;
    theme.writePadded(stdout, title_line, panel_width - 2) catch {};
    term.setBold(false);
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.resetColor();
    stdout.writeAll("\r\n") catch {};

    // Body lines
    for (lines, 0..) |line, idx| {
        term.moveCursor(top_row + 2 + @as(u16, @intCast(idx)), panel_col);
        var item_buf: [160]u8 = undefined;
        const item_line = if (bullet)
            std.fmt.bufPrint(&item_buf, " • {s}", .{line}) catch line
        else
            std.fmt.bufPrint(&item_buf, " {s}", .{line}) catch line;
        theme.drawPanelRow(stdout, panel_width, item_line, border, colors) catch {};
    }

    // Footer row
    const footer_row = top_row + 2 + @as(u16, @intCast(lines.len));
    term.moveCursor(footer_row, panel_col);
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.setFg256(colors.accent); // Call-to-action color
    var footer_buf: [80]u8 = undefined;
    const footer_line = std.fmt.bufPrint(&footer_buf, " {s} ", .{footer_text}) catch footer_text;
    theme.writePadded(stdout, footer_line, panel_width - 2) catch {};
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.resetColor();
    stdout.writeAll("\r\n") catch {};

    // Bottom border
    term.moveCursor(footer_row + 1, panel_col);
    theme.drawPanelBottom(stdout, panel_width, border, colors) catch {};
}

/// Dims and re-renders a backdrop widget. Works with widgets that take
/// `render(rows, cols)` (indexers/profiles) and ones that take `render()`.
fn renderDimmedBackdrop(backdrop: anytype, rows: u16, cols: u16) void {
    term.setDimPersistent(true);
    if (comptime @hasField(@TypeOf(backdrop.*), "force_full_redraw")) {
        backdrop.force_full_redraw = true;
        backdrop.render(rows, cols);
    } else {
        backdrop.has_drawn_once = false;
        backdrop.render();
    }
    term.setDimPersistent(false);
}

pub const ProfileModifiedAction = enum { save_existing, new_profile, discard, cancel };

fn matchModifiedKey(event: term.Event) ?ProfileModifiedAction {
    return switch (event.key) {
        .escape => .cancel,
        .char => switch (event.value) {
            's', 'S' => .save_existing,
            'n', 'N' => .new_profile,
            'd', 'D' => .discard,
            else => null,
        },
        else => null,
    };
}

/// F2 warning shown when the live tracker set differs from the active profile.
pub fn renderProfileModifiedOverlay(
    term_rows: *u16,
    term_cols: *u16,
    refresh_terminal_size: RefreshTerminalSizeFn,
    backdrop: anytype,
) ProfileModifiedAction {
    term.discardPendingInput();
    var needs_render = true;
    const input_poll_ms: i32 = 80;
    const lines = [_][]const u8{
        "Live trackers differ from the active profile.",
        "(s) save changes to active profile",
        "(n) save as a new profile",
        "(d) discard and continue",
    };

    while (true) {
        if (refresh_terminal_size(term_rows, term_cols)) needs_render = true;
        if (needs_render) {
            renderDimmedBackdrop(backdrop, term_rows.*, term_cols.*);
            drawLinesModal("Trackers Modified", theme.superseedr_like.warn, &lines, "Esc cancel", false);
            needs_render = false;
        }
        const maybe_event = term.readKeyWithTimeout(input_poll_ms) catch return .cancel;
        if (maybe_event) |event| {
            if (matchModifiedKey(event)) |action| return action;
        }
    }
}

pub const ProfileSaveChoiceAction = enum { overwrite, new_profile, cancel };

fn matchSaveChoiceKey(event: term.Event) ?ProfileSaveChoiceAction {
    return switch (event.key) {
        .escape => .cancel,
        .char => switch (event.value) {
            'o', 'O' => .overwrite,
            'n', 'N' => .new_profile,
            else => null,
        },
        else => null,
    };
}

/// F3 prompt shown when the committed set differs from the active profile.
pub fn renderProfileSaveChoiceOverlay(
    term_rows: *u16,
    term_cols: *u16,
    refresh_terminal_size: RefreshTerminalSizeFn,
    backdrop: anytype,
) ProfileSaveChoiceAction {
    term.discardPendingInput();
    var needs_render = true;
    const input_poll_ms: i32 = 80;
    const lines = [_][]const u8{
        "(o) overwrite the active profile",
        "(n) save as a new profile",
    };

    while (true) {
        if (refresh_terminal_size(term_rows, term_cols)) needs_render = true;
        if (needs_render) {
            renderDimmedBackdrop(backdrop, term_rows.*, term_cols.*);
            drawLinesModal("Save Profile", theme.superseedr_like.accent, &lines, "Esc cancel", false);
            needs_render = false;
        }
        const maybe_event = term.readKeyWithTimeout(input_poll_ms) catch return .cancel;
        if (maybe_event) |event| {
            if (matchSaveChoiceKey(event)) |action| return action;
        }
    }
}

pub const ProfileUncommittedAction = enum { include, discard, cancel };

fn matchUncommittedKey(event: term.Event) ?ProfileUncommittedAction {
    return switch (event.key) {
        .escape => .cancel,
        .char => switch (event.value) {
            'i', 'I' => .include,
            'd', 'D' => .discard,
            else => null,
        },
        else => null,
    };
}

/// F3 prompt shown when the Indexers screen has uncommitted toggles.
pub fn renderProfileUncommittedOverlay(
    term_rows: *u16,
    term_cols: *u16,
    refresh_terminal_size: RefreshTerminalSizeFn,
    backdrop: anytype,
    pending_names: []const []const u8,
) ProfileUncommittedAction {
    term.discardPendingInput();
    var needs_render = true;
    const input_poll_ms: i32 = 80;

    while (true) {
        if (refresh_terminal_size(term_rows, term_cols)) needs_render = true;
        if (needs_render) {
            renderDimmedBackdrop(backdrop, term_rows.*, term_cols.*);
            drawNamedListModal(
                "Uncommitted Changes",
                theme.superseedr_like.warn,
                pending_names,
                "(i) commit & include  (d) discard  Esc cancel",
            );
            needs_render = false;
        }
        const maybe_event = term.readKeyWithTimeout(input_poll_ms) catch return .cancel;
        if (maybe_event) |event| {
            if (matchUncommittedKey(event)) |action| return action;
        }
    }
}

pub const NamePromptResult = union(enum) {
    name: []u8,
    cancel,
};

/// Text-input modal for naming a profile. Returns an allocator-owned name
/// (caller frees) or `.cancel`. If the typed name collides with an existing
/// one, the first ENTER arms an overwrite (shows a hint); a second ENTER on
/// the same name confirms. Editing the text disarms.
pub fn renderProfileNamePromptOverlay(
    allocator: std.mem.Allocator,
    term_rows: *u16,
    term_cols: *u16,
    refresh_terminal_size: RefreshTerminalSizeFn,
    backdrop: anytype,
    existing_names: []const []const u8,
) !NamePromptResult {
    term.discardPendingInput();
    defer term.hideCursor();
    var input = std.ArrayList(u8).empty;
    defer input.deinit(allocator);

    var armed_overwrite = false;
    var needs_render = true;
    const input_poll_ms: i32 = 80;

    while (true) {
        if (refresh_terminal_size(term_rows, term_cols)) needs_render = true;
        if (needs_render) {
            term.hideCursor();
            renderDimmedBackdrop(backdrop, term_rows.*, term_cols.*);
            drawNamePromptModal(input.items, armed_overwrite);
            needs_render = false;
        }

        const maybe_event = term.readKeyWithTimeout(input_poll_ms) catch return .cancel;
        if (maybe_event) |event| {
            switch (event.key) {
                .char, .digit => {
                    try input.append(allocator, event.value);
                    armed_overwrite = false;
                    needs_render = true;
                },
                .backspace => {
                    if (input.items.len > 0) _ = input.pop();
                    armed_overwrite = false;
                    needs_render = true;
                },
                .shift_backspace => {
                    input.clearRetainingCapacity();
                    armed_overwrite = false;
                    needs_render = true;
                },
                .enter => {
                    const trimmed = std.mem.trim(u8, input.items, " ");
                    if (trimmed.len == 0) continue;
                    const collides = nameExists(existing_names, trimmed);
                    if (collides and !armed_overwrite) {
                        armed_overwrite = true;
                        needs_render = true;
                        continue;
                    }
                    return .{ .name = try allocator.dupe(u8, trimmed) };
                },
                .escape => return .cancel,
                else => {},
            }
        }
    }
}

fn nameExists(existing_names: []const []const u8, name: []const u8) bool {
    for (existing_names) |existing| {
        if (std.mem.eql(u8, existing, name)) return true;
    }
    return false;
}

fn drawNamePromptModal(query: []const u8, armed_overwrite: bool) void {
    const stdout = compat.stdoutWriter();
    const colors = theme.superseedr_like;
    const border = theme.unicode_border;
    const size = term.getTerminalSize() catch term.TerminalSize{ .rows = 24, .cols = 80 };

    const is_compact = theme.isCompactViewport(size.rows, size.cols);
    if (is_compact) {
        term.moveCursor(1, 1);
        term.setFg256(colors.accent);
        term.setBold(true);
        stdout.writeAll("Profile name:\r\n") catch {};
        term.setBold(false);
        term.setFg256(colors.text);
        var input_buf: [128]u8 = undefined;
        const input_line = std.fmt.bufPrint(&input_buf, "> {s}\r\n", .{query}) catch "> ";
        stdout.writeAll(input_line) catch {};
        term.setFg256(colors.muted);
        if (armed_overwrite) {
            stdout.writeAll("Name exists - Enter to overwrite\r\n") catch {};
        } else {
            stdout.writeAll("ENTER save | ESC cancel\r\n") catch {};
        }
        term.resetColor();
        const compact_cursor_col_usize = @min(@as(usize, @intCast(size.cols)), 3 + theme.displayWidthOfText(query));
        term.moveCursor(2, @as(u16, @intCast(compact_cursor_col_usize)));
        term.showCursor();
        return;
    }

    const panel_width = @min(@as(usize, 56), @as(usize, @intCast(size.cols - 4)));
    const left_pad = (@as(usize, @intCast(size.cols)) - panel_width) / 2;
    const panel_height = 5;
    const top_pad = @max(@as(usize, 2), (@as(usize, @intCast(size.rows)) - panel_height) / 2);
    const panel_col = @as(u16, @intCast(left_pad + 1));
    const top_row = @as(u16, @intCast(top_pad));

    // Top border
    term.moveCursor(top_row, panel_col);
    theme.drawPanelTop(stdout, panel_width, border, colors) catch {};

    // Title row
    term.moveCursor(top_row + 1, panel_col);
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.setFg256(colors.panel_title);
    term.setBold(true);
    theme.writePadded(stdout, " Profile name ", panel_width - 2) catch {};
    term.setBold(false);
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.resetColor();
    stdout.writeAll("\r\n") catch {};

    // Input row
    term.moveCursor(top_row + 2, panel_col);
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.setFg256(colors.text);
    var input_buf: [256]u8 = undefined;
    const input_text = std.fmt.bufPrint(&input_buf, " Name: {s}", .{query}) catch " Name: ";
    const disp_w = theme.displayWidthOfText(input_text);
    stdout.writeAll(input_text) catch {};
    if (disp_w < panel_width - 2) {
        for (0..(panel_width - 2 - disp_w)) |_| stdout.writeAll(" ") catch {};
    }
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.resetColor();
    stdout.writeAll("\r\n") catch {};

    // Help/status row
    term.moveCursor(top_row + 3, panel_col);
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    if (armed_overwrite) {
        term.setFg256(colors.warn);
        theme.writePadded(stdout, " Name exists - press Enter again to overwrite ", panel_width - 2) catch {};
    } else {
        term.setFg256(colors.muted);
        theme.writePadded(stdout, " Press ENTER to save | ESC to cancel ", panel_width - 2) catch {};
    }
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.resetColor();
    stdout.writeAll("\r\n") catch {};

    // Bottom border
    term.moveCursor(top_row + 4, panel_col);
    theme.drawPanelBottom(stdout, panel_width, border, colors) catch {};

    const prompt_len = theme.displayWidthOfText(" Name: ");
    const cursor_col = panel_col + 1 + prompt_len + theme.displayWidthOfText(query);
    term.moveCursor(top_row + 2, @as(u16, @intCast(cursor_col)));
    term.showCursor();
}

/// Confirms deletion of a profile. ENTER confirms, Esc (or any other key) aborts.
pub fn renderProfileDeleteConfirmOverlay(
    term_rows: *u16,
    term_cols: *u16,
    refresh_terminal_size: RefreshTerminalSizeFn,
    backdrop: anytype,
    profile_name: []const u8,
) bool {
    term.discardPendingInput();
    var needs_render = true;
    const input_poll_ms: i32 = 80;

    while (true) {
        if (refresh_terminal_size(term_rows, term_cols)) needs_render = true;
        if (needs_render) {
            renderDimmedBackdrop(backdrop, term_rows.*, term_cols.*);
            var line_buf: [160]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "Delete profile \"{s}\"?", .{profile_name}) catch "Delete this profile?";
            const lines = [_][]const u8{line};
            drawLinesModal("Confirm Delete", theme.superseedr_like.err, &lines, "ENTER delete | ESC cancel", false);
            needs_render = false;
        }
        const maybe_event = term.readKeyWithTimeout(input_poll_ms) catch return false;
        if (maybe_event) |event| {
            if (event.key == .enter) return true;
            if (event.key == .escape) return false;
        }
    }
}

/// Generic dismissable notice over an arbitrary backdrop (e.g. "Saved").
pub fn renderInfoNoticeOverlay(
    term_rows: *u16,
    term_cols: *u16,
    refresh_terminal_size: RefreshTerminalSizeFn,
    backdrop: anytype,
    title: []const u8,
    message: []const u8,
    title_color: u8,
) void {
    term.discardPendingInput();
    var needs_render = true;
    const input_poll_ms: i32 = 80;

    while (true) {
        if (refresh_terminal_size(term_rows, term_cols)) needs_render = true;
        if (needs_render) {
            renderDimmedBackdrop(backdrop, term_rows.*, term_cols.*);
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

/// Dismissable modal listing profile-apply failures.
pub fn renderProfileApplyFailuresOverlay(
    term_rows: *u16,
    term_cols: *u16,
    refresh_terminal_size: RefreshTerminalSizeFn,
    backdrop: anytype,
    failed_names: []const []const u8,
) void {
    term.discardPendingInput();
    var needs_render = true;
    const input_poll_ms: i32 = 80;

    while (true) {
        if (refresh_terminal_size(term_rows, term_cols)) needs_render = true;
        if (needs_render) {
            renderDimmedBackdrop(backdrop, term_rows.*, term_cols.*);
            drawNamedListModal("Failed to Apply", theme.superseedr_like.err, failed_names, "Press any key to close");
            needs_render = false;
        }
        const maybe_event = term.readKeyWithTimeout(input_poll_ms) catch return;
        if (maybe_event != null) {
            term.discardPendingInput();
            return;
        }
    }
}

pub const SaveFailuresAction = enum { retry, revert };

pub fn renderIndexerSaveFailuresOverlay(
    term_rows: *u16,
    term_cols: *u16,
    refresh_terminal_size: RefreshTerminalSizeFn,
    widget: anytype,
    failed_names: []const []const u8,
) SaveFailuresAction {
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

            drawNamedListModal("Failed to Save", theme.superseedr_like.err, failed_names, "r retry failed | ESC discard failed");
            needs_render = false;
        }

        const maybe_event = term.readKeyWithTimeout(input_poll_ms) catch return .revert;
        if (maybe_event) |event| {
            term.discardPendingInput();
            if (event.key == .char and (event.value == 'r' or event.value == 'R')) return .retry;
            if (event.key == .escape) return .revert;
        }
    }
}

pub fn renderExitConfirmationOverlay(
    term_rows: *u16,
    term_cols: *u16,
    refresh_terminal_size: RefreshTerminalSizeFn,
    context: anytype,
) bool {
    term.discardPendingInput();
    var needs_render = true;
    const input_poll_ms: i32 = 80;

    while (true) {
        if (refresh_terminal_size(term_rows, term_cols)) {
            needs_render = true;
        }

        if (needs_render) {
            term.setDimPersistent(true);
            if (comptime @hasField(@TypeOf(context.*), "force_full_redraw")) {
                context.force_full_redraw = true;
                context.render(term_rows.*, term_cols.*);
            } else {
                context.has_drawn_once = false;
                context.render();
            }
            term.setDimPersistent(false);

            drawExitConfirmationModal();
            needs_render = false;
        }

        const maybe_event = term.readKeyWithTimeout(input_poll_ms) catch return false;
        if (maybe_event) |event| {
            term.discardPendingInput();
            if (event.key == .escape) {
                return true;
            } else {
                return false;
            }
        }
    }
}

fn drawExitConfirmationModal() void {
    const stdout = compat.stdoutWriter();
    const colors = theme.superseedr_like;
    const border = theme.unicode_border;
    const size = term.getTerminalSize() catch term.TerminalSize{ .rows = 24, .cols = 80 };

    const is_compact = theme.isCompactViewport(size.rows, size.cols);
    if (is_compact) {
        term.moveCursor(1, 1);
        term.setFg256(colors.err);
        term.setBold(true);
        stdout.writeAll("Exit Confirmation:\r\n") catch {};
        term.setBold(false);
        term.setFg256(colors.text);
        stdout.writeAll("Press ESC again to exit,\r\n") catch {};
        stdout.writeAll("any other key to cancel.\r\n") catch {};
        term.resetColor();
        return;
    }

    const panel_width = @min(@as(usize, 52), @as(usize, @intCast(size.cols - 4)));
    const left_pad = (@as(usize, @intCast(size.cols)) - panel_width) / 2;
    const panel_height = 5;
    const top_pad = @max(@as(usize, 2), (@as(usize, @intCast(size.rows)) - panel_height) / 2);
    const panel_col = @as(u16, @intCast(left_pad + 1));
    const top_row = @as(u16, @intCast(top_pad));

    // Top border
    term.moveCursor(top_row, panel_col);
    theme.drawPanelTop(stdout, panel_width, border, colors) catch {};

    // Title row
    term.moveCursor(top_row + 1, panel_col);
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.setFg256(colors.err);
    term.setBold(true);
    var title_buf: [64]u8 = undefined;
    const title_line = std.fmt.bufPrint(&title_buf, " Exit Confirmation ", .{}) catch " Exit Confirmation ";
    theme.writePadded(stdout, title_line, panel_width - 2) catch {};
    term.setBold(false);
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.resetColor();
    stdout.writeAll("\r\n") catch {};

    // Message row 1
    term.moveCursor(top_row + 2, panel_col);
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.setFg256(colors.text);
    theme.writePadded(stdout, " Press ESC again to exit, ", panel_width - 2) catch {};
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.resetColor();
    stdout.writeAll("\r\n") catch {};

    // Message row 2
    term.moveCursor(top_row + 3, panel_col);
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.setFg256(colors.muted);
    theme.writePadded(stdout, " any other key to cancel. ", panel_width - 2) catch {};
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.resetColor();
    stdout.writeAll("\r\n") catch {};

    // Bottom border
    term.moveCursor(top_row + 4, panel_col);
    theme.drawPanelBottom(stdout, panel_width, border, colors) catch {};
}

pub const BackgroundUpdateContext = struct {
    ptr: ?*anyopaque,
    update_fn: *const fn (ptr: ?*anyopaque) anyerror!BackgroundUpdateDelta,
};

pub const BackgroundUpdateDelta = struct {
    backdrop_changed: bool = false,
    status_changed: bool = false,
};

pub fn renderListSearchOverlay(
    term_rows: *u16,
    term_cols: *u16,
    refresh_terminal_size: RefreshTerminalSizeFn,
    widget: *results_widget.ResultsWidget,
    bg_update: ?BackgroundUpdateContext,
) !void {
    term.discardPendingInput();
    defer term.hideCursor();
    var query_buf = std.ArrayList(u8).empty;
    defer query_buf.deinit(widget.allocator);

    var needs_backdrop_render = true;
    var needs_modal_render = true;
    var force_backdrop_full_redraw = true;
    const input_poll_ms: i32 = 80;

    while (true) {
        if (refresh_terminal_size(term_rows, term_cols)) {
            needs_backdrop_render = true;
            needs_modal_render = true;
            force_backdrop_full_redraw = true;
        }

        if (bg_update) |bg| {
            if (bg.update_fn(bg.ptr)) |delta| {
                if (delta.backdrop_changed) {
                    needs_backdrop_render = true;
                    needs_modal_render = true;
                } else if (delta.status_changed and !needs_backdrop_render and !needs_modal_render) {
                    term.beginSyncRender();
                    term.setDimPersistent(true);
                    const rendered_status_only = widget.renderStatusOnly(term_rows.*, term_cols.*);
                    term.setDimPersistent(false);
                    if (!rendered_status_only) {
                        needs_backdrop_render = true;
                        needs_modal_render = true;
                    } else {
                        drawListSearchModal(query_buf.items);
                    }
                    term.endSyncRender();
                }
            } else |err| {
                return err;
            }
        }

        if (needs_backdrop_render or needs_modal_render) {
            term.beginSyncRender();
            term.hideCursor();

            if (needs_backdrop_render) {
                if (force_backdrop_full_redraw) {
                    widget.force_full_redraw = true;
                    force_backdrop_full_redraw = false;
                }

                term.setDimPersistent(true);
                widget.render(term_rows.*, term_cols.*);
                term.setDimPersistent(false);
                needs_backdrop_render = false;
                needs_modal_render = true;
            }

            if (needs_modal_render) {
                drawListSearchModal(query_buf.items);
                needs_modal_render = false;
            }

            term.endSyncRender();
        }

        const maybe_event = term.readKeyWithTimeout(input_poll_ms) catch return;
        if (maybe_event) |event| {
            switch (event.key) {
                .char, .digit => {
                    try query_buf.append(widget.allocator, event.value);
                    needs_modal_render = true;
                },
                .backspace => {
                    if (query_buf.items.len > 0) {
                        _ = query_buf.pop();
                    }
                    needs_modal_render = true;
                },
                .shift_backspace => {
                    query_buf.clearRetainingCapacity();
                    needs_modal_render = true;
                },
                .enter => {
                    var non_space_count: usize = 0;
                    for (query_buf.items) |c| {
                        if (c != ' ') non_space_count += 1;
                    }
                    if (non_space_count >= 2) {
                        try widget.applyListSearch(query_buf.items);
                        return;
                    }
                },
                .escape => {
                    return;
                },
                else => {},
            }
        }
    }
}

fn drawListSearchModal(query: []const u8) void {
    const stdout = compat.stdoutWriter();
    const colors = theme.superseedr_like;
    const border = theme.unicode_border;
    const size = term.getTerminalSize() catch term.TerminalSize{ .rows = 24, .cols = 80 };

    const is_compact = theme.isCompactViewport(size.rows, size.cols);

    var non_space_count: usize = 0;
    for (query) |c| {
        if (c != ' ') non_space_count += 1;
    }
    const unlocked = (non_space_count >= 2);

    if (is_compact) {
        term.moveCursor(1, 1);
        term.setFg256(colors.accent);
        term.setBold(true);
        stdout.writeAll("Search in results:\r\n") catch {};
        term.setBold(false);
        term.setFg256(colors.text);
        var input_buf: [128]u8 = undefined;
        const input_line = std.fmt.bufPrint(&input_buf, "> {s}\r\n", .{query}) catch "> ";
        stdout.writeAll(input_line) catch {};
        term.setFg256(colors.muted);
        if (unlocked) {
            stdout.writeAll("ENTER search | ESC cancel\r\n") catch {};
        } else {
            stdout.writeAll("Type >= 2 chars...\r\n") catch {};
        }
        term.resetColor();
        const compact_cursor_col_usize = @min(@as(usize, @intCast(size.cols)), 3 + theme.displayWidthOfText(query));
        const compact_cursor_col = @as(u16, @intCast(compact_cursor_col_usize));
        term.moveCursor(2, compact_cursor_col);
        term.showCursor();
        return;
    }

    const panel_width = @min(@as(usize, 52), @as(usize, @intCast(size.cols - 4)));
    const left_pad = (@as(usize, @intCast(size.cols)) - panel_width) / 2;
    const panel_height = 5;
    const top_pad = @max(@as(usize, 2), (@as(usize, @intCast(size.rows)) - panel_height) / 2);
    const panel_col = @as(u16, @intCast(left_pad + 1));
    const top_row = @as(u16, @intCast(top_pad));

    // Top border
    term.moveCursor(top_row, panel_col);
    theme.drawPanelTop(stdout, panel_width, border, colors) catch {};

    // Title row
    term.moveCursor(top_row + 1, panel_col);
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.setFg256(colors.panel_title);
    term.setBold(true);
    var title_buf: [64]u8 = undefined;
    const title_line = std.fmt.bufPrint(&title_buf, " Search in results ", .{}) catch " Search in results ";
    theme.writePadded(stdout, title_line, panel_width - 2) catch {};
    term.setBold(false);
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.resetColor();
    stdout.writeAll("\r\n") catch {};

    // Input row
    term.moveCursor(top_row + 2, panel_col);
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};

    term.setFg256(colors.text);
    var input_buf: [256]u8 = undefined;
    const input_text = std.fmt.bufPrint(&input_buf, " Search: {s}", .{query}) catch " Search: ";

    const disp_w = theme.displayWidthOfText(input_text);
    stdout.writeAll(input_text) catch {};
    if (disp_w < panel_width - 2) {
        const remaining = panel_width - 2 - disp_w;
        for (0..remaining) |_| stdout.writeAll(" ") catch {};
    }

    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.resetColor();
    stdout.writeAll("\r\n") catch {};

    // Help/status row
    term.moveCursor(top_row + 3, panel_col);
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};

    if (unlocked) {
        term.setFg256(colors.accent);
        theme.writePadded(stdout, " Press ENTER to search | ESC to cancel ", panel_width - 2) catch {};
    } else {
        term.setFg256(colors.muted);
        theme.writePadded(stdout, " Type at least 2 characters to search ", panel_width - 2) catch {};
    }

    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.resetColor();
    stdout.writeAll("\r\n") catch {};

    // Bottom border
    term.moveCursor(top_row + 4, panel_col);
    theme.drawPanelBottom(stdout, panel_width, border, colors) catch {};

    const prompt_len = theme.displayWidthOfText(" Search: ");
    const cursor_col = panel_col + 1 + prompt_len + theme.displayWidthOfText(query);
    term.moveCursor(top_row + 2, @as(u16, @intCast(cursor_col)));
    term.showCursor();
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

test "matchModifiedKey maps letters and escape, ignores others" {
    try std.testing.expectEqual(ProfileModifiedAction.save_existing, matchModifiedKey(.{ .key = .char, .value = 's' }).?);
    try std.testing.expectEqual(ProfileModifiedAction.new_profile, matchModifiedKey(.{ .key = .char, .value = 'n' }).?);
    try std.testing.expectEqual(ProfileModifiedAction.discard, matchModifiedKey(.{ .key = .char, .value = 'd' }).?);
    try std.testing.expectEqual(ProfileModifiedAction.discard, matchModifiedKey(.{ .key = .char, .value = 'D' }).?);
    try std.testing.expectEqual(ProfileModifiedAction.cancel, matchModifiedKey(.{ .key = .escape, .value = 0 }).?);
    try std.testing.expect(matchModifiedKey(.{ .key = .char, .value = 'x' }) == null);
    try std.testing.expect(matchModifiedKey(.{ .key = .enter, .value = 0 }) == null);
}

test "matchSaveChoiceKey maps o/n and escape" {
    try std.testing.expectEqual(ProfileSaveChoiceAction.overwrite, matchSaveChoiceKey(.{ .key = .char, .value = 'o' }).?);
    try std.testing.expectEqual(ProfileSaveChoiceAction.new_profile, matchSaveChoiceKey(.{ .key = .char, .value = 'n' }).?);
    try std.testing.expectEqual(ProfileSaveChoiceAction.cancel, matchSaveChoiceKey(.{ .key = .escape, .value = 0 }).?);
    try std.testing.expect(matchSaveChoiceKey(.{ .key = .char, .value = 'd' }) == null);
}

test "matchUncommittedKey maps i/d and escape" {
    try std.testing.expectEqual(ProfileUncommittedAction.include, matchUncommittedKey(.{ .key = .char, .value = 'i' }).?);
    try std.testing.expectEqual(ProfileUncommittedAction.discard, matchUncommittedKey(.{ .key = .char, .value = 'd' }).?);
    try std.testing.expectEqual(ProfileUncommittedAction.cancel, matchUncommittedKey(.{ .key = .escape, .value = 0 }).?);
    try std.testing.expect(matchUncommittedKey(.{ .key = .char, .value = 'z' }) == null);
}

test "nameExists matches case-sensitively" {
    const names = [_][]const u8{ "Anime", "Movies" };
    try std.testing.expect(nameExists(&names, "Anime"));
    try std.testing.expect(!nameExists(&names, "anime"));
    try std.testing.expect(!nameExists(&names, "Books"));
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
