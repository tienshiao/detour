---
id: TASK-372
title: >-
  Error page: a failed in-page navigation names the previous page's URL, so
  Reload goes back instead of retrying
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
labels:
  - navigation
  - error-pages
dependencies: []
references:
  - wiki/features/error-pages.md
priority: medium
type: bug
ordinal: 453000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-352's probe. When a navigation started inside a page fails (script location change, link click, tabs.update), Detour's error page records the previous page's URL as failedURL; its Reload then returns to the old page instead of retrying the URL that failed. Seen in Quick Detour and space tabs.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The error page shows and retries the URL that failed
- [ ] #2 Tests cover a script navigation, a link click and tabs.update failing
<!-- AC:END -->
