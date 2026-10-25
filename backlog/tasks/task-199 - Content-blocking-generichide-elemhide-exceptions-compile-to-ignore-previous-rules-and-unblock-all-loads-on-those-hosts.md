---
id: TASK-199
title: >-
  Content blocking: $generichide / $elemhide exceptions compile to
  ignore-previous-rules and unblock all loads on those hosts
status: To Do
assignee: []
created_date: '2026-10-25 00:17'
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
- [ ] #1 A $generichide / $elemhide exception no longer cancels network block rules for its hosts; a test with a generic block rule and such an exception proves it
- [ ] #2 Cosmetic behaviour of those exceptions decided and recorded (applied correctly, or deliberately ignored)
- [ ] #3 Checked at runtime: a page on 127.0.0.1 or localhost loading a generically blocked resource is blocked
<!-- AC:END -->
