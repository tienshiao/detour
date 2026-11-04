---
id: TASK-231.2
title: >-
  Concurrency: history and session database access is compiler-checked across
  threads
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T00:07:00Z'
updated_date: '2026-11-03T01:02:00Z'
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
- [x] #1 No concurrency warnings remain in Storage/, the palette history pass (CommandPaletteView, SuggestionProvider), HistoryPageBridge or TabRecord+BrowserTab
- [x] #2 `@unchecked Sendable`, `nonisolated(unsafe)` and `MainActor.assumeIsolated` remain only where the compiler cannot check the code, each with a comment saying what makes it safe
- [x] #3 History, session save/restore, palette suggestions and History page results are unchanged: HistoryDatabaseTests, the History*Tests suites, AppDatabaseTests, the SessionSave*/SessionSnapshot* suites, SuggestionProviderTests and InternalPageIntegrationTests pass, and the palette still drops a background result whose query is stale
- [x] #4 The affected test suites pass under Thread Sanitizer (`xcodebuild ... -enableThreadSanitizer YES`), or the task records why a suite cannot run under it
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. HistoryDatabase and AppDatabase become `nonisolated struct … : Sendable`: all their state is the GRDB DatabaseQueue (Sendable, serialised), and they are called from the main thread, the palette query queue, the History page and chrome.history background reads.
2. NSLock + @unchecked Sendable (HistoryDatabase.QueryTokenCache, AppDatabase read counters) → Synchronization.Mutex (macOS 15+), so the compiler checks the guarding.
3. History completion handlers (recordVisit, deleteVisits, …) become @Sendable: they run on GRDB writer queue.
4. Pure helpers the storage layer calls become nonisolated (URLHost, ExtensionPageURL, HistoryTimeRange, RuntimeInstalledEvent.pending, TabStore.incognitoProfileID, SuggestionProvider helpers).
5. SuggestionProvider becomes nonisolated + Sendable (its only state is the history DB); its network and favicon entry points are @MainActor; SuggestionItem Sendable.
6. HistoryPageBridge: the background closure only reads rows; the [String: Any] reply is built and sent on the main thread; reply takes the @MainActor @Sendable WebKit type.
7. TabRecord.init(tab:) is @MainActor (TabRecord itself is nonisolated through its GRDB conformances).
8. Verify: full rebuild per-file warning diff against the TASK-231.1 baseline, affected suites normally and under Thread Sanitizer.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Done 2026-11-02.

Changes: HistoryDatabase and AppDatabase are `nonisolated struct … : Sendable` (their only state is the serialising DatabaseQueue). NSLock + @unchecked Sendable gone: the history SQL functions token cache is a static `Mutex<(query, tokens)>` and the DEBUG read counters a `Mutex<[String: Int]>`. Write completions (recordVisit, the three deleteVisits/deleteHistory forms) are @Sendable. Pure helpers made nonisolated: URLHost.swift, ExtensionPageURL.swift (also clears the PersistedExtensionPage isolated-conformance warning), HistoryTimeRange.swift, RuntimeInstalledEvent (enum), HistoryCursor, TabStore.incognitoProfileID, the storage and TabStore `log` globals. SuggestionProvider is nonisolated + Sendable (searchSuggestions and loadFavicon @MainActor, reading SearchSuggestionsService.shared there), SuggestionItem Sendable (NSImage is Sendable in the SDK). HistoryPageBridge: the background block only reads rows; the [String: Any] reply is built and sent inside the main hop; `reply` and `confirmClear` take main-actor types. TabRecord.init(tab:…) is @MainActor (TabRecord is nonisolated because GRDB TableRecord/EncodableRecord are SendableMetatype). Review fix: the RunLoop.main.perform block in TabStore.recordVisit completion uses MainActor.assumeIsolated (main run loop blocks run on the main thread), with a comment.

Warnings (full rebuild of the Detour target): 345 → 269. Storage/ 46 → 0, HistoryPageBridge 8 → 0, TabRecord+BrowserTab 11 → 0, CommandPaletteView 2 → 0, TabStore 25 → 19, FaviconPNGLoader 6 → 4, ExtensionPolyfillHandler 5 → 4. No file increased.

Tests: the affected suites (AppDatabase, CommandPaletteFocus, ExtensionDatabase, ExtensionHistoryScope, History* incl. benchmarks, InternalPage*, Palette*, SessionSave*, SessionSnapshotRepair, SuggestionProvider, WebKitDelegateReachability) 476 tests, 3 skipped, 0 failures; the same under Thread Sanitizer (-enableThreadSanitizer YES, TSan runtime confirmed in the app bundle): 476 passed, 0 ThreadSanitizer reports. After the review fixes, the same suites plus QuickDetourTests, SameDocumentVisitTests, TabStoreTests, HistoryTitleUpdateTests: 561 tests, 3 skipped, 0 failures (not rerun under TSan; the review change only wraps a main-thread block in assumeIsolated).

Runtime (harness docs/harness/task231-2-harness.patch, profile DetourVerify2312): three visits seeded through recordVisit (completion ids 1-3); the History page lists 3 rows and its search narrows to 2; SuggestionProvider.localSuggestions run on a global queue completes "alpha" to alpha.test; deleteVisits completes off the main thread with deletedVisitCount 1 and the URL removed. All PASS. The harness ran before the review fixes.

/code-review --fix: no correctness findings (reply ordering, stale-result guard and Mutex semantics checked); fixed: TabStore log global nonisolated, the recordVisit run-loop block, QueryTokenCache class folded into a static Mutex, an overstated "used from background queues" claim about AppDatabase in the doc comment and wiki.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The history and session storage layer and its background callers are now compiler-checked: both database types are nonisolated and Sendable, the two NSLock-guarded caches are Mutexes, write completions are @Sendable, the palette background pass (SuggestionProvider) is nonisolated with Sendable inputs and results, and the History page builds its reply on the main thread instead of off it. 0 concurrency warnings remain in Storage/, the palette history pass, HistoryPageBridge and TabRecord+BrowserTab (target total 345 → 269). Verified with 561 tests across the affected suites, the core 476 also under Thread Sanitizer with no reports, and a runtime harness (History page listing and search, palette background completion, async delete). No behaviour change intended or observed.
<!-- SECTION:FINAL_SUMMARY:END -->
