---
id: TASK-380
title: >-
  Hand checks owed from the Nov 15–16 batch (trackpad swipes, signed-build
  1Password)
status: To Do
assignee:
  - '@tma'
created_date: '2026-11-16T09:55:00Z'
labels:
  - verification
dependencies: []
references:
  - wiki/tabs/back-swipe-to-opener.md
  - wiki/extensions/native-messaging.md
priority: low
type: task
ordinal: 461000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13). Things the agents could not check without the user's hands or a signed build.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 TASK-355: two-finger (WebKit) swipe back on a child's page 2, then forward: the card shows page 2; same with a three-finger back; a cross-site page 2
- [ ] #2 TASK-358: a real trackpad swipe on a child of a favourite closes it to the favourite
- [ ] #3 TASK-281: a signed build still connects 1Password's native host (only changes if com.1password.1password.json exists in Detour's own NativeMessagingHosts folder)
<!-- AC:END -->
