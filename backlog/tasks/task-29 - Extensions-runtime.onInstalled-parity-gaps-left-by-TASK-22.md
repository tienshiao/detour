---
id: TASK-29
title: 'Extensions: runtime.onInstalled parity gaps left by TASK-22'
status: Done
assignee:
  - '@claude'
created_date: '2026-09-12 23:49'
updated_date: '2026-09-13 00:29'
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
- [x] #1 Extension pages do not observe WebKit's spurious onInstalled on reload or re-enable (or the limitation is documented with a measured reason it cannot be hidden), with a test
- [x] #2 A same-version reinstall through ExtensionManager.install delivers update with previousVersion equal to the installed version exactly once, and a plain reload still delivers nothing; covered by RuntimeInstalledEventTests
- [x] #3 The Private profile behaviour is decided, implemented and recorded in docs/1password-integration-plan.md, with a test for the relaunch case
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Measure first: an ExtensionPolyfillProfileWiringTests case with a real extension page from a loaded context, loaded after the controller's 5 s freshly-created window so WebKit fires a real install. Page listener added through chrome.runtime.onInstalled vs. a control listener added through the native prototype method; worker listener must get Detour's install exactly once.
2. Gap 1: runtimeOnInstalledJS shadows add/remove/hasListener(s) in every context with runtime.onInstalled; workers keep mode 'detour' + claim, pages get mode 'suppressed' (never claim, never dispatch). Keep the patch-not-visible fallback. Never touch chrome/browser/runtime.
3. Gap 2: migration v10 adds extensionInstalledEvent.reinstallPending (bool, default 0). RuntimeInstalledEvent.pending takes the flag: row + flag -> update with previousVersion = delivered version (equal to current on a same-version reinstall). ExtensionManager.install marks every row for the id when it replaces an installed extension, before contexts load; the claim clears it. Reload/enable/relaunch never touch it.
4. Gap 3: the pure rule returns nil for the Private profile; claim/pending take isPrivateProfile, never write a Private row; the handler passes profile.isIncognito; wakeForPendingInstalledEvent skips incognito. v10 deletes existing Private rows. Record decision and caveat in docs/1password-integration-plan.md.
5. Tests: RuntimeInstalledEventTests (rule, ledger, v10 migration, reinstall once, reload nothing, Private relaunch), ExtensionPolyfillTests (page suppression mode, Private claim through native bridge), API Explorer popup shows its own page mode. Full DetourTests run.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Measured page shadowing (2026-09-12, macOS 26.6.2, test process): new ExtensionPolyfillProfileWiringTests.testRealExtensionPageDoesNotSeeWebKitsRuntimeOnInstalled loads a throwaway context, waits 5.5 s past the controller's freshly-created window, loads an extension whose classic worker busy-waits 2.5 s, opens a real extension page from the context and adds one listener through chrome.runtime.onInstalled (shadowed) plus a control through WebKit's prototype addListener. Result: page polyfill mode 'suppressed', own shadow present and held; after waking the worker, WebKit really fired install at the page (control got [{reason: install}]) while the shadowed listener got [] and a fresh read after heap churn still returned the patched wrapper (hasListeners true). The worker, mode 'detour', got exactly one install (Detour's claim, claimCount 1). So the shadowing sticks in extension pages; no limitation to document.

Implemented: (1) runtimeOnInstalledJS shadows in every context with runtime.onInstalled; workers mode 'detour' (claim), pages mode 'suppressed' (no claim, no dispatch). (2) Migration v10 adds extensionInstalledEvent.reinstallPending; RuntimeInstalledEvent.pending(ledger:currentVersion:isPrivateProfile:) reads a flagged row as update from the delivered version; ExtensionManager.install marks all rows for the id via AppDatabase.markRuntimeInstalledEventReinstalled when it replaces an installed extension; the claim clears the flag. (3) pending/claim take isPrivateProfile (profile.isIncognito) and return nil without writing; ExtensionManager.installedEventOwingWake (used by wakeForPendingInstalledEvent) skips incognito; v10 deletes Private rows. Doc: new TASK-29 subsection in docs/1password-integration-plan.md, TASK-22 bullets marked superseded. API Explorer popup readout shows the popup's own mode and that its listener received nothing.

Validation: RuntimeInstalledEventTests 19/19, ExtensionPolyfillTests 140/140, ExtensionPolyfillProfileWiringTests 20/20; full DetourTests 799 tests, 0 failures (data dir DetourTests-task29). The app was not launched: all three behaviours are covered by tests, and the page-shadowing measurement ran against a real WebKit dispatch in the test process.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Closed the three runtime.onInstalled gaps TASK-22 left open. (1) Extension pages now shadow WebKit's onInstalled the same way the worker does, in mode 'suppressed': they never claim and never dispatch, so the spurious install WebKit fires on a recovery reload or re-enable cannot reach a page. This was measured first with a real extension page against a real WebKit install dispatch: a control listener on the native method received it, the shadowed listener did not, and the worker still got exactly one Detour install. (2) Migration v10 adds extensionInstalledEvent.reinstallPending. ExtensionManager.install sets it when replacing an installed extension, and the pure rule turns a flagged row into update with previousVersion equal to the delivered version, exactly once per profile. Reload, enable and relaunch never set it, so they still deliver nothing. (3) The Private profile never gets onInstalled, matching Chrome's spanning incognito mode: the rule, claim and wake all return nothing for it, no row is written, and v10 deletes the Private rows v9 seeded. The decision and the non-persistent-storage caveat are recorded in docs/1password-integration-plan.md. The API Explorer popup shows its own mode. Tests: RuntimeInstalledEventTests, ExtensionPolyfillTests and ExtensionPolyfillProfileWiringTests; full DetourTests 799/0.
<!-- SECTION:FINAL_SUMMARY:END -->
