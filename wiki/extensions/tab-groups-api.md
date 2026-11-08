---
type: Feature
title: Tab groups API
description: chrome.tabGroups, tabs.group / tabs.ungroup and groupId on tabs, built on TabStore's tab groups; the permission gate, session ids, how a window is named, the groupId cache, the parked event channel that reaches pages too, and what differs from Chrome.
tags: [extensions, tab-groups, polyfill, events, claude-extension]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-08T01:00:00Z }
sources:
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift (tabGroupsJS)
  - id: handler
    resource: ../../Detour/Extensions/Runtime/ExtensionPolyfillHandler+TabGroups.swift
    title: ExtensionPolyfillHandler+TabGroups.swift
  - id: events
    resource: ../../Detour/Extensions/Runtime/ExtensionTabGroups.swift
    title: ExtensionTabGroups.swift (ids, wire form, move index, event hub)
  - id: tests
    resource: ../../DetourTests/ExtensionTabGroupsTests.swift
    title: ExtensionTabGroupsTests (real contexts) and ExtensionTabGroupsUnitTests
  - id: task
    resource: backlog:TASK-132.12
    title: "Extensions: tabs.group, tabs.ungroup, chrome.tabGroups and groupId on tabs"
---

# Summary

The extension face of [tab groups](../tabs/tab-groups.md), for the Claude
extension, which keeps each agent session's tabs in one group and acts only
on them. WebKit vends none of it. `tabGroupsJS` in the polyfill bundle talks
to `handleTabGroupsRequest`, which calls the TabStore API; the
[tab id bridge](./tab-and-window-bridge.md) turns WebKit's tab ids into
handles.[^task]

# What the Claude extension uses

Read from its 1.0.105 bundle: `tabs.group` / `tabs.ungroup`,
`tabGroups.get` / `update` / `query`, `Color`, `TAB_GROUP_ID_NONE`,
`tab.groupId`, and `tabs.onUpdated` with `changeInfo.groupId`, subscribed
in its worker **and** its side panel page (to notice a tab leaving its
group). It registers no `tabGroups.on*` listener.

# The gate

| Part | Needs `tabGroups` | Why |
|---|---|---|
| `tabs.group`, `tabs.ungroup` | no | Chrome gates neither, and they cost nothing until called |
| `chrome.tabGroups` | yes (`permissions` or `optional_permissions`); the handler also refuses a denial in Settings. WebKit does not know the name, so it is one of `WebExtension.permissionsOutsideWebKit`: Detour's handler answers `permissions.request` for it and the restore applies a saved decision at load | Chrome |
| `groupId` on Tab objects, `tabs.query({groupId})`, synthesized `onUpdated({groupId})` | yes | **Detour's choice**: Chrome decorates every extension's tabs, but here each decoration resolves the tabs through the bridge, which would slow every extension's `tabs.query` (1Password calls it constantly) |

# Ids and windows

- **Group ids** are positive 32-bit integers drawn at random per UUID by
  `ExtensionTabGroupIDs`, stable for the session and process-wide. Random,
  not counted: with a process-wide counter, the gap between two of an
  extension's own groups would tell it how many were made in other
  profiles, Private's included (review finding). A group an undo recreates has its
  old UUID and so its old id. The handler looks an id up among its own
  profile's spaces only, so another profile's group answers "No group with
  id: N.", exactly like an unknown one.
- **Windows** have no bridge. As for `chrome.sidePanel`, a `windowId` is
  sent as the handle of the window's active tab, from
  `windows.get(id, {populate: true})`. A group's `windowId` is read the other
  way: from a member tab's `tabs.get`. A window with no tab has no group:
  `query` lists none for it, and `tabs.group` / `move` naming it are refused
  as another window.
- **`tabGroups.move`'s index** is Chrome's: the position of the group's first
  tab in the window after the move, counting the listed pinned tabs and live
  Peeks (`extensionWindowTabs` order). `tabGroupMoveTarget` maps it to a gap
  in the normal tabs; an index among the pinned tabs or inside another group
  is refused with Chrome's texts, and an index inside a split moves past it.

# groupId on Tab objects

Two sources, because WebKit's own events must not wait:

- **API results** (`get`, `getCurrent`, `query`, `create`, `update`,
  `duplicate`, `move`) are decorated after one `tabGroups.membership` lookup:
  the tabs' handles in, their group ids out. Accurate, one round trip.
- **WebKit's `tabs.onCreated` / `tabs.onUpdated`** get the group from a
  per-context cache, synchronously, so an event is never delayed or
  reordered. The cache starts from `tabGroups.membershipSnapshot` when the
  context starts listening and follows the events below; lookups refresh it.

Consequence: a tab placed straight into a group as it opens (one opened
from a grouped tab) reaches `tabs.onCreated` as ungrouped, and an
`onUpdated({groupId})` follows. Chrome reports the group in `onCreated`. The
Claude extension's group tracking handles the `onUpdated` (it adds the tab to
its session).

The resolver's own `tabs.query` walk (`__detourFindTabIdForHandle`) calls
WebKit's original query, so it does not decorate (and resolve) every tab
twice.

# Events

`ExtensionTabGroupEvents`, one per profile, made at the first wait, observes
TabStore and queues into an `ExtensionEventParking` (the slot machinery,
shared with the [debugger events](./debugger-api.md) since TASK-132.13):

- `created`, `updated`, `removed`, `moved` for the group events (only for an
  extension whose `tabGroups` permission is active);
- `membership` (tab handle, group id) for every change of a tab's group, and
  for a tab inserted straight into a group, which TabStore reports only as an
  insertion.

A context parks `tabGroups.awaitEvent` while it has a `tabs.onCreated` /
`onUpdated` or `tabGroups.on*` listener, acknowledging by `seq`, as
[notifications](./polyfill-layer.md#chromenotifications-events-reach-the-background-through-a-parked-request)
do. Differences from that channel:

- **Pages park too.** A slot per JS context instance; a page's slot holds its
  web view weakly and goes when the view does; at most 8 page slots per
  extension, the one parked longest ago evicted first (ranked by a park
  counter: the event counter does not move between parks, which made every
  slot tie in the first version).
- **The background** has one slot; a newer incarnation supersedes the parked
  wait, an older one is refused, and an event wakes a background that has
  listened this launch.
- A refused or superseded wait stops the context listening for good rather
  than retrying in a loop.
- Each slot keeps at most 64 unacknowledged events.

A membership event is delivered to `tabs.onUpdated` listeners as
`(tabId, {groupId}, tab)` when it changes what the listeners were last told
(`announcedGroupId`), so the same change reported twice (an insertion and a
membership change) fires once. That is deliberately not the decoration
cache: the context's own `tabs.group` and its lookups fill the cache before
the event arrives, and comparing against it hid the extension's own changes,
which Chrome reports (found by the runtime check). One exception: a value the snapshot set never hides the
first event for that tab, because a change landing between registering the
wait and reading the snapshot is already in the snapshot.

# Not like Chrome

- No moving tabs or a group to another window (`createProperties.windowId`,
  `move({windowId})` of another window are refused).
- `groupId` only for extensions declaring `tabGroups` (above).
- `windows.get({populate})` / `getAll` tabs carry no `groupId`.
- `onCreated` of a tab that opens inside a group reports it ungrouped.
- Error texts for a pinned tab or two windows are Detour's own.

# Tests

`ExtensionTabGroupsTests` runs the API from a module worker and an extension
page: the gate both ways, a denial, create / add / ungroup, errors in promise
and callback form, decoration, `query({groupId})` with unselected tabs,
get / query / update / move, profile isolation, favourite and pinned
refusals, group events and `groupId` changes reaching both contexts, and
WebKit's own `onUpdated` carrying a group another context set.
`ExtensionTabGroupsUnitTests` covers the ids, the move index, the title
pattern and the hub's parking rules. The API Explorer's "Tab groups" section
drives it by hand.

[^task]: TASK-132.12 in Backlog.
