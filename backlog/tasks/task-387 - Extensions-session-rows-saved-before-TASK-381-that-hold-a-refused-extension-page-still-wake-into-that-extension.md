---
id: TASK-387
title: >-
  Extensions: session rows saved before TASK-381 that hold a refused extension
  page still wake into that extension
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T21:41:00Z'
updated_date: '2026-11-16T21:41:00Z'
labels:
  - extensions
  - security
  - persistence
dependencies: []
references:
  - wiki/extensions/extension-pages.md
priority: low
type: task
ordinal: 468000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-16 during the second two-lane batch (TASK-381, its code review). TASK-381 made a page-chosen `webkit-extension://` URL that WebKit refuses never become `tab.url`, so the existing `extensionID` column (stamped from `tab.url`) is the persisted provenance: a refused page saves with no extension id and is not rebuilt into the extension's configuration at relaunch. Rows saved before that fix that hold such a refused URL (for example the tab a web page opened with `window.open('webkit-extension://<id>/options.html')`) cannot be told apart from an extension's own tab and are grandfathered: restored as before, so after a relaunch they wake into that extension's configuration and load the non-web-accessible page with its privileges. Read from code and the TASK-381 notes; not reproduced with a database from before the fix.

To decide: clean such rows on load (the review found nothing in a saved row that tells them apart, so a rule has to be found first), or accept them (a page had to do it before the update). Wiki: wiki/extensions/extension-pages.md ("Only a servable page becomes the tab's url").
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The decision (clean on load, and by which rule, or accept) is recorded in this task and on wiki/extensions/extension-pages.md
- [ ] #2 If cleaned: a test with a session row from before TASK-381 holding a non-web-accessible extension page shows it no longer loads that page after a relaunch, while an extension's own restored tabs still do
<!-- AC:END -->
