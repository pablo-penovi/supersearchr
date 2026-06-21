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
    arrow_left,
    arrow_right,
    shift_arrow_up,
    shift_arrow_down,
    f1,
    digit,
    char,
    tab,
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

const win32 = struct {
    pub const HANDLE = *anyopaque;
    pub const DWORD = u32;
    pub const WORD = u16;
    pub const SHORT = i16;
    pub const BOOL = i32;

    pub const COORD = extern struct {
        X: SHORT,
        Y: SHORT,
    };

    pub const SMALL_RECT = extern struct {
        Left: SHORT,
        Top: SHORT,
        Right: SHORT,
        Bottom: SHORT,
    };

    pub const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
        dwSize: COORD,
        dwCursorPosition: COORD,
        wAttributes: WORD,
        srWindow: SMALL_RECT,
        dwMaximumWindowSize: COORD,
    };

    pub const INFINITE: DWORD = 0xFFFFFFFF;
    pub const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
    pub const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));

    pub extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) ?HANDLE;
    pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: ?HANDLE, lpMode: *DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: ?HANDLE, dwMode: DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: ?HANDLE, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) BOOL;
    pub extern "kernel32" fn WaitForSingleObject(hHandle: ?HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
};

var original_termios: std.posix.termios = undefined;
var original_windows_input_mode: win32.DWORD = 0;
var original_windows_output_mode: win32.DWORD = 0;
var term_initialized: bool = false;
var dim_persistent: bool = false;
const escape_sequence_timeout_ms: i32 = 10;
const cursor_steady_block_sequence = "\x1b[2 q";
const cursor_blinking_default_sequence = "\x1b[0 q";

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

    if (b == 0x09) {
        return Event{ .key = .tab, .value = 0 };
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
    // Arrow keys: \x1b[A (up), \x1b[B (down), \x1b[D (left), \x1b[C (right)
    if (std.mem.eql(u8, seq, "[A")) return Event{ .key = .arrow_up, .value = 0 };
    if (std.mem.eql(u8, seq, "[B")) return Event{ .key = .arrow_down, .value = 0 };
    if (std.mem.eql(u8, seq, "[D")) return Event{ .key = .arrow_left, .value = 0 };
    if (std.mem.eql(u8, seq, "[C")) return Event{ .key = .arrow_right, .value = 0 };
    // Shift+arrow: \x1b[1;2A (shift+up), \x1b[1;2B (shift+down)
    if (std.mem.eql(u8, seq, "[1;2A")) return Event{ .key = .shift_arrow_up, .value = 0 };
    if (std.mem.eql(u8, seq, "[1;2B")) return Event{ .key = .shift_arrow_down, .value = 0 };
    // F1: \x1bOP (SS3, most xterm-like terminals) or \x1b[11~ (older/rxvt-style)
    if (std.mem.eql(u8, seq, "OP")) return Event{ .key = .f1, .value = 0 };
    if (std.mem.eql(u8, seq, "[11~")) return Event{ .key = .f1, .value = 0 };
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
    const stdin_handle = win32.GetStdHandle(win32.STD_INPUT_HANDLE) orelse return error.Unexpected;
    const wait_ms: win32.DWORD = @intCast(escape_sequence_timeout_ms);
    const wait_res = win32.WaitForSingleObject(stdin_handle, wait_ms);
    if (wait_res == 0x00000102 or wait_res == 0x00000080 or wait_res == 0xFFFFFFFF) {
        return 0;
    }

    var idx: usize = 0;
    while (idx < buf.len) {
        var single_buf: [1]u8 = undefined;
        const read_n = try compat.readFile(stdin, &single_buf);
        if (read_n == 0) break;
        buf[idx] = single_buf[0];
        idx += 1;
        if (endsEscapeSequence(buf[0..idx])) break;

        const loop_res = win32.WaitForSingleObject(stdin_handle, 0);
        if (loop_res == 0x00000102 or loop_res == 0x00000080 or loop_res == 0xFFFFFFFF) {
            break;
        }
    }
    return idx;
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

pub fn setCursorSteadyBlock() void {
    compat.stdoutWriteAll(cursor_steady_block_sequence);
}

pub fn setCursorBlinkingDefault() void {
    compat.stdoutWriteAll(cursor_blinking_default_sequence);
}

pub fn moveCursor(row: u16, col: u16) void {
    const stdout = std.Io.File.stdout();
    var buf: [32]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "\x1b[{};{}H", .{ row, col }) catch return;
    compat.writeFileAll(stdout, msg) catch {};
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
    const stdin_handle = win32.GetStdHandle(win32.STD_INPUT_HANDLE) orelse return error.Unexpected;
    const stdout_handle = win32.GetStdHandle(win32.STD_OUTPUT_HANDLE) orelse return error.Unexpected;

    if (win32.GetConsoleMode(stdin_handle, &original_windows_input_mode) == 0) {
        return error.Unexpected;
    }
    if (win32.GetConsoleMode(stdout_handle, &original_windows_output_mode) == 0) {
        return error.Unexpected;
    }

    const ENABLE_PROCESSED_INPUT: win32.DWORD = 0x0001;
    const ENABLE_LINE_INPUT: win32.DWORD = 0x0002;
    const ENABLE_ECHO_INPUT: win32.DWORD = 0x0004;
    const ENABLE_QUICK_EDIT_MODE: win32.DWORD = 0x0040;
    const ENABLE_EXTENDED_FLAGS: win32.DWORD = 0x0080;
    const ENABLE_VIRTUAL_TERMINAL_INPUT: win32.DWORD = 0x0200;

    var input_mode = original_windows_input_mode;
    input_mode &= ~ENABLE_LINE_INPUT;
    input_mode &= ~ENABLE_ECHO_INPUT;
    input_mode &= ~ENABLE_PROCESSED_INPUT;
    input_mode &= ~ENABLE_QUICK_EDIT_MODE;
    input_mode |= ENABLE_EXTENDED_FLAGS;
    input_mode |= ENABLE_VIRTUAL_TERMINAL_INPUT;

    if (win32.SetConsoleMode(stdin_handle, input_mode) == 0) {
        return error.Unexpected;
    }

    std.Io.File.stdout().enableAnsiEscapeCodes(compat.io()) catch {};
}

fn deinitWindows() void {
    const stdin_handle = win32.GetStdHandle(win32.STD_INPUT_HANDLE) orelse return;
    const stdout_handle = win32.GetStdHandle(win32.STD_OUTPUT_HANDLE) orelse return;
    _ = win32.SetConsoleMode(stdin_handle, original_windows_input_mode);
    _ = win32.SetConsoleMode(stdout_handle, original_windows_output_mode);
}

fn readKeyWithTimeoutWindows(timeout_ms: i32) !?Event {
    const stdin_handle = win32.GetStdHandle(win32.STD_INPUT_HANDLE) orelse return error.Unexpected;
    const wait_ms: win32.DWORD = if (timeout_ms < 0) win32.INFINITE else @intCast(timeout_ms);
    const wait_res = win32.WaitForSingleObject(stdin_handle, wait_ms);
    if (wait_res == 0x00000102 or wait_res == 0x00000080 or wait_res == 0xFFFFFFFF) {
        return null;
    }
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
    const stdout_handle = win32.GetStdHandle(win32.STD_OUTPUT_HANDLE) orelse return error.Unexpected;
    var info: win32.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (win32.GetConsoleScreenBufferInfo(stdout_handle, &info) == 0) {
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

test "classifyEscapeSequence recognizes F1 in both SS3 and CSI forms" {
    const ss3 = classifyEscapeSequence("OP");
    try std.testing.expectEqual(Key.f1, ss3.key);

    const csi = classifyEscapeSequence("[11~");
    try std.testing.expectEqual(Key.f1, csi.key);
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

test "steady cursor block escape code" {
    try std.testing.expectEqualStrings("\x1b[2 q", cursor_steady_block_sequence);
}

test "cursor blinking default escape code" {
    try std.testing.expectEqualStrings("\x1b[0 q", cursor_blinking_default_sequence);
}
