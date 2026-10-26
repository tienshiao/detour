---
id: TASK-191.3
title: 'Air Traffic Control: Settings UI to add, edit, reorder and remove routes'
status: Done
assignee: []
created_date: '2026-10-24 09:44'
updated_date: '2026-10-26 01:08'
labels:
  - links
  - settings
  - ui
  - feature
dependencies:
  - TASK-191.1
parent_task_id: TASK-191
priority: medium
ordinal: 221000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Third part of TASK-191. A Links pane in Settings (or a section of the Spaces pane; decide), following Arc's sheet (docs/air-traffic-control/): a list of routes, each row `URL [match kind ▾] [pattern] ⊖` with `↳ Open in [space ▾]`; New Route; drag to reorder; a Default popup at the bottom. The space popup lists the non-Private spaces with their emoji and name, plus Most Recent Space. A route whose space is gone shows as broken. Follow the shared layout rules from TASK-189 if they have landed.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Routes can be added, edited, reordered and removed, and the Default target set; changes take effect for the next link without a restart
- [x] #2 Broken routes (deleted space) are shown as such
- [x] #3 Checked at runtime with captures, light and dark
- [x] #4 A route can be given a From app condition with an app picker (icon and name shown, bundle ID stored), and app-only routes are supported or explicitly ruled out
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-24: each route gets an optional 'From app' condition: an app picker (running apps plus Choose… for any .app; shows icon and name, stores the bundle ID), shown as an extra line under the URL line. A route may also be app-only (any URL from that app) — decide whether the URL part can be left empty.

2026-10-24: the Open in popup lists Private Window (and Quarantine, for routes that can only match links from other apps, and for the Default) after the spaces and Most Recent Space.

User 2026-10-25: own Links pane (not a Spaces section); app-only routes allowed (URL part optional when a From app is set; a route needs at least one condition). Space deletion in the sidebar and in the Spaces pane is blocked while routes target the space: the alert names the routes and offers to open the Links pane. Hide the Quarantine/Quick Detour targets until their tasks land.

2026-10-25 implementation:
- Own Links pane (toolbar item after Spaces, arrow.triangle.branch): routes in order, each row URL [match kind] [pattern] ⊖ / From app [app] / Open in [target]; New Route; drag to reorder; Default popup at the bottom with a caption (applies to links from other apps, typed links and clicks to another site).
- UI choices: match kind 'Any URL' and From app 'Any App' are the no-condition items (an empty pattern never means any URL, so clearing a field can't widen a route); app menu = running regular apps + a stored app not running + Choose… (NSOpenPanel on /Applications). Target popup: normal spaces, Most Recent Space, Private Window; Quarantine/Quick Detour hidden unless already stored. Nothing incomplete is saved: New Route adds a draft ('Not saved yet'); a refused edit of a saved route stays on its row ('Not saved: links follow the saved route') while the store keeps routing by the saved version. Warnings are a wrapping line under the route (rows grow by it; the list doesn't take focus). ⊖ removes without confirmation, as in Arc.
- Validation lives in the store (LinkRouteValidation.swift): noCondition, emptyPattern, invalidPattern (Domain is: no host / whitespace; Is equal to: not an http(s) URL with a host), missingSpace, privateSpace. add refuses any problem; update refuses condition problems and target problems only when the target changes (so a broken route can be repaired); setDefaultTarget refuses missing/Private spaces. Broken routes (defensive only, deletion is blocked) show '⚠ Space deleted' and stay editable.
- SpaceDeletionBlockedAlert: 'Open Links Settings…' opens the pane with the blocking routes (by saved target) and Default highlighted, scrolled to the first; used from the sidebar, the Spaces pane and the undo/redo refusal.
- TDD: red LinkRouteEditorTests 13/13 failing, LinkRouteStoreTests 12/38 failing (10 new + 2 relying on the old check); green 51/51. (A first red run crashed the host on rows[0]; tests switched to XCTUnwrap and re-run red.)
- /code-review --fix: 7 findings, 6 fixed: draft shown twice during the store notification on save; field edits lost when New Route/pop-ups/⊖/drop reloaded the table (commitPendingEdit); highlight used the shown rather than saved target; From-app menu rebuilt on every refresh; a Private-space test became vacuous under the new validation; duplicated http(s) check (isRoutableURL now shared). Skipped: per-refresh space-context rebuild (small at current sizes). Own review of captures: the refused-edit warning was truncated; fixed as a wrapping line under the route.
- Tests (final): LinkRouteEditor 14, LinkRouteStore 39, LinkRouteResolver 38, LinkPlacement 19, ExternalLinkRouting 13, LinkRoutingEligibility 40, InPageLinkRouting 21, UndoAfterDeleteSpace 8, TabStore 40, AppDatabase 28, SettingsPaneHeight 20, ProfileSettingsLayout 15; all pass.
- Runtime (docs/harness/task191-3-harness.patch, real posted input, light + dark, twice: before and after the review fixes): add/edit/match kind/target/remove/Default take effect for the next link without restart; refused edit keeps routing by the saved route; Finder From-app route matched only Finder; space rename updates the popups; all three alert paths open the pane highlighted; drafts committed by New Route, pop-up change and Tab; empty state; 23 routes reach the height cap and scroll; warnings shown in full. Not verified: a person's own drag with the gap animation (reorder driven by a stub drop), choosing an app in the open panel (shown and cancelled only).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Settings has a Links pane for Air Traffic Control: routes with a URL condition, a From app condition or both, an Open in target, drag to reorder, and the Default. Incomplete or invalid edits are never saved (the store validates; rows show why), routes to a deleted space show as broken, and the can't-delete-space alert opens the pane with the blocking routes highlighted. Changes apply to the next link. Tests pass; checked at runtime in light and dark with real input before and after the review fixes.
<!-- SECTION:FINAL_SUMMARY:END -->
