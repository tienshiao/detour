---
id: TASK-30
title: >-
  Tabs: undo of Delete Tab (and other tile restores) must rehome extension page
  URLs
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-13 00:58'
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
- [ ] #1 Undo of Delete Tab on a pinned extension-page entry after a context reload restores the entry on the extension's current origin, and activating it loads the page
- [ ] #2 With the extension disabled between delete and undo, the entry is restored dormant with its pending origin registered, and a later enable moves it onto the new origin; with it uninstalled, undo restores nothing for that entry (other entries in the same action are unaffected)
- [ ] #3 Every other undo path that restores a stored URL (favourites, pinned folders, unpin) follows the same rule, or the audit notes why it cannot hold an extension page; ordinary URLs are unchanged; tests cover the pinned entry and at least one other path
<!-- AC:END -->
