---
id: TASK-69
title: >-
  Content blocker: the 'Block content on this site' switch does not take effect
  (or does not reflect state) — reloading still reports 12 blocked resources
status: Done
assignee:
  - '@claude'
created_date: '2026-09-14 03:23'
updated_date: '2026-09-14 06:29'
labels:
  - content-blocker
  - bug
dependencies: []
references:
  - Detour/Browser/Sidebar/SettingsPopoverViewController.swift
  - Detour/Browser/ContentBlocker/ContentBlockerWhitelist.swift
  - Detour/Browser/ContentBlocker/ContentBlockerManager.swift
  - Detour/Browser/ContentBlocker/BlockedResourceTracker.swift
  - Detour/Browser/Window/BrowserWindowController.swift
priority: high
ordinal: 69000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported 2026-09-13 on https://techcrunch.com/2026/09/12/automattic-confirms-mullenweg-has-returned-as-ceo-after-attempted-ouster-by-board/ : in the settings popover the user turned 'Block content on this site' off and reloaded the page, but the popover's counter still showed '12 resources blocked'. It is not yet known whether the switch fails to change the state (whitelist entry / recompiled 'ignore-previous-rules' list not applied to the tab's web view), or the state is applied but the switch and counter misreport it, or the counter (BlockedResourceTracker's user script, which posts a count via the 'blockedCount' script message handler) counts something other than rule-list blocks (e.g. resources failed for other reasons, or a stale count that survives the reload). Mechanics to check: SettingsPopoverViewController's toggle calls ContentBlockerWhitelist.toggleHost (per-profile host set persisted in AppDatabase, then recompileWhitelistRules compiles one 'ignore-previous-rules' list with if-domain *host), and the .contentBlockerRulesDidChange notification makes BrowserWindowController.handleContentBlockerRulesChanged remove and re-add rule lists on the selected owned tab's panes via ContentBlockerManager.applyRuleLists — verify the whitelist list is added after the block lists (order matters for ignore-previous-rules), that the host key matches the page's host (www. vs bare domain, subresources on other hosts are ignored by if-domain of the top document), that the notification reaches the window that owns the web view, and that BrowserTab.blockedCount is reset on reload (BrowserTab.swift lines ~767/812) rather than carrying the previous page's count.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Turning the switch off on a site, then reloading, shows the switch off and the blocked counter at 0 for that page (verified on the techcrunch.com URL above)
- [x] #2 Turning it back on and reloading restores blocking and a non-zero counter
- [x] #3 The switch reflects the persisted whitelist state when the popover is reopened, after switching tabs, and after a relaunch
- [x] #4 A unit or integration test covers the whitelist rule being applied after the block lists and the counter resetting on navigation
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Replace the whitelist rule list with WebKit's per-navigation switch: implement decidePolicyFor(navigationAction, preferences) and, for main-frame navigations to a whitelisted host (exact host or subdomain of a stored host, via a pure decision helper shared with tests), call the private -[WKWebpagePreferences _setContentBlockersEnabled:NO] through an @objc protocol shim (guarded by respondsToSelector, log an error otherwise). Delete recompileWhitelistRules/getWhitelistRuleList and the whitelist compile in ContentBlockerManager.applyRuleLists/initialize; keep the persisted per-profile host set.
2. Replace BlockedResourceTracker's error-event heuristic with the private navigation delegate callback @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:) on BrowserWindowController: increment tab(owning: webView).blockedCount when the action's blockedLoad (KVC) is true. Remove the user script, the blockedCount script message handler branch and its handler name.
3. Popover: isWhitelisted uses the same helper (subdomain-aware); toggleHost removes every entry covering the host when turning blocking back on; after a toggle reload the display tab so the change takes effect (Safari behaviour) — reapplyRuleLists is no longer needed for the whitelist.
4. Tests (ContentBlockerTests + a new integration test): decision helper cases (exact, subdomain, unrelated, empty host); a WKWebView with a compiled block list and loadHTMLString(baseURL: http://site.example) referencing http://blocked.example/x.png gets exactly one blockedLoad callback with blocking on and none when the navigation preferences disable content blockers via the shared helper; BrowserTab.blockedCount resets in didCommitNavigation and load().
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Root cause (2026-09-13, from WebKit source ContentExtensionsBackend.cpp): ignore-previous-rules only cancels rules in the SAME rule list — actionsFromContentRuleList is evaluated per list and the Block results of every list are merged, so a separate 'whitelist' list can never un-block EasyList's blocks; list order is irrelevant. The switch was therefore a no-op. Second defect: BlockedResourceTracker counts every element 'error' event (any failed IMG/SCRIPT/... load), not rule-list blocks, so the counter stays non-zero on pages whose third-party loads fail for other reasons.

Implemented (commit 8e2f303): the whitelist rule list is gone; whitelisted main-frame navigations get -[WKWebpagePreferences _setContentBlockersEnabled:NO] from decidePolicyFor:preferences: (ContentBlockerManager.configure), subdomain-aware ContentBlockerWhitelist.covers/entriesCovering, toggleHost removes every covering entry and the popover reloads the tab. The counter now comes from the private navigation delegate callback _webView:contentRuleListWithIdentifier:performedAction:forURL: (blockedLoad) via tab(owning:), so peek and split panes are covered; BlockedResourceTracker and its script handler are deleted. Tests: ContentBlockerWhitelistTests (16) incl. a real WKWebView proving one blockedLoad callback with blocking on and none when the host is whitelisted; both SPI selectors verified present on macOS 26.6.2.

Review fixes (2026-09-13): tab-owned navigation delegate for background-opened tabs, profile from the navigating tab not the window's active space, per-URL dedupe of blocked-load callbacks (WebKit fires once per list), responds(to:) guard on the SPI KVC, reload of every covered pane on toggle, retired whitelist rule lists removed at startup, UA spoof applied to the navigating tab. docs/content-blocking.md rewritten for the new mechanism.

Closed 2026-09-13: manual check of the switch on the techcrunch.com page (off → reload shows off and 0 blocked; on → blocking and a non-zero count return; state persists across popover reopen, tab switch and relaunch) confirmed by the user on the signed build from commit a68e26e.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Root cause: WebKit evaluates each WKContentRuleList independently, so the separate ignore-previous-rules whitelist list never cancelled EasyList's blocks, and the counter was an error-event heuristic counting every failed load. Fix: the per-site switch now disables content blockers per main-frame navigation via -[WKWebpagePreferences _setContentBlockersEnabled:] (window delegate, and the tab itself for unclaimed web views), the whitelist is a subdomain-aware persisted host set, toggling reloads the affected panes, and the counter comes from WebKit's per-list blocked-load callback deduplicated per URL. Verified by ContentBlockerWhitelistTests (18, incl. a real WKWebView proving one blockedLoad callback with blocking on and none when whitelisted) and ContentBlockerTests (11). AC#1-#3 await a manual check on the techcrunch URL.
<!-- SECTION:FINAL_SUMMARY:END -->
