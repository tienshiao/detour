---
id: TASK-229
title: >-
  Hover card: show a tab's Peek (its title, URL and thumbnail), including from
  the Peek favicon in the sidebar row
status: Done
assignee:
  - '@claude'
created_date: '2026-10-29T04:25:00Z'
updated_date: '2026-10-29T07:14:00Z'
labels:
  - sidebar
  - peek
dependencies: []
priority: low
ordinal: 265000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested Oct 28 2026. The sidebar hover card (TASK-190, Detour/Browser/HoverCard/) describes only the host tab: its title, URL and thumbnail. A tab with a Peek open or parked shows the Peek's favicon as a badge at the trailing edge of its row (TabCellView peekFaviconImageView, TASK-47 for favourite tiles, TASK-173 for the Control+Tab switcher), but hovering the row or the badge says nothing about the Peek. The user wants the card to cover Peeks, either as part of the host row's card or as its own card when the pointer is over the Peek favicon in the row.

Context for whoever picks this up:
- A Peek is a BrowserTab held in its host's `peekTab` (wiki/tabs/peek.md). It can be live (web view on screen or hidden) or parked (host asleep, Peek web view gone, state saved by `parkPeek`), and it is restored from the host's `peekURL`/`peekInteractionState` after a relaunch. The card has to work for each state without waking anything.
- Thumbnails come from `switcherPreview`, taken when a tab is left on screen, and from the disk cache keyed by `TabStore.thumbnailKey(for:)` (TASK-190). Whether a Peek ever gets its own preview, or whether the host's capture already includes the Peek overlay, has not been checked. Never wake or host a hidden tab to take one (wiki/platform/gpu-iosurface-limit.md).
- The card's rules are pure functions in HoverCardRules.swift with tests in TabHoverCardTests. Extend those rather than branching in the view.

Decide when planning, with the user's input on the product question:
- One card for the row with a Peek section, or a separate card for the badge, or both.
- What the card shows for a parked Peek or one restored after a relaunch with no thumbnail.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Hovering the Peek favicon in a sidebar row shows a hover card for the Peek (its title and URL), for a live or a parked Peek; hovering the rest of the row still shows the host tab's card as before
- [x] #2 Moving the pointer between the Peek favicon and the rest of the row swaps the card at once (no fresh show delay), and the card is placed beside the row as the host's card is
- [x] #3 The Peek's thumbnail is shown when one exists, the card has a compact layout when none does, and no Peek or host is woken or shown to make one
- [x] #4 Pinned rows, favourite tiles and split panes that have a Peek behave the same as normal rows
- [x] #5 The rule changes are covered in TabHoverCardTests (live, parked and no-Peek cases), and the card is checked at runtime in light and dark mode
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Rules (HoverCardRules.swift, test first in TabHoverCardTests): add HoverCardTarget.peek(host:), compared by host identity; HoverCardTarget.peekBadge(of:) turns a row or tile target with a live host that has a Peek into a .peek target (nil for a dormant entry or tile, or a host with no Peek); HoverCardContent for a Peek: a live or parked Peek gives its own title and URL (falling back to host.peekURL); a session-restored Peek (no peekTab) gives the URL as the title; its preview is the Peek's in-memory switcherPreview; no disk key (Peeks have no thumbnail file); no picture while the host is on screen (the Peek is then presented over it).
2. TabCellView: report whether the pointer is over the Peek badge (a fixed trailing hit rect computed from the badge's constants, not its laid-out frame), via mouseMoved and recheckHover, and re-check when the badge appears or goes. TabCellHoverDelegate gains overPeekBadge.
3. FavoriteTileView: same for the tile's corner chip (mouseMoved tracking), delegate gains overPeekBadge.
4. TabSidebarViewController: map overPeekBadge to HoverCardTarget.peekBadge(of:); the existing end-then-begin on the same view gives the immediate swap through the controller's swap window. Controller tests for the swap.
5. Split rows show no Peek badge (configureSplitCell passes nil), so there is nothing to hover there; record it.
6. Wiki (tab-hover-card.md, peek.md, tab-cell.md), /code-review --fix, /verify in light and dark, tests, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decision (user, Oct 28 2026): the Peek gets its own hover card, shown while the pointer is over the Peek favicon badge in the sidebar row. The host row's card is unchanged and has no Peek section.

Implemented (Oct 28 2026):
- Rules (HoverCardRules.swift): HoverCardTarget.peek(host:), peekBadge(of:) (a live tab with peekTab or peekURL; none for a dormant entry or tile), isSameRow(as:) (a row and its own badge are one row for dismissal). Peek content: the Peek tab's title and URL (host.peekURL when the tab has none); after a relaunch the URL alone (no Peek tab, and Peeks record no history); picture = the Peek's in-memory switcherPreview, none while its host is on screen; never a disk key.
- Views: TabCellView and FavoriteTileView report overPeekBadge from fixed hit rects built from the layout constants (peekBadgeHoverRect(in:)); the tile's tracking area gained .mouseMoved; both re-check when the badge appears or goes under a resting pointer.
- Sidebar: cardTarget(_:overPeekBadge:); beginCardHover ends the old target only when it is not isSameRow, so crossing the badge swaps the card in place.
- Decisions: no disk thumbnail for Peeks (a restored Peek's card is text only until it is shown and left again). Split rows show no Peek badge (configureSplitCell passes nil), so they have no Peek card: AC #4 is met for pinned rows and favourite tiles only; left unchecked pending the user's call (reword, or a follow-up to give split rows a badge).
- /code-review --fix found 3, fixed 3: dismissal no longer lifted by crossing the badge (isSameRow + 2 tests), a stale split half in hoverRegionChanged after a row stops being a split, the close-button gap constant shared with the hit rect.
- Tests: TabHoverCardTests + TabHoverCardControllerTests + FavoriteTileBadgeTests pass (TDD: the new content, badge-target and hit-rect tests failed first against empty stubs; the swap test passed at once because the controller's swap window already covered it). Full suite: 3349 tests, 18 skipped; failures were 10-20 s web-content timeouts under load average ~30 (HistoryDeletionIntegration, HistoryTitleUpdate, FaviconLinkBridge, InPageLinkRouting, ExtensionWindowsCreatePrivate, one ExtensionPolyfillIntegration test); rerun alone: 138 tests, 0 failures. SettingsPaneColumnsTests.testTheLinksPaneDoesNotNeedMoreThanTheListMinimum fails on main before this change too.
- Runtime (docs/harness/task229-harness.patch, isolated profile, local fixture pages, two phases with a relaunch; screen locked): badge swap 0.04 s each way in light and dark; fresh badge hovers 0.46 s; cards 6 pt outside the sidebar, top level with the row; live Peek cards (normal, pinned, favourite) with own title, URL and picture; parked Peek kept both; selected host's Peek card had no picture; restored Peeks showed the URL alone (38 pt card). Not verified: pixels (locked screen: no window captures; cacheDisplay and layer.render of the glass card are blank), and a real pointer (hover was driven through the views' own mouse handlers).

Oct 29 2026, split rows (the user asked for a badge on them):
- TabCellView: the trailing badge is now the single tab's or the split's right pane's; the left pane has its own (leftPanePeekFaviconImageView) between its close button and the divider (4 pt / 14 pt), shown only while the row is a split, with its own hover rect (leftPanePeekBadgeHoverRect(in:), ending at the row's middle). configureSplitCell passes each half's displayPeekFavicon (pinned: entry.tab?.displayPeekFavicon). The hover card needed no rule change: the half's target goes through peekBadge(of:).
- TDD: TabCellPeekBadgeHoverTests (single row's badge, each split pane's badge in its own half, a pane without a Peek, the left badge going with the split) failed first against stubs.
- /code-review --fix: 6 found, 3 fixed (badges set before updateSplitPane so an animated reveal measures the final layout, and the left badge fades in with the reveal; a stale left badge cleared when the row stops being a split, with a test; the three favicon views set up in one loop). Skipped: a one-member split showing the same Peek twice (a fallback that should not occur), the left badge vanishing at once on an animated collapse, a few extra layout passes per split reconfigure.
- Tests: 388 tests in the sidebar, split, Peek and hover card suites; 1 failure, BrowserWindowSidebarModeTests.testAutosaveRestoreArrivesAsExternalCollapse, which passes alone (8/8, twice) and was flaky in the Oct 28 full run before this change.
- Runtime (harness phase 3, screen locked, light and dark): each pane's badge showed its Peek's card and each title area its pane's card, every move swapping at once; left title, close button, 4 pt, badge, 14 pt, divider, nothing overlapping; the left title keeps 32 pt of a 188 pt row with a badge (52 pt without); clearing the left pane's Peek hid its badge. Pinned split rows use the same rendering but were not run.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The Peek badge in a sidebar row, a favourite tile or either pane of a split row (normal or pinned) now shows its own hover card describing the Peek: title, URL, and its in-memory picture when it has one; the rest of the row keeps the host's or pane's card. Split rows, which had no Peek badge, now show one per pane (the right pane's in the trailing slot, the left pane's before the divider). Moving between a badge and the row swaps the card at once, a dismissal holds across the badge until the pointer leaves the row, and nothing is woken or shown to picture a Peek. A Peek restored after a relaunch gets a compact URL-only card (Peek pictures are not kept on disk). Covered by TabHoverCardTests, TabHoverCardControllerTests and TabCellPeekBadgeHoverTests, and a three-phase runtime harness in light and dark (behaviour and frames; no pixels, the screen was locked; pinned split rows not run).
<!-- SECTION:FINAL_SUMMARY:END -->
