const std = @import("std");
const term = @import("term");

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

pub fn writePadded(writer: anytype, text: []const u8, width: usize) !void {
    if (width == 0) return;
    if (text.len >= width) {
        try writer.writeAll(text[0..width]);
        return;
    }

    try writer.writeAll(text);
    for (0..(width - text.len)) |_| try writer.writeAll(" ");
}

pub fn truncateWithEllipsis(text: []const u8, width: usize, scratch: []u8) []const u8 {
    if (width == 0) return "";
    if (text.len <= width) return text;
    if (scratch.len < width) return text[0..width];

    if (width <= 3) {
        @memcpy(scratch[0..width], text[0..width]);
        return scratch[0..width];
    }

    const keep = width - 3;
    @memcpy(scratch[0..keep], text[0..keep]);
    @memcpy(scratch[keep..width], "...");
    return scratch[0..width];
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
