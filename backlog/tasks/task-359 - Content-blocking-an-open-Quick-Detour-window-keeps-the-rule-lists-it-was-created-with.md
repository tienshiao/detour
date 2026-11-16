---
id: TASK-359
title: >-
  Content blocking: an open Quick Detour window keeps the rule lists it was
  created with
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T05:53:00Z'
updated_date: '2026-11-16T07:19:00Z'
labels:
  - content-blocking
  - quick-detour
dependencies: []
references:
  - wiki/features/content-blocking-per-site-switch.md
  - wiki/features/content-blocking-chunks.md
priority: low
type: bug
ordinal: 440000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15 while splitting wiki/features/content-blocking.md (read from the code, not run). A Quick Detour page gets its rule lists through Space.makeWebViewConfiguration(for:inSpace:), but QuickDetourWindowController does not observe .contentBlockerRulesDidChange, so a list refresh, Clear Cache & Redownload or a list switched on/off does not reach an open Quick Detour page; browser windows do re-apply. Also noted: urlhaus-filter grew from 9,605 rules (2026-10-04) to 102,775 (2026-10-26), about two thirds of the 150,000 per-list cap (chunking handles lists over it since TASK-145).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 An open Quick Detour (and quarantine) page uses the new rule lists after a refresh, a Clear Cache or a list toggle, with a test
- [x] #2 Each list's current rule count is re-measured and recorded in wiki/features/content-blocking-chunks.md
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Confirm with a failing test: a real QuickDetourWindowController (plain, and quarantine on an incognito profile); its content rule lists come from a ContentRuleStore seam (default the shared manager's) through ContentBlockerManager.ruleLists(for:in:); a private temp store holds tiny lists under the real identifiers. Post the rules-changed notification after a list toggle, a recompile, and invalidateAll + recompile; a loopback page reports which subresource loaded. Red before the observer.
2. Fix: QuickDetourWindowController observes .contentBlockerRulesDidChange and replaces its page's rule lists for the window's current profile (shared remove-and-reapply helper with BrowserWindowController, its selected-tab/ownership rule unchanged).
3. AC #2: fetch the four lists, count with a standalone swiftc build of EasyListParser (as TASK-145) and compile each through WKContentRuleListStore; record in content-blocking-chunks.md.
4. Run the new tests + ContentRuleListChunkTests + WindowCloseReleaseTests + Quick Detour window suites; /verify toggling a list with a Quick Detour open; code review; wiki; commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Premise confirmed by a failing test before the fix (QuickDetourContentBlockingTests, 3 tests, 4 failures): after ContentBlockerManager.shared.reapplyRuleLists() an open Quick Detour page still blocked the path of a list switched off ("blocked" != "loaded"), a recompiled list's old rule still blocked and its new one did not, and a quarantine page still blocked with the Private profile's list switched off. The first phase of each test (the lists the page opened with block both paths, and the window counts them) passed, so the fixture itself works.

Fix: QuickDetourWindowController observes .contentBlockerRulesDidChange and calls the new ContentBlockerManager.replaceRuleLists(on:profile:from:) (remove all, add the profile's current lists) on its page, with the window's current profile (the Private profile for a quarantine; a quarantine is the same controller, so it is covered by the same observer). BrowserWindowController.handleContentBlockerRulesChanged uses the same helper; its selected-tab/ownership rule is unchanged. Test seam: QuickDetourWindowController.contentRuleStore (defaults to the shared manager's store).

Tests (one xcodebuild run, 12 suites, 225 tests, 0 failures): QuickDetourContentBlockingTests 3, ContentRuleListChunkTests 35, ContentBlockerWhitelistTests 22, WindowCloseReleaseTests 21, QuarantineTests 25, QuarantineWindowTests 24, QuickDetourWindowTests 16, QuickDetourOpenInWindowTests 17, QuickDetourProfileSwitchWindowTests 17, QuickDetourArchiveWindowTests 11, QuickDetourExtensionTests 18, QuickDetourTitleBarTests 16.

Runtime (/verify, DETOUR_DATA_DIR=DetourVerify-359, endpoint): lists downloaded and compiled at launch; a loopback page opened with Open Link in Quick Detour requested /qd.html and /control.png but not /1pixel.php (EasyPrivacy rule); EasyPrivacy switched off for Default in Settings > Profiles, Cmd+R in the Quick Detour: /1pixel.php requested; switched back on, Cmd+R: blocked again. Not verified at runtime: a quarantine window (the endpoint reaches it only with Private access allowed; covered by the test), a refresh or Clear Cache with a Quick Detour open (covered by the recompile test).

AC #2: the four lists fetched 2026-11-15 and counted with EasyListParser built standalone (swiftc, rulesFormatVersion 3), each compiled whole through a temporary WKContentRuleListStore: easylist 73,252 (3,562 lines skipped, 48.8% of the cap), easyprivacy 56,555 (106, 37.7%), easylist-cookie 25,109 (273, 16.7%), urlhaus-filter 109,083 (1, 72.7%); no rule stripped. The Debug app on a fresh data dir recorded the same ruleCount/compiledRuleCount (easylist 73,255 from a copy fetched minutes later). Recorded in wiki/features/content-blocking-chunks.md with a trend table.

Code review (/code-review medium --fix): no correctness findings. Applied: the applyRuleLists doc comment now points to replaceRuleLists; the test fixture uses replaceRuleLists instead of its own loop. Re-run after the fixes: QuickDetourContentBlockingTests + ContentRuleListChunkTests, 38 tests, 0 failures. Skipped (out of scope, reported): browser windows still re-apply only on the selected tab's panes (background tabs with a web view keep old lists) — a store-wide pass over every live web view would cover both; the small duplicate add-loop in applyRuleLists/replaceRuleLists; the test-only contentRuleStore property.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
An open Quick Detour or quarantine window now follows content-blocking changes: on .contentBlockerRulesDidChange it replaces its page's rule lists with its current profile's (the Private profile's for a quarantine) through the new ContentBlockerManager.replaceRuleLists(on:profile:from:), which the browser window's handler now shares. The premise was confirmed by QuickDetourContentBlockingTests failing before the fix (a list switched off still blocked, a recompiled list's old rule still blocked, a quarantine ignored the Private profile's switch); green after, with 12 related suites (225 tests, 0 failures). Checked at runtime: EasyPrivacy switched off and on in Settings > Profiles with a Quick Detour open; its reload let /1pixel.php through, then blocked it again. Lists re-measured 2026-11-15 and recorded on wiki/features/content-blocking-chunks.md: easylist 73,252, easyprivacy 56,555, easylist-cookie 25,109, urlhaus-filter 109,083 (72.7% of the 150,000 cap), all compiled whole. Not verified at runtime: a quarantine window or a refresh/Clear Cache with a Quick Detour open (test-covered). Follow-up candidates: background browser tabs keep old lists until selected or rebuilt; urlhaus-filter approaching the cap.
<!-- SECTION:FINAL_SUMMARY:END -->
