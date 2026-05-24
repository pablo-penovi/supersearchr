const std = @import("std");
const config = @import("config");
const jackett = @import("jackett");
const superseedr = @import("superseedr");
const term = @import("term");
const panels = @import("panels");
const search_widget = @import("search");
const results_widget = @import("results");
const update_checker = @import("update_checker");
const build_options = @import("build_options");
const Torrent = @import("torrent").Torrent;
const debug_log = @import("debug_log");
const compat = @import("compat");

const State = union(enum) {
    search: SearchState,
    results: ResultsState,
    err: ErrorState,
};

const SearchState = struct {
    query: []const u8,
};

const ResultsState = struct {
    query: []u8,
    torrents: std.ArrayList(Torrent),
    search_session: ?*jackett.SearchSession,
    live_status: results_widget.ResultsWidget.LiveStatus,
};

const ErrorState = struct {
    message: []const u8,
};

const AppDeps = struct {
    jackett_body_executor: jackett.BodyExecutor = jackett.defaultBodyExecutor,
    jackett_link_fetcher: jackett.LinkFetchExecutor = jackett.defaultLinkFetchExecutor,
    jackett_parallel_requests: usize = 4,
    superseedr_executor: *const fn (allocator: std.mem.Allocator, argv: []const []const u8) anyerror!void = superseedr.defaultExecutor,
    superseedr_process_checker: *const fn (allocator: std.mem.Allocator) anyerror!bool = superseedr.defaultProcessChecker,
    superseedr_spawner: *const fn (allocator: std.mem.Allocator, terminal: []const u8) anyerror!void = superseedr.defaultSpawner,
    update_latest_version_executor: update_checker.LatestVersionExecutor = update_checker.defaultLatestVersionExecutor,
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
    latest_version: ?[]u8 = null,
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
    defer if (app.latest_version != null) app.allocator.free(app.latest_version.?);

    checkLatestVersionOnStartup(&app);

    while (app.running) {
        switch (app.state) {
            .search => {
                try runSearchState(&app);
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

    if (app.state.search.query.len > 0) {
        try widget.setQuery(app.state.search.query);
        app.allocator.free(app.state.search.query);
        app.state.search.query = "";
    }

    configureSearchWidgetForApp(&widget, app);
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
                transitionSearchToStreamingResults(app, query);
                return;
            },
            .cancel => {
                if (panels.renderExitConfirmationOverlay(&app.term_rows, &app.term_cols, refreshTerminalSizeValues, &widget)) {
                    app.running = false;
                    return;
                }
                widget.has_drawn_once = false;
                needs_render = true;
            },
        }
    }
}

fn checkLatestVersionOnStartup(app: *App) void {
    app.latest_version = update_checker.checkLatestVersion(
        app.allocator,
        build_options.version,
        .{ .owner = "pablo-penovi", .name = "supersearchr" },
        app.deps.update_latest_version_executor,
    ) catch null;
}

fn configureSearchWidgetForApp(widget: *search_widget.SearchWidget, app: *const App) void {
    widget.setLatestVersion(app.latest_version);
}

fn runResultsState(app: *App, results_state: *ResultsState) !void {
    var cleaned_up = false;
    defer if (!cleaned_up) deinitResultsState(app.allocator, results_state);

    term.hideCursor();
    defer term.showCursor();

    var widget = results_widget.ResultsWidget.init(app.allocator);
    defer widget.deinit();

    widget.setTorrents(results_state.torrents.items, results_state.torrents.items.len);
    widget.setLiveStatus(results_state.live_status);
    var needs_render = true;
    const input_poll_ms: i32 = 80;
    const marquee_step_interval_ms: i64 = scaledMarqueeIntervalMs(input_poll_ms, 30);
    var marquee_budget_ms: i64 = 0;
    var last_loop_ms: i64 = compat.milliTimestamp();

    while (true) {
        if (refreshTerminalSize(app)) {
            widget.force_full_redraw = true;
            needs_render = true;
        }

        const previous_cursor_link = if (widget.cursor < widget.torrents.len) widget.torrents[widget.cursor].link else null;
        const search_changed = updateStreamingResults(app, results_state, &widget) catch |err| {
            deinitResultsState(app.allocator, results_state);
            cleaned_up = true;
            app.state = .{ .err = .{ .message = getErrorMessage(err) } };
            return;
        };
        if (search_changed) {
            widget.updateTorrents(results_state.torrents.items, results_state.torrents.items.len, previous_cursor_link);
            needs_render = true;
        }
        widget.setLiveStatus(results_state.live_status);

        const now_ms = compat.milliTimestamp();
        const elapsed_ms = nonNegativeElapsedMs(last_loop_ms, now_ms);
        last_loop_ms = now_ms;
        marquee_budget_ms += elapsed_ms;

        if (needs_render) {
            term.beginSyncRender();
            widget.render(app.term_rows, app.term_cols);
            term.endSyncRender();
            needs_render = false;
        }

        const maybe_event = term.readKeyWithTimeout(input_poll_ms) catch {
            deinitResultsState(app.allocator, results_state);
            cleaned_up = true;
            app.state = .{ .err = .{ .message = "Failed to read input" } };
            return;
        };
        if (maybe_event) |event| {
            const action = widget.handleEvent(event, app.term_rows);
            needs_render = true;

            switch (action) {
                .continue_browsing => {},
                .review_failures => {
                    if (widget.failed_indexers.items.len > 0) {
                        panels.renderFailedIndexersOverlay(
                            &app.term_rows,
                            &app.term_cols,
                            refreshTerminalSizeValues,
                            &widget,
                        );
                        widget.force_full_redraw = true;
                    }
                },
                .new_search => {
                    const last_query = try app.allocator.dupe(u8, results_state.query);
                    deinitResultsState(app.allocator, results_state);
                    cleaned_up = true;
                    app.state = .{ .search = .{ .query = last_query } };
                    return;
                },
                .cancel => {
                    if (panels.renderExitConfirmationOverlay(&app.term_rows, &app.term_cols, refreshTerminalSizeValues, &widget)) {
                        deinitResultsState(app.allocator, results_state);
                        cleaned_up = true;
                        app.running = false;
                        return;
                    }
                    widget.force_full_redraw = true;
                    needs_render = true;
                },
                .select => |idx| {
                    if (idx >= results_state.torrents.items.len) continue;
                    const torrent = results_state.torrents.items[idx];
                    const result = addLinkWithAppDeps(app, torrent.link);

                    if (result) |_| {
                        debug_log.writef(
                            app.allocator,
                            "app",
                            "Added torrent to superseedr title=\"{s}\" link_kind={s}",
                            .{ torrent.title, selectedLinkKind(torrent.link) },
                        );
                        widget.setSendState(idx, .success);
                    } else |err| {
                        debug_log.writef(
                            app.allocator,
                            "app",
                            "Failed to add torrent err={s} title=\"{s}\" link_kind={s}",
                            .{ @errorName(err), torrent.title, selectedLinkKind(torrent.link) },
                        );
                        widget.setSendState(idx, .failed);
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
        } else if (consumeMarqueeTick(&marquee_budget_ms, marquee_step_interval_ms)) {
            const marquee_changed = widget.advanceMarquee(app.term_rows, app.term_cols);
            const spinner_changed = widget.advanceSpinner();
            if (marquee_changed or spinner_changed) {
                needs_render = true;
            }
        }
    }
}

fn startSearchWithAppDeps(app: *App, query: []const u8) jackett.JackettError!*jackett.SearchSession {
    return app.client.startStreamingSearch(
        query,
        app.deps.jackett_body_executor,
        app.deps.jackett_parallel_requests,
    );
}

fn addLinkWithAppDeps(app: *App, link: []const u8) superseedr.AddLinkError!void {
    var resolved_link = jackett.resolveDownloadLink(app.allocator, link, app.deps.jackett_link_fetcher) catch |err| {
        debug_log.writef(
            app.allocator,
            "app",
            "Failed to resolve selected link err={s} link_kind={s}",
            .{ @errorName(err), selectedLinkKind(link) },
        );
        return error.LinkResolveFailed;
    };
    defer resolved_link.deinit(app.allocator);

    debug_log.writef(
        app.allocator,
        "app",
        "Selected link ready for superseedr kind={s}",
        .{@tagName(resolved_link.kind)},
    );

    return superseedr.addLinkWithAllDeps(
        app.allocator,
        resolved_link.value,
        app.terminal,
        app.deps.superseedr_executor,
        app.deps.superseedr_process_checker,
        app.deps.superseedr_spawner,
    );
}

fn selectedLinkKind(link: []const u8) []const u8 {
    if (std.mem.startsWith(u8, link, "magnet:")) return "magnet";
    if (std.mem.startsWith(u8, link, "http://") or std.mem.startsWith(u8, link, "https://")) return "http";
    if (std.mem.endsWith(u8, link, ".torrent")) return "torrent_path";
    return "other";
}

fn transitionSearchToStreamingResults(app: *App, query: []u8) void {
    const session = startSearchWithAppDeps(app, query) catch |err| {
        app.allocator.free(query);
        app.state = .{ .err = .{ .message = getErrorMessage(err) } };
        return;
    };
    app.state = .{ .results = .{
        .query = query,
        .torrents = .empty,
        .search_session = session,
        .live_status = liveStatusFromSnapshot(session.snapshot()),
    } };
}

fn updateStreamingResults(app: *App, results_state: *ResultsState, widget: ?*results_widget.ResultsWidget) jackett.JackettError!bool {
    const session = results_state.search_session orelse return false;
    const previous_status = results_state.live_status;

    if (session.fatalError()) |err| {
        return err;
    }

    var changed = try session.drainInto(app.allocator, &results_state.torrents);
    results_state.live_status = liveStatusFromSnapshot(session.snapshot());
    if (!std.meta.eql(previous_status, results_state.live_status)) changed = true;

    // Extract failed indexers from search session queue
    if (widget) |w| {
        const io = compat.io();
        session.queue.mutex.lockUncancelable(io);
        for (session.queue.failed_indexers.items) |name| {
            w.addFailedIndexer(name) catch {};
        }
        session.queue.mutex.unlock(io);
    }

    if (session.fatalError()) |err| {
        return err;
    }

    if (session.isDone()) {
        _ = try session.drainInto(app.allocator, &results_state.torrents);
        results_state.live_status = liveStatusFromSnapshot(session.snapshot());
        session.deinit();
        results_state.search_session = null;
        return true;
    }

    return changed;
}

fn liveStatusFromSnapshot(snapshot: jackett.SearchProgressSnapshot) results_widget.ResultsWidget.LiveStatus {
    return .{
        .phase = switch (snapshot.phase) {
            .discovering => .discovering,
            .querying => .querying,
            .done => .done,
        },
        .completed = snapshot.completed,
        .total = snapshot.total,
        .failed = snapshot.failed,
    };
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
        error.LinkResolveFailed => "Failed to resolve Jackett download link",
        error.SuperseedrNotFound => "superseedr not found in PATH",
        error.SuperseedrFailed => "Failed to add to superseedr",
        error.SuperseedrLaunchFailed => "Failed to launch superseedr",
    };
}

fn deinitResultsState(allocator: std.mem.Allocator, results_state: *ResultsState) void {
    if (results_state.search_session) |session| {
        if (session.isDone()) {
            session.deinit();
        } else {
            session.abandon();
        }
        results_state.search_session = null;
    }
    allocator.free(results_state.query);
    for (results_state.torrents.items) |t| {
        allocator.free(t.title);
        allocator.free(t.link);
    }
    results_state.torrents.deinit(allocator);
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

fn drainUntilDone(app: *App, results_state: *ResultsState) !void {
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        _ = try updateStreamingResults(app, results_state, null);
        if (results_state.search_session == null) return;
        compat.sleepNanos(std.time.ns_per_ms);
    }
    return error.TestUnexpectedResult;
}

fn waitForStreamingError(app: *App, results_state: *ResultsState) jackett.JackettError {
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        if (updateStreamingResults(app, results_state, null)) |_| {} else |err| return err;
        compat.sleepNanos(std.time.ns_per_ms);
    }
    return error.ParseFailed;
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

test "state transitions smoke path search -> streaming results with injected deps" {
    const mock = struct {
        fn exec(allocator: std.mem.Allocator, url: []const u8) jackett.JackettError![]u8 {
            if (std.mem.indexOf(u8, url, "t=indexers&configured=true") != null) {
                return allocator.dupe(u8, "<indexers><indexer id=\"linuxtracker\"><title>LinuxTracker</title></indexer></indexers>") catch error.OutOfMemory;
            }
            if (std.mem.indexOf(u8, url, "/indexers/linuxtracker/") == null) return error.ParseFailed;
            if (std.mem.indexOf(u8, url, "q=ubuntu") == null) return error.ParseFailed;
            return allocator.dupe(u8, "<rss><channel><item><title>Ubuntu ISO</title><link>magnet:?xt=urn:btih:abc</link><torznab:attr name=\"seeders\" value=\"120\"/><torznab:attr name=\"peers\" value=\"4\"/></item></channel></rss>") catch error.OutOfMemory;
        }
    };

    var app = App{
        .allocator = std.testing.allocator,
        .client = jackett.Client.init(std.testing.allocator, "http://localhost:9117", "test-key"),
        .deps = .{
            .jackett_body_executor = mock.exec,
        },
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
    };

    const query = try std.testing.allocator.dupe(u8, "ubuntu");

    transitionSearchToStreamingResults(&app, query);

    switch (app.state) {
        .results => |*results_state| {
            defer deinitResultsState(std.testing.allocator, results_state);
            try std.testing.expectEqual(@as(usize, 0), results_state.torrents.items.len);
            try drainUntilDone(&app, results_state);
            try std.testing.expectEqual(@as(usize, 1), results_state.torrents.items.len);
            try std.testing.expectEqualStrings("Ubuntu ISO", results_state.torrents.items[0].title);
            try std.testing.expectEqual(results_widget.ResultsWidget.LivePhase.done, results_state.live_status.phase);
        },
        else => return error.UnexpectedState,
    }
}

test "state transitions smoke path discovery failure goes to error" {
    const mock = struct {
        fn exec(_: std.mem.Allocator, _: []const u8) jackett.JackettError![]u8 {
            return error.ConnectionRefused;
        }
    };

    var app = App{
        .allocator = std.testing.allocator,
        .client = jackett.Client.init(std.testing.allocator, "http://localhost:9117", "test-key"),
        .deps = .{
            .jackett_body_executor = mock.exec,
        },
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
    };

    const query = try std.testing.allocator.dupe(u8, "ubuntu");

    transitionSearchToStreamingResults(&app, query);

    switch (app.state) {
        .results => |*results_state| {
            const err = waitForStreamingError(&app, results_state);
            deinitResultsState(std.testing.allocator, results_state);
            app.state = .{ .err = .{ .message = getErrorMessage(err) } };
        },
        else => return error.UnexpectedState,
    }

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

test "startSearchWithAppDeps uses injected jackett body executor" {
    const state = struct {
        var indexers_called = false;
        var search_called = false;
    };
    state.indexers_called = false;
    state.search_called = false;

    const mock = struct {
        fn exec(allocator: std.mem.Allocator, url: []const u8) jackett.JackettError![]u8 {
            if (std.mem.indexOf(u8, url, "/api/v2.0/indexers/all/results/torznab/api?apikey=test-key&t=indexers&configured=true") != null) {
                state.indexers_called = true;
                return allocator.dupe(u8, "<indexers><indexer id=\"linuxtracker\"><title>LinuxTracker</title></indexer></indexers>") catch error.OutOfMemory;
            }
            state.search_called = true;
            if (std.mem.indexOf(u8, url, "/api/v2.0/indexers/linuxtracker/results/torznab/api?apikey=test-key&t=search&q=ubuntu") == null) {
                return error.ParseFailed;
            }
            return allocator.dupe(u8, "<rss><channel></channel></rss>") catch error.OutOfMemory;
        }
    };

    var app = App{
        .allocator = std.testing.allocator,
        .client = jackett.Client.init(std.testing.allocator, "http://localhost:9117", "test-key"),
        .deps = .{
            .jackett_body_executor = mock.exec,
            .jackett_parallel_requests = 1,
        },
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
    };

    const session = try startSearchWithAppDeps(&app, "ubuntu");
    defer session.deinit();
    while (!session.isDone()) {
        compat.sleepNanos(std.time.ns_per_ms);
    }
    try std.testing.expect(state.indexers_called);
    try std.testing.expect(state.search_called);
    const snapshot = session.snapshot();
    try std.testing.expectEqual(@as(usize, 1), snapshot.total);
    try std.testing.expectEqual(@as(usize, 1), snapshot.completed);
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

test "checkLatestVersionOnStartup stores latest version from injected executor" {
    const mocked_latest_tag = "v99.99.99";
    const expected_latest = "99.99.99";
    const state = struct {
        var called_count: usize = 0;
    };
    state.called_count = 0;

    const mock = struct {
        fn exec(allocator: std.mem.Allocator, _: []const u8) update_checker.UpdateError![]u8 {
            state.called_count += 1;
            return std.fmt.allocPrint(
                allocator,
                "{{\"tag_name\":\"{s}\"}}",
                .{mocked_latest_tag},
            ) catch return error.OutOfMemory;
        }
    };

    var app = App{
        .allocator = std.testing.allocator,
        .client = undefined,
        .deps = .{
            .update_latest_version_executor = mock.exec,
        },
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
    };
    defer if (app.latest_version != null) std.testing.allocator.free(app.latest_version.?);

    checkLatestVersionOnStartup(&app);

    try std.testing.expectEqual(@as(usize, 1), state.called_count);
    try std.testing.expect(app.latest_version != null);
    try std.testing.expectEqualStrings(expected_latest, app.latest_version.?);
}

test "checkLatestVersionOnStartup keeps latest_version null on executor failure" {
    const state = struct {
        var called_count: usize = 0;
    };
    state.called_count = 0;

    const mock = struct {
        fn exec(_: std.mem.Allocator, _: []const u8) update_checker.UpdateError![]u8 {
            state.called_count += 1;
            return error.HttpError;
        }
    };

    var app = App{
        .allocator = std.testing.allocator,
        .client = undefined,
        .deps = .{
            .update_latest_version_executor = mock.exec,
        },
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
    };

    checkLatestVersionOnStartup(&app);

    try std.testing.expectEqual(@as(usize, 1), state.called_count);
    try std.testing.expect(app.latest_version == null);
}

test "configureSearchWidgetForApp forwards latest version to search widget" {
    const latest = try std.testing.allocator.dupe(u8, "0.3.7");
    defer std.testing.allocator.free(latest);

    var app = App{
        .allocator = std.testing.allocator,
        .client = undefined,
        .deps = .{},
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
        .latest_version = latest,
    };

    var widget = search_widget.SearchWidget.init(std.testing.allocator);
    defer widget.deinit();

    configureSearchWidgetForApp(&widget, &app);

    try std.testing.expect(widget.latest_version != null);
    try std.testing.expectEqualStrings("0.3.7", widget.latest_version.?);
}
