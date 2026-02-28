const std = @import("std");
const builtin = @import("builtin");

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

const windows = std.os.windows;

var original_termios: std.posix.termios = undefined;
var original_windows_input_mode: windows.DWORD = 0;
var original_windows_output_mode: windows.DWORD = 0;
var term_initialized: bool = false;
var dim_persistent: bool = false;

pub fn init() !void {
    term_initialized = true;
    dim_persistent = false;

    if (builtin.os.tag == .windows) {
        try initWindows();
        return;
    }

    try initPosix();
}

pub fn deinit() void {
    if (!term_initialized) return;
    term_initialized = false;
    dim_persistent = false;

    clearScreen();
    std.fs.File.stdout().writeAll("\x1b[1;1H") catch {};

    if (builtin.os.tag == .windows) {
        deinitWindows();
        return;
    }
    deinitPosix();
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
    if (builtin.os.tag == .windows) {
        return try readKeyWithTimeoutWindows(timeout_ms);
    }

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
    if (builtin.os.tag == .windows) {
        return;
    }

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
    if (builtin.os.tag == .windows) {
        return try getTerminalSizeWindows();
    }
    if (builtin.os.tag == .linux) {
        return getTerminalSizeLinux();
    }
    return try getTerminalSizePosixIoctl();
}

fn initPosix() !void {
    const stdin = std.fs.File.stdin();
    original_termios = try std.posix.tcgetattr(stdin.handle);

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

fn deinitPosix() void {
    const stdin = std.fs.File.stdin();
    std.posix.tcsetattr(stdin.handle, .NOW, original_termios) catch {};
}

fn initWindows() !void {
    const stdin_handle = try windows.GetStdHandle(windows.STD_INPUT_HANDLE);
    const stdout_handle = try windows.GetStdHandle(windows.STD_OUTPUT_HANDLE);

    if (windows.kernel32.GetConsoleMode(stdin_handle, &original_windows_input_mode) == 0) {
        return error.Unexpected;
    }
    if (windows.kernel32.GetConsoleMode(stdout_handle, &original_windows_output_mode) == 0) {
        return error.Unexpected;
    }

    const ENABLE_PROCESSED_INPUT: windows.DWORD = 0x0001;
    const ENABLE_LINE_INPUT: windows.DWORD = 0x0002;
    const ENABLE_ECHO_INPUT: windows.DWORD = 0x0004;
    const ENABLE_QUICK_EDIT_MODE: windows.DWORD = 0x0040;
    const ENABLE_EXTENDED_FLAGS: windows.DWORD = 0x0080;
    const ENABLE_VIRTUAL_TERMINAL_INPUT: windows.DWORD = 0x0200;

    var input_mode = original_windows_input_mode;
    input_mode &= ~ENABLE_LINE_INPUT;
    input_mode &= ~ENABLE_ECHO_INPUT;
    input_mode &= ~ENABLE_PROCESSED_INPUT;
    input_mode &= ~ENABLE_QUICK_EDIT_MODE;
    input_mode |= ENABLE_EXTENDED_FLAGS;
    input_mode |= ENABLE_VIRTUAL_TERMINAL_INPUT;

    if (windows.kernel32.SetConsoleMode(stdin_handle, input_mode) == 0) {
        return error.Unexpected;
    }

    _ = std.fs.File.stdout().getOrEnableAnsiEscapeSupport();
}

fn deinitWindows() void {
    const stdin_handle = windows.GetStdHandle(windows.STD_INPUT_HANDLE) catch return;
    const stdout_handle = windows.GetStdHandle(windows.STD_OUTPUT_HANDLE) catch return;
    _ = windows.kernel32.SetConsoleMode(stdin_handle, original_windows_input_mode);
    _ = windows.kernel32.SetConsoleMode(stdout_handle, original_windows_output_mode);
}

fn readKeyWithTimeoutWindows(timeout_ms: i32) !?Event {
    const stdin_handle = try windows.GetStdHandle(windows.STD_INPUT_HANDLE);
    const wait_ms: windows.DWORD = if (timeout_ms < 0) windows.INFINITE else @intCast(timeout_ms);
    windows.WaitForSingleObject(stdin_handle, wait_ms) catch |err| switch (err) {
        error.WaitAbandoned => return null,
        error.WaitTimeOut => return null,
        else => return err,
    };
    return try readKey();
}

fn getTerminalSizeLinux() !TerminalSize {
    const stdin = std.fs.File.stdin();
    var winsize: std.posix.winsize = undefined;
    const result = std.os.linux.ioctl(stdin.handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&winsize));

    if (result == 0) {
        return TerminalSize{ .rows = winsize.row, .cols = winsize.col };
    }

    return error.Unexpected;
}

fn getTerminalSizePosixIoctl() !TerminalSize {
    const stdin = std.fs.File.stdin();
    var winsize: std.posix.winsize = undefined;
    const result = std.c.ioctl(stdin.handle, std.c.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (result == 0) {
        return TerminalSize{ .rows = winsize.row, .cols = winsize.col };
    }
    return error.Unexpected;
}

fn getTerminalSizeWindows() !TerminalSize {
    const stdout_handle = try windows.GetStdHandle(windows.STD_OUTPUT_HANDLE);
    var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (windows.kernel32.GetConsoleScreenBufferInfo(stdout_handle, &info) == 0) {
        return error.Unexpected;
    }

    const width_i32 = @as(i32, info.srWindow.Right) - @as(i32, info.srWindow.Left) + 1;
    const height_i32 = @as(i32, info.srWindow.Bottom) - @as(i32, info.srWindow.Top) + 1;
    if (width_i32 <= 0 or height_i32 <= 0) return error.Unexpected;

    return TerminalSize{
        .rows = @as(u16, @intCast(height_i32)),
        .cols = @as(u16, @intCast(width_i32)),
    };
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
