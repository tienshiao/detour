---
id: TASK-160
title: >-
  Session: a session save that fails for a reason that is not a row (full disk,
  I/O error) tells the user once
status: To Do
assignee: []
created_date: '2026-10-04 18:40'
labels:
  - bug
dependencies: []
references:
  - Detour/Browser/TabStore.swift
  - Detour/Browser/Shared/ToastView.swift
  - wiki/architecture/persistence.md
priority: low
ordinal: 183000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up to TASK-154, filed 2026-10-04. The user accepted TASK-154 without this and asked for it as its own task.

Since TASK-154, TabStore.saveNow() returns a SessionSaveOutcome and keeps it in lastSaveOutcome. A row the database refuses costs only the unit holding it (.savedExcept). Any other error (disk full, I/O error, locked or damaged file) is .failed(reason): nothing is written, the database keeps the last good save, and the only trace is an error-level log line and lastSaveOutcome. If that failure repeats, every debounced save and the save at termination fail the same way, and the user quits and loses every session change since the last good save without having been told.

Tell the user once, with a toast (ToastView, Detour/Browser/Shared/ToastView.swift), when a save ends in .failed. TASK-154 did not add it because TabStore has no UI seam: this needs a way for a window to learn the outcome (a TabStoreObserver callback or equivalent) and window code to show the toast.

To decide here: which window shows it (the key window, every window); whether .savedExcept is also worth a message (TASK-154 decided no: the user loses at most the changes to one space and there is nothing the message could tell them to do); what happens when the failing save is the one at termination, where a toast cannot be seen.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 When a session save ends in .failed, the user sees one toast saying that changes to tabs and spaces are not being saved
- [ ] #2 The toast is shown once per run of failures: further failing saves do not repeat it, and after a save succeeds a later failure shows it again; a test with an injected non-row failure (the SQLITE_FULL seam of SessionSaveAtomicityTests) covers the rule, with the clock and save trigger under the test's control
- [ ] #3 The task records the decisions: which window shows the toast, whether .savedExcept shows anything, and what a failing save at termination does
- [ ] #4 The toast is checked in the running app with /verify (a save made to fail in an isolated profile), and what it looks like is recorded
- [ ] #5 wiki/architecture/persistence.md is updated
<!-- AC:END -->
