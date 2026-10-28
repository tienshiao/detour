---
id: TASK-220
title: >-
  Extensions: a popup whose content is wider than its first size stays at
  126x126 and is cut off
status: Done
assignee:
  - '@claude'
created_date: 2026-10-27 22:21
updated_date: '2026-10-28T12:55:00Z'
labels:
  - extensions
  - bug
dependencies: []
references:
  - Detour/Extensions/UI/ExtensionPopoverController.swift
priority: low
ordinal: 256000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen during TASK-210's runtime check: the verify probe extension's popup, opened from the Quick Detour bar, stayed at 126x126 points and cut off its 220-point-wide content. The popover sizes itself from the extensionPopupResize message (ExtensionPopoverController). Find why the resize did not apply (message not sent, measured before layout, or ignored) and whether the main window's popups have the same problem.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A popup with fixed 220x300 content opens at that size from both the main window and the Quick Detour bar
- [x] #2 A popup that changes size after load resizes the popover
- [x] #3 Checked at runtime with a test extension, light and dark
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reproduce in a test host: load a 220x300 popup extension, open it with ExtensionPopoverController.show and log the popover size, web view frame, intrinsicContentSize and the document over time.
2. Red tests (ExtensionPopoverSizingTests): opens at the content size via show (both windows use show), via presentPopupWebView with an already-loaded web view (openPopup path), clamped to 100..800 x 100..600, resizes when the content changes size after load, takes a second page's size after the popup navigates.
3. Fix ExtensionPopoverController: size from the popup web view's own intrinsicContentSize (WebKit's size-to-content autosizing on the action popup web view), which survives reloads and navigations, instead of JS measurement + a ResizeObserver injected into whatever document was current 50 ms after reload; present once the reload has finished loading (bounded by a timeout), and follow later intrinsic size changes.
4. Runtime check with a probe extension (220x300 popup that can resize itself) from the main window's pinned button and the Quick Detour bar, light and dark; measure the popover windows.
5. Wiki (popup-and-options-ui, appkit/webkit quirk), log line, lint; code review; commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Root cause: a race in ExtensionPopoverController, in every entry point (not specific to Quick Detour). show() reloads the popup web view and presentPopupWebView measured the body from script 50 ms later; at that point the web view was still on about:blank (reproduced in the test host: url about:blank, body 16x8), so the size clamped to 100x100, and the ResizeObserver + __detourMeasureBody were injected into that about:blank document, which the popup page then replaced with neither present (window.__detourResizeObserver undefined afterwards). The popover stayed at 100x100 content = a 126x126 popover window (popover window = content + 26 pt), while WebKit laid the page out at its own size behind it: the action popup web view uses size-to-content autosizing (_sizeToContentAutoSizeMaximumSize 800x600, WebExtensionActionCocoa.mm), so innerWidth was 220 in a 100-wide frame and the page was cut off rather than reflowed. When the reload happened to finish within 50 ms the popup came out right, which is why it looked like a Quick Detour problem.

Main window: same problem. Runtime baseline on the old code: the main window's pinned button opened the probe at 126x126 window / 100x100 web view (intrinsic 220x300) on the first open; the Quick Detour's open right after came out 246x326 / 220x300 (reload won the race). Neither followed a later size change.

Fix: size from the popup web view's intrinsicContentSize (WebKit's own content size, what its own popup popover uses), no page script and no message handler. Presented once the reloaded page has finished loading (KVO isLoading; 0.5 s timeout; close() while waiting cancels and calls onClose). The web view sits in a PopupContentView pinned top-leading only, with min/max 100..800 x 100..600 constraints, high hugging/compression and a 360x480 fallback at priority 50; when WebKit invalidates its intrinsic size Auto Layout resizes it and the container's layout() sets popover.contentSize. On close the constraints are removed and the web view leaves the container (WebKit reuses it). Removing the extensionPopupResize handler also drops a strong reference the shared user content controller held to the last controller.

Tests (ExtensionPopoverSizingTests, new): red on the old code: 3 of 5 failed (opens at content size: first size 100x100; navigation to a second page: stayed 220x300; clamp: stayed 100x100); the two that passed did so because the reload won the 50 ms race in that run. Green after the fix: 7 tests (the 5 plus reopening the reused web view and a close before the page loads), 3 iterations, 21/21 passed.

Code review (/code-review high --fix): 7 findings. Fixed: (1) a late popoverDidClose of the previous controller (Quick Detour closes the old popup as it opens the next) pulled the shared web view out of the new popover: now the controller removes only its own constraints and detaches the web view only if it is still in its own container (test testALateCloseOfThePreviousPopoverLeavesTheNextOneItsWebView); (2) an anchor gone by the time the page loaded presented nothing and never called onClose, so an openPopup() completion handler leaked: now reported closed (test testAPopupWhoseAnchorIsGoneByLoadIsReportedClosed); (3) ExtensionManager.presentActionPopup stores activePopovers/popupCompletionHandlers before presentPopupWebView, since an already-loaded web view now presents (or reports a close) synchronously. Skipped: hugging/compression priorities left on the reused web view (nothing else hosts it); a popup still loading at the 0.5 s timeout opens at the previous document's size and then grows (by design of the timeout; a heavier popup like 1Password could show it); the opening size computed by hand and by the constraints (two copies of the clamp); the fixed 1.2 s sleep in the close-before-load test.

Tests after the review: ExtensionPopoverSizingTests 9/9, ExtensionMenuPopupDecisionTests 6/6, InPageLinkRoutingTests 24/24 (39 in one run, 0 failures); QuickDetourExtensionTests on its own 18/18. Before the review: ExtensionPopoverSizingTests 7 tests x 3 iterations = 21/21.

Runtime (/verify, Debug build in .derived, docs/harness/task220-harness.patch, probe 'Verify Popup Size' with a 220x300 popup and a Grow/Shrink button to 340x420, installed with ExtensionManager.install(from:) and pinned in Default; measured in-process: popover window frame, web view frame and intrinsicContentSize, page innerWidth/innerHeight, the bottom-right corner square and prefers-color-scheme):
- Old code (DetourVerify2200, light): main window first open 126x126 window / 100x100 web view, intrinsic 220x300 (cut off); Quick Detour 246x326 / 220x300 (reload won the race); grow did not resize either.
- Fixed, before review (2201 light, 2202 dark) and after review (2203 light, 2204 dark): main window and Quick Detour both first seen at 246x326 window / 220x300 web view (innerWidth 220x300, corner square at 216..220 x 296..300, i.e. fully inside), grown to 366x446 / 340x420, shrunk back to 246x326 / 220x300, closed by Escape; the page saw scheme=light / dark.
Not verified: the screen was LOCKED for the whole session (ioreg CGSSessionScreenIsLocked true), so there are no screenshots and nothing was checked by eye; posted clicks did not reach the popup page, so the Grow button was pressed from script (the page's own click handler, a real after-load size change) rather than by a click; a slow popup hitting the 0.5 s timeout; a real extension's popup (1Password); action.openPopup() at runtime (covered by the presentPopupWebView test). Popup taller than 600 (TASK-150) unchanged. Data dirs and their defaults keys removed after each run.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Action popups now open at their content's size and follow it. Root cause: a race in ExtensionPopoverController, the same for the main window and the Quick Detour. show() reloads the popup web view and the popover was measured from script 50 ms later, while the web view was still on about:blank (16x8 body, clamped to 100x100 = a 126x126 popover window); the ResizeObserver that should have corrected it was injected into that about:blank document, which the popup page replaced. WebKit laid the page out at its own size behind the 100x100 frame, so it was cut off. Fix: the popover takes the popup web view's intrinsicContentSize (WebKit's size-to-content autosizing on action popups, the size WebKit's own popover uses), presents once the reload has finished loading (0.5 s timeout), and follows later changes through Auto Layout (PopupContentView); no script is injected. From the review: a late close of the previous popover no longer takes the next one's web view, a popup whose anchor is gone is reported closed, and openPopup()'s completion handler is stored before presenting. Tests: new ExtensionPopoverSizingTests (9; red on the old code for open size, clamp and navigation), plus ExtensionMenuPopupDecisionTests, InPageLinkRoutingTests, QuickDetourExtensionTests green. Runtime: both windows, light and dark, 220x300 at open, 340x420 after growing, back after shrinking, measured in-process; the screen was locked, so no visual check and the Grow button was pressed from script. Wiki: popup-and-options-ui (Popup size), appkit-gotchas, webkit-source-lookup.
<!-- SECTION:FINAL_SUMMARY:END -->
