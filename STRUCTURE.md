# Repository Structure

This file summarizes tracked files to avoid re-scanning. Build artifacts in `zig-out/` are excluded by design.
Current project version: `v0.3.12`.

## Root

- `AGENTS.md`: Agent rules, Zig 0.15.2 constraints, workflows, and project overview.
- `CHANGELOG.md`: Project changelog for released and unreleased changes.
- `CLAUDE.md`: Project summary, architecture notes, and developer guidance.
- `README.md`: User-facing guide (requirements, setup, usage, troubleshooting).
- `LICENSE`: Project license.
- `STRUCTURE.md`: This repository map.
- `build.zig`: Zig build script defining modules, test steps, and kcov coverage reporting.
- `build.zig.zon`: Zig package metadata (name, version, minimum Zig, paths).

## GitHub Workflows (`.github/workflows/`)

- `.github/workflows/ci.yml`: Pull request and `main` CI for tests, cross-compilation checks, and formatting.
- `.github/workflows/release.yml`: `v*` tag release workflow that builds optimized executables and uploads them as release assets.

## Source (`src/`)

- `src/main.zig`: Program entry; initializes allocator, loads config, runs TUI app, and checks the entrypoint signature.
- `src/config.zig`: Config file path handling, creation, defaults patching, and validation.
- `src/debug/log.zig`: Optional debug logging controlled by environment variables.
- `src/update_checker.zig`: Latest-release checker (GitHub API fetch + semantic version comparison).
- `src/structs/torrent.zig`: `Torrent` struct definition and metadata storage test.
- `src/jackett/client.zig`: Jackett Torznab API client, gzip-aware body reads, configured-indexer discovery, parallel per-indexer searches, XML parsing, sorting, and selected download-link resolution.
- `src/superseedr/client.zig`: Superseedr integration, final magnet/path validation, process checks, spawn/add flow.
- `src/tui/term.zig`: Terminal raw mode, key reading, ANSI helpers, terminal size.
- `src/tui/theme.zig`: Color palette, border styles, and rendering helpers.
- `src/tui/panels.zig`: Shared panel/overlay rendering helpers for notices and errors.
- `src/tui/app.zig`: App state machine (search/loading/results/error) and orchestration.
- `src/tui/widgets/search.zig`: Search input widget and tests.
- `src/tui/widgets/results.zig`: Results list widget with navigation and tests.
