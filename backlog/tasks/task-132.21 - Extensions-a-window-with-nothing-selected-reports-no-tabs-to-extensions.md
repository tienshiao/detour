---
id: TASK-132.21
title: 'Extensions: a window with nothing selected reports no tabs to extensions'
status: To Do
assignee: []
created_date: '2026-10-04 00:10'
updated_date: '2026-10-04 00:30'
labels: []
dependencies:
  - TASK-132.23
  - TASK-132.12
parent_task_id: TASK-132
priority: high
ordinal: 153000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-132.2 (2026-10-03). WebKit's WebExtensionWindow::tabs() returns an empty list unless activeTab(for:) is non-nil and is one of the tabs it was given (WebExtensionWindowCocoa.mm logs 'Array returned by tabsForWebExtensionContext: does not contain the active tab' and returns {}; WebKit main does the same). The per-window list is not stored anywhere in WebKit: it is asked from the window object on every tabs.query / windows.getAll, so there is no accounting to update and no way to say 'these tabs, none active'. Detour reports no active tab when nothing is selected, a normal state (deselectAllTabs() has about ten callers: closing a selected pinned tab, unloading tiles, the empty state with live pinned tabs or favourites). In that state the window's tabs vanish from tabs.query and windows.getAll({populate: true}); by-id calls (tabs.get, tabs.getZoom) and tab events still work because WebKit's flat tab table is fed by didOpenTab/didCloseTab.

User decisions (2026-10-03): 'we should be reporting the tabs that we have', and 'if nothing is selected, we probably should not return an active tab'. Both cannot be had from WebKit directly, so the agreed approach to TRY is a masked stand-in:
- Natively, when the window (a space, once TASK-132.23 lands) has tabs and nothing selected, activeTab(for:) names a stand-in from the list so WebKit keeps the list. The stand-in answers isSelected(for:) false, so WebKit reports it active: true but highlighted: false, a combination Chrome never produces; Detour does not implement isSelected(for:) today, so WebKit falls back to isActive.
- The polyfill's chrome.tabs wrapper (built for groupId in TASK-132.12) treats active && !highlighted as the marker: it rewrites the Tab to active: false, drops it from active: true queries, and no activation is announced for it (ExtensionActiveTabTracker), so no tabs.onActivated.
- Things WebKit resolves natively against the active tab are wrapped or refused one by one: tabs.captureVisibleTab, calls that omit the tab id and mean 'the current tab' (tabs.update, tabs.reload, tabs.getZoom/setZoom, tabs.goBack/goForward, tabs.detectLanguage, scripting targets), and activeTab grants from a toolbar action or command while nothing is selected.
- Detour's own selection (selectedTabID) and what is on screen never change.

Alternatives, kept as the starting point if the masked stand-in does not hold up in testing:
1. Leave it: the window lists no tabs while nothing is selected. No work, nothing can leak; extensions that enumerate lose those tabs until something is selected, and Claude's group members in that window are absent from tabs.query.
2. Unmasked stand-in: name a stand-in and let extensions see it as active (the original direction of this task). Simplest that keeps the list; rejected because a toolbar action or an 'active tab' query then acts on a tab the user is not looking at.
3. Placeholder tab: report the empty page itself as a blank tab and name it active, which is what the user is looking at. Needs no masking and cannot leak; costs an extra tab that comes and goes (tabs.onCreated/onRemoved churn, counts off by one), a defined answer for every action on it (tabs.update opens a real tab? tabs.remove is a no-op? tabs.group refuses), and a WKWebExtensionTab that is not a BrowserTab everywhere the code assumes one.

Weak points of the chosen approach to watch in testing: the mask exists only where the polyfill runs (extension pages and workers), so anything WebKit decides natively from the active tab has to be found and wrapped; the list of default-tab calls may be incomplete; highlighted: false on an 'active' tab is visible to any context that reads tabs before the polyfill patches them.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 With nothing selected, tabs.query({}) and windows.getAll({populate: true}) list every tab the window's extensionTabs lists
- [ ] #2 A window with no tabs at all still reports an empty list and no active tab
- [ ] #3 The selected tab, the presented-Peek rule (TASK-51) and split-pane focus are reported exactly as before when something is selected
- [ ] #4 Detour's own selection (selectedTabID) and what is on screen are unchanged by the stand-in
- [ ] #5 Tests cover the nothing-selected window in a real extension context; ExtensionActiveTabTests still pass; docs/extensions.md states the rule
- [ ] #6 With nothing selected, no tab of the window is active as extensions see it: Tab objects from tabs.query, tabs.get and tab events carry active: false, and tabs.query({active: true}) returns nothing for that window
- [ ] #7 No tabs.onActivated fires for the stand-in; selecting a tab afterwards fires exactly one, for that tab
- [ ] #8 tabs.captureVisibleTab for that window is refused, and calls that default to the current tab do not read or change the stand-in
- [ ] #9 A toolbar action click or command while nothing is selected does not name the stand-in or grant activeTab on it
- [ ] #10 The stand-in choice is deterministic and documented, and the alternatives above stay recorded in the task and in docs/extensions.md
<!-- AC:END -->



## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Parked 2026-10-03 behind TASK-132.23 (space as WebKit window). The user does not want an active tab reported when nothing is selected, so the 'announce the stand-in as active' direction in the description is superseded; the candidate is a stand-in masked from extensions in the polyfill, to be confirmed in TASK-132.23.
<!-- SECTION:NOTES:END -->
