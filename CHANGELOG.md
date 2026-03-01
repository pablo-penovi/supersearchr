# Changelog

All notable changes to this project are documented in this file.

## Unreleased

## 0.3.4

### Added
- Display version number below the search box (compact and panel views), sourced from `build.zig.zon` via a compile-time build options module.

## 0.3.3

### Added
- Added `fmt` CI job to enforce `zig fmt` formatting on all source files.

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
