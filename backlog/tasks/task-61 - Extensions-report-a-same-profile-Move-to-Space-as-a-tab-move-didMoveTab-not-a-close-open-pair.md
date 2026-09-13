---
id: TASK-61
title: >-
  Extensions: report a same-profile Move to Space as a tab move (didMoveTab),
  not a close/open pair
status: To Do
assignee: []
created_date: '2026-09-13 19:25'
labels: []
dependencies: []
ordinal: 61000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TabStore.carry (TASK-38) tells the extension contexts about a tab moving to another space with ExtensionTabLifecycle.didClose followed by the destination container's didPlace/didOpen — even within one profile, where the tab keeps its web view and content scripts. Extensions therefore see tabs.onRemoved + tabs.onCreated for a tab that never went away and drop per-tab state (ports, 1Password frame maps). Chrome and WebKit model a tab changing window as detach/attach: WKWebExtensionContext.didMoveTab(_:from:in:) (unused in Detour today). The cross-profile branch must keep the close/open pair (different contexts). Found in the review of e912d33..1e26a52.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 ExtensionTabLifecycle gains a didMove(tab, fromIndex:, in oldWindow:) seam over WKWebExtensionContext.didMoveTab, called after the tab is in the destination container
- [ ] #2 TabStore.carry uses didMove for a same-profile move and keeps didClose + re-open for a cross-profile move
- [ ] #3 When neither space is shown by any window the notification is skipped and the choice is documented
- [ ] #4 ExtensionTabLifecycleTests cover same-profile (onMoved/onDetached+onAttached) and cross-profile (close+open) moves; the API Explorer extension logs tabs.onDetached/onAttached/onMoved
<!-- AC:END -->
