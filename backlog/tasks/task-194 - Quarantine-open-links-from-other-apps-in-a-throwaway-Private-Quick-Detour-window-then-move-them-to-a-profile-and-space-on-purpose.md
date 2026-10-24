---
id: TASK-194
title: >-
  Quarantine: open links from other apps in a throwaway Private Quick Detour
  window, then move them to a profile and space on purpose
status: To Do
assignee: []
created_date: '2026-10-24 10:15'
updated_date: '2026-10-24 10:18'
labels:
  - links
  - privacy
  - window
  - feature
dependencies:
  - TASK-191.1
  - TASK-191.2
  - TASK-193.1
  - TASK-193.3
priority: medium
ordinal: 230000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the user 2026-10-24.

**What.** A link from another app can be opened in **quarantine**: a Little/Quick Detour window (TASK-193) on a Private, throwaway data store, so the destination does not see or set any of your cookies or site data, and nothing is recorded in history. The window makes the state obvious (a quarantine badge or tint in the title bar, showing where the link redirected to) and offers an explicit move: Open in <Profile / Space>, which loads the current URL fresh in a tab of the chosen space (never carrying the quarantined cookies over, which is the point).

**How it is chosen.** Through Air Traffic Control (TASK-191): Quarantine is an Open in target. Proposed: it can be the **Default** target (every link from another app that no route matches is quarantined, which is what the user described) and a per-route target; routes keep sending trusted sites straight to their space. Only links from other apps are quarantined (typed URLs and in-browser clicks are not); decide whether a route can also quarantine in-browser clicks.

**Decisions to make and record:**
- **Isolation:** the shared Private profile store would let two quarantined links, and any open Private window, share cookies. Proposed: a fresh non-persistent data store per quarantine window (as the profile setting "per-tab isolation" already does per tab), discarded when the window closes or the page moves.
- **Fingerprinting:** an ephemeral store removes cookies and storage only; IP, fonts, canvas, screen and similar still identify you. Research what WebKit can do here, e.g. the SPI behind Safari's Advanced Tracking and Fingerprinting Protection (noise injection, `_networkConnectionIntegrityPolicy`-style policies) and link tracking protection (stripping click IDs such as `gclid`, `fbclid` from the URL). Record what works on the shipped macOS; guard any private API.
- **Extensions:** proposed none run in quarantine (not even those allowed in Private).
- **Downloads:** allowed, blocked or asked; and what the move offers when the page is mid-form.
- **Name:** Quick Detour vs Little Detour (see TASK-193).

Builds on: TASK-191.1 (target model), TASK-191.2 (external link routing), TASK-193.1 (the window), TASK-193.3 (moving the page to a space; here always a reload, since the data store differs).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Quarantine can be chosen as Air Traffic Control's Default target and as a route's target; a link from another app matching it opens in a quarantine window
- [ ] #2 The quarantine window uses a fresh ephemeral data store (or the decided alternative), records no history, runs no extensions, and is visibly marked
- [ ] #3 Open in <Profile/Space> loads the current URL fresh in a tab of the chosen space and closes the quarantine window; no quarantined cookie or storage reaches the destination (checked with a local fixture that sets a cookie)
- [ ] #4 Fingerprinting and link-tracking measures are researched, the ones adopted are implemented with guarded API, and the limits are recorded in the wiki
- [ ] #5 Routing and isolation rules have tests written first
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decided (user, 2026-10-24): quarantine applies to links from other apps only. A route never quarantines typed URLs or in-browser clicks (opening a Quick Detour window from a click does not make sense). For sending in-browser clicks to a private context, use the Private window target of Air Traffic Control instead (TASK-191).
<!-- SECTION:NOTES:END -->
