---
id: TASK-404
title: >-
  GPU process: persist the IOSurface growth curve and per-event deltas (show,
  wake, sleep, close) so a recurrence can be attributed
status: Done
assignee:
  - '@claude'
created_date: '2026-11-17T19:47:00Z'
updated_date: '2026-11-17T20:02:00Z'
labels:
  - gpu
  - webkit
  - diagnostics
dependencies:
  - TASK-403
priority: high
type: feature
ordinal: 485000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up to TASK-403 (2026-11-17). After the GPU process was recycled at 11:10:56, its IOSurface count went 506 -> 2,241 in five minutes, while the user cmd-clicked a batch of YouTube links and the Jira tab reloaded into a new web process. Closing every YouTube tab and both Jira tabs (all of their WebContent processes exited, and the GPU process logged removeGPUConnectionToWebProcess for each) freed only about 450, settling around 2,000-2,300. Purged regions then fell from 1,871 to 1,564 while the total rose, so some leftovers are being reused (cache-like) rather than simply leaked.

TASK-104's show budget assumes closing or sleeping a tab frees its surfaces; this observation questions that. Today the only record is a hand-run vmmap sampler: the recycler logs nothing persisted below its limits, and nothing ties a change in the count to the tab or event that caused it. The user asked for instrumentation that lets a normal long-running build collect the evidence by itself.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The recycler's periodic sample is logged at notice (persisted) when the total moved by at least 50 since the last logged sample, at least every 10 minutes, and whenever the GPU process changed; the line carries total, non-resident regions, the number of distinct tab web processes and the GPU pid
- [x] #2 Showing, waking, sleeping and closing a tab queue an event (kind, host, web process pid); a sample a few seconds after the first queued event logs the change in total and non-resident since the previous sample with the coalesced events, at notice
- [x] #3 Counting stays off the main thread, and one sample is in flight at a time
- [x] #4 Pure decision and formatting logic (when to log a periodic sample, how events coalesce) has unit tests
- [x] #5 Non-resident region counts from the in-app walk are checked against vmmap's PURGE=E count on a real GPU process
- [x] #6 The wiki's GPU IOSurface page documents the log lines and how to read them
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. GPUSurfaceTelemetry (new file): pure rules (periodic log decision, line format, event folding) + a MainActor recorder with one serial sampling queue shared with the recycler.
2. GPUProcessRecycler.check samples through the telemetry and passes the sample to recordPeriodic; ioSurfaceRegionCounts adds a non-resident count (pri_pages_resident == 0).
3. BrowserTab hooks: show (noteShown), wake, sleep, close (teardown with a live web view); webProcessIdentifier made internal.
4. Tests, runtime check, vmmap comparison, wiki.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Review (/code-review medium --fix): 7 findings, 3 fixed. Incognito/ephemeral-store hosts are logged as 'private'. The wiki section placement is corrected. The assumeIsolated comment is added. Not changed: the event delta is against the previous sample of any kind (intended, documented). ioSurfaceCount stays as a thin wrapper used by tests. The tab-process count runs on main (negligible). Peek teardowns are logged as close.

Privacy follow-up (user decision 2026-11-17): event lines no longer write host names by default. A host is logged as site-xxxxxxxx: HMAC-SHA256 of the lowercased host, trailing dot removed, under a random per-launch key that is never stored. The tokens match within a launch and are linkable once one line is tied to a known visit. The opt-in defaults key GPUSurfaceLogPublic logs real hosts, read at each event, and logs a one-time 'PUBLICLY' notice the first time a launch writes one. Incognito/ephemeral tabs are always 'private'. Review: 5 findings, 2 fixed (opt-in notice, host normalization), wording of the linkability claim corrected. Not done: a fixture test for the incognito/ephemeral wiring (pre-existing logic; only the pure function is tested). Tests: GPUSurfaceTelemetryTests 18/18, with GPUProcessRecyclePolicyTests 35/35 before the review fixes. Runtime: default run logged 'show site-0a9ea62e[52784], close site-8d9fd108[52862]'. A run with the launch argument -GPUSurfaceLogPublic YES logged 'show example.com[52971], close example.org[53004]'. The real defaults domain was left untouched.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A running build now persists the GPU process's IOSurface curve and ties moves to tab events, all at notice in category gpu-surfaces. Periodic lines come from the recycler's 2-min sample: logged on a move of 50+, after 10 min of silence, or for a new GPU process. 'after <events>' lines come 3 s after a batch of show/wake/sleep/close events and carry host[web-process pid]; incognito hosts are logged as 'private'. Each line has total and non-resident regions with deltas, distinct tab processes and the GPU pid.

Verification:
- GPUSurfaceTelemetryTests (13) plus tab suites: 209/209 pass (BrowserTabUnclaimedNavigation, BrowserTabWake, FavoritePeekPersistence, FavoriteSpaceHandoff, PinnedTabMove, SplitOpening, SplitTab, TabStore, SleepShowBudget, GPUSurfaceTelemetry, GPUProcessRecyclePolicy).
- Runtime, isolated Debug build: show lines for new tabs; then 'after show example.com[45502], close webglsamples.org[45384]: total=77 (-19) nonResident=0 (+0) tabProcesses=1'.
- The walk's non-resident count on the production GPU process was 2,138-2,147 against vmmap PURGE=E 2,119, totals identical (2,574/2,575).

Not verified: a long run of the signed build (the point of the task, once the user runs a build with it).
<!-- SECTION:FINAL_SUMMARY:END -->
