---
id: TASK-208
title: >-
  Peek: same-site links that redirect to another site open in a Peek on pinned
  tabs
status: To Do
assignee: []
created_date: '2026-10-26 04:22'
labels:
  - peek
  - question
dependencies: []
priority: low
ordinal: 244000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in TASK-191.4. On a pinned tab or favourite, a same-host link whose server redirect goes to another host opens the redirect target in a Peek, because WebKit asks the policy again for the redirect with the click's link-activation type and gesture (_isRedirect is the only marker). wiki/tabs/peek.md used to claim redirects stay in place; it now describes the actual behaviour. Decide whether this is wanted (the user ended up off the pinned site) or whether redirects of a same-host click should stay in the tab, and implement the decision.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The behaviour for a same-host click that redirects off-site on a pinned tab or favourite is decided and recorded
- [ ] #2 If changed: covered by a PeekAnchor test and checked at runtime with a loopback redirect
<!-- AC:END -->
