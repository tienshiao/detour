---
id: TASK-28
title: 'Tabs: undoing the close of an extension page tab restores a dead page'
status: Done
assignee:
  - '@claude'
created_date: '2026-09-12 23:49'
updated_date: '2026-09-13 00:27'
labels:
  - extensions
  - tabs
  - bug
dependencies: []
priority: low
ordinal: 28000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-24 work. The Close Tab undo handlers in TabStore (closeTab's registerUndo around 'Close Tab', 'Close Both Splits', and the pinned-entry 'Close Tab' undo) rebuild the tab as BrowserTab(archivedInteractionState:fallbackURL:configuration: space.makeWebViewConfiguration()). A webkit-extension:// page cannot load in the space configuration (it needs its extension context's configuration), and if the context was reloaded since the close its origin is dead too, so undo brings back a blank tab. TASK-24 already fixed the equivalent paths for Reopen Closed Tab, dormant pinned tiles and favourites via TabStore.makeTab(loading:) (sleeping tab, resolved in BrowserTab.wake through the owning context) and Profile.extensionID(forPageURL:) / pendingExtensionOrigins for dead origins; the undo closures should capture the extension id at close time and go through the same path. Session-only bug (undo does not survive relaunch).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Undo of Close Tab, Close Both Splits and closing a pinned entry's tab on an extension page (e.g. an options page) restores a working page on the extension's current origin
- [x] #2 If the extension's context was reloaded between close and undo, the restored page is on the new origin; if the extension was disabled or uninstalled meanwhile, undo restores no dead tab (skips or restores the ordinary non-extension behaviour for other tabs in the same action)
- [x] #3 Split-group rejoin and closed-tab-stack bookkeeping in the undo handlers are unchanged for ordinary tabs; tests cover the extension-page cases
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Factor TabStore helpers: classifyCapturedPage(url:extensionID:in:) (closedTabPage delegates to it), liveExtensionPageURL (rewrite onto the loaded context base, else register a pending origin) and restoredTab(id:url:title:faviconURL:interactionState:page:in:) -> BrowserTab? (ordinary: eager tab from the space configuration, exactly as before; restorable: sleeping makeTab on the live base, no interaction state; disabled/unavailable: nil). reopenClosedTab uses restoredTab too.
2. closeTab 'Close Tab' undo: capture the extension id at close; rebuild via restoredTab; nil -> no-op (no insert, closed-tab record untouched, no redo).
3. closeSplitGroup 'Close Both Splits' undo: snapshot extension ids; rebuild members; all restored -> rejoin as before; one -> restore alone, no group, only its record removed, redo = closeTab; none -> no-op.
4. closePinnedTab 'Close Tab' undo: capture id for tab URL (or current pinned URL); nil -> entry stays dormant, no redo.
5. deleteSpace 'Delete Space' undo: snapshot ids; extension page tabs rebuilt sleeping on the live base; disabled/unavailable tabs dropped (sanitizeSplitGroups, selection fix-up, backing tab dropped leaves entry dormant); pinned entry URLs re-homed.
6. Tests: new ExtensionPageUndoTests with real contexts (in-memory DB + one TabStore.shared wake test); run SplitTabTests/ExtensionPage* and full target.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Shared helpers in TabStore: classifyCapturedPage (closedTabPage now delegates), liveExtensionPageURL, rehomedTileURL, restoredTab(page:) and a classifying overload. reopenClosedTab builds through restoredTab too.

Undo paths changed: closeTab 'Close Tab', closeSplitGroup 'Close Both Splits', closePinnedTab 'Close Tab', deleteSpace 'Delete Space'. Each captures the extension id at close time and rebuilds via restoredTab: ordinary pages exactly as before (live, space configuration, interaction state); restorable pages sleeping on the live base (or a pending origin when the context is not loaded), without interaction state; disabled/uninstalled give no tab. Single-tab undos then do nothing, register no redo, and leave the closed-tab record. Close Both Splits restores the surviving member alone, without a group, consuming only its record, redo = closeTab. Delete Space drops such tabs (sanitizeSplitGroups, selection fix-up, backing tab dropped leaves the entry dormant) and rehomes pinned entry URLs.

Found while testing: BrowserTab.wake never loaded a tab created sleeping with no interaction state (the TASK-24 makeTab(loading:) extension pages: dormant tiles, favourites, Reopen Closed Tab). The url publisher's initial nil emission cleared tab.url before the load read it. wake now seeds lastAttemptedURL when it is nil. Covered by the shared-store wake test.

Not changed (follow-up candidate): deletePinnedEntry's 'Delete Tab' undo restores the entry's pinnedURL as captured, so a context reload between delete and undo leaves that dormant tile on a dead origin. It rebuilds no tab.

Tests: ExtensionPageUndoTests (13) pass. Full DetourTests target: 801 tests, 0 failures.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Undoing the close of an extension page no longer brings back a dead tab. The Close Tab, Close Both Splits, pinned-entry Close Tab and Delete Space undos now capture the page's extension id at close. They rebuild through one TabStore helper (restoredTab), which Reopen Closed Tab also uses, and classify with TASK-24's rules. An enabled extension's page comes back sleeping on the context's current base, or on a pending origin if the context is not loaded, without interaction state. A disabled or uninstalled extension's page is not restored. Single undos become no-ops that keep the closed-tab record. A mixed Close Both Splits restores the ordinary member alone. Delete Space drops such tabs and fixes up splits and the selection. Ordinary tabs are unchanged.

Also fixed BrowserTab.wake, which never loaded a tab created sleeping without interaction state. This affected every makeTab(loading:) extension page since TASK-24.

Tests: ExtensionPageUndoTests (13 tests, one waking through the shared store). Full DetourTests target: 801 tests, 0 failures. Follow-up candidate: the pinned 'Delete Tab' undo does not rehome the entry URL.
<!-- SECTION:FINAL_SUMMARY:END -->
