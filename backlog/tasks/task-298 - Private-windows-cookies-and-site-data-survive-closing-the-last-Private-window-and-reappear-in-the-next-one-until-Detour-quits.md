---
id: TASK-298
title: >-
  Private windows: cookies and site data survive closing the last Private window
  and reappear in the next one, until Detour quits
status: To Do
assignee: []
created_date: '2026-11-08T08:40:00Z'
labels:
  - private
  - privacy
  - bug
dependencies: []
references:
  - TASK-238
  - TASK-292.7
priority: high
type: bug
ordinal: 359000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by both website agents' runtime checks (TASK-292.5, TASK-292.7) on v0.4.0, Nov 8 2026: in a Private window, set a cookie and localStorage on a page; close every Private window; open a new Private window on the same page: document.cookie and localStorage still hold the values. They go away only when Detour quits. Chrome and Safari drop private data when the last private window closes, which is what users expect from "Private".

Cause: the built-in Private profile's `dataStore` is a lazy `.nonPersistent()` created once per process (Detour/Browser/Profile.swift ~168), and the profile object is reused for every Private session (its id is a constant). `TabStore.endPrivateSessionIfUnused()` (~2589) ends a session when nothing uses it (last Private window's space removed, last Private Quick Detour closed or switched profile) but discards only the session's site settings and the Private profile's extension notifications (TASK-238), never the website data. Quarantine is unaffected: each Quarantine window has its own fresh store (Quarantine.swift).

What makes the fix more than swapping the store: extensions allowed in Private keep their contexts loaded between sessions on the Private profile's store (see the TASK-238 comments and the extension-data-store notes: WebKit never copies defaultWebsiteDataStore into extension web views; the incognito worker was cycled on the ephemeral store), Private downloads, the Private profile's per-session state, and anything else that captured the old store (web view configurations, the extension controller's defaultWebsiteDataStore).

The website's Private Browsing page (detour-website src/content/features/private-browsing.md) and the home grid line currently describe the bug's behavior ("logins and cookies last until you quit Detour"); they change with the fix.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 After the last Private window and the last Private Quick Detour close, a new Private window starts with no cookies, localStorage, IndexedDB, cache or service workers from the previous Private session
- [ ] #2 While a Private session is live, its Private windows still share one store (sign in once, signed in across them)
- [ ] #3 Extensions allowed in Private keep working in the next Private session, and nothing they stored in the previous session's website data survives into it
- [ ] #4 Normal profiles and Quarantine windows are unaffected
- [ ] #5 Tests cover the session boundary (data set in session 1 is absent in session 2; present across two windows of one session)
- [ ] #6 Checked at runtime with /verify: cookie and localStorage gone after closing all Private windows, kept across two open Private windows
- [ ] #7 The website's Private Browsing page and home grid line are updated to the new behavior
<!-- AC:END -->
