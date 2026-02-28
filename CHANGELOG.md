# Changelog

All notable changes to this project are documented in this file.

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
