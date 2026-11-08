---
id: TASK-306
title: 'History: record pages viewed in a Peek'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-08T09:55:00Z'
updated_date: '2026-11-08T10:43:00Z'
labels:
  - history
  - peek
dependencies: []
references:
  - TASK-292.6
priority: medium
ordinal: 367000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Pages opened in a Peek never reach History, however long they stay up (confirmed at runtime by TASK-292.6, Nov 8 2026). Arc records Peek pages in history (the user, who used Arc), and so do browsers generally outside private browsing: History is how people find a page again, and a page glanced at in a Peek is a typical one to want back.

Cause: a Peek is a BrowserTab held in its host's `peekTab`, with no `spaceID`, not in `space.tabs` and not subscribed by TabStore (wiki/tabs/peek.md, "The Peek is a tab that is in no list"). History is recorded from TabStore's per-tab `$isLoading` subscription (TabStore ~5345-5352 → recordHistoryVisit with `tab.historySpaceID`), which Peeks never get. recordHistoryVisit's own rules (no Private space, no Private Quick Detour, http/https only, error pages skipped, title correction and dedup) should apply unchanged, keyed to the host tab's space.

The website's Peek and History guide pages (TASK-292.6) currently say Peek pages are not recorded; they change when this ships.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A page that loads in a Peek in a normal window is recorded in History under the host tab's space and profile, with its title, like a page loaded in a tab; navigations inside the Peek are recorded too
- [x] #2 Peeks in Private windows, Private Quick Detours and Quarantine are never recorded
- [x] #3 Expanding a Peek into a tab (Open in New Tab / Open in Split View) does not record the same visit twice
- [x] #4 Tests cover Peek recording in a normal space, the Private exclusions and the expand path
- [x] #5 Checked at runtime with /verify: a Shift-clicked link's page appears on the History page
- [ ] #6 The website's Peek and History pages and wiki/tabs/peek.md are updated
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extract the history sinks of TabStore.subscribeToTab (isLoading -> recordHistoryVisit, debounced same-document URL, debounced title correction) into historyRecordingSinks(for:).
2. BrowserTab.peekHost (weak, set by the host's peekTab didSet); historySpaceID falls back to the host's; recordHistoryVisit / updateHistoryTitle resolve Private through the host.
3. TabStore.recordHistory(ofPeek:) stores the sinks on the Peek (historyObservers); showPeekOverlay calls it. Dropped by teardown() and when the host's peekTab changes (close, replace, expand/split hand-over), which prevents the old Peek object (still observing the handed-over web view) from recording again.
4. PeekHistoryTests; runtime check with a Shift-clicked link and the History page; wiki peek.md + history recording.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented as planned. Files: TabStore.swift (historyRecordingSinks, recordHistory(ofPeek:), Private check via peekHost, updateHistoryTitle resolves the space via historySpaceID), BrowserTab.swift (peekHost, historyObservers, peekTab didSet, teardown, historySpaceID), BrowserWindowController.swift (showPeekOverlay calls recordHistory(ofPeek:)).

Quick Detours and quarantines have no Peeks today; the rule is still keyed to the host, so a Peek on a Private Quick Detour host records nothing (tested with a synthetic host).

Tests: PeekHistoryTests 7/7 (host-space recording with title, inner navigation, Private window, Private Quick Detour host, Peek taken off its host records nothing, expand records once and the old Peek object records nothing after, teardown releases the Peek). Regression: HistoryTitleUpdateTests 26, SameDocumentVisitTests 18, PeekStateTests 11, ExtensionActiveTabTests 15, QuickDetourTests 27, QuarantineTests 31: all pass.

Runtime (Nov 8, DetourB8-306-1, temp harness, local python http.server on 127.0.0.1:8761): a posted Shift-click on a link in a normal tab opened a Peek (Peek Target); a posted click on a link inside the Peek navigated it (Peek Second). The History page (detour://history) listed Peek Second, Peek Target and Host Page, and history.db had all three visits with titles under the host's space id. Not checked at runtime: the Private window case (tests cover it). WebKit store dir for DetourB8-306-1 left under ~/Library/WebKit/com.detourbrowser.mac.

Website facts for AC #6 (Peek and History guide pages): pages you open in a Peek are now saved in History like pages in a tab, under the space of the tab the Peek opened from, including links you follow inside the Peek. Peeks in Private windows are not recorded. Opening a Peek as a tab (or in Split View) does not add a second visit. Remove 'Peek pages are not recorded' wherever the pages say it.

Website AC pending (held for release).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Peek pages are recorded in History under the host tab's space and profile: the history sinks of subscribeToTab were extracted (historyRecordingSinks) and installed on each Peek (recordHistory(ofPeek:), stored on the Peek, weak captures), with the Peek's historySpaceID resolved through its host. recordHistoryVisit's rules apply unchanged (Private, http(s), error pages, title correction, dedup). The sinks end on teardown or when the Peek leaves its host, so the expand/split hand-over never records a page twice. PeekHistoryTests (7) and the history/peek/Quick Detour suites pass; verified at runtime with a Shift-clicked link on the History page and in history.db. Website AC pending (facts in notes).
<!-- SECTION:FINAL_SUMMARY:END -->
