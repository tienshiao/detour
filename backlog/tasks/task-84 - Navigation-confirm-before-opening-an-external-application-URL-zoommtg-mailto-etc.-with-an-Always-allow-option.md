---
id: TASK-84
title: >-
  Navigation: confirm before opening an external application URL (zoommtg:,
  mailto:, etc.) with an 'Always allow' option
status: To Do
assignee: []
created_date: '2026-09-15 18:41'
labels:
  - navigation
  - security
dependencies: []
priority: medium
ordinal: 84000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Any non-http(s) navigation (zoommtg:, slack:, mailto:, itms-apps:, …) is handed straight to NSWorkspace.shared.open in BrowserWindowController+Navigation.swift (~line 94-99, the 'Open non-HTTP(S) URLs externally' branch) with no prompt, so any page can launch a local application without the user's consent. Show a confirmation sheet on the tab's window naming the page's origin and the target application (NSWorkspace.urlForApplication(toOpen:)), e.g. 'Open “zoom.us.app”?' with Open / Cancel and a checkbox 'Always allow <origin> to open links of this type in <app>' (Chrome's model: remembered per requesting origin + scheme). Persist decisions (per profile; not written from the Private profile) and provide a way to clear them in Settings. If no application handles the scheme, don't prompt — show an error/toast instead. Decide the behaviour for navigations without a user gesture (e.g. a page redirecting to zoommtg: on load, which Zoom's join page does) — they should still prompt, never auto-open unless allowed.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Opening an external-scheme URL from a page shows a confirmation sheet naming the requesting origin and the handling application; Cancel opens nothing
- [ ] #2 Checking 'Always allow' and choosing Open remembers the decision for that origin + scheme; later requests from that origin open without a prompt
- [ ] #3 Remembered decisions persist across relaunch, are scoped per profile, are never persisted from the Private profile, and can be cleared in Settings
- [ ] #4 A scheme with no registered handler does not prompt and surfaces a clear failure instead of silently doing nothing
- [ ] #5 Tests cover the decision store (allow, lookup, per-origin/per-scheme isolation, private profile not persisted) and the policy that decides whether to prompt
<!-- AC:END -->
