---
id: TASK-130
title: >-
  Sidebar: keyboard focus stays behind on a tab list whose page has slid off
  screen
status: Done
assignee:
  - '@claude'
created_date: '2026-10-02 07:05'
updated_date: '2026-10-02 07:34'
labels:
  - sidebar
  - window
  - bug
dependencies: []
priority: low
ordinal: 130000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up to TASK-128 (code-review finding: 'the off-screen focus gate covers only the archive page'). Measured in-app on 2026-10-02 with a key-view probe (Full Keyboard Access off, the user's setting):

What does NOT happen: Tab from the end of a web page, from a sidebar tab list, or with nothing focused never reaches an off-screen sidebar control. Web views and the space pages' tables are not linked into any key-view loop (nextKeyView nil — they are created after AppKit builds its one-off loop when the window is first shown), and the loop's only possible key views are the archive page's search field and list, which TASK-128 gates.

What DOES happen: focus that is already on a space page's tab list (a click on a row puts it there) stays on that list when its page leaves the screen. (1) Open the Archived Tabs page: the active space's list is off screen but still first responder, and Down arrow switches the selected tab (A2 -> A1 in the probe) while the user is looking at the archive. (2) Switch space: the old space's list keeps focus, arrow keys move its selection invisibly (selectedRow -1 -> 2) and the new space's list ignores the keyboard. Also, makeFirstResponder on an off-screen list succeeds, so anything that focuses a list programmatically can land there.

Not measured: Full Keyboard Access on. By AppKit's rules the archive page's Clear and Filter buttons, which are in the key-view loop, become key views then, on screen or not.

The archive page already handles its own case (acceptsKeyboardFocus, resignArchivePageFocus). The same rule should hold for every page of the strip, driven by one piece of state rather than per control.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A space page's tab list refuses first responder while its page is not the one the strip rests on (another space is active, or the Archived Tabs page is showing), and accepts it again when it is
- [x] #2 Keyboard focus held by a control of a strip page moves off that control when the page leaves the screen: showing the archive page or switching space no longer leaves an off-screen list as first responder
- [x] #3 After focus leaves an off-screen page it goes to the web page the window shows (or to nothing when there is none), so arrow keys no longer switch tabs in a list the user cannot see
- [x] #4 The archive page's Clear and Filter buttons refuse first responder while the page is off screen
- [x] #5 Clicking a tab row still focuses the active page's list and arrow keys still walk its rows; the archive search field and list still take focus while the archive page shows
- [x] #6 Unit tests cover the gate and the focus hand-off for a space switch and for the archive page
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Give DraggableTableView the same allowsKeyboardFocus switch ArchiveTableView has (acceptsFirstResponder and becomeFirstResponder), and SpacePageView an acceptsKeyboardFocus property that drives it (off by default).
2. In TabSidebarViewController, replace the archive-only handling with one updatePageKeyboardFocus(): only the page the strip rests on (archive page while it shows, else the active space's) accepts focus; called from isShowingArchivePage's didSet and updateActivePage().
3. Generalise resignArchivePageFocus to resignOffscreenPageFocus: a first responder inside the strip but outside the current page is resigned, then the delegate is told (new tabSidebarDidReleaseKeyboardFocus), and BrowserWindowController hands focus to the page with restoreWebContentFocus().
4. ArchivePageView: Clear and Filter buttons refuse first responder while the page is off screen (Full Keyboard Access).
5. Tests: SidebarPageFocusTests on a regular window with two spaces (gate, space switch, archive show/dismiss, focus on the current page stays); extend the archive page test for the buttons.
6. Verify in-app with the key-view probe (.claude/task130-harness.patch) before and after.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented (uncommitted, 2026-10-02). TabSidebarViewController.updatePageKeyboardFocus() is the single gate: only the page the strip rests on accepts focus (SpacePageView.acceptsKeyboardFocus -> DraggableTableView.allowsKeyboardFocus; the archive page as before, now including its Clear and Filter buttons). resignOffscreenPageFocus() replaces resignArchivePageFocus(): a first responder inside the strip but outside the current page is resigned and the delegate is told (tabSidebarDidReleaseKeyboardFocus), where BrowserWindowController calls restoreWebContentFocus(). On a space switch the sidebar resigns before setActiveSpace's selectTab runs, so selectTab's nothing-holds-focus rule (TASK-128) focuses the new space's page.
AppKit facts learned: NSWindow.makeFirstResponder does not ask acceptsFirstResponder, and reports success even when the view's becomeFirstResponder declines (the window takes focus) — so both table classes override becomeFirstResponder too, and tests assert on window.firstResponder, not the return value.
Behaviour change beyond the bug: leaving the archive page with its search field or list focused now hands the keyboard to the web page (it used to leave nothing focused).
Verified: SidebarPageFocusTests (7 new) plus InitialWindowFocusTests pass; with the fix stashed 6 of the 7 and the Filter-button assertions fail. 205 tests across the window/sidebar suites pass (SidebarPageFocus, CommandPaletteFocus, UnhandledKeyFallthrough, InitialWindowFocus, ProductionDefaultsIsolation, ExtensionActiveTab, SidebarVisibilityState, SidebarLayout, SidebarDragDrop, SplitTab); the full suite was not run. In-app probe before/after: with a tab list focused, showing the archive page now leaves the web view first responder and Down arrow no longer changes the selected tab; switching space focuses the new space's page and the old list's selection is untouched; focusing an off-screen list programmatically leaves the window as first responder.
NOT exercised: real key presses and clicks (the probe sends keyDown to the first responder directly), a swipe or a space-button click as the trigger (both end in the same setActiveSpace path), Full Keyboard Access on (could not be enabled for one process: the -AppleKeyboardUIMode launch argument and swizzling isFullKeyboardAccessEnabled both had no effect on NSButton.canBecomeKeyView).

Code review (Oct 2), no severe finding; four low-severity ones fixed: the focus gate shared by both lists is now one base class, FocusGatedTableView (DraggableTableView and ArchiveTableView inherit it); the leftover acceptsKeyboardFocus assignment in updateArchivePagePresence is gone (updatePageKeyboardFocus is the only gate site); new test for leaving the archive page with the search field focused (the field-editor path); SidebarPageFocusTests saves and restores TabStore.lastActiveSpaceID and ExtensionManager.lastActiveSpaceID, which a regular window would otherwise leave naming a deleted space. 206 tests across the window/sidebar suites pass on the reviewed code (SidebarPageFocusTests is now 8).
Left open: (a) leaving the archive page for a space other than the active one focuses the outgoing space's page for a moment before setActiveSpace focuses the new one — a spurious focus/blur pair on the page being left, end state correct. (b) Pre-existing: rebuildPages tears down the page holding first responder (space added or deleted elsewhere, undo of Add Space) and nothing hands the keyboard on; the window ends up first responder — inferred from code, not run. (c) The gate is per control while resigning is generic, so a focusable control added to a page later must be wired in by hand; row buttons in off-screen pages under Full Keyboard Access are ungated and unmeasured.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Only the sidebar page the strip rests on takes keyboard focus now, and focus held by a page that leaves the screen is handed to the web page. Before, a tab list that had focus (a click on a row) kept it after its page slid away: with the Archived Tabs page showing, arrow keys switched tabs behind it; after a space switch they walked the old space's hidden rows. TabSidebarViewController.updatePageKeyboardFocus() is the single gate (space pages via SpacePageView.acceptsKeyboardFocus, the archive page including its Clear and Filter buttons; both lists share FocusGatedTableView, which also declines becomeFirstResponder because makeFirstResponder does not ask acceptsFirstResponder). resignOffscreenPageFocus() gives the focus up and tells the delegate, and BrowserWindowController focuses the page. Side effect: leaving the archive page with its search field or list focused now focuses the web page instead of nothing. The reviewed premise — Tab reaching off-screen sidebar controls — was measured and does not occur: web views and space lists are not in AppKit's key-view loop. Verified with SidebarPageFocusTests (8, 6 of the original 7 fail without the fix), 206 tests across the window and sidebar suites, and an in-app probe before and after; not exercised with real key presses, a swipe, or Full Keyboard Access. Open items are in the notes; the focus drop when pages are rebuilt is followed up separately.
<!-- SECTION:FINAL_SUMMARY:END -->
