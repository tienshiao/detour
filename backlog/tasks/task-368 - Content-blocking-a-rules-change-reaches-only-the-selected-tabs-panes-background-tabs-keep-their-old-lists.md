---
id: TASK-368
title: >-
  Content blocking: a rules change reaches only the selected tab's panes;
  background tabs keep their old lists
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
updated_date: '2026-11-16T17:06:00Z'
labels:
  - content-blocking
dependencies: []
references:
  - wiki/features/content-blocking.md
priority: low
type: bug
ordinal: 449000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-359's agent. BrowserWindowController.handleContentBlockerRulesChanged updates only the selected tab's panes (in the window that owns the web view). A background tab that already has a web view keeps its old rule lists until it is selected during a later change or its web view is rebuilt. One pass over every live web view (ContentBlockerManager.replaceRuleLists) would fix both window kinds.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 After a list refresh, toggle or Clear Cache, every live web view (all tabs, Quick Detour, quarantine) uses the new lists
- [x] #2 A test covers a background tab
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Move the rules-change pass from BrowserWindowController (selected panes of the owning window only) to TabStore: one pass over every live web view of the spaces (tabs, pinned backing tabs, their Peeks) and the favourites (and their Peeks), each with its space's/profile's lists (ContentBlockerManager.replaceRuleLists). TabStore.shared observes .contentBlockerRulesDidChange; its contentRuleStore is injectable for tests. A web view exists once whatever window shows it, so no ownership check and no double apply; remove the window's handler.
2. Quick Detour / quarantine pages stay with their window's observer (TASK-359, injectable store); the pass skips them so nothing is applied twice.
3. Skip web views built from an extension context's configuration (servedExtensionOriginHost): they never got lists at creation, and that configuration's controller is the extension's.
4. Tests first (real window, loopback fixture fetching two paths): a background tab, a background split pair, a background tab's Peek, a pinned tab follow a toggle and a recompile without being selected; another profile's tab keeps its own lists; enumeration test (favourite included; sleeping, Quick Detour and extension tabs excluded).
5. /verify: a background tab polling the fixture server; toggle a list in Settings > Profiles; server log shows the blocked path stops/starts being requested before the tab is selected.
6. Wiki (content-blocking hub table), Backlog notes, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented: the pass moved from BrowserWindowController.handleContentBlockerRulesChanged (removed; it reached only the selected tab's panes of the owning window) to TabStore (TabStore+ContentBlocking.swift): contentBlockingPages lists every live web view of the spaces (tabs, pinned backing tabs) and favourites, plus their Peeks, each with its space's/profile's lists, deduplicated by web view; replaceContentRuleListsOnLivePages runs ContentBlockerManager.replaceRuleLists on each; only TabStore.shared observes .contentBlockerRulesDidChange. TabStore.contentRuleStore is injectable (tests).
Chosen by Claude (not yet confirmed by the user): Quick Detour and quarantine pages stay with their window's observer (TASK-359) and the store's pass skips them (no double apply); alternative: fold them into the store's pass and drop the window observer.
Chosen by Claude (not yet confirmed by the user): a web view built from an extension context's configuration (servedExtensionOriginHost != nil) is left alone, as it got no lists at creation and its controller is the extension's; the old handler did replace a selected one's lists. Alternative: give it its profile's lists too.
Tests: LivePageContentBlockingTests (new, 4): failed before the fix for every page but the selected one (switched-off list, recompiled list, other profile's tab); green after. With QuickDetourContentBlockingTests + ContentBlockerWhitelistTests: 29 tests, 0 failures.
Runtime (/verify, DETOUR_DATA_DIR=DetourVerify-368, endpoint): real lists downloaded and compiled; a loopback page polling /alive.png and EasyPrivacy's /1pixel.php every 2 s opened, then a second tab selected over it; the server saw /alive.png only. EasyPrivacy switched off for Default in Settings > Profiles (09:03:21): /1pixel.php requested from the next poll (09:03:29) on, the other tab still selected; switched back on (09:03:42): /1pixel.php no longer requested. Not checked at runtime: a Peek, split pair, pinned or favourite tab (test-covered except favourites, which the enumeration test covers), a refresh or Clear Cache recompile.

Code review (/code-review medium --fix, forked): no correctness findings. Applied: stale descriptions of the old window handler in docs/content-blocking.md, docs/architecture.md, wiki/architecture/overview.md, wiki/features/quick-detour-window.md. Skipped: folding Quick Detour pages into the store pass (changes TASK-359's design; recorded above as a provisional choice), reusing allLiveTabs (it carries no profile per tab), caching ruleLists per profile (negligible gain). Docs-only changes after the test run, so tests not rerun.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A rules change (a list switched on or off, a refresh, Clear Cache's recompile) now replaces the rule lists on every live web view of the spaces and favourites — background tabs, pinned tabs, split pairs, Peeks — through one pass in TabStore (replaceContentRuleListsOnLivePages over contentBlockingPages), instead of the owning browser window's selected panes only; the window handler is gone. Quick Detour and quarantine pages keep their window's observer (TASK-359), so nothing is applied twice; extension-configuration pages and sleeping tabs are left out (Claude's choices, to confirm). LivePageContentBlockingTests (4) failed before the fix for every page but the selected one and pass after (29 tests with the related suites, 0 failures). Runtime: a background tab polling a loopback server asked for EasyPrivacy's /1pixel.php from its first poll after the list was switched off in Settings > Profiles and stopped once it was back on, never selected.
<!-- SECTION:FINAL_SUMMARY:END -->
