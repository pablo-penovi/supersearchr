# Changelog

All notable changes to this project are documented in this file.

## Unreleased

### Added
- Added indexer profiles: a profile is a named set of enabled indexers. `F3` on the indexers screen saves the enabled indexers as a new profile or overwrites the active one, and `F2` on the search screen opens a profiles list to load or delete them. Loading a profile enables and disables indexers on Jackett to match it. Profiles live in `profiles.json` in the app config directory.
- Loading a profile runs on a worker thread with live "Applying c/t" progress in the profiles panel, like committing on the indexers screen. `Esc` stops after the indexer in flight, and indexers that fail to toggle can be retried or kept as-is.
- The search panel now shows the active profile next to its title, marked `(modified)` when the indexers enabled on Jackett no longer match it.
- Added a **Record** column to the indexers screen with each indexer's last five search outcomes (`record.json`), and a **Last Status** column with the outcome of its most recent enable/disable (`last_status.json`).
- Pressing `F2` with no saved profiles now explains how to create one instead of doing nothing.
- The profiles screen shows a details panel beside the list (on terminals wide enough for it) previewing the selected profile: each indexer with what loading would do — `stays on`, `+ enable`, `- disable`, or `missing` when Jackett no longer has it — plus a summary row.
- Profiles can be renamed with `r` on the profiles screen. The prompt is pre-filled with the current name; renaming onto another profile's name replaces it after a confirming `Enter`.
- `F2` on the indexers screen switches straight to the profiles screen, and `F1` on the profiles screen switches back. Uncommitted indexer toggles must be committed or discarded first.

### Changed
- `main` now runs the app on its own `std.Io.Threaded` (installed through `compat.installIo`) instead of the global single-threaded `Io`, which supports neither concurrent tasks nor cancelation. The startup profile check relies on both.
- The indexers (`F1`) and profiles (`F2`) screens are now only reachable from the search screen; the results screen no longer handles either shortcut.
- The search screen's key hints now list `F1` and `F2` in both layouts, the compact indexers footer lists `F3`, and the results footer lists `/` instead of `F2`.
- User-facing text now consistently says "indexer", Jackett's own term, instead of mixing in "tracker".

### Fixed
- Fixed profile saves silently failing: a profiles file that could not be written still showed "Saved". Write failures now show an error notice.
- Fixed the "Indexers Modified" prompt leaving a ghost of itself over the profiles list after choosing to discard.
- Fixed the compact indexers and profiles screens leaving the tail of the "Loading…" notice on their title line.
- Fixed the key-hints footer wrapping onto the next line when it was wider than the terminal, which pushed the panel out of place. The hints now scroll back and forth with the same marquee used for over-long torrent titles (new `src/tui/widgets/hints.zig`), on the search, results, indexers and profiles screens, in both the panel and compact layouts.
- Fixed the results panel becoming garbled when an indexer returns a title containing control characters. Some indexers (e.g. `catorrent`) scrape a multi-line page block into `<title>`, and the raw newlines moved the terminal cursor mid-row, shifting every row below it. Torrent titles and indexer names are now normalized in `src/jackett/client.zig` — trimmed, XML entities decoded (titles previously rendered a literal `&amp;`), control characters collapsed to single spaces, and invalid UTF-8 bytes replaced — so the renderer only ever receives measurable text.
- Fixed `displayWidth` in `src/tui/theme.zig` counting combining marks, zero-width joiners and variation selectors as one column each instead of zero, and counting `Emoji_Presentation` symbols such as ✅, ⚡ and ⭐ as one column instead of two. Both cases desynchronized the title column from what the terminal actually drew.
- Fixed a potential buffer overrun in `truncateWithEllipsis` in `src/tui/theme.zig`, whose scratch-buffer bounds check compared display columns against buffer bytes; a title of multi-byte characters could write past the buffer on a wide terminal.
- Fixed the search screen's `(modified)` marker staying unknown until `F1` or `F2` had been visited. When `profiles.json` has an active profile, a background check now compares it with the indexers enabled on Jackett at launch and updates the label once it finishes, without blocking the UI. If Jackett can't be reached the marker just stays off, and quitting cancels a check that is still waiting on Jackett instead of waiting for it.
- Fixed the results screen's failed-indexers overlay (`e`) listing indexer IDs such as `thepiratebay` instead of their display names. `record.json` is still keyed by ID.
- Fixed the compact indexers footer showing the normal key hints while changes were being committed. It now shows `ESC stop after current`, then `Finishing current indexer…` after `Esc`, like the compact profiles footer.

## 0.5.0

### Added
- Added an F1 indexers management screen for viewing Jackett indexers, toggling them active/inactive, and saving changes through Jackett's admin API while caching disabled indexer configs for later re-enable.
- Added `jackettAdminPassword` as an optional config field for Jackett instances that protect the admin API with a password.

### Changed
- The indexers screen now groups enabled indexers together at the top, sorted alphabetically, with disabled indexers sorted alphabetically below. Toggling an indexer's active state live-moves it into its new alphabetical position within the corresponding group (shown in the existing pending-change color until saved); reverting restores the original saved-state ordering.

### Fixed
- Fixed the list-search overlay's error handler in `src/tui/app.zig` matching nonexistent error names (`ResponseEmpty`, `XmlParsingFailed`) instead of the real `jackett.JackettError` variants, which caused real failures (e.g. parse errors, HTTP errors) to surface as a generic "Unexpected error in search overlay" message. It now reuses the existing exhaustive `getErrorMessage` mapping.
- Fixed an unbounded buffer write in `padTitle` in `src/tui/widgets/results.zig` that could overflow its destination buffer when padding a selected, search-highlighted row with a wide marquee-truncated title.
- Fixed the indexers management screen leaving the terminal's text cursor visible instead of hidden, unlike the search and results screens.

### Removed
- Removed unused dead code from the project:
  - Eliminated unused `drawBorder`, `centerText`, and `writeHeaderRightAligned` functions in `src/tui/widgets/results.zig`.
  - Eliminated unused `addLink` and `addLinkWithExecutor` functions in `src/superseedr/client.zig`.
  - Eliminated unused `consumeEscapeSequence`, `consumeEscapeSequenceWindows`, `setColor`, `reverseVideo`, and `reverseVideoOff` functions in `src/tui/term.zig`.
  - Eliminated the unreachable `extractEnclosureUrl` function and its dead branch in `src/jackett/client.zig` (always shadowed by `extractEnclosureInfo`, which is checked first and matches the same tags).
  - Eliminated `Client.searchIndexersInParallel`, `ParallelSearchContext`, `parallelSearchWorker`, and `searchSingleIndexer` in `src/jackett/client.zig` — this whole non-streaming search path was superseded by `startStreamingSearch`/`SearchSession` and had no callers left in the app.
  - Eliminated the dead `buildHeaderCells` function in `src/tui/widgets/results.zig`, which was only exercised by its own tests and no longer matched the real header-rendering path (`writeHeaderCells`). Replaced its tests with direct coverage of `formatColumnHeader` (the function actually used in production) and of `buildDataCells`'s column offsets.
  - Removed the unused `torrents_len` parameter from `computeDisplayCount` in `src/tui/widgets/results.zig`.

## 0.4.4

### Added
- Made the results **Age** column sortable, supporting sorting direction toggles (ascending / descending) navigatable via Left/Right Arrow keys and triggered by pressing `TAB`.
- Added a new shortcut, `r` or `R`, on the torrent results screen to refresh results by triggering a new search with the same query. This action and its shortcut hint are only enabled when a search is not already in progress, and the refresh request bypasses the Jackett internal cache (`&cache=false`) to ensure fresh tracker results.
- Added an "Age" column to the torrent results screen between "Title" and "S" that displays how long ago the torrent was published (formatted dynamically in truncated integer units: seconds, minutes, hours, days, months, or years).
- Implemented robust RSS RFC 822 and ISO 8601 `<pubDate>` tag extraction in `src/jackett/client.zig`.

### Changed
- Preserved and maintained the active sorting configuration (criteria and order) when refreshing torrent search results.

## 0.4.3

### Fixed
- Fixed sending torrents to Superseedr when Zig's process-spawn IO allocator was not initialized, and added fallback/debug logging around Superseedr launch attempts.

## 0.4.2

### Fixed
- Set app-managed cursor style to steady block for all cursor-visible contexts during the TUI session, restoring terminal default blinking style on exit.
- Fixed in-results `/` search overlay cursor instability during live background status updates by redrawing the modal cursor position and visibility after status-only renders.

## 0.4.1

### Added
- Added dynamic search results sorting. Users can now navigate a sort-column cursor over **S** (Seeders), **L** (Leechers), and **Size** headers using `←`/`→` arrow keys, and press `TAB` to apply sorting and toggle sorting direction between ascending (`↑`) and descending (`↓`).
- Statically-aligned headers to prevent visual character shifting when cursor or sorting arrow indicators are toggled.

### Fixed
- Fixed release artifact size issue where the Linux executable was not being stripped (resulting in a 9.18 MB binary). The root cause was `exe_tests` sharing the main executable's `root_module`, which allowed the coverage setup loop to mutate the `strip` property of both to `false` on every build graph construction. Now, `exe_tests` uses an isolated root module to prevent cross-mutation.

## 0.4.0

### Added
- Pre-populate the search query input with the last searched term when starting a new search from the results screen.
- Support clearing the search query input by pressing `Shift+Backspace` or `Ctrl+Backspace`.
- Document the clear shortcut in the search panel UI help texts as `Ctrl-BS`.
- Show a confirmation modal in the center of the screen when exiting the app with `ESC` from any screen, requiring a second `ESC` press to exit or any other key to cancel.

### Changed
- Migrated the project tooling and documentation to Zig 0.16.0.
- Show the results screen immediately after submitting a search and stream Jackett indexer batches into the sorted result list as they finish.
- Moved live indexer discovery/search progress into the results status row, with per-indexer failures reported inline.

### Fixed
- Resolved a segmentation fault in ResultsWidget.updateTorrents caused by a use-after-free when the streaming results array list reallocates.
- Completed the Zig 0.16.0 migration, resolving all filesystem, network sockets, allocator, and timer test suite and build failures.
- Updated the Coverage Pages workflow to use Node.js 24-compatible GitHub Pages actions.

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
