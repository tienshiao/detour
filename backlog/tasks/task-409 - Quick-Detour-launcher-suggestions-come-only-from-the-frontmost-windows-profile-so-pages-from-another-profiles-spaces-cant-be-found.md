---
id: TASK-409
title: >-
  Quick Detour launcher: suggestions come only from the frontmost window's
  profile, so pages from another profile's spaces can't be found
status: To Do
assignee: []
created_date: '2026-11-17T21:35:00Z'
labels:
  - quick-detour
  - palette
  - profiles
dependencies: []
priority: medium
type: feature
ordinal: 490000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported by the user on 2026-11-17: the global-hotkey Quick Detour palette seems scoped to the frontmost Detour window, so its suggestions only come from that space, which is annoying when looking for something that was in another space.

What the code and wiki say:
- The panel uses the profile of the frontmost Detour window (QuickDetour.profileForNewWindow, the user's TASK-193.4 decision).
- Its history is that profile's whole history: every space of the profile plus the profile's Quick Detour scope (PaletteTabScope.historySpaceIDs, TASK-209).
- It offers no open-tab rows at all, because switching to a tab would bring a browser window forward.
- So a space of the same profile is searched. A space of another profile is not, and the user's two spaces sit on different profiles: Home on Personal, Work on Work.
- TASK-209 (the user's request, 2026-10-26) made every palette row come from the palette's profile only. This ticket revisits that rule for the Quick Detour launcher, which is not tied to a browser window.

Arc, from secondhand sources only (no official doc found):
- Arc's built-in command bar appears to follow the active space's profile; suggestions reset when switching to a space of another profile.
- The Browser Company's own Raycast extension searches history across all Arc profiles and labels each result with its profile.
- Little Arc's profile behaviour was not confirmed.

Open decision for the user: whether the launcher should search other profiles (labelled, opening the Quick Detour in the row's profile so its cookies/logins apply), only on request (a modifier or prefix), or stay as it is.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The user's decision on cross-profile suggestions in the Quick Detour launcher is recorded here
- [ ] #2 Whatever is decided, the Private profile's history never appears outside a Private context, and in-window palettes (Cmd+T, Cmd+L) keep TASK-209's profile scoping unless the user decides otherwise
- [ ] #3 Suggestion pipeline tests cover the decided scope for the launcher
<!-- AC:END -->
