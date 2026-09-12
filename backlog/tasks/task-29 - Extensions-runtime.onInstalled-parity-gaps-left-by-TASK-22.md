---
id: TASK-29
title: 'Extensions: runtime.onInstalled parity gaps left by TASK-22'
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-12 23:49'
labels:
  - extensions
  - webkit
dependencies: []
documentation:
  - docs/1password-integration-plan.md
priority: low
ordinal: 29000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-22 (commit 1bf5460) made Detour the source of runtime.onInstalled for service workers: the worker polyfill hides WebKit's event on the native runtime.onInstalled object and claims a Detour-decided event once per worker start from the extensionInstalledEvent ledger (migration v9, RuntimeInstalledEvent.pending, AppDatabase.claimRuntimeInstalledEvent). Three gaps were knowingly left, each needing its own decision: (1) Extension pages (popup, options, other tabs) are not covered by the polyfill override, so a page that is open and has an onInstalled listener still receives WebKit's unreliable event — including the spurious install WebKit fires on a background-recovery reload or disable->enable. (2) Reinstalling the same version delivers nothing, because a version-keyed ledger cannot tell a reinstall from a reload; Chrome reports update for reloading an unpacked extension. Consider having ExtensionManager.install (explicit user action) clear or mark the ledger row so the next claim is update with previousVersion equal to the current version. (3) The Private (incognito) profile's storage is non-persistent but its ledger row is not, so an extension that does first-run setup in onInstalled finds its Private storage empty on every later launch with no event to rebuild it. Chrome's default 'spanning' incognito mode shares the regular profile's background, so decide the Detour equivalent (e.g. clear the Private profile's ledger rows at launch, or never deliver separately to Private) and record it in the plan doc.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Extension pages do not observe WebKit's spurious onInstalled on reload or re-enable (or the limitation is documented with a measured reason it cannot be hidden), with a test
- [ ] #2 A same-version reinstall through ExtensionManager.install delivers update with previousVersion equal to the installed version exactly once, and a plain reload still delivers nothing; covered by RuntimeInstalledEventTests
- [ ] #3 The Private profile behaviour is decided, implemented and recorded in docs/1password-integration-plan.md, with a test for the relaunch case
<!-- AC:END -->
