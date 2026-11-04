---
id: TASK-197
title: >-
  Dev mode: tie the under-construction motif to the Detour branding (orange
  hazard border)
status: Done
assignee:
  - '@claude'
created_date: '2026-10-24 21:05'
updated_date: '2026-10-24 23:29'
labels:
  - dev-mode
  - branding
  - design
dependencies: []
priority: low
ordinal: 233000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the user 2026-10-24 (an idea to explore): tie dev mode's 'under construction' look more to the branding and icon. For example, the sidebar row's hazard border could be more orange than yellow.

Today (TASK-186.1, HazardBorderView): systemYellow solid stroke under a near-black dashed 1.5 pt 4/4 stroke; the dev toolbar (TASK-186.2, DevToolbarView) uses faint diagonal stripes. The icon's plate is orange rgb(255,118,0) with black, i.e. road-construction signage colours, so an orange-and-black border and stripes would echo it.

To explore: border colour (brand orange vs a slightly lighter orange for contrast on the sidebar's tint), whether the toolbar stripes pick up a faint orange, light and dark mode contrast, and selected vs unselected rows. If the app icon task changes the palette, follow it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A couple of options (e.g. brand orange, lighter orange, current yellow) compared in window captures, light and dark, selected and unselected rows
- [x] #2 The chosen colours applied to the sidebar border and, if agreed, the toolbar stripes, defined once and shared
- [x] #3 Checked at runtime, light and dark
- [x] #4 Like Arc, only the selected row shows the hazard border; an unselected dev-mode row keeps the host line but no border (user, 2026-10-24)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Related: TASK-196 (app icon); if it changes the palette, follow it.

Decision (user, 2026-10-24): option B, brand orange #FF7600 (the icon's plate) for the border on today's 1.5 pt line with near-black dashes; toolbar stripes stay grey. Applied in DevModePalette.standard (brandOrange). Options and contrast: docs/harness/task197-harness.patch header.

User note (2026-10-24): Arc shows the border only on the selected tab; an unselected tab shows the two lines (title + host) but no border. Taken into this task. Choices made here: a selected split row borders its dev-mode half/halves; an unselected split row shows no marking (split halves have no host line); a favourite tile is bordered only when it is the selected tab; selection is per window, so each sidebar decides by its own selection.

Built (2026-10-24, Opus subagents): DevModePalette (hazard = brandOrange rgb(255,118,0) both appearances, hazardDash near-black, toolbarStripe grey; DEBUG-only debugOverride used by the comparison harness) read by HazardBorderView and DevToolbarView. Selected-row rule: pure DevModeRowMarking.display(isSelected:) -> DevModeRowDisplay(hostLabel, showsMainBorder, showsRightBorder): .tab keeps its host line always and the border only when selected; .split borders its dev half/halves only when the split row is selected, else nothing; .none nothing. Selection reaches cells through TabRowView.isSelected (NSTableView keeps row views in step without reloads) -> TabCellView.isRowSelected, also read in viewDidMoveToSuperview; favourite tiles through the bar's existing updateSelection -> tile.isSelected. No sidebar controller changes; no row geometry changes (title/host frames identical across steps).

TDD: DevModeTests red 8 of 41 failing (16 assertions) with a stub returning .hidden; green 41/41.

/code-review --fix: 4 findings, 1 fixed (a real bug): a dormant favourite (no tab) compared nil == nil with an empty selection and counted as selected, so it got the border and the selected background whenever nothing was selected; FavoritesBarView.isSelected(_:selectedTabID:) now returns false for a nil selection at all four sites, with testDormantFavoriteTileIsNotSelectedWhenNothingIs (not run red before the fix). Skipped: the DEBUG debugOverride hook and internal updateColors exist for the saved comparison harness; host label read through display(isSelected:) keeps one rule (style).

Tests after review: 247/247 (DevModeTests 42, DevModeSiteOverrideTests 15, DevToolbarHostingTests 12, FavoriteFaviconTests 4, FavoriteTileBadgeTests 9, SidebarLayoutTests 41, SplitTabTests 63, TabStoreTests 40, DevToolbarLayoutTests 21).

Runtime: docs/harness/task197-harness.patch (five colour options compared at 2x, light and dark, with WCAG contrast) and docs/harness/task197b-harness.patch (selection rule at 2x, light and dark; re-run after the review with an identical log, screen unlocked): selected dev row bordered, other dev rows host line only; border follows a table selection change; a normal tab selected leaves no borders and all host lines; selected split borders only its dev half whichever pane is focused, unselected split nothing; favourite tile bordered only when selected; live pinned row bordered when selected, dormant pinned row host line only; two windows each border their own selection; space switch and closing the selected tab move the border correctly. Border pixels read #FF7600 alternating with #191919 (light) / #0D0D0D (dark). Not verified: Ctrl+Tab/keyboard selection driven separately (same selectTab path), a real mouse click (table selectRowIndexes used), flicker during split-collapse or drop animations (temporary cells outside a row view draw no border).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Dev mode's hazard border is now the app icon's orange (#FF7600) with near-black dashes, chosen from five options compared at 2x; toolbar stripes stay grey; colours defined once in DevModePalette. Like Arc, the border shows only on the selected row (unselected dev rows keep the host line), per window, including split halves and favourite tiles. 247 tests pass; runtime harness clean after review.
<!-- SECTION:FINAL_SUMMARY:END -->
