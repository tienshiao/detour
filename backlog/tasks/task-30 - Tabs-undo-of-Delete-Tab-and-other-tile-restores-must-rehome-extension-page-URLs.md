---
id: TASK-30
title: >-
  Tabs: undo of Delete Tab (and other tile restores) must rehome extension page
  URLs
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 00:58'
updated_date: '2026-09-13 01:03'
labels:
  - extensions
  - tabs
  - bug
dependencies: []
priority: low
ordinal: 30000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-28 work (f9cab25). TabStore.deletePinnedEntry's 'Delete Tab' undo recreates the PinnedEntry with the pinnedURL captured at delete time. For a webkit-extension:// page, if the extension's context was reloaded between delete and undo (TASK-2 recovery, update, disable->enable) that origin is dead, so the restored tile opens a dead page; if the extension was uninstalled meanwhile it restores a tile TASK-24 would drop at the next launch. TASK-28 added the helpers to reuse: capture the extension id with Profile.extensionID(forPageURL:) at delete time, classify with classifyCapturedPage, and rewrite with rehomedTileURL (restorable: live origin; disabled: register a pending origin so a later enable resolves it). Audit every other undo closure that restores a stored URL without rebuilding a tab (e.g. favourite delete/unfavourite, pinned folder delete, unpin) and apply the same rule.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Undo of Delete Tab on a pinned extension-page entry after a context reload restores the entry on the extension's current origin, and activating it loads the page
- [x] #2 With the extension disabled between delete and undo, the entry is restored dormant with its pending origin registered, and a later enable moves it onto the new origin; with it uninstalled, undo restores nothing for that entry (other entries in the same action are unaffected)
- [x] #3 Every other undo path that restores a stored URL (favourites, pinned folders, unpin) follows the same rule, or the audit notes why it cannot hold an extension page; ordinary URLs are unchanged; tests cover the pinned entry and at least one other path
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extend TASK-28's tile helper: rehomedTileURL returns nil for an uninstalled extension's page (.unavailable), plus an overload that classifies a URL captured with its extension id.
2. deletePinnedEntry: capture the entry's extension id at delete time (Profile.extensionID(forPageURL:)); the undo restores the entry on rehomedTileURL (restorable: live origin; disabled: dormant with its pending origin registered) and restores nothing, registering no redo, when the extension is uninstalled. rejoinPinnedSplit is skipped, so the partner stays dissolved.
3. Audit every registerUndo closure in TabStore. Delete Space's entry loop drops uninstalled entries (with their backing tabs) and sanitizes pinned split groups after; the others either rebuild live tab objects (Unpin Tab, Unpin Split, Pin Tab/Split), restore no URL (Delete Folder reparents, moves, renames, separates), are already TASK-28's, or do not exist (favourites register no undo).
4. Tests in ExtensionPageUndoTests: pinned Delete Tab after a reload then activate and wake on the shared store; disabled then enabled; uninstalled; Delete Space with an uninstalled and a disabled entry; ordinary entry unchanged.
5. Run ExtensionPageUndoTests and related pinned/undo test classes.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Helper: rehomedTileURL (TASK-28) now returns nil for .unavailable, with an overload taking the captured extension id; Delete Tab and Delete Space both go through it.

Audit of every registerUndo closure in TabStore:
- Delete Tab (deletePinnedEntry): captured extension id at delete time; undo rehomes the entry (restorable: live origin, or pending if the context is not loaded; disabled: dormant, pending origin registered); uninstalled: no restore, no redo, split partner stays dissolved (rejoinPinnedSplit is not reached).
- Delete Space: entries already rehomed by TASK-28, but an uninstalled extension's entry was restored as a dead tile. Now dropped with its backing tab (as restore does), pinned split groups sanitized after, selection moves off a dropped backing tab. Other entries unaffected.
- Delete Folder: removes only the folder and reparents its children; no entries are deleted or restored, so no URL is restored.
- Unpin Tab / Unpin Split / Pin Tab / Pin Split: the undo moves the same live BrowserTab objects back (tab.url is kept current by retargetExtensionPages; a disable/uninstall closes the tab so the undo's lookup fails and it does nothing). No stored URL.
- Favourites: no undo is registered (removeFavorite, restoreFavoriteAsTab/AsPinned, reorder).
- Close Tab, Close Both Splits, pinned Close Tab, Delete Space tabs: TASK-28.
- Rename, move, separate, split, Add/Edit/Move Space: no URLs.
Found outside scope (not changed): restoreFavoriteAsTab builds a dormant favourite's tab with BrowserTab(fallbackURL:configuration: space config) instead of makeTab(loading:), so an extension-page favourite dragged to the tab list cannot load.

Tests: ExtensionPageUndoTests 18/18 (5 new), SplitTabTests 63/63.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The pinned Delete Tab undo now captures the entry's extension id at delete time and restores the entry through TASK-28's rehomedTileURL: on the extension's live origin when enabled, dormant on a registered pending origin when disabled (a later enable moves it), and not at all (no redo, split partner stays dissolved) when uninstalled. rehomedTileURL returns nil for an uninstalled extension's page, so Delete Space's undo now drops such entries with their backing tabs and sanitizes pinned splits, leaving other entries alone. The audit found no other undo that restores a stored URL: Delete Folder only reparents, the pin/unpin undos move live tab objects, and favourites register no undo. Ordinary URLs are unchanged. Verified with 5 new ExtensionPageUndoTests (reload then activate and wake on the new origin, disabled then enabled, uninstalled with a split partner, ordinary entry with split rejoin, Delete Space with uninstalled and disabled entries); ExtensionPageUndoTests 18/18 and SplitTabTests 63/63 pass.
<!-- SECTION:FINAL_SUMMARY:END -->
