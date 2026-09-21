---
id: TASK-102
title: >-
  Extensions: 1Password's worker in the Private profile throws 'undefined is not
  an object (evaluating a.providers)' on page loads
status: To Do
assignee: []
created_date: '2026-09-21 08:12'
labels:
  - extensions
  - 1password
  - privacy
dependencies: []
documentation:
  - docs/1password-integration-plan.md
priority: low
ordinal: 102000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen in the signed build on 2026-09-21 (761c4b6, 1Password 8.12.26.40, allowed in Private per TASK-74, extension pages in the ephemeral store per TASK-73) while the user browsed reddit.com in a Private window: eight '[unhandled rejection] TypeError: undefined is not an object (evaluating 'a.providers')' at lK@webkit-extension://<private base>/background/background.js:69:2813 between 01:00:42 and 01:00:55, clustered with '[Webauthn] Could not complete _handleGetCredential: missing-public-key', '[Fill] Session does not exist for 492, skipping event.', '[Cache] The item cache has not been initialized yet.' and one '[Tabs] Could not collect all frames that were initially found.' at 01:00:54. The Personal and Work workers, used on the TASK-4 fixture in the same run, logged none of these — but they were not used on reddit.com, so whether this is Private-specific or site-specific is unknown. The worker kept running and answering keep-alive pings, and the user reported no visible failure. 'providers' suggests 1Password's sign-in-with (SSO provider) data for the page — possibly a storage/session value that is undefined in a fresh ephemeral store, or an API answer that differs for a context with private access. Distinct from TASK-81 (A.id TypeError from windows.getCurrent). First step is cheap: load reddit.com with 1Password in a normal profile with ExtensionConsoleLogPublic set and see whether the same rejection appears; then locate background.js:69:2813 in the unpacked extension to see what 'a' is and which API call or storage read produced it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Determined and recorded: does the rejection appear on reddit.com in a persistent profile too (site-specific) or only in Private (profile-specific)
- [ ] #2 The expression at background.js:69:2813 is identified and traced to the API result or storage value that was undefined
- [ ] #3 Either a fix lands with tests (and API Explorer coverage if an API's behaviour changes), or the cause is documented as 1Password-internal/benign and the task is closed with that note
- [ ] #4 The '[Tabs] Could not collect all frames that were initially found' line on reddit.com is explained or handed to the iframe tasks with the frame list that produced it
<!-- AC:END -->
