## Tooling

This project is compiled using Zig 0.15.2.
**CRITICAL**: It is essential to only use syntax, objects and functions that are compatible with Zig 0.15.2. It's wise to search in the Zig docs: https://ziglang.org/documentation/0.15.2/

## Coding rules

- Do not use *std.Arraylist({type}).init(allocator)* to initialize ArrayList. This is INVALID in Zig 0.15.2. Instead, use *std.ArrayList({type}) = .{}*
- When appending an item to an ArrayList, do not use *{array}.append(item)*. This is INVALID in Zig 0.15.2. Instead, use *{array}.append(allocator, item)*
- When using this structure:
```zig
// the "list" variable in this example is a std.ArrayList that you receive from another function
defer {
    for (list.items) |*inner| {
        inner.deinit(allocator);
    }
    list.deinit(allocator);
}
```
make sure the capture is a var (|*{name}|) and not a const (|{name}|)
- When adding a new module with tests, add a corresponding test section in build.zig following the pattern of existing tests (config_tests, jackett_tests, superseedr_tests, search_widget_tests, results_widget_tests, app_tests) and dependOn it in the test_step
- std.io.getStdIn() and std.io.getStdOut() are deprecated in Zig 0.15.2. Use std.fs.File.stdin() and std.fs.File.stdout() instead

## Running Tests

- Always run tests with `zig build test --summary all` to see detailed output including test names and pass/fail status
- Do not use `std.debug.print` for output in tests or production code unless explicitly asked by the user or the plan

## Project Overview

Supersearchr is a TUI BitTorrent search tool written in Zig 0.15.2. It searches via Jackett and sends selected magnet or torrent links to Superseedr.

## Commands

```bash
zig build                          # Compile (output: zig-out/bin/supersearchr)
zig build run                      # Build and run
zig build test --summary all       # Run all tests with detailed output
```

## Architecture

The app is a state machine: SEARCH → LOADING → RESULTS → ERROR, with ESC exiting from any state.

Modules use dependency injection (function pointer executors/checkers/spawners) for testability in `jackett/client.zig` and `superseedr/client.zig`.

## Key Modules

- `src/main.zig`: Entry point; loads config and starts the TUI app.
- `src/config.zig`: Loads `~/.config/supersearchr/config.json`, validates required fields, and patches optional defaults like `terminal`.
- `src/structs/torrent.zig`: Torrent struct (title, seeders, leechers, link).
- `src/jackett/client.zig`: Jackett Torznab HTTP client; parses XML and sorts results.
- `src/superseedr/client.zig`: Spawns or talks to `superseedr add <link>`, validates link format.
- `src/tui/term.zig`: Raw terminal mode, input, ANSI helpers, size detection.
- `src/tui/app.zig`: Main event loop and state machine.
- `src/tui/widgets/search.zig`: Search input widget.
- `src/tui/widgets/results.zig`: Results list widget with navigation and selection.

## Repository Map

See `STRUCTURE.md` for a concise summary of all tracked files and their contents.

## Workflows

### Starting a new feature

When the user asks you to start a new feature, he should tell you what the feature is about. If he forgets, ask him for it.

**MANDATORY**: These steps should ALWAYS be executed first when starting a new task, and should always be the first steps when making a plan for a new task:

1. If current branch is not main, and has uncommitted changes or unpushed commits, inform user, stop and await instructions
2. If current branch is not main, switch to main
3. If main has uncomitted changes or unpushed commits, inform user, stop and await instructions
4. Pull latest changes from main
5. Checkout a new branch with the format "feature/{succint name for task}" (ensure branch doesn't exist already in local or remote)
6. Push the branch to create it on remote

### Finishing a feature

**MANDATORY**: At some point, the user will ask you to finish or finalize a feature. At this point, you should:

1. Run corresponding day tests to ensure they pass. If they don't, investigate, diagnose, but DO NOT FIX. Inform the user of your findings and the changes that you think would fix the issue.
2. If tests pass, ask the user for the new version number.
3. Update version references and documentation as needed using that version number, including `STRUCTURE.md`, `README.md`, and `CHANGELOG.md`.
4. Commit and push any uncommitted changes and push any unpushed commits.
5. Create a PR using GitHub CLI. Be sure to adequately describe the changes in the PR description. The PR title should be descriptive but short. To avoid shell expansion mangling the description, always write the PR body to a markdown file in `/tmp` and pass it with `gh pr create --body-file /tmp/<name>.md` (or `gh pr edit --body-file /tmp/<name>.md`).
