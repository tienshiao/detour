---
id: TASK-132.20
title: 'Extensions: end-to-end check of the Claude extension in a signed build'
status: To Do
assignee: []
created_date: '2026-10-03 23:09'
updated_date: '2026-10-03 23:09'
labels: []
dependencies:
  - TASK-132.4
  - TASK-132.5
  - TASK-132.6
  - TASK-132.8
  - TASK-132.9
  - TASK-132.12
  - TASK-132.14
  - TASK-132.15
parent_task_id: TASK-132
priority: medium
ordinal: 152000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Run the real extension in a signed build and record what works. Covers the paths no unit test reaches: Web Store install, claude.ai sign-in, the side panel, a task that uses screenshots, clicks, typing and navigation across two tabs with one of them unselected, and the Claude Code / Claude desktop connection over native messaging (hosts com.anthropic.claude_code_browser_extension and com.anthropic.claude_browser_extension, bridge at wss://bridge.claudeusercontent.com).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Install, sign in and opening the panel work from a clean profile, with no uncaught errors in the Extensions log
- [ ] #2 A side panel task that reads a page, clicks, types and opens a second tab completes, with the second tab driven while unselected
- [ ] #3 The session's tabs show the group stripe, and closing the panel or the group tab leaves no orphaned state
- [ ] #4 Claude Code's browser tools (tabs_context_mcp, navigate, computer screenshot and click) work through the native host
- [ ] #5 The extension's service worker survives 10 minutes idle and responds afterwards
- [ ] #6 Every failure found is filed as a follow-up task
<!-- AC:END -->
