# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Supersearchr is a TUI (terminal user interface) BitTorrent search tool written in Zig 0.15.2. It searches for torrents via **Jackett** (a torrent indexer API) and sends selected magnets/torrents to **Superseedr** (a companion TUI torrent client).

## Commands

```bash
zig build                          # Compile (output: zig-out/bin/supersearchr)
zig build run                      # Build and run
zig build test --summary all       # Run all tests with detailed output
```

Always use `--summary all` when running tests to see test names and pass/fail status.

## Architecture

The app is a state machine: **SEARCH → LOADING → RESULTS**, with ESC exiting from any state.

```
src/
├── main.zig              # Entry point; loads config, launches app
├── config.zig            # Loads ~/.config/supersearchr/config.json; validates apiKey, apiUrl, apiPort
├── structs/torrent.zig   # Data struct: title, seeders, leechers, link
├── jackett/client.zig    # HTTP client for Jackett Torznab API; parses XML manually; sorts by seeders
├── superseedr/client.zig # Spawns `superseedr add <link>` subprocess; validates magnet/torrent links
└── tui/
    ├── term.zig          # Raw terminal mode, key reading, ANSI colors, terminal size
    ├── app.zig           # Main event loop and state machine; wires all modules together
    └── widgets/
        ├── search.zig    # Search input widget
        └── results.zig   # Results list widget (numbered, digit input to select)
```

Modules use **dependency injection** (function pointer `executor` fields) for testability — both `jackett/client.zig` and `superseedr/client.zig` accept an executor that can be swapped in tests.

Each module has its own test section in `build.zig`. When adding a new module with tests, follow the existing pattern (`config_tests`, `jackett_tests`, etc.) and add it to `test_step`.

## Zig 0.15.2 Critical Rules

**Only use syntax and APIs compatible with Zig 0.15.2.** When in doubt, check: https://ziglang.org/documentation/0.15.2/

- **ArrayList init:** Use `std.ArrayList(T) = .{}` — **NOT** `.init(allocator)` (invalid in 0.15.2)
- **ArrayList append:** Use `list.append(allocator, item)` — **NOT** `list.append(item)`
- **Defer captures:** Use `|*inner|` (var capture), not `|inner|` (const capture) when mutating in defer blocks
- **Stdin/stdout:** Use `std.fs.File.stdin()` / `std.fs.File.stdout()` — **NOT** `std.io.getStdIn()` / `std.io.getStdOut()` (deprecated)
- Do not use `std.debug.print` in tests or production code unless explicitly requested

## Workflows

### Starting a new feature

These steps are **mandatory** before any new task:

1. If current branch is not `main` and has uncommitted changes or unpushed commits → inform user, stop, await instructions
2. Switch to `main` if not already on it
3. If `main` has uncommitted/unpushed changes → inform user, stop, await instructions
4. Pull latest changes from `main`
5. Checkout a new branch: `feature/{succinct-name}` (verify it doesn't exist locally or remotely)
6. Push the branch to remote immediately

### Finishing a feature

When the user asks to finish/finalize a feature:

1. Run tests (`zig build test --summary all`). If they fail → investigate and diagnose, but **do not fix** — report findings and proposed fixes to the user
2. If tests pass → commit and push any uncommitted/unpushed changes
3. Create a PR via GitHub CLI with a short but descriptive title and adequate description of changes
