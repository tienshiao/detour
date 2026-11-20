---
id: TASK-415
title: >-
  Website: capture session — retake the Settings stills, and record the
  Automation (MCP) loop
status: To Do
assignee: []
created_date: '2026-11-20T02:57:00Z'
updated_date: '2026-11-20T03:17:00Z'
labels:
  - website
dependencies: []
priority: low
ordinal: 496000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-338 redesigned Settings (grouped rows, switches) and TASK-327 added a Shortcuts pane. link-routes.webp on the Link Routes guide shows the old window (no Shortcuts pane, old layout); check the other feature stills (profiles-*.webp, web-extensions.webp, privacy.webp, private-browsing.webp) for Settings content too. Retake with docs/capture/capture.py (takes the screen over while it runs; see wiki/playbooks/release-and-website.md, Website captures).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Every website still that shows Settings shows the 0.5.0 Settings window
- [ ] #2 The retaken stills are deployed after the user's review
- [ ] #3 The Automation guide (src/content/features/automation.md) gets a short loop: the connected-agent label naming Claude Code and the agent pointer clicking a tab and typing into a page (Debug build: the agent pointer and indicator overrides), added as the page's media after the user's review
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-19: the user asked to record the Automation page's video later, with this capture session, not on release night. The page shipped on website branch guides-0.5.0 without media (the schema allows it).
<!-- SECTION:NOTES:END -->
