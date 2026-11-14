---
id: TASK-326
title: 'Copy URL: Shift-Cmd-C copies the URL with tracking parameters removed'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14T09:35:00Z'
updated_date: '2026-11-14T20:11:00Z'
labels:
  - feature
  - links
dependencies: []
priority: medium
ordinal: 400000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Shift-Cmd-C (Edit > Copy URL) copies the page URL exactly as loaded, so links shared from Detour carry utm_*, fbclid, gclid and similar tracking parameters. The user wants the copied link to be the clean one.

Today (Nov 14 2026) the menu item calls `copyCurrentURL(_:)`, which is implemented twice: `BrowserWindowController.copyCurrentURL` → `copyURL(_:)` (toast "URL copied") and `QuickDetourWindowController.copyCurrentURL` (toast "Link copied"). The sidebar faux address bar link button (`onCopyURL`) also routes through `BrowserWindowController.copyCurrentURL`, and the dev toolbar link button through `copyURL(_:)`. Other copy paths do not: the sidebar row context menu Copy URL / Copy Link (`contextMenuCopyURL`, `QuickDetour.sidebarCopyURL`) and Quick Detour's title-bar Copy Link button. Whether those should strip too is a decision to settle and record when the task is picked up; Shift-Cmd-C is the required scope.

Only the copied string changes: the page's loaded URL, history and session records keep the original.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Shift-Cmd-C in a browser window copies the current URL with known tracking parameters removed (at least utm_*, fbclid, gclid, msclkid, mc_eid/mc_cid, igshid, _ga, yclid, dclid) and all other query parameters kept in their original order and encoding
- [x] #2 Shift-Cmd-C in a Quick Detour window behaves the same way
- [x] #3 A URL with only tracking parameters copies without a dangling ? ; a URL with no tracking parameters copies unchanged, including its fragment
- [x] #4 Parameters whose names only resemble tracking ones (e.g. a site's own `ref` or `source`) are not stripped unless the list says so explicitly, and the list lives in one place
- [x] #5 The page's loaded URL, history entries and session records are not modified
- [x] #6 The decision on the other copy entry points (sidebar context menu, faux address bar button, Quick Detour title-bar button, dev toolbar) is recorded in the task, and the shipped behavior matches it
- [x] #7 Unit tests cover the stripping rule: mixed tracking/non-tracking params, only-tracking params, no params, fragments, percent-encoded values, repeated keys, case of parameter names
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reuse the existing pure rule (Quarantine.removingTrackingParameters, TASK-194) instead of writing a second one: move the one list + isTrackingParameter + removingTrackingParameters to a neutral enum TrackingParameters (Detour/Browser/TrackingParameters.swift); Quarantine.trackingFreeURL calls it.
2. Add _ga (AC #1) to the one list; fix a dangling '?'/'&' when the query has empty pairs (utm_source=x&).
3. Strip at every clipboard writer of a page/tab URL: BrowserWindowController.copyURL (menu Shift-Cmd-C, faux address bar button, dev toolbar link button), QuickDetourWindowController.copyCurrentURL (menu + title-bar Copy Link), TabSidebarViewController.contextMenuCopyURL (with an injectable pasteboard). Not QuickDetour.sidebarCopyURL: that is the address an Opt-Cmd-click loads, not a clipboard copy.
4. Tests: move the strip tests to TrackingParametersTests + AC #7 cases; entry-point tests with private pasteboards asserting the tab's url keeps its parameters.
5. Wiki (quarantine page, new/updated section), /verify via automation endpoint, code review, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Reuse: the stripping rule already existed for Quarantine (TASK-194: Quarantine.trackingParameterNames / isTrackingParameter / removingTrackingParameters). Moved it to a neutral enum TrackingParameters (Detour/Browser/TrackingParameters.swift: names, isTracking, removing, copyableString); Quarantine.trackingFreeURL and openQuarantine call it. One list for both: adding _ga (AC #1) also makes quarantine navigations drop _ga. Fixed on the way: a query with empty pieces (utm_source=x& , gclid=1&&fbclid=2) used to leave a dangling '?' or '&'; when something is removed, empty pieces go too. A URL with nothing to remove is still returned byte for byte.

AC #6 decision — PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): every Detour command that copies 'this page's / this tab's' address strips: Edit > Copy URL / Shift-Cmd-C in browser and Quick Detour windows, the faux address bar's link button, the dev toolbar's link button, Quick Detour's title-bar Copy Link, and the sidebar tab menu's Copy URL / Copy Link (tabs, split rows, pinned entries live or dormant, pinned splits). Reason: the clean link is what Detour copies, whichever button made it. Left alone: WebKit's own Copy Link inside page content (the page's content); the sidebar menu's Share… (not a copy, not in the task); QuickDetour.sidebarCopyURL — the task text lists it as a copy path but it is the address an Opt-Cmd-click LOADS into a new Quick Detour, so stripping there would change a loaded URL (AC #5). Grepped every clipboard writer (setString/writeObjects/NSPasteboard.general): the only URL writers are the three paths above (others: dev toolbar PNG captures, Settings token copy, drag payloads). Alternative: strip only Shift-Cmd-C; flipping is one line per entry point (copyURL, QuickDetour copyCurrentURL, contextMenuCopyURL). The sidebar's Copy URL now writes through an injectable urlPasteboard like the window controllers.

Dev toolbar (review point, PROVISIONAL like the rest of AC #6): its link button strips too, so a developer testing their own site's ?utm_ handling on localhost gets the clean address from that button; they can still copy from the palette (Cmd+L shows the full address). Alternative: exempt the dev toolbar (call the unstripped write from BrowserWindowController+DevToolbar), a two-line change.

Tests (xcodebuild DetourTests, final run after the review): TrackingParametersTests 13, CopyURLTests 7, QuarantineTests 24, QuarantineWindowTests 22, QuickDetourWindowTests 16, DevToolbarHostingTests 11, OpenInQuickDetourMenuTests 13 = 106 tests, 0 failures. Full suite not run (the lead runs it).

Runtime (/verify, docs/harness/task326-copy-url-checks.py through the automation endpoint, isolated DETOUR_DATA_DIR, Debug build of this branch): loopback page at ...?id=42&utm_source=news&utm_medium=email&fbclid=abc&gclid=def&_ga=1.2.3&ref=home#comments. Edit > Copy URL (menu path), Shift-Cmd-C (key equivalent cmd+shift+c), the faux address bar's Copy Link button (clicked at its hit-tested point) and the sidebar row's context menu Copy URL each put ...?id=42&ref=home#comments on the real clipboard (pbpaste; the user's clipboard text saved and restored). list_tabs before and after, history.db (historyURL) and browser.db (tab) kept the tracked URL. Runtime run was on the build before the review's behavior-preserving refactor of removing(from:) (same results in unit tests). Not checked at runtime: Quick Detour's Shift-Cmd-C and title-bar button (covered by QuickDetourWindowTests on a loopback page), the dev toolbar button (DevToolbarHostingTests).

Code review (/code-review medium --fix): no correctness bugs; fixed: double evaluation per pair in removing(from:). Also done after it: the harness docstring now says only plain clipboard text is restored; QuarantineTests covers _ga and empty pieces in quarantine navigations. Skipped: merging the three clipboard writers into one helper (small gain across three files).

Runtime check rerun on the final build (dylib built 12:08:58, after the review's edit) with the committed docs/harness/task326-copy-url-checks.py: all 12 checks passed (menu, Shift-Cmd-C, address bar button, sidebar Copy URL clean; tab URL, history and session kept the tracked address). Defaults keys and data directory of every run removed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Copy URL now copies the clean link. The tracking-parameter rule that Quarantine already had moved to a shared pure enum, TrackingParameters (one list; _ga added; a query with stray empty pieces no longer leaves a '?' or '&'), and every Detour copy of a page's or tab's address goes through it: Shift-Cmd-C in browser and Quick Detour windows, the faux address bar, dev toolbar and Quick Detour title-bar link buttons, and the sidebar tab menu's Copy URL / Copy Link (now through an injectable pasteboard). A page's own Copy Link, Share… and the Opt-Cmd-click Quick Detour copy (a load, not a clipboard write) are untouched. The loaded URL, history and session keep the original. AC #6's scope is a PROVISIONAL decision by Claude (not confirmed by the user), recorded in the notes with its alternative. Tests: 106 across 7 suites, 0 failures; runtime check through the automation endpoint passed (menu, key equivalent, address bar button, sidebar menu; history and session unchanged). Wiki: new features/copy-url.md; quarantine and webkit-privacy-protections name the shared rule. Possible follow-up: whether Share… should share the clean link too.
<!-- SECTION:FINAL_SUMMARY:END -->
