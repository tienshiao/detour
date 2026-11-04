---
id: TASK-211
title: 'Settings: keep a pane''s list and details fixed; scroll only their contents'
status: Done
assignee:
  - '@claude'
created_date: '2026-10-27 02:17'
updated_date: '2026-10-27 04:51'
labels:
  - settings
  - ui
  - bug
dependencies: []
priority: medium
ordinal: 247000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Feedback (user, 2026-10-26, screenshot of the Profiles pane): scrolling the profile's details also scrolls the profile list on the left out of view. Since TASK-189, SettingsPaneViewController puts each pane's whole body in one NSScrollView, so a list pane's master list and detail area move together.

Change: in the list panes (Profiles, Spaces, Extensions, Links — the ones with SettingsMetrics.listPaneMinimumHeight), the list and the detail area are anchored to the top and bottom of the pane below the description. The list's rows scroll inside the list, and the detail contents scroll inside the detail area, independently. Panes without a master list (General, Content Blocking) keep scrolling as a whole.

Keep the TASK-189/TASK-192 sizing rules: the window still fits smaller displays (SettingsPaneHeight, minimum heights), nothing widens the window, and a long list scrolled to its end stays at its end.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 In Profiles, Spaces, Extensions and Links, scrolling the details leaves the list in place, and scrolling the list leaves the details in place
- [x] #2 The list and the details fill the pane's height below the description, top and bottom, at every window height the pane allows
- [x] #3 General and Content Blocking still scroll as one body
- [x] #4 The window still fits a small display, as TASK-192 requires, and a long list scrolled to its end stays at its end
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. TDD: SettingsPaneColumnsTests (fake list pane + real panes) for fixed columns, independent scrolling, natural height from column content, end anchoring; red with empty stubs.
2. SettingsPaneViewController: scrollsBodyAsWhole (default true); false pins the body to the pane's edges below the description; makeColumnScrollView(document:estimatedWidth:) builds a SettingsColumnScrollView (end-anchored in tile()) and registers the document for naturalContentHeight; scrollColumnsToTop() for a new selection.
3. Spaces, Profiles, Extensions: detail column in a column scroll view, list table in SettingsColumnScrollView, scrollsBodyAsWhole false.
4. Links (user decision): Quick Detour section moved to a new QuickDetourSettingsViewController pane (toolbar after Links, one scrolling body); Links' route list fills the height and scrolls, Default + caption pinned to the bottom; minimum raised only if needed.
5. Runtime harness: seeded rows, wheel events over each column, frames/offsets logged, end anchoring on shrink, small screen, Quick Detour pane; light and dark.
6. Review, tests, wiki, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Queued (user, 2026-10-26): ahead of TASK-194, after TASK-210 (order: 210, this task, 194, 201, 202, 209).

Decision (user via coordinator, 2026-10-26) on the Links pane, which has no master/detail layout: the Quick Detour section moves out of Links into its own Settings pane (new toolbar item 'Quick Detour' next to Links; same controls and behaviour; scrolls as one body like General). Links then is: the Routes list filling the height under 'Routes' and scrolling its own rows; Default and its caption fixed at the bottom, not scrolling. Raise the Links minimum only if Default + caption need it; the TASK-189 small-display rule (window fits the screen) still holds.

Follow-up request (user via coordinator, 2026-10-26): Extensions' Uninstall Extension button stays fixed below the scrolling details (outside the column scroll view, level with the list's bottom). Spaces and Profiles have no comparable bottom action (delete is the list's − button, always visible), so nothing changed there. naturalContentHeight now holds each column scroll view at its content height while measuring the body, so a footer like the button counts.

Built (2026-10-26/27): SettingsPaneViewController.scrollsBodyAsWhole (default true; false pins the body to the pane's edges below the description, scrollView nil); makeColumnScrollView(document:estimatedWidth:) -> SettingsColumnScrollView (flipped clip, autohiding scroller, end-anchored in tile(): a column scrolled to its end stays at its end when resized); naturalContentHeight holds each visible column at its content height while measuring the body (counts footers); scrollColumnsToTop() when the details show another item (tracked by id: shownSpaceID/shownProfileID/shownExtensionID). Spaces (grid), Profiles (sections), Extensions (stack) in column scroll views; master-list tables in SettingsColumnScrollView. Links: route list fills the height (rows' height at priority 250, 56 pt floor at 490), scrolls its rows; Default + caption pinned to the bottom; minimum stays 400 (Default + caption leave ~177 pt of list at 400). New QuickDetourSettingsViewController (toolbar 'quickdetour' after Links, SF Symbol macwindow.on.rectangle: a window over another; no description or section title; rows unchanged; caption now says 'on the Links pane'; retries a refused shortcut on appear, ends recording on disappear); LinkRouteListScrollView removed. Extensions' Uninstall below the column scroll view.

Choices: detail column ends at the pane margin, so the overlay scroller draws over its right edge while scrolling (recorded in the wiki); spacing between Quick Detour rows kept at rowGap.

TDD: SettingsPaneColumnsTests red 6 of 14 failing against empty stubs (scrollsBodyAsWhole true, plain scroll view), then green; real-pane, scroll-to-top and footer tests added after (the footer natural-height test would have failed against the first max() measurement).

/code-review --fix: 7 findings, 5 fixed (reset-to-top keyed by item id instead of row change, so adds/deletes/uninstall/showSpacesPane also reset; scrollView now Optional; class doc listed the wrong panes; shared scroll view setup helper; naturalContentHeight top computed without the mode flag); 1 comment fixed (Links viewDidLayout). Skipped: wiki (already updated in the working tree, outside the reviewed file list); possible stale route row heights when the route list's legacy scroller appears without a pane relayout (unconfirmed; cells re-wrap on their own layout).

Tests: SettingsPaneColumnsTests 21, SettingsPaneHeightTests 20, ProfileSettingsLayoutTests 15, LinkRouteEditorTests 15, LinkRouteStoreTests 39, QuickDetourHotKeyTests 22, HotKeyShortcutTests 27, HotKeyRegistrationTests 20, ExtensionOptionsPageEntryTests 14, SpacePageScrollAnchorTests 4: 197/197.

Runtime (docs/harness/task211-harness.patch; final run after the review fixes and the Uninstall change, light and dark logs identical, 28 captures, no constraint conflicts): see the patch header for frames. Not verified: a real trackpad (gesture-phase) scroll and a real mouse drag of the window edge (driven by setFrame); legacy always-show scroll bars; the blocked-deletion alert's highlighted route scrolled into view in the list; recording a shortcut in the moved Quick Detour pane.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
In Settings, Spaces, Profiles and Extensions keep their list and detail column fixed to the pane below the description; each scrolls only its own contents, a list or column scrolled to its end stays there when the window shrinks, and another item's details open at the top. Extensions' Uninstall button stays in view below the scrolling details. Links (user decision): the route list fills the height and scrolls, the Default and its caption stay at the bottom; the Quick Detour controls moved to a new Quick Detour pane after Links (one scrolling body). General, Quick Detour and Content Blocking still scroll as one body; the height rule and small-screen cap are unchanged (minimum 400, not raised). 197 tests pass; runtime harness in light and dark measured both columns under wheel events, end anchoring, a 520 pt screen and the new pane.
<!-- SECTION:FINAL_SUMMARY:END -->
