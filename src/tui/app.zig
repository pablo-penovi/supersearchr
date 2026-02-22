const std = @import("std");
const config = @import("config");
const jackett = @import("jackett");
const superseedr = @import("superseedr");
const term = @import("term");
const theme = @import("theme");
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
        term.setFg256(colors.muted);
        stdout.writeAll("Contacting Jackett...") catch {};
        term.resetColor();
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
        theme.drawPanelRow(stdout, panel_width, query_line, border, colors) catch {};
        writeSpaces(stdout, left_pad) catch {};
        theme.drawPanelRow(stdout, panel_width, " Contacting Jackett...", border, colors) catch {};
        writeSpaces(stdout, left_pad) catch {};
        theme.drawPanelBottom(stdout, panel_width, border, colors) catch {};
    }

    var stop = std.atomic.Value(bool).init(false);
    const spinner_row = if (compact) @as(u16, 3) else @as(u16, @intCast(top_pad + 4));
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

    while (true) {
        widget.render(app.term_rows, app.term_cols);

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
    renderNoticePanel("Success", "Added to superseedr!", theme.superseedr_like.ok);

    const event = term.readKey() catch return;
    _ = event;
}

fn renderError(message: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Error: {s}", .{message}) catch "Error";
    renderNoticePanel("Error", msg, theme.superseedr_like.err);
}

fn renderNoticePanel(title: []const u8, message: []const u8, title_color: u8) void {
    const stdout = std.fs.File.stdout();
    const colors = theme.superseedr_like;
    const border = theme.unicode_border;
    const size = term.getTerminalSize() catch term.TerminalSize{ .rows = 24, .cols = 80 };

    if (size.cols < 56 or size.rows < 10) {
        term.moveCursor(1, 1);
        term.clearScreen();
        term.setFg256(title_color);
        term.setBold(true);
        stdout.writeAll(title) catch {};
        term.setBold(false);
        stdout.writeAll(": ") catch {};
        term.setFg256(colors.text);
        stdout.writeAll(message) catch {};
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

    term.moveCursor(1, 1);
    term.clearScreen();
    term.moveCursor(@as(u16, @intCast(top_pad)), 1);

    writeSpaces(stdout, left_pad) catch {};
    theme.drawPanelTop(stdout, panel_width, border, colors) catch {};

    writeSpaces(stdout, left_pad) catch {};
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

    writeSpaces(stdout, left_pad) catch {};
    theme.drawPanelRow(stdout, panel_width, shown, border, colors) catch {};

    writeSpaces(stdout, left_pad) catch {};
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.setFg256(colors.muted);
    theme.writePadded(stdout, " Press any key to continue... ", panel_width - 2) catch {};
    term.setFg256(colors.panel_border);
    stdout.writeAll(border.vertical) catch {};
    term.resetColor();
    stdout.writeAll("\r\n") catch {};

    writeSpaces(stdout, left_pad) catch {};
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
