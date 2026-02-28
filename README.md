# supersearchr

Terminal-first BitTorrent search for Jackett + Superseedr, written in Zig 0.15.2.

`supersearchr` lets you search Jackett from a TUI, browse sorted results, and send a selected magnet/torrent link to `superseedr add`.
Current project version: `v0.2.2`.

## Requirements

- Linux (this is the only platform currently guaranteed)
- Zig `0.15.2`
- A running Jackett instance with API key
- `superseedr` CLI in your `PATH`
- A terminal emulator in your `PATH` (used to launch `superseedr` if not already running)

## Quick Start

```bash
zig build
zig build run
```

On first run, `supersearchr` creates:

`~/.config/supersearchr/config.json`

Then it exits so you can fill in real Jackett values.

## Build, Run, Test

```bash
# Build (installs artifact to zig-out/bin/supersearchr)
zig build

# Run
zig build run

# Build optimized for your current machine
zig build -Doptimize=ReleaseSafe -Dtarget=native-native

# Cross-compile Linux binary example
zig build -Dtarget=x86_64-linux

# Run all tests with detailed summary
zig build test --summary all
```

## Installation

After building, copy `zig-out/bin/supersearchr` to a directory in your `PATH`, for example `~/.local/bin`.

## Configuration

Config path:

`~/.config/supersearchr/config.json`

Expected format:

```json
{
  "apiKey": "YOUR_JACKETT_API_KEY",
  "apiUrl": "http://127.0.0.1",
  "apiPort": 9117,
  "terminal": "ghostty"
}
```

Notes:

- `apiKey`, `apiUrl`, and `apiPort` are required.
- `terminal` is used when `superseedr` is not running and the app needs to spawn it.
- Placeholder values like `YOUR_JACKETT_API_KEY` / `YOUR_JACKET_URL` are rejected.

## Usage

Search screen:

- Type query text
- `Enter`: search
- `Esc`: exit app

Results screen:

- `j` / `k`: move down/up one result
- `J` / `K`: move down/up one page
- `Enter`: send selected link to Superseedr
- `n` or `N`: new search
- `Esc`: exit app

State flow: `SEARCH -> LOADING -> RESULTS -> ERROR`

## Debug Logging

```bash
# Enable debug logs
SUPERSEARCHR_DEBUG=1 supersearchr

# Custom log path (default: /tmp/supersearchr-debug.log)
SUPERSEARCHR_DEBUG=1 SUPERSEARCHR_DEBUG_PATH=/path/to/supersearchr.log supersearchr
```

Logs include Jackett request/parsing failures, Superseedr execution failures, and selected torrent metadata.

## Troubleshooting

- `Cannot connect to Jackett. Is it running?`
  - Verify Jackett is running and `apiUrl`/`apiPort` are correct.
- `superseedr not found in PATH`
  - Install `superseedr` and ensure it is discoverable in your shell `PATH`.
- Config file keeps failing validation
  - Ensure `apiKey` and `apiUrl` are not placeholders and `apiPort` is a non-zero number.

## Project Layout

See `STRUCTURE.md` for a concise map of source files.
