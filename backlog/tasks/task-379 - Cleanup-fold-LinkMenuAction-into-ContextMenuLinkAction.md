---
id: TASK-379
title: 'Cleanup: fold LinkMenuAction into ContextMenuLinkAction'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T09:55:00Z'
updated_date: '2026-11-16T21:45:00Z'
labels:
  - cleanup
  - links
dependencies: []
references:
  - wiki/features/link-routing-in-page.md
priority: low
type: chore
ordinal: 460000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-356's review. TASK-356 added LinkMenuAction (which Open Link item was chosen) next to the existing ContextMenuLinkAction; folding them touches about 37 call sites.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 One enum names the link menu's actions; behaviour and tests unchanged
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Keep one enum: ContextMenuLinkAction (the task title's direction), moved out of BrowserWindowController to top level in LinkRouting/LinkRoutingEligibility.swift (the pure routing rule needs it), cases openInNewTab/openInNewWindow/openInSplitView/openInQuickDetour (the menu items' names), Equatable + CaseIterable; no .none case — the window's pending choice becomes ContextMenuLinkAction? (nil = none).
2. Remove LinkMenuAction and the linkMenuAction bridge property; InPageLinkEntry.linkMenuAction carries ContextMenuLinkAction; createWebViewWith routes on the optional and switches on it with a nil branch for the page's own requests.
3. Update tests (LinkRoutingEligibilityTests, InPageLinkRoutingTests, OpenInQuickDetourMenuTests) for the renamed type/cases only; wiki link-routing-in-page.
4. Run LinkRoutingEligibilityTests, InPageLinkRoutingTests, LinkPlacementTests, OpenInQuickDetourMenuTests, PageOpenedWindowTests; /code-review.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Done: one top-level enum ContextMenuLinkAction (LinkRouting/LinkRoutingEligibility.swift), cases openInNewTab/openInNewWindow/openInSplitView/openInQuickDetour, Equatable + CaseIterable. LinkMenuAction, the nested BrowserWindowController.ContextMenuLinkAction, its .none case and the linkMenuAction bridge are gone; the window holds ContextMenuLinkAction? (nil = a page's own request), createWebViewWith routes 'if let' and switches with 'case nil'. Tests changed only for the type and case names (and XCTAssertNil / = nil for the consumed action).

Chosen by Claude (not yet confirmed by the user): the surviving name is ContextMenuLinkAction (the task title) with the menu items' case names; the rule's entry case and exclusion keep the name linkMenuAction (InPageLinkEntry.linkMenuAction, LinkRoutingExclusion.linkMenuAction), so the rule's API and the wiki tables did not change. Alternative: keep LinkMenuAction (newTab, ...) as the one name and make the window's property LinkMenuAction?; or also rename the entry case.

Tests (sandbox off, -only-testing): InPageLinkRoutingTests 34, LinkPlacementTests 24, LinkRoutingEligibilityTests 51, OpenInQuickDetourMenuTests 11, PageOpenedWindowTests 11 — 131 tests, 0 failures. No other suite references either type (grep of Detour/DetourTests/wiki/docs). No /verify: behaviour-neutral refactor.

Review (/code-review medium --fix, forked): no correctness findings. Fixed: wiki/log.md line + generated stamp. Not fixed: (a) naming mix linkMenuAction case vs ContextMenuLinkAction type (cosmetic, see choice above); (b) pre-existing: if WebKit's replay of a menu item never reaches createWebViewWith the pending action stays set and the page's next window.open is treated as that menu choice (skips the data: refusal and pageWindowRequest routing) — out of scope, reported to the lead.

User decisions 2026-11-16: confirmed: the surviving name is ContextMenuLinkAction with the menu items' case names; the rule's entry case and exclusion keep linkMenuAction (InPageLinkEntry.linkMenuAction, LinkRoutingExclusion.linkMenuAction). Follow-up filed: TASK-398 (a menu action WebKit never acts on stays pending and takes the page's next window.open; pre-existing).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Folded TASK-356's LinkMenuAction into one top-level ContextMenuLinkAction enum (openInNewTab/openInNewWindow/openInSplitView/openInQuickDetour) used by both the window's pending link-menu choice (now ContextMenuLinkAction?, nil for none) and the pure routing rule (InPageLinkEntry.linkMenuAction). Behaviour unchanged; tests changed only for the names. 131 tests in the five link suites pass. Review found no bugs; a pre-existing stale-pending-action edge case was reported as a possible follow-up.
<!-- SECTION:FINAL_SUMMARY:END -->
