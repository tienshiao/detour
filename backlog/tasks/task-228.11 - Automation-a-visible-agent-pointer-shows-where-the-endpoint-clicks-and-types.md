---
id: TASK-228.11
title: 'Automation: a visible agent pointer shows where the endpoint clicks and types'
status: To Do
assignee: []
created_date: '2026-11-15T20:08:00Z'
labels:
  - automation
  - ui
dependencies: []
references:
  - Detour/Automation/AutomationInput.swift
  - Detour/Automation/AutomationCapture.swift
  - wiki/features/automation-endpoint.md
parent_task_id: TASK-228
priority: low
type: feature
ordinal: 424000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Proposed 2026-11-15 by the user, after Claude in Chrome's virtual cursor. The MCP endpoint delivers clicks and keys inside Detour without moving the person's mouse (wiki/features/automation-endpoint.md, 'how clicks, keys and menus are delivered'), so the person cannot see where an agent is acting; the connected-agent capsule only says an agent is there. Draw a visible agent pointer.

Design (the user approved these defaults on 2026-11-15):
- Native, not in the page: a click-through overlay window (ignoresMouseEvents, child of the target window) drawn by Detour. The endpoint also clicks sidebar rows, menus, switches and Settings, which an in-page DOM cursor cannot reach, and a DOM cursor would be visible to page scripts and to hit_test and the page tools.
- Every click route in AutomationInput already knows the window and point: the pointer glides from its last position to the target, shows a press ripple, then the event is delivered. Short glide (about 150 ms) by default; longer, slower motion while capture staging is in use, so a recording can be followed.
- Typing: a brief highlight on the element or field that receives the keys (there is no point to move to).
- Look: a tinted arrow with a small 'Agent' label, clearly distinct from the system pointer.
- Shown also when the target window is in the background and Detour is not frontmost (the case where the person most needs to see it).
- Scope: browser windows first; Quick Detour, quarantine and Settings windows if they come for free through the same window routing.
- A setting under Settings > General > Automation, on by default. Tests and harnesses turn it off with the Debug set_debug_override (like automation_indicator), so their clicks gain no delay.
- Agent screenshots: the screenshot tool captures one window through ScreenCaptureKit (AutomationCapture.swift), which should leave a separate overlay window out; confirm it. Full-screen recordings (website captures) are expected to show the pointer.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 An endpoint click (by selector, page point or window point, left or right) in a browser window shows the agent pointer gliding to the point and a press ripple, then delivers the click; the person's own pointer does not move
- [ ] #2 Typing through the endpoint briefly highlights the element or field that receives the keys
- [ ] #3 The pointer is shown when the target window is in the background and Detour is not frontmost, and never takes clicks, focus or key status
- [ ] #4 Settings > General > Automation has a switch for the pointer, on by default; off, endpoint input is delivered with no added delay (a test measures it)
- [ ] #5 The endpoint's screenshot tool leaves the pointer out of the image; a full-screen recording shows it (checked at runtime)
- [ ] #6 A Debug set_debug_override turns it off for tests and harnesses; existing automation tests and harnesses still pass
- [ ] #7 Checked at runtime with /verify (a recording of clicks in the sidebar, a Settings switch and a page); wiki updated (automation endpoint, capture staging)
<!-- AC:END -->
