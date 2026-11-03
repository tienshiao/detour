---
id: TASK-231.2
title: >-
  Concurrency: history and session database access is compiler-checked across
  threads
status: To Do
assignee: []
created_date: '2026-11-03T00:07:00Z'
labels:
  - concurrency
dependencies:
  - TASK-231.1
references:
  - Detour/Storage/HistoryDatabase.swift
  - Detour/Storage/Database.swift
  - Detour/Browser/TabRecord+BrowserTab.swift
  - Detour/Browser/InternalPages/HistoryPageBridge.swift
  - Detour/Browser/CommandPalette/CommandPaletteView.swift
documentation:
  - wiki/architecture/history-database.md
  - wiki/architecture/session-database.md
parent_task_id: TASK-231
priority: medium
type: chore
ordinal: 269000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The history database is read and written from several threads: GRDB's asyncWrite completions run on the writer queue, the command palette runs its history queries on its own queue (CommandPaletteView historyQueryQueue), and the History page bridge dispatches to a global queue. HistoryDatabase.QueryTokenCache is an NSLock-guarded `@unchecked Sendable` class. At the 2026-11-02 measurement this area had the most warnings: HistoryDatabase 32, TabRecord+BrowserTab 11, HistoryPageBridge 6. Context: the Synchronization framework's Mutex is available from macOS 15, and the deployment target is 15.4.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 No concurrency warnings remain in Storage/, the palette history pass (CommandPaletteView, SuggestionProvider), HistoryPageBridge or TabRecord+BrowserTab
- [ ] #2 `@unchecked Sendable`, `nonisolated(unsafe)` and `MainActor.assumeIsolated` remain only where the compiler cannot check the code, each with a comment saying what makes it safe
- [ ] #3 History, session save/restore, palette suggestions and History page results are unchanged: HistoryDatabaseTests, the History*Tests suites, AppDatabaseTests, the SessionSave*/SessionSnapshot* suites, SuggestionProviderTests and InternalPageIntegrationTests pass, and the palette still drops a background result whose query is stale
- [ ] #4 The affected test suites pass under Thread Sanitizer (`xcodebuild ... -enableThreadSanitizer YES`), or the task records why a suite cannot run under it
<!-- AC:END -->
