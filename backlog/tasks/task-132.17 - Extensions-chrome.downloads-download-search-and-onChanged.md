---
id: TASK-132.17
title: 'Extensions: chrome.downloads download, search and onChanged'
status: To Do
assignee: []
created_date: '2026-10-03 23:09'
labels: []
dependencies: []
parent_task_id: TASK-132
priority: low
ordinal: 149000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The Claude extension saves GIF recordings with downloads.download({url: <blob URL>, filename, saveAs: false}), watches downloads.onChanged for state complete / interrupted, and reads the result with downloads.search({id}). WebKit has no downloads API; back it with DownloadManager.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 download saves a blob:, data: and https URL to the profile's download folder under the given filename and resolves with an id
- [ ] #2 onChanged reports the state change to complete or interrupted, and search({id}) returns the item with filename and state
- [ ] #3 The download appears in Detour's downloads popover
- [ ] #4 A filename that escapes the download folder is refused
- [ ] #5 An extension without the downloads permission gets no chrome.downloads; tests cover both, and API Explorer covers the API
<!-- AC:END -->
