---
id: TASK-229
title: >-
  Hover card: show a tab's Peek (its title, URL and thumbnail), including from
  the Peek favicon in the sidebar row
status: To Do
assignee: []
created_date: '2026-10-29T04:25:00Z'
labels:
  - sidebar
  - peek
dependencies: []
priority: low
ordinal: 265000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested Oct 28 2026. The sidebar hover card (TASK-190, Detour/Browser/HoverCard/) describes only the host tab: its title, URL and thumbnail. A tab with a Peek open or parked shows the Peek's favicon as a badge at the trailing edge of its row (TabCellView peekFaviconImageView, TASK-47 for favourite tiles, TASK-173 for the Control+Tab switcher), but hovering the row or the badge says nothing about the Peek. The user wants the card to cover Peeks, either as part of the host row's card or as its own card when the pointer is over the Peek favicon in the row.

Context for whoever picks this up:
- A Peek is a BrowserTab held in its host's `peekTab` (wiki/tabs/peek.md). It can be live (web view on screen or hidden) or parked (host asleep, Peek web view gone, state saved by `parkPeek`), and it is restored from the host's `peekURL`/`peekInteractionState` after a relaunch. The card has to work for each state without waking anything.
- Thumbnails come from `switcherPreview`, taken when a tab is left on screen, and from the disk cache keyed by `TabStore.thumbnailKey(for:)` (TASK-190). Whether a Peek ever gets its own preview, or whether the host's capture already includes the Peek overlay, has not been checked. Never wake or host a hidden tab to take one (wiki/platform/gpu-iosurface-limit.md).
- The card's rules are pure functions in HoverCardRules.swift with tests in TabHoverCardTests. Extend those rather than branching in the view.

Decide when planning, with the user's input on the product question:
- One card for the row with a Peek section, or a separate card for the badge, or both.
- What the card shows for a parked Peek or one restored after a relaunch with no thumbnail.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Hovering a tab that has a Peek (live or parked) shows the Peek's title and URL on the hover card, in the layout the user chose (a section on the host's card, a separate card for the Peek favicon, or both)
- [ ] #2 The Peek's thumbnail is shown when one exists, the card has a compact layout when none does, and no Peek or host is woken or shown to make one
- [ ] #3 Pinned rows, favourite tiles and split panes that have a Peek behave the same as normal rows
- [ ] #4 The rule changes are covered in TabHoverCardTests (live, parked and no-Peek cases), and the card is checked at runtime in light and dark mode
<!-- AC:END -->
