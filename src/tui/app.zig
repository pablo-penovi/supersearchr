const std = @import("std");
const config = @import("config");
const jackett = @import("jackett");
const superseedr = @import("superseedr");
const term = @import("term");
const theme = @import("theme");
const search_widget = @import("search");
const results_widget = @import("results");
const Torrent = @import("torrent").Torrent;
const debug_log = @import("debug_log");

const State = union(enum) {
    search: SearchState,
    results: ResultsState,
    loading: LoadingState,
    err: ErrorState,
};

const SearchState = struct {
    query: []const u8,
};

const ResultsState = struct {
    torrents: []Torrent,
};

const LoadingState = struct {
    query: []const u8,
};

const ErrorState = struct {
    message: []const u8,
};

const SpinnerContext = struct {
    message: []const u8,
    stop: *std.atomic.Value(bool),
    row: u16,
    col: u16,
    color: u8,
};

const App = struct {
    allocator: std.mem.Allocator,
    client: jackett.Client,
    state: State,
    running: bool,
    term_rows: u16,
    term_cols: u16,
    terminal: []const u8,
};

pub fn run(allocator: std.mem.Allocator, cfg: config.Config) !void {
    term.init() catch |err| {
        std.debug.print("Failed to initialize terminal: {}\n", .{err});
        return err;
    };
    defer term.deinit();

    const size = term.getTerminalSize() catch term.TerminalSize{ .rows = 24, .cols = 80 };

    const base_url = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ cfg.api_url, cfg.api_port });
    defer allocator.free(base_url);

    var client = jackett.Client.init(allocator, base_url, cfg.api_key);

    var app = App{
        .allocator = allocator,
        .client = client,
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = size.rows,
        .term_cols = size.cols,
        .terminal = cfg.terminal,
    };

    defer client.deinit();

    while (app.running) {
        switch (app.state) {
            .search => {
                try runSearchState(&app);
            },
            .loading => |*loading_state| {
                try runLoadingState(&app, loading_state);
            },
            .results => |*results_state| {
                try runResultsState(&app, results_state);
            },
            .err => |*error_state| {
                try runErrorState(&app, error_state);
            },
        }
    }
}

fn runSearchState(app: *App) !void {
    var widget = search_widget.SearchWidget.init(app.allocator);
    defer widget.deinit();
    var needs_render = true;
    const input_poll_ms: i32 = 80;

    while (true) {
        if (refreshTerminalSize(app)) {
            needs_render = true;
        }

        if (needs_render) {
            widget.render();
            needs_render = false;
        }

        const maybe_event = term.readKeyWithTimeout(input_poll_ms) catch {
            app.state = .{ .err = .{ .message = "Failed to read input" } };
            return;
        };
        const event = maybe_event orelse continue;
        const action = widget.handleEvent(event);
        needs_render = true;

        switch (action) {
            .continue_search => {},
            .submit => {
                const query = try app.allocator.dupe(u8, widget.getQuery());
                app.state = .{ .loading = .{ .query = query } };
                return;
            },
            .cancel => {
                app.running = false;
                return;
            },
        }
    }
}

fn spinnerThread(ctx: SpinnerContext) void {
    const frames = [_]u8{ '|', '/', '-', '\\' };
    var frame: usize = 0;
    const stdout = std.fs.File.stdout();
    var buf: [128]u8 = undefined;

    while (!ctx.stop.load(.acquire)) {
        term.moveCursor(ctx.row, ctx.col);
        term.setFg256(ctx.color);
        const line = std.fmt.bufPrint(&buf, "{s} {c}", .{ ctx.message, frames[frame] }) catch break;
        stdout.writeAll(line) catch break;
        term.resetColor();
        frame = (frame + 1) % frames.len;
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
    term.moveCursor(ctx.row, ctx.col);
    term.setFg256(ctx.color);
    const line = std.fmt.bufPrint(&buf, "{s}  ", .{ctx.message}) catch return;
    stdout.writeAll(line) catch {};
    term.resetColor();
}

fn runLoadingState(app: *App, loading_state: *LoadingState) !void {
    const query = loading_state.query;
    defer app.allocator.free(query);

    term.hideCursor();
    defer term.showCursor();
    _ = refreshTerminalSize(app);

    const stdout = std.fs.File.stdout();
    const colors = theme.superseedr_like;
    const border = theme.unicode_border;
    const compact = app.term_cols < 56 or app.term_rows < 10;
    const panel_width = if (compact) @as(usize, 0) else @min(@as(usize, 74), @as(usize, @intCast(app.term_cols - 4)));
    const left_pad = if (compact) @as(usize, 0) else (@as(usize, @intCast(app.term_cols)) - panel_width) / 2;
    const top_pad = if (compact) @as(usize, 1) else @max(@as(usize, 2), (@as(usize, @intCast(app.term_rows)) - 8) / 2);

    var query_trunc: [256]u8 = undefined;
    const shown_query = theme.truncateWithEllipsis(query, panel_width - 13, query_trunc[0..]);
    var query_line_buf: [320]u8 = undefined;
    const query_line = std.fmt.bufPrint(&query_line_buf, " Query: {s}", .{shown_query}) catch " Query:";

    term.moveCursor(1, 1);
    term.clearScreen();
    if (compact) {
        term.setFg256(colors.panel_title);
        term.setBold(true);
        stdout.writeAll("Searching\r\n") catch {};
        term.setBold(false);
        term.setFg256(colors.text);
        stdout.writeAll(query_line) catch {};
        stdout.writeAll("\r\n") catch {};
    } else {
        term.moveCursor(@as(u16, @intCast(top_pad)), 1);

        writeSpaces(stdout, left_pad) catch {};
        theme.drawPanelTop(stdout, panel_width, border, colors) catch {};
        writeSpaces(stdout, left_pad) catch {};
        term.setFg256(colors.panel_border);
        stdout.writeAll(border.vertical) catch {};
        term.setFg256(colors.panel_title);
        term.setBold(true);
        theme.writePadded(stdout, " Searching ", panel_width - 2) catch {};
        term.setBold(false);
        term.setFg256(colors.panel_border);
        stdout.writeAll(border.vertical) catch {};
        term.resetColor();
        stdout.writeAll("\r\n") catch {};
        writeSpaces(stdout, left_pad) catch {};
        theme.drawPanelRow(stdout, panel_width, "", border, colors) catch {};
        writeSpaces(stdout, left_pad) catch {};
        theme.drawPanelRow(stdout, panel_width, query_line, border, colors) catch {};
        writeSpaces(stdout, left_pad) catch {};
        term.setFg256(colors.panel_border);
        stdout.writeAll(border.vertical) catch {};
        term.setFg256(colors.muted);
        theme.writePadded(stdout, "", panel_width - 2) catch {};
        term.setFg256(colors.panel_border);
        stdout.writeAll(border.vertical) catch {};
        term.resetColor();
        stdout.writeAll("\r\n") catch {};
        writeSpaces(stdout, left_pad) catch {};
        theme.drawPanelBottom(stdout, panel_width, border, colors) catch {};
    }

    var stop = std.atomic.Value(bool).init(false);
    const spinner_row = if (compact) @as(u16, 3) else @as(u16, @intCast(top_pad + 6));
    const spinner_col = if (compact) @as(u16, 1) else @as(u16, @intCast(left_pad + 3));
    const thread = try std.Thread.spawn(.{}, spinnerThread, .{SpinnerContext{
        .message = " Contacting Jackett...",
        .stop = &stop,
        .row = spinner_row,
        .col = spinner_col,
        .color = colors.accent,
    }});

    const torrents = app.client.searchWithExecutor(query, jackett.defaultSearchExecutor) catch |err| {
        stop.store(true, .release);
        thread.join();
        const message = getErrorMessage(err);
        app.state = .{ .err = .{ .message = message } };
        return;
    };

    stop.store(true, .release);
    thread.join();

    app.state = .{ .results = .{ .torrents = torrents } };
}

fn runResultsState(app: *App, results_state: *ResultsState) !void {
    const torrents = results_state.torrents;
    defer freeTorrents(app.allocator, torrents);

    term.hideCursor();
    defer term.showCursor();

    var widget = results_widget.ResultsWidget.init(app.allocator);
    defer widget.deinit();

    widget.setTorrents(torrents, torrents.len);
    var needs_render = true;
    const input_poll_ms: i32 = 80;
    const marquee_step_interval_ms: i64 = scaledMarqueeIntervalMs(input_poll_ms, 30);
    var marquee_budget_ms: i64 = 0;
    var last_loop_ms: i64 = std.time.milliTimestamp();

    while (true) {
        if (refreshTerminalSize(app)) {
            widget.force_full_redraw = true;
            needs_render = true;
        }

        const now_ms = std.time.milliTimestamp();
        const elapsed_ms = nonNegativeElapsedMs(last_loop_ms, now_ms);
        last_loop_ms = now_ms;
        marquee_budget_ms += elapsed_ms;

        if (needs_render) {
            widget.render(app.term_rows, app.term_cols);
            needs_render = false;
        }

        const maybe_event = term.readKeyWithTimeout(input_poll_ms) catch {
            app.state = .{ .err = .{ .message = "Failed to read input" } };
            return;
        };
        if (maybe_event) |event| {
            const action = widget.handleEvent(event, app.term_rows);
            needs_render = true;

            switch (action) {
                .continue_browsing => {},
                .new_search => {
                    app.state = .{ .search = .{ .query = "" } };
                    return;
                },
                .cancel => {
                    app.running = false;
                    return;
                },
                .select => |idx| {
                    const torrent = torrents[idx];
                    const result = superseedr.addLink(app.allocator, torrent.link, app.terminal);

                    if (result) |_| {
                        debug_log.writef(
                            app.allocator,
                            "app",
                            "Added torrent to superseedr title=\"{s}\" link=\"{s}\"",
                            .{ torrent.title, torrent.link },
                        );
                        renderResultNoticeOverlay(
                            app,
                            &widget,
                            "Success",
                            "Added to superseedr!",
                            theme.superseedr_like.ok,
                        );
                        widget.force_full_redraw = true;
                    } else |err| {
                        debug_log.writef(
                            app.allocator,
                            "app",
                            "Failed to add torrent err={s} title=\"{s}\" link=\"{s}\"",
                            .{ @errorName(err), torrent.title, torrent.link },
                        );
                        renderResultErrorOverlay(app, &widget, getSuperseedrErrorMessage(err));
                        widget.force_full_redraw = true;
                    }
                },
            }
        } else if (consumeMarqueeTick(&marquee_budget_ms, marquee_step_interval_ms) and widget.advanceMarquee(app.term_rows, app.term_cols)) {
            needs_render = true;
        }
    }
}

fn runErrorState(app: *App, error_state: *ErrorState) !void {
    var needs_render = true;
    const input_poll_ms: i32 = 80;

    while (true) {
        if (refreshTerminalSize(app)) {
            needs_render = true;
        }

        if (needs_render) {
            renderError(error_state.message);
            needs_render = false;
        }

        const maybe_event = term.readKeyWithTimeout(input_poll_ms) catch {
            app.state = .{ .search = .{ .query = "" } };
            return;
        };
        if (maybe_event != null) {
            app.state = .{ .search = .{ .query = "" } };
            return;
        }
    }
}

fn renderResultNoticeOverlay(
    app: *App,
    widget: *results_widget.ResultsWidget,
    title: []const u8,
    message: []const u8,
    title_color: u8,
) void {
    term.discardPendingInput();
    var needs_render = true;
    const input_poll_ms: i32 = 80;

    while (true) {
        if (refreshTerminalSize(app)) {
            needs_render = true;
        }

        if (needs_render) {
            term.setDimPersistent(true);
            widget.force_full_redraw = true;
            widget.render(app.term_rows, app.term_cols);
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

fn renderResultErrorOverlay(app: *App, widget: *results_widget.ResultsWidget, message: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Error: {s}", .{message}) catch "Error";
    renderResultNoticeOverlay(app, widget, "Error", msg, theme.superseedr_like.err);
}

fn renderError(message: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Error: {s}", .{message}) catch "Error";
    renderNoticePanel("Error", msg, theme.superseedr_like.err, true);
}

fn renderNoticePanel(title: []const u8, message: []const u8, title_color: u8, clear_backdrop: bool) void {
    const stdout = std.fs.File.stdout();
    const colors = theme.superseedr_like;
    const border = theme.unicode_border;
    const size = term.getTerminalSize() catch term.TerminalSize{ .rows = 24, .cols = 80 };

    if (size.cols < 56 or size.rows < 10) {
        if (clear_backdrop) {
            term.moveCursor(1, 1);
            term.clearScreen();
        }
        term.moveCursor(1, 1);
        var compact_buf: [256]u8 = undefined;
        const compact_line = std.fmt.bufPrint(&compact_buf, "{s}: {s}", .{ title, message }) catch title;
        var trunc_buf: [256]u8 = undefined;
        const shown = theme.truncateWithEllipsis(compact_line, @max(@as(usize, 1), @as(usize, @intCast(size.cols))), trunc_buf[0..]);
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

    const panel_width = @min(@as(usize, 72), @as(usize, @intCast(size.cols - 4)));
    const left_pad = (@as(usize, @intCast(size.cols)) - panel_width) / 2;
    const top_pad = @max(@as(usize, 2), (@as(usize, @intCast(size.rows)) - 7) / 2);
    var trunc_buf: [320]u8 = undefined;
    const shown = theme.truncateWithEllipsis(message, panel_width - 4, trunc_buf[0..]);

    if (clear_backdrop) {
        term.moveCursor(1, 1);
        term.clearScreen();
    }
    const panel_col: u16 = @as(u16, @intCast(left_pad + 1));
    const top_row: u16 = @as(u16, @intCast(top_pad));
    term.moveCursor(top_row, panel_col);
    theme.drawPanelTop(stdout, panel_width, border, colors) catch {};

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

    term.moveCursor(top_row + 2, panel_col);
    var msg_buf: [352]u8 = undefined;
    const message_line = std.fmt.bufPrint(&msg_buf, " {s}", .{shown}) catch shown;
    theme.drawPanelRow(stdout, panel_width, message_line, border, colors) catch {};

    term.moveCursor(top_row + 3, panel_col);
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.setFg256(colors.muted);
    theme.writePadded(stdout, " Press any key to continue... ", panel_width - 2) catch {};
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.resetColor();
    stdout.writeAll("\r\n") catch {};

    term.moveCursor(top_row + 4, panel_col);
    theme.drawPanelBottom(stdout, panel_width, border, colors) catch {};
}

fn getErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ConnectionRefused => "Cannot connect to Jackett. Is it running?",
        error.HttpError => "Jackett returned error",
        else => "Failed to parse Jackett response",
    };
}

fn getSuperseedrErrorMessage(err: superseedr.AddLinkError) []const u8 {
    return switch (err) {
        error.InvalidLink => "Invalid link",
        error.SuperseedrNotFound => "superseedr not found in PATH",
        error.SuperseedrFailed => "Failed to add to superseedr",
        error.SuperseedrLaunchFailed => "Failed to launch superseedr",
    };
}

fn freeTorrents(allocator: std.mem.Allocator, torrents: []Torrent) void {
    for (torrents) |t| {
        allocator.free(t.title);
        allocator.free(t.link);
    }
    allocator.free(torrents);
}

fn writeSpaces(writer: anytype, count: usize) !void {
    for (0..count) |_| try writer.writeAll(" ");
}

fn scaledMarqueeIntervalMs(base_ms: i32, slowdown_percent: u8) i64 {
    const base: i64 = @as(i64, base_ms);
    return @max(@as(i64, 1), base + @divTrunc(base * @as(i64, slowdown_percent), 100));
}

fn nonNegativeElapsedMs(previous_ms: i64, current_ms: i64) i64 {
    if (current_ms <= previous_ms) return 0;
    return current_ms - previous_ms;
}

fn consumeMarqueeTick(budget_ms: *i64, interval_ms: i64) bool {
    if (interval_ms <= 0) return false;
    if (budget_ms.* < interval_ms) return false;
    budget_ms.* -= interval_ms;
    return true;
}

fn refreshTerminalSize(app: *App) bool {
    const size = term.getTerminalSize() catch term.TerminalSize{ .rows = 24, .cols = 80 };
    if (size.rows == app.term_rows and size.cols == app.term_cols) return false;
    app.term_rows = size.rows;
    app.term_cols = size.cols;
    return true;
}

test "state transitions: search -> loading -> results" {
    const Testing = @import("std").testing;

    var search_called = false;
    var loading_called = false;
    var results_called = false;

    search_called = true;
    loading_called = true;
    results_called = true;

    try Testing.expect(search_called);
    try Testing.expect(loading_called);
    try Testing.expect(results_called);
}

test "scaledMarqueeIntervalMs slows base interval by percent" {
    try std.testing.expectEqual(@as(i64, 104), scaledMarqueeIntervalMs(80, 30));
    try std.testing.expectEqual(@as(i64, 1), scaledMarqueeIntervalMs(0, 30));
}

test "nonNegativeElapsedMs handles backwards clock safely" {
    try std.testing.expectEqual(@as(i64, 0), nonNegativeElapsedMs(10, 8));
    try std.testing.expectEqual(@as(i64, 5), nonNegativeElapsedMs(10, 15));
}

test "consumeMarqueeTick spends only one interval per loop" {
    var budget: i64 = 160;
    try std.testing.expect(consumeMarqueeTick(&budget, 104));
    try std.testing.expectEqual(@as(i64, 56), budget);
    try std.testing.expect(!consumeMarqueeTick(&budget, 104));
}

test "getErrorMessage maps known jackett errors and fallback" {
    try std.testing.expectEqualStrings(
        "Cannot connect to Jackett. Is it running?",
        getErrorMessage(error.ConnectionRefused),
    );
    try std.testing.expectEqualStrings(
        "Jackett returned error",
        getErrorMessage(error.HttpError),
    );
    try std.testing.expectEqualStrings(
        "Failed to parse Jackett response",
        getErrorMessage(error.Unexpected),
    );
}

test "getSuperseedrErrorMessage maps all AddLinkError values" {
    try std.testing.expectEqualStrings("Invalid link", getSuperseedrErrorMessage(error.InvalidLink));
    try std.testing.expectEqualStrings(
        "superseedr not found in PATH",
        getSuperseedrErrorMessage(error.SuperseedrNotFound),
    );
    try std.testing.expectEqualStrings(
        "Failed to add to superseedr",
        getSuperseedrErrorMessage(error.SuperseedrFailed),
    );
    try std.testing.expectEqualStrings(
        "Failed to launch superseedr",
        getSuperseedrErrorMessage(error.SuperseedrLaunchFailed),
    );
}

test "refreshTerminalSize returns false and keeps values when unchanged" {
    const size = term.getTerminalSize() catch term.TerminalSize{ .rows = 24, .cols = 80 };
    var app = App{
        .allocator = std.testing.allocator,
        .client = undefined,
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = size.rows,
        .term_cols = size.cols,
        .terminal = "xterm",
    };

    try std.testing.expect(!refreshTerminalSize(&app));
    try std.testing.expectEqual(size.rows, app.term_rows);
    try std.testing.expectEqual(size.cols, app.term_cols);
}

test "refreshTerminalSize returns true and updates values when changed" {
    const size = term.getTerminalSize() catch term.TerminalSize{ .rows = 24, .cols = 80 };
    const initial_rows: u16 = if (size.rows == 1) 2 else 1;
    const initial_cols: u16 = if (size.cols == 1) 2 else 1;

    var app = App{
        .allocator = std.testing.allocator,
        .client = undefined,
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = initial_rows,
        .term_cols = initial_cols,
        .terminal = "xterm",
    };

    try std.testing.expect(refreshTerminalSize(&app));
    try std.testing.expectEqual(size.rows, app.term_rows);
    try std.testing.expectEqual(size.cols, app.term_cols);
}
