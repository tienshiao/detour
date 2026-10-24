---
id: TASK-191.4
title: 'Air Traffic Control: route typed URLs and links clicked inside Detour'
status: To Do
assignee: []
created_date: '2026-10-24 09:48'
updated_date: '2026-10-24 10:18'
labels:
  - links
  - spaces
  - feature
dependencies:
  - TASK-191.1
parent_task_id: TASK-191
priority: medium
ordinal: 222000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Fourth part of TASK-191 (scope set by the user 2026-10-24: Arc routes typed URLs and in-browser link clicks too, not only links from other apps).

**Typed URLs.** The command palette's URL submission (`paletteLoadURL`, after `AddressInputClassifier` decides it is a URL; searches are never routed) resolves the route; a match whose space is not the current one opens the URL as a new tab in that space, shown the same way as an external link (TASK-191.2: a window showing the space, else switch the window). Decide: whether the in-place mode (Cmd+L, address bar click) routes too or always navigates the current tab (proposed: Cmd+T routes; Cmd+L stays in place, since the user picked the tab).

**Links clicked in a page.** Entry points: `decidePolicyFor navigationAction` (plain clicks, Cmd+click background tabs), `createWebViewWith` (target=_blank and tab-style window.open). Proposed rules, to confirm and record:
- new-tab opens (Cmd+click, _blank, tab-style window.open) route to the matched space;
- a plain click that would navigate in place routes only when it leaves the current host; the current tab stays where it is and the link opens in the routed space;
- never routed: redirects and script-driven navigations, same-host clicks, popup-style window.open (it must keep its opener: TASK-168), Option-click splits, Shift-click Peeks, links inside a Peek, and the pinned/favourite anchor-to-Peek intercept unless the route sends the link elsewhere (decide the precedence);
- never across the Private boundary in either direction;
- a route whose target is the current space does nothing.
These rules belong in a pure function next to the resolver, tested first, rather than branching in the delegate.

Keep modifier precedence and the existing policies' order (wiki/tabs/tab-lifecycle.md, wiki/tabs/peek.md, wiki/platform/wkwebview-delegate-order.md).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A typed URL matching a route opens in the routed space (Cmd+L behaviour decided and recorded); searches are never routed
- [ ] #2 New-tab link opens and cross-host plain clicks route as decided; the excluded cases (redirects, scripts, same-host, popups with opener, Option/Shift-click, Peek contents, Private) are untouched
- [ ] #3 The click routing rule is a pure function with tests for every case above, written first
- [ ] #4 Checked at runtime with a local fixture page of links in two spaces
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-24: routes to Private apply to typed URLs and in-browser clicks too (open in the most recent Private window, else a new one); from inside a Private window, routes to normal spaces are ignored. Quarantine never applies to typed URLs or clicks.
<!-- SECTION:NOTES:END -->
