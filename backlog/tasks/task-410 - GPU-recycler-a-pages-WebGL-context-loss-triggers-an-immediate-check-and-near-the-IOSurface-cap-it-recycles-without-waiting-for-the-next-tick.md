---
id: TASK-410
title: >-
  GPU recycler: a page's WebGL context loss triggers an immediate check, and
  near the IOSurface cap it recycles without waiting for the next tick
status: To Do
assignee: []
created_date: '2026-11-18T08:41:00Z'
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
- [ ] #1 A webglcontextlost or webglcontextcreationerror in any frame of a normal or private tab reaches the recycler as an immediate check; pages cannot observe the listener or the message handler
- [ ] #2 With the count at or above the near-cap level, a confirmed signal recycles even within minimumInterval and while a tab is audible, and never while a tab captures camera or microphone
- [ ] #3 Below the near-cap level, a signal only logs; a page calling WEBGL_lose_context does not recycle
- [ ] #4 Context losses caused by a recycle do not trigger another recycle (grace period), and the signal rate is limited per web view
- [ ] #5 Every signal logs a notice in category gpu-recycle with kind, tokenized host, count and decision
- [ ] #6 Policy tests cover the confirmed-breakage path (interval and audio bypass, capture guard, below-threshold, grace period); a runtime check with low env thresholds and a fixture page that loses its context shows the immediate recycle in log show
<!-- AC:END -->
