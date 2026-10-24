---
id: TASK-189
title: >-
  Settings: fix the window's spacing and clipping (controls cut off, uneven
  gaps)
status: To Do
assignee: []
created_date: '2026-10-24 09:27'
labels:
  - settings
  - ui
  - bug
dependencies: []
priority: medium
ordinal: 216000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported by the user 2026-10-24: the Settings window is janky: inconsistent spacing, things getting cut off.

What the code and wiki already say (wiki/features/settings.md, Gotchas):
- The window is not resizable (740 wide) and every pane hard-codes its own height in `preferredContentSize` (General 120, Spaces 400, Profiles 580, Extensions 640, Content Blocking 300); `switchToPane` sizes the window to that number, not to the content.
- **A pane that overflows does not scroll** as a whole. On Extensions, an overflowing detail column squeezes the permissions scroll view (low compression resistance). Profiles shows and hides rows by state (Private note, archive row, isolation warning, custom user-agent field and preview, extension switches, external apps), so its real height varies while the pane's height does not.
- `NSStackView.edgeInsets` on the cross axis are soft (hugging priority only), so bottom insets collapse in a height-constrained column; `NSBox` does not grow to an Auto Layout content view's fitting height.
- Spacing is set per pane, with no shared metrics.

Plan:
1. **Survey at runtime first** (harness, isolated profile): capture every pane, light and dark, in the states that change layout: Private vs normal profile, Custom user agent, no / one / many extensions (with long names and many permissions), long space and profile names, content blocking on and off. For each, log the frames (`convert(bounds, to: nil)`) of the rows and the pane edges, and list every clip, overlap and uneven gap. Measure, do not eyeball (wiki/playbooks/ui-probes.md).
2. **Shared layout rules**: one set of spacing metrics (pane margins, section gap, row gap, label column width), each pane's content in a scroll view or sized from its fitting height, and the window height derived from the content (capped to the screen, scrolling beyond that). Decide whether the window becomes resizable.
3. **Fix pane by pane**, re-running the survey; before/after captures go in the task.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Every pane was captured in the listed states before the change, with each clipping and spacing defect listed in the task
- [ ] #2 No control is clipped or overlapped in any surveyed state, light or dark; a pane taller than the window scrolls
- [ ] #3 All panes use shared spacing metrics; the window's height follows the pane's content (decision on resizing recorded)
- [ ] #4 After captures for every pane and state are attached to the task; the wiki's Settings page is updated
<!-- AC:END -->
