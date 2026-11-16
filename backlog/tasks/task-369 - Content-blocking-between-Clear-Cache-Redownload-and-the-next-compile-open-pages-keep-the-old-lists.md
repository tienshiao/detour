---
id: TASK-369
title: >-
  Content blocking: between Clear Cache & Redownload and the next compile, open
  pages keep the old lists
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
updated_date: '2026-11-16T17:29:00Z'
labels:
  - content-blocking
dependencies: []
references:
  - wiki/features/content-blocking-clear-cache.md
priority: low
type: bug
ordinal: 450000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-359's agent, read from the code. Clear Cache & Redownload removes the compiled lists, but nothing updates open pages until the next successful compile, so they keep the old lists attached (both window kinds).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 What open pages use between Clear Cache and the recompile is decided and recorded
- [x] #2 Pages pick up the recompiled lists when it lands
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Premise check: after TASK-368 every compile's reapplyRuleLists replaces lists on all live pages with the store's current ones. After invalidateAll a list not yet recompiled has none, so the first list to recompile (or any toggle in the gap) strips the other cleared lists from every page; offline, the pages keep the old lists only until the next rules change. New tabs in the gap get none.
2. Decision (Chosen by Claude): open pages keep a cleared list's old rules until that list compiles again; a new page opened in the gap gets them too; a list or the master switch turned off in the gap still removes it. Implemented in ContentRuleStore: invalidateAll keeps each list's chunks in memory (clearedLists) for attaching only (attachableLists(forList:)), dropped when the list's next compile records; never written to disk, never counted as compiled (Settings status, counts, isCompiled unchanged), so TASK-202's guarantee holds. ContentBlockerManager.ruleLists(for:in:) attaches through it.
3. Tests first in LivePageContentBlockingTests: clear, recompile one list → background page still blocks with the other's old rules, then that list's recompile replaces them; a fresh web view after the clear blocks with the kept lists (WebKit accepts a list whose file was removed); a list switched off in the gap stops blocking; store-level: status cleared, kept lists survive a second clear.
4. Pages pick up the recompile: the manager's compile paths post reapplyRuleLists, reaching every page (TASK-368) — covered by the recompile test and checked at runtime with Clear Cache & Redownload and a background polling tab.
5. Wiki (clear-cache 'Not handled', hub), Backlog, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Premise confirmed, and wider after TASK-368: after invalidateAll a list has no compiled chunks until its redownload compiles, so the first list's recompile (its rules change replaces every page's lists with the store's) stripped the other cleared lists from every page; a switch flipped in the gap did the same; a page opened in the gap got none. Test: after a clear and easylist's recompile, a background page no longer blocked with easyprivacy (failed before the change).
Chosen by Claude (not yet confirmed by the user): until a cleared list compiles again, open pages and pages opened in the gap keep blocking with its old rules (ContentRuleStore.invalidateAll keeps the removed chunks in memory, clearedLists; attachableLists(forList:) gives them for a list with no compiled chunk; the list's next compile drops them). Only for attaching: isCompiled, counts and Settings say cleared; nothing written; a second clear keeps the first's. A list or master switch turned off in the gap still removes them. A failed redownload (offline) leaves them in use until quit. Alternatives: drop them at the clear (pages unblocked until the recompile), or keep them on open pages only (new pages get none).
AC2: every compile path posts reapplyRuleLists on .compiled, which reaches every live page since TASK-368; the recompile replaces the kept lists (test: easyprivacy recompiled with other rules -> old rule gone, new blocks).
Tests: LivePageContentBlockingTests +3 (7 total); with QuickDetourContentBlockingTests, ContentRuleStoreThreadingTests, ContentRuleListChunkTests, ContentBlockerTests, ContentBlockerWhitelistTests: 95 tests, 0 failures.
Runtime (/verify, DetourVerify-368, endpoint, real lists): background probe tab polling /1pixel.php every 2 s; Clear Cache & Redownload clicked 09:13:21 (Settings showed 'No active rules. Updating 4 lists...'), a new probe tab opened 09:13:22; recompiles: easylist-cookie :24, easyprivacy :27, easylist :29, urlhaus-filter :45; /alive.png polled throughout from both tabs, /1pixel.php never requested. Not checked at runtime: the recompiled list's new rules replacing the kept ones (same rules at runtime; test-covered), an offline redownload.

Code review (/code-review medium --fix, forked): applied — (1) the kept-lists test now waits for WebKit's removal before opening a store on the same folder (race); (2) invalidateAll kept the snapshot from compiledLists, which a refresh still in WebKit has partly overwritten with its new chunks: it now keeps each list's last completed set (completedLists, set by a completed compile or launch look-up); new ContentRuleStoreThreadingTests.testAClearDuringARecompileKeepsTheLastCompletedLists failed with the first version and passes; (3) cachedLists' doc comment and a test comment corrected. Skipped: keeping the old rules for the rest of the session when the redownload fails (offline) — that is the recorded choice (alternative above), worth the user's eye since a user clearing to get rid of a bad rule keeps it until a successful compile or quit; the new-page test attaches through replaceRuleLists with the test's store rather than Space.makeWebViewConfiguration's shared manager (same ruleLists(for:in:) path, different store); chunkCounts entries made by lookups (no effect).
Final run: LivePageContentBlockingTests, QuickDetourContentBlockingTests, ContentRuleStoreThreadingTests, ContentRuleListChunkTests, ContentBlockerTests, ContentBlockerWhitelistTests: 96 tests, 0 failures. Runtime check above was on the first version (before the completedLists change, which only affects a clear during a running compile).

Correction to the note above: the completedLists change is not limited to a clear during a running compile — it replaced the snapshot source for every clear and added the launch look-up's entry (lookUpList fills completedLists), the path a real Clear Cache normally takes. Added ContentRuleStoreThreadingTests.testAClearAfterALaunchLookUpKeepsTheListsItFound (look-up in a relaunched store, clear, the kept lists are the found objects): ContentRuleStoreThreadingTests + LivePageContentBlockingTests 26 tests, 0 failures. Runtime rerun on the final build (DetourVerify-368, two launches so the lists came from the look-up): Clear Cache at 09:27:37, new probe tab at :38; easylist recompiled :43, easyprivacy :45; the new tab polled at :40/:42/:44 without asking for /1pixel.php. The screen locked at about :44 (timers stopped), so the background tab's part of the rerun is missing; it was seen on the first build and is test-covered.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Decided (Chosen by Claude, to confirm): between Clear Cache & Redownload and each list's recompile, pages — open ones and ones opened meanwhile — keep blocking with that list's old rules. ContentRuleStore.invalidateAll keeps each list's last completed chunks in memory for attaching only (attachableLists(forList:), used by ContentBlockerManager.ruleLists(for:in:)); the list's next compile drops them and its rules change replaces them on every page (TASK-368). Status, counts and Settings still say cleared; nothing is written, so TASK-202 holds. Before, the first list to recompile (or any switch flipped in the gap) stripped the other cleared lists from every page, and a new page got none — confirmed by failing tests. Tests: LivePageContentBlockingTests +3, ContentRuleStoreThreadingTests +1; 96 tests across the content-blocking suites, 0 failures. Runtime: a background and a newly opened tab polling EasyPrivacy's /1pixel.php never requested it through a real Clear Cache & Redownload (lists recompiled 3-24 s after the click). Open: an offline or failed redownload keeps the old rules until quit.
<!-- SECTION:FINAL_SUMMARY:END -->
