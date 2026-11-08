---
id: TASK-299
title: >-
  Address bars: the sidebar's and Quick Detour's icons are in a different order,
  and the sidebar's copy-link button moves as extensions are pinned
status: To Do
assignee: []
created_date: '2026-11-08T08:40:00Z'
updated_date: '2026-11-08T10:20:00Z'
labels:
  - ui
  - quick-detour
dependencies: []
priority: low
ordinal: 360000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The two address bars order their trailing icons differently (left to right, Nov 8 2026, main == v0.4.0):
- Sidebar faux address bar (Detour/Browser/Sidebar/FauxAddressBar.swift): host → copy link ("link", tooltip "Copy URL", shown only on hover) → pinned extensions → Site Settings ("slider.horizontal.3"). The copy button is pinned to the extension stack's leading edge, so its position changes as extensions are pinned or unpinned.
- Quick Detour title bar (Detour/Browser/QuickDetour/QuickDetourTitleBar.swift): profile pill → host → pinned extensions → Site Settings → copy link ("Copy Link") at the capsule's trailing edge.
The user finds the mismatch bothersome and recalls Arc keeping copy closer to the URL so it doesn't move around with extensions. (Arc's help center: pinned extensions show in Arc's URL bar when you hover the sidebar, and Site Controls sits to the right of the URL bar; it doesn't say where copy sits.)

Options for the agreed order, for example: copy and Site Settings at fixed spots with extensions growing away from them; or the sidebar adopting Quick Detour's order (copy at the trailing edge, fixed); or copy right after the host in both with extensions after Site Settings. The tooltip wording should match too.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The order is agreed with the user before implementation
- [ ] #2 Both bars show the same icons in the same order, with the same tooltips and accessibility labels
- [ ] #3 The copy-link and Site Settings buttons stay in the same place when extensions are pinned or unpinned
- [ ] #4 Checked at runtime with /verify with zero, one and several pinned extensions, in the sidebar and in Quick Detour
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026, user decision: order in both bars is host … [extensions] [copy link] [Site Settings]. Copy and Site Settings sit together at the trailing edge, so the right side is identical regardless of pinned extensions (and across profiles); extensions grow leftward from copy.
<!-- SECTION:NOTES:END -->
