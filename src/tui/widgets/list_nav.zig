const std = @import("std");

pub fn moveDown(cursor: *usize, len: usize) bool {
    if (len == 0) return false;
    if (cursor.* < len - 1) {
        cursor.* += 1;
        return true;
    }
    return false;
}

pub fn moveUp(cursor: *usize) bool {
    if (cursor.* > 0) {
        cursor.* -= 1;
        return true;
    }
    return false;
}

pub fn movePageDown(cursor: *usize, len: usize, display_count: usize) bool {
    if (len == 0) return false;
    const step = @min(display_count, len - 1 - cursor.*);
    cursor.* += step;
    return step > 0;
}

pub fn movePageUp(cursor: *usize, display_count: usize) bool {
    const step = @min(display_count, cursor.*);
    cursor.* -= step;
    return step > 0;
}

pub fn adjustScroll(cursor: usize, scroll_offset: *usize, display_count: usize) void {
    if (display_count == 0) return;
    if (cursor < scroll_offset.*) {
        scroll_offset.* = cursor;
    } else if (cursor >= scroll_offset.* + display_count) {
        scroll_offset.* = cursor - display_count + 1;
    }
}

pub fn computeDisplayCount(max_rows: u16) usize {
    return if (max_rows > 7) @as(usize, @intCast(max_rows - 7)) else 1;
}

pub const RenderMode = enum {
    full,
    partial_window,
    partial_cursor,
    none,
};

pub const BaseSnapshot = struct {
    rows: u16,
    cols: u16,
    is_compact: bool,
    cursor: usize,
    scroll_offset: usize,
    display_count: usize,
    item_count: usize,
};

pub fn computeRedrawMode(
    has_drawn_once: bool,
    force_full_redraw: bool,
    force_selected_redraw: bool,
    prev: ?BaseSnapshot,
    current: BaseSnapshot,
    extra_full_tier_changed: bool,
    extra_window_tier_changed: bool,
) RenderMode {
    if (!has_drawn_once or force_full_redraw) return .full;
    if (force_selected_redraw) return .partial_cursor;
    const p = prev orelse return .full;

    if (current.is_compact or p.is_compact) return .full;
    if (p.rows != current.rows or p.cols != current.cols) return .full;
    if (p.display_count != current.display_count) return .full;
    if (p.item_count != current.item_count) return .full;
    if (extra_full_tier_changed) return .full;
    if (extra_window_tier_changed) return .partial_window;
    if (p.scroll_offset != current.scroll_offset) return .partial_window;
    if (p.cursor != current.cursor) return .partial_cursor;
    return .none;
}

test "moveDown advances cursor while below the last index" {
    var cursor: usize = 0;
    try std.testing.expect(moveDown(&cursor, 3));
    try std.testing.expectEqual(@as(usize, 1), cursor);
}

test "moveDown at last index does nothing" {
    var cursor: usize = 2;
    try std.testing.expect(!moveDown(&cursor, 3));
    try std.testing.expectEqual(@as(usize, 2), cursor);
}

test "moveDown on empty list does nothing" {
    var cursor: usize = 0;
    try std.testing.expect(!moveDown(&cursor, 0));
    try std.testing.expectEqual(@as(usize, 0), cursor);
}

test "moveUp retreats cursor while above zero" {
    var cursor: usize = 2;
    try std.testing.expect(moveUp(&cursor));
    try std.testing.expectEqual(@as(usize, 1), cursor);
}

test "moveUp at index 0 does nothing" {
    var cursor: usize = 0;
    try std.testing.expect(!moveUp(&cursor));
    try std.testing.expectEqual(@as(usize, 0), cursor);
}

test "movePageDown clamps at end of list" {
    var cursor: usize = 8;
    try std.testing.expect(movePageDown(&cursor, 10, 5));
    try std.testing.expectEqual(@as(usize, 9), cursor);
}

test "movePageDown on empty list does nothing" {
    var cursor: usize = 0;
    try std.testing.expect(!movePageDown(&cursor, 0, 5));
    try std.testing.expectEqual(@as(usize, 0), cursor);
}

test "movePageUp clamps at start of list" {
    var cursor: usize = 2;
    try std.testing.expect(movePageUp(&cursor, 5));
    try std.testing.expectEqual(@as(usize, 0), cursor);
}

test "movePageUp at index 0 does nothing" {
    var cursor: usize = 0;
    try std.testing.expect(!movePageUp(&cursor, 5));
    try std.testing.expectEqual(@as(usize, 0), cursor);
}

test "adjustScroll scrolls down when cursor leaves window below" {
    var scroll_offset: usize = 0;
    adjustScroll(10, &scroll_offset, 5);
    try std.testing.expectEqual(@as(usize, 6), scroll_offset);
}

test "adjustScroll scrolls up when cursor leaves window above" {
    var scroll_offset: usize = 5;
    adjustScroll(2, &scroll_offset, 5);
    try std.testing.expectEqual(@as(usize, 2), scroll_offset);
}

test "adjustScroll does nothing when display_count is zero" {
    var scroll_offset: usize = 3;
    adjustScroll(10, &scroll_offset, 0);
    try std.testing.expectEqual(@as(usize, 3), scroll_offset);
}

test "computeDisplayCount returns 1 floor for short terminals" {
    try std.testing.expectEqual(@as(usize, 1), computeDisplayCount(5));
    try std.testing.expectEqual(@as(usize, 1), computeDisplayCount(7));
    try std.testing.expectEqual(@as(usize, 13), computeDisplayCount(20));
}

fn testSnapshot() BaseSnapshot {
    return .{
        .rows = 24,
        .cols = 80,
        .is_compact = false,
        .cursor = 0,
        .scroll_offset = 0,
        .display_count = 17,
        .item_count = 5,
    };
}

test "computeRedrawMode full on first draw" {
    try std.testing.expectEqual(RenderMode.full, computeRedrawMode(false, false, false, null, testSnapshot(), false, false));
}

test "computeRedrawMode full when forced" {
    try std.testing.expectEqual(RenderMode.full, computeRedrawMode(true, true, false, testSnapshot(), testSnapshot(), false, false));
}

test "computeRedrawMode partial_cursor when selected redraw forced" {
    try std.testing.expectEqual(RenderMode.partial_cursor, computeRedrawMode(true, false, true, testSnapshot(), testSnapshot(), false, false));
}

test "computeRedrawMode full on resize" {
    const prev = testSnapshot();
    var current = testSnapshot();
    current.cols = 100;
    try std.testing.expectEqual(RenderMode.full, computeRedrawMode(true, false, false, prev, current, false, false));
}

test "computeRedrawMode full on item_count change" {
    const prev = testSnapshot();
    var current = testSnapshot();
    current.item_count = 6;
    try std.testing.expectEqual(RenderMode.full, computeRedrawMode(true, false, false, prev, current, false, false));
}

test "computeRedrawMode full when extra_full_tier_changed" {
    const prev = testSnapshot();
    const current = testSnapshot();
    try std.testing.expectEqual(RenderMode.full, computeRedrawMode(true, false, false, prev, current, true, false));
}

test "computeRedrawMode partial_window on scroll change" {
    const prev = testSnapshot();
    var current = testSnapshot();
    current.scroll_offset = 1;
    try std.testing.expectEqual(RenderMode.partial_window, computeRedrawMode(true, false, false, prev, current, false, false));
}

test "computeRedrawMode partial_window when extra_window_tier_changed" {
    const prev = testSnapshot();
    const current = testSnapshot();
    try std.testing.expectEqual(RenderMode.partial_window, computeRedrawMode(true, false, false, prev, current, false, true));
}

test "computeRedrawMode partial_cursor on cursor change" {
    const prev = testSnapshot();
    var current = testSnapshot();
    current.cursor = 1;
    try std.testing.expectEqual(RenderMode.partial_cursor, computeRedrawMode(true, false, false, prev, current, false, false));
}

test "computeRedrawMode none when nothing changed" {
    const prev = testSnapshot();
    const current = testSnapshot();
    try std.testing.expectEqual(RenderMode.none, computeRedrawMode(true, false, false, prev, current, false, false));
}
