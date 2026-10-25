---
id: TASK-199
title: >-
  Content blocking: $generichide / $elemhide exceptions compile to
  ignore-previous-rules and unblock all loads on those hosts
status: Done
assignee:
  - '@claude'
created_date: '2026-10-25 00:17'
updated_date: '2026-10-25 03:52'
labels:
  - bug
  - content-blocker
dependencies: []
priority: medium
ordinal: 235000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-195 subagent 2026-10-24 (recorded as a gotcha in wiki/features/content-blocking.md). EasyListParser turns $generichide and $elemhide exception rules into a plain ignore-previous-rules action, which in WebKit's content blocker cancels ALL earlier block rules for matching loads, not just element hiding. EasyList's own exceptions (@@://127.0.0.1$generichide, @@://localhost:$generichide, @@://192.168.$generichide, @@||accounts.google.com^$generichide, ...) therefore switch network blocking off entirely on those hosts. Seen at runtime: a page on 127.0.0.1 loading /jquery.popunder.js (blocked by a generic rule) was not blocked; the same page via lvh.me was.

Fix direction: these options only affect cosmetic (css-display-none) rules. Either drop such exceptions from the network rule set and apply them only to cosmetic rules (WebKit has no per-rule cosmetic exception, so likely: skip generic cosmetic rules for those domains via unless-domain / if-domain on the cosmetic rules, or ignore the option), or skip them. Check $document, $elemhide, $generichide, $specifichide handling together. Mind TASK-155 (chunked lists: exceptions must sit in the same chunk as the rules they cancel).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A $generichide / $elemhide exception no longer cancels network block rules for its hosts; a test with a generic block rule and such an exception proves it
- [x] #2 Cosmetic behaviour of those exceptions decided and recorded (applied correctly, or deliberately ignored)
- [x] #3 Checked at runtime: a page on 127.0.0.1 or localhost loading a generically blocked resource is blocked
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Built (2026-10-24, Opus subagents). WebKit facts (source, then a real web view): rule lists are evaluated independently; ignore-previous-rules drops every earlier action of its own list for a matching load; unconditioned generic .* hiding before a list's first exception is merged into one shared stylesheet added by any load that didn't hit an exception, so a document-only exception can't keep generic hiding off (the old exceptions didn't even do that: .generic-ad stayed hidden on 127.0.0.1).

Chosen: reorder each list into sections: generic hiding, $generichide exceptions, specific hiding, $elemhide exceptions, block rules, network exceptions, $document allowlists, $important block rules (last, so no exception undoes them). Cosmetic exceptions are page-wide (url-filter .* + if-top-url from the rule's pattern, or if-domain for pattern-less domain= rules), so they only undo the hiding before them. $document also gets a page-wide exception. Network exceptions now apply wherever they stood in the file (also resolves TASK-155 review note 1). Dropped: $genericblock/$specifichide (absent), popup/websocket/webrtc/ping/csp-only exceptions (42 $popup ones like @@||accounts.google.com^$popup used to unblock all loads), redirect/rewrite/CSP-only exceptions; $badfilter cancels its target; $elemhide checked before $generichide. Rejected: unless-domain on generic rules (easylist 30.6 -> 76.8 MB, compile 3.7 -> 14.9 s, loses the shared stylesheet, can't express non-domain patterns); dropping the exceptions (generic hiding would break GitHub, Google Docs, YouTube...); a separate hiding list (works, doubles chunk bookkeeping). Known limits (wiki): hiding section must fit one chunk; a split list's carried exceptions come after $important; a page-wide exception with both a pattern and domain= keeps only the pattern; a partially failed chunked compile records the new format.

Upgrade: EasyListParser.rulesFormatVersion = 2 recorded per list (ContentBlocker.<id>.rulesFormat); a missing or different format recompiles from cached text at launch (parse on a background queue, compile on main), the fallback fetch for a missing cache is unconditional (a 304 can't leave an old list attached), and refreshIfNeeded runs after the cache compile.

TDD: ContentBlockerExceptionTests red 16 of 18 failing (37 assertions); green; 4 more tests from the review ($important, $badfilter, elemhide precedence, redirect/CSP exceptions).

/code-review --fix: 10 findings, 6 fixed ($important losing to exceptions after the reorder; $badfilter ignored; fallback fetch 304 leaving old lists; ~190k-line parse on the main thread at upgrade; no update check on the upgrade launch; elemhide/generichide precedence; redirect/CSP exceptions). Skipped as known limits: hiding across a chunk boundary, mixed-format chunks after a partial failure, pattern + domain= page-wide exceptions.

Tests after review: 113/113 (ContentBlockerExceptionTests 23, ContentBlockerTests 11 compiling the four real lists, ContentRuleListChunkTests 35, ContentBlockerWhitelistTests 22, SiteSettingsStoreTests 11, AutomaticPictureInPictureTests 11).

Runtime (docs/harness/task199-harness.patch; list URLs served by a URLProtocol from local files; isolated defaults suite): run 1 (old compiled lists) reproduces: 127.0.0.1 and localhost unblocked, lvh.me blocked; run 2 (upgrade) recompiles all four to format 2 in ~16 s, the missing-cache list fetched without conditional headers (200) and compiled, the stale list's refresh started after its cache compile, 127.0.0.1 and localhost now blocked (.ad-slot shown there by $generichide), lvh.me still blocked and hidden; run 3 reuses the lists with no recompile or fetch. Main thread: no hang; three 0.4-0.5 s gaps during the recompile from ContentRuleStore.compileChunk serialising rules to JSON on the main queue (pre-existing, recorded in the wiki). Not verified: real list hosts, a signed build, real sites at runtime (covered by the evaluator test over the real EasyList).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
EasyList $generichide/$elemhide exceptions no longer switch off network blocking: lists are compiled in sections so cosmetic exceptions only undo hiding and every exception sits where EasyList semantics put it ($important still wins, $badfilter cancels its target, popup/CSP-only exceptions dropped). Existing installs recompile once at launch, off the main thread for parsing. 127.0.0.1 and localhost are blocked again. 113 tests pass; runtime upgrade path verified.
<!-- SECTION:FINAL_SUMMARY:END -->
