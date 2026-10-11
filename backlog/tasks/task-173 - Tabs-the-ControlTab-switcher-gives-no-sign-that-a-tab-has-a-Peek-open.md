---
id: TASK-173
title: 'Tabs: the Control+Tab switcher gives no sign that a tab has a Peek open'
status: Done
assignee:
  - '@claude'
created_date: '2026-10-11 07:21'
updated_date: '2026-10-11 08:17'
labels:
  - tabs
  - switcher
  - peek
dependencies: []
references:
  - Detour/Browser/Window/RecentTabSwitcher.swift
  - Detour/Browser/Window/BrowserWindowController+RecentTabSwitcher.swift
  - wiki/tabs/tab-switching.md
  - wiki/tabs/peek.md
priority: low
ordinal: 196000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A tab whose Peek is open returns to the Peek when it is selected, but its card in the Control+Tab switcher shows only the host page behind it (the snapshot is of the host's web view; the Peek is a sibling view). A user who expects to land on the Peek, or on the host, cannot tell which from the overlay.

Expected: the card of a tab that will come back with a Peek shows it — the host's picture dimmed, with the Peek's page in a panel over it, as on screen. Without a picture of the Peek (parked, restored from the session, capture failed) the panel shows the Peek's favicon.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The card of a tab whose Peek will be presented on return (live, hidden or parked) shows a panel over a dimmed preview; a tab without a Peek is unchanged
- [x] #2 The panel shows the Peek's page as it was when the tab was left, and for the current tab as it is when the switcher opens
- [x] #3 With no picture of the Peek, the panel shows the Peek's favicon instead of staying blank
- [x] #4 A split's card shows the Peek of the pane that gets focus when the card is chosen
- [x] #5 Closing or expanding the Peek removes the panel from the card
- [x] #6 Tests cover which entries carry a Peek and the capture when the tab is left
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Tests first: BrowserTab.hasPeek (PeekStateTests); RecentTabSwitcherPeekTests in a real window — which entries carry a Peek (left, current, closed, parked, focused pane of a split) and that the Peek is pictured on leave and when the switcher opens (switcherPreviewRequest).
2. BrowserTab.hasPeek = the condition restorePeekOverlayIfNeeded acts on. RecentTabSwitcher.Entry.peekHost = the focus tab when it has a Peek.
3. Capture: stampDeselected pictures the tab's Peek too, so selectTab stamps before hidePeekUI (the Peek's web view must still be in the window); captureVisibleSwitcherPreviews does the same for the presented Peek. The picture lives on the Peek's own BrowserTab.
4. RecentTabCardView: dim layer + rounded panel with the Peek's picture over the preview, the Peek's favicon when there is no picture.
5. Runtime check with screenshots of the overlay; wiki pages tabs/tab-switching.md and tabs/peek.md.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented 2026-10-11 on branch task-173-174-switcher-peek-sidebar-focus (from main). BrowserTab.hasPeek; RecentTabSwitcher.Entry.peekHost (the focus tab when it has a Peek); stampDeselected and captureVisibleSwitcherPreviews picture the Peek onto its own BrowserTab, and selectTab now stamps before hidePeekUI so the Peek's web view is still in the window; RecentTabCardView draws a dim layer and a rounded panel (10% / 7% insets) with the Peek's picture, or its favicon when there is none.

TDD: tests written against API stubs first (hasPeek = false, peekHost never set, no capture): PeekStateTests + RecentTabSwitcherPeekTests = 18 run, 9 failed. After the implementation 18 run, 0 failed. Final code: affected suites (RecentTabSwitcherPeekTests 7, PeekStateTests 11, RecentTabSwitcherMonitorTests 10, RecentTabOrderTests 10, with the TASK-174 suites) 76 run, 0 failed. Full DetourTests on the final code: 2,139 run, 11 skipped, 1 failure — ExtensionPolyfillIntegrationTests.testStorageManagedInRealExtensionContextSurvivesGarbageCollection ('no collection observed in 10 rounds'), which passes run alone; an earlier full run before the review fixes had instead the known tracking-prevention timeout recorded in TASK-169. Neither is in code this change touches.

Runtime (harness docs/harness/task173-174-harness.patch, isolated profile DetourVerify173a, screencapture of the window with the overlay up): (1) a tab left with a Peek — its card shows the page dimmed and the Peek's page in a panel; (2) the same with the Peek's picture removed — a white panel with a globe; (3) the current tab with its Peek presented — its card shows the panel, the other card does not; (4) after closing the Peek — no panel. The log shows the Peek pictured once on leave (requests=1, picture present 1.5 s later). NOT exercised at runtime: a split, a parked Peek (host asleep), a pinned tab or favourite as host, dark mode, the smallest card width.

Code review (/code-review --fix): no correctness finding in this task's code; one cleanup applied (the Peek's fallback icon is built only for a card that has a Peek).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The Control+Tab switcher now shows the Peek a tab comes back with: the card's preview is dimmed and the Peek's page is drawn in a panel over it (its favicon when there is no picture yet), for the pane that gets focus when the card is chosen. The Peek is pictured with its host when the tab is left and when the switcher opens. Covered by RecentTabSwitcherPeekTests and PeekStateTests; the four card states were captured in the running app. Not run: split, parked Peek, pinned/favourite host, dark mode.
<!-- SECTION:FINAL_SUMMARY:END -->
