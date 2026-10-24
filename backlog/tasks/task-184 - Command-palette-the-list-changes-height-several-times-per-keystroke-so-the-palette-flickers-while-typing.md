---
id: TASK-184
title: >-
  Command palette: the list changes height several times per keystroke, so the
  palette flickers while typing
status: To Do
assignee: []
created_date: '2026-10-24 08:52'
updated_date: '2026-10-24 08:58'
labels:
  - command-palette
  - bug
  - ui
dependencies: []
priority: medium
ordinal: 206000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported by the user 2026-10-24: Arc's palette keeps one height while you type; ours visibly changes height, which reads as flicker.

Cause (from the code): `CommandPaletteView.updatePanelHeight` sizes the list to `min(rows, 6) * 36 pt` on every `updateSuggestions` / `appendSearchSuggestions`, and each keystroke rebuilds the list up to three times (see wiki/features/suggestion-pipeline.md, 'Two passes per keystroke'):
1. the instant main-thread pass (open tabs only: top hit, verbatim row, up to 3 tabs), often 1-2 rows;
2. the background history pass a few ms later, usually more rows;
3. network search suggestions ~150 ms later (debounced), more rows again.
So the box shrinks at every keystroke and then grows back in one to three steps. The TASK-181/182 runtime harness log showed it: after one Backspace the list went 4 rows -> 6 rows between two snapshots 0.7 s apart with no further typing. The box's top stays put (the centred position uses the maximum height), so it is the bottom edge and the rows below the first few that jump.

Options:
- A: fixed list height while the palette shows suggestions (six rows of space; rows not filled stay empty), as Arc appears to do. Simplest and steadiest; the box is taller for short lists.
- B: never shrink within one query's rebuilds and only re-fit when the query changes. Still moves once per keystroke.
- C: also keep the instant pass from replacing longer rows with fewer: carry the previous query's history rows until the background pass lands. Reduces row flicker, not only height.
Recommendation: A (decide whether the default list with nothing typed, and the no-suggestion state, also keep the fixed height), plus C if rows still visibly blink.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 While typing a query, the palette's height does not change from keystroke to keystroke or between the instant, history and search-suggestion passes
- [ ] #2 Behaviour for the empty-field default list and for a query with no suggestions is decided and recorded
- [ ] #3 Checked at runtime by logging the glass container's frame across keystrokes and passes (harness), before and after
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decision (user, 2026-10-24): keep a fixed height — option A — for every state the palette shows a list in.
<!-- SECTION:NOTES:END -->
