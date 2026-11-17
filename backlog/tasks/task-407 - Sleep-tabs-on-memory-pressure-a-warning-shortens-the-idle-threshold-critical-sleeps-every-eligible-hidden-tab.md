---
id: TASK-407
title: >-
  Sleep tabs on memory pressure: a warning shortens the idle threshold, critical
  sleeps every eligible hidden tab
status: Done
assignee: []
created_date: '2026-11-17T20:35:00Z'
updated_date: '2026-11-17T21:43:00Z'
labels:
  - sleeping
  - memory
  - gpu
dependencies: []
priority: medium
type: feature
ordinal: 488000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Detour does not react to macOS memory pressure at all. The only release paths are the profile's idle threshold (1 h default) and the TASK-104 show budget. A survey on 2026-11-17 of six open-source WebKit browsers (Search, Zigzag, Nook, Lilo, Zephium, Ora) found that all but Ora react to pressure, usually through DispatchSource.makeMemoryPressureSource:
- Search: a warning shortens the idle wait to 5 min, critical to 0.
- Zigzag: either level shortens it to 5 min for 2 min after the event; rescans at most once per 30 s; favourites sleep only on critical, because the first warning is common in everyday use.
- Nook: a warning unloads one tab; critical unloads up to half of the eligible tabs, at most once per 30 s.
- Lilo and Zephium: cap the number of live web views.

Fewer live web processes also means fewer per-connection IOSurface pools in the GPU process, so this helps with the TASK-104/403 limit as a side effect. The user decides the exact rule (thresholds, whether pinned/favourite tabs are included, at which level); the survey's numbers are starting points, not the decision.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A memory-pressure source drives sleeping; warning and critical levels are handled distinctly, per a rule the user has confirmed
- [x] #2 The existing never-sleep guards still apply: the selected/hosted tab, audible or capturing tabs, split partners, and a profile set to never sleep
- [x] #3 A burst of pressure events cannot cause repeated full sweeps (rate-limited), and sleeps do not stall the main thread
- [x] #4 Policy tests in the existing sleep suites cover both levels, the guards and the rate limit, with an injected clock and a fake pressure source
- [x] #5 Each pressure-driven sleep is logged at notice so a run can be reviewed
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. MemoryPressureSleepPolicy (pure, injectable clock): note(warning|critical, at:), idleThresholdCap(at:) = 5 min for 2 min after the last warning, takeDueSweep(at:) rate-limited to one pressure sweep per 30 s (deferred, never dropped), nextCheck(after:) for the rescans inside the warning window and a deferred critical.
2. MemoryPressureSleeper (@MainActor, owned by TabStore): DispatchSource.makeMemoryPressureSource on .main, handler hops via MainActor.assumeIsolated (commented); injectable scheduler so tests fire re-checks by hand; logs one notice line per pressure sweep (level, tabs slept). Started from AppDelegate, not in the unit-test host.
3. TabStore.sleepStaleTabs(now:pressure:) -> Int: the profile idle threshold is capped by idleThresholdCap (also on the periodic sweep inside the window; never lengthened, .never honoured); critical sleeps every eligible hidden tab incl. pinned entries' and favourites' backing tabs; split partners (incl. pinned splits) still checked; count = tabs that actually became asleep.
4. Capture guard: BrowserTab.isCapturingMedia (camera/mic) joins isAudible in the shared precondition (also changes the idle and budget rules) and is reused by the GPU recycler.
5. Measure the cost of a critical sweep over ~40 live tabs; stagger if needed (re-checking eligibility per turn).
6. Tests in a new MemoryPressureSleepTests (SleepShowBudgetTests style) + policy unit tests; run sleep/TabStore/split/favourites suites.
7. Wiki sleeping-and-archiving.md (+ gpu page mention), log.md.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
User decision 2026-11-17: 'Shorten, then sweep'. Warning: hidden normal tabs sleep once they've been hidden 5 min, for 2 min after the last warning (the profile threshold is shortened, not replaced; a profile set to never sleep is honoured). Critical: every eligible hidden tab sleeps now, including pinned entries' and favourites' backing tabs. Rescan at most once per 30 s. The usual guards still apply: hosted/on screen, audible, capturing, split partners.

Implemented 2026-11-17 (agent, branch gpu-406-407).
- MemoryPressureSleepPolicy (pure): warning opens a 2-min window in which the idle threshold is capped at 5 min (min with the profile's, so never lengthened; .never honoured); critical is a one-shot sweep of every eligible hidden tab incl. pinned entries' and favourites' backing tabs. Pressure sweeps at most once per 30 s; an event inside the 30 s is deferred to the 30 s mark (a pending critical outranks the warning window); the warning window is rescanned at +0/30/60/90/120 s. The cap also applies to the periodic 300 s sweep while the window is open. A return to normal changes nothing.
- MemoryPressureSleeper (@MainActor, TabStore.memoryPressureSleeper): DispatchSource.makeMemoryPressureSource([.warning, .critical], queue: .main), handler via MainActor.assumeIsolated (commented); started in AppDelegate, not in the unit-test host. Injectable clock, scheduler and next-turn hook. One notice line per pressure sweep, category memory-pressure: 'Memory pressure <level>: slept N tabs'; the event itself at info.
- TabStore: sleepStaleTabs(now:pressure:) -> Int = sleepTabs(staleTabCandidates(now:pressure:)); counts tabs that actually became asleep.
- Cost measured (gated leg testMeasureCriticalSweepCost, TEST_RUNNER_DETOUR_MEASURE_PRESSURE_SWEEP=1): 40 hidden tabs with loaded pages, one synchronous critical sweep = 181 ms (4.5 ms per tab) + 54 ms on the next main-loop turn, in the test host without sidebar observers. So pressure sweeps are staggered: 4 tabs per main-loop turn (DispatchQueue.main.async), candidates recomputed before each batch (a tab selected/started playing mid-sweep is spared; a tab already tried is not retried); the log line comes after the last batch. The periodic sweep still sleeps in one go.
- Claude's choices: (1) camera/microphone capture (BrowserTab.isCapturingMedia) now keeps a tab awake on EVERY sleep rule, not just pressure — before, a silent tab on a call could sleep on the idle/budget rules; the GPU recycler's media gate reuses the property. (2) Critical does not open the warning window. (3) A return-to-normal event does not end the warning window early. (4) Batch size 4 per turn.
Tests: MemoryPressureSleepTests 21 (20 pass + measurement leg skipped by default; the leg passed when enabled), SleepShowBudgetTests 16, GPUProcessRecyclePolicyTests 23, GPUSurfaceTelemetryTests 18, BrowserTabWakeTests 7, ArchiveMediaTests 10, SplitTabTests 63, TabStoreTests 40, FavoriteSpaceHandoffTests 8, FavoritePeekPersistenceTests 5, PinnedTabMoveTests 17: 228 run, 0 failures, 1 skipped.
Not verified: a real memory-pressure event in the running app (no runtime check; 'sudo memory_pressure -S -l warn|critical' or notifyutil could simulate it). /code-review not run by the implementing agent (left to the lead).

Follow-up in the same commit: scheduled checks now run as of the time they were armed for (receive reads the clock once). Late timers had pushed the +120 s rescan just past the window, so it was never armed; testTheLastRescanRunsWhenTimersFireLate (checks 50 ms late) covers it. MemoryPressureSleepTests 22 (21 pass + 1 skipped leg), SleepShowBudgetTests 16: 0 failures.
Claude's choice (5): a critical event within 30 s of a warning sweep waits for the 30 s mark (up to 30 s), because the 30 s rate limit and 'critical sleeps now' collide there; the rate limit won.

The user confirmed Claude's choices on 2026-11-17.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
MemoryPressureSleeper listens on a DispatchSource memory-pressure source, using the pure MemoryPressureSleepPolicy.
- Warning: for 2 min the idle threshold is the shorter of 5 min and the profile's own (.never honoured). Rescans run at +0, 30, 60, 90 and 120 s.
- Critical: one sweep of every eligible hidden tab, pinned entries' and favourites' backing tabs included.
- Rate limit: pressure sweeps at most once per 30 s; a deferred event is never dropped.
- Batching: sweeps sleep 4 tabs per main-loop turn, with candidates rechecked before each batch. Measured 4.5 ms per sleep in the test host.
- Logging: one notice line per sweep (category memory-pressure).
- New guard: a tab using the camera or microphone stays awake under every sleep rule. The review extended it to sleep() itself, so a capturing Peek is not parked.

Tests: MemoryPressureSleepTests 22 plus the sleep, TabStore, split, favourites and pinned suites; 237 passed, 1 gated skip, on the rebased branch.

Not verified at runtime: a real memory-pressure event. Simulating one would hit the user's other apps; the dispatch source wiring only ran through injected fakes.

Claude's choices, for the user to confirm:
1. The camera/microphone guard now applies to all sleep rules.
2. A critical event within 30 s of a warning sweep waits for the 30 s mark.
3. Critical is a single sweep and does not open the warning window.
4. 4 tabs per batch.

Review follow-ups left: the periodic 5-min sweep during a warning window sleeps unstaggered; candidates are rebuilt per batch (O(N²/4)); a check that fires hours late replays on its armed timeline (wasted scans only).
<!-- SECTION:FINAL_SUMMARY:END -->
