const std = @import("std");
const term = @import("term");

pub const SearchWidget = struct {
    allocator: std.mem.Allocator,
    query: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) SearchWidget {
        return .{
            .allocator = allocator,
            .query = .{},
        };
    }

    pub fn deinit(self: *SearchWidget) void {
        self.query.deinit(self.allocator);
    }

    pub fn render(self: *SearchWidget) void {
        term.moveCursor(1, 1);
        term.clearScreen();
        std.fs.File.stdout().writeAll("[Type in search query. ENTER→search, ESC→exit]: ") catch {};
        std.fs.File.stdout().writeAll(self.query.items) catch {};
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
};

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
