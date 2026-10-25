---
id: TASK-204
title: 'Air Traffic Control: source-app routes for the link that launches Detour'
status: To Do
assignee: []
created_date: '2026-10-25 22:00'
labels:
  - links
  - feature
dependencies: []
priority: low
ordinal: 240000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-191.2. When a link from another app cold-launches Detour, AppKit delivers it to application(_:open:) with no current Apple Event (NSAppleEventManager.currentAppleEvent is nil), so the sender is unknown and a source-app route can never match that first link; it goes to the Default. Later links, including the rest of the same multi-URL open, carry the sender. Proposed fix: install Detour's own kAEGetURL (and open-documents if needed) handler early (applicationWillFinishLaunching), read keySenderPIDAttr there, and queue the URLs with their sender until launch finishes, then route them through openExternalURLs(_:sourceApp:). Check that this does not break the existing open-URLs-at-launch path or session restore ordering.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A link from an app that a source-app route names opens in that route's space even when it launches Detour
- [ ] #2 Links delivered during launch keep their order and are opened once
- [ ] #3 Checked at runtime with a helper .app opening a link into a non-running Debug copy with its own bundle ID (recipe in wiki/features/link-routing.md)
<!-- AC:END -->
