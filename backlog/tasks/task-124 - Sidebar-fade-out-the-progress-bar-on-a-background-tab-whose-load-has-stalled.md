---
id: TASK-124
title: 'Sidebar: fade out the progress bar on a background tab whose load has stalled'
status: Done
assignee: []
created_date: '2026-10-01 21:07'
updated_date: '2026-10-01 22:16'
labels:
  - bug
  - sidebar
dependencies: []
priority: medium
ordinal: 124000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Background (cmd-click) tabs often show a sidebar progress bar that never completes until the tab is focused. Root cause (measured Oct 1 2026 with a standalone WKWebView spike): WebKit's ProcessThrottler drops a hidden web view's WebContent process to a Background RunningBoard assertion at commit and releases the foreground assertion 1 s later. On a CPU-saturated Mac (load average 40-50 on 10 cores) the process then gets almost no CPU, so JS-heavy pages (YouTube: main thread parked inside the 12 MB kevlar_base script, 0% CPU) freeze mid-load with estimatedProgress ~0.9 until WebKit sees the view as visible. Not page JS, rAF, hidden-page timer throttling, App Nap or network. A pending callAsyncJavaScript holds a foreground activity and makes the load finish in ~2 s, but the user is fine with background tabs being de-prioritised and chose a presentation fix: when a background tab's progress has not moved for ~2 s, fade its sidebar progress bar out; bring it back if progress resumes.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A tab whose web view is not in a window and whose estimatedProgress has not changed for the stall interval stops drawing its sidebar progress bar
- [x] #2 The bar returns when progress moves again, and a tab shown in a window never counts as stalled
- [x] #3 isLoading and estimatedProgress themselves are unchanged (reload/stop button, extension tab status, history recording unaffected)
- [x] #4 Unit tests cover stalled-hidden, resumed and hosted cases
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. BrowserTab: publish isLoadProgressStalled (load in flight, web view in no window, estimatedProgress unchanged for loadStallInterval = 2 s); any isLoading/progress change clears it and restarts the timer; a tab on screen is re-checked each interval. sidebarProgress = 0 while stalled.
2. TabStore.subscribeToTab: notify observers when the flag flips so the row refreshes.
3. TabSidebarViewController: all row configuration paths (normal, pinned, split, pinned split) draw sidebarProgress instead of estimatedProgress; TabCellView already fades the bar out at 0.
4. Tests: LoadProgressStallTests (hidden stalled, cleared when the load moves, hosted never stalled then noticed once hidden).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented Oct 1 2026 (uncommitted): BrowserTab.isLoadProgressStalled + sidebarProgress, restartLoadStallTimer driven by isLoading/estimatedProgress (cleared in releaseWebView); TabStore.subscribeToTab notifies on the flag; TabSidebarViewController's six row paths draw sidebarProgress. Tests: DetourTests/LoadProgressStallTests (3) pass along with FaviconLinkBridgeTests (5); StallingSchemeHandler gained releaseHeld(). Not yet checked in the running app (fade on a real cmd-clicked YouTube row). Spike and WebKit ProcessSuspension log evidence: memory note project_hidden_webview_load_stalls. Alternative not taken: hold a pending callAsyncJavaScript during background loads to keep foreground priority (finishes hidden YouTube in ~2 s).

/code-review --fix (Oct 1 2026): a stall was never cleared when the tab was shown unless progress moved (hung subresource, or the timer firing during an ownership transfer). BrowserTab.noteShown() now clears the flag and restarts the watch; the window attach paths and the occlusion handler already call it. Added testShowingAStalledTabClearsTheStallWithoutProgressMoving; the hosted test calls noteShown() before attaching. LoadProgressStallTests (4) + FaviconLinkBridgeTests (5) pass. Known pre-existing quirk left alone: TabCellView.hideProgressBar zeroes the bar width 0.3 s after the fade starts, so progress resuming inside that window can leave a zero-width bar until the next step.

Checked the suspected TabCellView.hideProgressBar quirk (completion zeroing the bar width after progress resumes mid-fade), Oct 1 2026: it does not occur. A diagnostic test against the unmodified cell, hosted in a window (shown and not shown), resuming progress 0, 150 and 280 ms into the fade, sampled every 60 ms: the completion fires at 0.3 s but the width stays at the resumed value in every sample (TabCellView.layout() re-derives the frame from currentProgress), and the layer's presentation opacity is 1.0 from the first sample. No change made to TabCellView.

Live check Oct 1 2026 (temporary env-gated harness, saved as .claude/task124-harness.patch; isolated DetourVerify124 profile; local server whose image request never answers): background tab at t+1 s loading, progress 0.50, bar drawn on the row; at t+4.5 s stalled=true, sidebarProgress 0, bar gone from the row snapshot; after selectTab stalled=false, bar drawn again and still there 5 s later.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Background tabs' loads stall because WebKit drops a hidden page's web process to background priority ~1 s after commit and the machine is CPU-saturated; the user accepts that de-prioritisation. BrowserTab now publishes isLoadProgressStalled (hidden web view, loading, no progress for 2 s; cleared by any progress/loading change and by noteShown) and the sidebar draws sidebarProgress, so a stalled background row fades its bar and gets it back when progress moves or the tab is shown. isLoading/estimatedProgress untouched. Verified by LoadProgressStallTests (4), FaviconLinkBridgeTests (5) and a live run with sidebar snapshots.
<!-- SECTION:FINAL_SUMMARY:END -->
