---
id: TASK-137
title: >-
  Command palette: a normal window's open-tab suggestions include tabs from open
  Private windows
status: In Progress
assignee: []
created_date: '2026-10-04 01:58'
updated_date: '2026-10-04 08:12'
labels: []
dependencies: []
references:
  - wiki/architecture/incognito.md
  - Detour/Browser/CommandPalette/CommandPaletteView.swift
priority: high
ordinal: 160000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
CommandPaletteView.gatherTabInfos (Detour/Browser/CommandPalette/CommandPaletteView.swift) narrows the space list only when the palette's own window is Private: `spaces.filter { !isIncognito || $0.id == activeSpaceID }`. In a normal window isIncognito is false, so the filter passes every space in TabStore.spaces, which includes the spaces of open Private windows. Their tabs (URL, title, favicon) are handed to SuggestionProvider as open-tab candidates and can appear in the suggestion list, as the top hit, and as a switch-to-tab target. Found by reading the code while writing wiki/architecture/incognito.md; not yet observed in the running app.

Expected: a Private window's tabs are never offered in another window's palette; a Private window's palette keeps offering only its own space's tabs.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A normal window's palette (empty query and typed query, including the top hit) never lists a tab that belongs to an incognito space
- [x] #2 A Private window's palette still lists the open tabs of its own space and of no other
- [x] #3 The space filtering is a testable rule with a unit test that fails before the fix (normal window + open Private window; Private window + normal spaces)
- [x] #4 wiki/architecture/incognito.md and wiki/features/suggestion-pipeline.md are updated
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extract the space filter as a pure rule: PaletteTabScope.offeredSpaceIDs(spaces:windowIsPrivate:activeSpaceID:) (inputs: each space's id + incognito flag, whether the palette's window is Private, its active space id).
2. Failing tests first (PaletteTabScopeTests): normal window + open Private window; Private window + normal spaces; second Private window; fail-closed cases.
3. Rule: a normal window is offered only non-incognito spaces; a Private window is offered only its own active space.
4. CommandPaletteView.gatherTabInfos calls the rule (both the empty-query and typed-query paths go through it, so the top hit is covered).
5. grep TabInfo( for other callers that hand tabs to the suggestion pipeline.
6. Update wiki/architecture/incognito.md, wiki/features/suggestion-pipeline.md (and the palette pages that state the old rule), wiki-lint, wiki/log.md.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation (branch worktree-agent-ab102709ae8060f37, based on bugfix-batch 5bc537c).

Rule: new pure function PaletteTabScope.offeredSpaceIDs(spaces:windowIsPrivate:activeSpaceID:) in Detour/Browser/CommandPalette/PaletteTabScope.swift. A normal window is offered every non-incognito space; a Private window is offered its own space only (not another Private window's). Fail-closed addition beyond the task text: a window whose active space is incognito counts as Private even when the flag (which reaches the palette through the optional profile) says otherwise; a Private window with no or an unknown active space is offered nothing.

CommandPaletteView.gatherTabInfos now calls the rule. Space incognito state is read as Space.isIncognito (= profile?.isIncognito ?? false). gatherTabInfos feeds both loadDefaultSuggestions (empty query) and refreshLocalSuggestions (instant pass and the background localSuggestions pass, so the top hit and inline completion too), so AC #1 holds for all of them. It was made internal (was private) for the wiring test.

Other callers: grep for TabInfo( finds only gatherTabInfos outside the tests; SuggestionProvider never reads TabStore. No other caller hands tabs to the suggestion pipeline, so nothing else needed fixing.

TDD: the rule was first extracted with the old behaviour. Red run (PaletteTabScopeTests + PaletteTabScopeWiringTests, 10 tests, 5 failing): testNormalWindowIsNotOfferedAnOpenPrivateWindowsSpace, testNormalWindowIsOfferedNoneOfSeveralPrivateWindowsSpaces, testNormalWindowWithoutAnActiveSpaceIsStillOfferedNoPrivateSpace, testAWindowShowingAnIncognitoSpaceIsTreatedAsPrivateEvenWhenNotFlagged, and the wiring test testNormalWindowPaletteIsNotHandedAPrivateWindowsTabs (real TabStore with a normal space and an incognito space: the Private tab was in the list). The Private-window direction (testPrivateWindowIsOfferedOnlyItsOwnSpace, testPrivateWindowIsNotOfferedAnotherPrivateWindowsSpace, testPrivateWindowPaletteIsHandedOnlyItsOwnSpacesTabs) passed before and after: that direction was already correct, the tests guard it.

After the fix: PaletteTabScopeTests 8/8, PaletteTabScopeWiringTests 2/2, SuggestionProviderTests 19/19, CommandPaletteFocusTests 4/4 (33 tests, 0 failures).

Not verified: nothing was checked in the running app (the leak itself was never observed at runtime either); /code-review and /verify are left to the supervising session.

Docs: wiki/architecture/incognito.md (new rule section, item removed from 'Not covered'), wiki/features/suggestion-pipeline.md (new 'Which open tabs are candidates' section, invariant, tests), wiki/features/command-palette.md (edge case), docs/command-palette.md (Open Tabs paragraph), wiki/log.md. CLAUDE.md's directory layout does not list the new file (not edited by the agent).
<!-- SECTION:NOTES:END -->
