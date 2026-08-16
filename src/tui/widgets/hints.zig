const std = @import("std");
const theme = @import("theme");
const list_nav = @import("list_nav");

/// Scrolling key-hints footer.
///
/// The hints row sits on the last terminal line, so a hint string wider than
/// the terminal wraps and pushes the whole panel up by one row. Instead of
/// letting that happen, the row shows a window over the hints and slides it
/// back and forth, exactly like the marquee used for over-long torrent titles.

/// Blank columns kept to the left of the hints text inside the panel layout.
pub const panel_indent_cols: usize = 2;

/// The compact layout draws flush against the left edge.
pub const compact_indent_cols: usize = 0;

/// One column is left unwritten at the right edge: writing the final cell of
/// the final row makes some terminals scroll.
const right_margin_cols: usize = 1;

const edge_hold_ticks: u8 = 2;

/// Widest hint string the scratch buffer can hold. Hints are short, fixed
/// strings; this only bounds the window copied out for rendering.
const scratch_bytes: usize = 512;

/// Columns available to the hints text itself on a terminal `max_cols` wide.
pub fn availableCols(max_cols: u16, indent_cols: usize) usize {
    const cols: usize = @intCast(max_cols);
    if (cols <= indent_cols + right_margin_cols) return 0;
    return cols - indent_cols - right_margin_cols;
}

/// Terminal row the hints footer is drawn on: below the panel bottom, and
/// never past the last row.
pub fn rowFromDisplayCount(display_count: usize, max_rows: u16) u16 {
    const row = 7 + display_count;
    if (row >= @as(usize, max_rows)) return max_rows;
    return @intCast(row);
}

pub const HintsMarquee = struct {
    offset_cols: usize = 0,
    moving_right: bool = true,
    edge_hold: u8 = 0,
    target_set: bool = false,
    target_text: []const u8 = &.{},
    target_width: usize = 0,
    /// Set when `advance` moved the window; cleared once the row is redrawn.
    dirty: bool = false,

    pub fn reset(self: *HintsMarquee) void {
        self.* = .{};
    }

    /// Restarts the scroll whenever the hint string or the available width
    /// changes, so a new footer always starts from its first column.
    fn ensureTarget(self: *HintsMarquee, text: []const u8, avail_cols: usize) void {
        if (self.target_set and self.target_width == avail_cols and std.mem.eql(u8, self.target_text, text)) {
            return;
        }
        self.target_set = true;
        self.target_text = text;
        self.target_width = avail_cols;
        self.offset_cols = 0;
        self.moving_right = true;
        self.edge_hold = edge_hold_ticks;
    }

    /// Steps the window one column on a footer that owns the terminal row.
    /// Returns true when the visible slice changed and the row needs a repaint.
    pub fn advance(self: *HintsMarquee, text: []const u8, max_cols: u16, indent_cols: usize) bool {
        return self.advanceIn(text, availableCols(max_cols, indent_cols));
    }

    /// Steps the window one column inside an arbitrary `avail_cols`-wide slot,
    /// for hints drawn within a panel frame rather than on a bare row.
    pub fn advanceIn(self: *HintsMarquee, text: []const u8, avail_cols: usize) bool {
        if (avail_cols == 0) return false;
        self.ensureTarget(text, avail_cols);

        const text_cols = theme.displayWidthOfText(text);
        if (text_cols <= avail_cols) return false;

        const overflow = text_cols - avail_cols;
        if (self.offset_cols > overflow) {
            self.offset_cols = overflow;
            self.dirty = true;
            return true;
        }

        if (list_nav.stepMarqueeState(
            &self.offset_cols,
            &self.moving_right,
            &self.edge_hold,
            overflow,
            edge_hold_ticks,
        )) {
            self.dirty = true;
            return true;
        }
        return false;
    }

    /// The portion of `text` visible at the current offset, without the indent.
    pub fn visibleSlice(self: *HintsMarquee, text: []const u8, max_cols: u16, indent_cols: usize, scratch: []u8) []const u8 {
        return self.visibleSliceIn(text, availableCols(max_cols, indent_cols), scratch);
    }

    /// The visible window inside an arbitrary `avail_cols`-wide slot.
    pub fn visibleSliceIn(self: *HintsMarquee, text: []const u8, avail_cols: usize, scratch: []u8) []const u8 {
        if (avail_cols == 0) return "";
        self.ensureTarget(text, avail_cols);

        const text_cols = theme.displayWidthOfText(text);
        if (text_cols <= avail_cols) return text;

        const overflow = text_cols - avail_cols;
        const offset_cols = @min(self.offset_cols, overflow);
        return theme.sliceByDisplayColumns(text, offset_cols, avail_cols, scratch);
    }

    /// Writes the indent plus the visible window. Callers are expected to clear
    /// the rest of the row afterwards.
    pub fn draw(self: *HintsMarquee, writer: anytype, text: []const u8, max_cols: u16, indent_cols: usize) void {
        self.dirty = false;
        const avail_cols = availableCols(max_cols, indent_cols);
        if (avail_cols == 0) return;

        var scratch: [scratch_bytes]u8 = undefined;
        const shown = self.visibleSliceIn(text, avail_cols, scratch[0..]);
        for (0..indent_cols) |_| writer.writeAll(" ") catch {};
        writer.writeAll(shown) catch {};
    }

    /// Writes the visible window padded out to `avail_cols`, for hints that sit
    /// inside a panel frame and must not disturb the closing border.
    pub fn drawPaddedIn(self: *HintsMarquee, writer: anytype, text: []const u8, avail_cols: usize) void {
        self.dirty = false;
        if (avail_cols == 0) return;

        var scratch: [scratch_bytes]u8 = undefined;
        const shown = self.visibleSliceIn(text, avail_cols, scratch[0..]);
        theme.writePadded(writer, shown, avail_cols) catch {};
    }
};

const test_hints = "ENTER select | s search | ESC exit";

test "availableCols leaves room for the indent and the right margin" {
    try std.testing.expectEqual(@as(usize, 77), availableCols(80, panel_indent_cols));
    try std.testing.expectEqual(@as(usize, 0), availableCols(3, panel_indent_cols));
    try std.testing.expectEqual(@as(usize, 0), availableCols(1, panel_indent_cols));
}

test "rowFromDisplayCount sits below the panel and never past the last row" {
    try std.testing.expectEqual(@as(u16, 24), rowFromDisplayCount(17, 24));
    try std.testing.expectEqual(@as(u16, 12), rowFromDisplayCount(99, 12));
}

test "visibleSlice returns the full text when it fits" {
    var marquee: HintsMarquee = .{};
    var scratch: [128]u8 = undefined;
    const out = marquee.visibleSlice(test_hints, 80, panel_indent_cols, scratch[0..]);
    try std.testing.expectEqualStrings(test_hints, out);
}

test "visibleSlice windows the text when it overflows" {
    var marquee: HintsMarquee = .{};
    var scratch: [128]u8 = undefined;
    const cols: u16 = 20;
    const out = marquee.visibleSlice(test_hints, cols, panel_indent_cols, scratch[0..]);
    try std.testing.expectEqual(availableCols(cols, panel_indent_cols), theme.displayWidthOfText(out));
    try std.testing.expectEqualStrings(test_hints[0..availableCols(cols, panel_indent_cols)], out);
}

test "advance does nothing while the hints fit" {
    var marquee: HintsMarquee = .{};
    try std.testing.expect(!marquee.advance(test_hints, 80, panel_indent_cols));
    try std.testing.expectEqual(@as(usize, 0), marquee.offset_cols);
    try std.testing.expect(!marquee.dirty);
}

test "advance scrolls an overflowing hints bar and bounces back" {
    var marquee: HintsMarquee = .{};
    const cols: u16 = 20;
    const overflow = theme.displayWidthOfText(test_hints) - availableCols(cols, panel_indent_cols);

    // The first ticks are consumed by the leading edge hold.
    for (0..edge_hold_ticks) |_| try std.testing.expect(!marquee.advance(test_hints, cols, panel_indent_cols));

    for (0..overflow) |_| try std.testing.expect(marquee.advance(test_hints, cols, panel_indent_cols));
    try std.testing.expectEqual(overflow, marquee.offset_cols);
    try std.testing.expect(marquee.dirty);

    // At the right edge it pauses, flips, then walks back to the start.
    try std.testing.expect(!marquee.advance(test_hints, cols, panel_indent_cols));
    for (0..edge_hold_ticks) |_| try std.testing.expect(!marquee.advance(test_hints, cols, panel_indent_cols));
    for (0..overflow) |_| try std.testing.expect(marquee.advance(test_hints, cols, panel_indent_cols));
    try std.testing.expectEqual(@as(usize, 0), marquee.offset_cols);
}

test "advance restarts when the hint text changes" {
    var marquee: HintsMarquee = .{};
    const cols: u16 = 20;
    for (0..edge_hold_ticks + 3) |_| _ = marquee.advance(test_hints, cols, panel_indent_cols);
    try std.testing.expect(marquee.offset_cols > 0);

    _ = marquee.advance("ENTER select | s search | r refresh | ESC exit", cols, panel_indent_cols);
    try std.testing.expectEqual(@as(usize, 0), marquee.offset_cols);
}

test "advance clamps the offset when the terminal widens" {
    var marquee: HintsMarquee = .{};
    const narrow: u16 = 20;
    for (0..edge_hold_ticks + 5) |_| _ = marquee.advance(test_hints, narrow, panel_indent_cols);
    const offset_before = marquee.offset_cols;
    try std.testing.expect(offset_before > 0);

    // Same text, wider terminal: the target resets rather than keeping an
    // offset that would scroll past the end.
    _ = marquee.advance(test_hints, 34, panel_indent_cols);
    try std.testing.expectEqual(@as(usize, 0), marquee.offset_cols);
}

test "draw writes the indent plus the visible window" {
    var marquee: HintsMarquee = .{};
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    marquee.draw(&writer, test_hints, 80, panel_indent_cols);
    try std.testing.expectEqualStrings("  " ++ test_hints, writer.buffered());
}

test "draw never exceeds the terminal width" {
    var marquee: HintsMarquee = .{};
    var buf: [256]u8 = undefined;
    const cols: u16 = 24;
    var writer: std.Io.Writer = .fixed(&buf);
    marquee.draw(&writer, test_hints, cols, panel_indent_cols);
    try std.testing.expect(theme.displayWidthOfText(writer.buffered()) < cols);
}

test "draw clears the dirty flag" {
    var marquee: HintsMarquee = .{};
    const cols: u16 = 20;
    for (0..edge_hold_ticks + 1) |_| _ = marquee.advance(test_hints, cols, panel_indent_cols);
    try std.testing.expect(marquee.dirty);

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    marquee.draw(&writer, test_hints, cols, panel_indent_cols);
    try std.testing.expect(!marquee.dirty);
}

test "compact layout drops the indent and gets the columns back" {
    try std.testing.expectEqual(@as(usize, 55), availableCols(56, compact_indent_cols));

    var marquee: HintsMarquee = .{};
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    marquee.draw(&writer, test_hints, 56, compact_indent_cols);
    try std.testing.expectEqualStrings(test_hints, writer.buffered());
}

test "drawPaddedIn fills the slot exactly, scrolled or not" {
    var marquee: HintsMarquee = .{};
    var buf: [256]u8 = undefined;

    var wide: std.Io.Writer = .fixed(&buf);
    marquee.drawPaddedIn(&wide, test_hints, 40);
    try std.testing.expectEqual(@as(usize, 40), theme.displayWidthOfText(wide.buffered()));

    marquee.reset();
    var narrow: std.Io.Writer = .fixed(&buf);
    marquee.drawPaddedIn(&narrow, test_hints, 20);
    try std.testing.expectEqual(@as(usize, 20), theme.displayWidthOfText(narrow.buffered()));
}

test "advanceIn scrolls inside a panel slot" {
    var marquee: HintsMarquee = .{};
    const avail: usize = 20;
    for (0..edge_hold_ticks) |_| try std.testing.expect(!marquee.advanceIn(test_hints, avail));
    try std.testing.expect(marquee.advanceIn(test_hints, avail));
    try std.testing.expectEqual(@as(usize, 1), marquee.offset_cols);
}

test "draw writes nothing on a terminal with no room" {
    var marquee: HintsMarquee = .{};
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    marquee.draw(&writer, test_hints, 2, panel_indent_cols);
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
}
