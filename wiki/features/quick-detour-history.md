---
type: Feature
title: Quick Detour history scope
description: "How Quick Detour visits are recorded: under a per-profile scope id that is no space (the profile id XORed with a mask), labelled on the History page, kept by the launch sweep, with the rejected nullable-column migration, and the profile-wide palette suggestions."
tags: [history, palette, profiles]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:00:09Z }
sources:
  - id: task-193-1
    resource: backlog:TASK-193.1
    title: "Quick Detour: the window, its single tab and the palette that opens it"
  - id: task-209
    resource: backlog:TASK-209
    title: "Command palette: scope suggestions to the palette's profile"
  - id: rules
    resource: ../../Detour/Browser/QuickDetour/QuickDetour.swift
    title: QuickDetour.swift (history scope, which profile, palette scope)
  - id: store
    resource: ../../Detour/Browser/QuickDetour/TabStore+QuickDetour.swift
    title: TabStore+QuickDetour.swift
  - id: palette-scope
    resource: ../../Detour/Browser/CommandPalette/PaletteTabScope.swift
    title: PaletteTabScope.swift (historySpaceIDs)
---

A Quick Detour is in no space, but every history query is keyed by a space id. Its visits are filed under a per-profile id that no space has.

# Decision

Decision 1 (user, 2026-10-25): visits are recorded under the window's
profile with no space, labelled "Quick Detour" on the History page,
searchable like any visit, and no space's history is touched. A Private Quick Detour records nothing (`recordHistoryVisit` checks
`quickDetourProfile.isIncognito`).

# How it works

`historyVisit.spaceID` is `TEXT NOT NULL` and every reader scopes by it, so a
Quick Detour visit is filed under `QuickDetour.historySpaceID(forProfileID:)`,
the profile id XORed with a fixed mask: deterministic, needing no storage,
and never any space's id. `BrowserTab.historySpaceID` (`spaceID ?? that
scope`) is what the recorder, the same-document recorder and the late-title
correction read. `HistoryPageBridge.scope(forProfile:)` adds the scope, so
the History page and `chrome.history.search` include these visits; the
History page marks each with `quickDetour: true`, rendered as a small "Quick
Detour" label. The launch sweep keeps each live profile's scope and sweeps a
deleted profile's with its spaces'. The scopes are a keep-list only: they
never count as proof that the space table is intact, so a session that failed
to restore still stops the sweep (`deleteVisits(notInSpaceIDs:alsoKeeping:)`). Details on
[history recording and search](./history-recording-and-search.md).

# Alternatives rejected

A migration making `spaceID` nullable plus a `profileID`
column. Every query and index is keyed by space id
(`historyVisit_spaceID_visitTime`, `historyTitle`'s unique key and its
triggers); a nullable column would need each of them changed for one kind of
visit, where a sentinel id rides them unchanged. Also rejected in the task:
filing under the profile's first space (it would touch a space's history),
and recording nothing.

# Palette suggestions

The launcher's palette and the window's suggest from the profile's whole
history, its spaces and this scope (`PaletteTabScope.historySpaceIDs`, the
History page's scope), whichever window they were asked from; nothing for the
Private profile, so nothing in a Private Quick Detour or a quarantine
(TASK-209). Until then they read the space they were asked from when it was
the same profile's, else only the Quick Detour scope
(`QuickDetour.paletteHistorySpaceID`, removed).

When the page moves into a space ([Open in](./quick-detour-open-in.md#history))
or the window switches profile ([profile pill](./quick-detour-profile-pill.md#consequences)),
the visits so far stay under the old scope and later ones go to the new one.

# Tests

Suites, counts and the runtime passes are on [Quick Detour tests and runtime checks](./quick-detour-tests.md).

# Related

- [Quick Detour](./quick-detour.md) — the hub: what the window is and the list of its pages.
- [History recording and search](./history-recording-and-search.md) — the recorder and the sweep the scope rides.
- [History page](./history-page.md) — the "Quick Detour" label.
- [Suggestion pipeline](./suggestion-pipeline.md) — the profile-scoped palette history (TASK-209).
- [Quick Detour archive and idle auto-close](./quick-detour-archive.md) — closed-tab rows filed under the same scope.
- [Quick Detour tests and runtime checks](./quick-detour-tests.md) — the suites, what was written first, and the runtime passes.
