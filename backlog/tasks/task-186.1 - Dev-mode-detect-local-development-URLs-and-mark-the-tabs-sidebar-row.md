---
id: TASK-186.1
title: 'Dev mode: detect local development URLs and mark the tab''s sidebar row'
status: Done
assignee:
  - '@claude'
created_date: '2026-10-24 09:13'
updated_date: '2026-10-24 17:25'
labels:
  - dev-mode
  - sidebar
  - feature
dependencies: []
parent_task_id: TASK-186
priority: medium
ordinal: 209000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
First part of TASK-186. Reference: docs/dev-mode/arc-sidebar-row.png.

1. A pure rule `isLocalDevelopmentURL(_:)` (test-first): which URLs put a tab in dev mode (see the parent for the proposed host set and open questions), and `devModeHostLabel` = host:port when the port is not the scheme's default, else the host.
2. Sidebar: a dev-mode tab's row gets an "under construction" treatment (Arc: yellow/black dashed hazard border around the row) and a second line under the title with the host label. Applies to normal tabs, pinned tabs and favourites' rows where they show titles; split rows need a decision (one pane local, one not).
3. The row follows navigation: leaving the local URL drops the style, coming back restores it. Sleeping tabs use their stored URL.

Row height: the second line must not change the list's row layout math (wiki/sidebar/row-layout.md), or the change goes through SidebarLayout and its tests.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 isLocalDevelopmentURL and the host label are pure functions with tests covering localhost, *.localhost, loopback IPv4/IPv6, 0.0.0.0, default vs non-standard ports, and non-local hosts
- [x] #2 A tab on a local development URL shows the hazard-style row and host:port second line; navigating away removes it
- [x] #3 Split rows, pinned rows and favourites are decided and recorded
- [x] #4 Checked at runtime (sidebar capture) in light and dark mode
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-24: the row and (TASK-186.2) toolbar must read the *effective* dev-mode state (per-site override from TASK-186.5, else isLocalDevelopmentURL), so keep the URL rule a separate function the effective rule composes.

Decisions (user, 2026-10-24): host set: localhost, *.localhost, 127.0.0.0/8, [::1], 0.0.0.0, *.test (http/https only); LAN IPs and .local excluded. Split rows: the hazard border goes around the local pane's half only, no second host:port line. (Mine, to confirm at review: pinned rows like normal rows; favourite tiles get the hazard border, no text.)

Implemented (2026-10-24, Opus subagent): Detour/Browser/DevMode/DevMode.swift — isLocalDevelopmentURL (http/https; localhost, *.localhost, 127.0.0.0/8 parsed the WHATWG way incl. 127.1 / 0x7f000001 / octal, 0.0.0.0 incl. '0', ::1 in any spelling via inet_pton, *.test; not ::ffff:127.0.0.1, bare 'test', LAN, .local), devModeHostLabel (lowercased host, IPv6 bracketed, :port only when non-default, trailing dot dropped), DevMode.isActive(for:) as the single entry point for TASK-186.5's override, DevModeRowMarking. HazardBorderView: solid systemYellow stroke under a near-black 1.5 pt 4/4 dashed stroke on the row's highlight rect; created lazily, no implicit animations, scale set on window move. Row: 10 pt secondary host line under the title, title shifted up, row height unchanged (36 pt, SidebarLayout untouched). Decisions: pinned rows as normal rows; favourite tiles border only; split rows border the local half(s), no host line; dormant pinned/favourite rows use their stored URL.
Review (/code-review --fix, 7 findings): fixed layer scale possibly staying 1x for borders added on screen, zero-padded IPv4 parts over 12 digits rejected, trailing dot kept in the label, an unused settable cornerRadius. Skipped: the marking snapping mid split reveal/collapse animation (visual, noted in the wiki), the unused isActive(for: BrowserTab) (entry point for later subtasks), replacing the parser with inet_aton (overflow semantics differ).
Tests: DevModeTests 31 (red step: 23/30 failed against empty stubs); 209 across DevModeTests, SidebarLayoutTests, SplitTabTests, TabCellSplitCollapseTests, FavoriteTileBadgeTests, SidebarPageFocusTests, TabHoverCardTests, 0 failures. Runtime (docs/harness/task186-1-harness.patch, pages on 127.0.0.1:8186): captures light and dark match — localhost tab and local pinned tab with border and host line, split local half bordered, local favourite tile bordered, non-local rows plain; navigating away drops the style and back restores it; a dormant pinned tab gets it from its pinned URL. Not checked at runtime: hover on a dev row, a sleeping normal tab, the review's scale fix (no re-run).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Tabs on local development URLs (localhost, *.localhost, loopback IPv4/IPv6, 0.0.0.0, *.test over http/https) get a yellow/black dashed hazard border in the sidebar and a host:port line under the title, without changing row height; split rows border only the local half, favourite tiles get the border. The rule is pure and tested (31 tests) and is the entry point TASK-186.5's per-site override will extend.
<!-- SECTION:FINAL_SUMMARY:END -->
