---
id: TASK-132.14
title: >-
  Extensions: chrome.debugger input — Input.dispatchMouseEvent,
  dispatchKeyEvent, insertText
status: To Do
assignee: []
created_date: '2026-10-03 23:09'
labels: []
dependencies:
  - TASK-132.13
parent_task_id: TASK-132
priority: high
ordinal: 146000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deliver CDP input to an attached tab as real (trusted) events by synthesising NSEvents for its web view. Mouse: type mousePressed / mouseReleased / mouseMoved / mouseWheel, x and y in CSS pixels of the viewport, button, buttons, clickCount, modifiers, deltaX, deltaY. Keys: type keyDown / rawKeyDown / keyUp / char with key, code, windowsVirtualKeyCode, text, modifiers, commands. insertText goes through the text input client. Must work on an unselected, automation-attached tab without moving the real pointer, the key window or first responder of the user's own tab.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A click at page coordinates fires pointer and mouse events with isTrusted true on the element at that point, at any page zoom and scroll offset
- [ ] #2 Double and triple click, right click, drag (press, move, release) and wheel scrolling work
- [ ] #3 Typed keys reach the focused element with correct key, code and modifiers, including Enter, Tab, arrows, Backspace and Cmd/Ctrl shortcuts such as select-all
- [ ] #4 insertText inserts into inputs, textareas and contenteditable, including non-ASCII text
- [ ] #5 Input to an unselected attached tab reaches it while the user keeps typing in the selected tab undisturbed
- [ ] #6 Input never reaches Detour's own chrome (sidebar, palette) or another tab
<!-- AC:END -->
