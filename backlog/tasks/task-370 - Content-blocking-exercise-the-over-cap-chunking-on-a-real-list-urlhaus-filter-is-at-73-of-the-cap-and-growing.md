---
id: TASK-370
title: >-
  Content blocking: exercise the over-cap chunking on a real list
  (urlhaus-filter is at 73% of the cap and growing)
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
updated_date: '2026-11-16T21:45:00Z'
labels:
  - content-blocking
  - tests
dependencies: []
references:
  - wiki/features/content-blocking-chunks.md
priority: low
type: task
ordinal: 451000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-359's measurement (2026-11-15): urlhaus-filter 109,083 rules, 72.7% of WebKit's 150,000-rule cap, up from 102,775 twenty days earlier. TASK-145's chunking has only run on synthetic lists.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A test (or gated measurement) compiles a real list padded past the cap through the chunk path and checks every chunk attaches
- [x] #2 The chunks page records the result
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Gated test in ContentRuleListChunkTests (TEST_RUNNER_DETOUR_REAL_LIST_CHUNKS=1): read the cached urlhaus-filter (and easylist) read-only, skip if missing; pad deterministically on both sides with ||pN.chunk-padding.invalid^$all lines so the 150,000-rule boundary falls inside the real rules (two chunks), plus one padding @@ exception for a host in the last chunk.
2. Compile through ContentRuleStore at the production cap over a temporary rule list store: every chunk compiled, cached, stored; compiledRuleCount == parsed count (nothing stripped); a fresh store's lookUpList finds every chunk.
3. Attach through ContentBlockerManager.ruleLists(for:in:) to a WKWebView: a padding probe in each chunk is blocked and reported by that chunk's identifier; the exempted probe is not blocked. Only .invalid hosts are loaded.
4. Run the leg, record list date, counts, chunk sizes, timings on wiki/features/content-blocking-chunks.md; fix the 'has not run on a real list' lines; add the env var to wiki/playbooks/build-and-test.md.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Gated legs added to ContentRuleListChunkTests (TEST_RUNNER_DETOUR_REAL_LIST_CHUNKS=1): testTheRealURLhausFilterPaddedPastTheCapBlocksFromEveryChunk and testTheRealEasyListPaddedPastTheCapBlocksFromEveryChunk. Each reads the cached list (test data directory first, else the app's; read only; skips without it), pads it on both sides with ||p<n>.chunk-padding.invalid^$all lines so the 150,000 boundary falls in the middle of the real block rules (asserted: each chunk holds real block rules; no element-hiding rule after chunk 0), adds one padding exception for a URL of a chunk-0 block rule, compiles through ContentRuleStore at the production cap into a temporary store, checks every chunk compiled/cached/stored, compiledRuleCount == parsed count (nothing stripped), a fresh store's lookUpList finds both chunks, and in a WKWebView each chunk blocks its own padding probe under its own identifier while the exempted URL is not blocked. Only .invalid hosts load.

Result 2026-11-16 (test data dir copies downloaded 2026-11-15, rulesFormatVersion 4): urlhaus-filter 109,048 real rules, padded to 205,524 = chunks 150,000 + 55,525, compiled in 7.6-8.2 s, leg 38 s; easylist 74,992 (546 carried exceptions), padded to 188,223 = 150,000 + 38,770, compiled 4.4-5.8 s, leg 17 s. Test host peak ~1.2 GB RSS (watchdog sampled). Standalone: exactly 150,000 rules compile; 150,005 fail with WebKit 'Too many rules in JSON array'.

Tests: ContentRuleListChunkTests 37 (with the gated legs on) + ContentBlockerTests 11: 48 run, 0 failures. Not verified: element hiding in a web view for the split EasyList; a real (non-padding) rule loaded in a web view (would contact a live malware/ad host) — real rules are checked by compiling them.

Code review (/code-review medium --fix, 7 findings): fixed — a negative prefix count now fails instead of trapping on the range; paddingIndex ignores the padding exception (could have been chosen as a later chunk's probe); cachedFilterListFile is one file-scope helper shared with ContentBlockerTests; wiki wording 'loaded' -> 'was not blocked'. Also added (from the review's last finding) the check that no element-hiding rule is laid out after chunk 0. Left: the real list is parsed twice (once for counts) and the big arrays live to the end of the leg — gated test, ~1.2 GB peak, kept simple.

Follow-up filed 2026-11-16: TASK-401 (a compiler warning about a weak self capture in ContentBlockerManager, reported by the lead). The wiki's build-and-test traps now say WebKit rule-list compiles fail inside the Bash sandbox.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Two gated legs of ContentRuleListChunkTests (TEST_RUNNER_DETOUR_REAL_LIST_CHUNKS=1) pad the downloaded urlhaus-filter and EasyList past WebKit's 150,000-rule cap, with the boundary inside the real rules, and run them through the app's path: ContentRuleStore compile at the production cap, a relaunch look-up, and ContentBlockerManager.ruleLists attached to a WKWebView. Both chunks of each list compiled with no rule stripped and blocked their own probe under their own identifier; a carried exception exempted a chunk-0 rule. Run 2026-11-16: urlhaus-filter 205,524 rules -> 150,000 + 55,525 (compile ~8 s), EasyList 188,223 -> 150,000 + 38,770 (~5 s), ~1.2 GB peak. Recorded on wiki/features/content-blocking-chunks.md (new section) and the env var in wiki/playbooks/build-and-test.md. 48 tests, 0 failures. Not covered: element hiding in a web view for a split list; loading a real list rule (would contact a live host).
<!-- SECTION:FINAL_SUMMARY:END -->
