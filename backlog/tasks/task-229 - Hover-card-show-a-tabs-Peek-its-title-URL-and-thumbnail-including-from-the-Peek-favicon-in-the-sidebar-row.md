---
id: TASK-229
title: >-
  Hover card: show a tab's Peek (its title, URL and thumbnail), including from
  the Peek favicon in the sidebar row
status: To Do
assignee: []
created_date: '2026-10-29T04:25:00Z'
updated_date: '2026-10-29T04:27:00Z'
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
- [ ] #1 Hovering the Peek favicon in a sidebar row shows a hover card for the Peek (its title and URL), for a live or a parked Peek; hovering the rest of the row still shows the host tab's card as before
- [ ] #2 Moving the pointer between the Peek favicon and the rest of the row swaps the card at once (no fresh show delay), and the card is placed beside the row as the host's card is
- [ ] #3 The Peek's thumbnail is shown when one exists, the card has a compact layout when none does, and no Peek or host is woken or shown to make one
- [ ] #4 Pinned rows, favourite tiles and split panes that have a Peek behave the same as normal rows
- [ ] #5 The rule changes are covered in TabHoverCardTests (live, parked and no-Peek cases), and the card is checked at runtime in light and dark mode
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decision (user, Oct 28 2026): the Peek gets its own hover card, shown while the pointer is over the Peek favicon badge in the sidebar row. The host row's card is unchanged and has no Peek section.
<!-- SECTION:NOTES:END -->
