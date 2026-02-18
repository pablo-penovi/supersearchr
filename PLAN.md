# supersearchr - Detailed Implementation Plan

## 1. Project Overview

A Zig TUI application to search torrents via Jackett, display magnet-enabled results sorted by seeders, and send selected magnets to `superseedr`.

## 2. File Structure

```
src/
├── main.zig              # Entry point, app initialization
├── config.zig           # Config loading/creation
├── jackett/
│   └── client.zig       # Jackett API client
├── tui/
│   ├── term.zig         # Terminal utilities (raw mode, keys, colors)
│   ├── app.zig          # Main TUI state machine
│   └── widgets/
│       ├── search.zig    # Search input widget
│       └── results.zig   # Results list widget
└── superseedr.zig       # superseedr integration
```

## 3. Modules

### 3.1 Config (`config.zig`)

**Responsibility:** Load config, create if missing

**JSON Format (camelCase):**
```json
{
  "apiKey": "YOUR_JACKETT_API_KEY",
  "apiUrl": "YOUR_JACKET_URL",
  "apiPort": 9117
}
```

**Zig Struct (snake_case):**
```zig
pub const Config = struct {
    api_key: []const u8,
    api_url: []const u8,
    api_port: u16,
};

pub fn loadConfig(allocator: std.mem.Allocator) !Config
```

**Behavior:**
1. Path: `~/.config/supersearchr/config.json`
2. Check if exists
3. If not:
   - Create directory `~/.config/supersearchr/`
   - Write placeholder:
     ```json
     {
       "apiKey": "YOUR_JACKETT_API_KEY",
       "apiUrl": "YOUR_JACKET_URL",
       "apiPort": 9117
     }
     ```
   - Print error: "Config created at ~/.config/supersearchr/config.json. Please add your Jackett API key, URL and port."
   - Exit with code 1
4. Parse JSON, validate all three fields exist and are not the default/empty values
- Test missing config creates file
- Test missing config field returns error for each field (apiKey, apiUrl, apiPort)
- Test default config value returns error for each field (apiKey, apiUrl, apiPort)

---

### 3.2 Jackett Client (`jackett/client.zig`)

**Responsibility:** Search torrents via Jackett API

**Public API:**
```zig
pub const Torrent = struct {
    title: []const u8,
    seeders: u32,
    leechers: u32,
    magnet_uri: ?[]const u8,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    api_key: []const u8,
    http_client: std.http.Client,

    pub fn search(self: *Client, query: []const u8) ![]Torrent
};
```

**Implementation:**
- Endpoint: `<apiUrl>:<apiPort>/api/v2.0/indexers/all/results?apikey=<key>&q=<query>&o=json`
- Use `std.http.Client`
- Parse JSON response
- Filter: only keep results where `magnet_uri` is non-null
- Sort by `seeders` descending

**Error handling:**
- Connection refused → "Cannot connect to Jackett. Is it running on URL <apiUrl> and port <apiPort>?"
- HTTP error → "Jackett returned error: <code>"
- JSON parse error → "Failed to parse Jackett response"

**Unit Tests:**
- Test JSON parsing with valid response
- Test filtering results without magnet
- Test sorting by seeders descending
- Test connection refused error
- Test HTTP error response by Jackett API
- Test JSON parse error when invalid JSON received

---

### 3.3 Terminal Utilities (`tui/term.zig`)

**Responsibility:** Raw terminal control, key reading, output

**Public API:**
```zig
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
    value: u8,  // for char/digit
};

pub fn initTerm() !void
pub fn deinitTerm() void
pub fn readKey() !Event
pub fn clearScreen() void
pub fn moveCursor(row: u16, col: u16) void
pub fn setColor(fg: Color) void
pub fn resetColor() void

pub const Color = enum {
    red, green, yellow, blue, white, cyan,
};
```

**Implementation:**
- Use `std.posix.tcgetattr`/`tcsetattr` for raw mode
- Store original termios, restore on deinit
- Read with `std.io.getStdIn().readByte()` 
- Handle escape sequences for special keys
- ANSI escape codes for colors/cursor
- Ensure cross platform compatibility

**Unit Tests:**
- Test color escape code generation
- Test cursor position escape code generation

---

### 3.4 superseedr Integration (`superseedr.zig`)

**Responsibility:** Execute superseedr add command

**Public API:**
```zig
pub fn addMagnet(magnet: []const u8) !void
```

**Implementation:**
- Use `std.process.Child.run()` with `&.{"superseedr", "add", magnet}`
- Check for `std.process.Child.RunError`
- On success: print "Added to superseedr" in green
- On spawn failure: "Error: superseedr not found. Ensure it is in your PATH."
- On error by superseedr: "Error: superseedr returned error: <message>"

**Unit Tests:**
- Test magnet URL validation (starts with "magnet:")
- Test command building

---

### 3.5 TUI App (`tui/app.zig`)

**Responsibility:** Main state machine and render loop

**States:**
```zig
const State = union(enum) {
    search: SearchState,
    results: ResultsState,
    loading: LoadingState,
    error: ErrorState,
};

const SearchState = struct {
    query: std.ArrayList(u8),
};

const ResultsState = struct {
    torrents: []Torrent,
    selected_idx: ?usize,
};

const LoadingState = struct {
    query: []const u8,
};

const ErrorState = struct {
    message: []const u8,
};
```

**Main Loop:**
```zig
pub fn run(allocator: std.mem.Allocator, config: Config) !void
```

**Flow:**
1. **SEARCH state**: Render input prompt, read keystrokes, build query
2. On Enter → transition to LOADING
3. **LOADING state**: Call Jackett client, on success → RESULTS, on error → ERROR
4. **RESULTS state**: Render numbered list, read number input or commands
5. On valid number Enter → add to superseedr, show result, stay in RESULTS
6. **ERROR state**: Show error message, any key → back to SEARCH
7. **ESC** from any state → exit

**Unit Tests:**
- Test state transitions
- Test number parsing from input

---

### 3.6 Widgets

**Search Widget:**
- Prompt: "Search: "
- Echo typed characters
- Backspace to delete
- Enter to submit

**Results Widget:**
- Format: `{idx}. {title} [S:{seeders} L:{leechers}]`
- Max display: fit screen height - 3 (leave room for status/hints)
- If more results: show "(showing first N of M)"
- Input: digits build number, Enter selects
- ESC: return to search
- 'n': new search

---

## 4. User Interface

### Search Screen
```
┌─────────────────────────────────────────┐
│ Search: █                               │
│ [Enter to search, ESC to exit]          │
└─────────────────────────────────────────┘
```

### Results Screen
```
┌─────────────────────────────────────────┐
│ Results for "matrix" (15 found)         │
│ 1. The Matrix 1999 1080p [S:1234 L:56]  │
│ 2. The Matrix Reloaded [S:987 L:23]     │
│ 3. The Matrix Revolutions [S:456 L:12]  │
│ ...                                     │
│ ─────────────────────────────────────── │
│ > _                                     │
│ [Enter number to add, ESC exit, n new]  │
└─────────────────────────────────────────┘
```

### Loading Screen
```
┌─────────────────────────────────────────┐
│ Searching...                            │
└─────────────────────────────────────────┘
```

### Error Screen
```
┌─────────────────────────────────────────┐
│ Error: Cannot connect to Jackett        │
│ Press any key to continue               │
└─────────────────────────────────────────┘
```

---

## 5. Error Handling Summary

| Error | Message | Action |
|-------|---------|--------|
| Config missing | "Config created. Please add API key." | Exit 1 |
| Config invalid JSON | "Invalid config file format" | Exit 1 |
| Config missing apiKey | "apiKey not found in config" | Exit 1 |
| Config missing apiUrl | "apiUrl not found in config" | Exit 1 |
| Config missing apiPort | "apiPort not found in config" | Exit 1 |
| Config empty apiKey | "apiKey cannot be empty" | Exit 1 |
| Config empty apiUrl | "apiUrl cannot be empty" | Exit 1 |
| Jackett connection | "Cannot connect to Jackett" | Show error screen |
| Jackett HTTP error | "Jackett error: {code}" | Show error screen |
| Jackett parse error | "Failed to parse response" | Show error screen |
| superseedr not found | "superseedr not in PATH" | Show error + Exit 1 |
| superseedr failed | "Failed to add magnet" | Show in results screen |

---

## 6. Dependencies

None. All from Zig 0.15.2 std:
- `std.json` - JSON parsing
- `std.http` - HTTP client
- `std.posix` - Terminal control
- `std.process` - Child process

---

## 7. Implementation Steps

1. Create `src/config.zig` - config loading/creation + tests
2. Create `src/jackett/client.zig` - Jackett API + tests
3. Create `src/tui/term.zig` - Terminal utilities + tests
4. Create `src/superseedr.zig` - superseedr integration + tests
5. Create `src/tui/widgets/search.zig` - Search input
6. Create `src/tui/widgets/results.zig` - Results display
7. Create `src/tui/app.zig` - State machine + tests
8. Update `src/main.zig` - Wire everything
9. Run `zig build test` to verify all tests pass
10. Manual testing

---

## 8. Testing Strategy

- **Unit tests** for each module (config, jackett, term, superseedr, app)
- Run with `zig build test`
- Mock HTTP responses where possible for jackett client tests
- Manual testing for TUI interaction
