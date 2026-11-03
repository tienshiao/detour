---
id: TASK-231.5
title: >-
  Concurrency: image loaders, GPU process monitors and dev-mode capture are
  compiler-checked across threads
status: To Do
assignee: []
created_date: '2026-11-03T00:08:00Z'
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
- [ ] #1 No concurrency warnings remain in these files
- [ ] #2 `@unchecked Sendable`, `nonisolated(unsafe)` and `MainActor.assumeIsolated` remain only where the compiler cannot check the code, each with a comment saying what makes it safe
- [ ] #3 MediaArtworkLoaderTests, TabThumbnailTests, PageCaptureTests, the favicon suites and the GPUProcess*PolicyTests pass
- [ ] #4 The affected test suites pass under Thread Sanitizer (`xcodebuild ... -enableThreadSanitizer YES`), or the task records why a suite cannot run under it
- [ ] #5 At runtime (/verify): favicons load, hover-card thumbnails appear, Now Playing artwork shows, and a dev-mode page capture saves
<!-- AC:END -->
