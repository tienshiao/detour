---
id: TASK-368
title: >-
  Content blocking: a rules change reaches only the selected tab's panes;
  background tabs keep their old lists
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
labels:
  - content-blocking
dependencies: []
references:
  - wiki/features/content-blocking.md
priority: low
type: bug
ordinal: 449000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-359's agent. BrowserWindowController.handleContentBlockerRulesChanged updates only the selected tab's panes (in the window that owns the web view). A background tab that already has a web view keeps its old rule lists until it is selected during a later change or its web view is rebuilt. One pass over every live web view (ContentBlockerManager.replaceRuleLists) would fix both window kinds.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 After a list refresh, toggle or Clear Cache, every live web view (all tabs, Quick Detour, quarantine) uses the new lists
- [ ] #2 A test covers a background tab
<!-- AC:END -->
