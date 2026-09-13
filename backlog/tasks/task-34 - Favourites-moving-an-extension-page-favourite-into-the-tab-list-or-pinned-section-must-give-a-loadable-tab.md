---
id: TASK-34
title: >-
  Favourites: moving an extension-page favourite into the tab list or pinned
  section must give a loadable tab
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 01:41'
updated_date: '2026-09-13 01:55'
labels:
  - extensions
  - tabs
  - bug
dependencies: []
priority: low
ordinal: 34000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-30 work. TabStore.restoreFavoriteAsTab builds the tab for a dormant favourite with space.makeWebViewConfiguration() instead of TabStore.makeTab(loading:) (TASK-24), so a favourite whose URL is a webkit-extension:// page (e.g. an options page) dragged into the tab list becomes a tab that cannot load the scheme. Check restoreFavoriteAsPinned and every other conversion between favourites, pinned entries and tabs (favourite -> pinned, pinned -> favourite, tab -> favourite, drag between sections and across spaces of the same profile) for the same pattern, and for the extension id being carried: a live backing tab moves as-is, a dormant one must be built through makeTab(loading:), and a stored URL on a dead origin must be rehomed with the TASK-28/TASK-30 helpers (rehomedTileURL / classifyCapturedPage), dropping it only if the extension is uninstalled.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Dragging a dormant extension-page favourite into the tab list or the pinned section gives a tab that loads the page on the extension's current origin
- [x] #2 Every favourite/pinned/tab conversion path is audited; those that can carry an extension page build dormant tabs via makeTab(loading:) and rehome stored URLs; ordinary URLs are unchanged
- [x] #3 Tests cover favourite -> tab and favourite -> pinned for an extension page (including after a context reload) and one ordinary URL
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Audit favourite/pinned/tab conversions: restoreFavoriteAsTab, restoreFavoriteAsPinned, addFavorite (tab/live pinned -> favourite), addFavoriteFromEntry (dormant pinned -> favourite), reorderFavorite, activateFavorite, materializeDormantEntry, and the sidebar/favourites-bar drop paths that end in them.
2. TabStore: classify a dormant favourite's URL by Profile.extensionID(forPageURL:) (classifyCapturedPage). Live backing tabs move as-is. restoreFavoriteAsTab builds dormant tabs through makeTab(loading:) on rehomedTileURL; refuses (returns false, favourite stays) for a disabled extension (a tab list tab on a pending origin is dead and restore drops it) and for an uninstalled one. restoreFavoriteAsPinned rehomes the entry URL (disabled: pending origin registered); refuses uninstalled. addFavoriteFromEntry refuses an uninstalled page and the controller only detaches the pinned entry once the favourite was added.
3. Public TabStore.favoriteDropTargets(id:profileID:in:) -> FavoriteDropTargets (tabList/pinned). validateSidebarDrop gains favoriteTargets (default .all) and rejects a favourite drop into a section it may not enter; acceptFavoriteDrop re-checks. New TabSidebarDelegate query with default .all, implemented by BrowserWindowController.
4. No undo added (favourites register none; confirm).
5. Tests: new ExtensionPageFavoriteTests (real WKWebExtension contexts): favourite -> tab after reload (wake loads on new origin, shared store), favourite -> pinned after reload (activate+wake), live backing tab moved, disabled (pinned: pending resolves on enable; tab: refused), uninstalled refused for tab/pinned/favourites, ordinary URL unchanged. SidebarDragDropTests for the favourite target filter.
6. Run class tests then the full DetourTests target.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Audit of favourite/pinned/tab conversions (TabStore + BrowserWindowController+TabSidebar + TabSidebarViewController drop paths):
- restoreFavoriteAsTab (favourite -> tab list): WAS the bug (space configuration). Live backing tab moves as-is. Dormant: classified by Profile.extensionID(forPageURL:) (loaded context or pending origin), URL rehomed with rehomedTileURL, tab built by makeTab(loading:). Refused (returns false, favourite stays) for a disabled extension (a tab on the pending origin cannot load and restore drops open tabs of a disabled extension) and for an uninstalled one.
- restoreFavoriteAsPinned (favourite -> pinned): live as-is. Dormant entry URL rehomed (disabled: kept, pending origin registered, an enable moves it). Refused for uninstalled. Activation goes through materializeDormantEntry.
- addFavoriteFromEntry (dormant pinned -> favourite): URL rehomed; refused for uninstalled. The window controller now adds the favourite first and detaches the entry only on success, so a refusal leaves the entry pinned.
- addFavorite (tab -> favourite, live pinned -> favourite): live tab moves as-is, no change.
- reorderFavorite: array move only, no URL, no change.
- activateFavorite and materializeDormantEntry: already makeTab(loading:) (TASK-24); stored URLs are kept current by retargetExtensionPages / pending origins, no change.
- Across spaces of the same profile: favourites are per profile and every favourite drop uses the window's active space, so the same paths cover it. No cross-space tab/pinned drag exists (payloads are rejected by spaceID).
- Favourites register no undo: confirmed (tests assert undoManager.canUndo is false after the moves), none added.
Why a favourite needs no in-memory extension id: a context reload rewrites favourite URLs (retargetExtensionPages), and restore and disable register the origin as pending. Only an uninstall forgets it, and that is exactly the refused case.
Drop validation: new FavoriteDropTargets OptionSet (SidebarDragDrop.swift). validateSidebarDrop takes favoriteTargets (default .all) and rejects a favourite drop into a section it may not enter. acceptFavoriteDrop re-checks via favoriteDropSection(destination:). TabSidebarDelegate.tabSidebar(_:dropTargetsForFavorite:) (default .all) is backed by TabStore.favoriteDropTargets(id:profileID:). classifyCapturedPage/liveExtensionPageURL/rehomedTileURL gained Profile-based overloads, and the Space versions forward to them.
Not changed (found in the audit, outside the favourites scope): unpinning or activating a dormant pinned entry of a disabled or uninstalled extension still makes a tab that cannot load. The context-menu Move to Space re-creates the page with addTab(in:url:). The pinned -> favourite drop gate in FavoritesBarView does not pre-reject an uninstalled entry; the drop is a clean no-op. Validation queries the database (installed/enabled ids) per validateDrop call, but only while dragging a dormant extension-page favourite.
Tests: ExtensionPageFavoriteTests (7, shared store, real contexts, real reload/disable/enable/uninstall paths) and SidebarDragDropTests +2. Focused run: ExtensionPageFavoriteTests 7, ExtensionPagePersistenceTests 9, ExtensionPageRehostTests 16, ExtensionPageUndoTests 18, SidebarDragDropTests 38, TabStoreTests 27, all 0 failures. Full DetourTests target: 836 tests, 0 failures.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A dormant favourite moved into the tab list is now built through makeTab(loading:) on its URL rehomed onto the extension's live origin, so an extension-page favourite loads. Favourite -> pinned and dormant pinned -> favourite rehome their URLs the same way. Live backing tabs move as they are, and ordinary URLs are unchanged. The uninstalled-extension case is refused rather than deleted: the favourite (or pinned entry) stays where it was, the sidebar drop validation rejects it through FavoriteDropTargets, and the store calls return false. A disabled extension's dormant favourite may only become a pinned entry, kept on a pending origin that an enable resolves. Favourites still register no undo. Verified with ExtensionPageFavoriteTests (7) and SidebarDragDropTests (+2); the full DetourTests target ran 836 tests with 0 failures.
<!-- SECTION:FINAL_SUMMARY:END -->
