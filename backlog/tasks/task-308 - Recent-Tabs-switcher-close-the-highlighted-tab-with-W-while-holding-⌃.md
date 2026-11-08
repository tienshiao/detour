---
id: TASK-308
title: 'Recent Tabs switcher: close the highlighted tab with W while holding ⌃'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-08T10:00:00Z'
updated_date: '2026-11-08T11:35:00Z'
labels:
  - tabs
  - recent-tabs
dependencies: []
references:
  - TASK-292.6
priority: low
ordinal: 369000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Arc let you close tabs from its Control-Tab switcher by continuing to hold Control and tapping W (Arc for macOS 2023 release notes: "You can now close tabs from the recent tab switcher (CTRL + TAB) by continuing to hold CTRL and tapping W"). Detour's switcher (RecentTabSwitcher.swift: a local key monitor; ⌃Tab / ⌃⇧Tab move, ←/→ move, Return or keypad Enter commits, Escape cancels, releasing ⌃ commits) has no way to close a tab, so the website's Recent Tabs page (TASK-292.6) lists it under "Not in Detour". Requested by the user, Nov 8 2026.

Things to settle while building it: a split card (one card for two tabs) closes both or asks; pinned tabs and favorites (close = make dormant, as ⌘W does); the highlight moves to the next card and the switcher stays open while ⌃ is held; the last card closing ends the switcher; closing goes through the same path as ⌘W, so ⇧⌘T / Undo bring it back.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 With the switcher open and ⌃ held, pressing W closes the highlighted card's tab through the same path as ⌘W (Undo and Reopen Closed Tab bring it back), the card disappears and the highlight moves to the next card
- [x] #2 Split cards, pinned tabs and favorites follow a rule agreed with the user
- [x] #3 Closing the last card closes the switcher; releasing ⌃ afterwards selects the highlighted tab as usual
- [x] #4 Tests cover the switcher's close handling (RecentTabOrder / switcher model) for normal, split and pinned cards
- [x] #5 Checked at runtime with /verify
- [ ] #6 The website's Recent Tabs page moves it from Not in Detour to the how-to steps
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Pure model in RecentTabOrder.swift: RecentTabSwitcherState.removeHighlighted(hasCurrent:) (card leaves, highlight to the next card wrapping to the first, stays open while something is left to switch to) and recentTabCloseAction(card:members:) (lone normal tab -> closeTab, split -> closeSplitGroup, pinned (one or a pinned split) -> makePinnedDormant, favourite -> deactivateFavorite).
2. RecentTabSwitcher: Control+W while active calls closeEntry, removes the card, rebuilds the overlay or ends.
3. BrowserWindowController.closeSwitcherEntry runs the action through Cmd+W's paths (closeTab(at:wasSelected:), closePinnedTab(at:)/store.closePinnedTab, deactivateFavorite) and the sidebar's split close (extracted as closeSplitGroup(_:)).
4. Tests: RecentTabOrderTests (model), RecentTabSwitcherMonitorTests (key handling), RecentTabSwitcherCloseTests (real window: lone, current, split, pinned, stale).
5. Runtime check: posted Control+Tab / Control+W / Control release, Undo and Reopen Closed Tab.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026, user decision: ⌃W on a split card closes both tabs (Undo brings both back); pinned tabs and favorites do what ⌘W does (dormant) and leave the switcher.

Implemented as planned. Files: RecentTabOrder.swift (RecentTabSwitcherState.removeHighlighted(hasCurrent:), RecentTabCardMember, RecentTabCloseAction, recentTabCloseAction(card:members:)), RecentTabSwitcher.swift (Control+W case, closeEntry/currentTabID hooks, closeHighlighted, test accessors), BrowserWindowController+RecentTabSwitcher.swift (closeSwitcherEntry), BrowserWindowController+TabSidebar.swift (split close extracted as closeSplitGroup(_:)).

Decisions made here: the highlight moves to the card after the closed one, wrapping to the first; the switcher stays open while there is something to switch to (the begin rule), so it ends when no card is left or only the window's current card is; a Peek presented on the card's tab does not take Control+W (unlike Cmd+W): the tab closes with its Peek; a pinned split card makes both entries dormant (consistent with 'split closes both' + 'pinned does what Cmd+W does'); W with other modifiers is swallowed and does nothing while switching.

Tests: RecentTabOrderTests 19 (9 new), RecentTabSwitcherMonitorTests 14 (4 new), RecentTabSwitcherCloseTests 5 (new, real window: lone, current, split, pinned, stale card), RecentTabSwitcherPeekTests 7, SplitTabTests 63: all pass.

Runtime (Nov 8, DetourB8-308-1, temp harness posting real NSEvents in a normal window with A, B, C, a D|E split and pinned P): Control+Tab listed [A, B, C, D|E, P] highlight 1; Control+W closed B (cards [A, C, D|E, P], highlight on C, switcher open); Control+Tab, Control+W closed both D and E (undo name 'Close Both Splits'); Control+W made P dormant and it left the cards; Control+Tab, release Control selected C. Undo x3: P live again, the split back as a split, B back. Control+W on B then Shift+Cmd+T: B reopened. Control+W repeatedly: the switcher ended when only the current card was left. Not checked at runtime: favourites (unit-level rule + Cmd+W's path), dark mode. WebKit store dir for DetourB8-308-1 left under ~/Library/WebKit/com.detourbrowser.mac.

Website facts for AC #6 (Recent Tabs page: move from Not in Detour to the how-to steps): while holding Control in the Control+Tab switcher, press W to close the highlighted tab; the card disappears and the next one is highlighted, keep holding Control to close more, release Control to switch to the highlighted tab. A split card closes both tabs. Pinned tabs and favourites are unloaded (as Cmd+W does) and leave the switcher. Edit > Undo (Cmd+Z) or Reopen Closed Tab (Shift+Cmd+T) brings a closed tab back; Undo brings a split back as a split. When nothing is left to switch to, the switcher closes.

Website AC pending (held for release).

Nov 8 2026 (lead review): ⌃W now matches the typed character ('w', charactersIgnoringModifiers), falling back to the ANSI W key position only on non-Latin layouts; covered for AZERTY, Dvorak and Cyrillic in RecentTabSwitcherMonitorTests.

Website: updated Recent Tabs (new 'Close tabs from the switcher' section: hold ⌃ and press W; split closes both; pinned/favorites unloaded; Undo / Reopen Closed Tab; Arc box moved to Same) and Keyboard Shortcuts (switcher row) on website branch next-release (1fe0664), held for the release

Nov 8 2026 (lead): landed on main with the batch; /code-review on its branch (fixes folded in); full DetourTests on the integrated code: 3882 tests, 18 skipped, 2 failures, both pre-existing on main before the batch (TASK-310).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Control+W in the Control+Tab switcher closes the highlighted card through Cmd+W's paths: a lone tab closes (Undo / Reopen Closed Tab), a split closes both tabs under one undo, pinned tabs and favourites go dormant and leave the switcher. The card disappears, the highlight moves to the next card, the switcher stays open while there is something to switch to and releasing Control selects as usual. Decisions live in recentTabCloseAction and RecentTabSwitcherState.removeHighlighted, tested in RecentTabOrderTests, with the key handling in RecentTabSwitcherMonitorTests and the window paths in RecentTabSwitcherCloseTests; verified at runtime with posted events incl. Undo and Shift+Cmd+T. Website AC pending (facts in notes).
<!-- SECTION:FINAL_SUMMARY:END -->
