---
id: TASK-191.2
title: 'Air Traffic Control: send links from other apps to the routed space'
status: To Do
assignee: []
created_date: '2026-10-24 09:44'
updated_date: '2026-10-24 10:18'
labels:
  - links
  - spaces
  - feature
dependencies:
  - TASK-191.1
parent_task_id: TASK-191
priority: medium
ordinal: 220000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Second part of TASK-191. In `AppDelegate.application(_:open:)`, resolve each URL's destination space with `resolveLinkRoute` and open it there:
- a window already showing that space: open the tab there and bring that window forward;
- otherwise the most recently active normal window switches to that space (or a new window opens on it; decide, proposed: switch the most recent window, as a space switch does today);
- Most Recent Space keeps today's behaviour exactly.
Several URLs at once (multi-select open from Finder or Mail) each route on their own. Optional (decision in TASK-191): match on the sending app via the Get URL Apple Event's sender.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A link from another app matching a route opens in that route's space, in a window showing it when there is one
- [ ] #2 Unmatched links go to the Default target; Most Recent Space behaves exactly as today
- [ ] #3 Covered by a test driving application(_:open:) against a store with several spaces and windows; checked at runtime with open -a from the shell
- [ ] #4 A route with a source-app condition matches links from that app only; the sender's bundle ID is read from the Get URL Apple Event, and what macOS reports for a few senders is recorded
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-24: include the source-app condition. Read the sender of the current kAEGetURL Apple Event in application(_:open:) (NSAppleEventManager.shared().currentAppleEvent, keyAddressAttr / keySenderPIDAttr → NSRunningApplication → bundleIdentifier); a link opened with no identifiable sender (e.g. `open` from a shell) matches no source-app route. Record what macOS reports for Finder, Mail, Slack (Electron) and the shell.

2026-10-24: a link routed to Private opens as a tab in the most recent open Private window, else a new Private window; Quarantine (TASK-194) opens its own window.
<!-- SECTION:NOTES:END -->
