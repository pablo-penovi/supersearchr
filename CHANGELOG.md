# Changelog

All notable changes to this project are documented in this file.

## Unreleased

## 0.3.14

### Added
- Display torrent sizes in the non-compact results table when Jackett provides size metadata.

### Changed
- Updated agent workflows so finalizing a feature no longer requires a version bump; unreleased changes stay in `CHANGELOG.md` until an explicit release is requested.

### Fixed
- Pinned the Coverage Pages workflow to Ubuntu 22.04 so `kcov` can be installed from apt.
- Added a cache-busting query to the README coverage badge so GitHub refreshes stale Shields failures.

## 0.3.13

### Added
- Added a `zig build coverage` step that runs all test binaries through `kcov` and merges the reports under `coverage/`.
- Added a GitHub Pages coverage workflow that publishes the merged kcov report and a Shields-compatible README badge endpoint.
- Added a main entrypoint smoke test so `main.zig` appears in kcov reports without launching the TUI.
- Added a torrent struct smoke test to include torrent metadata coverage in the standard test suite.

### Fixed
- Made Superseedr argv-capture tests copy argument entries instead of retaining a temporary slice, keeping them valid under LLVM-backed coverage builds.

## 0.3.12

### Added
- Added a tag-triggered GitHub release workflow that builds and uploads target-specific executable assets for `v*` tags.

## 0.3.11

### Fixed
- Resolve Jackett HTTP download links before sending selections to Superseedr, including magnet redirects and downloaded `.torrent` files.
- Reject unresolved HTTP URLs as final Superseedr inputs so non-magnet Jackett results fail clearly instead of being treated as local paths.

## 0.3.10

### Added
- Query configured Jackett indexers in parallel and merge sorted results instead of using the consolidated all-indexers search endpoint.
- Show loading progress while discovering and querying Jackett indexers.

### Fixed
- Decode gzip-compressed Jackett responses before parsing indexer discovery XML.
- Reject non-indexer discovery responses instead of silently treating them as zero configured indexers.

## 0.3.9

### Fixed
- Ignored unsupported results-screen key presses instead of treating terminal escape sequences, including arrow keys, as `ESC` exit.

### Changed
- Added terminal key parser tests to the standard `zig build test` step.

## 0.3.8

### Changed
- Replaced the results-screen success modal after `superseedr add` with inline row-status feedback.
- Added persistent per-search row status coloring in results: successful sends are shown in green and failed sends in red.
- Kept failure modal behavior unchanged while also marking failed rows red in the list.
- Improved selected-row readability by increasing foreground contrast for normal, success, and failed rows when highlighted.

## 0.3.7

### Added
- Added one-time startup release checking against GitHub latest releases.
- Added a search-screen version alert (`[NEW vX.Y.Z]`) when a newer release is available.
- Added a new `update_checker` module with dependency-injected executor support and tests.

## 0.3.6

### Removed
- Removed code coverage monitoring: dropped `build-coverage` step from `build.zig` and the `coverage` CI job (kcov + Codecov upload) from CI.

## 0.3.5

### Fixed
- Fixed the Codecov CI upload input to use the merged kcov Cobertura report path and disabled auto-discovery to prevent invalid coverage processing.

## 0.3.4

### Added
- Display version number below the search box (compact and panel views), sourced from `build.zig.zon` via a compile-time build options module.

## 0.3.3

### Added
- Added `zig build coverage` step using `kcov` to generate per-suite and merged HTML/Cobertura coverage reports.
- Added `fmt` CI job to enforce `zig fmt` formatting on all source files.
- Added `coverage` CI job that runs `kcov`, merges results, and uploads Cobertura XML to Codecov.

## 0.3.2

### Fixed
- Prevented an integer underflow in loading-state query truncation on compact terminals.
- Made compact results title truncation width follow the current terminal width instead of a hardcoded value.
- Preserved results-table alignment when seeder/leecher values exceed column width by clipping to fixed-width cells.
- Removed an unused dead `ResultsWidget` API (`getSelectedIndex`) to reduce misleading surface area.

## 0.3.1

### Fixed
- Restored launching Superseedr in an independent terminal process using the configured terminal command.
- Fixed child-process reaping for the launcher process to avoid zombie children while `supersearchr` remains open.
- Added terminal-launch argument handling for common platform behaviors (`wt`/`cmd start` on Windows, `Terminal` via `osascript` on macOS, and Unix terminal exec modes).
- On Linux/macOS, detached launcher processes into their own process group so closing the `supersearchr` terminal does not terminate the spawned Superseedr terminal.

## 0.3.0

### Added
- Added Windows console support in the TUI terminal layer (raw input mode, timed key waits, and console-size detection).
- Added POSIX terminal-size fallback for non-Linux Unix targets (including macOS) using `ioctl(T.IOCGWINSZ)`.

### Changed
- Made config file location OS-aware: Linux (`~/.config`), macOS (`~/Library/Application Support`), Windows (`%LOCALAPPDATA%`).
- Made debug-log default path OS-aware using temp-directory environment variables.
- Made Superseedr process checks cross-platform (`pgrep` on Unix-like targets, `tasklist` on Windows) and switched default spawn to direct `superseedr` background launch.
- Updated README platform requirements and cross-compilation/configuration guidance for Linux, macOS, and Windows.

## 0.2.3

### Added
- Added typed `JackettError` handling with exhaustive UI error-message mapping in the app state machine.
- Expanded Jackett parser test coverage for malformed/partial XML, mixed field ordering, and numeric link entities.

### Changed
- Hardened config default patching by mutating parsed JSON objects and reserializing before writing.
- Enforced `apiPort` bounds to valid TCP port range (`1..65535`) with explicit validation errors.
- Replaced terminal-size ioctl magic number with named Linux constant `std.os.linux.T.IOCGWINSZ`.

## 0.2.2

### Changed
- Kept the results list visible while showing send-status modals in the TUI.
- Improved terminal rendering utilities used by modal overlays.

## 0.2.1

### Added
- Extended debug mode to log Jackett API/connection failures (request setup, send/receive, non-OK HTTP status, and response parsing errors).
- Extended debug mode to log Superseedr invocation failures (process check, spawn, and `superseedr add` execution errors).

### Changed
- Updated README debug mode documentation with the expanded error logging scope.
- Slowed the selected-result title marquee animation by about 30% to improve readability while keeping results navigation responsive.

## 0.2.0

### Added
- Expanded support for additional link types returned by the Torznab API.

### Fixed
- Corrected Unicode character display in the results screen.

## 0.1.0

### Added
- Initial Supersearchr release as a Zig 0.15.2 TUI application.
- Torrent search integration through Jackett (Torznab API).
- Sending selected magnet or torrent links to Superseedr.
- Interactive terminal flow with search input, loading, results, and error screens.
