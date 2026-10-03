---
id: TASK-132.7
title: 'Extensions: chrome.identity.getRedirectURL and launchWebAuthFlow'
status: To Do
assignee: []
created_date: '2026-10-03 23:07'
labels: []
dependencies: []
parent_task_id: TASK-132
priority: medium
ordinal: 139000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The Claude extension re-authorises silently with identity.launchWebAuthFlow({url, interactive: false, abortOnLoadForNonInteractive: false, timeoutMsForNonInteractive: 15000}) and a redirect_uri from identity.getRedirectURL() (https://<extension id>.chromiumapp.org/). WebKit has no identity API. Polyfill both: the flow loads the URL in a web view on the calling profile's data store (so the site's cookies apply), and resolves with the first navigation to the redirect URL without loading it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 getRedirectURL(path) returns https://<id>.chromiumapp.org/<path>
- [ ] #2 A non-interactive flow resolves with the redirect URL when the server redirects without user input, and rejects on timeout or when interaction would be needed, without showing UI
- [ ] #3 An interactive flow shows the page in a window, resolves on redirect, and rejects when the user closes it
- [ ] #4 The flow uses the calling profile's cookies; a Private profile's flow does not touch a persistent store
- [ ] #5 An extension without the identity permission gets no chrome.identity; tests cover both
- [ ] #6 API Explorer covers both methods
<!-- AC:END -->
