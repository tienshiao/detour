---
id: TASK-201
title: >-
  Content blocking: cosmetic rules with both included and excluded domains
  (a.example,~b.example##sel) compile to a trigger WebKit rejects
status: To Do
assignee: []
created_date: '2026-10-25 09:39'
labels:
  - bug
  - content-blocker
dependencies: []
priority: low
ordinal: 237000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-200 subagent 2026-10-25 while writing a sample list. EasyListParser gives a cosmetic rule whose domain list mixes included and excluded domains (e.g. `a.example,~b.example##.sel`) both an if-domain and an unless-domain in one trigger. WebKit allows only one such condition per trigger and rejects the rule ('more than one condition'). The bad-rule search then strips it, so the rule never applies. This may be why easylist-cookie compiles with 2 bad rules (not confirmed).

Fix direction: an included-plus-excluded list means 'on these domains, except these subdomains'. Options: emit the rule with if-domain only and add a following ignore-previous-rules-style exception (cosmetic-scoped, as TASK-199 does) for the excluded domains; or drop the excluded domains when they're not subdomains of an included one (the exclusion is then a no-op); or, when the excluded domains are subdomains of included ones, split into if-domain for the included and a whole-page cosmetic exception for the excluded. Check how network rules with $domain=a|~b are handled (same problem?). Count how many rules in the real lists are affected before and after.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Mixed included/excluded domain rules compile without WebKit rejecting them, and hide on the included domains but not the excluded ones (test with a real web view)
- [ ] #2 The number of bad rules stripped from each real list is recorded before and after; easylist-cookie's 2 explained
- [ ] #3 Network rules with mixed $domain= lists checked for the same problem
<!-- AC:END -->
