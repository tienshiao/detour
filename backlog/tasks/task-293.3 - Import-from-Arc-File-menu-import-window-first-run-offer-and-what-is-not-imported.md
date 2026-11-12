---
id: TASK-293.3
title: >-
  Import from Arc: File menu import window, first-run offer, and what is not
  imported
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-12T09:23:00Z'
labels:
  - import
dependencies:
  - TASK-293.2
parent_task_id: TASK-293
ordinal: 386000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Arc users look for an import first (most of the people who try Detour come from Arc). The window has to cover both sources from TASK-293.1 and say plainly what does not come across: logins and cookies (Arc encrypts them with a Keychain key and WebKit cannot bulk-load cookies), passwords, extensions, Easels, Notes, Boosts, Little Arc. Detour has no first-run flow yet.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 File › Import from Arc… opens a window that offers Arc on this Mac (when found) and an Arc Data Export file, lists Arc profiles with a target Detour profile each, and lets the user pick spaces and what to bring (pinned tabs and folders, favourites, Today tabs, history)
- [ ] #2 The window lists what is not imported before the import, and after it shows what was imported and what was skipped
- [ ] #3 On the first launch with no saved session, when Arc data is found, Detour offers the import once; declining never asks again
- [ ] #4 A missing or unreadable Arc install or file shows a clear message and changes nothing
- [ ] #5 Checked at runtime with /verify in an isolated profile against a copy of real Arc data and an exported file
<!-- AC:END -->
