---
id: TASK-38
title: >-
  Tabs: Move to Space loses extension pages (rebuilds the tab in the space
  configuration)
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-13 03:21'
labels:
  - extensions
  - tabs
  - bug
dependencies: []
priority: low
ordinal: 38000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-34 work, not yet confirmed. The sidebar context menu's Move to Space appears to rebuild the moved tab with addTab(in:url:), i.e. a new web view in the destination space's configuration, instead of moving the BrowserTab. A webkit-extension:// page cannot load in a space configuration (TASK-24: extension pages must be built through TabStore.makeTab(loading:) so BrowserTab.wake uses the owning context), so moving an extension page tab is likely to give a dead tab; moving to a space of a different profile has no context for the extension at all. Also check whether ordinary tabs lose back/forward history on the move. First confirm the current behaviour with a test, then fix: within the same profile move the tab (or rebuild via makeTab(loading:) with the rehomed URL); across profiles, rebuild through the destination profile's context if the extension is enabled there, otherwise refuse the move for extension pages. Keep split groups and pinned state rules from CLAUDE.md.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A test demonstrates the current Move to Space behaviour for an ordinary tab and an extension page tab, and the finding is recorded
- [ ] #2 Moving an extension page tab to another space of the same profile keeps a loadable page; to a space of another profile it loads there if the extension is enabled in that profile, and is otherwise refused without losing the tab
- [ ] #3 Ordinary tabs keep their existing (or improved, if history loss is found) behaviour; split members and pinned entries follow the documented rules; tests cover each case
<!-- AC:END -->
