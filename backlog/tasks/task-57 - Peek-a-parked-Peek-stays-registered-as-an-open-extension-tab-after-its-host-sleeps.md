---
id: TASK-57
title: >-
  Peek: a parked Peek stays registered as an open extension tab after its host
  sleeps
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 17:31'
updated_date: '2026-09-13 19:00'
labels:
  - bug
  - peek
  - extensions
dependencies: []
priority: low
ordinal: 57000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the TASK-51 review. When a host tab sleeps or is retargeted, BrowserTab.sleep(force:) (BrowserTab.swift ~526) and retarget(to:) (~565) save the Peek state onto the host and call peek.sleep(force:), which releases the Peek web view but leaves the Peek BrowserTab registered with the extension contexts (extensionRegisteredProfile stays set; no ExtensionTabLifecycle.didClose). For an ordinary sleeping tab that is by design: it stays registered and its wake re-reports it. A parked Peek is different: it is never woken as the same object. showPeekOverlay (BrowserWindowController.swift ~2321) always builds a new BrowserTab and tears the parked one down, and the host peekTab reference is only cleared by closePeekOverlay, teardown, or that re-present. So from the host sleep (auto-sleep via sleepStaleTabs, a profile swap, a retarget) until the host is next peeked or torn down, extensions see a phantom open tab that has no web view: it appears in tabs.query results and window tab lists, and tabs.sendMessage / tabs.get against it cannot reach a page.

The Peek cannot be reported open again on its own, so its sleep is a close in every sense the contexts care about; the parked state (peekURL, peekInteractionState, peekFavicon) already lives on the host and is what a later re-present restores. The simplest fix is to close the Peek at the point the host parks it, e.g. call ExtensionTabLifecycle.didClose(peek) after peek.sleep in both sleep(force:) and retarget(to:), or park via peek.teardown() after savePeekStateForPersistence (teardown already closes and releases, and is idempotent for the later orphan teardown in showPeekOverlay). Keep the host peekTab reference (or the parked favicon/URL) so the TASK-47 tile badge and displayPeekFavicon keep working. A session-restore parked peek (peekTab nil, peekURL set) is unaffected and must stay that way.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 After a host tab with a live Peek sleeps (sleep(force:) and retarget(to:)), the Peek is no longer registered with the profile extension contexts (not in the open tab list the contexts enumerate)
- [x] #2 Re-presenting the peek on the same host after it wakes still restores the parked URL and interaction state and registers the new Peek tab exactly once
- [x] #3 The parked peek favicon badge on tiles and the sidebar cell (TASK-47) still shows after the host sleeps
- [x] #4 Unit test with the ExtensionTabLifecycle notifier spy asserts didClose for the Peek on host sleep and on retarget, and no phantom remains until the next present
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. In BrowserTab.sleep(force:) and retarget(to:), after savePeekStateForPersistence() and peek.sleep(force:), close the parked peek registration with ExtensionTabLifecycle.didClose(peek). The parked peek is never woken as the same object (showPeekOverlay always builds a new BrowserTab and tears the parked one down), so its sleep is a close for the contexts; the host keeps peekTab so displayPeekFavicon / the TASK-47 badge still work.
2. Confirm the later paths stay correct: showPeekOverlay orphan teardown -> didClose is a no-op (idempotent); a re-present registers the new peek exactly once through the peekTab didSet; extensionWindowTabs already excludes a parked peek.
3. Tests in ExtensionTabLifecycleTests (RecordingNotifier): host with live peek -> host.sleep(force:) records .close for the peek and the peek is unregistered (extensionRegisteredProfile nil); same for retarget(to:); re-presenting yields exactly one .open for the new peek; a session-restore parked peek (peekTab nil, peekURL set) records nothing. FavoriteTileBadgeTests / PeekStateTests must stay green.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
BrowserTab.parkPeek(force:) owns save -> sleep -> didClose for a parked peek at both host call sites (sleep(force:) and retarget(to:)); the close is gated on the peek having released its web view, since a non-forced sleep spares an audible peek which must stay registered. Review added the same close for Profile.retargetExtensionPages, which retargets the peek object directly. AC #2 (re-present registers the new peek once) is verified by reading showPeekOverlay, not by an automated test: presenting needs a BrowserWindowController harness these suites lack.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A parked Peek is closed with the extension contexts when its host sleeps or is retargeted, so no phantom open tab remains; the host keeps the parked state for the badge and re-present. Verified by ExtensionTabLifecycleTests, PeekStateTests and FavoriteTileBadgeTests.
<!-- SECTION:FINAL_SUMMARY:END -->
