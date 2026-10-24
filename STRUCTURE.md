# Repository Structure

This file summarizes tracked files to avoid re-scanning. Build artifacts in `zig-out/` are excluded by design.
Current project version: `v0.5.0`.

## Root

- `AGENTS.md`: Agent rules, Zig 0.17.0 constraints, feature/release workflows, and project overview.
- `CHANGELOG.md`: Project changelog for released and unreleased changes.
- `CLAUDE.md`: Project summary, architecture notes, and developer guidance.
- `README.md`: User-facing guide (requirements, setup, usage, troubleshooting).
- `LICENSE`: Project license.
- `STRUCTURE.md`: This repository map.
- `build.zig`: Zig build script defining modules, test steps, and kcov coverage reporting.
- `build.zig.zon`: Zig package metadata (name, version, minimum Zig, paths).

## GitHub Workflows (`.github/workflows/`)

- `.github/workflows/ci.yml`: Pull request and `main` CI for tests, cross-compilation checks, and formatting.
- `.github/workflows/coverage-pages.yml`: `main` and manual workflow that runs `zig build coverage`, publishes the merged kcov HTML report to GitHub Pages, and generates the Shields-compatible coverage badge endpoint.
- `.github/workflows/release.yml`: `v*` tag release workflow that builds optimized executables and uploads them as release assets.

## Source (`src/`)

- `src/main.zig`: Program entry; initializes the allocator and the app's `std.Io.Threaded`, loads config, runs TUI app, and checks the entrypoint signature.
- `src/config.zig`: Config file path handling, creation, defaults patching, and validation.
- `src/debug/log.zig`: Optional debug logging controlled by environment variables.
- `src/update_checker.zig`: Latest-release checker (GitHub API fetch + semantic version comparison).
- `src/profiles.zig`: Indexer profiles store (named indexer-ID sets plus the active profile, with upsert/rename/remove), apply-plan diffing, and `profiles.json` persistence.
- `src/record.zig`: Per-indexer search outcome history (last five successes/failures) persisted to `record.json`.
- `src/last_status.zig`: Per-indexer latest enable/disable outcome persisted to `last_status.json`.
- `src/structs/torrent.zig`: `Torrent` struct definition (title, stats, optional byte size, optional pub date, link) and metadata storage test.
- `src/jackett/admin_client.zig`: Jackett admin REST client for login, indexer listing, config get/set/delete, and local disabled-indexer config caching.
- `src/jackett/client.zig`: Jackett Torznab API client, gzip-aware body reads, configured-indexer discovery, streaming parallel per-indexer searches, XML parsing including size and pubDate metadata, sorting, and selected download-link resolution.
- `src/jackett/http_exec.zig`: Shared low-level HTTP request executor used by Jackett client modules.
- `src/jackett/url_encode.zig`: Percent-encoding helper for Torznab/admin URL path and query components.
- `src/superseedr/client.zig`: Superseedr integration, final magnet/path validation, process checks, spawn/add flow.
- `src/tui/term.zig`: Terminal raw mode, key reading, ANSI helpers, terminal size.
- `src/tui/theme.zig`: Color palette, border styles, and rendering helpers.
- `src/tui/panels.zig`: Shared panel/overlay rendering helpers for notices, errors, and the profile save/apply/delete prompts.
- `src/tui/app.zig`: App state machine (search/results/indexers/profiles/error), streaming Jackett session orchestration, indexer management and profile flows (worker-thread commits with live progress), a background startup check for active-profile drift, and Superseedr handoff.
- `src/tui/widgets/indexers.zig`: Indexers table widget with navigation, toggle state, Record/Last Status columns, commit progress, save/revert actions, and tests.
- `src/tui/widgets/profiles.zig`: Profiles list widget for the F2 screen with a side-by-side details panel previewing the selected profile's changes, navigation, load/rename/delete actions, apply progress, and tests.
- `src/tui/widgets/list_nav.zig`: Shared cursor/scroll/page navigation helpers and the commit-progress type used by list-style widgets.
- `src/tui/widgets/hints.zig`: Key-hints footer marquee: scrolls the hints back and forth when they are wider than the terminal instead of letting them wrap.
- `src/tui/widgets/search.zig`: Search input widget with the active-profile label, and tests.
- `src/tui/widgets/results.zig`: Results list widget with navigation, live search status, streaming update preservation, stats/size/age table rendering, and tests.
