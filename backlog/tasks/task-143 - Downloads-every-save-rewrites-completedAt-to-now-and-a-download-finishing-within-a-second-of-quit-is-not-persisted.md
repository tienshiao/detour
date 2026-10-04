---
id: TASK-143
title: >-
  Downloads: every save rewrites completedAt to now, and a download finishing
  within a second of quit is not persisted
status: To Do
assignee: []
created_date: '2026-10-04 02:23'
labels: []
dependencies: []
references:
  - Detour/Browser/Downloads/DownloadManager.swift
  - wiki/features/downloads.md
priority: low
ordinal: 166000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Two defects in DownloadManager's persistence (Detour/Browser/Downloads/DownloadManager.swift), found by reading the code while correcting docs/data-model.md (TASK-140); neither has been observed at runtime.

1. saveNow() builds each DownloadRecord with `completedAt: item.state == .completed ? Date() : nil`. It runs for every non-downloading item on every debounced save, so each completed download's completedAt is overwritten with the time of the latest save instead of keeping the time the download finished. Nothing in Detour/ reads the column today (DownloadItem(record:) ignores it), so the visible effect is nil for now, but docs/data-model.md documents it as 'when download finished' and anything built on it (ordering, expiry, chrome.downloads endTime in TASK-132.17) would be wrong.

2. scheduleSave() debounces by 1 s and saveNow() is private; applicationWillTerminate only calls TabStore.shared.saveNow(). A download that completes, fails or is cancelled less than a second before the app quits is never written: after relaunch it is missing from the list (or, if it had been saved earlier in another state, shows the stale one).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 completedAt is set once, when the download reaches the completed state, and later saves leave it unchanged; a test fails before the fix
- [ ] #2 A state change pending in the debounce window is written before the app terminates; a test covers the flush
- [ ] #3 DownloadItem carries the completion time across a relaunch (loaded from the record), or the task records why the column is dropped instead
- [ ] #4 docs/data-model.md and wiki/features/downloads.md match the result
<!-- AC:END -->
