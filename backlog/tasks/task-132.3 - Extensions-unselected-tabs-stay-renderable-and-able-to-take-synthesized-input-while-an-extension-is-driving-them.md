---
id: TASK-132.3
title: >-
  Extensions: unselected tabs stay renderable and able to take synthesized input
  while an extension is driving them
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 23:07'
updated_date: '2026-10-04 01:37'
labels: []
dependencies: []
parent_task_id: TASK-132
priority: high
ordinal: 135000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Product decision: Claude must drive tabs that are not selected. Today a hidden tab's web view is not in a window, only one window owns a tab's web view, a sleeping tab has no web view, and WebKit drops a hidden tab's WebContent to a background assertion about 1 s after commit (see the hidden web view load stalls investigation). Screenshots (takeSnapshot) and NSEvent-based input both need a web view that lays out and paints. Design and build the mechanism that keeps a tab 'automation-attached': woken, hosted somewhere it renders at the tab's real size without being visible or stealing focus, exempt from sleep/archive, and handed back cleanly when the tab is selected, moved to another window, or released.

**Constraint (user, 2026-10-03):** "I don't want a solution that elevates priority on all background tabs. If we're elevating thread priority, we should only do that for the ones that the extension is interacting with." The user accepts WebKit's de-prioritisation of ordinary hidden tabs. So anything that keeps a hidden tab's WebContent at foreground priority, painting, or awake must be scoped per tab to a live extension attachment (for example chrome.debugger attached, or a command in flight) and dropped when that ends. A tab that is only a member of the extension's tab group, with nothing attached, is not elevated. No app-wide or profile-wide setting, and no change to how other hidden tabs load.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 An automation-attached tab that is not selected produces a snapshot of its current page at the content-area size, not a blank or stale image
- [x] #2 A sleeping tab is woken when attached, and an attached tab is not put to sleep or archived
- [x] #3 Selecting the tab, showing it in a second window, or closing it while attached leaves web view ownership consistent (no blank pane, no double-hosted web view)
- [x] #4 Attaching never changes the selected tab, the key window or the first responder
- [x] #5 Releasing the attachment returns the tab to normal hidden-tab behaviour
- [x] #6 docs/webview-ownership.md describes the attached state
- [x] #7 Only tabs with a live extension attachment are kept at elevated priority or kept rendering; every other hidden tab, including unattached members of the extension's tab group, keeps today's background de-prioritisation, verified by comparing the process assertion state of an attached and an unattached hidden tab
- [x] #8 No app-wide, profile-wide or configuration-level change raises the priority of hidden tabs in general
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Decision (user, 2026-10-03): no priority elevation. Attached tabs are parked HIDDEN; the covered/minimised-window case gets no hold either. Un-hiding the parked view is the one switch that would raise that single tab, kept in reserve in case the end-to-end run (TASK-132.20) shows stalled loads on the user's Mac; it could be limited to while that tab is loading.

Attached state: while an extension holds a live attachment on a tab (chrome.debugger attached, or a command in flight) and the tab is not on screen, its web view container is kept IN its window at the full content-area size, hidden (isHidden), in a host view at the bottom of the content area's z-order. Input and snapshots need a window, not visibility (probe: .claude/scratch/task132.3-covered-webview-spike.m). Nothing changes for any other tab, and no tab's process priority changes.

1. Model: BrowserTab gets an attachment count/owner set; TabStore's sleep and archive policy skips attached tabs; attaching wakes a sleeping tab.
2. Hosting: BrowserWindowController gets an automation host view below everything in contentContainerView. An attached tab that is not the displayed tab/pane has its webViewContainer parked there, hidden, at content-area size and resized with the content area. Selecting the tab moves the container to the normal pane and shows it; deselecting an attached tab parks it again instead of removing it. Ownership transfer between windows moves the parked container with the web view; closing or detaching removes it.
3. Focus: the window refuses makeFirstResponder for a parked web view (WebKit asks for it on every mouse press it receives, hidden or not).
4. Release: last attachment gone -> unpark -> ordinary hidden tab.
5. Tests: unit tests for the attach/park state machine and the sleep/archive exemption; an in-window test that a parked tab snapshots its current page and that selection round-trips ownership; a ProcessSuspension log comparison showing a parked hidden tab holds no foreground assertion (same as an unparked hidden tab).
6. docs/webview-ownership.md: the parked/attached state.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Probe results, macOS 26.7, 2026-10-03 (web views: A front, B covered sibling, C in no window, D isHidden):
- Window on screen: B reports visibilityState visible, timers at full rate (40 ticks of a 100 ms interval in 3 s) and requestAnimationFrame running (~297 frames in 3 s), exactly like A; its WebContent process holds RunningBoard assertion type 3 (foreground). C and D report hidden, 1 timer tick per second, rAF stalled, assertion type 0. So parking a web view in the window raises exactly that tab and no other — the per-tab scoping the user asked for.
- Same with B inside a 1x1 clipping view: still visible / foreground / full-size 800x600 snapshot, and B.visibleRect is 1x1, so its NSTrackingInVisibleRect tracking areas (options 0x241, 0x227) cannot pick up the real pointer.
- Snapshots: takeSnapshot returned the right, freshly painted content (after a DOM colour change) for all four, including the windowless and hidden ones, and also when the whole window was occluded.
- Input sent straight to the view (mouseMoved/mouseDown/mouseUp/keyDown/keyUp with a synthesized NSEvent carrying the window number, and insertText:replacementRange:) produced trusted events on B: mouseover, pointerdown, mousedown, mouseup, click, focusin, keydown, keypress, beforeinput, input, keyup, and 'héllo' inserted. The app was not active and the window not key. A saw none of it.
- A web view in NO window got pointerdown/mousedown but no mouseup/click: input needs a window.
- Focus theft: the first mouse press made WebKit call [window makeFirstResponder:B] (A lost first responder). With an NSWindow subclass that returns NO for that one view (veto fired once), A kept first responder and its focused input, and B still took every click, key and insertText.
- Window occluded or app in the background with the window behind others: every web view, the front one included, is hidden to WebKit (assertion type 1, timers 1/s, rAF stalled); snapshots and input still worked. So when Detour itself is not visible an attached tab runs at background priority like the selected tab does.

Open question for the user: should an attached tab be held at foreground priority even while Detour's window is occluded or minimised (a pending callAsyncJavaScript on that tab only does it)? Default in this plan: no extra hold.

Follow-up probe 2026-10-03 (user asked whether elevation is needed at all): a web view that is IN the window but isHidden (D) can be driven fully without counting as visible. Click on a button, click on an input, keyDown and insertText all arrived as trusted events (value 'ahéllo'), a snapshot after a DOM change was fresh, and the window veto kept first responder on the front view (it fired for D as well). D stayed visibilityState hidden, timers 1/s, rAF stalled, and its process stayed at assertion type 1/0 (background or none) while the two visible views were at type 3. So what input needs is a window, not visibility: parking the container hidden gives input and snapshots with no priority change, and un-hiding the parked container is the single switch that makes that one tab foreground. Only the no-window case loses mouseup/click.

Implemented 2026-10-03 (Opus agent, reviewed by the main session).
- New Detour/Browser/Window/AutomationParking.swift: TabAutomationOwner, TabAutomationHosting, AutomationParkingView (per-window host, bottom of the content area, ends a parked page's responder chain, own undo manager, no hit testing or key equivalents), BrowserWindow (refuses first responder for a parked view), AutomationParking (reconcile: wake + park every attached tab no window displays), AutomationInput.sendKey.
- API for the debugger tasks: tab.attachAutomation(TabAutomationOwner(extensionID:reason:)) / detachAutomation; tab.isAutomationAttached; tab.automationHosting (.notAttached / .displayed / .parked / .unhosted); tab.automationDrivableWebView(); AutomationInput.sendKey(event, to:); mouse events and insertText(_:replacementRange:) go straight to the view with events built for webView.window.
- Parking window rule: the window that just stopped displaying the tab; else the first window showing its space, else the first on its profile, else the first browser window; no window -> .unhosted, parked when a controller is created.
- Sleep/archive: sleep() refuses while attached; sleepStaleTabs and archiveStaleTabs skip attached tabs; a forced sleep (profile swap, cross-profile move, retarget) still releases the web view and the tab is re-woken and re-parked on the next main-queue turn. The attachment survives a profile change, so the debugger task must detach on ExtensionTabLifecycle.didClose.
- Addition beyond the plan: AutomationInput.sendKey. WebKit re-sends a key down the page declined through NSApp.sendEvent, so a declined letter sent to a parked page was typed into the visible page's focused field and a declined Cmd-key fired a menu item (.claude/scratch/task132.3/declined-key-spike.m). sendKey remembers the key downs it sends and a local monitor drops them when they come back.
- Reserve switch: AutomationParking.revealsParkedWebViews (false). On, the parked container is not hidden and that tab alone goes to a foreground assertion with full-rate timers and rAF.

Priority measurement (by hand, window on screen, not key): selected page visible, 38 ticks of a 100 ms timer in 4 s, 291 rAF frames, assertion type 3; parked attached page hidden, 9 ticks, rAF stalled, assertion type 1 (background), reaching type 3 only for the 5-30 ms a callAsyncJavaScript or input was in flight; plain hidden page hidden, 9 ticks, rAF stalled, type 0 from about 3 s after load. So a parked tab is never foreground, but it holds a background assertion where an ordinary hidden tab drops to none: its suspend preparation keeps retrying markLayersVolatile. That is the one difference from an ordinary hidden tab.

Verification: 455 tests in the new and affected suites, 0 failures, 1 skipped (the env-gated assertion probe), .claude/scratch/task132.3/06-regression.log; the two new classes re-run by the reviewer on the final sources: 32 tests, 0 failures, 1 skipped. App builds and launches in an isolated profile with no error-level log lines. The full suite was not run.

Not verified: where a declined key lands inside the real app (the test proves WebKit re-sent it and sendKey dropped it; that a dropped key goes nowhere rests on the spike); undo-manager isolation beyond TabStore.undoManager.canUndo being unchanged; the key-equivalent block and responder-chain sink have no direct test; attaching a Peek tab is handled in code but untested; reveal mode's foreground state is from the by-hand run only.
For TASK-132.14: WebKit queues mouse and key events separately (a key sent right after a click can arrive before the click moves focus, so wait for the click to land); a synthesized right-click pops a real context menu on screen (not handled); WebKit asks for first responder only when the page wants focus.

Retroactive /code-review and running-app check, 2026-10-03 (the pre-commit rule was added to CLAUDE.md after this task was committed).
- /code-review medium over 208bbd8..96756a5: one finding. A context menu opened on a parked page ran BrowserWebView.appendExtensionMenuItems against the window's SELECTED tab and called userGesturePerformed(in:) on it for every extension context, granting activeTab on the tab the user is looking at for a click nobody made. Fixed with a guard (a parked page gets no extension items and no gesture grant). Tests: testAContextMenuOnAParkedPageGrantsNoUserGestureInTheSelectedTab (fails without the guard: gesture granted, 'Parking test item' appended) and the mirror testAContextMenuOnTheDisplayedPageStillGrantsTheUserGestureAndAddsExtensionItems. TabAutomationAttachmentTests + AutomationParkingWindowTests: 34 tests, 0 failures, 1 skipped. The review did not read the test files line by line. The same review found nothing in the TASK-132.2 files.
- Running app, env-gated harness (.claude/task132.3-harness.patch, removed from the tree), isolated profile, local fixture pages. Attach of an unselected tab: parked, selection / key window / first responder unchanged, parked view at the content-area frame (1372x1100), page hidden with 2 timer ticks and 0 rAF frames in 3 s (same as an unattached hidden tab; the selected page 30 and ~220). What the user sees: 0 differing pixels in the content area and sidebar before attach vs while parked, and byte-identical window captures. Snapshot after a DOM change while parked: 1372x1100, new content. Input: trusted click, key and insertText on the parked page (field 'ahéllo'), the selected page saw nothing and kept first responder; one first-responder request refused; a declined key was dropped. Select the parked tab: displayed, not blank, same web view; select back: parked again. Detach: container leaves the window. Second window on the same space: nine hand-off steps including a snapshot window, ensureOwnsWebView, claim on windowDidBecomeKey and window close all left exactly one host.
- Control for the declined-key hazard, in the running app with the window key: the same kind of key sent with raw webView.keyDown to the parked page was typed into the selected page's focused field; through AutomationInput.sendKey it was dropped.
- Observed, not failures: a parked page reports document.hasFocus() true while its window is key (now in docs/webview-ownership.md); after an ownership claim the claiming window's first responder is the window, not the web view (existing behaviour, not from this task).
- Not exercised in the running app: a real synthesized right-click on a parked page, RunningBoard assertion levels, split panes, Peek, attaching a sleeping tab, forced sleep, revealsParkedWebViews, resize while parked, 2x rendering, a real extension calling attach.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A tab an extension has attached now stays awake and, when no window displays it, is parked hidden in a browser window at content-area size, so it can be snapshotted and sent trusted mouse, key and text input without changing the selected tab, the key window or first responder. No priority is raised: a parked page stays visibilityState hidden with throttled timers and no foreground assertion (it holds a background assertion where an ordinary hidden tab drops to none). Attached tabs are exempt from sleep and archive; select/deselect, split panes, ownership transfer, window close and tab close keep ownership consistent; releasing the last attachment returns the tab to ordinary hidden-tab behaviour. Declined synthesized keys are stopped from leaking into the user's window. 32 new tests; 455 tests across the affected suites pass. docs/webview-ownership.md describes the parked state.
<!-- SECTION:FINAL_SUMMARY:END -->
