# supersearchr

[![coverage](https://img.shields.io/endpoint?url=https%3A%2F%2Fpablo-penovi.github.io%2Fsupersearchr%2Fcoverage-badge.json%3Fv%3D1&cacheSeconds=300)](https://pablo-penovi.github.io/supersearchr/coverage/)

Terminal-first BitTorrent search for [Jackett](https://github.com/Jackett/Jackett) + [Superseedr](https://github.com/Jagalite/superseedr), written in Zig 0.16.0.

`supersearchr` lets you search Jackett from a TUI, browse sorted results, manage active Jackett indexers, and send a selected magnet/torrent link to `superseedr add`. Searches query configured Jackett indexers in parallel, stream result batches as each indexer finishes, and keep the displayed list sorted by seeders while the search continues.
Current project version: `v0.4.4`.

## Requirements

- Linux, macOS, or Windows (Windows Terminal recommended on Windows)
- Zig `0.16.0`
- `kcov` for coverage reports
- A running Jackett instance with API key
- `superseedr` CLI in your `PATH`

## Quick Start

```bash
zig build
zig build run
```

On first run, `supersearchr` creates:

- Linux: `~/.config/supersearchr/config.json`
- macOS: `~/Library/Application Support/supersearchr/config.json`
- Windows: `%LOCALAPPDATA%\supersearchr\config.json`

Then it exits so you can fill in real Jackett values.

## Build, Run, Test

```bash
# Build (installs artifact to zig-out/bin/supersearchr)
zig build

# Run
zig build run

# Build optimized for your current machine
zig build -Doptimize=ReleaseSafe -Dtarget=native-native

# Cross-compile examples
zig build -Dtarget=x86_64-linux
zig build -Dtarget=x86_64-macos
zig build -Dtarget=aarch64-macos
zig build -Dtarget=x86_64-windows

# Run all tests with detailed summary
zig build test --summary all

# Run tests through kcov and merge coverage reports
zig build coverage
```

Coverage output is written to `coverage/`. Open `coverage/merged/kcov-merged/index.html` for the merged HTML report, or use `coverage/merged/kcov-merged/cobertura.xml` for Cobertura-compatible tooling. The `Coverage Pages` workflow publishes the merged report to GitHub Pages and serves the README coverage badge from the generated Cobertura summary.

## Installation

After building, copy `zig-out/bin/supersearchr` to a directory in your `PATH`, for example `~/.local/bin`.

## Platform Notes

- Linux: defaults should work in common ANSI-capable terminals.
- macOS: run from Terminal.app or iTerm2.
- Windows: run from Windows Terminal (PowerShell or cmd), not legacy `conhost` shells.
- `superseedr` must be available in `PATH` on all platforms.
- Spawned Superseedr terminals are launched independently; on Linux/macOS they are detached from the `supersearchr` process group, so closing `supersearchr` does not terminate them.

## Configuration

Config path:

- Linux: `~/.config/supersearchr/config.json`
- macOS: `~/Library/Application Support/supersearchr/config.json`
- Windows: `%LOCALAPPDATA%\supersearchr\config.json`

Expected format:

```json
{
  "apiKey": "YOUR_JACKETT_API_KEY",
  "apiUrl": "http://127.0.0.1",
  "apiPort": 9117,
  "terminal": "ghostty",
  "jackettAdminPassword": ""
}
```

Notes:

- `apiKey`, `apiUrl`, and `apiPort` are required.
- `terminal` is kept for compatibility and defaults by OS (`ghostty`/`Terminal`/`wt`).
- `jackettAdminPassword` is optional. Leave it empty if Jackett's admin API does not require a password.
- Placeholder values like `YOUR_JACKETT_API_KEY` / `YOUR_JACKET_URL` are rejected.

## Usage

Search screen:

- Type query text
- `Enter`: search
- `F1`: open indexers management
- `Esc`: exit app

Results screen:

- `Up` / `Down`: move one result
- `Shift+Up` / `Shift+Down`: move one page
- `Left` / `Right`: move sort cursor
- `Tab`: apply/toggle sorting
- `Enter`: send selected link to Superseedr
- `s` or `S`: new search
- `r` or `R`: refresh completed results
- `/`: search within the current results list
- `e` or `E`: review failed indexers when failures are present
- `F1`: open indexers management
- `Esc`: exit app

Indexers screen:

- `Up` / `Down`: move one indexer
- `Shift+Up` / `Shift+Down`: move one page
- `Space`: toggle selected indexer active/inactive
- `Enter`: save pending changes
- `Esc`: revert pending changes, or return to the previous screen when there are none

Results show publication age, seeders, leechers, and torrent size when Jackett provides size metadata. New results appear incrementally while configured indexers are still searching, and the bottom status row shows discovery/search progress plus per-indexer failures.

Disabling an indexer deletes it through Jackett's admin API after caching its config locally under the app config directory. Re-enabling restores the cached config.

State flow: `SEARCH -> RESULTS -> INDEXERS -> ERROR`

## Debug Logging

```bash
# Enable debug logs
SUPERSEARCHR_DEBUG=1 supersearchr

# Custom log path (default: OS temp dir + supersearchr-debug.log)
SUPERSEARCHR_DEBUG=1 SUPERSEARCHR_DEBUG_PATH=/path/to/supersearchr.log supersearchr
```

Windows PowerShell examples:

```powershell
$env:SUPERSEARCHR_DEBUG = "1"
supersearchr

$env:SUPERSEARCHR_DEBUG = "1"
$env:SUPERSEARCHR_DEBUG_PATH = "C:\temp\supersearchr.log"
supersearchr
```

Logs include Jackett request/parsing failures, Superseedr execution failures, and selected torrent metadata.

## Troubleshooting

- `Cannot connect to Jackett. Is it running?`
  - Verify Jackett is running and `apiUrl`/`apiPort` are correct.
- `superseedr not found in PATH`
  - Install `superseedr` and ensure it is discoverable in your shell `PATH`.
- On Windows, `superseedr` process check fails unexpectedly
  - Confirm `tasklist` is available and `superseedr.exe` is the running process name.
- UI does not render correctly on Windows
  - Use Windows Terminal and avoid shells that do not support ANSI/VT sequences.
- Terminal size/layout issues on macOS
  - Use Terminal.app or iTerm2 and avoid launching from non-interactive contexts.
- Config file keeps failing validation
- Ensure `apiKey` and `apiUrl` are not placeholders and `apiPort` is between `1` and `65535`.

## Project Layout

See `STRUCTURE.md` for a concise map of source files.
See `CHANGELOG.md` for release history.
