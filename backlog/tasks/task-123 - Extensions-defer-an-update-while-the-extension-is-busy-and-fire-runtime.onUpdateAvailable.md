---
id: TASK-123
title: >-
  Extensions: defer an update while the extension is busy and fire
  runtime.onUpdateAvailable
status: To Do
assignee: []
created_date: '2026-09-26 02:51'
labels:
  - extensions
  - enhancement
dependencies:
  - TASK-113
priority: low
ordinal: 123000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-113 installs an update the moment it is verified, so runtime.onUpdateAvailable is defined by the polyfill but never fires. Chrome instead downloads the update, fires onUpdateAvailable, and applies it only when the extension is idle (no open extension pages, background worker idle) or when the extension calls runtime.reload(); an extension in the middle of work (1Password mid-fill, a userscript manager saving) is not torn down under the user. Implement that deferral in ExtensionUpdater / ExtensionManager.applyUpdate: stage the verified, unpacked update, fire onUpdateAvailable with {version} in the background context (needs a native→worker event push like the onInstalled wake path), apply when idle or on runtime.reload(), and apply staged updates at the next launch. Keep the added-permissions policy (install disabled pending approval) for the staged copy.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A verified update for an extension with an open extension page or a busy worker is staged, not installed; runtime.onUpdateAvailable fires in its background context with the new version
- [ ] #2 The staged update installs when the extension becomes idle, when it calls runtime.reload(), or at the next launch, through ExtensionManager.applyUpdate
- [ ] #3 An idle extension still updates immediately as in TASK-113; tests cover both paths and the API Explorer logs onUpdateAvailable
<!-- AC:END -->
