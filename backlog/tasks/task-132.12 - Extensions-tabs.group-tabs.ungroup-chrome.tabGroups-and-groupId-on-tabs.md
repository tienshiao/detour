---
id: TASK-132.12
title: 'Extensions: tabs.group, tabs.ungroup, chrome.tabGroups and groupId on tabs'
status: To Do
assignee: []
created_date: '2026-10-03 23:09'
updated_date: '2026-10-03 23:09'
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
- [ ] #1 tabs.group creates a group or adds to one and returns its id; tabs.ungroup removes tabs; both accept a single id or an array
- [ ] #2 Tab objects from tabs.get, query, create, update, getCurrent and from tabs events carry groupId (-1 when ungrouped)
- [ ] #3 tabs.query({groupId}) returns exactly the members, across the window's tabs, including unselected ones
- [ ] #4 tabGroups.get, query, update and move work, and onCreated, onUpdated, onRemoved and onMoved fire in the background context
- [ ] #5 Grouping a pinned tab, a favourite, a tab of another profile or an unknown id fails with an error and changes nothing
- [ ] #6 An extension without the tabGroups permission gets no chrome.tabGroups; tests cover positive and negative cases
- [ ] #7 The Claude extension's session group appears with its title and colour when its panel opens
- [ ] #8 API Explorer has a tab groups section
<!-- AC:END -->
