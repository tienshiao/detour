---
id: TASK-228.3
title: >-
  Automation: capture tooling on the MCP endpoint, so a release's website media
  is one script instead of a harness rebuild
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14T01:49:00Z'
updated_date: '2026-11-14T17:48:00Z'
labels:
  - tooling
  - automation
  - website
dependencies:
  - TASK-228.1
references:
  - TASK-228.1
  - docs/task-110/README.md
  - TASK-293.6
  - TASK-110
parent_task_id: TASK-228
priority: low
type: feature
ordinal: 395000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested 2026-11-14. Website captures (loops and stills for detourbrowser.com) use the kit in docs/task-110. Its DemoStage harness is pasted into a throwaway worktree, wired into AppDelegate with a patch that has to be adapted to each release, and rebuilt. It is then driven through a command file it polls. Every capture session re-does that work and adds harness commands for new UI: for TASK-293.6 that meant the space editor (TASK-289) and the Arc import offer (TASK-293.5). The endpoint from TASK-228.1 already drives input, menus and appearance, and its client CLI can script a sequence. What capturing still needs is staging: a demo world, exact window placement, and specific UI on demand.

Stays outside Detour: the 2x virtual display (vdisplay.m), screencapture for video and for stills with the native window shadow (an in-app snapshot has no shadow), the wallpaper swap, and encode.sh. The capture scripts themselves live with the kit or the website, not in the app.

Same gate as TASK-228.1: these tools exist only in the isolated DETOUR_DATA_DIR test-run mode, and the UI-on-demand tools are Debug-only like 228.1's Debug overrides.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A client can seed a demo world from a fixture file (profiles, spaces with name/emoji/colour/profile, pinned tabs and nested folders, splits, favorites, normal tabs, history visits, link routes) into an empty isolated data directory, and the result matches the fixture after a relaunch
- [x] #2 A client can set a window's size and position in points, move it to a given display (including a virtual display), and read back its on-screen frame and CGWindowID for screencapture
- [x] #3 A client can type text into the focused field at a given per-character pace, so recorded typing reads naturally
- [x] #4 Debug builds can open specific UI on demand for staging: the space editor with a draft (name, colour, emoji, profile), the Arc import offer and window fed from a fixture Arc folder (never the real one), and a given Settings pane and row
- [x] #5 A fixture-driven capture script for the next release's media replaces DemoStage in docs/task-110 (README updated, the harness and AppDelegate hook patch retired), demonstrated by re-taking at least one existing loop and one still with no app patching
- [x] #6 Tests cover the seeding (round trip through a relaunch, a malformed fixture refused with a clear error, refusal outside the isolated test-run mode) and the window placement tool's errors (unknown window or display)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 14 2026 (agent, Opus).

Built:
- seed_world {fixture_path} (test runs only; gate_closed otherwise): JSON fixture v1 (profiles + favorites; spaces with name/emoji/color/profile, pinned pages, nested folders with collapsed, pinned splits, tabs, tab splits, selected tab; history visits with ages; Link Routes; active_space). Parsed and checked completely first by AutomationWorldFixture (invalid_fixture with error.details.path, unknown fields refused), then carried out by TabStore.applyArcImport (plan structs gained faviconURL and folder isCollapsed): first fixture profile = the data dir's default profile renamed, Home space deleted after, undo cleared, saveNow, history via HistoryDatabase.importVisits. "Empty" = 1 profile, 1 space, nothing pinned, no favorites, no tab with a page (blank New Tab allowed), no routes or changed Default, no history visits; else not_empty with the list. Titles/icons from the file: no page loads needed.
- list_displays (display_id, frame/visible_frame in global top-left points, scale, main, name, pixel size); set_window_frame (test runs only) {window_id | window_number, x, y, width, height, display_id?, activate?} returns frame, screen_bounds (CGWindowList), settled, is_key, app_active, window_number; waits up to 2 s for the window server's bounds to match. unknown_window, new unknown_display. list_windows gained screen_bounds and display_id.
- open_ui (Debug builds + test runs): space_editor (draft name/emoji/color/profile_id, new or space_id), arc_offer / arc_import (arc_folder only inside the data dir or a temp folder, realpath-compared, never Arc's own; points ArcSidebarReader.dataDirectoryOverride at it), settings (pane, row). Absent from Release (Release test run's tool list checked).
- Arc guard in the app: a test run (AutomationGate.isTestRunRequested) skips the launch Arc offer and points ArcSidebarReader.dataDirectoryOverride (Mutex) at <data dir>/Arc.
- type_text already typed into a window's focused native field at interval_ms; verified with the space editor's name field (test). Nothing was missing.
- set_debug_override automation_indicator (Debug only): hides the connected-agent capsule for captures (design decision for the lead: Release cannot hide it).
- Kit moved to docs/capture (task-110 README is a pointer); DemoStage.swift.txt and appdelegate-hook.patch git rm'd. capture.py (stdlib, scripts/detour-mcp Session): vdisplay, launch, seed demo-world.json, indicator off, wallpaper via demo.sh (now a wallpaper.swift helper, state in ~/Library/Caches/detour-capture), place, shots spaces (loop), split, space-editor (stills), encode.sh (output to $CAPTURE_OUT), full cleanup in finally. --offline rewrites pages to a local server (icons from the website's favicons dir).

Tests: AutomationStagingTests 19 (seed round trip through a relaunch, malformed fixture refused with nothing applied, field errors, gate, not_empty, sort orders, test-run request, Arc override, displays, placement + errors incl. gate, open_ui Debug-only, space editor + paced typing, Arc offer + refusals, Settings pane/row, open_ui errors and gate); AutomationCaptureTests + indicator test; MCPServerTests codes. Affected suites (Staging, Capture, Tools, Input, MCPServer, Controller, HTTP, Endpoint, ArcImportTabStore, ArcImportPlanner, ArcSidebarReader): 151/0 before the last gate change; Staging+MCPServer+Capture+Tools 62/0 after. Full suite (once, at the end): 4211 tests, 19 skipped, 3 failures counted (1 unexpected) in 2 tests, ExtensionOriginTrackingPreventionTests.testTrackingPreventionPassSparesOriginsWithALoggedInteraction (30 s ITP timeout) and ExtensionPolyfillIntegrationTests.testFrameKindsAsReportedByNativeGetAllFrames; both pass run alone (full-run-only, unrelated to this change).

Runtime (isolated DetourCapture-* runs, cleaned up each time): seed of demo-world.json, not_empty on a second seed, relaunch keeps the world; set_window_frame and unknown_display; open_ui space_editor + type_text (6 chars at 120 ms = 0.9 s), settings, arc_offer from make_fake_arc.py output, refusal of ~/Library/Application Support/Arc. Release build: tool list has no open_ui / set_debug_override.

AC #5 demonstration (offline mode, local pages, so rows show dev-mode marks), outputs in the scratch dir capture/demo:
- spaces.mp4 1400x1760, 10.9 s, 760 KB (+ poster 110 KB): Work → Personal → Reading → Side and back, window active throughout. From the diagnostic run active3 (same flow, no favicons dir, script before the focus checks; its first Personal visit shows a blank split, since fixed by visiting each space first, not re-run).
- split.webp 2784x1584, 270 KB, and spaces-editor.webp 1400x1760, 117 KB ("Recipes" typed at 110 ms, 🍳, Sage, Personal): from run2. Sizes match the site's files exactly.
- The final script has not completed a spaces loop: run3 and run4 exited 1 because Detour lost the front mid-take (to Google Chrome, then Mimestream); HID idle time was 22 s, so someone was using the Mac. Screen-affecting runs were stopped. The script now fails fast naming the app in front instead of retrying.
Focus: captures take the keyboard focus by design (set_window_frame activate=true, needed for coloured traffic lights; screencapture alone does not); open_ui settings/arc_import windows activate too. All test-run only. Avoidable only by recording an inactive window.
Every run: wallpaper restored (backup gone), vdisplay gone, data dirs/WebKit stores/defaults keys removed.

Not done: folder toggling, Quick Detour placement, private windows, CRX installs from DemoStage are not ported (README lists them); a clean full-script capture on an idle Mac; real-site capture (rules: local pages only).

Commits: 379ee11 (app + tests), b767ea6 (capture kit), 13f8688 (wiki).

Correction: AutomationStagingTests has 17 tests (not 19), all passing in the full run.

2026-11-14, /code-review high --fix on 8849b12..c8830e6: 10 findings, 9 fixed in 545ea8d. Two were real holes:
- An arc_folder could reach the user's Arc data through a link inside it. It now refuses any symlink or extra hard link inside the folder, and anything under Arc's own folder.
- A DETOUR_DATA_DIR with '..' counted as isolated. The name must now resolve inside Application Support.
The other fixes:
- The automation_indicator override is test-run only.
- The fixture is read as a regular file with a bounded read.
- demo.sh keeps the wallpaper snapshot if restoring fails.
- capture.py restores after a failed wallpaper set and tolerates Release builds.
- The Arc override is set only after the sheet is presented.
- The space editor's original profile comes from the stored space.
- One ASCII colour check; pinned split panes refuse 'selected'.
Skipped:
- A child window of a Private window, reached by window_number: parent is not checked, only sheetParent. Low severity.
- DETOUR_DATA_DIR=Arc counts as isolated (no Arc data is read).
- A link swapped in after the check (a test-run-only TOCTOU).
The lead's runs after the fixes:
- Staging, HTTP, Capture, MCPServer, Tools and Controller: 91 tests, 3 failures, all in testAWindowIsPlacedOnADisplayAndReadBack. The window server's bounds were still at AppKit's open animation (686×471 for 700×480), so settled was false.
- The test's window now has animationBehavior .none. The staging suite then passed twice, 17/0 each.
AC #5 stays open: the final capture.py has not completed a spaces loop. Two takes were stopped when another app came to the front while the Mac was in use. One run of capture.py on an idle Mac (it takes focus for about a minute and swaps the wallpaper, then restores it) closes it.

Nov 14 2026, AC #5 shown on an idle unlocked Mac: docs/capture/capture.py with a fresh Debug build (online, default shots) exited 0. It re-took the spaces loop (spaces.mp4 + poster) and the split and space-editor stills, with no app patching: seed_world, a 2x virtual display, set_window_frame, open_ui. Cleanup restored the wallpaper, removed the virtual display, stopped Detour and removed its data directory. Stills checked by eye. The split still shows Wikipedia's live donation banner; use --offline for website takes.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Capture staging tools on the automation endpoint: seed_world (a fixture world through TabStore.applyArcImport into an isolated data directory), list_displays, set_window_frame (points, display, CGWindowID read back) and the Debug/test-run open_ui (space editor draft, Arc import offer from a fixture Arc folder behind a mutex-guarded override, Settings pane/row). docs/capture/ (capture.py, demo-world.json, vdisplay, wallpaper and encode helpers) replaces the docs/task-110 DemoStage harness and AppDelegate patch. Verified by AutomationStagingTests and by a clean capture.py run on Nov 14 2026, which re-took the spaces loop and the split and space-editor stills with no app patching and restored the wallpaper and display afterwards.
<!-- SECTION:FINAL_SUMMARY:END -->
