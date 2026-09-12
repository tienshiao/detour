---
id: TASK-28
title: 'Tabs: undoing the close of an extension page tab restores a dead page'
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-12 23:49'
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
- [ ] #1 Undo of Close Tab, Close Both Splits and closing a pinned entry's tab on an extension page (e.g. an options page) restores a working page on the extension's current origin
- [ ] #2 If the extension's context was reloaded between close and undo, the restored page is on the new origin; if the extension was disabled or uninstalled meanwhile, undo restores no dead tab (skips or restores the ordinary non-extension behaviour for other tabs in the same action)
- [ ] #3 Split-group rejoin and closed-tab-stack bookkeeping in the undo handlers are unchanged for ordinary tabs; tests cover the extension-page cases
<!-- AC:END -->
