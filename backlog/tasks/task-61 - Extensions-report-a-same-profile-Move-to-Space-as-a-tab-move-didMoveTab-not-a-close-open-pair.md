---
id: TASK-61
title: >-
  Extensions: report a same-profile Move to Space as a tab move (didMoveTab),
  not a close/open pair
status: In Progress
assignee:
  - '@claude'
created_date: '2026-09-13 19:25'
updated_date: '2026-09-13 22:00'
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

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. ExtensionTabLifecycleNotifying gains didMove(_ tab, fromIndex:, in oldWindow:, in profile:); production notifier forwards to WKWebExtensionContext.didMoveTab(_:from:in:); ExtensionTabLifecycle.didMove(tab, fromIndex:, in:) guards on the registered profile.
2. TabStore.moveTab / movePinnedEntry: for a same-profile move resolve the old window (the controller whose activeSpaceID is the source space) and the tab's index in that window's extension tab enumeration before mutating; carry() no longer sends didClose for a same-profile move; after the tab is in the destination container call didMove. Cross-profile keeps didClose + re-open via didPlace.
3. Skip rule: when no window shows the source and none lists the tab after the move, send nothing (documented in the seam's doc comment). Window resolution goes through an injectable hook so tests can supply stub windows.
4. Tests in ExtensionTabLifecycleTests: same-profile move (normal tab and pinned entry) records open then move, no close; cross-profile move records close then open; no-window case records nothing. API Explorer background.js logs tabs.onMoved / onDetached / onAttached.
<!-- SECTION:PLAN:END -->
