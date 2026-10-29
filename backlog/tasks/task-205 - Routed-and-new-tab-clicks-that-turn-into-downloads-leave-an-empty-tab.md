---
id: TASK-205
title: Routed and new-tab clicks that turn into downloads leave an empty tab
status: Done
assignee:
  - '@claude'
created_date: 2026-10-26 04:22
updated_date: '2026-10-29T02:56:00Z'
labels:
  - links
  - downloads
  - bug
dependencies: []
priority: medium
ordinal: 241000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in TASK-191.4 review. A link is routed (Air Traffic Control: a route, or a Default naming a space) at the click, in decidePolicyFor navigationAction, before the response is known. When the server answers with a download (Content-Disposition: attachment, or a type WebKit can't show), the routed space gets a new empty tab and the window has switched space or another window came forward, for nothing. The same empty tab already happens for Cmd+click and target=_blank links that turn into downloads (pre-existing). Proposed: a tab whose first navigation becomes a download closes itself, and a routed open puts back the space or window order it changed. Check against the Private download rules and the downloads scope.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A routed click whose response is a download leaves no empty tab, and the window's space and window order are as before the click
- [x] #2 Cmd+click and _blank links that become downloads leave no empty tab
- [x] #3 The download itself proceeds and shows as today
- [x] #4 The close/restore rule is a pure function with tests; checked at runtime with a loopback attachment response
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Probe 2026-10-28 (DownloadOpenedTabTests, loopback attachment): a background tab (no window has claimed its web view) never starts the download at all - BrowserTab's own navigation delegate has no response policy, so WebKit drops it - and is left with its URL as title; a selected tab downloads and is left empty (nothing committed).
1. Pure DownloadOpenedTabPolicy (tests first): closesTab(normal tab, never committed a page) and restoration(of a routed open, windows now) -> steps (close the window the route created, switch the placed window back to its previous space, bring the source window to the front), only while the placed window is key and still on the routed space.
2. Shared response policy (CRX / download / allow) used by the window and by BrowserTab's own delegate; BrowserTab hands a download to DownloadManager with its space's scope.
3. One closer for both delegates: close the tab without an undo record on the next main-queue turn, then apply the restoration recorded on the tab.
4. AppDelegate.openLink records the routed open (source window, placed window, created or not, previous space) on the placed tab.
5. Integration tests with the loopback server (background, selected, routed switch), runtime check, wiki downloads + link-routing.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-28 implementation:
- Probe (loopback attachment): a background tab (no window has claimed it, the Cmd+click shape) never downloaded at all - BrowserTab's own navigation delegate had no response policy - and stayed with its URL as title; a selected tab downloaded and was left empty.
- BrowserWindowController.responseHandling(for:) (extension package / download / show) is shared by the window and BrowserTab's own delegate; BrowserTab now downloads (its space's scope, no animation), returns .download for shouldPerformDownload (review), and offers a .crx.
- DownloadOpenedTabPolicy (pure): closesTab = a normal tab with no committed page; restoration of a routed open = close the window opened for it (not a Private one: its download is listed only there and closing would cancel it, TASK-156), else switch the placed window back to its previous space, then bring the clicked window to the front - only while the placed window is still the front browser window and on the routed space. Rule chosen by state, not by entry point, so typed URLs in a new tab and extension-created tabs that download close too (Chrome's behaviour).
- DownloadOpenedTab closes the tab a main-queue turn later with no undo record, settling the selection the way a user close does (review: opener over neighbour); restored or slept tabs (standsForSavedPage) never close; a .crx tab closes too.
- AppDelegate.openLink records a RoutedOpenRecord (windows held weakly so a freed window's address is never mistaken for a new one) after placement; BrowserTab.load clears it; restoreWindows(after:) applies the steps.
Review (/code-review --fix): fixed selection order, stale routed record on a later load, <a download> in an unclaimed tab, key-window expression, lookups; I fixed the skipped three as well (CRX tab, weak window identity, woken tab without session).
Tests: DownloadOpenedTabPolicyTests 11, DownloadOpenedTabTests 7 (background, selected, opener over neighbour, page tab stays, slept tab stays, routed switch back) - red first for the policy; with 19 related suites (downloads, link routing, placement, Quick Detour, quarantine, page-opened windows, background titles): 371 passed, 0 failed; sleep/wake/archive suites 89 passed.
Runtime (Debug build, isolated DETOUR_DATA_DIR, python loopback server with a 1 KB attachment): a seeded tab selected on the attachment URL loaded, downloaded (row completed, file in ~/Downloads) and closed within 2 s, selection back on its opener (DB 2 -> 1 tab); a page script's Cmd-flagged click on a download link also downloaded with no tab left over. Cleaned up (files, data dir, defaults keys).
Not verified at runtime: a real routed click and a real target=_blank click (the routed restore is covered by the integration test through the real AppDelegate.openLink); a Quick Detour window whose first navigation is a download is unchanged (not a space tab).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A tab whose first navigation turns into a download now closes once the download has started: Cmd+click, target=_blank, routed and typed-URL tabs, never pinned, favourite, restored or slept tabs, with no undo record and the selection back on the opener. A routed link that downloads puts the windows back (switches the window back to its space, closes a window opened for it, brings the clicked window forward), except a new Private window, which holds the download. Background tabs (Cmd+click) previously never downloaded at all: their own navigation delegate now uses the window's response rule. Tests: 11 policy + 7 integration, 371 in related suites, 89 sleep/wake; checked in the running app with a loopback attachment. Not checked at runtime: real routed and _blank clicks (covered by integration tests).
<!-- SECTION:FINAL_SUMMARY:END -->
