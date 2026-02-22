# Repository Structure

This file summarizes tracked files to avoid re-scanning. Build artifacts in `zig-out/` are excluded by design.

## Root

- `AGENTS.md`: Agent rules, Zig 0.15.2 constraints, workflows, and project overview.
- `CLAUDE.md`: Project summary, architecture notes, and developer guidance.
- `FIX.md`: Historical compilation fix plan for Jackett client and Zig 0.15.2 API changes.
- `PLAN.md`: Legacy implementation plan and architecture notes.
- `README.md`: One-line project description.
- `LICENSE`: Project license.
- `build.zig`: Zig build script defining modules and test steps.
- `build.zig.zon`: Zig package metadata (name, version, minimum Zig, paths).

## Source (`src/`)

- `src/main.zig`: Program entry; initializes allocator, loads config, runs TUI app.
- `src/config.zig`: Config file path handling, creation, defaults patching, and validation.
- `src/structs/torrent.zig`: `Torrent` struct definition.
- `src/jackett/client.zig`: Jackett Torznab API client, URL building, XML parsing, sorting.
- `src/superseedr/client.zig`: Superseedr integration, process checks, spawn/add flow.
- `src/tui/term.zig`: Terminal raw mode, key reading, ANSI helpers, terminal size.
- `src/tui/app.zig`: App state machine (search/loading/results/error), rendering, and actions.
- `src/tui/widgets/search.zig`: Search input widget and tests.
- `src/tui/widgets/results.zig`: Results list widget with navigation and tests.
