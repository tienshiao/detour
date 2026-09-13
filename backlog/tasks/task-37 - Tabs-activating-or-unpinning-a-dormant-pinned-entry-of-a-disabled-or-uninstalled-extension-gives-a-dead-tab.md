---
id: TASK-37
title: >-
  Tabs: activating or unpinning a dormant pinned entry of a disabled or
  uninstalled extension gives a dead tab
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 03:21'
updated_date: '2026-09-13 09:32'
labels:
  - extensions
  - tabs
  - bug
dependencies: []
priority: low
ordinal: 37000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-34 work. TASK-24 keeps a disabled extension's pinned entries as dormant tiles (pending origin) and drops uninstalled ones at restore; TASK-34 refuses favourite moves for those pages. But activating such a dormant pinned entry (TabStore.activatePinnedEntry -> materializeDormantEntry -> makeTab(loading:)) or unpinning it produces a sleeping tab that can never load while the extension is disabled, and an entry whose extension was uninstalled mid-session (after restore) opens a dead page. Decide the behaviour with the same classification (classifyCapturedPage / Profile.extensionID(forPageURL:)): e.g. refuse activation of a disabled extension's tile with a visible hint (toast) that the extension is off, and drop or refuse an uninstalled extension's tile; unpinning a dormant disabled tile could keep it dormant elsewhere or be refused. Keep ordinary and enabled-extension tiles unchanged.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Activating a dormant pinned entry of a disabled extension does not create a dead tab; the user gets the chosen feedback, and after enabling the extension activation loads the page on its current origin
- [x] #2 A dormant pinned entry of an extension uninstalled mid-session is handled per the chosen rule (dropped or refused) without leaving a dead tab, keeping pinned split invariants valid
- [x] #3 Unpin of such entries follows the same rule; tests cover activate and unpin for disabled and uninstalled extensions plus an ordinary entry
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Decision: an entry or favourite whose extension is disabled or was uninstalled mid-session is refused (tile stays dormant), never dropped — the next restore already drops uninstalled ones (TASK-24), and dropping mid-session from a click would surprise. Record in notes.
2. TabStore.activatePinnedEntry / activateFavorite / unpinTab / unpinSplitGroup report refusal (@discardableResult Bool or a small result enum) and TabStore exposes the refusal reason for a dormant tile (disabled vs uninstalled, with the extension's display name) so the window can phrase a toast.
3. BrowserWindowController shows toastManager.show(message:) on a refused user click of a dormant pinned entry or favourite and on a refused unpin (drag or context menu); non-interactive callers (split partner activation, close-split fallback) stay silent.
4. Tests in ExtensionPageFavoriteTests: activate + unpin for a disabled extension, an uninstalled extension, and an ordinary entry, asserting the result/reason; existing refusal tests keep passing.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Review fix (session 2026-09-12): TabStore.materializeDormantEntry now returns nil for a dormant entry whose page classifies as disabled/unavailable/legacy (via dormantTilePage + dormantTileDropTargets(.tabList) + rehomedTileURL), and activatePinnedEntry, unpinTab and unpinSplitGroup bail before mutating; activateFavorite gets the same gate. Tests in ExtensionPageFavoriteTests (disabled favourite stays dormant on activate; disabled entry is neither activated nor unpinned, registers no undo). Not done: the visible hint (toast) when activation is refused, and a decision on dropping vs refusing an entry uninstalled mid-session (currently refused, tile stays).

Decision: a dormant entry or favourite whose extension is disabled or was uninstalled mid-session is refused, never dropped — the tile stays and the next restore drops uninstalled ones (TASK-24); dropping from a click would delete a user tile behind their back and could break pinned-split invariants. activatePinnedEntry / activateFavorite / unpinTab / unpinSplitGroup now return Bool; TabStore.dormantTileRefusal(url:in:) classifies the refusal (DormantTileRefusal: extensionDisabled(name:) / extensionUnavailable) and the window toasts its message at every user-driven site (tile click, favourite click, drag unpin, context-menu unpin, unpin split group, favourites-bar drop of a dormant pinned tile, and the post-close fallbacks); the extension is named only when it is loaded, so a raw id is never shown. Non-interactive callers (split partner activation) stay silent. Tests: ExtensionPageFavoriteTests covers activate and unpin for disabled, uninstalled and ordinary entries.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Refused activations and unpins of dormant tiles now report why: the store returns a Bool and a DormantTileRefusal reason, and BrowserWindowController shows a toast at each user-driven site. Uninstalled-mid-session tiles are refused (kept) rather than dropped. Verified with ExtensionPageFavoriteTests and the full suite.
<!-- SECTION:FINAL_SUMMARY:END -->
