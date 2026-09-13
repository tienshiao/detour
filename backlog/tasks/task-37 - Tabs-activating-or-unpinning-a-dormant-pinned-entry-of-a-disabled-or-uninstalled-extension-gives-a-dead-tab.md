---
id: TASK-37
title: >-
  Tabs: activating or unpinning a dormant pinned entry of a disabled or
  uninstalled extension gives a dead tab
status: In Progress
assignee:
  - '@claude'
created_date: '2026-09-13 03:21'
updated_date: '2026-09-13 05:25'
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
- [ ] #1 Activating a dormant pinned entry of a disabled extension does not create a dead tab; the user gets the chosen feedback, and after enabling the extension activation loads the page on its current origin
- [ ] #2 A dormant pinned entry of an extension uninstalled mid-session is handled per the chosen rule (dropped or refused) without leaving a dead tab, keeping pinned split invariants valid
- [ ] #3 Unpin of such entries follows the same rule; tests cover activate and unpin for disabled and uninstalled extensions plus an ordinary entry
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Review fix (session 2026-09-12): TabStore.materializeDormantEntry now returns nil for a dormant entry whose page classifies as disabled/unavailable/legacy (via dormantTilePage + dormantTileDropTargets(.tabList) + rehomedTileURL), and activatePinnedEntry, unpinTab and unpinSplitGroup bail before mutating; activateFavorite gets the same gate. Tests in ExtensionPageFavoriteTests (disabled favourite stays dormant on activate; disabled entry is neither activated nor unpinned, registers no undo). Not done: the visible hint (toast) when activation is refused, and a decision on dropping vs refusing an entry uninstalled mid-session (currently refused, tile stays).
<!-- SECTION:NOTES:END -->
