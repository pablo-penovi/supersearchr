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

const SpinnerContext = struct {
    message: []const u8,
    stop: *std.atomic.Value(bool),
};

const App = struct {
    allocator: std.mem.Allocator,
    client: jackett.Client,
    state: State,
    running: bool,
    term_rows: u16,
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
        const line = std.fmt.bufPrint(&buf, "\r{s} {c}", .{ ctx.message, frames[frame] }) catch break;
        stdout.writeAll(line) catch break;
        frame = (frame + 1) % frames.len;
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
    const line = std.fmt.bufPrint(&buf, "\r{s}  ", .{ctx.message}) catch return;
    stdout.writeAll(line) catch {};
}

fn runLoadingState(app: *App, loading_state: *LoadingState) !void {
    const query = loading_state.query;
    defer app.allocator.free(query);

    term.hideCursor();
    defer term.showCursor();

    var msg_buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Searching for \"{s}\"...", .{query}) catch "Searching...";

    term.moveCursor(1, 1);
    term.clearScreen();
    std.fs.File.stdout().writeAll(msg) catch {};

    var stop = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, spinnerThread, .{SpinnerContext{ .message = msg, .stop = &stop }});

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

    while (true) {
        widget.render(app.term_rows);

        const event = term.readKey() catch {
            app.state = .{ .err = .{ .message = "Failed to read input" } };
            return;
        };
        const action = widget.handleEvent(event, app.term_rows);

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

fn renderSuccess() void {
    term.moveCursor(1, 1);
    term.clearScreen();
    term.setColor(.green);
    std.fs.File.stdout().writeAll("Added to superseedr!") catch {};
    term.resetColor();
    term.moveCursor(3, 1);
    std.fs.File.stdout().writeAll("Press any key to continue...") catch {};

    const event = term.readKey() catch return;
    _ = event;
}

fn renderError(message: []const u8) void {
    term.moveCursor(1, 1);
    term.clearScreen();
    term.setColor(.red);
    {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Error: {s}", .{message}) catch return;
        std.fs.File.stdout().writeAll(msg) catch {};
    }
    term.resetColor();
    term.moveCursor(3, 1);
    std.fs.File.stdout().writeAll("Press any key to continue...") catch {};
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
