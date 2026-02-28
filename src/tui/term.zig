const std = @import("std");

pub const Key = enum {
    escape,
    enter,
    backspace,
    digit,
    char,
    unknown,
};

pub const Event = struct {
    key: Key,
    value: u8,
};

pub const Color = enum {
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,
};

var original_termios: std.posix.termios = undefined;
var term_initialized: bool = false;
var dim_persistent: bool = false;

pub fn init() !void {
    const stdin = std.fs.File.stdin();
    original_termios = try std.posix.tcgetattr(stdin.handle);
    term_initialized = true;
    dim_persistent = false;

    var raw = original_termios;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.iflag.IGNBRK = false;
    raw.iflag.BRKINT = false;
    raw.iflag.PARMRK = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.iflag.IXANY = false;
    raw.iflag.IXOFF = false;
    raw.iflag.IMAXBEL = false;
    raw.oflag.OPOST = false;
    raw.cflag.PARENB = false;
    raw.cflag.CSIZE = .CS8;

    try std.posix.tcsetattr(stdin.handle, .NOW, raw);
}

pub fn deinit() void {
    if (!term_initialized) return;
    term_initialized = false;
    dim_persistent = false;

    clearScreen();
    std.fs.File.stdout().writeAll("\x1b[1;1H") catch {};

    const stdin = std.fs.File.stdin();
    std.posix.tcsetattr(stdin.handle, .NOW, original_termios) catch {};
}

pub fn readKey() !Event {
    const stdin = std.fs.File.stdin();
    var buf: [1]u8 = undefined;
    const byte = try stdin.read(&buf);
    if (byte == 0) return error.EndOfStream;
    const b = buf[0];

    if (b == 0x1b) {
        return Event{ .key = .escape, .value = 0 };
    }

    if (b == '\r' or b == '\n') {
        return Event{ .key = .enter, .value = 0 };
    }

    if (b == 0x7f or b == 0x08) {
        return Event{ .key = .backspace, .value = 0 };
    }

    if (b >= '0' and b <= '9') {
        return Event{ .key = .digit, .value = b };
    }

    if (b >= 0x20 and b <= 0x7e) {
        return Event{ .key = .char, .value = b };
    }

    return Event{ .key = .unknown, .value = b };
}

pub fn readKeyWithTimeout(timeout_ms: i32) !?Event {
    const stdin = std.fs.File.stdin();
    var poll_fds = [_]std.posix.pollfd{
        .{
            .fd = stdin.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };

    const ready = try std.posix.poll(&poll_fds, timeout_ms);
    if (ready == 0) return null;
    if ((poll_fds[0].revents & std.posix.POLL.IN) == 0) return null;
    return try readKey();
}

pub fn discardPendingInput() void {
    const stdin = std.fs.File.stdin();
    var poll_fds = [_]std.posix.pollfd{
        .{
            .fd = stdin.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    var buf: [64]u8 = undefined;

    while (true) {
        const ready = std.posix.poll(&poll_fds, 0) catch return;
        if (ready == 0) break;
        if ((poll_fds[0].revents & std.posix.POLL.IN) == 0) break;

        const read_n = stdin.read(&buf) catch return;
        if (read_n == 0) break;
        poll_fds[0].revents = 0;
    }
}

pub fn clearScreen() void {
    std.fs.File.stdout().writeAll("\x1b[2J") catch {};
}

pub fn hideCursor() void {
    std.fs.File.stdout().writeAll("\x1b[?25l") catch {};
}

pub fn showCursor() void {
    std.fs.File.stdout().writeAll("\x1b[?25h") catch {};
}

pub fn moveCursor(row: u16, col: u16) void {
    const stdout = std.fs.File.stdout();
    var buf: [32]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "\x1b[{};{}H", .{ row, col }) catch return;
    stdout.writeAll(msg) catch {};
}

pub fn setColor(fg: Color) void {
    const code: u8 = switch (fg) {
        .black => 30,
        .red => 31,
        .green => 32,
        .yellow => 33,
        .blue => 34,
        .magenta => 35,
        .cyan => 36,
        .white => 37,
        .bright_black => 90,
        .bright_red => 91,
        .bright_green => 92,
        .bright_yellow => 93,
        .bright_blue => 94,
        .bright_magenta => 95,
        .bright_cyan => 96,
        .bright_white => 97,
    };
    var buf: [16]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "\x1b[{}m", .{code}) catch return;
    std.fs.File.stdout().writeAll(msg) catch {};
}

pub fn setFg256(code: u8) void {
    var buf: [24]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "\x1b[38;5;{}m", .{code}) catch return;
    std.fs.File.stdout().writeAll(msg) catch {};
}

pub fn setBg256(code: u8) void {
    var buf: [24]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "\x1b[48;5;{}m", .{code}) catch return;
    std.fs.File.stdout().writeAll(msg) catch {};
}

pub fn setBold(on: bool) void {
    if (on) {
        std.fs.File.stdout().writeAll("\x1b[1m") catch {};
    } else {
        std.fs.File.stdout().writeAll("\x1b[22m") catch {};
    }
}

pub fn setDim(on: bool) void {
    if (on) {
        std.fs.File.stdout().writeAll("\x1b[2m") catch {};
    } else {
        std.fs.File.stdout().writeAll("\x1b[22m") catch {};
    }
}

pub fn setDimPersistent(on: bool) void {
    dim_persistent = on;
    setDim(on);
}

pub fn resetColor() void {
    std.fs.File.stdout().writeAll("\x1b[0m") catch {};
    if (dim_persistent) {
        setDim(true);
    }
}

pub fn reverseVideo(writer: anytype) !void {
    try writer.writeAll("\x1b[7m");
}

pub fn reverseVideoOff(writer: anytype) !void {
    try writer.writeAll("\x1b[27m");
}

pub const TerminalSize = struct { rows: u16, cols: u16 };

pub fn getTerminalSize() !TerminalSize {
    const stdin = std.fs.File.stdin();
    var winsize: std.posix.winsize = undefined;
    const result = std.os.linux.ioctl(stdin.handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&winsize));

    if (result == 0) {
        return TerminalSize{ .rows = winsize.row, .cols = winsize.col };
    }

    return error.Unexpected;
}

test "color escape codes" {
    const Testing = @import("std").testing;
    var buf: [16]u8 = undefined;

    const result = std.fmt.bufPrint(&buf, "\x1b[{}m", .{30}) catch unreachable;
    try Testing.expectEqualStrings("\x1b[30m", result);
}

test "cursor position escape code" {
    const Testing = @import("std").testing;
    var buf: [32]u8 = undefined;

    const result = std.fmt.bufPrint(&buf, "\x1b[{};{}H", .{ 5, 10 }) catch unreachable;
    try Testing.expectEqualStrings("\x1b[5;10H", result);
}

test "256 color fg escape code" {
    const Testing = @import("std").testing;
    var buf: [24]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, "\x1b[38;5;{}m", .{33}) catch unreachable;
    try Testing.expectEqualStrings("\x1b[38;5;33m", result);
}

test "256 color bg escape code" {
    const Testing = @import("std").testing;
    var buf: [24]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, "\x1b[48;5;{}m", .{236}) catch unreachable;
    try Testing.expectEqualStrings("\x1b[48;5;236m", result);
}
