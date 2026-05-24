const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");

pub const Key = enum {
    escape,
    enter,
    backspace,
    shift_backspace,
    arrow_up,
    arrow_down,
    shift_arrow_up,
    shift_arrow_down,
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
const escape_sequence_timeout_ms: i32 = 10;

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
    compat.stdoutWriteAll("\x1b[1;1H");

    if (builtin.os.tag == .windows) {
        deinitWindows();
        return;
    }
    deinitPosix();
}

pub fn readKey() !Event {
    const stdin = std.Io.File.stdin();
    var buf: [1]u8 = undefined;
    const byte = try compat.readFile(stdin, &buf);
    if (byte == 0) return error.EndOfStream;
    const b = buf[0];

    if (b == 0x1b) {
        if (builtin.os.tag == .windows) {
            var seq_buf: [32]u8 = undefined;
            const seq_len = try readEscapeSequenceWindows(stdin, &seq_buf);
            if (seq_len > 0) {
                return classifyEscapeSequence(seq_buf[0..seq_len]);
            }
            return Event{ .key = .escape, .value = 0 };
        } else {
            var seq_buf: [32]u8 = undefined;
            const seq_len = try readEscapeSequencePosix(stdin, &seq_buf);
            if (seq_len > 0) {
                return classifyEscapeSequence(seq_buf[0..seq_len]);
            }
            return Event{ .key = .escape, .value = 0 };
        }
    }

    if (b == '\r' or b == '\n') {
        return Event{ .key = .enter, .value = 0 };
    }

    if (b == 0x7f or b == 0x08) {
        if (builtin.os.tag == .windows) {
            if (b == 0x08) return Event{ .key = .backspace, .value = 0 };
            return Event{ .key = .shift_backspace, .value = 0 };
        } else {
            const erase_char = original_termios.cc[@intFromEnum(std.posix.V.ERASE)];
            const is_backspace = if (erase_char != 0) b == erase_char else b == 0x7f;
            if (is_backspace) {
                return Event{ .key = .backspace, .value = 0 };
            } else {
                return Event{ .key = .shift_backspace, .value = 0 };
            }
        }
    }

    if (b >= '0' and b <= '9') {
        return Event{ .key = .digit, .value = b };
    }

    if (b >= 0x20 and b <= 0x7e) {
        return Event{ .key = .char, .value = b };
    }

    return Event{ .key = .unknown, .value = b };
}

fn classifyEscapeSequence(seq: []const u8) Event {
    // Arrow keys: \x1b[A (up), \x1b[B (down)
    if (std.mem.eql(u8, seq, "[A")) return Event{ .key = .arrow_up, .value = 0 };
    if (std.mem.eql(u8, seq, "[B")) return Event{ .key = .arrow_down, .value = 0 };
    // Shift+arrow: \x1b[1;2A (shift+up), \x1b[1;2B (shift+down)
    if (std.mem.eql(u8, seq, "[1;2A")) return Event{ .key = .shift_arrow_up, .value = 0 };
    if (std.mem.eql(u8, seq, "[1;2B")) return Event{ .key = .shift_arrow_down, .value = 0 };
    // Shift+backspace variants
    if (std.mem.eql(u8, seq, "[127;2u") or
        std.mem.eql(u8, seq, "[8;2u") or
        std.mem.eql(u8, seq, "[3;2~") or
        std.mem.eql(u8, seq, "[27;2;127~") or
        std.mem.eql(u8, seq, "[27;2;8~"))
    {
        return Event{ .key = .shift_backspace, .value = 0 };
    }
    return Event{ .key = .unknown, .value = 0 };
}

fn consumeEscapeSequence(stdin: std.Io.File) !bool {
    if (builtin.os.tag == .windows) {
        return consumeEscapeSequenceWindows(stdin);
    }

    var dummy: [32]u8 = undefined;
    const len = try readEscapeSequencePosix(stdin, &dummy);
    return len > 0;
}

fn readEscapeSequencePosix(stdin: std.Io.File, buf: []u8) !usize {
    var poll_fds = [_]std.posix.pollfd{
        .{
            .fd = stdin.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };

    var idx: usize = 0;
    while (idx < buf.len) {
        poll_fds[0].revents = 0;
        const ready = try std.posix.poll(&poll_fds, escape_sequence_timeout_ms);
        if (ready == 0) break;
        if ((poll_fds[0].revents & std.posix.POLL.IN) == 0) break;

        var single_buf: [1]u8 = undefined;
        const read_n = try compat.readFile(stdin, &single_buf);
        if (read_n == 0) break;

        buf[idx] = single_buf[0];
        idx += 1;

        if (endsEscapeSequence(buf[0..idx])) break;
    }
    return idx;
}

fn readEscapeSequenceWindows(stdin: std.Io.File, buf: []u8) !usize {
    const stdin_handle = try windows.GetStdHandle(windows.STD_INPUT_HANDLE);
    const wait_ms: windows.DWORD = @intCast(escape_sequence_timeout_ms);
    windows.WaitForSingleObject(stdin_handle, wait_ms) catch |err| switch (err) {
        error.WaitAbandoned => return 0,
        error.WaitTimeOut => return 0,
        else => return err,
    };

    var idx: usize = 0;
    while (idx < buf.len) {
        var single_buf: [1]u8 = undefined;
        const read_n = try compat.readFile(stdin, &single_buf);
        if (read_n == 0) break;
        buf[idx] = single_buf[0];
        idx += 1;
        if (endsEscapeSequence(buf[0..idx])) break;

        windows.WaitForSingleObject(stdin_handle, 0) catch |err| switch (err) {
            error.WaitAbandoned => break,
            error.WaitTimeOut => break,
            else => return err,
        };
    }
    return idx;
}

fn consumeEscapeSequenceWindows(stdin: std.Io.File) !bool {
    var dummy: [32]u8 = undefined;
    const len = try readEscapeSequenceWindows(stdin, &dummy);
    return len > 0;
}

fn endsEscapeSequence(bytes: []const u8) bool {
    for (bytes, 0..) |byte, idx| {
        if (idx == 0 and (byte == '[' or byte == 'O' or byte == ']')) continue;
        if (byte >= 0x40 and byte <= 0x7e) return true;
    }
    return false;
}

pub fn readKeyWithTimeout(timeout_ms: i32) !?Event {
    if (builtin.os.tag == .windows) {
        return try readKeyWithTimeoutWindows(timeout_ms);
    }

    const stdin = std.Io.File.stdin();
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

    const stdin = std.Io.File.stdin();
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

        const read_n = compat.readFile(stdin, &buf) catch return;
        if (read_n == 0) break;
        poll_fds[0].revents = 0;
    }
}

pub fn clearScreen() void {
    compat.stdoutWriteAll("\x1b[2J");
}

pub fn clearBelow() void {
    compat.stdoutWriteAll("\x1b[J");
}

pub fn beginSyncRender() void {
    compat.stdoutWriteAll("\x1b[?2026h");
}

pub fn endSyncRender() void {
    compat.stdoutWriteAll("\x1b[?2026l");
}

pub fn hideCursor() void {
    compat.stdoutWriteAll("\x1b[?25l");
}

pub fn showCursor() void {
    compat.stdoutWriteAll("\x1b[?25h");
}

pub fn moveCursor(row: u16, col: u16) void {
    const stdout = std.Io.File.stdout();
    var buf: [32]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "\x1b[{};{}H", .{ row, col }) catch return;
    compat.writeFileAll(stdout, msg) catch {};
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
    compat.stdoutWriteAll(msg);
}

pub fn setFg256(code: u8) void {
    var buf: [24]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "\x1b[38;5;{}m", .{code}) catch return;
    compat.stdoutWriteAll(msg);
}

pub fn setBg256(code: u8) void {
    var buf: [24]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "\x1b[48;5;{}m", .{code}) catch return;
    compat.stdoutWriteAll(msg);
}

pub fn setBold(on: bool) void {
    if (on) {
        compat.stdoutWriteAll("\x1b[1m");
    } else {
        compat.stdoutWriteAll("\x1b[22m");
    }
}

pub fn setDim(on: bool) void {
    if (on) {
        compat.stdoutWriteAll("\x1b[2m");
    } else {
        compat.stdoutWriteAll("\x1b[22m");
    }
}

pub fn setDimPersistent(on: bool) void {
    dim_persistent = on;
    setDim(on);
}

pub fn resetColor() void {
    compat.stdoutWriteAll("\x1b[0m");
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
    const stdin = std.Io.File.stdin();
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
    const stdin = std.Io.File.stdin();
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

    std.Io.File.stdout().enableAnsiEscapeCodes(compat.io()) catch {};
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
    const stdin = std.Io.File.stdin();
    var winsize: std.posix.winsize = undefined;
    const result = std.os.linux.ioctl(stdin.handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&winsize));

    if (result == 0) {
        return TerminalSize{ .rows = winsize.row, .cols = winsize.col };
    }

    return error.Unexpected;
}

fn getTerminalSizePosixIoctl() !TerminalSize {
    const stdin = std.Io.File.stdin();
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

test "endsEscapeSequence waits for CSI final byte" {
    try std.testing.expect(!endsEscapeSequence("["));
    try std.testing.expect(endsEscapeSequence("[A"));
    try std.testing.expect(endsEscapeSequence("[1;5D"));
}

test "endsEscapeSequence treats alt key suffix as complete sequence" {
    try std.testing.expect(endsEscapeSequence("x"));
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
