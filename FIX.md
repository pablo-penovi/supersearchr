# FIX.md — Compilation Fix Plan

## Summary

The project has **one file** with compilation errors: `src/jackett/client.zig`.
All other files (`main.zig`, `config.zig`, `superseedr/client.zig`, `tui/term.zig`,
`tui/app.zig`, `tui/widgets/search.zig`, `tui/widgets/results.zig`,
`structs/torrent.zig`) already use correct Zig 0.15.2 APIs and compile cleanly.
The test suite passes completely (27/27) because the broken HTTP code path
(`defaultSearchExecutor`) is unreachable from any test — but it is reachable from
the main executable, which is why `zig build` fails.

---

## Root Cause

Zig 0.15.2 replaced the old `std.io.Reader` (lowercase) interface with a new
`std.Io.Reader` (uppercase) interface. The new reader has a completely different
API: instead of a `.read(buf)` method it uses a streaming/vtable model with methods
like `readSliceShort`, `allocRemaining`, `streamRemaining`, etc.

The `std.http.Client` response object's `.reader()` method now returns a
`*std.Io.Reader`, so all code that calls `.read()` on it no longer compiles.

Additionally, `std.ArrayList(T)` in Zig 0.15.2 is now the **unmanaged** type
(it does not store the allocator internally). This means:
- `.deinit()` must be called as `.deinit(allocator)`
- `.appendSlice(items)` must be called as `.appendSlice(allocator, items)`

---

## Errors in Detail

All three bugs are inside the single function `defaultSearchExecutor` in
`src/jackett/client.zig` (lines 33–62):

### Error 1 — Confirmed compile error (line 56)
```zig
const bytes_read = reader.read(&read_buf) catch break;
```
`Io.Reader` has no `.read()` method. The compiler reports:
```
error: no field or member function named 'read' in 'Io.Reader'
```

### Error 2 — Hidden (line 51, revealed after Error 1 is fixed)
```zig
defer body.deinit();
```
`std.ArrayList(u8)` in 0.15.2 is unmanaged; `deinit` requires an allocator.
Correct call: `defer body.deinit(allocator);`

### Error 3 — Hidden (line 58, revealed after Error 1 is fixed)
```zig
try body.appendSlice(read_buf[0..bytes_read]);
```
Same reason: unmanaged `appendSlice` requires an allocator.
Correct call: `try body.appendSlice(allocator, read_buf[0..bytes_read]);`

---

## The Fix

Replace the body-accumulation block in `defaultSearchExecutor` (lines 50–61)
with the new `Io.Reader.allocRemaining()` API. This eliminates all three errors
at once and produces simpler code.

**File:** `src/jackett/client.zig`

**Current code (lines 33–62):**
```zig
pub fn defaultSearchExecutor(allocator: std.mem.Allocator, url: []const u8) anyerror![]Torrent {
    var http_client = std.http.Client{ .allocator = allocator };
    defer http_client.deinit();

    const uri = try std.Uri.parse(url);
    var request = try http_client.request(.GET, uri, .{});
    defer request.deinit();

    try request.sendBodiless();
    var header_buf: [1024]u8 = undefined;
    var response = try request.receiveHead(&header_buf);

    const status = response.head.status;
    if (status != .ok) {
        return error.HttpError;
    }

    var body: std.ArrayList(u8) = .{};
    defer body.deinit();                               // BUG: missing allocator

    var read_buf: [1024]u8 = undefined;
    var reader = response.reader(&read_buf);
    while (true) {
        const bytes_read = reader.read(&read_buf) catch break;  // BUG: .read() gone
        if (bytes_read == 0) break;
        try body.appendSlice(read_buf[0..bytes_read]); // BUG: missing allocator
    }

    return try parseTorrents(allocator, body.items);
}
```

**Replacement code:**
```zig
pub fn defaultSearchExecutor(allocator: std.mem.Allocator, url: []const u8) anyerror![]Torrent {
    var http_client = std.http.Client{ .allocator = allocator };
    defer http_client.deinit();

    const uri = try std.Uri.parse(url);
    var request = try http_client.request(.GET, uri, .{});
    defer request.deinit();

    try request.sendBodiless();
    var header_buf: [1024]u8 = undefined;
    var response = try request.receiveHead(&header_buf);

    const status = response.head.status;
    if (status != .ok) {
        return error.HttpError;
    }

    var read_buf: [4096]u8 = undefined;
    const reader = response.reader(&read_buf);
    const body = try reader.allocRemaining(allocator, .unlimited);
    defer allocator.free(body);

    return try parseTorrents(allocator, body);
}
```

**Why this is safe:**
- `parseTorrents` calls `allocator.dupe()` on all title and link strings it
  extracts from the XML, so they are independent copies. Freeing `body` after
  `parseTorrents` returns leaves no dangling pointers.
- `defer allocator.free(body)` runs on both success and error paths, so memory
  is never leaked regardless of what `parseTorrents` does.

---

## Verification Steps

After applying the fix:

```bash
zig build               # must succeed with no errors
zig build test --summary all   # must still pass 27/27 tests
```

---

## Files Changed

| File | Change |
|------|--------|
| `src/jackett/client.zig` | Rewrite body-reading block in `defaultSearchExecutor` |

No other files need changes.
