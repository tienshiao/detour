---
id: TASK-356
title: >-
  Link Routes: Open Link in New Tab and Open Link in New Window go through Link
  Routes
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T05:53:00Z'
updated_date: '2026-11-16T08:52:00Z'
labels:
  - links
  - link-routes
dependencies: []
references:
  - TASK-191.4
  - wiki/features/link-routing-in-page.md
priority: low
type: feature
ordinal: 436000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The user's decision 2026-11-15 on TASK-191.4's unconfirmed choices. Today none of the link menu's actions are routed (linkMenuAction). The user wants the actions that open a new tab or window routed like a Cmd+click, for consistency with other browsers' link rules (Arc Air Traffic Control, Firefox Multi-Account Containers apply rules whatever opened the link). Open Link in Split View (an explicit 'next to this tab') and Open Link in Quick Detour (an explicit 'outside any space') stay unrouted. The other five TASK-191.4 choices were confirmed as built.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Open Link in New Tab and Open Link in New Window open a link that matches a route where the route says, as a Cmd+click would
- [x] #2 Open Link in Split View and Open Link in Quick Detour are never routed
- [x] #3 linkRoutingEligibility tests cover each link menu action; checked at runtime
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. LinkRoutingEligibility: InPageLinkEntry.linkMenuAction carries the action (LinkMenuAction: newTab, newWindow, splitView, quickDetour). New Tab / New Window -> routable(.linkMenuNewTab / .linkMenuNewWindow) after the web-URL and Peek checks, whatever the modifiers, gesture or host (like Cmd+click). Split View / Quick Detour -> notRouted(.linkMenuAction).
2. createWebViewWith: for any pending link-menu action, ask the rule (routedDecision with entry .linkMenuAction(action)); a decision -> openRoutedLink (cancelled, opened a turn later, selected with its window in front, as a routed Cmd+click) and return nil; otherwise the action's code as before. No Peek anchor intercept for menu actions (as before).
3. Tests: LinkRoutingEligibilityTests per action (+ Peek, non-web, same host, no gesture, with the resolver); InPageLinkRoutingTests drive the menu path with a pending contextMenuLinkAction + window.open: New Tab / New Window routed to Work, unrouted New Tab here, Split View and Quick Detour not routed with a matching route.
4. /verify: loopback page + route, endpoint right click -> choose_menu_item for each of the four items.
5. Wiki link-routing-in-page (Changed -> done, exclusion row, entry table), lint, log; backlog notes; commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-16 implementation:
- The earlier estimate (one line in createWebViewWith) was short: production never built a .linkMenuAction request. InPageLinkEntry.linkMenuAction now carries LinkMenuAction (newTab, newWindow, splitView, quickDetour); the rule answers routable(.linkMenuNewTab/.linkMenuNewWindow) after the web-URL and Peek checks, whatever the host, modifiers or gesture signal; Split View and Quick Detour -> notRouted(.linkMenuAction). createWebViewWith asks the rule for any pending contextMenuLinkAction (ContextMenuLinkAction.linkMenuAction maps it) before the action's own code; a decision -> openRoutedLink (cancelled, opened one turn later, selected with its window in front, exactly the routed Cmd+click path), return nil; otherwise the action's code unchanged. No Peek anchor intercept for menu actions (as before).
- Follows from 'as a Cmd+click' (brief/AC): a routed New Window opens no window of its own unless placement would (no window on the space -> the most recent normal window switches to it). Alternative if the user wants it: a routed New Window could open a new window on the routed space (createNewWindow(showing:)).
- Link menu in a Peek's page: not routed (inPeek), as a Cmd+click in a Peek.
- TDD red check: with the createWebViewWith hunk reverted, InPageLinkRoutingTests 33 tests / 3 failures (the three routed menu tests time out; the not-routed ones pass by design). Green: LinkRoutingEligibilityTests 51/0, InPageLinkRoutingTests 33/0, OpenInQuickDetourMenuTests 11/0, PageOpenedWindowTests 11/0 (106 tests, 0 failures).
- Runtime (docs/harness/task356-link-menu-checks.py, endpoint, DetourVerify-356, real right click + list_menu + choose_menu_item, links window made key first): New Tab and New Window on a localhost link (route -> Work) opened in Work, selected in the Work window, which became key; no tab in Personal, no new window, the links window kept its page; Split View made a split with the page in Personal; Quick Detour opened a Quick Detour window (not quarantine); unrouted New Tab a background tab in Personal; unrouted New Window a new window. Log: exactly two 'Link routed' lines (linkMenuNewTab, linkMenuNewWindow). ALL PASS. Data dir, WebKit stores and window keys removed. Not run at runtime: a Private window's and a Peek's link menu (in-app tests cover both).

Review (/code-review medium --fix, forked): 5 findings. Fixed (separate commit, out of the ACs, easy to drop): Open Link in New Window from a Private window called createNewWindowWithURL(url) with incognito false, so the link opened in a NORMAL window on the last normal space and its profile (pre-existing, confirmed red: the new test testOpenLinkInNewWindowInAPrivateWindowOpensAPrivateWindow fails against the old line); now createNewWindowWithURL(url, incognito: isIncognito). Not checked at runtime (the endpoint does not reach Private windows by default); the in-app test covers it. Skipped: routedDecision also builds a request for Split View / Quick Detour (negligible; keeps the rule the single authority); LinkMenuAction duplicates ContextMenuLinkAction (folding them touches ~37 call sites, out of scope); the Peek test passes on the overlay alone (isPeekWebView's overlay shortcut, unchanged); the in-app tests stand window.open in for WebKit's replayed menu item (covered by the runtime check).
- After the review: LinkRoutingEligibilityTests 51/0, InPageLinkRoutingTests 34/0, LinkPlacementTests 24/0, OpenInQuickDetourMenuTests 11/0, PageOpenedWindowTests 11/0 (131 tests, 0 failures). The runtime check ran before the Private fix (it does not touch that path).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The link menu's Open Link in New Tab and Open Link in New Window now go through Link Routes like a Cmd+click: a link a route sends elsewhere opens there one turn later, selected with its window in front, and the page's tab is left alone; unrouted they open as before. Open Link in Split View and Open Link in Quick Detour, and the link menu of a Peek's page, are never routed. The rule (linkRoutingEligibility, entry .linkMenuAction(action)) is asked in createWebViewWith for every menu action. Tests: 131 in five suites pass (unit cases per action, in-app wiring, red check); runtime: real right click + menu choice through the automation endpoint for all four items on a routed link and New Tab/New Window on an unrouted one, all as expected. Also fixed from review: a Private window's Open Link in New Window opened a normal window (now a Private one). Note: a routed New Window opens no window placement would not (Cmd+click's placement).
<!-- SECTION:FINAL_SUMMARY:END -->
