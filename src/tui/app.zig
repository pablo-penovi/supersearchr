const std = @import("std");
const config = @import("config");
const jackett = @import("jackett");
const superseedr = @import("superseedr");
const term = @import("term");
const theme = @import("theme");
const panels = @import("panels");
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

const AppDeps = struct {
    jackett_search_executor: *const fn (allocator: std.mem.Allocator, url: []const u8) jackett.JackettError![]Torrent = jackett.defaultSearchExecutor,
    superseedr_executor: *const fn (allocator: std.mem.Allocator, argv: []const []const u8) anyerror!void = superseedr.defaultExecutor,
    superseedr_process_checker: *const fn (allocator: std.mem.Allocator) anyerror!bool = superseedr.defaultProcessChecker,
    superseedr_spawner: *const fn (allocator: std.mem.Allocator, terminal: []const u8) anyerror!void = superseedr.defaultSpawner,
};

const App = struct {
    allocator: std.mem.Allocator,
    client: jackett.Client,
    deps: AppDeps,
    state: State,
    running: bool,
    term_rows: u16,
    term_cols: u16,
    terminal: []const u8,
};

pub fn run(allocator: std.mem.Allocator, cfg: config.Config) !void {
    return runWithDeps(allocator, cfg, .{});
}

pub fn runWithDeps(allocator: std.mem.Allocator, cfg: config.Config, deps: AppDeps) !void {
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
        .deps = deps,
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
    const compact = theme.isCompactViewport(app.term_rows, app.term_cols);
    const panel_width = if (compact) @as(usize, 0) else @min(@as(usize, 74), @as(usize, @intCast(app.term_cols - 4)));
    const left_pad = if (compact) @as(usize, 0) else (@as(usize, @intCast(app.term_cols)) - panel_width) / 2;
    const top_pad = if (compact) @as(usize, 1) else @max(@as(usize, 2), (@as(usize, @intCast(app.term_rows)) - 8) / 2);

    var query_trunc: [256]u8 = undefined;
    const query_width = loadingQueryWidth(app.term_cols, panel_width, compact);
    const shown_query = theme.truncateWithEllipsis(query, query_width, query_trunc[0..]);
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

    transitionLoadingToNextState(app, query);
    stop.store(true, .release);
    thread.join();
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
                    const result = addLinkWithAppDeps(app, torrent.link);

                    if (result) |_| {
                        debug_log.writef(
                            app.allocator,
                            "app",
                            "Added torrent to superseedr title=\"{s}\" link=\"{s}\"",
                            .{ torrent.title, torrent.link },
                        );
                        panels.renderResultNoticeOverlay(
                            &app.term_rows,
                            &app.term_cols,
                            refreshTerminalSizeValues,
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
                        panels.renderResultErrorOverlay(
                            &app.term_rows,
                            &app.term_cols,
                            refreshTerminalSizeValues,
                            &widget,
                            getSuperseedrErrorMessage(err),
                        );
                        widget.force_full_redraw = true;
                    }
                },
            }
        } else if (consumeMarqueeTick(&marquee_budget_ms, marquee_step_interval_ms) and widget.advanceMarquee(app.term_rows, app.term_cols)) {
            needs_render = true;
        }
    }
}

fn searchWithAppDeps(app: *App, query: []const u8) jackett.JackettError![]Torrent {
    return app.client.searchWithExecutor(query, app.deps.jackett_search_executor);
}

fn addLinkWithAppDeps(app: *App, link: []const u8) superseedr.AddLinkError!void {
    return superseedr.addLinkWithAllDeps(
        app.allocator,
        link,
        app.terminal,
        app.deps.superseedr_executor,
        app.deps.superseedr_process_checker,
        app.deps.superseedr_spawner,
    );
}

fn transitionLoadingToNextState(app: *App, query: []const u8) void {
    const torrents = searchWithAppDeps(app, query) catch |err| {
        app.state = .{ .err = .{ .message = getErrorMessage(err) } };
        return;
    };
    app.state = .{ .results = .{ .torrents = torrents } };
}

fn runErrorState(app: *App, error_state: *ErrorState) !void {
    var needs_render = true;
    const input_poll_ms: i32 = 80;

    while (true) {
        if (refreshTerminalSize(app)) {
            needs_render = true;
        }

        if (needs_render) {
            panels.renderError(error_state.message);
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

fn getErrorMessage(err: jackett.JackettError) []const u8 {
    return switch (err) {
        error.ConnectionRefused => "Cannot connect to Jackett. Is it running?",
        error.InvalidUrl => "Invalid Jackett URL in config",
        error.RequestCreateFailed => "Failed to create Jackett request",
        error.RequestSendFailed => "Failed to send Jackett request",
        error.ResponseHeadReadFailed => "Failed to read Jackett response headers",
        error.HttpError => "Jackett returned error",
        error.ResponseReadFailed => "Failed to read Jackett response",
        error.ParseFailed => "Failed to parse Jackett response",
        error.OutOfMemory => "Out of memory while processing Jackett response",
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
    return refreshTerminalSizeValues(&app.term_rows, &app.term_cols);
}

fn refreshTerminalSizeValues(term_rows: *u16, term_cols: *u16) bool {
    const size = term.getTerminalSize() catch term.TerminalSize{ .rows = 24, .cols = 80 };
    if (size.rows == term_rows.* and size.cols == term_cols.*) return false;
    term_rows.* = size.rows;
    term_cols.* = size.cols;
    return true;
}

fn loadingQueryWidth(term_cols: u16, panel_width: usize, compact: bool) usize {
    if (compact) {
        const cols: usize = @as(usize, @intCast(term_cols));
        if (cols <= 8) return 1;
        return cols - 8;
    }
    if (panel_width <= 13) return 1;
    return panel_width - 13;
}

test "state transitions smoke path search -> loading -> results with injected deps" {
    const mock = struct {
        fn exec(allocator: std.mem.Allocator, url: []const u8) jackett.JackettError![]Torrent {
            if (std.mem.indexOf(u8, url, "q=ubuntu") == null) return error.ParseFailed;

            var torrents: []Torrent = try allocator.alloc(Torrent, 1);
            torrents[0] = .{
                .title = try allocator.dupe(u8, "Ubuntu ISO"),
                .seeders = 120,
                .leechers = 4,
                .link = try allocator.dupe(u8, "magnet:?xt=urn:btih:abc"),
            };
            return torrents;
        }
    };

    var app = App{
        .allocator = std.testing.allocator,
        .client = jackett.Client.init(std.testing.allocator, "http://localhost:9117", "test-key"),
        .deps = .{
            .jackett_search_executor = mock.exec,
        },
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
    };

    const query = try std.testing.allocator.dupe(u8, "ubuntu");
    defer std.testing.allocator.free(query);

    app.state = .{ .loading = .{ .query = query } };
    transitionLoadingToNextState(&app, query);

    switch (app.state) {
        .results => |results_state| {
            defer freeTorrents(std.testing.allocator, results_state.torrents);
            try std.testing.expectEqual(@as(usize, 1), results_state.torrents.len);
            try std.testing.expectEqualStrings("Ubuntu ISO", results_state.torrents[0].title);
        },
        else => return error.UnexpectedState,
    }
}

test "state transitions smoke path loading failure goes to error" {
    const mock = struct {
        fn exec(_: std.mem.Allocator, _: []const u8) jackett.JackettError![]Torrent {
            return error.ConnectionRefused;
        }
    };

    var app = App{
        .allocator = std.testing.allocator,
        .client = jackett.Client.init(std.testing.allocator, "http://localhost:9117", "test-key"),
        .deps = .{
            .jackett_search_executor = mock.exec,
        },
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
    };

    const query = try std.testing.allocator.dupe(u8, "ubuntu");
    defer std.testing.allocator.free(query);

    app.state = .{ .loading = .{ .query = query } };
    transitionLoadingToNextState(&app, query);

    switch (app.state) {
        .err => |error_state| try std.testing.expectEqualStrings(
            "Cannot connect to Jackett. Is it running?",
            error_state.message,
        ),
        else => return error.UnexpectedState,
    }
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

test "getErrorMessage exhaustively maps all jackett errors" {
    try std.testing.expectEqualStrings(
        "Cannot connect to Jackett. Is it running?",
        getErrorMessage(error.ConnectionRefused),
    );
    try std.testing.expectEqualStrings(
        "Invalid Jackett URL in config",
        getErrorMessage(error.InvalidUrl),
    );
    try std.testing.expectEqualStrings(
        "Failed to create Jackett request",
        getErrorMessage(error.RequestCreateFailed),
    );
    try std.testing.expectEqualStrings(
        "Failed to send Jackett request",
        getErrorMessage(error.RequestSendFailed),
    );
    try std.testing.expectEqualStrings(
        "Failed to read Jackett response headers",
        getErrorMessage(error.ResponseHeadReadFailed),
    );
    try std.testing.expectEqualStrings(
        "Jackett returned error",
        getErrorMessage(error.HttpError),
    );
    try std.testing.expectEqualStrings(
        "Failed to read Jackett response",
        getErrorMessage(error.ResponseReadFailed),
    );
    try std.testing.expectEqualStrings(
        "Failed to parse Jackett response",
        getErrorMessage(error.ParseFailed),
    );
    try std.testing.expectEqualStrings(
        "Out of memory while processing Jackett response",
        getErrorMessage(error.OutOfMemory),
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
        .deps = .{},
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
        .deps = .{},
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

test "searchWithAppDeps uses injected jackett search executor" {
    const state = struct {
        var called = false;
    };
    state.called = false;

    const mock = struct {
        fn exec(allocator: std.mem.Allocator, url: []const u8) jackett.JackettError![]Torrent {
            state.called = true;
            if (std.mem.indexOf(u8, url, "/api/v2.0/indexers/all/results/torznab/api?apikey=test-key&q=ubuntu") == null) {
                return error.ParseFailed;
            }
            return allocator.alloc(Torrent, 0);
        }
    };

    var app = App{
        .allocator = std.testing.allocator,
        .client = jackett.Client.init(std.testing.allocator, "http://localhost:9117", "test-key"),
        .deps = .{
            .jackett_search_executor = mock.exec,
        },
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
    };

    const torrents = try searchWithAppDeps(&app, "ubuntu");
    defer std.testing.allocator.free(torrents);
    try std.testing.expect(state.called);
    try std.testing.expectEqual(@as(usize, 0), torrents.len);
}

test "addLinkWithAppDeps uses injected superseedr dependencies" {
    const state = struct {
        var checker_called = false;
        var spawner_called = false;
        var executor_called = false;
    };
    state.checker_called = false;
    state.spawner_called = false;
    state.executor_called = false;

    const mock = struct {
        fn checker(_: std.mem.Allocator) anyerror!bool {
            state.checker_called = true;
            return false;
        }

        fn spawner(_: std.mem.Allocator, terminal: []const u8) anyerror!void {
            state.spawner_called = true;
            try std.testing.expectEqualStrings("ghostty", terminal);
        }

        fn exec(_: std.mem.Allocator, argv: []const []const u8) anyerror!void {
            state.executor_called = true;
            try std.testing.expectEqualStrings("superseedr", argv[0]);
            try std.testing.expectEqualStrings("add", argv[1]);
            try std.testing.expectEqualStrings("magnet:?xt=urn:btih:abc", argv[2]);
        }
    };

    var app = App{
        .allocator = std.testing.allocator,
        .client = jackett.Client.init(std.testing.allocator, "http://localhost:9117", "test-key"),
        .deps = .{
            .superseedr_executor = mock.exec,
            .superseedr_process_checker = mock.checker,
            .superseedr_spawner = mock.spawner,
        },
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "ghostty",
    };

    try addLinkWithAppDeps(&app, "magnet:?xt=urn:btih:abc");
    try std.testing.expect(state.checker_called);
    try std.testing.expect(state.spawner_called);
    try std.testing.expect(state.executor_called);
}

test "loadingQueryWidth avoids underflow in compact mode" {
    try std.testing.expectEqual(@as(usize, 1), loadingQueryWidth(4, 0, true));
    try std.testing.expectEqual(@as(usize, 12), loadingQueryWidth(20, 0, true));
}

test "loadingQueryWidth uses panel width in regular mode" {
    try std.testing.expectEqual(@as(usize, 61), loadingQueryWidth(80, 74, false));
    try std.testing.expectEqual(@as(usize, 1), loadingQueryWidth(80, 13, false));
}
