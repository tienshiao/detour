---
id: TASK-209
title: 'Command palette: scope suggestions to the palette''s profile'
status: Done
assignee:
  - '@claude'
created_date: '2026-10-26 07:08'
updated_date: '2026-10-27 09:45'
labels:
  - command-palette
  - profiles
dependencies: []
priority: medium
ordinal: 245000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the user 2026-10-26: the command palette should be scoped to the profile; history and other suggestions from other profiles must not appear as options.

Today (wiki/features/suggestion-pipeline.md):
- Open tabs: a normal window's palette offers the tabs of every non-incognito space (PaletteTabScope.offeredSpaceIDs), including spaces of other profiles. 'Switch to Tab' can therefore jump into another profile.
- History (top hit, history rows, inline completion, recent pages in the empty-field list and the TASK-184 filler rows) is scoped to the active space (TASK-94 decision), so it is narrower than the profile.
- Search suggestions use the active space's profile engine.

Change: every row the palette shows comes from the palette's profile only: open tabs from that profile's spaces (never another profile's, never across the Private boundary), history from that profile, filler rows likewise. Decide and record whether history widens from the space to the whole profile (matching the History page and the Quick Detour scope, which the profile's History page already includes) or stays space-scoped within the profile; this revisits TASK-94. Check every entry point: Cmd+T, Cmd+L, the empty-state 'Where to next?' palette, the Quick Detour launcher and its in-place palette.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 No palette row (open tab, history, top hit, inline completion, empty-field or filler row) comes from another profile, in every palette entry point
- [x] #2 History scope within the profile (space or whole profile) is decided with the user and recorded, replacing the TASK-94 note if it changes
- [x] #3 PaletteTabScope and the history lookups are driven by tests first (PaletteTabScopeTests, suggestion-provider tests), including two profiles with overlapping URLs
- [x] #4 Checked at runtime with two profiles
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Tests first (red): PaletteTabScopeTests - SpaceRef carries profileID; a normal window is offered only its active space's profile's non-incognito spaces (two profiles), nothing without an active space; history scope helper = the History page's scope (profile spaces + Quick Detour scope), empty for Private/deleted/nil. HistoryDatabase palette lookups take a scope (spaceIDs): two profiles with overlapping URLs/titles, sibling-space history and titles now shown, legacy shared-title guard widened to 'no visit outside the scope'. SuggestionProvider tests over two profiles. Quick Detour palette/launcher wiring tests.
2. PaletteTabScope: profile rule for open tabs; historySpaceIDs(profile:in:) reusing HistoryPageBridge.scope(forProfile:in:).
3. HistoryDatabase: recentHistory/searchHistory/bestURLCompletion/bestHostCompletions take spaceIDs through a scope CTE; label expression binds nothing; recentHistory walks newest-first per space (newestVisitPerURL, TASK-97) since a profile is wider than a space.
4. SuggestionProvider + CommandPaletteView take historySpaceIDs set by every creator (browser window showCommandPalette = Cmd+T, Cmd+L, faux address bar, empty state; Quick Detour window palette; launcher). Remove QuickDetour.paletteHistorySpaceID.
5. Measure with HistoryBenchmarkTests before/after (completion + search legs over a multi-space scope).
6. Runtime harness: two profiles with overlapping URLs/titles, type in each window's palette, log rows, light+dark captures.
7. Wiki (suggestion-pipeline, history-recording-and-search, history-own-title-matching decision, quick-detour, incognito if needed), code review, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decision (user, 2026-10-26): history in the palette widens from the active space to the whole profile, like the History page (including the profile's Quick Detour visits). This replaces the TASK-94 space-scoped decision; update wiki/features/suggestion-pipeline.md and the history own-title matching page accordingly (row titles then come from the profile's own visits, never another profile's).

Queued (user, 2026-10-26): after TASK-202 (order: 193.5, 194, 201, 202, 209).

Decision (user, recorded in the queue handover 2026-10-26): history in the palette widens to the whole profile, replacing the TASK-94 space scope. The profile's history is the History page's scope (HistoryPageBridge.scope(forProfile:)): the profile's spaces plus its Quick Detour scope. Private windows and quarantines (Private profile) get no history.

Implementation:
- PaletteTabScope.offeredSpaceIDs: SpaceRef carries profileID; a normal window is offered the non-incognito spaces of its active space's profile; no active space (or a missing one) offers nothing (was every normal space). Private unchanged (own space only).
- PaletteTabScope.historySpaceIDs(profile:in:) = HistoryPageBridge.scope(forProfile:in:) ?? [] (profile's spaces + Quick Detour scope; [] for Private, quarantine, deleted, nil). CommandPaletteView.historySpaceIDs set by every creator: BrowserWindowController.scopeCommandPalette (Cmd+T, Cmd+L, faux bar, sidebar New Tab, empty state), QuickDetourWindowController.showPalette, QuickDetourLauncher.show. QuickDetour.paletteHistorySpaceID removed.
- HistoryDatabase: recentHistory/searchHistory/bestURLCompletion/bestHostCompletions take spaceIDs through a scope CTE (scopeCTE, shared with chrome.history's urlEntriesSelect); the label binds nothing; the legacy fallback guard is 'no visit outside the scope'. recentHistory uses the newestVisitPerURL walk (TASK-97's proposal). searchHistory's EXISTS probes are +v.spaceID (urlID index). Completions drive from historyURL (CROSS JOIN, + on visit terms).
- Performance (HistoryBenchmarkTests, Debug, 55k visits, median of 5; before = one space 45% of visits, after = profile 80%): searchHistory a 49->25 ms, URL token 22->1.1, title word 30->8.5, own-title 7.2->1.0; recentHistory (main thread) 33->9; bestURLCompletion s 24->40, site13 15->3.2; bestHostCompletions s 38->61, site13 16->4.6. Only a one-letter prefix matching every URL is slower (more in-scope visits to sum). A visit-driven first cut measured site13 at 24 ms; the URL-driven plan was kept.
- Code review (high, --fix): fixed a palette left open while the window switches to another profile's empty space (setActiveSpace re-scopes it, CommandPaletteView.reloadSuggestions; test added), the duplicated scope CTE, and the HistoryURLSearchBenchmarkTests palette legs (now the profile). Skipped: recentHistory's walk on the main thread for a profile with few distinct URLs and many visits (same walk chrome.history uses; moving the empty list off main is beyond this task); the PaletteTabScope.historySpaceIDs wrapper (deliberate palette-side name).
- Pre-existing, not from this change: running QuarantineTests/QuarantineWindowTests before the Quick Detour window suites makes 12 loopback page loads time out in QuickDetourWindowTests (same 12 at HEAD with the same suite set); each Quick Detour suite passes on its own.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Every command palette row now comes from the palette's profile. Open tabs: the active space's profile's spaces only (Switch to Tab no longer jumps into another profile). History (rows, top hit, inline completion, host rows, empty-field list, TASK-184 filler): widened from the active space to the whole profile, the History page's scope incl. its Quick Detour visits (user decision 2026-10-26, supersedes TASK-94); none for Private windows, Private Quick Detours and quarantines. All entry points: Cmd+T, Cmd+L, faux bar, sidebar New Tab, empty state, Quick Detour window palette, launcher; an open palette follows a space switch to another profile.

Tests (TDD, red first): PaletteTabScopeTests 9, PaletteHistoryScopeTests 3, PaletteTabScopeWiringTests 3, PaletteEntryPointScopeTests 3, HistoryDatabaseTests 136, SuggestionProviderTests 34, HistoryTitleIndexTests 12, HistoryURLSearchTests 18, ExtensionHistoryScopeTests 17, HistoryDeletionIntegrationTests 63, InternalPageIntegrationTests 13, PaletteSelectionTests 14, PaletteRowsTests 12, CommandPaletteFocusTests 4, QuarantineTests 31, QuarantineWindowTests 22, QuickDetourLauncherTests 13, SidebarPageFocusTests 27, TabStoreTests 40, WebViewHandoffFocusTests 7: all pass. QuickDetourTests 27 + QuickDetourWindowTests 15, QuickDetourOpenInWindowTests 17 + QuickDetourProfileSwitchTests 23 + QuickDetourProfileSwitchWindowTests 17: pass run on their own; after the quarantine suites in one run 34 time out on loopback loads, identically at HEAD (pre-existing ordering problem). HistoryBenchmarkTests before/after recorded in the notes and the wiki.

Runtime (docs/harness/task209-harness.patch, DetourVerify2090, light and dark): two profiles with overlapping URLs/titles, 18 palettes per run across every entry point, rows logged from the palette table: 0 rows from the other profile, sibling-space and Quick Detour history found, Private shows no history, the open palette follows a profile switch. Not verified: pixels (screen locked the whole session: palettes opened by direct calls and typed through the field editor, no screenshots), posted Cmd+T/Cmd+L key equivalents (fallback used), the WebKit data-store folders the isolated run created under ~/Library/WebKit (left in place).
<!-- SECTION:FINAL_SUMMARY:END -->
