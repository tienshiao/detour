---
id: TASK-231.5
title: >-
  Concurrency: image loaders, GPU process monitors and dev-mode capture are
  compiler-checked across threads
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T00:08:00Z'
updated_date: '2026-11-03T02:53:00Z'
labels:
  - concurrency
dependencies:
  - TASK-231.4
references:
  - Detour/Browser/Shared/FaviconPNGLoader.swift
  - Detour/Browser/NowPlaying/MediaArtworkLoader.swift
  - Detour/Browser/HoverCard/TabThumbnailCache.swift
  - Detour/Browser/DevMode/PageCapture.swift
  - Detour/Browser/GPUProcessRecycler.swift
  - Detour/Browser/GPUProcessOrphanReaper.swift
parent_task_id: TASK-231
priority: medium
type: chore
ordinal: 272000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Background work outside storage and extensions: FaviconPNGLoader and MediaArtworkLoader (global queue, NSLock), TabThumbnailCache (own queue), PageCapture (save queue), the dev toolbar inspector and capture groups, and GPUProcessRecycler / GPUProcessOrphanReaper, which sample on utility queues and re-enter the main actor with `MainActor.assumeIsolated` from timer and dispatch-source handlers. At the 2026-11-02 measurement: DevToolbarInspectorGroup 9 warnings, FaviconPNGLoader 5, and smaller counts in the rest.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 No concurrency warnings remain in these files
- [x] #2 `@unchecked Sendable`, `nonisolated(unsafe)` and `MainActor.assumeIsolated` remain only where the compiler cannot check the code, each with a comment saying what makes it safe
- [x] #3 MediaArtworkLoaderTests, TabThumbnailTests, PageCaptureTests, the favicon suites and the GPUProcess*PolicyTests pass
- [x] #4 The affected test suites pass under Thread Sanitizer (`xcodebuild ... -enableThreadSanitizer YES`), or the task records why a suite cannot run under it
- [x] #5 At runtime (/verify): favicons load, hover-card thumbnails appear, Now Playing artwork shows, and a dev-mode page capture saves
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Dev mode: WebInspectorControl Capabilities/Selectors nonisolated; CaptureImage, CaptureGeometry, CaptureFileName, CaptureDelivery.save nonisolated; PageCapture.Completion @MainActor @Sendable, encode work closure @Sendable; picker follower timer (main run loop) uses MainActor.assumeIsolated, its seen-active state a property; picker state closures @MainActor @Sendable.
2. Favicons: FaviconLoader fetch seam completion @Sendable, String keys; FaviconPNGLoader nonisolated + Sendable, NSLock-guarded cache and in-flight table in one Mutex, fetch seam behind a Mutex, completions @Sendable.
3. Scheme handlers (FaviconSchemeHandler, InternalPageSchemeHandler): only an identity crosses to the lookup queue; live tasks in a main-thread table (review: SchemeTaskTable tickets with a serial, see notes).
4. TabThumbnailCache completion @MainActor @Sendable; MediaArtworkLoader CappedDataFetcher downloads in a Mutex mutated in place; GPUProcessTable nonisolated.
5. Verify: suites normally and under TSan; runtime harness for favicons, artwork, thumbnails, captures, History page favicon.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Done 2026-11-02.

Warnings (full rebuild): 204 → 164. In scope, none left that are concurrency: DevToolbarInspectorGroup 9 → 0, WebInspectorControl 14 → 0 (incl. the Capabilities isolated-conformance warnings), PageCapture 4 → 0, BrowserWindowController+DevToolbar 3 → 0, FaviconPNGLoader 4 → 0, FaviconLoader 1 → 0, TabThumbnailCache 3 → 0, GPUProcessOrphanReaper 1 → 0, MediaArtworkLoader 2 → 1. Left: MediaArtworkLoader #ImplicitStrongCapture and the GPUProcessRecycler WKProcessPool deprecation, neither concurrency.

Review (/code-review --fix) found a regression of mine: with only ObjectIdentifier crossing to the lookup queue and nothing retaining a stopped task, WebKit could allocate the next task at the same address and the old request late answer reached it (e.g. favicon PNG bytes answering the History page CSS). Fixed by the review with SchemeTaskTable (Browser/Shared): insert returns a Sendable ticket (identity + serial), take(ticket) returns the task once and only for the matching serial, remove on stop. Also removed a double main hop in FaviconSchemeHandler. New SchemeTaskTableTests (5): the two identity-reuse tests fail when the serial check is removed. Skipped (TASK-231.7): ~15 test files store the favicon fetch seams in variables of the old non-Sendable type.

Tests: DevModeSiteOverride, DevMode, DevToolbarHosting, DevToolbarLayout, ExtensionFaviconScope, FaviconLinkBridge, FaviconLookupScope, FavoriteFavicon, GPUProcessOrphanPolicy, GPUProcessRecyclePolicy, InternalPageIntegration, InternalPage, MediaArtworkLoader, NowPlayingRule, NowPlayingTab, PageCapture, TabThumbnail, WebInspectorControl: 289 tests, 0 failures; under TSan (before the review fix) 289, 0 failures, 0 ThreadSanitizer reports; after the review fix with SchemeTaskTableTests: 294, 0 failures.

Runtime (harness docs/harness/task231-5-harness.patch + task231-5-fixture-server.py; profiles DetourVerify2315, 2315b; run before and after the review fix, same result): a tab favicon from a page <link rel=icon>, FaviconLoader direct load, FaviconPNGLoader resized to 32 px from a recorded visit, Now Playing artwork through MediaArtworkLoader/CappedDataFetcher, a hover-card thumbnail store + read, a visible and a full-page PageCapture, and the History page rendering a row favicon through InternalPageSchemeHandler: 8/8 PASS. Not exercised at runtime: the element-picker follower timer and the GPU process reaper/recycler (policy suites only), an extension detour-favicon request (ExtensionFaviconScopeTests).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Image loaders, the GPU process table, dev-mode capture and the inspector picker are compiler-checked: lock-guarded state moved into Mutexes (favicon PNG cache and in-flight table, artwork downloads), background work closures are @Sendable with main-actor completions, pure helpers nonisolated, and main-run-loop timers assume the main actor with a comment. The scheme handlers no longer send WKURLSchemeTask across threads; they answer through SchemeTaskTable tickets, which also guard against WebKit reusing a stopped task address (a regression the review caught in the first version, now tested). No concurrency warnings remain in scope (target 204 → 164); 294 tests pass, the suites also under TSan with no reports, and favicons, artwork, thumbnails, captures and History favicons work in the running app.
<!-- SECTION:FINAL_SUMMARY:END -->
