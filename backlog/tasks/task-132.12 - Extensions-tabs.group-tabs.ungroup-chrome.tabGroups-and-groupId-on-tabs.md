---
id: TASK-132.12
title: 'Extensions: tabs.group, tabs.ungroup, chrome.tabGroups and groupId on tabs'
status: In Progress
assignee:
  - '@claude'
created_date: 2026-10-03 23:09
updated_date: '2026-11-08T00:51:00Z'
labels: []
dependencies:
  - TASK-132.2
  - TASK-132.10
parent_task_id: TASK-132
priority: high
ordinal: 144000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Expose the tab group model to extensions. The Claude extension uses tabs.group({tabIds, groupId}) and tabs.group({tabIds, createProperties: {windowId}}), tabs.ungroup, tabGroups.get / query / update({title, color, collapsed}), tabGroups.Color, tabGroups.TAB_GROUP_ID_NONE (-1), tab.groupId on every Tab object, and tabs.query({groupId}). WebKit vends none of it. chrome.tabGroups is a new own property; group, ungroup and the groupId decoration are patched onto the native chrome.tabs wrapper in place and rooted (docs/chrome-runtime-patching.md). Group ids are integers stable for the session.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 tabs.group creates a group or adds to one and returns its id; tabs.ungroup removes tabs; both accept a single id or an array
- [x] #2 Tab objects from tabs.get, query, create, update, getCurrent and from tabs events carry groupId (-1 when ungrouped)
- [x] #3 tabs.query({groupId}) returns exactly the members, across the window's tabs, including unselected ones
- [x] #4 tabGroups.get, query, update and move work, and onCreated, onUpdated, onRemoved and onMoved fire in the background context
- [x] #5 Grouping a pinned tab, a favourite, a tab of another profile or an unknown id fails with an error and changes nothing
- [x] #6 An extension without the tabGroups permission gets no chrome.tabGroups; tests cover positive and negative cases
- [ ] #7 The Claude extension's session group appears with its title and colour when its panel opens
- [x] #8 API Explorer has a tab groups section
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Survey (done): the Claude extension 1.0.105 uses tabs.group/ungroup, tabGroups.get/update/query, Color, TAB_GROUP_ID_NONE and tab.groupId, and subscribes to tabs.onUpdated changeInfo.groupId in its worker AND its side panel page (to notice a tab leaving its group); it registers no tabGroups.on* listener.
2. Ids: process-wide registry from TabGroup UUID to a session-stable positive Int (Chrome group ids are integers). Groups of another profile answer "No group with id: N.", like an unknown id.
3. Native handler (ExtensionPolyfillHandler+TabGroups.swift): tabs arrive as handles from the tab-id bridge (__detourResolveTab). Requests: group, ungroup, membership (handles -> groupId or -1), get, query, update, move, awaitEvent. chrome.tabGroups.* is gated on the manifest tabGroups permission (permissionRefusal, as sidePanel); tabs.group/ungroup and groupId need none (Chrome). All tabs must be normal tabs of one space of this profile; a pinned tab, favourite, Peek, other-profile tab or unknown id refuses the call and changes nothing. move maps Chrome's window index (live pinned tabs and their Peeks first) to a gap in the normal list.
4. Events: the handler observes TabStore for its profile's spaces and queues tabGroups.onCreated/onUpdated/onRemoved/onMoved (tabGroups permission) and membership changes (tab handle + groupId, also for a new tab placed straight into a group, so the context cache learns it). A parked tabGroups.awaitEvent per context, seq/ack backlog, newer worker incarnation supersedes, background woken on an event once it listened (the notifications pattern). Unlike notifications, extension pages park too (the side panel listens): one slot per page instance, held with a weak web view and dropped when it is gone, bounded per extension.
5. JS module replacing the interim tabGroups stand-in: chrome.tabGroups (with permission); tabs.group/ungroup patched onto the native tabs wrapper in place and rooted; tabs.get/getCurrent/query/create/update/duplicate results decorated with groupId from a native lookup; tabs.query({groupId}) filtered by membership; tabs.onCreated/onUpdated listeners wrapped so the tab object carries groupId from a per-context cache (kept by lookups and events; synchronous, so event order is kept), and a membership change is delivered as tabs.onUpdated(tabId, {groupId}, tab) to those listeners. Parks only while a tabs.onCreated/onUpdated or tabGroups.on* listener exists.
6. Tests in real extension contexts (worker and page, promise and callback/lastError): permission gating both ways, profile isolation, happy paths, errors (bad arguments, unknown/closed tab, unknown group, pinned/favourite), decoration, query({groupId}) with unselected tabs, events in the background and a page, membership onUpdated after a store change. API Explorer section. Docs and wiki.
7. AC #7 (the real Claude extension) needs a signed-in session: checked if possible, otherwise left to TASK-132.20.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-07/08, implementation: native ExtensionTabGroups.swift (random session group ids, wire form, tabGroups.move window index, per-profile event hub with parked waits for the background and pages) and ExtensionPolyfillHandler+TabGroups.swift (group, ungroup, membership, membershipSnapshot, get, query, update, move, awaitEvent; tabGroups.* gated on the permission, tabs.group/ungroup/membership ungated); JS tabGroupsJS replaces the interim stand-in (interim keeps only debugger). Decision (mine, documented): groupId decoration, query({groupId}) and synthesized onUpdated({groupId}) only for extensions declaring tabGroups, because each decoration resolves tabs through the tab-id bridge and would tax every extension's tabs.query; tabs.group/ungroup for all, as Chrome. Not like Chrome: no moving tabs/groups between windows; a tab opening straight into a group reaches onCreated ungrouped and then onUpdated({groupId}); windows.get populate tabs carry no groupId.
Found by my own unit test: page-slot eviction ranked by the event counter, which does not move between parks (all ties); fixed with a park counter.
/code-review high --fix: 8 findings, 6 fixed by the review (tabGroups added to the permissions WebKit does not know, so optional requests and saved denials work; the module is idempotent on a re-run; a tabs patch failure no longer drops chrome.tabGroups; a window with no tab is never a group's window; no synthesized onUpdated without a Tab; dead page slots answer their parked wait). The 2 left were fixed after: group ids are random rather than counted (a counter leaked how many groups other profiles, Private included, made between two of an extension's own); a snapshot value never hides the first event for its tab (race between registering the wait and reading the snapshot).
Tests: ExtensionTabGroupsTests 15 (real worker and page), ExtensionTabGroupsUnitTests 12, plus ExtensionPermissionRestoreTests, ExtensionInterimNamespacesTests and ExtensionPolyfillTests updated: 314 tests, 0 failures in the last run; earlier ExtensionSidePanel*/TabResolve/TabHandleRegistry/RuntimeGetContexts suites 327 run with only the then-expected interim failures, all since rewritten. API Explorer: new "Tab groups" section (popup + worker events).

Runtime check (subagent, DETOUR_DATA_DIR DetourVerify13212 and 13212b, build of 16:42 from this worktree, a hand-seeded MV3 test extension, loopback fixture pages): tabs.group, tabGroups.update/get/query, tabs.query({groupId}) with groupId on each tab, persistence (tabGroup row "Verify 132.12" orange and both tab rows in browser.db; the group back after a relaunch), ungroup (DB and tabs.get), and tabs.onUpdated({groupId}) in the worker for changes made by an extension page: all pass. Found: (1) a window whose space has no selected tab lists no tabs to WebKit at all (tabs.query {} empty), the known TASK-132.21 behaviour, not the groups code; (2) the worker heard no onUpdated({groupId}) for its own tabs.group/ungroup: dispatch compared with the decoration cache its own call had filled. Fixed with a separate announced map; test testAContextHearsItsOwnGroupAndUngroup. Added testGetCurrentCarriesGroupId (an extension page opened as a tab). Final: ExtensionTabGroupsTests 17 + ExtensionTabGroupsUnitTests 12 = 29/0 across the last two runs; neighbouring suites (side panel, tab resolve, handle registry, getContexts, polyfill integration and profile wiring, windows.create private, TabGroupStore/Placement) 268 run, 13 env-gated skips, 0 failures; ExtensionPolyfillTests + InterimNamespaces + PermissionRestore 314/0 earlier in the same tree.
AC #7 (the real Claude extension shows its session group with title and colour when its panel opens) is NOT checked: it needs a signed-in Claude session; left to TASK-132.20.
<!-- SECTION:NOTES:END -->
