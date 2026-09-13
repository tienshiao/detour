---
id: TASK-36
title: >-
  Tests: stop the test host writing WebKit data into the production app's WebKit
  directory
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-13 03:21'
labels:
  - tests
  - storage
  - profiles
dependencies: []
priority: medium
ordinal: 36000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-32 work. The DetourTests host is Detour.app with bundle id com.detourbrowser.mac, so every WKWebsiteDataStore(forIdentifier:) and persistent WKWebExtensionController a test creates lands in ~/Library/WebKit/com.detourbrowser.mac/ — the same directory the production app in /Applications uses. DETOUR_DATA_DIR isolates only Detour's own databases. On 2026-09-12 this had accumulated 4,976 WebsiteDataStore and 3,408 WebExtensions directories (about 3.2 GB) from test runs and isolated verify runs; they were moved to the Trash by hand, keeping only the production profiles' directories. It also forces TASK-32's on-disk removal to be disabled outside the default data dir, because an isolated run cannot tell its identifiers from production ones. Fix the root cause: give the test host (and ideally isolated DETOUR_DATA_DIR runs) a WebKit directory of their own. Options to evaluate: a Debug/test bundle identifier (check the impact on Sparkle, keychain, the 1Password BrowserSupport trust work in TASK-6/TASK-7, and native messaging host manifests), a separate test-host app target, or having Profile use non-persistent stores and controllers when running under XCTest (check which tests genuinely need persistence, e.g. TASK-32's integration test). Tests that do create persistent identifier stores must remove them in tearDown.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A full DetourTests run leaves no new directories under ~/Library/WebKit/com.detourbrowser.mac/ (verified by counting before and after)
- [ ] #2 Tests that need a persistent identifier store or extension controller still work and clean up what they create
- [ ] #3 The chosen approach and its effect on Debug app runs (bundle id, Sparkle, keychain, native messaging, 1Password trust) are recorded in the task notes; if isolated DETOUR_DATA_DIR app runs also get their own WebKit directory, TASK-32's isolated-data-dir removal gate is revisited
<!-- AC:END -->
