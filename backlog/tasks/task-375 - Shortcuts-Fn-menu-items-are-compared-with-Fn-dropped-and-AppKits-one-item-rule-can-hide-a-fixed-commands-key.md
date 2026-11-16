---
id: TASK-375
title: >-
  Shortcuts: Fn menu items are compared with Fn dropped, and AppKit's one-item
  rule can hide a fixed command's key
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T09:55:00Z'
labels:
  - keyboard
  - shortcuts
dependencies: []
references:
  - wiki/features/keyboard-shortcuts.md
  - wiki/platform/appkit-gotchas.md
priority: low
type: bug
ordinal: 456000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-350's agent. (1) Items that need Fn (fn-D, fn-E, Window tiling) are compared with Fn dropped, as the recorder does, so a binding on the same key without Fn could be named against them. (2) AppKit keeps a key equivalent on only one menu-bar item (macOS 26; docs/harness/task350); after a duplicate is seeded into defaults, an emptied live item can let the recorder accept a key a fixed command should hold. No current default is affected.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Fn is part of the comparison (or the difference is recorded with its reason)
- [ ] #2 The recorder checks fixed commands by their registry key, not the live item
<!-- AC:END -->
