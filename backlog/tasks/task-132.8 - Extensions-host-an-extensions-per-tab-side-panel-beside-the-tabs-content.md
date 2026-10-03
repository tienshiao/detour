---
id: TASK-132.8
title: 'Extensions: host an extension''s per-tab side panel beside the tab''s content'
status: To Do
assignee: []
created_date: '2026-10-03 23:08'
labels: []
dependencies:
  - TASK-132.1
parent_task_id: TASK-132
priority: high
ordinal: 140000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Show an extension side panel (chrome.sidePanel) as a trailing pane of the content area. The Claude extension sets a tab-specific panel (sidepanel.html?tabId=N) and opens it from its toolbar action and from the toggle-side-panel command (Cmd+E). Reuse the split view's hosting approach (frame-based NSSplitView, divider, remembered fraction; Auto Layout breaks the docked Web Inspector) but not the split-tab model: the panel is not a BrowserTab, has no sidebar row and is never selectedTabID. Whether the web view comes from WebKit's _WKWebExtensionSidebar or a Detour-built one follows the spike's decision. API surface: setOptions, getOptions, open, close, setPanelBehavior, getPanelBehavior.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Clicking the Claude toolbar action, or pressing its command shortcut, opens the panel beside the current tab; the shortcut pressed again closes it
- [ ] #2 A tab-specific panel shows only with its tab: switching tabs swaps or hides it, and switching back restores it without reloading the panel page
- [ ] #3 The panel does not appear in tabs.query, the sidebar, the Control+Tab switcher or closed-tab records, and Cmd+W closes the tab rather than the panel
- [ ] #4 A split tab with a panel shows both panes plus the panel, and the Web Inspector still docks
- [ ] #5 The divider can be dragged, has a minimum width, and the width is remembered
- [ ] #6 The user can close the panel from Detour's UI, and closing its tab or disabling the extension tears it down
- [ ] #7 A tab shown in two windows shows its panel only in the window that owns the web view
- [ ] #8 In a Private window the panel appears only when the extension is allowed in Private
- [ ] #9 An extension without the sidePanel permission gets no chrome.sidePanel; tests cover both, and API Explorer has a side panel section
<!-- AC:END -->
