---
id: TASK-212
title: Rename Air Traffic Control to Link Routes
status: Done
assignee:
  - '@claude'
created_date: '2026-10-27 02:19'
updated_date: '2026-10-27 05:01'
labels:
  - settings
  - links
dependencies: []
priority: low
ordinal: 248000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Decision (user, 2026-10-26): 'Air Traffic Control' is Arc's name, so the feature built in TASK-191 (and the Quick Detour target from TASK-193.5) is called Link Routes. The Settings pane keeps the name Links, and each entry stays a route; the code types (LinkRoute, LinkRouteStore, LinkRouteResolver) already use the generic name.

Other browsers checked for naming: Edge 'Automatic profile switching', Firefox Multi-Account Containers 'Always open this site in…', Vivaldi workspace rules, browser pickers 'Rules'.

Scope: the one user-visible sentence on the Links pane (LinksSettingsViewController.swift, 'Air Traffic Control opens links in…'), any other user-visible text found, code comments in Detour/ and DetourTests/, the wiki (wiki/features/link-routing.md and the pages that mention it), and the harness patches in docs/harness. Old Backlog tasks and git history keep the old name.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 No user-visible text says Air Traffic Control; the Links pane's description reads 'Link Routes open links in the space you choose: …' or similar
- [x] #2 grep -ri 'air traffic' over Detour/, DetourTests/, wiki/ and docs/ finds nothing except a wiki note that the feature was formerly named after Arc's
- [x] #3 The wiki page for the feature is titled Link Routes; wiki-lint passes
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Code: LinksSettingsViewController's description string -> 'Link Routes open links in the space you choose: ...'; every 'Air Traffic Control' code comment in Detour/ and DetourTests/ -> Link Routes (no identifiers change: types, the linkRoute table and its columns already use generic names, so no storage migration).
2. Wiki: features/link-routing.md keeps its file name/id (no ATC in it, inbound links stay valid), title -> Link Routes, one note that the feature was first named after Arc's Air Traffic Control; every other page's mentions and source titles -> Link Routes; lint --fix regenerates the index; log line.
3. docs/harness patch headers -> Link Routes. Left alone: docs/air-traffic-control/ (Arc's own screenshots, cited by TASK-191/191.3 which keep the old name), old Backlog tasks, past wiki/log.md entries (history).
4. Build, LinksSettings-related tests, runtime capture of Settings > Links light + dark, code review, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Queued (user, 2026-10-26): ahead of TASK-194, after TASK-211 (order: 210, 211, this task, 194, 201, 202, 209).

Renamed in: the Links pane description (now 'Link Routes open links in the space you choose: …'), code comments in Detour/ and DetourTests/ (where 'X's routes' read badly the comment says 'link routes', matching the LinkRoute type), wiki pages, and the headers of docs/harness/task191-1..4 and task193-5 patches. No identifier changed and no test asserts the description string, so there was no red test to write (a one-string rename; the runtime harness checks it instead).
Left alone, on purpose:
- Storage: nothing to migrate. Tables linkRoute/linkRouteDefault, their columns, the pasteboard type com.detour.link-route and the Settings toolbar id 'links' already use generic names; no UserDefaults key mentions the old name.
- docs/air-traffic-control/ (Arc's own screenshots of Arc's feature, cited by TASK-191 and TASK-191.3, which keep the old name); referenced by path from LinksSettingsViewController and the wiki.
- Old Backlog tasks (TASK-191..191.4, 193.5) and git history.
- wiki/log.md past entries (history; the 2026-10-25 TASK-191.1 and 2026-10-26 TASK-193.5 lines).
- Wiki page features/link-routing.md keeps its file name and id (no old name in it), so no inbound link moved; its title is now Link Routes, with the one note on the former name. Source titles and footnotes that quoted the old task titles ('Air Traffic Control: …') now lead with the task ID ('TASK-191.1: …') instead.
- quick-detour.md heading renamed; its one inbound anchor (link-routing.md) updated.

AC #2 exceptions, deliberate: wiki/log.md past entries (TASK-191.1, TASK-193.5) and the new TASK-212 line, which names the old name; docs/harness/task212-harness.patch, whose check searches for the phrase. code-review (--fix, low): 7 findings, all wiki; fixed 5 (missing log line, which duplicated mine and was removed; three stutters in settings.md, session-database.md, wkwebview-delegate-order.md; link-routing.md rewrap and a pre-existing double comma in its description); skipped 2 (source titles now lead with the task ID instead of quoting old titles, deliberate; run.sh not in the repo, as for earlier harness patches).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Air Traffic Control is now Link Routes everywhere but history. User-visible: the Links pane description reads 'Link Routes open links in the space you choose: …' (the pane stays Links, entries stay routes). Comments in Detour/ and DetourTests/, 11 wiki pages (features/link-routing.md retitled Link Routes, same file and id, with one note on the former Arc name), and the TASK-191.x/193.5 harness patch headers renamed. No identifiers or storage names changed (they were already generic: LinkRoute*, linkRoute/linkRouteDefault tables, no defaults key), so no migration. Kept: docs/air-traffic-control/ (Arc's screenshots, cited by old tasks), old Backlog tasks, past wiki/log.md entries.
Tests (-only-testing, all passed): LinkRouteResolverTests 38, LinkRouteStoreTests 39, LinkRoutingEligibilityTests 45, InPageLinkRoutingTests 21, QuickDetourOpenInWindowTests 17, LinkRouteEditorTests 15, SettingsPaneColumnsTests 21 (196, 0 failures).
Runtime (docs/harness/task212-harness.patch, light and dark): main menu 95 titles and all 7 Settings panes (196 visible strings) have no 'air traffic'; Links pane captured with the new description wrapping on two lines; Quick Detour caption ('on the Links pane') unchanged. Wiki lint 0 errors 0 warnings.
Not verified: the space-deletion alert and other routing UI were not shown at runtime (their strings never named the feature; checked by grep).
<!-- SECTION:FINAL_SUMMARY:END -->
