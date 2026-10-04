---
id: TASK-156
title: >-
  Downloads: a Private window's download that is still running when the window
  closes cannot be seen or cancelled
status: To Do
assignee: []
created_date: '2026-10-04 09:14'
labels: []
dependencies: []
references:
  - Detour/Browser/Downloads/DownloadManager.swift
  - wiki/features/downloads.md
priority: low
ordinal: 179000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follows from the rule chosen in TASK-148 (2026-10-04), raised by the code review of the batch as a behaviour to confirm.

A Private window's downloads are listed only in that window and are dropped from the list when it closes. One that is still in flight then moves to DownloadManager.unlistedItems: it keeps transferring and writing to ~/Downloads, no window lists or badges it, and nothing can cancel it short of quitting the app. Chrome asks before closing an incognito window with downloads in progress and cancels them if the user goes ahead; Safari keeps them listed.

Also not verified in TASK-148: whether WebKit keeps a real WKDownload transferring once the web view and non-persistent data store that started it are gone (the tests use manual items).

Decide the behaviour first: cancel on close (with or without a prompt), keep running but reachable somewhere, or keep today's rule.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The intended behaviour for a Private download in flight at window close is decided and recorded in the task
- [ ] #2 What WebKit does with a real WKDownload after its Private window closes is measured (local fixture server) and recorded
- [ ] #3 The decided behaviour is implemented with tests that fail before it; no download keeps running with no way for the user to see or stop it, unless the decision says so explicitly
- [ ] #4 wiki/features/downloads.md and wiki/architecture/incognito.md are updated
<!-- AC:END -->
