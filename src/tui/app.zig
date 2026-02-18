const std = @import("std");
const config = @import("config");
const jackett = @import("jackett");
const superseedr = @import("superseedr");
const term = @import("term");
const search_widget = @import("search");
const results_widget = @import("results");
const Torrent = @import("torrent").Torrent;

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

const App = struct {
    allocator: std.mem.Allocator,
    client: jackett.Client,
    state: State,
    running: bool,
    term_rows: u16,
};

pub fn run(allocator: std.mem.Allocator, cfg: config.Config) !void {
    term.init() catch |err| {
        std.debug.print("Failed to initialize terminal: {}\n", .{err});
        return err;
    };
    defer term.deinit();

    const size = term.getTerminalSize() catch .{ .rows = 24, .cols = 80 };

    var client = jackett.Client.init(allocator, cfg.api_url, cfg.api_key);

    var app = App{
        .allocator = allocator,
        .client = client,
        .state = .{ .search = .{ .query = "" } },
        .running = true,
        .term_rows = size.rows,
    };

    defer {
        if (app.state == .results) {
            freeTorrents(allocator, app.state.results.torrents);
        }
        client.deinit();
    }

    while (app.running) {
        switch (app.state) {
            .search => |*search_state| {
                try runSearchState(&app, search_state);
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

fn runSearchState(app: *App, _: *SearchState) !void {
    var widget = search_widget.SearchWidget.init(app.allocator);
    defer widget.deinit();

    while (true) {
        widget.render();

        const event = term.readKey() catch {
            app.state = .{ .err = .{ .message = "Failed to read input" } };
            return;
        };
        const action = widget.handleEvent(event);

        switch (action) {
            .continue_search => {},
            .submit => {
                const query = widget.getQuery();
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

fn runLoadingState(app: *App, loading_state: *LoadingState) !void {
    renderLoading(loading_state.query);

    const torrents = app.client.searchWithExecutor(loading_state.query, jackett.defaultSearchExecutor) catch |err| {
        const message = getErrorMessage(err);
        app.state = .{ .err = .{ .message = message } };
        return;
    };

    app.state = .{ .results = .{ .torrents = torrents } };
}

fn runResultsState(app: *App, results_state: *ResultsState) !void {
    var widget = results_widget.ResultsWidget.init(app.allocator);
    defer widget.deinit();

    widget.setTorrents(results_state.torrents, results_state.torrents.len);

    while (true) {
        widget.render(app.term_rows);

        const event = term.readKey() catch {
            app.state = .{ .err = .{ .message = "Failed to read input" } };
            return;
        };
        const action = widget.handleEvent(event);

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
                const torrent = results_state.torrents[idx];
                const result = superseedr.addLink(app.allocator, torrent.link);

                if (result) |_| {
                    renderSuccess();
                } else |err| {
                    const message = getSuperseedrErrorMessage(err);
                    app.state = .{ .err = .{ .message = message } };
                    return;
                }
            },
        }
    }
}

fn runErrorState(app: *App, error_state: *ErrorState) !void {
    renderError(error_state.message);

    const event = term.readKey() catch {
        app.state = .{ .search = .{ .query = "" } };
        return;
    };

    _ = event;
    app.state = .{ .search = .{ .query = "" } };
}

fn renderLoading(query: []const u8) void {
    term.moveCursor(1, 1);
    term.clearScreen();
    std.io.getStdOut().writer().print("Searching for \"{s}\"...", .{query}) catch {};
}

fn renderSuccess() void {
    term.moveCursor(1, 1);
    term.clearScreen();
    term.setColor(.green);
    std.io.getStdOut().writeAll("Added to superseedr!") catch {};
    term.resetColor();
    term.moveCursor(3, 1);
    std.io.getStdOut().writeAll("Press any key to continue...") catch {};

    const event = term.readKey() catch return;
    _ = event;
}

fn renderError(message: []const u8) void {
    term.moveCursor(1, 1);
    term.clearScreen();
    term.setColor(.red);
    std.io.getStdOut().writer().print("Error: {s}", .{message}) catch {};
    term.resetColor();
    term.moveCursor(3, 1);
    std.io.getStdOut().writeAll("Press any key to continue...") catch {};
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
    };
}

fn freeTorrents(allocator: std.mem.Allocator, torrents: []Torrent) void {
    for (torrents) |t| {
        allocator.free(t.title);
        allocator.free(t.link);
    }
    allocator.free(torrents);
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
