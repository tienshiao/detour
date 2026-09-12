---
id: TASK-24
title: >-
  Extensions: give extension-page tabs a durable identity so they survive a
  relaunch
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-12 19:07'
labels:
  - extensions
  - tabs
  - persistence
dependencies:
  - TASK-14
priority: low
ordinal: 24000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-14 (804e431) rehomes open extension pages when their context reloads mid-session, but a persisted tab, pinned entry or favourite whose URL is webkit-extension://<uuid>/... is dead after a relaunch: WebKit mints a fresh base URL per context load, so the restored host matches no loaded context, BrowserTab.wakeConfiguration falls back to the space configuration, and the page cannot load. Persist the extension id plus the page path (and query/fragment) alongside the URL for extension-scheme tabs, pinned entries and favourites, and resolve them to the current context base URL at restore time (Profile.extensionContext(for:).baseURL); fall back to closing the tab when the extension is no longer installed or enabled. Consider the same identity for the closed-tab record (TASK-14 currently skips the record for closes on disable/uninstall because the archived URL would be dead).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 An extension options page open in a tab, a pinned entry and a favourite all reopen on the correct page after quit and relaunch
- [ ] #2 A persisted extension page whose extension was uninstalled while the app was closed is dropped cleanly rather than restored as a blank tab
- [ ] #3 TabStore persistence tests cover the round trip for the three kinds
<!-- AC:END -->
