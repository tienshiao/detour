---
id: TASK-191.4
title: 'Air Traffic Control: route typed URLs and links clicked inside Detour'
status: Done
assignee: []
created_date: '2026-10-24 09:48'
updated_date: '2026-10-25 22:22'
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
- [x] #1 A typed URL matching a route opens in the routed space (Cmd+L behaviour decided and recorded); searches are never routed
- [x] #2 New-tab link opens and cross-host plain clicks route as decided; the excluded cases (redirects, scripts, same-host, popups with opener, Option/Shift-click, Peek contents, Private) are untouched
- [x] #3 The click routing rule is a pure function with tests for every case above, written first
- [x] #4 Checked at runtime with a local fixture page of links in two spaces
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-24: routes to Private apply to typed URLs and in-browser clicks too (open in the most recent Private window, else a new one); from inside a Private window, routes to normal spaces are ignored. Quarantine never applies to typed URLs or clicks.

2026-10-25 implementation:
- Pure eligibility rule (LinkRoutingEligibility.swift: linkRoutingEligibility, isSameLinkRoutingHost, inPageLinkOutcome, routedLinkDecision, typedURLIsRoutable), test-first; window glue in BrowserWindowController+LinkRouting.swift; 191.2 placement moved to AppDelegate.openLink(_:routedTo:typed:) used by all three origins.
- Routed: Cmd+click (wins over Shift/Option), target=_blank, tab-style window.open with a gesture, plain click to another host (tab stays on its page), Cmd+T typed URLs. Not routed: non-http(s), anything in or fired from a Peek, link-menu actions, popup-style window.open (keeps opener), no user gesture, server redirects, non-link-activation navigations (script location, client redirect, form, back/forward, reload), Shift-click Peek, Option-click split, subframe plain clicks, same-host clicks, Cmd+L, searches. Host comparison ignores case, trailing dot, leading www. (when a dot remains) and ports; host not site because there is no public-suffix list. A route to another destination wins over the pinned/favourite anchor-to-Peek intercept; .stay leaves the intercept as before.
- WebKit signals (standalone spike): navigationType == .linkActivated; _isUserInitiated (SPI, responds(to:) guard) false for page-timer/load-script clicks and location changes; _isRedirect (SPI) marks server redirects; synthetic MouseEvent metaKey arrives with no modifier flags. Missing SPI = every action is a gesture, nothing is a redirect.
- Decisions the brief didn't cover, defaults taken and recorded in the wiki as to confirm (user told 2026-10-25): link-menu actions not routed; Cmd+L with a Peek open routes (palette is in new-tab mode); a routed Cmd+click opens selected with its window in front; Cmd+click and _blank in iframes route; a click from an internal page to a web host is cross-host; window.open() then location= is not routed.
- Found, unchanged: on a pinned tab/favourite, a same-host link that server-redirects to another host opens in a Peek (WebKit reports the redirect as a link activation); wiki/tabs/peek.md corrected.
- TDD: red LinkRoutingEligibilityTests 40 tests / 63 failures, InPageLinkRoutingTests 21 / 19 (its not-routed cases pass red by design); green 40/0, 21/0.
- /code-review --fix: 10 findings. Fixed: routed typed URLs lost the typed flag for history (now passed through; test extended); routing work ran for every navigation, now only .linkActivated; address-bar palette with no selected tab didn't route like Cmd+T; duplicated outcome switch merged (performInPageLinkOutcome); repeated resolver call (resolveRoute); needless Optional on inPageLinkRequest. Skipped: a cross-host click to a download (Content-Disposition) is routed before the response is known, leaving an empty tab in the routed space (design change; pre-existing for Cmd+click/_blank; follow-up proposed to the user); pageURL is the provisional URL during an in-flight navigation (rare); origin space is the window's active space, not the firing tab's (needs a gesture in an unshown space); fixed 700 ms settle in negative in-app tests.
- Tests before review: 422 tests, 26 suites, 0 failures. After review fixes: 230 tests, 0 failures (LinkRoutingEligibility 40, InPageLinkRouting 21, LinkPlacement 19, ExternalLinkRouting 13, LinkRouteResolver 38, PeekAnchor 23, PeekState 11, FavoritePeekPersistence 5, SplitOpening 20, PageOpenedWindow 11, CommandPaletteFocus 4, PaletteSelection 14, TabNavigation 11).
- Runtime (docs/harness/task191-4-harness.patch, real NSApp.postEvent input, screen unlocked): every case above as expected, incl. popup keeps opener (postMessage received), redirect asked twice and landed in the tab, pinned tab route beats Peek, Private route from a normal window, routes ignored from a Private window. Trap: plain clicks posted to an inactive app are swallowed (Cmd-clicks aren't); harness activates Detour first. Runtime ran before the review fixes; not re-run after them. Not verified: favourite tabs, split panes, iframe links, History page links, real sites.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Typed URLs (Cmd+T) and links clicked in a page now follow Air Traffic Control: new-tab opens (Cmd+click, _blank, tab-style window.open) and plain clicks to another host open in the routed space, leaving the current tab on its page; same-host clicks, redirects, scripts, popups, Option/Shift-click, Peek contents, Cmd+L and searches are untouched, and nothing routes out of a Private window. The rule is a pure, tested function; 230 tests pass after review fixes; every case checked at runtime with real input. Known gap: a routed click that turns into a download leaves an empty tab.
<!-- SECTION:FINAL_SUMMARY:END -->
