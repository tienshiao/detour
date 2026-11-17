---
id: TASK-404
title: >-
  GPU process: persist the IOSurface growth curve and per-event deltas (show,
  wake, sleep, close) so a recurrence can be attributed
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-17T19:47:00Z'
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
- [ ] #1 The recycler's periodic sample is logged at notice (persisted) when the total moved by at least 50 since the last logged sample, at least every 10 minutes, and whenever the GPU process changed; the line carries total, non-resident regions, the number of distinct tab web processes and the GPU pid
- [ ] #2 Showing, waking, sleeping and closing a tab queue an event (kind, host, web process pid); a sample a few seconds after the first queued event logs the change in total and non-resident since the previous sample with the coalesced events, at notice
- [ ] #3 Counting stays off the main thread, and one sample is in flight at a time
- [ ] #4 Pure decision and formatting logic (when to log a periodic sample, how events coalesce) has unit tests
- [ ] #5 Non-resident region counts from the in-app walk are checked against vmmap's PURGE=E count on a real GPU process
- [ ] #6 The wiki's GPU IOSurface page documents the log lines and how to read them
<!-- AC:END -->
