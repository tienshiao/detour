---
id: TASK-200
title: >-
  Content blocking: serialise block-list rules to JSON and search for bad rules
  off the main thread
status: Done
assignee:
  - '@claude'
created_date: '2026-10-25 08:48'
updated_date: '2026-10-25 09:57'
labels:
  - content-blocker
  - performance
dependencies: []
priority: medium
ordinal: 236000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-199's runtime check (2026-10-24/25). ContentRuleStore.compileChunk turns the parsed rules into the JSON string WebKit compiles on the main queue: about 270 ms for EasyList and 200 ms for EasyPrivacy (standalone -O timings). The upgrade recompile showed three main-thread gaps of 403, 511 and 491 ms (a 100 ms heartbeat; no hang). easylist-cookie's bad-rule search, run after WebKit rejects a compile, is also driven from the main queue.

When it bites: the first launch after a rules-format change (all four lists rebuild), each list update download (about daily, possibly mid-browsing), and enabling a filter list in Settings. Predates TASK-199 (every compile serialised on main); 199 only added the one-time upgrade rebuild.

Fix direction: serialise each chunk's JSON (and run the bad-rule bisection) on a background queue, as the parse already is since TASK-199; return to the main queue only for WKContentRuleListStore compile/lookup calls if they must be there (check what WebKit requires) and to attach the lists. Keep chunk ordering and the TASK-155/199 invariants (exceptions with their rules, section order, rulesFormat recorded only after a successful compile).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 No rule serialisation or bad-rule search runs on the main queue; a test asserts the work happens off main (e.g. an injected queue or a main-thread assertion in the serialiser)
- [x] #2 TASK-155/199 behaviour unchanged: the existing ContentBlocker suites pass
- [x] #3 Checked at runtime with the TASK-199 harness's main-queue heartbeat during an upgrade recompile and a list update: no gap over 250 ms attributable to compiling
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Built (2026-10-25, Opus subagent). Queues now: reading/parsing cached text and downloads on the manager's serial parse queue (one list at a time); chunking, JSON encoding, bad-rule probes and the cleaned chunk on ContentRuleStore's serial work queue (injectable, debug check not-on-main); WKContentRuleListStore compile/lookup/remove, state recording (ETag, lastFetch, counts, rulesFormat, refreshing set) and attaching lists on main. WebKit: WKContentRuleListStore is main-actor (every call asserts RunLoop::isMain and completes on main); its compile parses the JSON synchronously on the caller to validate selectors (34 of 13,620 main samples across a four-list recompile), then compiles bytecode on its own queue. compile() is per-list FIFO (waitingCompiles); FilterListCompileOrder tickets, taken on main when text is chosen, drop a compile superseded by newer text. Also fixed: the refreshingIdentifiers data race.

TDD: ContentRuleStoreThreadingTests red 5 of 9 failing (the 4 passing are byte-identity guards and two orderings that already held), green 9/9.

/code-review --fix: no deadlocks or lost completions; rulesFormat still recorded only after a successful compile; tickets ordered correctly against the 199 launch recompile and refreshIfNeeded. 4 fixed (encoded JSON no longer retained through WebKit's compile; offMain helper reused; takeTicket() lost a dead parameter; the different-lists test asserts real independence). Then by hand: parsing moved from the concurrent global utility queue to one serial parse queue (review finding 3: Clear Cache & Redownload or the upgrade recompile held four lists' parse results at once); a missing cache file is checked on main before queueing, so its fallback download no longer waits 5-8 s behind other parses. Skipped and filed: Clear Cache & Redownload undone by an in-flight compile (TASK-202, pre-existing); the unreachable drop branch not clearing refreshingIdentifiers (folded into TASK-202); per-list serial parse instead of tickets (architectural). Found and filed separately: mixed included/excluded domain cosmetic rules rejected by WebKit (TASK-201).

Tests: 100/100 after all changes (ContentRuleStoreThreadingTests 9, ContentBlockerExceptionTests 23, ContentBlockerTests 11 compiling the four real lists, ContentRuleListChunkTests 35, ContentBlockerWhitelistTests 22).

Runtime (docs/harness/task200-harness.patch: 199's URLProtocol list server, 100 ms main-queue heartbeat, isolated defaults; load average 18-75): before (red build) the upgrade recompile showed gaps of 486/515/527 ms and the list update 571/361 ms during compiles; after, no gap over 250 ms attributable to compiling in three serial upgrade runs, the update and a relaunch: the remaining gaps are at launch (433-628 ms, present with no compile) and when the harness opens its first tab (253-287 ms; sample shows tab creation, no encoder/parser frames on main); one 285 ms gap in one upgrade run fell during easylist's WebKit compile (WebKit's own main-thread selector validation). Parses never overlap (each starts 1-3 ms after the previous ends). All four lists reach rulesFormat 2 in 14.8-18.6 s (concurrent parsing 13.5 s; 199: ~16 s). Peak footprint during the upgrade 268-283 MB serial vs 361 MB concurrent. Blocking unchanged (127.0.0.1/localhost blocked, .ad-slot shown; lvh.me blocked and hidden); rule counts unchanged. Not verified at runtime: the final missing-cache short-circuit (unit suites pass; it calls the same onMiss fallback the harness exercised), a signed/Release build, real list hosts, enabling a filter list in Settings, the stale-ticket drop (unit tests only).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Block-list compiles no longer stall the main thread: parsing runs on one serial background queue (one list at a time, ~90 MB lower peak), rule serialisation and the bad-rule search on the rule store's work queue, and only WebKit's own store calls stay on main, ordered per list with tickets so older text never replaces newer. Upgrade and list-update recompiles show no main-thread gap over 250 ms. 100 tests pass.
<!-- SECTION:FINAL_SUMMARY:END -->
