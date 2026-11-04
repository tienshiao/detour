---
id: TASK-132.25
title: >-
  Extensions: a scrolling action popup shrinks back when its content gets
  shorter
status: To Do
assignee: []
created_date: '2026-11-04T09:05:00Z'
labels:
  - bug
  - extensions
dependencies: []
parent_task_id: TASK-132
priority: low
ordinal: 309000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Lost in the merge of main into epic-claude-extension (45f5da1, Nov 4 2026). Main's TASK-220 sizes the popover from the web view's intrinsicContentSize through Auto Layout. The epic's TASK-150 scrolling was rebuilt on top of it: when the intrinsic height reaches 600, WebKit's size-to-content mode is switched off (with 800x0, because 0x0 makes WebKit drop the next intrinsic-size resend) and constraints hold the web view at width x 600. While the mode is off, WebKit reports no intrinsic size, so a popup whose content later becomes shorter than 600 stays 600 tall until the popover closes. TASK-150's original version measured the page from script and followed it back down. Code: Detour/Extensions/UI/ExtensionPopoverController.swift; wiki/extensions/popup-and-options-ui.md 'Content taller than the popover'.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A popup that scrolls at 600 and then shrinks below 600 resizes the popover to its new height while it stays open
- [ ] #2 No layout loop and no flicker when the content height hovers around 600
- [ ] #3 Covered by ExtensionPopoverSizingTests, plus a runtime check with API Explorer's popup
<!-- AC:END -->
