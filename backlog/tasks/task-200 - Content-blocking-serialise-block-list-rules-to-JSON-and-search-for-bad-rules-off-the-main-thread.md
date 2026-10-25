---
id: TASK-200
title: >-
  Content blocking: serialise block-list rules to JSON and search for bad rules
  off the main thread
status: To Do
assignee: []
created_date: '2026-10-25 08:48'
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
- [ ] #1 No rule serialisation or bad-rule search runs on the main queue; a test asserts the work happens off main (e.g. an injected queue or a main-thread assertion in the serialiser)
- [ ] #2 TASK-155/199 behaviour unchanged: the existing ContentBlocker suites pass
- [ ] #3 Checked at runtime with the TASK-199 harness's main-queue heartbeat during an upgrade recompile and a list update: no gap over 250 ms attributable to compiling
<!-- AC:END -->
