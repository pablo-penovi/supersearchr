const std = @import("std");
const term = @import("term");

pub const compact_cols: u16 = 56;
pub const compact_rows: u16 = 10;

pub const Theme = struct {
    panel_border: u8,
    panel_title: u8,
    text: u8,
    muted: u8,
    accent: u8,
    ok: u8,
    warn: u8,
    err: u8,
    selected_fg: u8,
    selected_bg: u8,
};

pub const BorderChars = struct {
    top_left: []const u8,
    top_right: []const u8,
    bottom_left: []const u8,
    bottom_right: []const u8,
    horizontal: []const u8,
    vertical: []const u8,
};

pub const superseedr_like = Theme{
    .panel_border = 60,
    .panel_title = 111,
    .text = 153,
    .muted = 66,
    .accent = 45,
    .ok = 84,
    .warn = 220,
    .err = 203,
    .selected_fg = 16,
    .selected_bg = 81,
};

pub const unicode_border = BorderChars{
    .top_left = "┏",
    .top_right = "┓",
    .bottom_left = "┗",
    .bottom_right = "┛",
    .horizontal = "━",
    .vertical = "┃",
};

pub fn drawPanelTop(writer: anytype, width: usize, border: BorderChars, colors: Theme) !void {
    if (width < 2) return;
    term.setFg256(colors.panel_border);
    try writer.writeAll(border.top_left);
    try writeRepeat(writer, border.horizontal, width - 2);
    try writer.writeAll(border.top_right);
    term.resetColor();
    try writer.writeAll("\r\n");
}

pub fn drawPanelBottom(writer: anytype, width: usize, border: BorderChars, colors: Theme) !void {
    if (width < 2) return;
    term.setFg256(colors.panel_border);
    try writer.writeAll(border.bottom_left);
    try writeRepeat(writer, border.horizontal, width - 2);
    try writer.writeAll(border.bottom_right);
    term.resetColor();
    try writer.writeAll("\r\n");
}

pub fn drawPanelRow(writer: anytype, width: usize, content: []const u8, border: BorderChars, colors: Theme) !void {
    if (width < 2) return;
    const inner = width - 2;
    term.setFg256(colors.panel_border);
    try writer.writeAll(border.vertical);
    term.setFg256(colors.text);
    try writePadded(writer, content, inner);
    term.setFg256(colors.panel_border);
    try writer.writeAll(border.vertical);
    term.resetColor();
    try writer.writeAll("\r\n");
}

pub fn writeRepeat(writer: anytype, chunk: []const u8, count: usize) !void {
    for (0..count) |_| try writer.writeAll(chunk);
}

pub fn isCompactViewport(rows: u16, cols: u16) bool {
    return cols < compact_cols or rows < compact_rows;
}

fn displayWidth(cp: u21) usize {
    if (cp >= 0x1100 and cp <= 0x115F) return 2;
    if (cp == 0x2329 or cp == 0x232A) return 2;
    if (cp >= 0x2E80 and cp <= 0x303E) return 2;
    if (cp >= 0x3041 and cp <= 0x33BF) return 2;
    if (cp >= 0x33FF and cp <= 0xA4CF) return 2;
    if (cp >= 0xA960 and cp <= 0xA97F) return 2;
    if (cp >= 0xAC00 and cp <= 0xD7FF) return 2;
    if (cp >= 0xF900 and cp <= 0xFAFF) return 2;
    if (cp >= 0xFE10 and cp <= 0xFE1F) return 2;
    if (cp >= 0xFE30 and cp <= 0xFE6F) return 2;
    if (cp >= 0xFF00 and cp <= 0xFF60) return 2;
    if (cp >= 0xFFE0 and cp <= 0xFFE6) return 2;
    if (cp >= 0x1B000 and cp <= 0x1B0FF) return 2;
    if (cp == 0x1F004 or cp == 0x1F0CF) return 2;
    if (cp >= 0x1F300 and cp <= 0x1F9FF) return 2;
    if (cp >= 0x20000 and cp <= 0x2FFFD) return 2;
    if (cp >= 0x30000 and cp <= 0x3FFFD) return 2;
    return 1;
}

fn displayWidthOf(text: []const u8) usize {
    var view = std.unicode.Utf8View.init(text) catch return text.len;
    var iter = view.iterator();
    var width: usize = 0;
    while (iter.nextCodepoint()) |cp| width += displayWidth(cp);
    return width;
}

fn nthColumnByteOffset(text: []const u8, n: usize) usize {
    var view = std.unicode.Utf8View.init(text) catch return @min(n, text.len);
    var iter = view.iterator();
    var byte_pos: usize = 0;
    var cols: usize = 0;
    while (cols < n) {
        const slice = iter.nextCodepointSlice() orelse break;
        const cp = std.unicode.utf8Decode(slice) catch break;
        const w = displayWidth(cp);
        if (cols + w > n) break;
        byte_pos += slice.len;
        cols += w;
    }
    return byte_pos;
}

pub fn displayWidthOfText(text: []const u8) usize {
    return displayWidthOf(text);
}

pub fn sliceByDisplayColumns(text: []const u8, start_col: usize, width: usize, scratch: []u8) []const u8 {
    if (width == 0) return "";
    const total_cols = displayWidthOf(text);
    const clamped_start = @min(start_col, total_cols);
    const start_byte = nthColumnByteOffset(text, clamped_start);
    const end_rel = nthColumnByteOffset(text[start_byte..], width);
    if (end_rel > scratch.len) return text[start_byte..start_byte];
    @memcpy(scratch[0..end_rel], text[start_byte .. start_byte + end_rel]);
    return scratch[0..end_rel];
}

pub fn writePadded(writer: anytype, text: []const u8, width: usize) !void {
    if (width == 0) return;
    const disp_width = displayWidthOf(text);
    if (disp_width >= width) {
        try writer.writeAll(text);
        return;
    }
    try writer.writeAll(text);
    for (0..(width - disp_width)) |_| try writer.writeAll(" ");
}

pub fn truncateWithEllipsis(text: []const u8, width: usize, scratch: []u8) []const u8 {
    if (width == 0) return "";
    const disp_width = displayWidthOf(text);
    if (disp_width <= width) return text;
    if (scratch.len < width) return text;

    if (width <= 3) {
        const end = nthColumnByteOffset(text, width);
        @memcpy(scratch[0..end], text[0..end]);
        return scratch[0..end];
    }

    const keep = width - 3;
    const byte_end = nthColumnByteOffset(text, keep);
    @memcpy(scratch[0..byte_end], text[0..byte_end]);
    @memcpy(scratch[byte_end .. byte_end + 3], "...");
    return scratch[0 .. byte_end + 3];
}

test "truncateWithEllipsis short text unchanged" {
    var buf: [16]u8 = undefined;
    const out = truncateWithEllipsis("abc", 10, &buf);
    try std.testing.expectEqualStrings("abc", out);
}

test "truncateWithEllipsis long text adds dots" {
    var buf: [16]u8 = undefined;
    const out = truncateWithEllipsis("abcdefgh", 6, &buf);
    try std.testing.expectEqualStrings("abc...", out);
}

test "unicode border is heavy box drawing" {
    try std.testing.expectEqualStrings("┏", unicode_border.top_left);
    try std.testing.expectEqualStrings("━", unicode_border.horizontal);
    try std.testing.expectEqualStrings("┃", unicode_border.vertical);
}

test "writePadded pads correctly with multi-byte char" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();
    // "⭐" is 3 bytes, 1 char. Total chars = 4. Pad to 6 → 2 spaces added.
    try writePadded(writer, "abc⭐", 6);
    try std.testing.expectEqualStrings("abc⭐  ", stream.getWritten());
}

test "truncateWithEllipsis handles multi-byte char in kept region" {
    var buf: [32]u8 = undefined;
    // "abc⭐xyz" = 7 chars, truncate to 6 → "abc..."
    const out = truncateWithEllipsis("abc⭐xyz", 6, &buf);
    try std.testing.expectEqualStrings("abc...", out);
}

test "truncateWithEllipsis short text with multi-byte char unchanged" {
    var buf: [32]u8 = undefined;
    const out = truncateWithEllipsis("abc⭐", 10, &buf);
    try std.testing.expectEqualStrings("abc⭐", out);
}

test "displayWidth returns 2 for wide emoji" {
    try std.testing.expectEqual(@as(usize, 2), displayWidth(0x1F31F)); // 🌟
}

test "displayWidth returns 1 for narrow char" {
    try std.testing.expectEqual(@as(usize, 1), displayWidth('A'));
}

test "writePadded pads correctly with wide emoji" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();
    // "🌟" is 4 bytes, 1 codepoint, display width 2. "abc🌟" = 5 display cols. Pad to 8 → 3 spaces.
    try writePadded(writer, "abc🌟", 8);
    try std.testing.expectEqualStrings("abc🌟   ", stream.getWritten());
}

test "truncateWithEllipsis truncates wide emoji correctly" {
    var buf: [32]u8 = undefined;
    // "ab🌟cd" = 2+2+2 = 6 display cols. Truncate to 5 → "ab..." (wide 🌟 overshoots at col 4)
    const out = truncateWithEllipsis("ab🌟cd", 5, &buf);
    try std.testing.expectEqualStrings("ab...", out);
}

test "isCompactViewport uses shared compact breakpoint" {
    try std.testing.expect(isCompactViewport(10, 55));
    try std.testing.expect(isCompactViewport(9, 80));
    try std.testing.expect(!isCompactViewport(10, 56));
}

test "sliceByDisplayColumns returns viewport window by display width" {
    var buf: [32]u8 = undefined;
    const out = sliceByDisplayColumns("ab🌟cd", 2, 3, &buf);
    try std.testing.expectEqualStrings("🌟c", out);
}
