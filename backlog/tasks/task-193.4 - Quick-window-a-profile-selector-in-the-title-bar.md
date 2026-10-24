---
id: TASK-193.4
title: 'Little Detour: a profile selector in the title bar'
status: To Do
assignee: []
created_date: '2026-10-24 10:11'
updated_date: '2026-10-24 10:11'
labels:
  - window
  - profiles
  - feature
dependencies:
  - TASK-193.1
parent_task_id: TASK-193
priority: low
ordinal: 228000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Fourth part of TASK-193. The pill at the left of the title bar ("Default" in the screenshot) shows the quick window's profile and switches it. Switching reloads the current URL in a fresh web view on the new profile's data store (cookies and logins differ), and the Open in dropdown then offers that profile's spaces. Default profile for a new quick window: decide (the frontmost window's, the last used in a quick window, or a setting).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The pill shows the profile; choosing another reloads the page in that profile's data store
- [ ] #2 The default profile for a new quick window is decided and implemented
<!-- AC:END -->
