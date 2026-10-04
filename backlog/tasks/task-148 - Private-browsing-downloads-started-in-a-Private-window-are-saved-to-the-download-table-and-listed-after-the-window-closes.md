---
id: TASK-148
title: >-
  Private browsing: downloads started in a Private window are saved to the
  download table and listed after the window closes
status: To Do
assignee: []
created_date: '2026-10-04 02:29'
labels: []
dependencies: []
references:
  - Detour/Browser/Downloads/DownloadManager.swift
  - wiki/architecture/incognito.md
priority: medium
ordinal: 171000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
DownloadManager (Detour/Browser/Downloads/) has no notion of incognito: nothing in the directory checks the profile or space a download came from. A download started in a Private window is added to the shared list, shown in every window's downloads popover, and written to the download table in browser.db (filename, source URL, destination path) by the debounced save, so it is still listed after the Private window closes and after a relaunch. Private browsing otherwise records no history and discards its data store on window close (wiki/architecture/incognito.md).

Read from the code while writing wiki/architecture/incognito.md; not observed. The downloaded file itself staying on disk is expected (as in other browsers); the question is the record. Decide the intended behaviour first: Safari and Chrome both keep the file and drop the list entry when the private session ends.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The intended behaviour is decided and recorded in the task (for example: listed while the Private window is open, never written to browser.db, removed from the list when the window closes)
- [ ] #2 A download from a Private window leaves no row in the download table, verified by a test that fails before the fix; downloads from normal windows are unaffected
- [ ] #3 A Private download is not shown in other windows' popovers if the decision says so
- [ ] #4 wiki/architecture/incognito.md and wiki/features/downloads.md are updated
<!-- AC:END -->
