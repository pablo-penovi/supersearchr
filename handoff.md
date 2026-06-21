# Handoff: Indexers Management Screen (F1)

Branch: `feature/handling-indexers` (pushed, commit `09ed364`).
Status: **builds cleanly, but `zig build test` hangs/segfaults partway through `test-app`.** Not yet root-caused. Feature code itself is believed complete per the plan; the blocker is in test infrastructure/isolation, detailed below.

## What this branch implements

A new in-TUI screen (opened with `F1` from either the Search or Results screen) to view and toggle Jackett indexers on/off, since Jackett itself has no enable/disable flag — only "configured" (has credentials) vs. fully deleted. The plan this was built from is at `/home/pablo/.claude/plans/i-d-like-to-implement-shimmying-floyd-agent-a7df29fcbac82a9f3.md` (still on disk, has the full design rationale, Jackett API research, and an 11-step sequencing plan). All 11 steps were implemented in order; this handoff picks up at the very end of step 9 (app.zig wiring), mid-way through getting its new tests green.

### New files
- `src/jackett/http_exec.zig` — shared low-level HTTP request/response executor (method/headers/body in, status/body/headers out, doesn't throw on non-OK). `client.zig`'s `defaultBodyExecutor` is now a thin wrapper over this.
- `src/jackett/url_encode.zig` — `percentEncode`, promoted out of `client.zig` so `admin_client.zig` can reuse it too.
- `src/jackett/admin_client.zig` — Jackett admin REST API client: `login` (session cookie, password or passwordless), `listAllIndexers`, `getIndexerConfig`/`setIndexerConfig`/`deleteIndexer`, plus a local disk cache (`cacheIndexerConfig`/`readCachedIndexerConfig`/`clearCachedIndexerConfig`) so disabling (DELETE) then re-enabling (POST) round-trips the indexer's config instead of losing it. 11 tests, all passing in isolation (`zig build test` → `test-jackett-admin` target).
- `src/tui/widgets/list_nav.zig` — cursor/scroll/redraw-mode logic extracted out of `results.zig` (byte-for-byte behavior preserved, verified by `results.zig`'s existing 40/41 tests staying green through the refactor). 23 tests, all passing.
- `src/tui/widgets/indexers.zig` — the new table widget, mirrors `results.zig`'s panel styling (2 columns: Indexer name, Active ✓/✗). 12 tests, all passing.

### Modified files
- `src/tui/term.zig` — added `Key.f1`, recognizes both `\x1bOP` (SS3) and `\x1b[11~` (CSI) encodings.
- `src/tui/widgets/results.zig` — dropped j/k/J/K (arrow keys + shift+arrow only now, to match the new screen), refactored to delegate cursor/scroll/redraw-mode to `list_nav.zig`. 41 tests passing.
- `src/tui/panels.zig` — generalized `drawFailedIndexersModal` into `drawNamedListModal`, added `renderIndexerSaveFailuresOverlay` (returns `.retry`/`.revert` based on Enter/Esc) for the new screen's partial-save-failure UX.
- `src/config.zig` — new optional `jackettAdminPassword` field (defaults to `""`, patched into existing configs on load).
- `src/tui/app.zig` — new `IndexersState` + `State.indexers` variant, `F1` dispatch from `runSearchState`/`runResultsState`, `runIndexersState` (login → list → interactive loop → save/revert/exit), `saveIndexerChanges`/`enableIndexer`/`disableIndexer` (the disable = cache+delete, enable = read-cache-or-fetch+set lifecycle), `getAdminErrorMessage`, `deinitIndexersState`. **This is where the hang was discovered, mid-way through adding tests.**
- `build.zig` — module wiring for all of the above (`http_exec_mod`, `url_encode_mod`, `admin_client_mod`, `list_nav_mod`, `indexers_widget_mod`), plus their test targets and the `app_tests`-duplicate-module pattern (mirrors the existing `jackett_mod`/`app_tests_jackett_mod` duplication already in the codebase).

## The open problem

Running `zig build test --summary all` either takes far longer than expected or hangs outright (multiple runs needed `timeout` + manual `pkill -9` to recover). Running the `test-app` binary directly (bypassing the build-system wrapper) shows exactly where:

```
1/20 ... through ... 18/20 app.test.deinitIndexersState frees pending_results when returning to results...OK
Segmentation fault at address 0x7f...
/usr/lib/zig/std/atomic.zig:81:39: in fetchOr
/usr/lib/zig/std/Io/Threaded.zig:614:66: in waitForCancelWithSignaling
/usr/lib/zig/std/Io/Threaded.zig:2335:41: in groupAwait
/usr/lib/zig/std/Io.zig:1284:33: in await
/usr/lib/zig/std/Io/net/HostName.zig:358:28: in connectMany
/usr/lib/zig/std/Io.zig:2337:13: in start
/usr/lib/zig/std/Io/Threaded.zig:741:20 / 1797:29: in start / worker
/usr/lib/zig/std/Thread.zig: in callFn / entryFn
```

Test 19/20 is `"runIndexersState login failure surfaces as ErrorState and cleans up pending search query"` (the new test added in this session). The crash is a **real DNS/TCP connection attempt** (`HostName.connect` → `connectMany`) happening inside a background worker thread of `std.Io.Threaded` — i.e. something is using the *real* `defaultBodyExecutor`/`defaultAdminExecutor` against an unreachable host, even though every test in this file is supposed to inject a mock executor.

This reproduced **deterministically**, at the same point, across multiple runs.

### What's been ruled out / found

1. **`compat.io()` returns `std.testing.io`** (see `src/compat.zig:5`) — a single `Io` instance (and its underlying `Io.Threaded` worker pool) **shared across every test in the same test binary process**, not per-test. This means a dangling/leftover async task or thread from an *earlier* test can plausibly surface during a *later, unrelated* test. This is the most likely mechanism, but the exact origin test hasn't been confirmed yet.

2. **My new test itself (`runIndexersState login failure...`) does not appear to make any real network call.** It only invokes `jackett_admin.login(...)` with a mocked `jackett_admin_executor`; tracing through `login`'s code path shows no use of `http_exec`/`std.http.Client` when the executor is mocked. So the crash is very likely *not* a logic bug in the new admin-client code itself, but a side effect of something else's leftover state.

3. **Renaming a test to `DISABLED_...` does NOT skip it** — Zig's test runner has no name-based skip mechanism; it still executes (confirmed empirically: renamed tests 1 & 2 still ran and the crash still occurred at the identical point). **This isolation attempt was invalid** — it needs to be redone by actually commenting out (or `return error.SkipZigTest`-ing, if that's supported by this custom test runner — check `/usr/lib/zig/compiler/test_runner.zig` first since this project's runner rejects unknown CLI args like `--test-filter`/`--help`) the test bodies of tests 1 and 2, not just renaming them, before concluding whether they're the source.

4. **`SearchSession.abandon()` (src/jackett/client.zig:860) detaches its coordinator thread instead of joining it** when `deinitResultsState` is called on a session that isn't done yet. This is a plausible mechanism for a thread to outlive its test, but I haven't confirmed any existing test actually takes this code path (test 1 drains to completion via `drainUntilDone`; test 2's discovery-failure path sets `done.store(true)` essentially synchronously with the fatal-error flag, so by the time `waitForStreamingError` observes the error, `isDone()` should already be true too — meaning `deinitResultsState` should take the `session.deinit()`/join path, not `abandon()`/detach, in both existing tests). This needs verifying empirically, not just by re-reading the code, since the timing could still race.

5. **Strong unconfirmed lead, not yet checked**: test `"addLinkWithAppDeps uses injected superseedr dependencies"` (existing, pre-existing test, around line ~868 before this session's edits) constructs its `App.deps` overriding only `superseedr_executor`/`superseedr_process_checker`/`superseedr_spawner` — it does **not** override `jackett_link_fetcher`, which defaults to the real `jackett.defaultLinkFetchExecutor`. The test calls `addLinkWithAppDeps(&app, "magnet:?xt=urn:btih:abc")`, which internally calls `jackett.resolveDownloadLink(app.allocator, link, app.deps.jackett_link_fetcher)`. **This was not checked**: does `resolveDownloadLink` short-circuit for `magnet:` links without ever invoking the executor (likely, since magnet links don't need HTTP resolution), or does it call through to the real executor regardless? If the latter, this pre-existing test would attempt a real connection to nothing every time it runs, which is a very strong candidate for exactly this kind of leftover-background-thread crash, **and it would be a pre-existing bug unrelated to anything added in this session** — just newly exposed by the timing/total-test-count change from adding 5 new tests to `app.zig`.

### Suggested next steps, in order

1. Check lead #5 first — read `jackett.resolveDownloadLink`'s implementation in `src/jackett/client.zig` and confirm whether it calls the executor for `magnet:` links. If it does, that's very likely the whole bug, and it's pre-existing (not introduced this session) — just decide whether to fix it there (e.g. have the test mock `jackett_link_fetcher` too) or harden `resolveDownloadLink` itself.
2. If #5 doesn't pan out, properly exclude tests 1, 2, 10, and 11 one at a time (comment out the body, not just rename) and rebuild+run after each, to bisect which specific pre-existing test leaves the dangling thread/task.
3. Once the source test is found, decide the fix: either properly join/await before returning from that test (preferred, keeps `abandon()`'s detach semantics intact for production use where it's arguably fine), or reconsider whether `abandon()` should join with a timeout instead of detaching outright.
4. After the hang is fixed, finish the originally-planned remaining work for step 9 of the plan (the test additions for `app.zig` were mid-way through — `getAdminErrorMessage`, `deinitIndexersState` x2, and `saveIndexerChanges` tests are written and pass; only `runIndexersState login failure` was newly added and triggered this investigation. Re-verify it actually passes once the hang is fixed), then proceed to step 10 (final `panels.zig` review — already done) and step 11 (manual end-to-end verification against a real or locally-mocked Jackett instance, plus a final full `zig build test` run).

### How to reproduce

```bash
cd /home/pablo/proyectos/supersearchr
zig build test --summary all   # hangs or times out; Ctrl-C and pkill -9 -f "test-app|zig build" if needed
# Better: build once, then run the binary directly for verbose per-test progress:
zig build 2>&1 | tail -5   # (or just let test compilation finish, then Ctrl-C the run step)
find .zig-cache/o -iname test-app -printf '%T@ %p\n' | sort -rn | head -1   # find the freshly built binary
timeout 30 <that path>   # runs with numbered per-test output, crashes after test 18/20
```

Current test counts when last green (before the hang was introduced by the `runIndexersState` test): 213/213 passing across all 16 test targets. With the 5 new `app.zig` tests added (`getAdminErrorMessage`, `deinitIndexersState` x2, `saveIndexerChanges`, `runIndexersState login failure`), `test-app` should have 20 tests; it currently gets through 18 before crashing.
