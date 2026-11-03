---
id: TASK-231.1
title: >-
  Concurrency: main-actor default isolation and complete checking for the app
  target, with every WebKit delegate method still reachable
status: To Do
assignee: []
created_date: '2026-11-03T00:07:00Z'
labels:
  - concurrency
dependencies: []
references:
  - project.yml
  - Detour/Browser/Window/BrowserWindowController+WKUIDelegate.swift
  - Detour/Browser/Window/BrowserWindowController+Navigation.swift
  - Detour/Browser/QuickDetour/QuickDetourWindowController+WebKit.swift
  - Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
  - Detour/Browser/InternalPages/InternalPageBridge.swift
parent_task_id: TASK-231
priority: medium
type: chore
ordinal: 268000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
First step of the epic: turn the checking on (as warnings, still in 5.10 mode) so the following subtasks have a warning list to work through. The settings break the build (5 errors), and they silently disconnect 12 optional WebKit delegate methods whose signatures stop matching (see the epic). Turning the settings on and keeping those methods reachable have to land together. The WebKit callbacks involved: JS alert/confirm/prompt, runOpenPanel, requestMediaCapturePermission, didReceive authentication challenge, in both BrowserWindowController and QuickDetourWindowController.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 project.yml sets `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY: YES` and `SWIFT_STRICT_CONCURRENCY: complete` for the Detour target only (GRDB and Sparkle unaffected, `SWIFT_VERSION` stays 5.10), and the app builds
- [ ] #2 No "nearly matches optional requirement" warnings remain, and a test asserts that each WebKit delegate and script-message-handler class responds to the optional selectors it implements, so a future signature drift fails a test instead of only warning
- [ ] #3 At runtime, in a browser window and a Quick Detour window: JS alert, confirm and prompt show and return their values, a file input opens the open panel, a camera/mic request reaches the permission decision, and an HTTP auth challenge reaches its handler
- [ ] #4 The extension polyfill handler and the detour:// internal-page bridge still answer messages (ExtensionPolyfillIntegrationTests, InternalPageIntegrationTests pass)
- [ ] #5 The full DetourTests suite passes, and the remaining warning count per file is recorded in the task as the baseline for the following subtasks
<!-- AC:END -->
