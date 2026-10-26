---
id: TASK-193.3
title: 'Quick Detour: Open in <Space> moves the page into a tab of a space (Cmd+O)'
status: To Do
assignee: []
created_date: '2026-10-24 10:11'
updated_date: '2026-10-26 07:07'
labels:
  - window
  - spaces
  - feature
dependencies:
  - TASK-193.1
parent_task_id: TASK-193
priority: medium
ordinal: 227000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Third part of TASK-193. The Open in <Space> button (Cmd+O) moves the quick window's page into a new tab of the shown space and closes the quick window; its dropdown lists the other spaces (emoji and name). Which space is shown by default: the most recently used space of the window's profile (decide). When the target space uses the window's profile, hand over the same web view (as `expandPeekToNewTab` does), keeping history and state; when it uses another profile, the web view cannot move (different data store): either reload the URL there or list only same-profile spaces (decide; the profile pill, TASK-193.4, affects this). The new tab is selected in a window showing that space (else the most recent window switches to it), the same placement rule as TASK-191.2.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Cmd+O and the button move the page to a new tab in the shown space and close the quick window; the dropdown picks another space
- [ ] #2 Same-profile moves keep the web view (back/forward history intact); cross-profile behaviour is decided and implemented
- [ ] #3 TabStore insertion is test-first; checked at runtime
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decisions (user, 2026-10-26):
1. Default space named on the button: the space that was in front when the Quick Detour was opened, if it uses the same profile; otherwise that profile's most recently used space.
2. Dropdown lists all normal spaces grouped by profile. Same-profile spaces get the page moved intact (same web view: scroll, back/forward, form state). Another profile's space reloads the URL there (that profile's cookies/logins; back/forward history lost). Rejected: same-profile spaces only.
3. Private Quick Detour: Open in Private Window moves the page intact into a new tab of the most recent Private window, else a new Private window (same throwaway store, no reload).
<!-- SECTION:NOTES:END -->
