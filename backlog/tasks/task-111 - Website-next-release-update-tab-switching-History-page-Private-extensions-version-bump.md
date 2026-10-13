---
id: TASK-111
title: >-
  Website: next-release update (tab switching, History page, Private extensions,
  version bump)
status: Done
assignee: []
created_date: '2026-09-23 07:52'
updated_date: '2026-10-13 01:22'
labels:
  - website
dependencies: []
priority: low
ordinal: 111000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
When the release after v0.2.2 ships, update ../detour-website: version pill/schema/download links/.dmg size; add Tab Switching (Cmd+Option+Up/Down, Control+Tab with previews), the History page (Cmd+Y, search, delete/clear, time range), per-extension opt-in for Private windows (fold into Private Browsing), confirmation before external-app links; bump the '(17 more)' count.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Version references updated to the new release
- [x] #2 New features described on the site
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-12, task sweep, checked against ../detour-website at 1993a58 and 9a9de9f (both 2026-10-02). Version: the pill, the schema softwareVersion, every download link and the .dmg line say 0.3.0 (10.32 MB). Features: History (item 18: Cmd+Y, search by title, time range, delete), Recent Tabs (item 19: Control+Tab with a preview, Cmd+Option+Up/Down), Private-window extensions ('Off in Private unless you allow them', under Web Extensions rather than Private Browsing), and the count reads '(19 more)'. Left out: the confirmation before external-app links is not mentioned on the page; the user chose to close the task without it.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The website was updated for 0.3.0: version references, History, Recent Tabs, the Private-window extension switch and the feature count (website commits 9a9de9f and 1993a58). The external-app link confirmation is not described on the site.
<!-- SECTION:FINAL_SUMMARY:END -->
