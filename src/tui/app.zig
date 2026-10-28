const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const jackett = @import("jackett");
const jackett_admin = @import("jackett_admin");
const superseedr = @import("superseedr");
const term = @import("term");
const theme = @import("theme");
const panels = @import("panels");
const search_widget = @import("search");
const results_widget = @import("results");
const indexers_widget = @import("indexers");
const profiles_widget = @import("profiles_widget");
const update_checker = @import("update_checker");
const record = @import("record");
const last_status = @import("last_status");
const profiles = @import("profiles");
const build_options = @import("build_options");
const Torrent = @import("torrent").Torrent;
const debug_log = @import("debug_log");
const compat = @import("compat");

const State = union(enum) {
    search: SearchState,
    results: ResultsState,
    indexers: IndexersState,
    profiles: ProfilesState,
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
    sort_column: ?results_widget.SortColumn = null,
    sort_order: ?results_widget.SortOrder = null,
    header_cursor: ?results_widget.SortColumn = null,
};

/// The indexers and profiles screens are only reachable from the search
/// screen, so they just carry the query to restore when returning to it.
const IndexersState = struct {
    pending_search_query: []u8,
};

const ProfilesState = struct {
    pending_search_query: []u8,
};

const ErrorState = struct {
    message: []const u8,
};

const AppDeps = struct {
    jackett_body_executor: jackett.BodyExecutor = jackett.defaultBodyExecutor,
    jackett_link_fetcher: jackett.LinkFetchExecutor = jackett.defaultLinkFetchExecutor,
    jackett_parallel_requests: usize = 4,
    /// Max concurrent indexer enable/disable calls. Each one waits on Jackett
    /// validating the indexer's site, so a batch takes as long as its slowest
    /// indexer when it fits under this cap.
    jackett_commit_parallel: usize = 16,
    jackett_admin_executor: jackett_admin.AdminExecutor = jackett_admin.defaultAdminExecutor,
    jackett_indexer_cache_dir_resolver: *const fn (allocator: std.mem.Allocator) anyerror![]u8 = jackett_admin.defaultIndexerCacheDir,
    record_path_resolver: *const fn (allocator: std.mem.Allocator) anyerror![]u8 = record.defaultRecordPath,
    last_status_path_resolver: *const fn (allocator: std.mem.Allocator) anyerror![]u8 = last_status.defaultStatusPath,
    profiles_path_resolver: *const fn (allocator: std.mem.Allocator) anyerror![]u8 = profiles.defaultProfilesPath,
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
    jackett_admin_password: []const u8 = "",
    latest_version: ?[]u8 = null,
    /// Whether the live (Jackett-enabled) indexer set differs from the active
    /// profile, as of the last time the startup check, the indexers screen or
    /// the profiles screen read it. `null` while unknown.
    active_profile_modified: ?bool = null,
    startup_modified_check: StartupModifiedCheck = .{},
};

const StartupModifiedResult = enum(u8) { pending, unmodified, modified, unknown };

/// One-shot background check run at launch so the search screen can flag a
/// drifted active profile without waiting for a visit to F1/F2. It runs as a
/// concurrent `Io` task so exit can cancel it rather than wait on a slow or
/// wedged Jackett. The task only reads `store` and writes `result`; the main
/// thread touches `store` again only after the task has been stopped.
const StartupModifiedCheck = struct {
    future: ?std.Io.Future(void) = null,
    store: ?profiles.ProfileStore = null,
    result: std.atomic.Value(StartupModifiedResult) = .init(.pending),
    /// Set once the result has been published, or superseded by F1/F2.
    consumed: bool = false,
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
    term.setCursorSteadyBlock();
    defer term.setCursorBlinkingDefault();

    const size = term.getTerminalSize() catch term.TerminalSize{ .rows = 24, .cols = 80 };

    const base_url = try allocator.print("{s}:{d}", .{ cfg.api_url, cfg.api_port });
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
        .jackett_admin_password = cfg.jackett_admin_password,
    };

    defer client.deinit();
    defer if (app.latest_version != null) app.allocator.free(app.latest_version.?);

    startStartupModifiedCheck(&app);
    defer stopStartupModifiedCheck(&app);

    checkLatestVersionOnStartup(&app);

    while (app.running) {
        switch (app.state) {
            .search => {
                try runSearchState(&app);
            },
            .results => |*results_state| {
                try runResultsState(&app, results_state);
            },
            .indexers => |*indexers_state| {
                try runIndexersState(&app, indexers_state);
            },
            .profiles => |*profiles_state| {
                try runProfilesState(&app, profiles_state);
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

    // Borrowed by the widget for the active-profile label; also tells F2
    // whether there is anything to load.
    var profile_store = loadProfileStore(app);
    defer profile_store.deinit();
    _ = pollStartupModifiedCheck(app);
    widget.setActiveProfile(profile_store.active, app.active_profile_modified orelse false);

    var needs_render = true;
    const input_poll_ms: i32 = 80;
    const marquee_step_interval_ms: i64 = scaledMarqueeIntervalMs(input_poll_ms, 30);
    var marquee_budget_ms: i64 = 0;
    var last_loop_ms: i64 = compat.milliTimestamp();

    while (true) {
        if (refreshTerminalSize(app)) {
            needs_render = true;
        }

        const now_ms = compat.milliTimestamp();
        marquee_budget_ms += nonNegativeElapsedMs(last_loop_ms, now_ms);
        last_loop_ms = now_ms;

        if (needs_render) {
            widget.render();
            needs_render = false;
        }

        const maybe_event = term.readKeyWithTimeout(input_poll_ms) catch {
            app.state = .{ .err = .{ .message = "Failed to read input" } };
            return;
        };
        const event = maybe_event orelse {
            if (pollStartupModifiedCheck(app)) {
                widget.setActiveProfile(profile_store.active, app.active_profile_modified orelse false);
                needs_render = true;
            }
            if (consumeMarqueeTick(&marquee_budget_ms, marquee_step_interval_ms)) {
                if (widget.advanceHintsMarquee()) needs_render = true;
            }
            continue;
        };
        if (event.key == .f1) {
            const query = try app.allocator.dupe(u8, widget.getQuery());
            app.state = .{ .indexers = .{ .pending_search_query = query } };
            return;
        }
        if (event.key == .f2) {
            if (profile_store.count() == 0) {
                panels.renderInfoNoticeOverlay(
                    &app.term_rows,
                    &app.term_cols,
                    refreshTerminalSizeValues,
                    &widget,
                    "Profiles",
                    no_profiles_message,
                    theme.superseedr_like.accent,
                );
                widget.has_drawn_once = false;
                needs_render = true;
                continue;
            }
            const query = try app.allocator.dupe(u8, widget.getQuery());
            app.state = .{ .profiles = .{ .pending_search_query = query } };
            return;
        }
        const action = widget.handleEvent(event);
        needs_render = true;

        switch (action) {
            .continue_search => {},
            .submit => {
                const query = try app.allocator.dupe(u8, widget.getQuery());
                transitionSearchToStreamingResults(app, query, false, null, null, null);
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

const no_profiles_message = "No profiles yet: press F1, pick indexers, then F3 to save one";

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

const ResultsBgUpdate = struct {
    app: *App,
    results_state: *ResultsState,
    widget: *results_widget.ResultsWidget,
    marquee_budget_ms: *i64,
    last_loop_ms: *i64,
    animation_step_interval_ms: i64,

    fn update(ptr: ?*anyopaque) anyerror!panels.BackgroundUpdateDelta {
        const self: *ResultsBgUpdate = @ptrCast(@alignCast(ptr orelse return .{}));
        const previous_cursor_link = if (self.widget.cursor < self.widget.torrents.len) self.widget.torrents[self.widget.cursor].link else null;
        var delta = panels.BackgroundUpdateDelta{};

        const changed = try updateStreamingResults(self.app, self.results_state, self.widget);
        if (changed) {
            self.widget.updateTorrents(self.results_state.torrents.items, self.results_state.torrents.items.len, previous_cursor_link);
            delta.backdrop_changed = true;
        }
        const previous_status = self.widget.live_status;
        self.widget.setLiveStatus(self.results_state.live_status);
        if (!std.meta.eql(previous_status, self.widget.live_status)) {
            delta.backdrop_changed = true;
        }

        const now_ms = compat.milliTimestamp();
        const elapsed_ms = nonNegativeElapsedMs(self.last_loop_ms.*, now_ms);
        self.last_loop_ms.* = now_ms;
        self.marquee_budget_ms.* += elapsed_ms;
        if (consumeMarqueeTick(self.marquee_budget_ms, self.animation_step_interval_ms)) {
            if (self.widget.advanceSpinner()) {
                delta.status_changed = true;
            }
        }
        return delta;
    }
};

fn runResultsState(app: *App, results_state: *ResultsState) !void {
    var cleaned_up = false;
    defer if (!cleaned_up) deinitResultsState(app.allocator, results_state);

    term.hideCursor();
    defer term.showCursor();

    var widget = results_widget.ResultsWidget.init(app.allocator);
    defer widget.deinit();

    if (results_state.sort_column) |col| {
        widget.sort_column = col;
    }
    if (results_state.sort_order) |ord| {
        widget.sort_order = ord;
    }
    if (results_state.header_cursor) |cursor| {
        widget.header_cursor = cursor;
    }

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
                .open_list_search => {
                    var bg_update = ResultsBgUpdate{
                        .app = app,
                        .results_state = results_state,
                        .widget = &widget,
                        .marquee_budget_ms = &marquee_budget_ms,
                        .last_loop_ms = &last_loop_ms,
                        .animation_step_interval_ms = marquee_step_interval_ms,
                    };
                    panels.renderListSearchOverlay(
                        &app.term_rows,
                        &app.term_cols,
                        refreshTerminalSizeValues,
                        &widget,
                        .{
                            .ptr = &bg_update,
                            .update_fn = ResultsBgUpdate.update,
                        },
                    ) catch |err| {
                        deinitResultsState(app.allocator, results_state);
                        cleaned_up = true;

                        app.state = .{ .err = .{ .message = getErrorMessage(@errorCast(err)) } };
                        return;
                    };
                    widget.force_full_redraw = true;
                    needs_render = true;
                },
                .new_search => {
                    const last_query = try app.allocator.dupe(u8, results_state.query);
                    deinitResultsState(app.allocator, results_state);
                    cleaned_up = true;
                    app.state = .{ .search = .{ .query = last_query } };
                    return;
                },
                .refresh => {
                    const last_query = try app.allocator.dupe(u8, results_state.query);
                    const saved_sort_column = widget.sort_column;
                    const saved_sort_order = widget.sort_order;
                    const saved_header_cursor = widget.header_cursor;
                    deinitResultsState(app.allocator, results_state);
                    cleaned_up = true;
                    transitionSearchToStreamingResults(app, last_query, true, saved_sort_column, saved_sort_order, saved_header_cursor);
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

fn deinitIndexersState(app: *App, indexers_state: *IndexersState) void {
    app.allocator.free(indexers_state.pending_search_query);
}

fn deinitProfilesState(app: *App, profiles_state: *ProfilesState) void {
    app.allocator.free(profiles_state.pending_search_query);
}

/// Returns to the search screen, handing the pending query back to it.
fn returnFromProfiles(app: *App, profiles_state: *ProfilesState) void {
    app.state = .{ .search = .{ .query = profiles_state.pending_search_query } };
}

fn runIndexersState(app: *App, indexers_state: *IndexersState) !void {
    if (!builtin.is_test) term.hideCursor();
    defer if (!builtin.is_test) term.showCursor();

    var widget = indexers_widget.IndexersWidget.init(app.allocator);
    defer widget.deinit();

    if (!builtin.is_test) {
        panels.renderNoticePanel("Indexers", "Loading indexers...", theme.superseedr_like.accent, true);
    }

    var session = jackett_admin.login(
        app.allocator,
        app.client.base_url,
        app.jackett_admin_password,
        app.deps.jackett_admin_executor,
    ) catch |err| {
        deinitIndexersState(app, indexers_state);
        app.state = .{ .err = .{ .message = getAdminErrorMessage(err) } };
        return;
    };
    defer session.deinit(app.allocator);

    const remote_indexers = jackett_admin.listAllIndexers(
        app.allocator,
        app.client.base_url,
        &session,
        app.deps.jackett_admin_executor,
    ) catch |err| {
        deinitIndexersState(app, indexers_state);
        app.state = .{ .err = .{ .message = getAdminErrorMessage(err) } };
        return;
    };
    defer jackett_admin.freeIndexerInfos(app.allocator, remote_indexers);

    var record_store = blk: {
        const record_path = app.deps.record_path_resolver(app.allocator) catch break :blk record.RecordStore.init(app.allocator);
        defer app.allocator.free(record_path);
        break :blk record.load(app.allocator, record_path) catch record.RecordStore.init(app.allocator);
    };
    defer record_store.deinit();

    var status_store = blk: {
        const status_path = app.deps.last_status_path_resolver(app.allocator) catch break :blk last_status.StatusStore.init(app.allocator);
        defer app.allocator.free(status_path);
        break :blk last_status.load(app.allocator, status_path) catch last_status.StatusStore.init(app.allocator);
    };
    defer status_store.deinit();

    var source_rows: std.ArrayList(indexers_widget.IndexersWidget.SourceRow) = .empty;
    defer source_rows.deinit(app.allocator);
    for (remote_indexers) |info| {
        try source_rows.append(app.allocator, .{ .id = info.id, .name = info.name, .configured = info.configured, .categories = info.categories, .record = record_store.get(info.id), .last_status = status_store.get(info.id) });
    }
    try widget.setIndexers(source_rows.items);

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

        const now_ms = compat.milliTimestamp();
        const elapsed_ms = nonNegativeElapsedMs(last_loop_ms, now_ms);
        last_loop_ms = now_ms;
        marquee_budget_ms += elapsed_ms;

        if (needs_render) {
            widget.render(app.term_rows, app.term_cols);
            needs_render = false;
        }

        const maybe_event = term.readKeyWithTimeout(input_poll_ms) catch {
            deinitIndexersState(app, indexers_state);
            app.state = .{ .err = .{ .message = "Failed to read input" } };
            return;
        };

        if (maybe_event == null) {
            if (consumeMarqueeTick(&marquee_budget_ms, marquee_step_interval_ms)) {
                if (widget.advanceMarquee(app.term_rows, app.term_cols)) {
                    needs_render = true;
                }
            }
            continue;
        }
        const event = maybe_event.?;
        if (event.key == .f3) {
            handleProfileSaveFromIndexers(app, &widget, &session) catch {
                deinitIndexersState(app, indexers_state);
                app.state = .{ .err = .{ .message = "Failed to save indexer changes" } };
                return;
            };
            widget.force_full_redraw = true;
            needs_render = true;
            continue;
        }
        if (event.key == .f2) {
            const leave = prepareLeaveIndexersForProfiles(app, &widget, &session) catch {
                deinitIndexersState(app, indexers_state);
                app.state = .{ .err = .{ .message = "Failed to save indexer changes" } };
                return;
            };
            if (leave) {
                app.state = .{ .profiles = .{ .pending_search_query = indexers_state.pending_search_query } };
                return;
            }
            widget.force_full_redraw = true;
            needs_render = true;
            continue;
        }
        const action = widget.handleEvent(event);
        needs_render = true;

        switch (action) {
            .continue_browsing => {},
            .save => {
                _ = commitIndexerChanges(app, &widget, &session) catch {
                    deinitIndexersState(app, indexers_state);
                    app.state = .{ .err = .{ .message = "Failed to save indexer changes" } };
                    return;
                };
            },
            .revert => {
                widget.revertPending();
            },
            .exit_to_previous => {
                refreshActiveProfileModified(app, &widget);
                app.state = .{ .search = .{ .query = indexers_state.pending_search_query } };
                return;
            },
        }
    }
}

const CommitOutcome = enum { committed, reverted };

/// Commits the widget's pending toggles to Jackett, driving the interactive
/// retry/revert overlay until everything succeeds or the user reverts.
/// Shared by the Indexers ENTER-save path and the F3 "include" path.
/// Returns `.reverted` if the user chose to revert all pending changes.
fn commitIndexerChanges(
    app: *App,
    widget: *indexers_widget.IndexersWidget,
    session: *const jackett_admin.AdminSession,
) !CommitOutcome {
    var failed_names = try runCommitWithProgress(app, widget, session);
    defer failed_names.deinit(app.allocator);
    widget.force_full_redraw = true;

    while (failed_names.items.len > 0) {
        const overlay_action = panels.renderIndexerSaveFailuresOverlay(
            &app.term_rows,
            &app.term_cols,
            refreshTerminalSizeValues,
            widget,
            failed_names.items,
        );
        switch (overlay_action) {
            .revert => {
                widget.revertPending();
                return .reverted;
            },
            .retry => {
                failed_names.deinit(app.allocator);
                failed_names = try runCommitWithProgress(app, widget, session);
                widget.force_full_redraw = true;
            },
        }
    }
    return .committed;
}

/// F3 on the Indexers screen: snapshots the committed (actually-enabled)
/// indexer set into a profile. Handles the uncommitted-changes,
/// first-time-save, and save-choice flows per the profiles spec.
fn handleProfileSaveFromIndexers(
    app: *App,
    widget: *indexers_widget.IndexersWidget,
    session: *const jackett_admin.AdminSession,
) !void {
    if (widget.hasPendingChanges()) {
        var pending_names: std.ArrayList([]const u8) = .empty;
        defer pending_names.deinit(app.allocator);
        for (widget.rows) |row| {
            if (row.pending_active != null) try pending_names.append(app.allocator, row.name);
        }
        const choice = panels.renderProfileUncommittedOverlay(
            &app.term_rows,
            &app.term_cols,
            refreshTerminalSizeValues,
            widget,
            pending_names.items,
            .save_profile,
        );
        switch (choice) {
            .commit => {
                const outcome = try commitIndexerChanges(app, widget, session);
                if (outcome == .reverted) return;
            },
            .discard => {},
            .cancel => return,
        }
    }

    // E = committed set (rows actually enabled on Jackett).
    var enabled: std.ArrayList([]const u8) = .empty;
    defer enabled.deinit(app.allocator);
    for (widget.rows) |row| {
        if (row.saved_active) try enabled.append(app.allocator, row.id);
    }

    var store = loadProfileStore(app);
    defer store.deinit();

    const active_name_opt = store.active;
    const matches_active = if (active_name_opt) |a|
        (if (store.get(a)) |p| profiles.setsEqual(p.indexers.items, enabled.items) else false)
    else
        false;

    switch (decideProfileSave(active_name_opt != null, matches_active)) {
        .first_time => {
            if (try promptAndSaveNewProfile(app, widget, &store, enabled.items)) {
                showSavedNotice(app, widget);
            }
        },
        .no_change => {},
        .choose => {
            const active_name = active_name_opt.?;
            const choice = panels.renderProfileSaveChoiceOverlay(
                &app.term_rows,
                &app.term_cols,
                refreshTerminalSizeValues,
                widget,
            );
            switch (choice) {
                .overwrite => {
                    if (saveProfileAs(app, widget, &store, active_name, enabled.items, false)) {
                        showSavedNotice(app, widget);
                    }
                },
                .new_profile => {
                    if (try promptAndSaveNewProfile(app, widget, &store, enabled.items)) {
                        showSavedNotice(app, widget);
                    }
                },
                .cancel => {},
            }
        },
    }
}

/// F2 on the Indexers screen: decides whether to switch to the profiles
/// screen. With no saved profiles it explains how to create one and stays.
/// Uncommitted toggles must first be committed or discarded (or the switch
/// cancelled). Returns true when the caller should switch.
fn prepareLeaveIndexersForProfiles(
    app: *App,
    widget: *indexers_widget.IndexersWidget,
    session: *const jackett_admin.AdminSession,
) !bool {
    var store = loadProfileStore(app);
    defer store.deinit();
    if (store.count() == 0) {
        panels.renderInfoNoticeOverlay(
            &app.term_rows,
            &app.term_cols,
            refreshTerminalSizeValues,
            widget,
            "Profiles",
            no_profiles_on_indexers_message,
            theme.superseedr_like.accent,
        );
        return false;
    }

    if (widget.hasPendingChanges()) {
        var pending_names: std.ArrayList([]const u8) = .empty;
        defer pending_names.deinit(app.allocator);
        for (widget.rows) |row| {
            if (row.pending_active != null) try pending_names.append(app.allocator, row.name);
        }
        const choice = panels.renderProfileUncommittedOverlay(
            &app.term_rows,
            &app.term_cols,
            refreshTerminalSizeValues,
            widget,
            pending_names.items,
            .leave,
        );
        switch (choice) {
            .commit => {
                // Reverting from the failures overlay keeps the user here to
                // see the outcome rather than leaving straight away.
                if (try commitIndexerChanges(app, widget, session) == .reverted) return false;
            },
            .discard => widget.revertPending(),
            .cancel => return false,
        }
    }
    return true;
}

const no_profiles_on_indexers_message = "No profiles yet: pick indexers, then press F3 to save one";

const SaveDecision = enum { first_time, no_change, choose };

/// Pure decision for F3 save: with no active profile it's a first-time save;
/// with an active profile that already matches the committed set there's
/// nothing to do; otherwise prompt to overwrite or save as new.
fn decideProfileSave(has_active: bool, matches_active: bool) SaveDecision {
    if (!has_active) return .first_time;
    if (matches_active) return .no_change;
    return .choose;
}

fn showSavedNotice(app: *App, backdrop: anytype) void {
    panels.renderInfoNoticeOverlay(
        &app.term_rows,
        &app.term_cols,
        refreshTerminalSizeValues,
        backdrop,
        "Profiles",
        "Saved",
        theme.superseedr_like.accent,
    );
}

/// Opens the name-prompt over `backdrop` and, if a name is chosen, saves the
/// given ID set under it and makes it active. Returns true if a profile was
/// saved (false if the prompt was cancelled).
fn promptAndSaveNewProfile(
    app: *App,
    backdrop: anytype,
    store: *profiles.ProfileStore,
    ids: []const []const u8,
) !bool {
    const existing = try store.names(app.allocator);
    defer app.allocator.free(existing);

    const result = try panels.renderProfileNamePromptOverlay(
        app.allocator,
        &app.term_rows,
        &app.term_cols,
        refreshTerminalSizeValues,
        backdrop,
        "Profile name",
        "",
        existing,
    );
    switch (result) {
        .name => |name| {
            defer app.allocator.free(name);
            return saveProfileAs(app, backdrop, store, name, ids, true);
        },
        .cancel => return false,
    }
}

/// Stores `ids` under `name` (optionally making it the active profile) and
/// writes the store to disk. On any failure an error notice is shown over
/// `backdrop` and false is returned, so callers never report a phantom save.
fn saveProfileAs(
    app: *App,
    backdrop: anytype,
    store: *profiles.ProfileStore,
    name: []const u8,
    ids: []const []const u8,
    make_active: bool,
) bool {
    store.upsert(name, ids) catch {
        showProfileSaveError(app, backdrop);
        return false;
    };
    if (make_active) {
        store.setActive(name) catch {
            showProfileSaveError(app, backdrop);
            return false;
        };
    }
    return persistProfileStore(app, backdrop, store);
}

/// Writes the store to disk, showing an error notice over `backdrop` if that
/// fails. Returns true on success.
fn persistProfileStore(app: *App, backdrop: anytype, store: *const profiles.ProfileStore) bool {
    saveProfileStore(app, store) catch {
        showProfileSaveError(app, backdrop);
        return false;
    };
    return true;
}

fn showProfileSaveError(app: *App, backdrop: anytype) void {
    panels.renderInfoNoticeOverlay(
        &app.term_rows,
        &app.term_cols,
        refreshTerminalSizeValues,
        backdrop,
        "Profiles",
        "Could not write the profiles file; changes were not saved",
        theme.superseedr_like.err,
    );
}

fn loadProfileStore(app: *App) profiles.ProfileStore {
    const path = app.deps.profiles_path_resolver(app.allocator) catch return profiles.ProfileStore.init(app.allocator);
    defer app.allocator.free(path);
    return profiles.load(app.allocator, path) catch profiles.ProfileStore.init(app.allocator);
}

fn saveProfileStore(app: *App, store: *const profiles.ProfileStore) !void {
    const path = try app.deps.profiles_path_resolver(app.allocator);
    defer app.allocator.free(path);
    try profiles.save(app.allocator, path, store);
}

/// Whether `live_ids` (the indexers enabled on Jackett) differ from the
/// store's active profile. `null` when there is no active profile.
fn activeProfileModified(store: *const profiles.ProfileStore, live_ids: []const []const u8) ?bool {
    const active_name = store.active orelse return null;
    const active_profile = store.get(active_name) orelse return null;
    return !profiles.setsEqual(active_profile.indexers.items, live_ids);
}

/// Records a value read by F1/F2. It is fresher than anything the startup
/// check could still report, so that result is dropped.
fn setActiveProfileModified(app: *App, value: ?bool) void {
    app.active_profile_modified = value;
    app.startup_modified_check.consumed = true;
}

/// Starts the startup check as a concurrent `Io` task when `profiles.json`
/// has an active profile. Any failure (including an `Io` without concurrency)
/// just leaves the marker unknown.
fn startStartupModifiedCheck(app: *App) void {
    const check = &app.startup_modified_check;
    var store = loadProfileStore(app);
    // `null` regardless of the live set means there is no active profile.
    if (activeProfileModified(&store, &.{}) == null) {
        store.deinit();
        check.consumed = true;
        return;
    }
    check.store = store;
    check.future = compat.io().concurrent(startupModifiedWorker, .{
        app.allocator,
        app.client.base_url,
        app.jackett_admin_password,
        app.deps.jackett_admin_executor,
        check,
    }) catch {
        check.store.?.deinit();
        check.store = null;
        check.consumed = true;
        return;
    };
}

fn startupModifiedWorker(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    admin_password: []const u8,
    executor: jackett_admin.AdminExecutor,
    check: *StartupModifiedCheck,
) void {
    const result = computeStartupModified(allocator, base_url, admin_password, executor, &check.store.?);
    check.result.store(result, .release);
}

/// Logs in, lists the indexers and compares the configured ones with the
/// store's active profile. Every failure maps to `.unknown`.
fn computeStartupModified(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    admin_password: []const u8,
    executor: jackett_admin.AdminExecutor,
    store: *const profiles.ProfileStore,
) StartupModifiedResult {
    var session = jackett_admin.login(allocator, base_url, admin_password, executor) catch return .unknown;
    defer session.deinit(allocator);
    const remote_indexers = jackett_admin.listAllIndexers(allocator, base_url, &session, executor) catch return .unknown;
    defer jackett_admin.freeIndexerInfos(allocator, remote_indexers);

    var enabled: std.ArrayList([]const u8) = .empty;
    defer enabled.deinit(allocator);
    for (remote_indexers) |info| {
        if (info.configured) enabled.append(allocator, info.id) catch return .unknown;
    }
    const modified = activeProfileModified(store, enabled.items) orelse return .unknown;
    return if (modified) .modified else .unmodified;
}

/// Publishes a finished startup check into `app.active_profile_modified`,
/// at most once. Returns whether the value changed (so the label needs a
/// refresh). Never blocks.
fn pollStartupModifiedCheck(app: *App) bool {
    const check = &app.startup_modified_check;
    if (check.consumed) return false;
    const value: bool = switch (check.result.load(.acquire)) {
        .pending => return false,
        .unknown => {
            check.consumed = true;
            return false;
        },
        .modified => true,
        .unmodified => false,
    };
    check.consumed = true;
    app.active_profile_modified = value;
    return true;
}

/// Stops the startup check and frees its store. A still-running check is
/// canceled: its in-flight Jackett call fails with `error.Canceled`, so exit
/// never waits on Jackett. `cancel` returns once the task has finished.
fn stopStartupModifiedCheck(app: *App) void {
    const check = &app.startup_modified_check;
    if (check.future) |*future| future.cancel(compat.io());
    check.future = null;
    if (check.store) |*store| store.deinit();
    check.store = null;
}

/// Recomputes `app.active_profile_modified` from the Indexers screen's
/// committed rows, so the search screen can flag a drifted profile.
fn refreshActiveProfileModified(app: *App, widget: *const indexers_widget.IndexersWidget) void {
    var store = loadProfileStore(app);
    defer store.deinit();

    var enabled: std.ArrayList([]const u8) = .empty;
    defer enabled.deinit(app.allocator);
    for (widget.rows) |row| {
        if (row.saved_active) enabled.append(app.allocator, row.id) catch return;
    }
    setActiveProfileModified(app, activeProfileModified(&store, enabled.items));
}

fn refreshProfilesWidget(
    app: *App,
    widget: *profiles_widget.ProfilesWidget,
    store: *const profiles.ProfileStore,
    remote: []const jackett_admin.IndexerInfo,
) !void {
    var source_rows: std.ArrayList(profiles_widget.ProfilesWidget.SourceRow) = .empty;
    defer {
        for (source_rows.items) |row| app.allocator.free(row.details);
        source_rows.deinit(app.allocator);
    }
    for (store.list.items) |*p| {
        const is_active = if (store.active) |a| std.mem.eql(u8, a, p.name) else false;
        const details = try buildProfileDetails(app.allocator, p.indexers.items, remote);
        source_rows.append(app.allocator, .{
            .name = p.name,
            .count = p.indexers.items.len,
            .active = is_active,
            .details = details,
        }) catch |err| {
            app.allocator.free(details);
            return err;
        };
    }
    try widget.setProfiles(source_rows.items);
}

/// Details-panel rows previewing what loading a profile would do: its
/// indexers (staying on, to enable, or missing from Jackett) sorted by name,
/// followed by the currently-enabled indexers it would disable. Caller frees
/// the slice; names borrow from `profile_ids`/`remote`.
fn buildProfileDetails(
    allocator: std.mem.Allocator,
    profile_ids: []const []const u8,
    remote: []const jackett_admin.IndexerInfo,
) ![]profiles_widget.ProfilesWidget.DetailSource {
    const DetailSource = profiles_widget.ProfilesWidget.DetailSource;
    var list: std.ArrayList(DetailSource) = .empty;
    errdefer list.deinit(allocator);

    for (profile_ids) |id| {
        const info = findIndexer(remote, id) orelse {
            try list.append(allocator, .{ .name = id, .change = .missing });
            continue;
        };
        try list.append(allocator, .{ .name = info.name, .change = if (info.configured) .keep else .enable });
    }
    for (remote) |info| {
        if (!info.configured) continue;
        if (containsId(profile_ids, info.id)) continue;
        try list.append(allocator, .{ .name = info.name, .change = .disable });
    }

    std.mem.sort(DetailSource, list.items, {}, lessThanDetail);
    return list.toOwnedSlice(allocator);
}

fn lessThanDetail(_: void, a: profiles_widget.ProfilesWidget.DetailSource, b: profiles_widget.ProfilesWidget.DetailSource) bool {
    const a_leaving = a.change == .disable;
    const b_leaving = b.change == .disable;
    if (a_leaving != b_leaving) return b_leaving;
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

fn findIndexer(remote: []const jackett_admin.IndexerInfo, id: []const u8) ?*const jackett_admin.IndexerInfo {
    for (remote) |*info| {
        if (std.mem.eql(u8, info.id, id)) return info;
    }
    return null;
}

fn containsId(ids: []const []const u8, id: []const u8) bool {
    for (ids) |candidate| {
        if (std.mem.eql(u8, candidate, id)) return true;
    }
    return false;
}

/// `r` on the Profiles screen: prompts for a new name (pre-filled with the
/// current one) and renames the profile, keeping the cursor on it. Renaming
/// onto another profile's name replaces that profile after a confirming ENTER.
fn renameProfile(
    app: *App,
    widget: *profiles_widget.ProfilesWidget,
    store: *profiles.ProfileStore,
    remote: []const jackett_admin.IndexerInfo,
    idx: usize,
) !void {
    const old_name = try app.allocator.dupe(u8, store.list.items[idx].name);
    defer app.allocator.free(old_name);

    // Collisions are only with the other profiles; keeping the name is a no-op.
    var others: std.ArrayList([]const u8) = .empty;
    defer others.deinit(app.allocator);
    for (store.list.items, 0..) |p, i| {
        if (i != idx) try others.append(app.allocator, p.name);
    }

    const result = try panels.renderProfileNamePromptOverlay(
        app.allocator,
        &app.term_rows,
        &app.term_cols,
        refreshTerminalSizeValues,
        widget,
        "Rename profile",
        old_name,
        others.items,
    );
    const new_name = switch (result) {
        .name => |name| name,
        .cancel => return,
    };
    defer app.allocator.free(new_name);
    if (std.mem.eql(u8, new_name, old_name)) return;

    store.rename(old_name, new_name) catch {
        showProfileSaveError(app, widget);
        return;
    };
    _ = persistProfileStore(app, widget, store);
    try refreshProfilesWidget(app, widget, store, remote);
    for (store.list.items, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, new_name)) widget.cursor = i;
    }
}

fn nameForId(remote: []const jackett_admin.IndexerInfo, id: []const u8) []const u8 {
    if (findIndexer(remote, id)) |info| return info.name;
    return id;
}

/// Builds the enable/disable work list that makes Jackett's enabled set match
/// `profile_ids` (caller owns the slice). Item ids borrow from the inputs,
/// which must outlive it; `idx` is just the item's position.
fn buildProfileApplyItems(
    app: *App,
    profile_ids: []const []const u8,
    enabled_ids: []const []const u8,
) ![]CommitItem {
    var plan = try profiles.applyPlan(app.allocator, profile_ids, enabled_ids);
    defer plan.deinit(app.allocator);

    var list: std.ArrayList(CommitItem) = .empty;
    errdefer list.deinit(app.allocator);
    for (plan.to_enable) |id| try list.append(app.allocator, .{ .idx = list.items.len, .enable = true, .id = id });
    for (plan.to_disable) |id| try list.append(app.allocator, .{ .idx = list.items.len, .enable = false, .id = id });
    return list.toOwnedSlice(app.allocator);
}

/// Outcome of one profile-apply pass. `failed_items` are the attempted items
/// whose toggle failed (retry candidates); `failed_names` are their display
/// names, borrowed from `remote`.
const ProfileApplyOutcome = struct {
    failed_items: []CommitItem,
    failed_names: std.ArrayList([]const u8),

    fn deinit(self: *ProfileApplyOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.failed_items);
        self.failed_names.deinit(allocator);
    }
};

/// Collects the worker outcomes of a profile-apply pass and persists the Last
/// Status column. Items with a null outcome (skipped by an ESC cancel) are
/// neither succeeded nor failed.
fn collectProfileApplyOutcome(
    app: *App,
    items: []const CommitItem,
    outcomes: []const ?bool,
    remote: []const jackett_admin.IndexerInfo,
) !ProfileApplyOutcome {
    var failed_items: std.ArrayList(CommitItem) = .empty;
    errdefer failed_items.deinit(app.allocator);
    var failed_names: std.ArrayList([]const u8) = .empty;
    errdefer failed_names.deinit(app.allocator);
    var succeeded_ids: std.ArrayList([]const u8) = .empty;
    defer succeeded_ids.deinit(app.allocator);
    var failed_ids: std.ArrayList([]const u8) = .empty;
    defer failed_ids.deinit(app.allocator);

    for (items, outcomes) |item, outcome| {
        const ok = outcome orelse continue;
        if (ok) {
            try succeeded_ids.append(app.allocator, item.id);
        } else {
            try failed_items.append(app.allocator, item);
            try failed_names.append(app.allocator, nameForId(remote, item.id));
            try failed_ids.append(app.allocator, item.id);
        }
    }

    persistLastStatus(app, succeeded_ids.items, failed_ids.items);
    return .{ .failed_items = try failed_items.toOwnedSlice(app.allocator), .failed_names = failed_names };
}

/// Applies a profile on a worker thread with live progress on the profiles
/// widget, offering to retry failed indexers. Returns true when Jackett's
/// enabled set now matches the profile, false when the user stopped early
/// (ESC) or kept a partial result.
fn applyProfileWithProgress(
    app: *App,
    widget: *profiles_widget.ProfilesWidget,
    session: *const jackett_admin.AdminSession,
    remote: []const jackett_admin.IndexerInfo,
    profile_ids: []const []const u8,
    enabled_ids: []const []const u8,
) !bool {
    const cache_dir = try app.deps.jackett_indexer_cache_dir_resolver(app.allocator);
    defer app.allocator.free(cache_dir);

    var items = try buildProfileApplyItems(app, profile_ids, enabled_ids);
    defer app.allocator.free(items);

    while (items.len > 0) {
        const outcomes = try app.allocator.alloc(?bool, items.len);
        defer app.allocator.free(outcomes);

        const completed = runToggleWorker(app, widget, session, cache_dir, items, outcomes);
        var outcome = try collectProfileApplyOutcome(app, items, outcomes, remote);
        defer outcome.deinit(app.allocator);

        if (completed < items.len) return false;
        if (outcome.failed_items.len == 0) return true;

        const choice = panels.renderProfileApplyFailuresOverlay(
            &app.term_rows,
            &app.term_cols,
            refreshTerminalSizeValues,
            widget,
            outcome.failed_names.items,
        );
        widget.force_full_redraw = true;
        switch (choice) {
            .keep => return false,
            .retry => {
                app.allocator.free(items);
                items = outcome.failed_items;
                outcome.failed_items = &.{};
            },
        }
    }
    return true;
}

fn runProfilesState(app: *App, profiles_state: *ProfilesState) !void {
    if (!builtin.is_test) term.hideCursor();
    defer if (!builtin.is_test) term.showCursor();

    var store = loadProfileStore(app);
    defer store.deinit();

    // No saved profiles: nothing to load. The search screen normally catches
    // this first and explains how to create one.
    if (store.count() == 0) {
        returnFromProfiles(app, profiles_state);
        return;
    }

    if (!builtin.is_test) {
        panels.renderNoticePanel("Profiles", "Loading profiles...", theme.superseedr_like.accent, true);
    }

    var session = jackett_admin.login(
        app.allocator,
        app.client.base_url,
        app.jackett_admin_password,
        app.deps.jackett_admin_executor,
    ) catch |err| {
        deinitProfilesState(app, profiles_state);
        app.state = .{ .err = .{ .message = getAdminErrorMessage(err) } };
        return;
    };
    defer session.deinit(app.allocator);

    const remote_indexers = jackett_admin.listAllIndexers(
        app.allocator,
        app.client.base_url,
        &session,
        app.deps.jackett_admin_executor,
    ) catch |err| {
        deinitProfilesState(app, profiles_state);
        app.state = .{ .err = .{ .message = getAdminErrorMessage(err) } };
        return;
    };
    defer jackett_admin.freeIndexerInfos(app.allocator, remote_indexers);

    // Current enabled set E.
    var enabled: std.ArrayList([]const u8) = .empty;
    defer enabled.deinit(app.allocator);
    for (remote_indexers) |info| {
        if (info.configured) try enabled.append(app.allocator, info.id);
    }

    var widget = profiles_widget.ProfilesWidget.init(app.allocator);
    defer widget.deinit();
    try refreshProfilesWidget(app, &widget, &store, remote_indexers);

    // Modified-warning step: live set differs from the active profile.
    setActiveProfileModified(app, activeProfileModified(&store, enabled.items));
    if (app.active_profile_modified orelse false) {
        const active_name = store.active.?;
        const choice = panels.renderProfileModifiedOverlay(
            &app.term_rows,
            &app.term_cols,
            refreshTerminalSizeValues,
            &widget,
        );
        widget.force_full_redraw = true;
        switch (choice) {
            .save_existing => {
                if (saveProfileAs(app, &widget, &store, active_name, enabled.items, false)) {
                    setActiveProfileModified(app, false);
                }
                try refreshProfilesWidget(app, &widget, &store, remote_indexers);
            },
            .new_profile => {
                if (try promptAndSaveNewProfile(app, &widget, &store, enabled.items)) {
                    setActiveProfileModified(app, false);
                }
                try refreshProfilesWidget(app, &widget, &store, remote_indexers);
            },
            .discard => {},
            .cancel => {
                returnFromProfiles(app, profiles_state);
                return;
            },
        }
    }

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

        const now_ms = compat.milliTimestamp();
        marquee_budget_ms += nonNegativeElapsedMs(last_loop_ms, now_ms);
        last_loop_ms = now_ms;

        if (needs_render) {
            widget.render(app.term_rows, app.term_cols);
            needs_render = false;
        }

        const maybe_event = term.readKeyWithTimeout(input_poll_ms) catch {
            deinitProfilesState(app, profiles_state);
            app.state = .{ .err = .{ .message = "Failed to read input" } };
            return;
        };
        const event = maybe_event orelse {
            if (consumeMarqueeTick(&marquee_budget_ms, marquee_step_interval_ms)) {
                if (widget.advanceMarquee(app.term_rows, app.term_cols)) {
                    needs_render = true;
                }
            }
            continue;
        };
        if (event.key == .f1) {
            app.state = .{ .indexers = .{ .pending_search_query = profiles_state.pending_search_query } };
            return;
        }
        const action = widget.handleEvent(event);
        needs_render = true;

        switch (action) {
            .continue_browsing => {},
            .load => |idx| {
                if (idx >= store.list.items.len) continue;
                const profile = &store.list.items[idx];
                const fully_applied = applyProfileWithProgress(
                    app,
                    &widget,
                    &session,
                    remote_indexers,
                    profile.indexers.items,
                    enabled.items,
                ) catch {
                    deinitProfilesState(app, profiles_state);
                    app.state = .{ .err = .{ .message = "Failed to apply profile" } };
                    return;
                };
                // The profile becomes active even when only partly applied:
                // the search screen then flags it as modified.
                setActiveProfileModified(app, !fully_applied);
                if (store.setActive(profile.name)) |_| {
                    _ = persistProfileStore(app, &widget, &store);
                } else |_| {
                    showProfileSaveError(app, &widget);
                }
                returnFromProfiles(app, profiles_state);
                return;
            },
            .delete => |idx| {
                if (idx >= store.list.items.len) continue;
                const confirm = panels.renderProfileDeleteConfirmOverlay(
                    &app.term_rows,
                    &app.term_cols,
                    refreshTerminalSizeValues,
                    &widget,
                    store.list.items[idx].name,
                );
                widget.force_full_redraw = true;
                if (confirm) {
                    const name_copy = app.allocator.dupe(u8, store.list.items[idx].name) catch continue;
                    defer app.allocator.free(name_copy);
                    store.remove(name_copy);
                    _ = persistProfileStore(app, &widget, &store);
                    if (store.count() == 0) {
                        returnFromProfiles(app, profiles_state);
                        return;
                    }
                    try refreshProfilesWidget(app, &widget, &store, remote_indexers);
                }
            },
            .rename => |idx| {
                if (idx >= store.list.items.len) continue;
                try renameProfile(app, &widget, &store, remote_indexers, idx);
                widget.force_full_redraw = true;
            },
            .close => {
                returnFromProfiles(app, profiles_state);
                return;
            },
        }
    }
}

/// One pending enable/disable to commit. `id`/`idx` borrow from the widget's
/// rows, which stay stable for the duration of a commit (no re-sort occurs).
const CommitItem = struct { idx: usize, enable: bool, id: []const u8 };

/// Collects the widget's pending toggles into a flat list (caller owns the
/// returned slice). Snapshotting them up front lets the per-item HTTP work run
/// on a worker thread without touching widget state.
fn gatherCommitItems(app: *App, widget: *indexers_widget.IndexersWidget) ![]CommitItem {
    var list: std.ArrayList(CommitItem) = .empty;
    errdefer list.deinit(app.allocator);
    for (widget.rows, 0..) |row, idx| {
        const target = row.pending_active orelse continue;
        try list.append(app.allocator, .{ .idx = idx, .enable = target, .id = row.id });
    }
    return list.toOwnedSlice(app.allocator);
}

/// Shared state for the commit worker pool. Workers claim items through
/// `next_index` and each writes only its own `outcomes` slot.
const CommitContext = struct {
    app: *App,
    session: *const jackett_admin.AdminSession,
    cache_dir: []const u8,
    items: []const CommitItem,
    outcomes: []?bool,
    next_index: std.atomic.Value(usize),
    progress: *jackett.Progress,
    cancel: *std.atomic.Value(bool),
};

/// Performs the enable/disable round-trip for every item, recording each
/// outcome into `outcomes` (parallel to `items`; null = not attempted) and
/// publishing progress. Touches no widget state, so it is safe to run on a
/// worker thread while the UI renders. Each enable/disable is a synchronous
/// Jackett call that can take minutes when the indexer's site is slow, so items
/// run concurrently on up to `jackett_commit_parallel` threads: the batch takes
/// as long as its slowest indexer rather than the sum of all of them.
fn commitItems(
    app: *App,
    session: *const jackett_admin.AdminSession,
    cache_dir: []const u8,
    items: []const CommitItem,
    outcomes: []?bool,
    progress: *jackett.Progress,
    cancel: *std.atomic.Value(bool),
) void {
    @memset(outcomes, null);
    var ctx = CommitContext{
        .app = app,
        .session = session,
        .cache_dir = cache_dir,
        .items = items,
        .outcomes = outcomes,
        .next_index = std.atomic.Value(usize).init(0),
        .progress = progress,
        .cancel = cancel,
    };

    const worker_count = @min(@max(app.deps.jackett_commit_parallel, @as(usize, 1)), items.len);
    var spawned: usize = 0;
    if (app.allocator.alloc(std.Thread, worker_count)) |threads| {
        defer app.allocator.free(threads);
        while (spawned < worker_count) : (spawned += 1) {
            threads[spawned] = std.Thread.spawn(.{}, commitWorker, .{&ctx}) catch break;
        }
        for (threads[0..spawned]) |thread| thread.join();
    } else |_| {}
    // No thread could be spawned: drain the items on this thread instead.
    if (spawned == 0) commitWorker(&ctx);
    progress.setPhase(.done);
}

fn commitWorker(ctx: *CommitContext) void {
    while (true) {
        // ESC sets `cancel`: in-flight items finish, but no new one starts.
        if (ctx.cancel.load(.monotonic)) return;
        const i = ctx.next_index.fetchAdd(1, .monotonic);
        if (i >= ctx.items.len) return;
        const item = ctx.items[i];
        const ok = if (item.enable)
            (if (enableIndexer(ctx.app, ctx.session, ctx.cache_dir, item.id)) |_| true else |_| false)
        else
            (if (disableIndexer(ctx.app, ctx.session, ctx.cache_dir, item.id)) |_| true else |_| false);
        ctx.outcomes[i] = ok;
        if (!ok) ctx.progress.recordFailed();
        ctx.progress.recordCompleted();
    }
}

/// Applies worker outcomes back onto the widget (mark each row saved/failed),
/// persists the Last Status column, and returns the names of rows that failed
/// (caller owns and must `.deinit()`). Borrowed name slices reference the
/// widget rows, which outlive the returned list.
///
/// Items with a null outcome were never attempted (skipped by an ESC cancel);
/// their rows keep the pending toggle and are neither marked saved nor failed.
fn applyCommitOutcomes(
    app: *App,
    widget: *indexers_widget.IndexersWidget,
    items: []const CommitItem,
    outcomes: []const ?bool,
) !std.ArrayList([]const u8) {
    var failed_names: std.ArrayList([]const u8) = .empty;
    errdefer failed_names.deinit(app.allocator);

    var succeeded_ids: std.ArrayList([]const u8) = .empty;
    defer succeeded_ids.deinit(app.allocator);
    var failed_ids: std.ArrayList([]const u8) = .empty;
    defer failed_ids.deinit(app.allocator);

    for (items, outcomes) |item, outcome| {
        const ok = outcome orelse continue;
        if (ok) {
            widget.markSaved(item.idx);
            try succeeded_ids.append(app.allocator, item.id);
        } else {
            widget.markFailed(item.idx);
            try failed_names.append(app.allocator, widget.rows[item.idx].name);
            try failed_ids.append(app.allocator, item.id);
        }
    }

    persistLastStatus(app, succeeded_ids.items, failed_ids.items);
    return failed_names;
}

/// Commits pending toggles on a worker thread with live progress (see
/// `runToggleWorker`), then applies the outcomes to the widget.
fn runCommitWithProgress(
    app: *App,
    widget: *indexers_widget.IndexersWidget,
    session: *const jackett_admin.AdminSession,
) !std.ArrayList([]const u8) {
    const items = try gatherCommitItems(app, widget);
    defer app.allocator.free(items);
    const outcomes = try app.allocator.alloc(?bool, items.len);
    defer app.allocator.free(outcomes);
    const cache_dir = try app.deps.jackett_indexer_cache_dir_resolver(app.allocator);
    defer app.allocator.free(cache_dir);

    _ = runToggleWorker(app, widget, session, cache_dir, items, outcomes);
    return applyCommitOutcomes(app, widget, items, outcomes);
}

/// Runs `commitItems` on a worker thread, animating an in-panel progress
/// status row on `widget` (the Indexers or Profiles list) until the worker
/// finishes. During the wait the list stays scrollable (arrow keys move the
/// cursor) but every other action is ignored; ESC requests a graceful stop
/// once the in-flight indexers finish. Returns how many items were attempted.
fn runToggleWorker(
    app: *App,
    widget: anytype,
    session: *const jackett_admin.AdminSession,
    cache_dir: []const u8,
    items: []const CommitItem,
    outcomes: []?bool,
) usize {
    var progress = jackett.Progress.init();
    progress.setTotal(items.len);
    progress.setPhase(.querying);
    var cancel = std.atomic.Value(bool).init(false);

    const thread = std.Thread.spawn(.{}, commitItems, .{ app, session, cache_dir, items, outcomes, &progress, &cancel }) catch {
        // No worker thread available: commit synchronously (UI stays blocked).
        commitItems(app, session, cache_dir, items, outcomes, &progress, &cancel);
        widget.setCommitProgress(null);
        return progress.snapshot().completed;
    };

    const input_poll_ms: i32 = 80;
    var spinner_frame: usize = 0;
    var canceling = false;
    while (true) {
        if (refreshTerminalSize(app)) widget.force_full_redraw = true;

        const snap = progress.snapshot();
        widget.setCommitProgress(.{
            .completed = snap.completed,
            .total = snap.total,
            .failed = snap.failed,
            .spinner_frame = spinner_frame,
            .canceling = canceling,
        });

        term.beginSyncRender();
        widget.render(app.term_rows, app.term_cols);
        term.endSyncRender();

        if (snap.phase == .done) break;

        // ~80ms tick. ESC requests a graceful stop; arrows scroll the list;
        // everything else is ignored mid-commit.
        const maybe_event = term.readKeyWithTimeout(input_poll_ms) catch null;
        if (maybe_event) |event| {
            if (event.key == .escape) {
                cancel.store(true, .monotonic);
                canceling = true;
            } else if (widget.handleNavigationOnly(event)) {
                widget.force_full_redraw = true;
            }
        }
        _ = widget.advanceMarquee(app.term_rows, app.term_cols);
        spinner_frame +%= 1;
    }

    thread.join();
    widget.setCommitProgress(null);
    widget.force_full_redraw = true;
    return progress.snapshot().completed;
}

/// Best-effort persistence of the latest commit outcomes to last_status.json.
/// Never fails the commit: a missing/unwritable file just leaves the column stale.
fn persistLastStatus(app: *App, succeeded: []const []const u8, failed: []const []const u8) void {
    if (succeeded.len == 0 and failed.len == 0) return;
    const path = app.deps.last_status_path_resolver(app.allocator) catch return;
    defer app.allocator.free(path);
    last_status.updateAfterCommit(app.allocator, path, succeeded, failed) catch {};
}

fn disableIndexer(
    app: *App,
    session: *const jackett_admin.AdminSession,
    cache_dir: []const u8,
    indexer_id: []const u8,
) !void {
    const config_json = try jackett_admin.getIndexerConfig(
        app.allocator,
        app.client.base_url,
        indexer_id,
        session,
        app.deps.jackett_admin_executor,
    );
    defer app.allocator.free(config_json);

    try jackett_admin.cacheIndexerConfig(app.allocator, cache_dir, indexer_id, config_json);

    try jackett_admin.deleteIndexer(
        app.allocator,
        app.client.base_url,
        indexer_id,
        session,
        app.deps.jackett_admin_executor,
    );
}

fn enableIndexer(
    app: *App,
    session: *const jackett_admin.AdminSession,
    cache_dir: []const u8,
    indexer_id: []const u8,
) !void {
    const cached = try jackett_admin.readCachedIndexerConfig(app.allocator, cache_dir, indexer_id);
    const config_json = cached orelse try jackett_admin.getIndexerConfig(
        app.allocator,
        app.client.base_url,
        indexer_id,
        session,
        app.deps.jackett_admin_executor,
    );
    defer app.allocator.free(config_json);

    try jackett_admin.setIndexerConfig(
        app.allocator,
        app.client.base_url,
        indexer_id,
        config_json,
        session,
        app.deps.jackett_admin_executor,
    );

    jackett_admin.clearCachedIndexerConfig(app.allocator, cache_dir, indexer_id);
}

fn getAdminErrorMessage(err: jackett_admin.AdminError) []const u8 {
    return switch (err) {
        error.ConnectionRefused => "Cannot connect to Jackett. Is it running?",
        error.InvalidUrl => "Invalid Jackett URL in config",
        error.RequestCreateFailed => "Failed to create Jackett admin request",
        error.RequestSendFailed => "Failed to send Jackett admin request",
        error.ResponseHeadReadFailed => "Failed to read Jackett admin response headers",
        error.HttpError => "Jackett admin API returned an error",
        error.ResponseReadFailed => "Failed to read Jackett admin response",
        error.ParseFailed => "Failed to parse Jackett admin response",
        error.LoginFailed => "Failed to authenticate with Jackett admin API - check jackettAdminPassword in config",
        error.NoSessionCookie => "Jackett did not return a session cookie - unexpected login response",
        error.OutOfMemory => "Out of memory while processing Jackett admin response",
    };
}

fn startSearchWithAppDeps(app: *App, query: []const u8, skip_cache: bool) jackett.JackettError!*jackett.SearchSession {
    return app.client.startStreamingSearch(
        query,
        app.deps.jackett_body_executor,
        app.deps.jackett_parallel_requests,
        skip_cache,
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

fn transitionSearchToStreamingResults(
    app: *App,
    query: []u8,
    skip_cache: bool,
    sort_column: ?results_widget.SortColumn,
    sort_order: ?results_widget.SortOrder,
    header_cursor: ?results_widget.SortColumn,
) void {
    const session = startSearchWithAppDeps(app, query, skip_cache) catch |err| {
        app.allocator.free(query);
        app.state = .{ .err = .{ .message = getErrorMessage(err) } };
        return;
    };
    app.state = .{ .results = .{
        .query = query,
        .torrents = .empty,
        .search_session = session,
        .live_status = liveStatusFromSnapshot(session.snapshot()),
        .sort_column = sort_column,
        .sort_order = sort_order,
        .header_cursor = header_cursor,
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

    if (widget) |w| syncFailedIndexers(session, w);

    if (session.fatalError()) |err| {
        return err;
    }

    if (session.isDone()) {
        _ = try session.drainInto(app.allocator, &results_state.torrents);
        results_state.live_status = liveStatusFromSnapshot(session.snapshot());
        // A failure may have landed between the sync above and `isDone`.
        if (widget) |w| syncFailedIndexers(session, w);
        persistSearchOutcomes(app, session);
        session.deinit();
        results_state.search_session = null;
        return true;
    }

    return changed;
}

/// Copies the session's failed indexers into the widget's 'e' overlay, by
/// display name (the widget ignores names it already has).
fn syncFailedIndexers(session: *jackett.SearchSession, widget: *results_widget.ResultsWidget) void {
    const io = compat.io();
    session.queue.mutex.lockUncancelable(io);
    defer session.queue.mutex.unlock(io);
    for (session.queue.failed_indexer_names.items) |name| {
        widget.addFailedIndexer(name) catch {};
    }
}

// Persist per-indexer success/failure outcomes after a search completes.
// Best-effort: a filesystem hiccup must never fail a completed search. Must be
// called before `session.deinit()`, since the queue (and the indexer-id strings
// it owns) become invalid afterwards.
fn persistSearchOutcomes(app: *App, session: *jackett.SearchSession) void {
    const io = compat.io();
    session.queue.mutex.lockUncancelable(io);
    const succeeded = app.allocator.dupe([]const u8, session.queue.succeeded_indexers.items) catch {
        session.queue.mutex.unlock(io);
        return;
    };
    const failed = app.allocator.dupe([]const u8, session.queue.failed_indexers.items) catch {
        app.allocator.free(succeeded);
        session.queue.mutex.unlock(io);
        return;
    };
    session.queue.mutex.unlock(io);
    defer app.allocator.free(succeeded);
    defer app.allocator.free(failed);

    const record_path = app.deps.record_path_resolver(app.allocator) catch return;
    defer app.allocator.free(record_path);

    record.updateAfterSearch(app.allocator, record_path, succeeded, failed) catch {};
}

fn liveStatusFromSnapshot(snapshot: jackett.ProgressSnapshot) results_widget.ResultsWidget.LiveStatus {
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
    return drainUntilDoneWithWidget(app, results_state, null);
}

fn drainUntilDoneWithWidget(app: *App, results_state: *ResultsState, widget: ?*results_widget.ResultsWidget) !void {
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        _ = try updateStreamingResults(app, results_state, widget);
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
            if (std.mem.find(u8, url, "t=indexers&configured=true") != null) {
                return allocator.dupe(u8, "<indexers><indexer id=\"linuxtracker\"><title>LinuxTracker</title></indexer></indexers>") catch error.OutOfMemory;
            }
            if (std.mem.find(u8, url, "/indexers/linuxtracker/") == null) return error.ParseFailed;
            if (std.mem.find(u8, url, "q=ubuntu") == null) return error.ParseFailed;
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

    transitionSearchToStreamingResults(&app, query, false, null, null, null);

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

    transitionSearchToStreamingResults(&app, query, false, null, null, null);

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

test "completed streaming search persists per-indexer outcomes to record.json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_abs = try tmp.dir.realPathFileAlloc(compat.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_abs);
    const record_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_abs, "record.json" });
    defer std.testing.allocator.free(record_path);

    const state = struct {
        var test_record_path: []const u8 = &.{};
    };
    state.test_record_path = record_path;

    const mock = struct {
        fn exec(allocator: std.mem.Allocator, url: []const u8) jackett.JackettError![]u8 {
            if (std.mem.find(u8, url, "t=indexers&configured=true") != null) {
                return allocator.dupe(u8, "<indexers><indexer id=\"ok\"><title>OK</title></indexer><indexer id=\"bad\"><title>Bad</title></indexer></indexers>") catch error.OutOfMemory;
            }
            if (std.mem.find(u8, url, "/indexers/ok/") != null) {
                return allocator.dupe(u8, "<rss><channel><item><title>OK Result</title><link>magnet:?xt=urn:btih:ok</link><torznab:attr name=\"seeders\" value=\"5\"/></item></channel></rss>") catch error.OutOfMemory;
            }
            return error.HttpError;
        }

        fn recordPath(alloc: std.mem.Allocator) anyerror![]u8 {
            return alloc.dupe(u8, state.test_record_path);
        }
    };

    var app = App{
        .allocator = std.testing.allocator,
        .client = jackett.Client.init(std.testing.allocator, "http://localhost:9117", "test-key"),
        .deps = .{
            .jackett_body_executor = mock.exec,
            .record_path_resolver = mock.recordPath,
        },
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
    };

    const query = try std.testing.allocator.dupe(u8, "ubuntu");
    transitionSearchToStreamingResults(&app, query, false, null, null, null);

    switch (app.state) {
        .results => |*results_state| {
            defer deinitResultsState(std.testing.allocator, results_state);
            try drainUntilDone(&app, results_state);
        },
        else => return error.UnexpectedState,
    }

    var store = try record.load(std.testing.allocator, record_path);
    defer store.deinit();
    try std.testing.expectEqualSlices(u8, &.{1}, store.get("ok"));
    try std.testing.expectEqualSlices(u8, &.{0}, store.get("bad"));
}

test "failed indexers overlay gets display names while record.json stays keyed by ID" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_abs = try tmp.dir.realPathFileAlloc(compat.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_abs);
    const record_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_abs, "record.json" });
    defer std.testing.allocator.free(record_path);

    const state = struct {
        var test_record_path: []const u8 = &.{};
    };
    state.test_record_path = record_path;

    const mock = struct {
        fn exec(allocator: std.mem.Allocator, url: []const u8) jackett.JackettError![]u8 {
            if (std.mem.find(u8, url, "t=indexers&configured=true") != null) {
                return allocator.dupe(u8, "<indexers><indexer id=\"ok\"><title>OK</title></indexer><indexer id=\"thepiratebay\"><title>The Pirate Bay</title></indexer></indexers>") catch error.OutOfMemory;
            }
            if (std.mem.find(u8, url, "/indexers/ok/") != null) {
                return allocator.dupe(u8, "<rss><channel><item><title>OK Result</title><link>magnet:?xt=urn:btih:ok</link></item></channel></rss>") catch error.OutOfMemory;
            }
            return error.HttpError;
        }

        fn recordPath(alloc: std.mem.Allocator) anyerror![]u8 {
            return alloc.dupe(u8, state.test_record_path);
        }
    };

    var app = App{
        .allocator = std.testing.allocator,
        .client = jackett.Client.init(std.testing.allocator, "http://localhost:9117", "test-key"),
        .deps = .{
            .jackett_body_executor = mock.exec,
            .record_path_resolver = mock.recordPath,
        },
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
    };

    var widget = results_widget.ResultsWidget.init(std.testing.allocator);
    defer widget.deinit();

    const query = try std.testing.allocator.dupe(u8, "ubuntu");
    transitionSearchToStreamingResults(&app, query, false, null, null, null);

    switch (app.state) {
        .results => |*results_state| {
            defer deinitResultsState(std.testing.allocator, results_state);
            try drainUntilDoneWithWidget(&app, results_state, &widget);
        },
        else => return error.UnexpectedState,
    }

    try std.testing.expectEqual(@as(usize, 1), widget.failed_indexers.items.len);
    try std.testing.expectEqualStrings("The Pirate Bay", widget.failed_indexers.items[0]);

    var store = try record.load(std.testing.allocator, record_path);
    defer store.deinit();
    try std.testing.expectEqualSlices(u8, &.{0}, store.get("thepiratebay"));
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
            if (std.mem.find(u8, url, "/api/v2.0/indexers/all/results/torznab/api?apikey=test-key&t=indexers&configured=true") != null) {
                state.indexers_called = true;
                return allocator.dupe(u8, "<indexers><indexer id=\"linuxtracker\"><title>LinuxTracker</title></indexer></indexers>") catch error.OutOfMemory;
            }
            state.search_called = true;
            if (std.mem.find(u8, url, "/api/v2.0/indexers/linuxtracker/results/torznab/api?apikey=test-key&t=search&q=ubuntu") == null) {
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

    const session = try startSearchWithAppDeps(&app, "ubuntu", false);
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
            return allocator.print(
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

test "transitionSearchToStreamingResults preserves sort fields" {
    const mock = struct {
        fn exec(allocator: std.mem.Allocator, url: []const u8) jackett.JackettError![]u8 {
            if (std.mem.find(u8, url, "t=indexers&configured=true") != null) {
                return allocator.dupe(u8, "<indexers></indexers>") catch error.OutOfMemory;
            }
            return error.ParseFailed;
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

    transitionSearchToStreamingResults(
        &app,
        query,
        false,
        .size,
        .asc,
        .leechers,
    );

    switch (app.state) {
        .results => |*results_state| {
            defer deinitResultsState(std.testing.allocator, results_state);
            try std.testing.expectEqual(results_widget.SortColumn.size, results_state.sort_column.?);
            try std.testing.expectEqual(results_widget.SortOrder.asc, results_state.sort_order.?);
            try std.testing.expectEqual(results_widget.SortColumn.leechers, results_state.header_cursor.?);
            try drainUntilDone(&app, results_state);
        },
        else => return error.UnexpectedState,
    }
}

test "getAdminErrorMessage exhaustively maps all admin errors" {
    try std.testing.expectEqualStrings(
        "Cannot connect to Jackett. Is it running?",
        getAdminErrorMessage(error.ConnectionRefused),
    );
    try std.testing.expectEqualStrings(
        "Invalid Jackett URL in config",
        getAdminErrorMessage(error.InvalidUrl),
    );
    try std.testing.expectEqualStrings(
        "Failed to create Jackett admin request",
        getAdminErrorMessage(error.RequestCreateFailed),
    );
    try std.testing.expectEqualStrings(
        "Failed to send Jackett admin request",
        getAdminErrorMessage(error.RequestSendFailed),
    );
    try std.testing.expectEqualStrings(
        "Failed to read Jackett admin response headers",
        getAdminErrorMessage(error.ResponseHeadReadFailed),
    );
    try std.testing.expectEqualStrings(
        "Jackett admin API returned an error",
        getAdminErrorMessage(error.HttpError),
    );
    try std.testing.expectEqualStrings(
        "Failed to read Jackett admin response",
        getAdminErrorMessage(error.ResponseReadFailed),
    );
    try std.testing.expectEqualStrings(
        "Failed to parse Jackett admin response",
        getAdminErrorMessage(error.ParseFailed),
    );
    try std.testing.expectEqualStrings(
        "Failed to authenticate with Jackett admin API - check jackettAdminPassword in config",
        getAdminErrorMessage(error.LoginFailed),
    );
    try std.testing.expectEqualStrings(
        "Jackett did not return a session cookie - unexpected login response",
        getAdminErrorMessage(error.NoSessionCookie),
    );
    try std.testing.expectEqualStrings(
        "Out of memory while processing Jackett admin response",
        getAdminErrorMessage(error.OutOfMemory),
    );
}

test "deinitIndexersState frees pending_search_query when returning to search" {
    var app = App{
        .allocator = std.testing.allocator,
        .client = undefined,
        .deps = .{},
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
    };

    var indexers_state = IndexersState{
        .pending_search_query = try std.testing.allocator.dupe(u8, "ubuntu"),
    };

    deinitIndexersState(&app, &indexers_state);
}

test "runIndexersState login failure surfaces as ErrorState and cleans up pending search query" {
    const mock = struct {
        fn exec(_: std.mem.Allocator, _: jackett_admin.AdminRequest) jackett_admin.AdminError!jackett_admin.AdminResponse {
            return error.ConnectionRefused;
        }
    };

    var app = App{
        .allocator = std.testing.allocator,
        .client = jackett.Client.init(std.testing.allocator, "http://localhost:9117", "test-key"),
        .deps = .{
            .jackett_admin_executor = mock.exec,
        },
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
    };

    var indexers_state = IndexersState{
        .pending_search_query = try std.testing.allocator.dupe(u8, "ubuntu"),
    };

    try runIndexersState(&app, &indexers_state);

    switch (app.state) {
        .err => |error_state| try std.testing.expectEqualStrings(
            "Cannot connect to Jackett. Is it running?",
            error_state.message,
        ),
        else => return error.UnexpectedState,
    }
}

test "commit core marks rows saved/failed and persists Last Status" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_abs = try tmp.dir.realPathFileAlloc(compat.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_abs);
    const cache_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_abs, "indexer_cache" });
    defer std.testing.allocator.free(cache_dir);
    const status_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_abs, "last_status.json" });
    defer std.testing.allocator.free(status_path);

    const state = struct {
        var test_cache_dir: []const u8 = &.{};
        var test_status_path: []const u8 = &.{};
    };
    state.test_cache_dir = cache_dir;
    state.test_status_path = status_path;

    const mock = struct {
        fn exec(alloc: std.mem.Allocator, request: jackett_admin.AdminRequest) jackett_admin.AdminError!jackett_admin.AdminResponse {
            // "good"'s GET-Config and DELETE URLs both contain this substring -> both succeed.
            if (std.mem.find(u8, request.url, "/indexers/good") != null) {
                return .{ .status = .ok, .body = try alloc.dupe(u8, "{}") };
            }
            // "bad"'s GET-Config succeeds (so it gets cached), but its DELETE
            // URL (no /Config suffix) falls through to the HttpError below,
            // so the disable operation fails partway through.
            if (std.mem.find(u8, request.url, "/indexers/bad/Config") != null) {
                return .{ .status = .ok, .body = try alloc.dupe(u8, "{}") };
            }
            return error.HttpError;
        }

        fn cacheDir(alloc: std.mem.Allocator) anyerror![]u8 {
            return alloc.dupe(u8, state.test_cache_dir);
        }

        fn statusPath(alloc: std.mem.Allocator) anyerror![]u8 {
            return alloc.dupe(u8, state.test_status_path);
        }
    };

    var app = App{
        .allocator = std.testing.allocator,
        .client = jackett.Client.init(std.testing.allocator, "http://localhost:9117", "test-key"),
        .deps = .{
            .jackett_admin_executor = mock.exec,
            .jackett_indexer_cache_dir_resolver = mock.cacheDir,
            .last_status_path_resolver = mock.statusPath,
        },
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
    };

    var widget = indexers_widget.IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setIndexers(&.{
        .{ .id = "good", .name = "Good Indexer", .configured = true },
        .{ .id = "bad", .name = "Bad Indexer", .configured = true },
    });
    // Both are enabled, so setIndexers sorts them alphabetically: Bad Indexer, then Good Indexer.
    widget.rows[0].pending_active = false;
    widget.rows[1].pending_active = false;

    var session = jackett_admin.AdminSession{ .cookie = try std.testing.allocator.dupe(u8, "Jackett=abc123") };
    defer session.deinit(std.testing.allocator);

    const items = try gatherCommitItems(&app, &widget);
    defer std.testing.allocator.free(items);
    const outcomes = try std.testing.allocator.alloc(?bool, items.len);
    defer std.testing.allocator.free(outcomes);
    const cache_dir_resolved = try app.deps.jackett_indexer_cache_dir_resolver(std.testing.allocator);
    defer std.testing.allocator.free(cache_dir_resolved);
    var progress = jackett.Progress.init();
    progress.setTotal(items.len);
    var cancel = std.atomic.Value(bool).init(false);
    commitItems(&app, &session, cache_dir_resolved, items, outcomes, &progress, &cancel);
    var failed_names = try applyCommitOutcomes(&app, &widget, items, outcomes);
    defer failed_names.deinit(std.testing.allocator);

    try std.testing.expect(widget.rows[0].pending_active != null);
    try std.testing.expect(widget.rows[0].save_state == .failed);

    try std.testing.expect(widget.rows[1].pending_active == null);
    try std.testing.expect(!widget.rows[1].saved_active);
    try std.testing.expect(widget.rows[1].save_state == .none);

    try std.testing.expectEqual(@as(usize, 1), failed_names.items.len);
    try std.testing.expectEqualStrings("Bad Indexer", failed_names.items[0]);

    // The Last Status of each row reflects its commit outcome, both live...
    try std.testing.expectEqual(@as(?bool, false), widget.rows[0].last_status);
    try std.testing.expectEqual(@as(?bool, true), widget.rows[1].last_status);
    // ...and persisted to last_status.json.
    var store = try last_status.load(std.testing.allocator, status_path);
    defer store.deinit();
    try std.testing.expectEqual(@as(?bool, true), store.get("good"));
    try std.testing.expectEqual(@as(?bool, false), store.get("bad"));
}

test "commitItems runs on a worker thread, recording outcomes and progress" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_abs = try tmp.dir.realPathFileAlloc(compat.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_abs);
    const cache_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_abs, "indexer_cache" });
    defer std.testing.allocator.free(cache_dir);

    const mock = struct {
        // Everything under /indexers/ok succeeds; /indexers/bad fails.
        fn exec(alloc: std.mem.Allocator, request: jackett_admin.AdminRequest) jackett_admin.AdminError!jackett_admin.AdminResponse {
            if (std.mem.find(u8, request.url, "/indexers/ok") != null) {
                return .{ .status = .ok, .body = try alloc.dupe(u8, "{}") };
            }
            return error.HttpError;
        }
    };

    var app = App{
        .allocator = std.testing.allocator,
        .client = jackett.Client.init(std.testing.allocator, "http://localhost:9117", "test-key"),
        .deps = .{ .jackett_admin_executor = mock.exec },
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
    };

    var session = jackett_admin.AdminSession{ .cookie = try std.testing.allocator.dupe(u8, "Jackett=abc123") };
    defer session.deinit(std.testing.allocator);

    const items = [_]CommitItem{
        .{ .idx = 0, .enable = true, .id = "ok" },
        .{ .idx = 1, .enable = true, .id = "bad" },
    };
    var outcomes: [2]?bool = undefined;
    var progress = jackett.Progress.init();
    progress.setTotal(items.len);
    progress.setPhase(.querying);
    var cancel = std.atomic.Value(bool).init(false);

    const thread = try std.Thread.spawn(.{}, commitItems, .{ &app, &session, cache_dir, items[0..], outcomes[0..], &progress, &cancel });
    thread.join();

    try std.testing.expectEqual(@as(?bool, true), outcomes[0]);
    try std.testing.expectEqual(@as(?bool, false), outcomes[1]);

    const snap = progress.snapshot();
    try std.testing.expectEqual(jackett.ProgressPhase.done, snap.phase);
    try std.testing.expectEqual(@as(usize, 2), snap.completed);
    try std.testing.expectEqual(@as(usize, 1), snap.failed);
}

test "commitItems runs items concurrently, up to jackett_commit_parallel" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_abs = try tmp.dir.realPathFileAlloc(compat.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_abs);
    const cache_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_abs, "indexer_cache" });
    defer std.testing.allocator.free(cache_dir);

    const state = struct {
        var in_flight = std.atomic.Value(usize).init(0);
        var max_in_flight = std.atomic.Value(usize).init(0);
    };
    state.in_flight.store(0, .monotonic);
    state.max_in_flight.store(0, .monotonic);

    const mock = struct {
        // Each GET-Config waits (bounded) until all three are in flight at
        // once, which only happens when the items run concurrently.
        fn exec(alloc: std.mem.Allocator, request: jackett_admin.AdminRequest) jackett_admin.AdminError!jackett_admin.AdminResponse {
            if (request.method == .get) {
                const now = state.in_flight.fetchAdd(1, .monotonic) + 1;
                _ = state.max_in_flight.fetchMax(now, .monotonic);
                var spins: usize = 0;
                while (state.max_in_flight.load(.monotonic) < 3 and spins < 1_000_000) : (spins += 1) {
                    std.Thread.yield() catch {};
                }
                _ = state.in_flight.fetchSub(1, .monotonic);
            }
            return .{ .status = .ok, .body = try alloc.dupe(u8, "{}") };
        }
    };

    var app = App{
        .allocator = std.testing.allocator,
        .client = jackett.Client.init(std.testing.allocator, "http://localhost:9117", "test-key"),
        .deps = .{ .jackett_admin_executor = mock.exec, .jackett_commit_parallel = 3 },
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
    };

    var session = jackett_admin.AdminSession{ .cookie = try std.testing.allocator.dupe(u8, "Jackett=abc123") };
    defer session.deinit(std.testing.allocator);

    const items = [_]CommitItem{
        .{ .idx = 0, .enable = true, .id = "a" },
        .{ .idx = 1, .enable = true, .id = "b" },
        .{ .idx = 2, .enable = true, .id = "c" },
        .{ .idx = 3, .enable = true, .id = "d" },
    };
    var outcomes: [4]?bool = undefined;
    var progress = jackett.Progress.init();
    progress.setTotal(items.len);
    var cancel = std.atomic.Value(bool).init(false);
    commitItems(&app, &session, cache_dir, items[0..], outcomes[0..], &progress, &cancel);

    try std.testing.expectEqual(@as(usize, 3), state.max_in_flight.load(.monotonic));
    for (outcomes) |outcome| try std.testing.expectEqual(@as(?bool, true), outcome);
    const snap = progress.snapshot();
    try std.testing.expectEqual(jackett.ProgressPhase.done, snap.phase);
    try std.testing.expectEqual(@as(usize, 4), snap.completed);
    try std.testing.expectEqual(@as(usize, 0), snap.failed);
}

test "commitItems stops early when cancel is set, leaving later items unattempted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_abs = try tmp.dir.realPathFileAlloc(compat.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_abs);
    const cache_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_abs, "indexer_cache" });
    defer std.testing.allocator.free(cache_dir);

    const mock = struct {
        fn exec(alloc: std.mem.Allocator, _: jackett_admin.AdminRequest) jackett_admin.AdminError!jackett_admin.AdminResponse {
            return .{ .status = .ok, .body = try alloc.dupe(u8, "{}") };
        }
    };

    var app = App{
        .allocator = std.testing.allocator,
        .client = jackett.Client.init(std.testing.allocator, "http://localhost:9117", "test-key"),
        .deps = .{ .jackett_admin_executor = mock.exec },
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
    };

    var session = jackett_admin.AdminSession{ .cookie = try std.testing.allocator.dupe(u8, "Jackett=abc123") };
    defer session.deinit(std.testing.allocator);

    const items = [_]CommitItem{
        .{ .idx = 0, .enable = true, .id = "ok" },
        .{ .idx = 1, .enable = true, .id = "ok" },
    };
    var outcomes = [_]?bool{ false, false };
    var progress = jackett.Progress.init();
    progress.setTotal(items.len);

    // Cancel before any item runs: no worker starts an item, nothing attempted.
    var cancel = std.atomic.Value(bool).init(true);
    commitItems(&app, &session, cache_dir, items[0..], outcomes[0..], &progress, &cancel);

    const snap = progress.snapshot();
    try std.testing.expectEqual(jackett.ProgressPhase.done, snap.phase);
    try std.testing.expectEqual(@as(usize, 0), snap.completed);
    try std.testing.expectEqual(@as(?bool, null), outcomes[0]);
    try std.testing.expectEqual(@as(?bool, null), outcomes[1]);
}

test "applyCommitOutcomes leaves unattempted rows pending" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_abs = try tmp.dir.realPathFileAlloc(compat.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_abs);
    const status_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_abs, "last_status.json" });
    defer std.testing.allocator.free(status_path);

    const state = struct {
        var test_status_path: []const u8 = &.{};
    };
    state.test_status_path = status_path;
    const mock = struct {
        fn statusPath(alloc: std.mem.Allocator) anyerror![]u8 {
            return alloc.dupe(u8, state.test_status_path);
        }
    };

    var app = App{
        .allocator = std.testing.allocator,
        .client = jackett.Client.init(std.testing.allocator, "http://localhost:9117", "test-key"),
        .deps = .{ .last_status_path_resolver = mock.statusPath },
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
    };

    var widget = indexers_widget.IndexersWidget.init(std.testing.allocator);
    defer widget.deinit();
    try widget.setIndexers(&.{
        .{ .id = "a", .name = "Aaa", .configured = true },
        .{ .id = "b", .name = "Bbb", .configured = true },
    });
    widget.rows[0].pending_active = false;
    widget.rows[1].pending_active = false;

    const items = [_]CommitItem{
        .{ .idx = 0, .enable = false, .id = "a" },
        .{ .idx = 1, .enable = false, .id = "b" },
    };
    const outcomes = [_]?bool{ true, null };

    // Only the first item was attempted; the second keeps its pending toggle
    // and is left untouched (no last_status recorded).
    var failed_names = try applyCommitOutcomes(&app, &widget, items[0..], outcomes[0..]);
    defer failed_names.deinit(std.testing.allocator);

    try std.testing.expect(widget.rows[0].pending_active == null);
    try std.testing.expectEqual(@as(?bool, true), widget.rows[0].last_status);
    try std.testing.expectEqual(@as(?bool, false), widget.rows[1].pending_active);
    try std.testing.expectEqual(@as(?bool, null), widget.rows[1].last_status);
    try std.testing.expectEqual(@as(usize, 0), failed_names.items.len);
}

test "decideProfileSave maps active/match combinations" {
    try std.testing.expectEqual(SaveDecision.first_time, decideProfileSave(false, false));
    try std.testing.expectEqual(SaveDecision.first_time, decideProfileSave(false, true));
    try std.testing.expectEqual(SaveDecision.no_change, decideProfileSave(true, true));
    try std.testing.expectEqual(SaveDecision.choose, decideProfileSave(true, false));
}

test "profile apply enables/disables to match profile and reports failures for retry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_abs = try tmp.dir.realPathFileAlloc(compat.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_abs);
    const cache_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_abs, "indexer_cache" });
    defer std.testing.allocator.free(cache_dir);
    const status_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_abs, "last_status.json" });
    defer std.testing.allocator.free(status_path);

    const state = struct {
        var test_cache_dir: []const u8 = &.{};
        var test_status_path: []const u8 = &.{};
    };
    state.test_cache_dir = cache_dir;
    state.test_status_path = status_path;

    const mock = struct {
        // Every request touching "add" succeeds; everything else (i.e. "drop")
        // fails, so enabling "add" works and disabling "drop" fails.
        fn exec(alloc: std.mem.Allocator, request: jackett_admin.AdminRequest) jackett_admin.AdminError!jackett_admin.AdminResponse {
            if (std.mem.find(u8, request.url, "/indexers/add") != null) {
                return .{ .status = .ok, .body = try alloc.dupe(u8, "{}") };
            }
            return error.HttpError;
        }

        fn cacheDir(alloc: std.mem.Allocator) anyerror![]u8 {
            return alloc.dupe(u8, state.test_cache_dir);
        }

        fn statusPath(alloc: std.mem.Allocator) anyerror![]u8 {
            return alloc.dupe(u8, state.test_status_path);
        }
    };

    var app = App{
        .allocator = std.testing.allocator,
        .client = jackett.Client.init(std.testing.allocator, "http://localhost:9117", "test-key"),
        .deps = .{
            .jackett_admin_executor = mock.exec,
            .jackett_indexer_cache_dir_resolver = mock.cacheDir,
            .last_status_path_resolver = mock.statusPath,
        },
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
    };

    var session = jackett_admin.AdminSession{ .cookie = try std.testing.allocator.dupe(u8, "Jackett=abc123") };
    defer session.deinit(std.testing.allocator);

    // Enabled now: keep, drop. Profile wants: keep, add.
    // Plan: enable "add" (succeeds), disable "drop" (fails -> reported).
    const items = try buildProfileApplyItems(&app, &.{ "keep", "add" }, &.{ "keep", "drop" });
    defer std.testing.allocator.free(items);
    try std.testing.expectEqual(@as(usize, 2), items.len);

    var outcomes: [2]?bool = undefined;
    var progress = jackett.Progress.init();
    progress.setTotal(items.len);
    var cancel = std.atomic.Value(bool).init(false);
    commitItems(&app, &session, cache_dir, items, &outcomes, &progress, &cancel);

    var drop_id = "drop".*;
    var drop_name = "Drop Me".*;
    const remote = [_]jackett_admin.IndexerInfo{
        .{ .id = &drop_id, .name = &drop_name, .configured = true, .categories = drop_name[0..0] },
    };
    var outcome = try collectProfileApplyOutcome(&app, items, &outcomes, &remote);
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), outcome.failed_items.len);
    try std.testing.expectEqualStrings("drop", outcome.failed_items[0].id);
    try std.testing.expect(!outcome.failed_items[0].enable);
    try std.testing.expectEqual(@as(usize, 1), outcome.failed_names.items.len);
    try std.testing.expectEqualStrings("Drop Me", outcome.failed_names.items[0]);

    // Applying a profile also records each indexer's commit outcome.
    var store = try last_status.load(std.testing.allocator, status_path);
    defer store.deinit();
    try std.testing.expectEqual(@as(?bool, true), store.get("add"));
    try std.testing.expectEqual(@as(?bool, false), store.get("drop"));
}

test "buildProfileDetails previews keeps, enables, missing and disables" {
    var ids = [_][3]u8{ "kep".*, "enb".*, "off".*, "dis".* };
    var names = [_][7]u8{ "Charlie".*, "alpha  ".*, "Delta  ".*, "Bravo  ".* };
    const remote = [_]jackett_admin.IndexerInfo{
        .{ .id = &ids[0], .name = names[0][0..7], .configured = true, .categories = names[0][0..0] },
        .{ .id = &ids[1], .name = names[1][0..5], .configured = false, .categories = names[1][0..0] },
        .{ .id = &ids[2], .name = names[2][0..5], .configured = false, .categories = names[2][0..0] },
        .{ .id = &ids[3], .name = names[3][0..5], .configured = true, .categories = names[3][0..0] },
    };

    // Profile: kep (enabled), enb (disabled), gone (unknown to Jackett).
    // "dis" is enabled but not in the profile; "off" is neither.
    const details = try buildProfileDetails(std.testing.allocator, &.{ "kep", "enb", "gone" }, &remote);
    defer std.testing.allocator.free(details);

    try std.testing.expectEqual(@as(usize, 4), details.len);
    try std.testing.expectEqualStrings("alpha", details[0].name);
    try std.testing.expectEqual(profiles_widget.ProfilesWidget.Change.enable, details[0].change);
    try std.testing.expectEqualStrings("Charlie", details[1].name);
    try std.testing.expectEqual(profiles_widget.ProfilesWidget.Change.keep, details[1].change);
    try std.testing.expectEqualStrings("gone", details[2].name);
    try std.testing.expectEqual(profiles_widget.ProfilesWidget.Change.missing, details[2].change);
    // Indexers the load would disable come last.
    try std.testing.expectEqualStrings("Bravo", details[3].name);
    try std.testing.expectEqual(profiles_widget.ProfilesWidget.Change.disable, details[3].change);
}

test "buildProfileApplyItems is empty when sets already match" {
    var app = App{
        .allocator = std.testing.allocator,
        .client = undefined,
        .deps = .{},
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
    };

    const items = try buildProfileApplyItems(&app, &.{ "a", "b" }, &.{ "b", "a" });
    defer std.testing.allocator.free(items);
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "collectProfileApplyOutcome ignores items skipped by a cancel" {
    var app = App{
        .allocator = std.testing.allocator,
        .client = undefined,
        .deps = .{
            .last_status_path_resolver = struct {
                fn f(_: std.mem.Allocator) anyerror![]u8 {
                    return error.NoStatusFileInTests;
                }
            }.f,
        },
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
    };

    const items = [_]CommitItem{
        .{ .idx = 0, .enable = true, .id = "a" },
        .{ .idx = 1, .enable = false, .id = "b" },
    };
    // Only the first item was attempted (and failed); "b" was never tried.
    const outcomes = [_]?bool{ false, null };
    var outcome = try collectProfileApplyOutcome(&app, &items, &outcomes, &.{});
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), outcome.failed_items.len);
    try std.testing.expectEqualStrings("a", outcome.failed_items[0].id);
    try std.testing.expectEqualStrings("a", outcome.failed_names.items[0]);
}

test "activeProfileModified compares the live set with the active profile" {
    var store = profiles.ProfileStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(?bool, null), activeProfileModified(&store, &.{"a"}));

    try store.upsert("Movies", &.{ "a", "b" });
    try std.testing.expectEqual(@as(?bool, null), activeProfileModified(&store, &.{"a"}));

    try store.setActive("Movies");
    try std.testing.expectEqual(@as(?bool, false), activeProfileModified(&store, &.{ "b", "a" }));
    try std.testing.expectEqual(@as(?bool, true), activeProfileModified(&store, &.{"a"}));
}

/// Admin executor for the startup-check tests: password login always
/// succeeds; the indexer list has "a" and "b" configured and "c" not.
const startup_check_mock = struct {
    fn exec(alloc: std.mem.Allocator, request: jackett_admin.AdminRequest) jackett_admin.AdminError!jackett_admin.AdminResponse {
        if (std.mem.endsWith(u8, request.url, "/UI/Dashboard")) {
            return .{ .status = .found, .set_cookie = try alloc.dupe(u8, "Jackett=abc; Path=/") };
        }
        if (std.mem.endsWith(u8, request.url, "/api/v2.0/indexers")) {
            return .{ .status = .ok, .body = try alloc.dupe(u8,
                \\[{"id":"a","name":"A","configured":true},
                \\ {"id":"b","name":"B","configured":true},
                \\ {"id":"c","name":"C","configured":false}]
            ) };
        }
        return error.HttpError;
    }

    fn refused(_: std.mem.Allocator, _: jackett_admin.AdminRequest) jackett_admin.AdminError!jackett_admin.AdminResponse {
        return error.ConnectionRefused;
    }
};

fn testAppForStartupCheck(executor: jackett_admin.AdminExecutor) App {
    return .{
        .allocator = std.testing.allocator,
        .client = jackett.Client.init(std.testing.allocator, "http://localhost:9117", "test-key"),
        .deps = .{ .jackett_admin_executor = executor },
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
        .jackett_admin_password = "secret",
    };
}

test "computeStartupModified compares Jackett's configured indexers with the active profile" {
    const allocator = std.testing.allocator;
    var store = profiles.ProfileStore.init(allocator);
    defer store.deinit();
    try store.upsert("Same", &.{ "b", "a" });
    try store.upsert("Other", &.{"a"});

    try store.setActive("Same");
    try std.testing.expectEqual(StartupModifiedResult.unmodified, computeStartupModified(allocator, "http://x", "secret", startup_check_mock.exec, &store));
    try store.setActive("Other");
    try std.testing.expectEqual(StartupModifiedResult.modified, computeStartupModified(allocator, "http://x", "secret", startup_check_mock.exec, &store));
}

test "computeStartupModified maps Jackett failures to unknown" {
    const allocator = std.testing.allocator;
    var store = profiles.ProfileStore.init(allocator);
    defer store.deinit();
    try store.upsert("Movies", &.{"a"});
    try store.setActive("Movies");

    try std.testing.expectEqual(StartupModifiedResult.unknown, computeStartupModified(allocator, "http://x", "secret", startup_check_mock.refused, &store));
}

test "pollStartupModifiedCheck publishes a finished result once" {
    var app = testAppForStartupCheck(startup_check_mock.refused);

    try std.testing.expect(!pollStartupModifiedCheck(&app));
    try std.testing.expectEqual(@as(?bool, null), app.active_profile_modified);

    app.startup_modified_check.result.store(.modified, .release);
    try std.testing.expect(pollStartupModifiedCheck(&app));
    try std.testing.expectEqual(@as(?bool, true), app.active_profile_modified);
    try std.testing.expect(!pollStartupModifiedCheck(&app));
}

test "pollStartupModifiedCheck leaves the marker unknown when the check failed" {
    var app = testAppForStartupCheck(startup_check_mock.refused);
    app.startup_modified_check.result.store(.unknown, .release);

    try std.testing.expect(!pollStartupModifiedCheck(&app));
    try std.testing.expectEqual(@as(?bool, null), app.active_profile_modified);
}

test "pollStartupModifiedCheck does not clobber a value read by F1/F2" {
    var app = testAppForStartupCheck(startup_check_mock.refused);
    setActiveProfileModified(&app, false);
    app.startup_modified_check.result.store(.modified, .release);

    try std.testing.expect(!pollStartupModifiedCheck(&app));
    try std.testing.expectEqual(@as(?bool, false), app.active_profile_modified);
}

test "startup check runs as a concurrent task and reports its result" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_abs = try tmp.dir.realPathFileAlloc(compat.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_abs);
    const profiles_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_abs, "profiles.json" });
    defer std.testing.allocator.free(profiles_path);

    var seed = profiles.ProfileStore.init(std.testing.allocator);
    defer seed.deinit();
    try seed.upsert("Movies", &.{"a"});
    try seed.setActive("Movies");
    try profiles.save(std.testing.allocator, profiles_path, &seed);

    const state = struct {
        var path: []const u8 = &.{};
        fn profilesPath(alloc: std.mem.Allocator) anyerror![]u8 {
            return alloc.dupe(u8, path);
        }
    };
    state.path = profiles_path;

    var app = testAppForStartupCheck(startup_check_mock.exec);
    app.deps.profiles_path_resolver = state.profilesPath;

    startStartupModifiedCheck(&app);
    try std.testing.expect(app.startup_modified_check.future != null);
    // Wait for the task to finish on its own rather than canceling it.
    while (app.startup_modified_check.result.load(.acquire) == .pending) compat.sleepMillis(5);
    stopStartupModifiedCheck(&app);

    try std.testing.expect(pollStartupModifiedCheck(&app));
    try std.testing.expectEqual(@as(?bool, true), app.active_profile_modified);
}

test "stopping the startup check cancels a Jackett call that never answers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_abs = try tmp.dir.realPathFileAlloc(compat.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_abs);
    const profiles_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_abs, "profiles.json" });
    defer std.testing.allocator.free(profiles_path);

    var seed = profiles.ProfileStore.init(std.testing.allocator);
    defer seed.deinit();
    try seed.upsert("Movies", &.{"a"});
    try seed.setActive("Movies");
    try profiles.save(std.testing.allocator, profiles_path, &seed);

    const state = struct {
        var path: []const u8 = &.{};
        fn profilesPath(alloc: std.mem.Allocator) anyerror![]u8 {
            return alloc.dupe(u8, path);
        }
        // Stands in for a Jackett that accepts the connection and then goes
        // silent: blocks far longer than the test allows, until canceled.
        fn hang(_: std.mem.Allocator, _: jackett_admin.AdminRequest) jackett_admin.AdminError!jackett_admin.AdminResponse {
            std.Io.sleep(compat.io(), .fromSeconds(30), .awake) catch return error.RequestSendFailed;
            return error.HttpError;
        }
    };
    state.path = profiles_path;

    var app = testAppForStartupCheck(state.hang);
    app.deps.profiles_path_resolver = state.profilesPath;

    startStartupModifiedCheck(&app);
    try std.testing.expect(app.startup_modified_check.future != null);
    const started_ms = compat.milliTimestamp();
    stopStartupModifiedCheck(&app);
    try std.testing.expect(compat.milliTimestamp() - started_ms < 5_000);

    try std.testing.expectEqual(StartupModifiedResult.unknown, app.startup_modified_check.result.load(.acquire));
    try std.testing.expect(!pollStartupModifiedCheck(&app));
    try std.testing.expectEqual(@as(?bool, null), app.active_profile_modified);
}

test "startup check is skipped without an active profile" {
    var app = testAppForStartupCheck(startup_check_mock.exec);
    app.deps.profiles_path_resolver = struct {
        fn f(alloc: std.mem.Allocator) anyerror![]u8 {
            return alloc.dupe(u8, "/nonexistent/supersearchr/profiles.json");
        }
    }.f;

    startStartupModifiedCheck(&app);
    defer stopStartupModifiedCheck(&app);
    try std.testing.expect(app.startup_modified_check.future == null);
    try std.testing.expect(!pollStartupModifiedCheck(&app));
    try std.testing.expectEqual(@as(?bool, null), app.active_profile_modified);
}

test "saveProfileStore reports a write failure instead of swallowing it" {
    var app = App{
        .allocator = std.testing.allocator,
        .client = undefined,
        .deps = .{
            .profiles_path_resolver = struct {
                fn f(_: std.mem.Allocator) anyerror![]u8 {
                    return error.NoProfilesPath;
                }
            }.f,
        },
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
    };

    var store = profiles.ProfileStore.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expectError(error.NoProfilesPath, saveProfileStore(&app, &store));
}

test "runProfilesState with no saved profiles returns to previous screen" {
    const mock = struct {
        fn exec(_: std.mem.Allocator, _: jackett_admin.AdminRequest) jackett_admin.AdminError!jackett_admin.AdminResponse {
            return error.ConnectionRefused; // must not be reached: no profiles -> no login
        }
        fn profilesPath(alloc: std.mem.Allocator) anyerror![]u8 {
            return alloc.dupe(u8, "/nonexistent/supersearchr/profiles.json");
        }
    };

    var app = App{
        .allocator = std.testing.allocator,
        .client = jackett.Client.init(std.testing.allocator, "http://localhost:9117", "test-key"),
        .deps = .{
            .jackett_admin_executor = mock.exec,
            .profiles_path_resolver = mock.profilesPath,
        },
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
    };

    var profiles_state = ProfilesState{
        .pending_search_query = try std.testing.allocator.dupe(u8, "ubuntu"),
    };

    try runProfilesState(&app, &profiles_state);

    switch (app.state) {
        .search => |s| {
            defer std.testing.allocator.free(s.query);
            try std.testing.expectEqualStrings("ubuntu", s.query);
        },
        else => return error.UnexpectedState,
    }
}

test "deinitProfilesState frees pending_search_query when returning to search" {
    var app = App{
        .allocator = std.testing.allocator,
        .client = undefined,
        .deps = .{},
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = 24,
        .term_cols = 80,
        .terminal = "xterm",
    };

    var profiles_state = ProfilesState{
        .pending_search_query = try std.testing.allocator.dupe(u8, "ubuntu"),
    };

    deinitProfilesState(&app, &profiles_state);
}
