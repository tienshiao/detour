---
id: TASK-409
title: >-
  Quick Detour launcher: suggestions come only from the frontmost window's
  profile, so pages from another profile's spaces can't be found
status: Done
assignee:
  - '@claude'
created_date: '2026-11-17T21:35:00Z'
updated_date: '2026-11-17T21:58:00Z'
labels:
  - quick-detour
  - palette
  - profiles
dependencies: []
priority: medium
type: feature
ordinal: 490000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported by the user on 2026-11-17: the global-hotkey Quick Detour palette seems scoped to the frontmost Detour window, so its suggestions only come from that space, which is annoying when looking for something that was in another space.

What the code and wiki say:
- The panel uses the profile of the frontmost Detour window (QuickDetour.profileForNewWindow, the user's TASK-193.4 decision).
- Its history is that profile's whole history: every space of the profile plus the profile's Quick Detour scope (PaletteTabScope.historySpaceIDs, TASK-209).
- It offers no open-tab rows at all, because switching to a tab would bring a browser window forward.
- So a space of the same profile is searched. A space of another profile is not, and the user's two spaces sit on different profiles: Home on Personal, Work on Work.
- TASK-209 (the user's request, 2026-10-26) made every palette row come from the palette's profile only. This ticket revisits that rule for the Quick Detour launcher, which is not tied to a browser window.

Arc, from secondhand sources only (no official doc found):
- Arc's built-in command bar appears to follow the active space's profile; suggestions reset when switching to a space of another profile.
- The Browser Company's own Raycast extension searches history across all Arc profiles and labels each result with its profile.
- Little Arc's profile behaviour was not confirmed.

Open decision for the user: whether the launcher should search other profiles (labelled, opening the Quick Detour in the row's profile so its cookies/logins apply), only on request (a modifier or prefix), or stay as it is.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The user's decision on cross-profile suggestions in the Quick Detour launcher is recorded here
- [x] #2 Whatever is decided, the Private profile's history never appears outside a Private context, and in-window palettes (Cmd+T, Cmd+L) keep TASK-209's profile scoping unless the user decides otherwise
- [x] #3 Suggestion pipeline tests cover the decided scope for the launcher
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. PaletteHistoryProfiles (every non-Private, non-deleted profile; union scope).
2. HistoryDatabase.latestVisitSpaceIDs plus SuggestionProvider.historyProfileIDs attribute each history row to the profile of its newest visit, off the main thread with each pass.
3. CommandPaletteView labels every history row while there is more than one profile, and answers historyProfileID(forSubmittedInput:).
4. QuickDetourLauncher uses the union and submits a row in its own profile; the source space goes along only within its own profile.
5. open_ui quick_detour_launcher for runtime checks; tests; wiki.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
User decision 2026-11-17: the user checked Arc. Arc behaves like Detour today: the palette is scoped to the frontmost window's profile, and switching windows switches the scope. For Detour's Quick Detour launcher, the user chose the recommendation: suggestions from every normal profile's history, each row labelled with its profile. All rows are labelled, the frontmost profile's included, because someone who switches profiles often may not remember which one they last used. Picking a row opens the Quick Detour in that row's profile. In-window palettes (Cmd+T, Cmd+L) keep TASK-209's profile scoping.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The Quick Detour launcher suggests from every normal profile's history, as the user decided.
- Labels: every history row names its profile, the frontmost one's too, while there is more than one profile. The name sits before the address, and the address truncates first.
- Attribution: a row belongs to the profile of its newest visit. A host row whose root address was never visited takes its host's newest visit (added in review).
- Opening: picking a row, or submitting the field its top hit completed, opens the Quick Detour in that row's profile, without another profile's source space. Searches and typed addresses use the launcher's profile.
- Unchanged: a Private launcher reads no history, and in-window palettes keep TASK-209's single-profile scope.
- Automation: open_ui quick_detour_launcher (Debug/test runs) opens the panel, types into it and reports its rows, so the launcher can be checked without the global hotkey.

Review: 8 findings; the reviewer fixed 4 (host-root attribution, deterministic field matching, Private gate and true front window in open_ui, a misplaced doc comment). I fixed 2 more (a reused cell's font, typing twice in open_ui). Left: a second history read on the main thread when the empty-field list loads (not on the typing path), and the fixed 600 ms wait in open_ui.

Tests: 268 passed (QuickDetourCrossProfilePalette 11, QuickDetourLauncher, AutomationStaging, SuggestionProvider, PaletteTabScope, SiteSearchPalette, QuickDetourWindow, HistoryDatabase).

Runtime: an isolated build seeded with Home and Work profiles (docs/harness/task409-world.json), launcher opened from the Home window. It listed Work's Jira ticket and the shared docs labelled Work (Work visited last) next to Home's news labelled Home. The screenshot shows 'Work · https://…' with the name in semibold.

Claude's choices:
- No labels with a single profile.
- Search and search-suggestion rows carry no label (they open in the frontmost profile).
- A URL visited by several profiles appears once, credited to the latest visitor.
<!-- SECTION:FINAL_SUMMARY:END -->
