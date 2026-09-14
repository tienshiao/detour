---
id: TASK-69
title: >-
  Content blocker: the 'Block content on this site' switch does not take effect
  (or does not reflect state) — reloading still reports 12 blocked resources
status: To Do
assignee: []
created_date: '2026-09-14 03:23'
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
- [ ] #1 Turning the switch off on a site, then reloading, shows the switch off and the blocked counter at 0 for that page (verified on the techcrunch.com URL above)
- [ ] #2 Turning it back on and reloading restores blocking and a non-zero counter
- [ ] #3 The switch reflects the persisted whitelist state when the popover is reopened, after switching tabs, and after a relaunch
- [ ] #4 A unit or integration test covers the whitelist rule being applied after the block lists and the counter resetting on navigation
<!-- AC:END -->
