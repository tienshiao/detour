---
id: TASK-132.21
title: 'Extensions: a window with nothing selected reports no tabs to extensions'
status: To Do
assignee: []
created_date: '2026-10-04 00:10'
labels: []
dependencies: []
parent_task_id: TASK-132
priority: high
ordinal: 153000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-132.2 (2026-10-03). WebKit's WebExtensionWindow::tabs() returns an empty list unless activeTab(for:) is non-nil and is one of the tabs it was given (WebExtensionWindowCocoa.mm: 'Array returned by tabsForWebExtensionContext: does not contain the active tab', then return {}). BrowserWindowController.activeTab(for:) answers extensionActiveTab, which is nil when the window has nothing selected (a real state in Detour: everything deselected, the empty state with live pinned tabs or favourites still listed). In that state tabs.query and windows.getAll({populate: true}) report zero tabs for the window although extensionTabs lists them; tabs.getZoom(tabId) and other by-id calls still work. Extensions do not expect a window whose tabs vanish; Chrome always has exactly one active tab per window. User decision (2026-10-03): 'we should be reporting the tabs that we have.'

Direction: whenever the window's tab list is non-empty, report an active tab that is in the list. With nothing selected, report a stand-in (for example the tab most recently active in that space, else the first listed) and announce it through the same activation funnel (ExtensionActiveTabTracker) so tabs.onActivated and the active flags agree. selectedTabID itself must not change. The stand-in means active: true can name a tab the user is not looking at; note what that does to toolbar actions and activeTab grants and decide whether anything needs guarding.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 With nothing selected, tabs.query({}) and windows.getAll({populate: true}) list every tab the window's extensionTabs lists
- [ ] #2 Exactly one tab of such a window is reported active, it is one of the listed tabs, and the choice is deterministic and documented
- [ ] #3 Selecting a tab afterwards reports that tab active, with one tabs.onActivated, and the stand-in is no longer active
- [ ] #4 A window with no tabs at all still reports an empty list and no active tab
- [ ] #5 The selected tab, the presented-Peek rule (TASK-51) and split-pane focus are reported exactly as before when something is selected
- [ ] #6 Detour's own selection (selectedTabID) and what is on screen are unchanged by the stand-in
- [ ] #7 Tests cover the nothing-selected window in a real extension context; ExtensionActiveTabTests still pass; docs/extensions.md states the rule
<!-- AC:END -->
