---
id: TASK-303
title: >-
  1Password: does it connect in Detour on a Mac where Chrome was never
  installed?
status: To Do
assignee: []
created_date: '2026-11-08T09:35:00Z'
labels:
  - extensions
  - 1password
  - investigation
dependencies: []
references:
  - TASK-292.8
priority: medium
ordinal: 364000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Detour finds a native messaging host by its manifest in four places (NativeMessagingHost.swift ~88-93): ~/Library/Application Support/Google/Chrome/NativeMessagingHosts, …/Chromium/NativeMessagingHosts, …/Detour/NativeMessagingHosts, and /Library/Google/Chrome/NativeMessagingHosts. 1Password works in Detour because the 1Password desktop app writes com.1password.1password.json into Chrome's folder. Nobody has checked whether 1Password writes that file when Chrome is not (and never was) installed. If it doesn't, the extension installs but never reaches the desktop app on such a Mac, and the website's Web Extensions page ("1Password works", TASK-292.8) is wrong for those people. Raised while writing that page (Nov 8 2026).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Determined on a Mac (or clean user account / VM) with no Chrome or Chromium ever installed: whether the 1Password desktop app writes a native messaging manifest anywhere Detour looks, and what Detour shows when it doesn't
- [ ] #2 If it doesn't: a fix is agreed with the user (for example Detour installing or linking the manifest into its own NativeMessagingHosts folder, or a clear in-app explanation), filed as its own task
- [ ] #3 The website's Web Extensions page states the requirement accurately
<!-- AC:END -->
