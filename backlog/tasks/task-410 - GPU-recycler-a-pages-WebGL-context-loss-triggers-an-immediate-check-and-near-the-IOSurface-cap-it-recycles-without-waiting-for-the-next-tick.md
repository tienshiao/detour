---
id: TASK-410
title: >-
  GPU recycler: a page's WebGL context loss triggers an immediate check, and
  near the IOSurface cap it recycles without waiting for the next tick
status: Done
assignee:
  - '@claude'
created_date: '2026-11-18T08:41:00Z'
updated_date: '2026-11-18T08:57:00Z'
labels:
  - gpu
  - webkit
dependencies:
  - TASK-403
references:
  - Detour/Browser/GPUProcessRecycler.swift
  - Detour/Browser/GPUSurfaceTelemetry.swift
  - DetourTests/GPUProcessRecyclePolicyTests.swift
priority: medium
type: feature
ordinal: 491000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up to TASK-403/404 (decided with the user on 2026-11-18).

Why: GPUProcessRecycler counts the GPU process's IOSurfaces every 120 s (checkInterval). Once the 16,384 per-process cap is hit, WebGL and canvas fail at once (YouTube shows 'WebGL: context lost', then serves its poisoned player response, see TASK-104). The exhausted tier only recycles at the next tick, so Detour can stay broken for up to about 2.5 min. Inside minimumInterval (1 h after a recycle) it does not recycle at all, and it also waits while any tab is audible. TASK-105 once planned a WebGL canary; the direct count replaced it because it detects the state before the breakage. This task adds the breakage signal back as a trigger, not as the detector.

Evidence for how fast the count climbs (2026-11-17, production build with TASK-403..409): a cmd-click burst of YouTube links took 901 to 2,235 surfaces. Watching and closing 9 YouTube tabs one at a time then took 1,742 to 5,820 (+240..+840 per closed tab). The WebContent processes exited and their GPU connections were removed, but the surfaces stayed. Safari 27.0 on its newer staged WebKit (21625.1.29) leaks the same way (71 to 4,062 for about 11 tabs, 4,020 ten minutes later), so the leak is WebKit's (TASK-106) and recycling remains the remedy.

Design (recommended, accepted):
1. Detection: a user script in a dedicated WKContentWorld, all frames, at document start. Capture-phase listeners on window for 'webglcontextlost' and 'webglcontextcreationerror' (neither bubbles, but both pass through the capture phase). Each event posts {kind} to a native message handler registered on every normal and private tab configuration. Rate-limit per web view, for example at most one message per 5 s. Pages must not be able to see the listener or the handler: isolated world only, never the page world.
2. The event is not trusted on its own. Context loss also happens for harmless reasons: a page calling WEBGL_lose_context, WebKit evicting its oldest context when a page has too many, a GPU reset after sleep, or the GPU process having just been recycled. The message only makes the recycler run check() now instead of at the next tick (coalesced, at most one immediate check per few seconds).
3. A new 'confirmed breakage' input to GPUProcessRecyclePolicy.decide: a context-loss signal in the last few seconds AND surfaceCount >= a near-cap level (proposal 15,000, env override). In that case, recycle even inside minimumInterval and even while a tab is audible: media in that state is likely failing already. Never recycle while a tab captures camera or microphone (capture runs in the GPU process; a recycle would cut the call off). Below the near-cap level, the signal changes nothing; the normal tiers apply.
4. Telemetry: a notice line (category gpu-recycle) for every received signal: kind, host (same tokenization as GPUSurfaceTelemetry.loggedHost, 'private' for incognito/ephemeral), the count at that moment and the decision. That shows whether context losses ever coincide with the cap, and at what count.
5. No automatic reload of the broken tab: it stays broken until the user reloads. A hint ('Graphics were reset, reload this page') is out of scope unless the user asks for it.

Guard against loops: WebKit terminates all web processes after repeated GPU process exits in a short window, and every recycle itself causes context losses in WebGL pages. Signals that arrive within a grace period after a recycle (or while the count is low) must not start another one.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A webglcontextlost or webglcontextcreationerror in any frame of a normal or private tab reaches the recycler as an immediate check; pages cannot observe the listener or the message handler
- [x] #2 With the count at or above the near-cap level, a confirmed signal recycles even within minimumInterval and while a tab is audible, and never while a tab captures camera or microphone
- [x] #3 Below the near-cap level, a signal only logs; a page calling WEBGL_lose_context does not recycle
- [x] #4 Context losses caused by a recycle do not trigger another recycle (grace period), and the signal rate is limited per web view
- [x] #5 Every signal logs a notice in category gpu-recycle with kind, tokenized host, count and decision
- [x] #6 Policy tests cover the confirmed-breakage path (interval and audio bypass, capture guard, below-threshold, grace period); a runtime check with low env thresholds and a fixture page that loses its context shows the immediate recycle in log show
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. WebGLContextLossBridge (new): an isolated-world script in every frame, with capture listeners on window for webglcontextlost and webglcontextcreationerror, at most one report per kind per frame per 5 s. It posts to the detourWebGLLoss handler; installed and registered beside the favicon and media bridges in BrowserTab.
2. Policy: breakageLimit 15,000, contextLossWindow 30 s, postRecycleGrace 5 min; inputs capturingMedia and lastContextLossAt; confirmsBreakage() is checked first in decide(). Env overrides BREAKAGE_LIMIT and POST_RECYCLE_GRACE_SECONDS.
3. Recycler: contextLossReported starts an immediate check, at most one per 5 s, with a check scheduled for any report in between. Each pending report is logged as a notice with the outcome (count, keep/wait/recycle). The recycle line says contextLoss=.
4. Tests: policy cases plus bridge tests with real WebGL (main frame, subframe, rate limit, creation error, page isolation, idempotent install).
5. Runtime check with low env thresholds and a fixture page; wiki gpu-iosurface-limit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented 2026-11-18.
- Review (/code-review --fix, 10 findings):
  - Fixed by the review: reports within the post-recycle grace start no count and are logged 'not counted'; the pid recheck runs before the losses are logged, so a cancelled kill logs 'recycle skipped (GPU process changed)'; a redundant condition; a duplicate test helper; the isolation test could not fail (it now registers a page-world handler and posts to it).
  - Fixed after the review: only isTrusted events count; the report throttle is now the pure ContextLossCheckThrottle and the grace is GPUProcessRecyclePolicy.isRecyclesOwn, both tested.
  - Not done: canvases outside the document and OffscreenCanvas are missed. Catching them would need a page-world getContext wrapper, which attestation scripts can detect; documented in the wiki. Also not done: no sampling-skip far below the limit (reports should still log a count, and one sample costs about 50 ms); not merged with the telemetry's event batching (different flush triggers).
- Tests: GPUProcessRecyclePolicyTests 34/0, WebGLContextLossBridgeTests 6/0 (real WebGL in the test host: main frame, subframe, 5 s per frame, untrusted events ignored, page isolation, idempotent install). The related suites (FaviconLinkBridge, PageMediaControl, MediaBridgeMessage, GPUSurfaceTelemetry, AutomationGPUTools, BackForwardCacheTrim, MemoryPressureSleep) also ran: 119 tests, 0 failures, 1 skipped (the gated measurement leg testMeasureCriticalSweepCost).
- Runtime (/verify): isolated DetourVerify410 with BREAKAGE_LIMIT=1, the other tiers at 100000, MIN_INTERVAL 3600, POST_RECYCLE_GRACE 60, and a local fixture page.
  - The page world sees no handler (typeof … 'undefined').
  - WEBGL_lose_context at 00:54:39 logged 'WebGL context lost in 127.0.0.1 (main frame): GPU process 20224 holds 35 IOSurfaces; recycle (breakage confirmed)' and 'Recycling … contextLoss=true'; the GPU pid changed 20224 → 21058.
  - A loss at 00:54:59 logged 'within 60 s of a recycle; not counted'.
  - A loss at 00:56:04, 85 s after the first recycle and inside the hour, recycled again (21058 → 22073). The page kept working through both.
  - The host was in the clear because GPUSurfaceLogPublic is set in the shared defaults domain.
- Not verified: a real failed creation from an exhausted GPU process; a page losing contexts at default limits (covered by the policy tests).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A page that loses a WebGL context, or fails to get one, now makes the GPU recycler count at once instead of at the next 2-minute tick.
- Detection: WebGLContextLossBridge listens in every frame of every tab, in its own script world, for trusted events only, at most once per kind per frame per 5 s.
- Decision: at 15,000 surfaces or more (breakageLimit) a report recycles immediately, even within the one-hour floor and while audio plays, but never during a camera or microphone call. Reports within 5 min of a recycle are the recycle's own and are ignored. Below the limit a report only logs.
- Logging: every report is logged at notice in gpu-recycle with the tokenized host, the count and the outcome.
- Limitation: canvases outside the document and OffscreenCanvas are missed (a page-world wrapper would be detectable); the 2-minute count still covers them.
- Verification: tests 40 + related suites (119, 0 failures); the runtime check showed an immediate recycle, the grace and the one-hour bypass.
<!-- SECTION:FINAL_SUMMARY:END -->
