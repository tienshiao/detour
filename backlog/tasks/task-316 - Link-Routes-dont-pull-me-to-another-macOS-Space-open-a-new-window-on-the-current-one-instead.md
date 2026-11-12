---
id: TASK-316
title: >-
  Link Routes: don't pull me to another macOS Space; open a new window on the
  current one instead
status: To Do
assignee: []
created_date: '2026-11-09T20:00:00Z'
labels:
  - link-routing
  - window
  - macos-spaces
dependencies: []
references:
  - Detour/Browser/LinkRouting/LinkPlacement.swift
  - Detour/App/AppDelegate.swift
  - TASK-191.2
  - TASK-314
priority: medium
type: feature
ordinal: 378000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the user 2026-11-09: 'I use spaces a lot. When I click on a link that routes to a certain window, I would prefer not to be taken away from my current space. I think if the window is not in the current space, it would be preferable to open a new window in the current space.'

'Space' here means a macOS Space (a Mission Control desktop), not a Detour space. This interpretation is to be confirmed with the user; the two names clash, so this task writes 'macOS Space' and 'Detour space'.

Today: linkPlacement (LinkPlacement.swift) picks the most recent normal window showing the routed Detour space (.openInWindow). Failing that, it switches the most recent normal window to that space (.switchWindow; user decision 2026-10-25). Only with no normal window does it open a new one. AppDelegate.present then calls makeKeyAndOrderFront. When the chosen window is on another macOS Space, macOS switches the user to that Space. The rule knows nothing about macOS Spaces: LinkPlacementWindow carries only id, activeSpaceID and isPrivate.

Wanted: a routed link never moves the user to another macOS Space. Only windows on the current macOS Space (NSWindow.isOnActiveSpace) are candidates. If none fits, a new window opens on the current macOS Space, showing the routed Detour space.

Proposed rule for .openInSpace(S), with windows filtered to the current macOS Space:
1. A window there showing S: open in it (as today).
2. Else: a new window on S on this macOS Space. Alternatively, switch the most recent window there to S (today's rule, applied per macOS Space). The user asked for a new window; to be confirmed.
3. Private routes the same way: a Private window on this macOS Space, else a new Private window.
Quarantine and Quick Detour already open new windows. Most Recent Space uses the key window, which is on the current macOS Space.

To measure before relying on it:
- isOnActiveSpace for a minimized window, a full-screen window (its own Space), a window on another display's Space, and a window assigned to All Desktops.
- Whether activating Detour (a link from another app) still jumps to another Space under System Settings > Desktop & Dock > 'When switching to an application, switch to a Space with open windows for the application', when the new window is created on the current Space before activation.
- Clicked links routed out of the window's own Detour space (TASK-191.4) go through the same placement, so this changes them too: a click that today switches another window would open a new one if that window is on another macOS Space.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 LinkPlacementWindow carries whether the window is on the current macOS Space, and linkPlacement only picks windows that are; LinkPlacementTests cover both rules (window on this Space showing S, window showing S only on another Space)
- [ ] #2 Runtime: with Detour windows on two macOS Spaces, a link routed to the Detour space shown on the other macOS Space opens a new window on the current one, and the current macOS Space stays active (checked with the 'switch to a Space with open windows' setting on and off)
- [ ] #3 A window on the current macOS Space that already shows the routed Detour space still takes the link, as today
- [ ] #4 Minimized, full-screen and All Desktops windows behave as measured and recorded in the notes; the wiki Link Routes page describes the rule
<!-- AC:END -->
