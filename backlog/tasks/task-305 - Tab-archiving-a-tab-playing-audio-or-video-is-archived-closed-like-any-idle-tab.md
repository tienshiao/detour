---
id: TASK-305
title: >-
  Tab archiving: a tab playing audio or video is archived (closed) like any idle
  tab
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-08T09:53:00Z'
updated_date: '2026-11-08T11:35:00Z'
labels:
  - tabs
  - archiving
  - bug
dependencies: []
references:
  - TASK-292.6
priority: medium
type: bug
ordinal: 366000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-292.6 code read (Nov 8 2026, not yet seen at runtime): the archive sweep (TabStore.archiveStaleTabs, ~5249-5279, every ~5 minutes) archives a normal tab once it has been deselected longer than the profile's "Archive tabs after" (12 hours by default). It skips pinned tabs, favorites, Private tabs, the last tab of a space and half-stale splits, but it does not check whether the tab is playing audio or video. Music or a podcast left playing in a background tab is therefore closed mid-playback after 12 hours; the now-playing bar exists precisely to control such tabs. (Sleeping already avoids this in places: a pending media check guards the GPU recycler and sleep; see allLiveTabs / media rules.)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Confirmed at runtime (or ruled out) with a tab playing audio past an injected short archive threshold
- [x] #2 A tab that is playing audible media is not archived; it becomes eligible once playback stops, counting from then or from its last deselection (rule agreed with the user)
- [x] #3 Muted or paused media does not block archiving
- [x] #4 TabStore archive tests cover playing, paused and muted tabs, with an injected clock
- [ ] #5 The website's Tab Archiving page mentions the rule
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reuse BrowserTab.isAudible (isPlayingAudio from WebKit's _isPlayingAudio KVO, minus page mute), already the gate for sleep, auto-PiP and the GPU recycler.
2. BrowserTab.lastAudibleAt: stamped (injectable audibilityClock) whenever isAudible goes true -> false (pause/end, mute, web view released).
3. BrowserTab.archiveClockStart(now:): nil while selected; now while the tab or its Peek is audible; else max(lastDeselectedAt, lastAudibleAt, peek's lastAudibleAt). archiveStaleTabs measures from it.
4. Persist the archive clock into the saved lastDeselectedAt (TabRecord factory, injectable now), so a relaunch (which stops the sound) restarts the countdown from the save instead of the old deselection.
5. ArchiveMediaTests: playing, muted, paused, restart-from-stop, mute restarts, stamp-before-deselection, audible Peek, split partner, saved clock.
6. Runtime check with a local WAV fixture and a short threshold if practical; wiki sleeping-and-archiving.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026, user decision: once playback stops, the 'Archive tabs after' countdown restarts from when it stopped (not from the last deselection).

Implemented: reused BrowserTab.isAudible (WebKit _isPlayingAudio KVO minus page mute; the gate sleep, auto-PiP and the GPU recycler already use). New BrowserTab.lastAudibleAt, stamped through an injectable audibilityClock whenever isAudible goes true -> false (pause/end, mute, web view released). BrowserTab.archiveClockStart(now:) = nil while selected; now while the tab or its Peek is audible; else max(lastDeselectedAt, lastAudibleAt, peek.lastAudibleAt). TabStore.archiveStaleTabs measures from it (the split and last-tab rules unchanged). The TabRecord factory saves the archive clock as lastDeselectedAt (injectable now), so a tab still playing at quit restarts from the save after relaunch (only the archive sweep reads that column for an off-screen restored tab).

Decisions made here: a mute ends the audible run like a pause (countdown restarts from the mute); an audible Peek holds its host (archiving the host would close the Peek's sound).

Tests: ArchiveMediaTests 9/9 (playing, muted, paused long ago, restart from stop incl. just-short/just-past the threshold, mute restarts, stop before deselection, audible Peek, split with one playing member, saved clock). Regression: TabStoreTests 40, SleepShowBudgetTests 16, NowPlayingTabTests 20, NowPlayingRuleTests 27, FavoritePeekPersistenceTests 5: all pass.

Runtime (AC #1, Nov 8, DetourB8-305-1, temp harness, injected clock instead of a short threshold: archiveStaleTabs(now: Date()+13h) with the default 12 h threshold): a deselected tab playing a looped generated WAV (data: URL, autoplay via mediaTypesRequiringUserActionForPlayback = []) reported playing=true audible=true and survived the +13 h sweep, while a silent tab and a page-muted playing tab (playing=true audible=false) were archived. After a scripted a.pause(), lastAudibleAt was stamped; a sweep at stop+11 h kept it, at stop+13 h archived it. The bug itself was not reproduced on the old build (the old sweep has no audio check by reading, and the silent/muted controls show the sweep ran). WebKit store dir for DetourB8-305-1 left under ~/Library/WebKit/com.detourbrowser.mac.

Website facts for AC #5 (Tab Archiving page): a tab playing sound you can hear is never archived; once it stops (paused, ended or muted), the 'Archive tabs after' countdown starts again from that moment, not from when you last left the tab. Muted or paused media does not keep a tab from being archived. A Peek playing sound keeps its tab too. Quitting Detour stops playback, so a tab playing at quit counts from the quit.

Website AC pending (held for release).

Nov 8 2026 (lead review): the Delete Space undo snapshot now stores archiveClockStart(now:) like the session save (testUndoDeleteSpaceCarriesTheArchiveClock).

Website: updated Tab Archiving (/features/tab-archiving/: a tab playing audible sound, or with an audible Peek, is never archived; the countdown restarts when the sound stops; muted/paused tabs archive as usual; FAQ too) on website branch next-release (65b076e), held for the release

Nov 8 2026 (lead): landed on main with the batch; /code-review on its branch (fixes folded in); full DetourTests on the integrated code: 3882 tests, 18 skipped, 2 failures, both pre-existing on main before the batch (TASK-310).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The archive sweep no longer closes a tab playing audible media. Its countdown is BrowserTab.archiveClockStart(now:): never stale while the tab (or its Peek) is audible, otherwise counted from the later of the deselection and the end of the last audible playback, which is stamped on pause, mute or web view release and saved into lastDeselectedAt so a relaunch restarts it. Muted or paused media does not block archiving. ArchiveMediaTests (9) plus affected suites pass; confirmed at runtime with a looped WAV and an injected clock. Website AC #5 pending (facts in notes).
<!-- SECTION:FINAL_SUMMARY:END -->
