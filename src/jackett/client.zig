const std = @import("std");
const Torrent = @import("torrent").Torrent;
const debug_log = @import("debug_log");
const compat = @import("compat");

pub const JackettError = error{
    InvalidUrl,
    ConnectionRefused,
    RequestCreateFailed,
    RequestSendFailed,
    ResponseHeadReadFailed,
    HttpError,
    ResponseReadFailed,
    ParseFailed,
    OutOfMemory,
};

const xml_tags = .{
    .item = "<item>",
    .item_end = "</item>",
    .indexer = "<indexer ",
    .indexer_end = "</indexer>",
    .indexer_id = "id=\"",
    .title = "<title>",
    .size = "<size>",
    .link = "<link>",
    .enclosure = "<enclosure ",
    .magneturl_attr_name = "name=\"magneturl\"",
    .size_attr_name = "name=\"size\"",
    .attr_value = "value=\"",
    .enclosure_url = "url=\"",
    .enclosure_length = "length=\"",
    .seeders_attr = "<torznab:attr name=\"seeders\" value=\"",
    .peers_attr = "<torznab:attr name=\"peers\" value=\"",
    .pub_date = "<pubDate>",
};

fn extractStringField(xml: []const u8, i: usize, tag: []const u8) ?struct { value: []const u8, end: usize } {
    if (std.mem.startsWith(u8, xml[i..], tag)) {
        const start = i + tag.len;
        const end = std.mem.indexOfScalarPos(u8, xml, start, '<') orelse xml.len;
        return .{ .value = xml[start..end], .end = end };
    }
    return null;
}

fn isLeapYear(year: i64) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or (@mod(year, 400) == 0);
}

const days_in_months = [12]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

fn dateToEpoch(year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64) i64 {
    var days: i64 = 0;
    var y: i64 = 1970;
    while (y < year) : (y += 1) {
        days += if (isLeapYear(y)) @as(i64, 366) else @as(i64, 365);
    }
    var m: i64 = 1;
    while (m < month) : (m += 1) {
        if (m == 2 and isLeapYear(year)) {
            days += 29;
        } else {
            days += days_in_months[@intCast(m - 1)];
        }
    }
    days += (day - 1);
    return days * 86400 + hour * 3600 + minute * 60 + second;
}

fn parseMonthName(name: []const u8) ?i64 {
    const months = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
    var lower: [3]u8 = undefined;
    if (name.len < 3) return null;
    for (0..3) |k| {
        lower[k] = std.ascii.toLower(name[k]);
    }
    for (months, 0..) |m, idx| {
        if (std.mem.eql(u8, lower[0..], m)) {
            return @intCast(idx + 1);
        }
    }
    return null;
}

fn parseTimezoneOffset(tz: []const u8) i64 {
    const trimmed = std.mem.trim(u8, tz, " \t\r\n");
    if (trimmed.len == 0) return 0;
    if (std.mem.eql(u8, trimmed, "Z") or std.mem.eql(u8, trimmed, "GMT") or std.mem.eql(u8, trimmed, "UTC") or std.mem.eql(u8, trimmed, "UT")) {
        return 0;
    }
    if (std.mem.eql(u8, trimmed, "EST")) return -5 * 3600;
    if (std.mem.eql(u8, trimmed, "EDT")) return -4 * 3600;
    if (std.mem.eql(u8, trimmed, "CST")) return -6 * 3600;
    if (std.mem.eql(u8, trimmed, "CDT")) return -5 * 3600;
    if (std.mem.eql(u8, trimmed, "MST")) return -7 * 3600;
    if (std.mem.eql(u8, trimmed, "MDT")) return -6 * 3600;
    if (std.mem.eql(u8, trimmed, "PST")) return -8 * 3600;
    if (std.mem.eql(u8, trimmed, "PDT")) return -7 * 3600;

    if (trimmed[0] == '+' or trimmed[0] == '-') {
        const sign: i64 = if (trimmed[0] == '+') 1 else -1;
        const digits = trimmed[1..];
        var hh: i64 = 0;
        var mm: i64 = 0;
        if (std.mem.indexOfScalar(u8, digits, ':')) |colon| {
            hh = std.fmt.parseInt(i64, digits[0..colon], 10) catch 0;
            mm = std.fmt.parseInt(i64, digits[colon + 1 ..], 10) catch 0;
        } else {
            if (digits.len >= 4) {
                hh = std.fmt.parseInt(i64, digits[0..2], 10) catch 0;
                mm = std.fmt.parseInt(i64, digits[2..4], 10) catch 0;
            } else if (digits.len >= 2) {
                hh = std.fmt.parseInt(i64, digits[0..2], 10) catch 0;
            }
        }
        return sign * (hh * 3600 + mm * 60);
    }
    return 0;
}

pub fn parseRssDate(raw_date: []const u8) ?i64 {
    var date_str = std.mem.trim(u8, raw_date, " \t\r\n");
    if (date_str.len == 0) return null;

    if (std.mem.indexOfScalar(u8, date_str, ',')) |comma_idx| {
        if (comma_idx + 1 < date_str.len) {
            date_str = std.mem.trim(u8, date_str[comma_idx + 1 ..], " \t\r\n");
        }
    }

    if (std.mem.indexOfScalar(u8, date_str, 'T') != null and std.mem.indexOfScalar(u8, date_str, '-') != null) {
        var it = std.mem.tokenizeScalar(u8, date_str, 'T');
        const date_part = it.next() orelse return null;
        const time_tz_part = it.next() orelse return null;

        var date_it = std.mem.tokenizeScalar(u8, date_part, '-');
        const y_str = date_it.next() orelse return null;
        const m_str = date_it.next() orelse return null;
        const d_str = date_it.next() orelse return null;

        const year = std.fmt.parseInt(i64, y_str, 10) catch return null;
        const month = std.fmt.parseInt(i64, m_str, 10) catch return null;
        const day = std.fmt.parseInt(i64, d_str, 10) catch return null;

        var tz_offset: i64 = 0;
        var hh: i64 = 0;
        var mm: i64 = 0;
        var ss: i64 = 0;

        if (std.mem.indexOfAny(u8, time_tz_part, "+-Z")) |tz_pos| {
            const time_part = time_tz_part[0..tz_pos];
            const tz_part = time_tz_part[tz_pos..];

            var time_it = std.mem.tokenizeScalar(u8, time_part, ':');
            const h_str = time_it.next() orelse return null;
            const mi_str = time_it.next() orelse return null;
            const s_str = time_it.next() orelse "00";

            hh = std.fmt.parseInt(i64, h_str, 10) catch return null;
            mm = std.fmt.parseInt(i64, mi_str, 10) catch return null;
            ss = std.fmt.parseInt(i64, s_str, 10) catch return null;

            tz_offset = parseTimezoneOffset(tz_part);
        } else {
            var time_it = std.mem.tokenizeScalar(u8, time_tz_part, ':');
            const h_str = time_it.next() orelse return null;
            const mi_str = time_it.next() orelse return null;
            const s_str = time_it.next() orelse "00";

            hh = std.fmt.parseInt(i64, h_str, 10) catch return null;
            mm = std.fmt.parseInt(i64, mi_str, 10) catch return null;
            ss = std.fmt.parseInt(i64, s_str, 10) catch return null;
        }

        const epoch_utc = dateToEpoch(year, month, day, hh, mm, ss);
        return epoch_utc - tz_offset;
    } else {
        var it = std.mem.tokenizeScalar(u8, date_str, ' ');
        const d_str = it.next() orelse return null;
        const m_str = it.next() orelse return null;
        const y_str = it.next() orelse return null;
        const time_part = it.next() orelse return null;
        const tz_part = it.next() orelse "";

        const day = std.fmt.parseInt(i64, d_str, 10) catch return null;
        const month = parseMonthName(m_str) orelse return null;
        const year = std.fmt.parseInt(i64, y_str, 10) catch return null;

        var time_it = std.mem.tokenizeScalar(u8, time_part, ':');
        const h_str = time_it.next() orelse return null;
        const mi_str = time_it.next() orelse return null;
        const s_str = time_it.next() orelse "00";

        const hh = std.fmt.parseInt(i64, h_str, 10) catch return null;
        const mm = std.fmt.parseInt(i64, mi_str, 10) catch return null;
        const ss = std.fmt.parseInt(i64, s_str, 10) catch return null;

        const tz_offset = parseTimezoneOffset(tz_part);
        const epoch_utc = dateToEpoch(year, month, day, hh, mm, ss);
        return epoch_utc - tz_offset;
    }
}

fn extractIntField(xml: []const u8, i: usize, tag: []const u8, default: u32) ?struct { value: u32, end: usize } {
    if (std.mem.startsWith(u8, xml[i..], tag)) {
        const start = i + tag.len;
        const end = std.mem.indexOfScalarPos(u8, xml, start, '"') orelse xml.len;
        return .{ .value = std.fmt.parseInt(u32, xml[start..end], 10) catch default, .end = end };
    }
    return null;
}

fn extractOptionalU64Element(xml: []const u8, i: usize, tag: []const u8) ?struct { value: ?u64, end: usize } {
    if (std.mem.startsWith(u8, xml[i..], tag)) {
        const start = i + tag.len;
        const end = std.mem.indexOfScalarPos(u8, xml, start, '<') orelse xml.len;
        const trimmed = std.mem.trim(u8, xml[start..end], " \t\r\n");
        return .{ .value = std.fmt.parseInt(u64, trimmed, 10) catch null, .end = end };
    }
    return null;
}

fn extractTorznabSizeAttr(xml: []const u8, i: usize) ?struct { value: ?u64, end: usize } {
    const attr_tag = "<torznab:attr ";
    if (!std.mem.startsWith(u8, xml[i..], attr_tag)) return null;

    const tag_end = std.mem.indexOfScalarPos(u8, xml, i, '>') orelse return null;
    const tag = xml[i .. tag_end + 1];

    if (std.mem.indexOf(u8, tag, xml_tags.size_attr_name) == null) return null;

    const value_pos = std.mem.indexOf(u8, tag, xml_tags.attr_value) orelse return null;
    const value_start = i + value_pos + xml_tags.attr_value.len;
    const value_end = std.mem.indexOfScalarPos(u8, xml, value_start, '"') orelse return null;
    return .{
        .value = std.fmt.parseInt(u64, xml[value_start..value_end], 10) catch null,
        .end = tag_end + 1,
    };
}

fn extractMagnetUrlAttr(xml: []const u8, i: usize) ?struct { value: []const u8, end: usize } {
    const attr_tag = "<torznab:attr ";
    if (!std.mem.startsWith(u8, xml[i..], attr_tag)) return null;

    const tag_end = std.mem.indexOfScalarPos(u8, xml, i, '>') orelse return null;
    const tag = xml[i .. tag_end + 1];

    if (std.mem.indexOf(u8, tag, xml_tags.magneturl_attr_name) == null) return null;

    const value_pos = std.mem.indexOf(u8, tag, xml_tags.attr_value) orelse return null;
    const value_start = i + value_pos + xml_tags.attr_value.len;
    const value_end = std.mem.indexOfScalarPos(u8, xml, value_start, '"') orelse return null;
    return .{ .value = xml[value_start..value_end], .end = tag_end + 1 };
}

fn extractEnclosureInfo(xml: []const u8, i: usize) ?struct { url: ?[]const u8, length: ?u64, end: usize } {
    if (!std.mem.startsWith(u8, xml[i..], xml_tags.enclosure)) return null;

    const tag_end = std.mem.indexOfScalarPos(u8, xml, i, '>') orelse return null;
    const tag = xml[i .. tag_end + 1];
    const url = if (std.mem.indexOf(u8, tag, xml_tags.enclosure_url)) |url_pos| url: {
        const url_start = i + url_pos + xml_tags.enclosure_url.len;
        const url_end = std.mem.indexOfScalarPos(u8, xml, url_start, '"') orelse break :url null;
        break :url xml[url_start..url_end];
    } else null;
    const length = if (std.mem.indexOf(u8, tag, xml_tags.enclosure_length)) |length_pos| length: {
        const length_start = i + length_pos + xml_tags.enclosure_length.len;
        const length_end = std.mem.indexOfScalarPos(u8, xml, length_start, '"') orelse break :length null;
        break :length std.fmt.parseInt(u64, xml[length_start..length_end], 10) catch null;
    } else null;
    return .{
        .url = url,
        .length = length,
        .end = tag_end + 1,
    };
}

fn normalizeLink(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < trimmed.len) {
        if (std.mem.startsWith(u8, trimmed[i..], "&amp;")) {
            try out.append(allocator, '&');
            i += 5;
        } else if (std.mem.startsWith(u8, trimmed[i..], "&lt;")) {
            try out.append(allocator, '<');
            i += 4;
        } else if (std.mem.startsWith(u8, trimmed[i..], "&gt;")) {
            try out.append(allocator, '>');
            i += 4;
        } else if (std.mem.startsWith(u8, trimmed[i..], "&quot;")) {
            try out.append(allocator, '"');
            i += 6;
        } else if (std.mem.startsWith(u8, trimmed[i..], "&apos;")) {
            try out.append(allocator, '\'');
            i += 6;
        } else if (trimmed[i] == '&' and i + 3 < trimmed.len and trimmed[i + 1] == '#') {
            if (decodeNumericEntity(trimmed[i..])) |decoded| {
                var utf8_buf: [4]u8 = undefined;
                const utf8_len = std.unicode.utf8Encode(decoded.codepoint, utf8_buf[0..]) catch {
                    try out.append(allocator, trimmed[i]);
                    i += 1;
                    continue;
                };
                try out.appendSlice(allocator, utf8_buf[0..utf8_len]);
                i += decoded.consumed;
            } else {
                try out.append(allocator, trimmed[i]);
                i += 1;
            }
        } else {
            try out.append(allocator, trimmed[i]);
            i += 1;
        }
    }

    return out.toOwnedSlice(allocator);
}

fn decodeNumericEntity(input: []const u8) ?struct { codepoint: u21, consumed: usize } {
    if (input.len < 4) return null;
    if (input[0] != '&' or input[1] != '#') return null;

    const semicolon_idx = std.mem.indexOfScalar(u8, input, ';') orelse return null;
    if (semicolon_idx < 3) return null;

    const number_slice = input[2..semicolon_idx];
    if (number_slice.len == 0) return null;

    const parsed: u21 = if ((number_slice[0] == 'x' or number_slice[0] == 'X') and number_slice.len > 1)
        std.fmt.parseInt(u21, number_slice[1..], 16) catch return null
    else
        std.fmt.parseInt(u21, number_slice, 10) catch return null;

    return .{
        .codepoint = parsed,
        .consumed = semicolon_idx + 1,
    };
}

fn mapAnyToJackettError(err: anyerror, fallback: JackettError) JackettError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ConnectionRefused => error.ConnectionRefused,
        else => fallback,
    };
}

fn mapAnyToLinkResolveError(err: anyerror, fallback: LinkResolveError) LinkResolveError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => fallback,
    };
}

pub const ProgressPhase = enum(u8) {
    discovering = 0,
    querying = 1,
    done = 2,
};

pub const SearchProgressSnapshot = struct {
    phase: ProgressPhase,
    completed: usize,
    total: usize,
    failed: usize,
};

pub const SearchProgress = struct {
    phase: std.atomic.Value(u8),
    completed: std.atomic.Value(usize),
    total: std.atomic.Value(usize),
    failed: std.atomic.Value(usize),

    pub fn init() SearchProgress {
        return .{
            .phase = std.atomic.Value(u8).init(@intFromEnum(ProgressPhase.discovering)),
            .completed = std.atomic.Value(usize).init(0),
            .total = std.atomic.Value(usize).init(0),
            .failed = std.atomic.Value(usize).init(0),
        };
    }

    pub fn setPhase(self: *SearchProgress, phase: ProgressPhase) void {
        self.phase.store(@intFromEnum(phase), .release);
    }

    pub fn setTotal(self: *SearchProgress, total: usize) void {
        self.total.store(total, .release);
    }

    pub fn recordCompleted(self: *SearchProgress) void {
        _ = self.completed.fetchAdd(1, .release);
    }

    pub fn recordFailed(self: *SearchProgress) void {
        _ = self.failed.fetchAdd(1, .release);
    }

    pub fn snapshot(self: *SearchProgress) SearchProgressSnapshot {
        const phase_value = self.phase.load(.acquire);
        const phase: ProgressPhase = switch (phase_value) {
            @intFromEnum(ProgressPhase.querying) => .querying,
            @intFromEnum(ProgressPhase.done) => .done,
            else => .discovering,
        };
        return .{
            .phase = phase,
            .completed = self.completed.load(.acquire),
            .total = self.total.load(.acquire),
            .failed = self.failed.load(.acquire),
        };
    }
};

pub const BodyExecutor = *const fn (allocator: std.mem.Allocator, url: []const u8) JackettError![]u8;

pub const LinkResolveError = error{
    InvalidLink,
    InvalidUrl,
    RequestCreateFailed,
    RequestSendFailed,
    ResponseHeadReadFailed,
    HttpError,
    ResponseReadFailed,
    UnresolvableLink,
    TempFileCreateFailed,
    TempFileWriteFailed,
    OutOfMemory,
};

pub const ResolvedLinkKind = enum {
    direct,
    magnet_redirect,
    torrent_file,
};

pub const ResolvedLink = struct {
    value: []u8,
    kind: ResolvedLinkKind,

    pub fn deinit(self: *ResolvedLink, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
        self.* = undefined;
    }
};

pub const LinkFetchResponse = struct {
    status: std.http.Status,
    location: ?[]u8 = null,
    body: []u8 = &.{},

    pub fn deinit(self: *LinkFetchResponse, allocator: std.mem.Allocator) void {
        if (self.location) |location| allocator.free(location);
        if (self.body.len != 0) allocator.free(self.body);
        self.* = undefined;
    }
};

pub const LinkFetchExecutor = *const fn (allocator: std.mem.Allocator, url: []const u8) LinkResolveError!LinkFetchResponse;

fn isHttpLink(link: []const u8) bool {
    return std.mem.startsWith(u8, link, "http://") or std.mem.startsWith(u8, link, "https://");
}

fn isRedirectStatus(status: std.http.Status) bool {
    const code = @intFromEnum(status);
    return code >= 300 and code < 400;
}

pub fn resolveDownloadLink(
    allocator: std.mem.Allocator,
    link: []const u8,
    fetcher: LinkFetchExecutor,
) LinkResolveError!ResolvedLink {
    if (std.mem.startsWith(u8, link, "magnet:") or (!isHttpLink(link) and std.mem.endsWith(u8, link, ".torrent"))) {
        debug_log.writef(
            allocator,
            "jackett",
            "Selected link used directly kind=direct",
            .{},
        );
        return .{
            .value = try allocator.dupe(u8, link),
            .kind = .direct,
        };
    }

    if (!isHttpLink(link)) {
        debug_log.writef(
            allocator,
            "jackett",
            "Selected link rejected before resolve",
            .{},
        );
        return error.InvalidLink;
    }

    var response = try fetcher(allocator, link);
    defer response.deinit(allocator);

    if (isRedirectStatus(response.status)) {
        const location = response.location orelse {
            debug_log.writef(
                allocator,
                "jackett",
                "HTTP link redirect had no location status={d}",
                .{@intFromEnum(response.status)},
            );
            return error.UnresolvableLink;
        };
        if (!std.mem.startsWith(u8, location, "magnet:")) {
            debug_log.writef(
                allocator,
                "jackett",
                "HTTP link redirected to non-magnet status={d}",
                .{@intFromEnum(response.status)},
            );
            return error.UnresolvableLink;
        }
        debug_log.writef(
            allocator,
            "jackett",
            "HTTP link resolved to magnet redirect status={d}",
            .{@intFromEnum(response.status)},
        );
        return .{
            .value = try allocator.dupe(u8, location),
            .kind = .magnet_redirect,
        };
    }

    if (response.status != .ok) {
        debug_log.writef(
            allocator,
            "jackett",
            "HTTP link returned non-OK status={d}",
            .{@intFromEnum(response.status)},
        );
        return error.HttpError;
    }

    if (response.body.len == 0) {
        debug_log.writef(
            allocator,
            "jackett",
            "HTTP link returned empty torrent body",
            .{},
        );
        return error.UnresolvableLink;
    }

    const path = try writeTempTorrentFile(allocator, response.body);
    debug_log.writef(
        allocator,
        "jackett",
        "HTTP link downloaded to temp torrent",
        .{},
    );
    return .{
        .value = path,
        .kind = .torrent_file,
    };
}

fn writeTempTorrentFile(allocator: std.mem.Allocator, bytes: []const u8) LinkResolveError![]u8 {
    const temp_dir = try getTempDir(allocator);
    defer allocator.free(temp_dir);

    var random_bytes: [12]u8 = undefined;
    var hex_buf: [24]u8 = undefined;

    var attempts: usize = 0;
    while (attempts < 8) : (attempts += 1) {
        compat.io().random(&random_bytes);
        const hex = std.fmt.bytesToHex(random_bytes, .lower);
        @memcpy(hex_buf[0..], hex[0..]);

        const filename = try std.fmt.allocPrint(allocator, "supersearchr-{s}.torrent", .{hex_buf[0..]});
        defer allocator.free(filename);
        const path = try std.fs.path.join(allocator, &.{ temp_dir, filename });
        errdefer allocator.free(path);

        const io = compat.io();
        const file = std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => return error.TempFileCreateFailed,
        };
        defer compat.closeFile(file);

        compat.writeFileAll(file, bytes) catch |err| switch (err) {
            else => return error.TempFileWriteFailed,
        };

        return path;
    }

    return error.TempFileCreateFailed;
}

fn getTempDir(allocator: std.mem.Allocator) ![]u8 {
    if (compat.getEnvVarOwned(allocator, "TMPDIR")) |value| {
        if (value.len > 0) return value;
        allocator.free(value);
    } else |_| {}

    return allocator.dupe(u8, "/tmp");
}

pub fn defaultLinkFetchExecutor(allocator: std.mem.Allocator, url: []const u8) LinkResolveError!LinkFetchResponse {
    var http_client = std.http.Client{ .allocator = allocator, .io = compat.io() };
    defer http_client.deinit();

    const uri = std.Uri.parse(url) catch |err| {
        debug_log.writef(
            allocator,
            "jackett",
            "Failed to parse Jackett download URL err={s}",
            .{@errorName(err)},
        );
        return error.InvalidUrl;
    };
    var request = http_client.request(.GET, uri, .{ .redirect_behavior = .unhandled }) catch |err| {
        debug_log.writef(
            allocator,
            "jackett",
            "Failed to create Jackett download request err={s}",
            .{@errorName(err)},
        );
        return mapAnyToLinkResolveError(err, error.RequestCreateFailed);
    };
    defer request.deinit();

    request.sendBodiless() catch |err| {
        debug_log.writef(
            allocator,
            "jackett",
            "Failed to send Jackett download request err={s}",
            .{@errorName(err)},
        );
        return mapAnyToLinkResolveError(err, error.RequestSendFailed);
    };
    var header_buf: [64 * 1024]u8 = undefined;
    var response = request.receiveHead(&header_buf) catch |err| {
        debug_log.writef(
            allocator,
            "jackett",
            "Failed to receive Jackett download response head err={s}",
            .{@errorName(err)},
        );
        return mapAnyToLinkResolveError(err, error.ResponseHeadReadFailed);
    };

    const location = if (response.head.location) |raw_location|
        allocator.dupe(u8, raw_location) catch return error.OutOfMemory
    else
        null;
    errdefer if (location) |owned_location| allocator.free(owned_location);

    if (response.head.status != .ok) {
        return .{
            .status = response.head.status,
            .location = location,
        };
    }

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => allocator.alloc(u8, std.compress.zstd.default_window_len) catch return error.OutOfMemory,
        .deflate, .gzip => allocator.alloc(u8, std.compress.flate.max_window_len) catch return error.OutOfMemory,
        .compress => return error.ResponseReadFailed,
    };
    defer if (decompress_buffer.len != 0) allocator.free(decompress_buffer);

    var read_buf: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&read_buf, &decompress, decompress_buffer);
    const body = reader.allocRemaining(allocator, .unlimited) catch |err| {
        if (location) |owned_location| allocator.free(owned_location);
        return mapAnyToLinkResolveError(err, error.ResponseReadFailed);
    };

    return .{
        .status = response.head.status,
        .location = location,
        .body = body,
    };
}

pub fn defaultBodyExecutor(allocator: std.mem.Allocator, url: []const u8) JackettError![]u8 {
    var http_client = std.http.Client{ .allocator = allocator, .io = compat.io() };
    defer http_client.deinit();

    const uri = std.Uri.parse(url) catch |err| {
        debug_log.writef(
            allocator,
            "jackett",
            "Failed to parse Jackett URL err={s} url=\"{s}\"",
            .{ @errorName(err), url },
        );
        return error.InvalidUrl;
    };
    var request = http_client.request(.GET, uri, .{}) catch |err| {
        debug_log.writef(
            allocator,
            "jackett",
            "Failed to create Jackett request err={s} url=\"{s}\"",
            .{ @errorName(err), url },
        );
        return mapAnyToJackettError(err, error.RequestCreateFailed);
    };
    defer request.deinit();

    request.sendBodiless() catch |err| {
        debug_log.writef(
            allocator,
            "jackett",
            "Failed to send Jackett request err={s} url=\"{s}\"",
            .{ @errorName(err), url },
        );
        return mapAnyToJackettError(err, error.RequestSendFailed);
    };
    var header_buf: [1024]u8 = undefined;
    var response = request.receiveHead(&header_buf) catch |err| {
        debug_log.writef(
            allocator,
            "jackett",
            "Failed to receive Jackett response head err={s} url=\"{s}\"",
            .{ @errorName(err), url },
        );
        return mapAnyToJackettError(err, error.ResponseHeadReadFailed);
    };

    const status = response.head.status;
    if (status != .ok) {
        debug_log.writef(
            allocator,
            "jackett",
            "Jackett returned non-OK status status={s} url=\"{s}\"",
            .{ @tagName(status), url },
        );
        return error.HttpError;
    }

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => allocator.alloc(u8, std.compress.zstd.default_window_len) catch |err| {
            debug_log.writef(
                allocator,
                "jackett",
                "Failed to allocate Jackett decompression buffer err={s} url=\"{s}\"",
                .{ @errorName(err), url },
            );
            return error.OutOfMemory;
        },
        .deflate, .gzip => allocator.alloc(u8, std.compress.flate.max_window_len) catch |err| {
            debug_log.writef(
                allocator,
                "jackett",
                "Failed to allocate Jackett decompression buffer err={s} url=\"{s}\"",
                .{ @errorName(err), url },
            );
            return error.OutOfMemory;
        },
        .compress => {
            debug_log.writef(
                allocator,
                "jackett",
                "Jackett returned unsupported content encoding url=\"{s}\"",
                .{url},
            );
            return error.ResponseReadFailed;
        },
    };
    defer if (decompress_buffer.len != 0) allocator.free(decompress_buffer);

    var read_buf: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&read_buf, &decompress, decompress_buffer);
    const body = reader.allocRemaining(allocator, .unlimited) catch |err| {
        debug_log.writef(
            allocator,
            "jackett",
            "Failed to read Jackett response body err={s} url=\"{s}\"",
            .{ @errorName(err), url },
        );
        return mapAnyToJackettError(err, error.ResponseReadFailed);
    };

    return body;
}

pub const Indexer = struct {
    id: []u8,
};

pub const SearchBatch = struct {
    torrents: []Torrent,

    pub fn deinit(self: *SearchBatch, allocator: std.mem.Allocator) void {
        for (self.torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(self.torrents);
        self.* = undefined;
    }
};

const StreamingSearchContext = struct {
    allocator: std.mem.Allocator,
    executor: BodyExecutor,
    base_url: []const u8,
    api_key: []const u8,
    encoded_query: []const u8,
    indexers: []const Indexer,
    next_index: std.atomic.Value(usize),
    progress: *SearchProgress,
    queue: *SearchBatchQueue,
    skip_cache: bool,
};

const SearchBatchQueue = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    batches: std.ArrayList(SearchBatch) = .empty,
    failed_indexers: std.ArrayList([]const u8) = .empty,
    first_error: ?JackettError = null,
    failures: usize = 0,

    fn push(self: *SearchBatchQueue, batch: SearchBatch) JackettError!void {
        const io = compat.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.batches.append(self.allocator, batch) catch return error.OutOfMemory;
    }

    fn pop(self: *SearchBatchQueue) ?SearchBatch {
        const io = compat.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.batches.items.len == 0) return null;
        return self.batches.orderedRemove(0);
    }

    fn recordFailure(self: *SearchBatchQueue, err: JackettError, indexer_id: []const u8) void {
        const io = compat.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.first_error == null) self.first_error = err;
        self.failures += 1;

        const id_copy = self.allocator.dupe(u8, indexer_id) catch return;
        self.failed_indexers.append(self.allocator, id_copy) catch {
            self.allocator.free(id_copy);
        };
    }

    fn setFatal(self: *SearchBatchQueue, err: JackettError) void {
        const io = compat.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.first_error = err;
    }

    fn fatalError(self: *SearchBatchQueue) ?JackettError {
        const io = compat.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.first_error;
    }

    fn deinit(self: *SearchBatchQueue) void {
        for (self.batches.items) |*batch| {
            batch.deinit(self.allocator);
        }
        self.batches.deinit(self.allocator);
        for (self.failed_indexers.items) |name| {
            self.allocator.free(name);
        }
        self.failed_indexers.deinit(self.allocator);
    }
};

pub const SearchSession = struct {
    allocator_value: std.mem.Allocator,
    executor: BodyExecutor,
    base_url: []u8,
    api_key: []u8,
    query: []u8,
    max_parallel: usize,
    progress: SearchProgress,
    queue: SearchBatchQueue,
    coordinator_thread: ?std.Thread = null,
    done: std.atomic.Value(bool),
    fatal_discovery_error: std.atomic.Value(bool),
    skip_cache: bool,

    fn allocator(self: *SearchSession) std.mem.Allocator {
        return self.allocator_value;
    }

    pub fn snapshot(self: *SearchSession) SearchProgressSnapshot {
        return self.progress.snapshot();
    }

    pub fn fatalError(self: *SearchSession) ?JackettError {
        if (!self.fatal_discovery_error.load(.acquire)) return null;
        return self.queue.fatalError();
    }

    pub fn isDone(self: *SearchSession) bool {
        return self.done.load(.acquire);
    }

    pub fn drainInto(self: *SearchSession, dst_allocator: std.mem.Allocator, dst: *std.ArrayList(Torrent)) JackettError!bool {
        var changed = false;
        while (self.queue.pop()) |batch_value| {
            var batch = batch_value;
            defer batch.deinit(self.allocator());
            for (batch.torrents) |torrent| {
                const cloned = try cloneTorrent(dst_allocator, torrent);
                errdefer {
                    dst_allocator.free(cloned.title);
                    dst_allocator.free(cloned.link);
                }
                try dst.append(dst_allocator, cloned);
            }
            changed = true;
        }
        if (changed) sortTorrents(dst.items);
        return changed;
    }

    pub fn abandon(self: *SearchSession) void {
        if (self.coordinator_thread) |thread| {
            thread.detach();
            self.coordinator_thread = null;
        }
    }

    pub fn deinit(self: *SearchSession) void {
        if (self.coordinator_thread) |thread| {
            thread.join();
            self.coordinator_thread = null;
        }
        self.destroy();
    }

    fn destroy(self: *SearchSession) void {
        const allocator_value = self.allocator();
        self.queue.deinit();
        allocator_value.free(self.base_url);
        allocator_value.free(self.api_key);
        allocator_value.free(self.query);
        std.heap.page_allocator.destroy(self);
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    api_key: []const u8,

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8, api_key: []const u8) Client {
        return .{
            .allocator = allocator,
            .base_url = base_url,
            .api_key = api_key,
        };
    }

    pub fn deinit(self: *Client) void {
        _ = self;
    }

    pub fn startStreamingSearch(
        self: *Client,
        query: []const u8,
        executor: BodyExecutor,
        max_parallel: usize,
        skip_cache: bool,
    ) JackettError!*SearchSession {
        const session = std.heap.page_allocator.create(SearchSession) catch return error.OutOfMemory;
        session.* = .{
            .allocator_value = std.heap.page_allocator,
            .executor = executor,
            .base_url = &.{},
            .api_key = &.{},
            .query = &.{},
            .max_parallel = max_parallel,
            .progress = SearchProgress.init(),
            .queue = undefined,
            .done = std.atomic.Value(bool).init(false),
            .fatal_discovery_error = std.atomic.Value(bool).init(false),
            .skip_cache = skip_cache,
        };
        const allocator = session.allocator();
        session.queue = .{ .allocator = allocator };
        errdefer std.heap.page_allocator.destroy(session);
        session.base_url = allocator.dupe(u8, self.base_url) catch return error.OutOfMemory;
        errdefer allocator.free(session.base_url);
        session.api_key = allocator.dupe(u8, self.api_key) catch return error.OutOfMemory;
        errdefer allocator.free(session.api_key);
        session.query = allocator.dupe(u8, query) catch return error.OutOfMemory;
        errdefer {
            allocator.free(session.query);
            session.queue.deinit();
        }

        session.coordinator_thread = std.Thread.spawn(.{}, streamingCoordinator, .{session}) catch return error.RequestSendFailed;
        return session;
    }

    fn fetchConfiguredIndexers(self: *Client, executor: BodyExecutor) JackettError![]Indexer {
        return fetchConfiguredIndexersOwned(self.allocator, self.base_url, self.api_key, executor);
    }
};

fn percentEncode(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (raw) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => {
                try result.append(allocator, c);
            },
            else => {
                var buf: [3]u8 = undefined;
                const encoded = std.fmt.bufPrint(&buf, "%{X:0>2}", .{c}) catch unreachable;
                try result.appendSlice(allocator, encoded);
            },
        }
    }
    return result.toOwnedSlice(allocator);
}

fn streamingCoordinator(session: *SearchSession) void {
    const allocator = session.allocator();
    session.progress.setPhase(.discovering);

    const indexers = fetchConfiguredIndexersOwned(
        allocator,
        session.base_url,
        session.api_key,
        session.executor,
    ) catch |err| {
        session.queue.setFatal(err);
        session.fatal_discovery_error.store(true, .release);
        session.progress.setPhase(.done);
        session.done.store(true, .release);
        return;
    };
    defer freeIndexers(allocator, indexers);

    session.progress.setTotal(indexers.len);
    session.progress.setPhase(.querying);

    if (indexers.len == 0) {
        session.progress.setPhase(.done);
        session.done.store(true, .release);
        return;
    }

    const encoded_query = percentEncode(allocator, session.query) catch {
        session.queue.setFatal(error.OutOfMemory);
        session.fatal_discovery_error.store(true, .release);
        session.progress.setPhase(.done);
        session.done.store(true, .release);
        return;
    };
    defer allocator.free(encoded_query);

    var ctx = StreamingSearchContext{
        .allocator = allocator,
        .executor = session.executor,
        .base_url = session.base_url,
        .api_key = session.api_key,
        .encoded_query = encoded_query,
        .indexers = indexers,
        .next_index = std.atomic.Value(usize).init(0),
        .progress = &session.progress,
        .queue = &session.queue,
        .skip_cache = session.skip_cache,
    };

    const worker_count = @min(@max(session.max_parallel, @as(usize, 1)), indexers.len);
    const threads = allocator.alloc(std.Thread, worker_count) catch {
        session.queue.setFatal(error.OutOfMemory);
        session.fatal_discovery_error.store(true, .release);
        session.progress.setPhase(.done);
        session.done.store(true, .release);
        return;
    };
    defer allocator.free(threads);

    var spawned: usize = 0;
    while (spawned < worker_count) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, streamingSearchWorker, .{&ctx}) catch {
            session.queue.setFatal(error.RequestSendFailed);
            session.fatal_discovery_error.store(true, .release);
            break;
        };
    }

    for (threads[0..spawned]) |thread| {
        thread.join();
    }

    session.progress.setPhase(.done);
    session.done.store(true, .release);
}

fn streamingSearchWorker(ctx: *StreamingSearchContext) void {
    while (true) {
        const idx = ctx.next_index.fetchAdd(1, .monotonic);
        if (idx >= ctx.indexers.len) return;

        const id = ctx.indexers[idx].id;
        searchSingleIndexerStreaming(ctx, id) catch |err| {
            ctx.queue.recordFailure(err, id);
            ctx.progress.recordFailed();
        };
        ctx.progress.recordCompleted();
    }
}

fn searchSingleIndexerStreaming(ctx: *StreamingSearchContext, indexer_id: []const u8) JackettError!void {
    const encoded_indexer = try percentEncode(ctx.allocator, indexer_id);
    defer ctx.allocator.free(encoded_indexer);

    const url = if (ctx.skip_cache)
        try std.fmt.allocPrint(
            ctx.allocator,
            "{s}/api/v2.0/indexers/{s}/results/torznab/api?apikey={s}&t=search&q={s}&cache=false",
            .{ ctx.base_url, encoded_indexer, ctx.api_key, ctx.encoded_query },
        )
    else
        try std.fmt.allocPrint(
            ctx.allocator,
            "{s}/api/v2.0/indexers/{s}/results/torznab/api?apikey={s}&t=search&q={s}",
            .{ ctx.base_url, encoded_indexer, ctx.api_key, ctx.encoded_query },
        );
    defer ctx.allocator.free(url);

    const body = try ctx.executor(ctx.allocator, url);
    defer ctx.allocator.free(body);

    const torrents = parseTorrents(ctx.allocator, body) catch |err| return mapAnyToJackettError(err, error.ParseFailed);
    errdefer {
        for (torrents) |t| {
            ctx.allocator.free(t.title);
            ctx.allocator.free(t.link);
        }
        ctx.allocator.free(torrents);
    }

    try ctx.queue.push(.{ .torrents = torrents });
}

fn fetchConfiguredIndexersOwned(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    api_key: []const u8,
    executor: BodyExecutor,
) JackettError![]Indexer {
    const url = try std.fmt.allocPrint(
        allocator,
        "{s}/api/v2.0/indexers/all/results/torznab/api?apikey={s}&t=indexers&configured=true",
        .{ base_url, api_key },
    );
    defer allocator.free(url);

    const body = try executor(allocator, url);
    defer allocator.free(body);

    return parseIndexers(allocator, body) catch |err| mapAnyToJackettError(err, error.ParseFailed);
}

fn parseIndexers(allocator: std.mem.Allocator, xml: []const u8) ![]Indexer {
    if (std.mem.indexOf(u8, xml, "<indexers") == null) return error.ParseFailed;

    var indexers: std.ArrayList(Indexer) = .empty;
    errdefer {
        for (indexers.items) |indexer| {
            allocator.free(indexer.id);
        }
        indexers.deinit(allocator);
    }

    var i: usize = 0;
    while (i < xml.len) {
        if (!std.mem.startsWith(u8, xml[i..], xml_tags.indexer)) {
            i += 1;
            continue;
        }

        const tag_end = std.mem.indexOfScalarPos(u8, xml, i, '>') orelse break;
        const tag = xml[i .. tag_end + 1];
        const id_pos = std.mem.indexOf(u8, tag, xml_tags.indexer_id) orelse {
            i = tag_end + 1;
            continue;
        };
        const id_start = i + id_pos + xml_tags.indexer_id.len;
        const id_end = std.mem.indexOfScalarPos(u8, xml, id_start, '"') orelse {
            i = tag_end + 1;
            continue;
        };

        try indexers.append(allocator, .{
            .id = try allocator.dupe(u8, xml[id_start..id_end]),
        });

        if (std.mem.indexOfPos(u8, xml, tag_end + 1, xml_tags.indexer_end)) |end_pos| {
            i = end_pos + xml_tags.indexer_end.len;
        } else {
            i = tag_end + 1;
        }
    }

    return indexers.toOwnedSlice(allocator);
}

fn freeIndexers(allocator: std.mem.Allocator, indexers: []Indexer) void {
    for (indexers) |indexer| {
        allocator.free(indexer.id);
    }
    allocator.free(indexers);
}

fn sortTorrents(torrents: []Torrent) void {
    std.mem.sort(Torrent, torrents, {}, struct {
        fn lessThan(_: void, a: Torrent, b: Torrent) bool {
            return a.seeders > b.seeders;
        }
    }.lessThan);
}

fn cloneTorrent(allocator: std.mem.Allocator, torrent: Torrent) !Torrent {
    const title = try allocator.dupe(u8, torrent.title);
    errdefer allocator.free(title);
    const link = try allocator.dupe(u8, torrent.link);
    return .{
        .title = title,
        .seeders = torrent.seeders,
        .leechers = torrent.leechers,
        .size_bytes = torrent.size_bytes,
        .pub_date = torrent.pub_date,
        .link = link,
    };
}

fn parseTorrents(allocator: std.mem.Allocator, xml: []const u8) ![]Torrent {
    var torrents: std.ArrayList(Torrent) = .empty;
    errdefer {
        for (torrents.items) |*t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        torrents.deinit(allocator);
    }

    var i: usize = 0;
    while (i < xml.len) {
        if (std.mem.startsWith(u8, xml[i..], xml_tags.item)) {
            i += xml_tags.item.len;
            var title: ?[]const u8 = null;
            var link: ?[]const u8 = null;
            var link_priority: u8 = 0;
            var link_source: []const u8 = "none";
            var seeders: u32 = 0;
            var peers: u32 = 0;
            var size_bytes: ?u64 = null;
            var explicit_size_seen = false;
            var enclosure_size_bytes: ?u64 = null;
            var pub_date: ?i64 = null;

            while (i < xml.len) {
                if (extractStringField(xml, i, xml_tags.item_end)) |_| {
                    break;
                }
                if (extractStringField(xml, i, xml_tags.title)) |result| {
                    title = result.value;
                    i = result.end;
                } else if (extractOptionalU64Element(xml, i, xml_tags.size)) |result| {
                    explicit_size_seen = true;
                    size_bytes = result.value;
                    i = result.end;
                } else if (extractMagnetUrlAttr(xml, i)) |result| {
                    if (link_priority < 2) {
                        link = result.value;
                        link_priority = 2;
                        link_source = "torznab:attr magneturl";
                    }
                    i = result.end;
                } else if (extractTorznabSizeAttr(xml, i)) |result| {
                    explicit_size_seen = true;
                    size_bytes = result.value;
                    i = result.end;
                } else if (extractStringField(xml, i, xml_tags.link)) |result| {
                    if (link_priority < 1) {
                        link = result.value;
                        link_priority = 1;
                        link_source = "link";
                    }
                    i = result.end;
                } else if (extractEnclosureInfo(xml, i)) |result| {
                    if (result.url) |url| {
                        if (link_priority < 3) {
                            link = url;
                            link_priority = 3;
                            link_source = "enclosure url";
                        }
                    }
                    enclosure_size_bytes = result.length;
                    i = result.end;
                } else if (extractIntField(xml, i, xml_tags.seeders_attr, 0)) |result| {
                    seeders = result.value;
                    i = result.end;
                } else if (extractIntField(xml, i, xml_tags.peers_attr, 0)) |result| {
                    peers = result.value;
                    i = result.end;
                } else if (extractStringField(xml, i, xml_tags.pub_date)) |result| {
                    pub_date = parseRssDate(result.value);
                    i = result.end;
                } else {
                    i += 1;
                }
            }

            if (title != null and link != null) {
                const title_copy = try allocator.dupe(u8, title.?);
                const link_copy = try normalizeLink(allocator, link.?);
                if (link_copy.len == 0) {
                    allocator.free(title_copy);
                    allocator.free(link_copy);
                    debug_log.writef(
                        allocator,
                        "jackett",
                        "Skipping torrent with empty normalized link title=\"{s}\" source={s}",
                        .{ title.?, link_source },
                    );
                    continue;
                }
                try torrents.append(allocator, .{
                    .title = title_copy,
                    .seeders = seeders,
                    .leechers = peers,
                    .size_bytes = if (explicit_size_seen) size_bytes else enclosure_size_bytes,
                    .pub_date = pub_date,
                    .link = link_copy,
                });
                debug_log.writef(
                    allocator,
                    "jackett",
                    "Parsed torrent title=\"{s}\" source={s} link=\"{s}\"",
                    .{ title.?, link_source, link_copy },
                );
            } else if (title != null) {
                debug_log.writef(
                    allocator,
                    "jackett",
                    "Skipping torrent without link title=\"{s}\"",
                    .{title.?},
                );
            }
        } else {
            i += 1;
        }
    }

    sortTorrents(torrents.items);

    return torrents.toOwnedSlice(allocator);
}

test "parse XML with valid response" {
    const allocator = std.testing.allocator;

    const xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><rss version=\"1.0\"><channel><item><title>Movie.2024.1080p.WEB.h264</title><link>magnet:?xt=urn:btih:abc123</link><torznab:attr name=\"seeders\" value=\"100\"/><torznab:attr name=\"peers\" value=\"50\"/></item><item><title>Movie.2024.720p.WEB.h264</title><link>magnet:?xt=urn:btih:def456</link><torznab:attr name=\"seeders\" value=\"200\"/><torznab:attr name=\"peers\" value=\"75\"/></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(usize, 2), torrents.len);
    try std.testing.expectEqualStrings("Movie.2024.720p.WEB.h264", torrents[0].title);
    try std.testing.expectEqual(@as(u32, 200), torrents[0].seeders);
    try std.testing.expectEqual(@as(u32, 75), torrents[0].leechers);
    try std.testing.expectEqualStrings("Movie.2024.1080p.WEB.h264", torrents[1].title);
    try std.testing.expectEqual(@as(u32, 100), torrents[1].seeders);
}

test "parse RSS date RFC 822 and ISO 8601" {
    // RFC 822 / 1123 formats
    const t1 = parseRssDate("Sun, 24 May 2026 21:00:00 -0300");
    const t1_expected = dateToEpoch(2026, 5, 24, 21, 0, 0) - (-3 * 3600);
    try std.testing.expectEqual(t1_expected, t1.?);

    const t2 = parseRssDate("24 May 2026 21:00:00 GMT");
    const t2_expected = dateToEpoch(2026, 5, 24, 21, 0, 0);
    try std.testing.expectEqual(t2_expected, t2.?);

    const t3 = parseRssDate("Sun, 24 May 2026 21:00:00 EST");
    const t3_expected = dateToEpoch(2026, 5, 24, 21, 0, 0) - (-5 * 3600);
    try std.testing.expectEqual(t3_expected, t3.?);

    // ISO 8601 formats
    const t4 = parseRssDate("2026-05-24T21:00:00Z");
    const t4_expected = dateToEpoch(2026, 5, 24, 21, 0, 0);
    try std.testing.expectEqual(t4_expected, t4.?);

    const t5 = parseRssDate("2026-05-24T21:00:00-03:00");
    const t5_expected = dateToEpoch(2026, 5, 24, 21, 0, 0) - (-3 * 3600);
    try std.testing.expectEqual(t5_expected, t5.?);
}

test "parse XML with pubDate" {
    const allocator = std.testing.allocator;

    const xml = "<rss><channel><item><title>With PubDate</title><link>magnet:?xt=urn:btih:pubdate</link><pubDate>Sun, 24 May 2026 21:00:00 -0300</pubDate></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(usize, 1), torrents.len);
    const expected_time = dateToEpoch(2026, 5, 24, 21, 0, 0) - (-3 * 3600);
    try std.testing.expectEqual(@as(?i64, expected_time), torrents[0].pub_date);
}

test "parse torrent size from size element" {
    const allocator = std.testing.allocator;

    const xml = "<rss><channel><item><title>Has Size</title><size>536870912</size><link>magnet:?xt=urn:btih:size</link><torznab:attr name=\"seeders\" value=\"1\"/></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(usize, 1), torrents.len);
    try std.testing.expectEqual(@as(?u64, 536870912), torrents[0].size_bytes);
}

test "parse torrent size from torznab size attr" {
    const allocator = std.testing.allocator;

    const xml = "<rss><channel><item><title>Has Attr Size</title><link>magnet:?xt=urn:btih:sizeattr</link><torznab:attr name=\"size\" value=\"1073741824\"/></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(usize, 1), torrents.len);
    try std.testing.expectEqual(@as(?u64, 1073741824), torrents[0].size_bytes);
}

test "parse torrent size from enclosure length fallback" {
    const allocator = std.testing.allocator;

    const xml = "<rss><channel><item><title>Has Enclosure Length</title><enclosure length=\"2147483648\" url=\"https://example.com/size.torrent\" type=\"application/x-bittorrent\"/></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(usize, 1), torrents.len);
    try std.testing.expectEqualStrings("https://example.com/size.torrent", torrents[0].link);
    try std.testing.expectEqual(@as(?u64, 2147483648), torrents[0].size_bytes);
}

test "parse missing and invalid torrent sizes as null" {
    const allocator = std.testing.allocator;

    const xml = "<rss><channel><item><title>Missing Size</title><link>magnet:?xt=urn:btih:missing</link><torznab:attr name=\"seeders\" value=\"2\"/></item><item><title>Invalid Size</title><size>not-bytes</size><link>magnet:?xt=urn:btih:invalid</link><enclosure length=\"1073741824\" url=\"magnet:?xt=urn:btih:ignored\"/></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(usize, 2), torrents.len);
    try std.testing.expectEqualStrings("Missing Size", torrents[0].title);
    try std.testing.expectEqual(@as(?u64, null), torrents[0].size_bytes);
    try std.testing.expectEqualStrings("Invalid Size", torrents[1].title);
    try std.testing.expectEqual(@as(?u64, null), torrents[1].size_bytes);
}

test "parse configured indexers from Jackett indexer response" {
    const allocator = std.testing.allocator;

    const xml = "<indexers><indexer id=\"1337x\"><title>1337x</title></indexer><indexer id=\"thepiratebay\"><title>The Pirate Bay</title></indexer></indexers>";

    const indexers = try parseIndexers(allocator, xml);
    defer freeIndexers(allocator, indexers);

    try std.testing.expectEqual(@as(usize, 2), indexers.len);
    try std.testing.expectEqualStrings("1337x", indexers[0].id);
    try std.testing.expectEqualStrings("thepiratebay", indexers[1].id);
}

fn gzipStoredBody(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    if (body.len > std.math.maxInt(u16)) return error.OutOfMemory;

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, std.compress.flate.Container.header(.gzip));
    try result.append(allocator, 0x01);

    var bits16: [2]u8 = undefined;
    const len: u16 = @intCast(body.len);
    std.mem.writeInt(u16, &bits16, len, .little);
    try result.appendSlice(allocator, &bits16);
    std.mem.writeInt(u16, &bits16, ~len, .little);
    try result.appendSlice(allocator, &bits16);
    try result.appendSlice(allocator, body);

    var crc: std.hash.Crc32 = .init();
    crc.update(body);

    var bits32: [4]u8 = undefined;
    std.mem.writeInt(u32, &bits32, crc.final(), .little);
    try result.appendSlice(allocator, &bits32);
    std.mem.writeInt(u32, &bits32, @intCast(body.len), .little);
    try result.appendSlice(allocator, &bits32);

    return result.toOwnedSlice(allocator);
}

const GzipHttpServer = struct {
    body: []const u8,

    fn serve(self: *const GzipHttpServer, server: *std.Io.net.Server) !void {
        const io = compat.io();
        var stream = try server.accept(io);
        defer stream.close(io);

        var read_buf: [1]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        _ = reader.interface.readSliceShort(&read_buf) catch 0;

        var response_head: [256]u8 = undefined;
        const head = try std.fmt.bufPrint(
            &response_head,
            "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{self.body.len},
        );
        var write_buf: [4096]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        try writer.interface.writeAll(head);
        try writer.interface.writeAll(self.body);
        try writer.interface.flush();
    }
};

test "default body executor decompresses gzip indexer discovery response" {
    const allocator = std.testing.allocator;
    const xml = "<indexers><indexer id=\"alpha\"><title>Alpha</title></indexer><indexer id=\"beta\"><title>Beta</title></indexer></indexers>";

    const gzipped = try gzipStoredBody(allocator, xml);
    defer allocator.free(gzipped);

    const io = compat.io();
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try std.Io.net.IpAddress.listen(&address, io, .{ .reuse_address = true });
    defer server.deinit(io);

    const handler = GzipHttpServer{ .body = gzipped };
    const thread = try std.Thread.spawn(.{}, GzipHttpServer.serve, .{ &handler, &server });

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/api/v2.0/indexers/all/results/torznab/api?apikey=test&t=indexers&configured=true", .{server.socket.address.getPort()});
    defer allocator.free(url);

    const body = try defaultBodyExecutor(allocator, url);
    defer allocator.free(body);
    thread.join();

    try std.testing.expectEqualStrings(xml, body);

    const indexers = try parseIndexers(allocator, body);
    defer freeIndexers(allocator, indexers);
    try std.testing.expectEqual(@as(usize, 2), indexers.len);
    try std.testing.expectEqualStrings("alpha", indexers[0].id);
    try std.testing.expectEqualStrings("beta", indexers[1].id);
}

test "parse configured indexers rejects non-indexer response" {
    try std.testing.expectError(error.ParseFailed, parseIndexers(std.testing.allocator, "\x1f\x8b compressed or html"));
}

test "streaming search publishes batches as indexers complete" {
    const state = struct {
        fn exec(allocator: std.mem.Allocator, url: []const u8) JackettError![]u8 {
            if (std.mem.indexOf(u8, url, "t=indexers&configured=true") != null) {
                return allocator.dupe(u8, "<indexers><indexer id=\"slow\"><title>Slow</title></indexer><indexer id=\"fast\"><title>Fast</title></indexer></indexers>") catch error.OutOfMemory;
            }
            if (std.mem.indexOf(u8, url, "/indexers/slow/") != null) {
                compat.sleepNanos(20 * std.time.ns_per_ms);
                return allocator.dupe(u8, "<rss><channel><item><title>Slow Result</title><link>magnet:?xt=urn:btih:slow</link><torznab:attr name=\"seeders\" value=\"10\"/></item></channel></rss>") catch error.OutOfMemory;
            }
            if (std.mem.indexOf(u8, url, "/indexers/fast/") != null) {
                return allocator.dupe(u8, "<rss><channel><item><title>Fast Result</title><link>magnet:?xt=urn:btih:fast</link><torznab:attr name=\"seeders\" value=\"50\"/></item></channel></rss>") catch error.OutOfMemory;
            }
            return error.InvalidUrl;
        }
    };

    var client = Client.init(std.testing.allocator, "http://localhost:9117", "test-key");
    const session = try client.startStreamingSearch("ubuntu", state.exec, 2, false);
    defer session.deinit();

    var results: std.ArrayList(Torrent) = .empty;
    defer {
        for (results.items) |t| {
            std.testing.allocator.free(t.title);
            std.testing.allocator.free(t.link);
        }
        results.deinit(std.testing.allocator);
    }

    var saw_first_batch = false;
    var attempts: usize = 0;
    while (attempts < 200 and !session.isDone()) : (attempts += 1) {
        if (try session.drainInto(std.testing.allocator, &results)) {
            saw_first_batch = true;
            if (results.items.len == 1) break;
        }
        compat.sleepNanos(std.time.ns_per_ms);
    }
    try std.testing.expect(saw_first_batch);
    try std.testing.expect(results.items.len >= 1);

    while (!session.isDone()) {
        _ = try session.drainInto(std.testing.allocator, &results);
        compat.sleepNanos(std.time.ns_per_ms);
    }
    _ = try session.drainInto(std.testing.allocator, &results);

    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expectEqualStrings("Fast Result", results.items[0].title);
    try std.testing.expectEqualStrings("Slow Result", results.items[1].title);

    const snapshot = session.snapshot();
    try std.testing.expectEqual(ProgressPhase.done, snapshot.phase);
    try std.testing.expectEqual(@as(usize, 2), snapshot.total);
    try std.testing.expectEqual(@as(usize, 2), snapshot.completed);
    try std.testing.expectEqual(@as(usize, 0), snapshot.failed);
}

test "streaming search keeps successful results when one indexer fails" {
    const state = struct {
        fn exec(allocator: std.mem.Allocator, url: []const u8) JackettError![]u8 {
            if (std.mem.indexOf(u8, url, "t=indexers&configured=true") != null) {
                return allocator.dupe(u8, "<indexers><indexer id=\"ok\"><title>OK</title></indexer><indexer id=\"bad\"><title>Bad</title></indexer></indexers>") catch error.OutOfMemory;
            }
            if (std.mem.indexOf(u8, url, "/indexers/ok/") != null) {
                return allocator.dupe(u8, "<rss><channel><item><title>OK Result</title><link>magnet:?xt=urn:btih:ok</link><torznab:attr name=\"seeders\" value=\"5\"/></item></channel></rss>") catch error.OutOfMemory;
            }
            return error.HttpError;
        }
    };

    var client = Client.init(std.testing.allocator, "http://localhost:9117", "test-key");
    const session = try client.startStreamingSearch("ubuntu", state.exec, 2, false);
    defer session.deinit();

    var results: std.ArrayList(Torrent) = .empty;
    defer {
        for (results.items) |t| {
            std.testing.allocator.free(t.title);
            std.testing.allocator.free(t.link);
        }
        results.deinit(std.testing.allocator);
    }

    while (!session.isDone()) {
        _ = try session.drainInto(std.testing.allocator, &results);
        compat.sleepNanos(std.time.ns_per_ms);
    }
    _ = try session.drainInto(std.testing.allocator, &results);

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("OK Result", results.items[0].title);
    try std.testing.expect(session.fatalError() == null);

    const snapshot = session.snapshot();
    try std.testing.expectEqual(@as(usize, 2), snapshot.completed);
    try std.testing.expectEqual(@as(usize, 1), snapshot.failed);
}

test "streaming search reports discovery failure as fatal" {
    const state = struct {
        fn exec(_: std.mem.Allocator, _: []const u8) JackettError![]u8 {
            return error.ConnectionRefused;
        }
    };

    var client = Client.init(std.testing.allocator, "http://localhost:9117", "test-key");
    const session = try client.startStreamingSearch("ubuntu", state.exec, 2, false);
    defer session.deinit();

    while (!session.isDone()) {
        compat.sleepNanos(std.time.ns_per_ms);
    }

    try std.testing.expectEqual(@as(?JackettError, error.ConnectionRefused), session.fatalError());
    const snapshot = session.snapshot();
    try std.testing.expectEqual(ProgressPhase.done, snapshot.phase);
}

test "include non-magnet links" {
    const allocator = std.testing.allocator;

    const xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><rss version=\"1.0\"><channel><item><title>With Magnet</title><link>magnet:?xt=urn:btih:abc123</link><torznab:attr name=\"seeders\" value=\"100\"/></item><item><title>With Torrent Link</title><link>https://example.com/torrent.torrent</link><torznab:attr name=\"seeders\" value=\"200\"/></item><item><title>No Link</title></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(usize, 2), torrents.len);
    try std.testing.expectEqualStrings("With Torrent Link", torrents[0].title);
    try std.testing.expectEqual(@as(u32, 200), torrents[0].seeders);
    try std.testing.expectEqualStrings("With Magnet", torrents[1].title);
    try std.testing.expectEqual(@as(u32, 100), torrents[1].seeders);
}

test "resolve Jackett HTTP link to magnet redirect" {
    const mock = struct {
        fn fetch(allocator: std.mem.Allocator, url: []const u8) LinkResolveError!LinkFetchResponse {
            if (!std.mem.eql(u8, "https://jackett.local/dl/test", url)) return error.UnresolvableLink;
            return .{
                .status = @enumFromInt(302),
                .location = try allocator.dupe(u8, "magnet:?xt=urn:btih:redirected"),
            };
        }
    };

    var resolved = try resolveDownloadLink(std.testing.allocator, "https://jackett.local/dl/test", mock.fetch);
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqual(.magnet_redirect, resolved.kind);
    try std.testing.expectEqualStrings("magnet:?xt=urn:btih:redirected", resolved.value);
}

test "resolve Jackett HTTP link to temp torrent file" {
    const torrent_bytes = "d8:announce13:http://tracker4:info0:e";
    const mock = struct {
        fn fetch(allocator: std.mem.Allocator, url: []const u8) LinkResolveError!LinkFetchResponse {
            if (!std.mem.eql(u8, "https://jackett.local/dl/file", url)) return error.UnresolvableLink;
            return .{
                .status = .ok,
                .body = try allocator.dupe(u8, torrent_bytes),
            };
        }
    };

    var resolved = try resolveDownloadLink(std.testing.allocator, "https://jackett.local/dl/file", mock.fetch);
    defer resolved.deinit(std.testing.allocator);
    defer std.Io.Dir.deleteFileAbsolute(compat.io(), resolved.value) catch {};

    try std.testing.expectEqual(.torrent_file, resolved.kind);
    try std.testing.expect(std.mem.endsWith(u8, resolved.value, ".torrent"));

    const io = compat.io();
    const written_file = std.Io.Dir.openFileAbsolute(io, resolved.value, .{}) catch return error.TestExpectedEqual;
    defer compat.closeFile(written_file);
    var file_reader = written_file.reader(io, &.{});
    const written = file_reader.interface.allocRemaining(std.testing.allocator, std.Io.Limit.limited(1024)) catch return error.TestExpectedEqual;
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings(torrent_bytes, written);
}

test "resolve direct magnet passthrough" {
    const mock = struct {
        fn fetch(_: std.mem.Allocator, _: []const u8) LinkResolveError!LinkFetchResponse {
            unreachable;
        }
    };

    var resolved = try resolveDownloadLink(std.testing.allocator, "magnet:?xt=urn:btih:direct", mock.fetch);
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqual(.direct, resolved.kind);
    try std.testing.expectEqualStrings("magnet:?xt=urn:btih:direct", resolved.value);
}

test "resolve invalid HTTP link returns clear error" {
    const mock = struct {
        fn fetch(_: std.mem.Allocator, _: []const u8) LinkResolveError!LinkFetchResponse {
            return .{
                .status = @enumFromInt(302),
                .location = null,
            };
        }
    };

    try std.testing.expectError(
        error.UnresolvableLink,
        resolveDownloadLink(std.testing.allocator, "https://jackett.local/dl/missing-location", mock.fetch),
    );
}

test "sort by seeders descending" {
    const allocator = std.testing.allocator;

    const xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><rss version=\"1.0\"><channel><item><title>Low Seeders</title><link>magnet:?xt=urn:btih:aaa</link><torznab:attr name=\"seeders\" value=\"10\"/></item><item><title>High Seeders</title><link>magnet:?xt=urn:btih:bbb</link><torznab:attr name=\"seeders\" value=\"1000\"/></item><item><title>Medium Seeders</title><link>magnet:?xt=urn:btih:ccc</link><torznab:attr name=\"seeders\" value=\"100\"/></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(u32, 1000), torrents[0].seeders);
    try std.testing.expectEqual(@as(u32, 100), torrents[1].seeders);
    try std.testing.expectEqual(@as(u32, 10), torrents[2].seeders);
}

test "prefer enclosure over torznab magneturl and link" {
    const allocator = std.testing.allocator;

    const xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><rss version=\"1.0\"><channel><item><title>Has All Links</title><link>https://example.com/download.php?id=42</link><torznab:attr name=\"magneturl\" value=\"magnet:?xt=urn:btih:abc123&amp;dn=Test\"/><enclosure url=\"magnet:?xt=urn:btih:enclosure&amp;dn=Preferred\" type=\"application/x-bittorrent;x-scheme-handler/magnet\"/></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(usize, 1), torrents.len);
    try std.testing.expectEqualStrings("magnet:?xt=urn:btih:enclosure&dn=Preferred", torrents[0].link);
}

test "prefer torznab magneturl over link and decode entities" {
    const allocator = std.testing.allocator;

    const xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><rss version=\"1.0\"><channel><item><title>Has Magnet Attr</title><link>https://example.com/download.php?id=42</link><torznab:attr name=\"magneturl\" value=\"magnet:?xt=urn:btih:abc123&amp;dn=Test\"/></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(usize, 1), torrents.len);
    try std.testing.expectEqualStrings("magnet:?xt=urn:btih:abc123&dn=Test", torrents[0].link);
}

test "parse enclosure url when link tag is absent" {
    const allocator = std.testing.allocator;

    const xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><rss version=\"1.0\"><channel><item><title>Enclosure Only</title><enclosure url=\"https://example.com/download.php?id=987\" type=\"application/x-bittorrent\"/></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(usize, 1), torrents.len);
    try std.testing.expectEqualStrings("https://example.com/download.php?id=987", torrents[0].link);
}

test "decode numeric entities in links" {
    const allocator = std.testing.allocator;

    const xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><rss version=\"1.0\"><channel><item><title>Numeric Entities</title><link>magnet:?xt=urn:btih:abc123&#x26;dn=Hex&#38;tr=Dec</link></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(usize, 1), torrents.len);
    try std.testing.expectEqualStrings("magnet:?xt=urn:btih:abc123&dn=Hex&tr=Dec", torrents[0].link);
}

test "parse tolerates malformed or partial xml entries without failing" {
    const allocator = std.testing.allocator;

    const xml = "<rss><channel><item><title>Broken One<title><link>magnet:?xt=urn:btih:broken</link></item><item><title>Good One</title><link>magnet:?xt=urn:btih:good</link></item><item><title>No End";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expect(torrents.len >= 1);

    var saw_good = false;
    for (torrents) |t| {
        if (std.mem.eql(u8, t.title, "Good One")) saw_good = true;
    }
    try std.testing.expect(saw_good);
}

test "parse works with mixed field ordering inside item" {
    const allocator = std.testing.allocator;

    const xml = "<?xml version=\"1.0\"?><rss><channel><item><torznab:attr name=\"peers\" value=\"3\"/><link>magnet:?xt=urn:btih:first</link><title>First</title><torznab:attr name=\"seeders\" value=\"2\"/></item><item><torznab:attr name=\"seeders\" value=\"40\"/><title>Second</title><enclosure type=\"application/x-bittorrent\" url=\"https://example.com/second.torrent\"/><torznab:attr name=\"peers\" value=\"11\"/></item></channel></rss>";

    const torrents = try parseTorrents(allocator, xml);
    defer {
        for (torrents) |t| {
            allocator.free(t.title);
            allocator.free(t.link);
        }
        allocator.free(torrents);
    }

    try std.testing.expectEqual(@as(usize, 2), torrents.len);
    try std.testing.expectEqualStrings("Second", torrents[0].title);
    try std.testing.expectEqual(@as(u32, 40), torrents[0].seeders);
    try std.testing.expectEqual(@as(u32, 11), torrents[0].leechers);
    try std.testing.expectEqualStrings("https://example.com/second.torrent", torrents[0].link);
    try std.testing.expectEqualStrings("First", torrents[1].title);
    try std.testing.expectEqual(@as(u32, 2), torrents[1].seeders);
    try std.testing.expectEqual(@as(u32, 3), torrents[1].leechers);
}
