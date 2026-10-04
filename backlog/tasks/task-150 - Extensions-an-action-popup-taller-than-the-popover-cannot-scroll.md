---
id: TASK-150
title: 'Extensions: an action popup taller than the popover cannot scroll'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-04 02:35'
updated_date: '2026-10-04 03:20'
labels:
  - bug
  - extensions
dependencies: []
priority: medium
ordinal: 173000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-10-03 while exercising the API Explorer popup in the running app for TASK-132.4. ExtensionPopoverController measures the popup's content and clamps the popover to 100...800 x 100...600. WebKit builds an action's popup web view in a size-to-content mode (private _sizeToContentAutoSizeMaximumSize, 800 x 600) in which the page never scrolls, because the host is expected to give the view the content's size. With 3456 pt of content in the 600 pt popover: window.scrollTo is a no-op, a wheel does nothing, and everything below the fold cannot be reached or clicked. Giving the view the full content height does not help: WebKit keeps a 600 pt viewport and hit-tests nothing below it. Chrome's popup scrolls at its own 800 x 600 limit.

A fix was started on the epic-claude-extension branch (uncommitted at the time of filing): once the measured content overflows, switch the size-to-content mode off (set the maximum size to zero through the private setter, guarded by responds(to:)) so the view keeps the popover's size and the page scrolls inside it; leave the mode on for a popup that fits, since WebKit's shrink-to-fit layout gives a popup without an explicit width its width. It is to be committed on that branch as its own commit so it can be cherry-picked to main.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A popup whose content is taller than 600 pt scrolls inside the popover with the wheel and with window.scrollTo, and controls below the fold can be clicked — verified in the running app
- [x] #2 A popup that fits keeps its measured size and does not gain a scroll bar; a popup without an explicit width keeps the width WebKit's shrink-to-fit gives it
- [x] #3 A popup that grows past 600 pt after opening becomes scrollable; one that shrinks back is sized to its content again
- [x] #4 On a WebKit without the private setter the popup behaves as before and a log line says why
- [ ] #5 Tests cover the size/overflow decision; 1Password's popup is checked for no regression (size, no stray scroll bar)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-03. Fixed on branch epic-claude-extension as its own commit b206956 (ExtensionPopoverController.swift, DetourTests/ExtensionPopoverSizingTests.swift, the Popup Presentation section of docs/extensions.md), cherry-pickable to main; not yet on main.

Cause, as measured on the code before the fix: the popup was measured a fixed 50 ms after reload(), a race with two outcomes seen with the same popup. (a) Measured in the old, complete document: the view is pinned to 600 pt before the reloaded page loads into it and WebKit then never scrolls it (scrollTo(0,300) -> 0, five wheel events -> 0). (b) Measured in a document the reload then replaces: the popover is presented at 100x100 and stays there, and the measure function and resize observer are gone; this happened to three small fixture popups on every run.

Fix: measure once the page has finished loading (poll isLoading every 50 ms up to 1.5 s, present anyway at the deadline and re-measure when it loads); while content overflows 600 pt switch WebKit's size-to-content mode off through the private setter (guarded by responds(to:)) so the page scrolls inside the popover, and restore it when the content fits or the popover closes. Content of exactly 600 keeps scrolling so a 100vh body cannot flip-flop.

/code-review medium --fix found two real issues, both fixed: (1) Detour never calls closePopup, WebKit hands out the same popup web view and each click builds a new controller, so an old controller's popoverDidClose could restore size-to-content on the view the new controller was showing; the scrolling state now lives per web view and only the controller that is the view's uiDelegate restores on close. (2) scroll mode decided on the body's height while fit mode decides on the document's, so a popup whose document is taller than its body (padding on html, an absolutely positioned footer) switched scrolling on and straight off; contentHeight now uses the document height whenever it exceeds the viewport. Left unfixed (low): a quirks-mode popup never shrinks back once scrolling; if the positioning view disappears during the load wait (now up to 1.5 s, previously 50 ms) nothing is presented and onClose never fires — that gap predates this change.

Tests: ExtensionPopoverSizingTests (12), ExtensionPopoverScrollStateTests (5), ExtensionPopoverMeasureScriptTests (5); with the old behaviour put back 8 of the first 12 fail, and 5 of the 10 review-fix tests fail against the pre-review logic. Final run with ExtensionMenuPopupDecisionTests: 28 tests, 0 failures.

Running app (env-gated harness .claude/task132.4-harness.patch, removed from the tree; isolated profile; window ordered front without activating; clicks were real NSEvents handed to the popup web view, wheel events synthetic; the screen was locked): API Explorer popup 440x600 over 3456 pt, scrollTo(0,300) -> 300, wheel from the top [120,240,360,480,600], all 11 below-the-fold buttons took a trusted click. Fitting popups: 320x117 with an explicit width and 446x131 without one, no scrolling, no scroll bar. Grow / shrink / grow: 300x137 -> 300x600 scrolling, a button under 1500 pt of filler clicked -> 300x137 -> scrolling again. Re-click while a tall popup is open, through the toolbar path: same web view, new controller, still scrolls, no late flip over 3.2 s; closing restores the mode; a fitting popup opened afterwards is sized to content and does not scroll. A document 616 pt tall with a 576 pt body: scrolls, bottom reachable, footer clicked, no alternation over 4 s.

Not verified: 1Password's popup (two small fixtures stood in for it); a physical trackpad or mouse; an animated popover close (with the screen locked it never completed, so the harness closed without animation); the no-private-setter log line at runtime (unit test only); a page still loading after 1.5 s; browser.action.openPopup(); the fix built on main.
<!-- SECTION:NOTES:END -->
