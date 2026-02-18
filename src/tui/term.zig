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

pub fn init() !void {
    const stdin = std.io.getStdIn();
    original_termios = try std.posix.tcgetattr(stdin.handle);
    term_initialized = true;

    var raw = original_termios;
    raw.lflag.cbreak = true;
    raw.lflag.echo = false;
    raw.iflag.ignbrk = false;
    raw.iflag.brkint = false;
    raw.iflag.parmrk = false;
    raw.iflag.inpck = false;
    raw.iflag.istrip = false;
    raw.iflag.inlcr = false;
    raw.iflag.igncr = false;
    raw.iflag.icrnl = false;
    raw.iflag.ixon = false;
    raw.iflag.ixany = false;
    raw.iflag.ixoff = false;
    raw.iflag.imaxbel = false;
    raw.oflag.opost = false;
    raw.cflagPARENB = false;
    raw.cflagCS8 = true;

    try std.posix.tcsetattr(stdin.handle, .now, raw);
}

pub fn deinit() void {
    if (!term_initialized) return;
    term_initialized = false;

    const stdin = std.io.getStdIn();
    std.posix.tcsetattr(stdin.handle, .now, original_termios) catch {};
}

pub fn readKey() !Event {
    const stdin = std.io.getStdIn();
    const byte = try stdin.reader().readByte();

    if (byte == 0x1b) {
        return Event{ .key = .escape, .value = 0 };
    }

    if (byte == '\r' or byte == '\n') {
        return Event{ .key = .enter, .value = 0 };
    }

    if (byte == 0x7f or byte == 0x08) {
        return Event{ .key = .backspace, .value = 0 };
    }

    if (byte >= '0' and byte <= '9') {
        return Event{ .key = .digit, .value = byte };
    }

    if (byte >= 'a' and byte <= 'z') {
        return Event{ .key = .char, .value = byte };
    }

    if (byte >= 'A' and byte <= 'Z') {
        return Event{ .key = .char, .value = byte };
    }

    return Event{ .key = .unknown, .value = byte };
}

pub fn clearScreen() void {
    std.io.getStdOut().writeAll("\x1b[2J") catch {};
}

pub fn moveCursor(row: u16, col: u16) void {
    const stdout = std.io.getStdOut();
    stdout.writer().print("\x1b[{};{}H", .{ row, col }) catch {};
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
    const stdout = std.io.getStdOut();
    stdout.writer().print("\x1b[{}m", .{code}) catch {};
}

pub fn resetColor() void {
    std.io.getStdOut().writeAll("\x1b[0m") catch {};
}

pub fn getTerminalSize() !struct { rows: u16, cols: u16 } {
    const stdin = std.io.getStdIn();
    var winsize: std.os.linux.winsize = undefined;
    const result = std.os.linux.ioctl(stdin.handle, std.os.linux.TIOCGWINSZ, @intFromPtr(&winsize));

    if (result == 0) {
        return .{ .rows = winsize.ws_row, .cols = winsize.ws_col };
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
