# Repository Structure

This file summarizes tracked files to avoid re-scanning. Build artifacts in `zig-out/` are excluded by design.
Current project version: `v0.2.2`.

## Root

- `AGENTS.md`: Agent rules, Zig 0.15.2 constraints, workflows, and project overview.
- `CHANGELOG.md`: Project changelog for released and unreleased changes.
- `CLAUDE.md`: Project summary, architecture notes, and developer guidance.
- `README.md`: User-facing guide (requirements, setup, usage, troubleshooting).
- `LICENSE`: Project license.
- `STRUCTURE.md`: This repository map.
- `build.zig`: Zig build script defining modules and test steps.
- `build.zig.zon`: Zig package metadata (name, version, minimum Zig, paths).

## Source (`src/`)

- `src/main.zig`: Program entry; initializes allocator, loads config, runs TUI app.
- `src/config.zig`: Config file path handling, creation, defaults patching, and validation.
- `src/debug/log.zig`: Optional debug logging controlled by environment variables.
- `src/structs/torrent.zig`: `Torrent` struct definition.
- `src/jackett/client.zig`: Jackett Torznab API client, URL building, XML parsing, sorting.
- `src/superseedr/client.zig`: Superseedr integration, process checks, spawn/add flow.
- `src/tui/term.zig`: Terminal raw mode, key reading, ANSI helpers, terminal size.
- `src/tui/theme.zig`: Color palette, border styles, and rendering helpers.
- `src/tui/app.zig`: App state machine (search/loading/results/error), rendering, and actions.
- `src/tui/widgets/search.zig`: Search input widget and tests.
- `src/tui/widgets/results.zig`: Results list widget with navigation and tests.
