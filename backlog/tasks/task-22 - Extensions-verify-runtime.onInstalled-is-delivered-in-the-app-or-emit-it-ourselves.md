---
id: TASK-22
title: >-
  Extensions: verify runtime.onInstalled is delivered in the app, or emit it
  ourselves
status: Done
assignee:
  - '@claude'
created_date: '2026-09-12 19:07'
updated_date: '2026-09-12 23:47'
labels:
  - extensions
  - webkit
  - 1password
dependencies: []
priority: medium
ordinal: 22000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-20 (commit 985a445) measured that WebKit never delivers runtime.onInstalled to a background service worker in a context loaded programmatically in the test process: the worker answers every other message, its own in-worker record of the event never appears, and a storage marker written by the listener never lands while a marker written by a plain handler in the same run does. Setting context.uniqueIdentifier and a controller delegate changed nothing. The test testRuntimeOnInstalledIsNotDelivered pins the measurement. Unknown whether the app is affected: if WebKit also withholds it on a real install/update/launch, every extension that does first-run setup in onInstalled (1Password included; the polyfill also has an onInstalled emitter) never runs it. Determine what the app sees on a real install and on a context reload, with the API Explorer worker recording onInstalled details (reason, previousVersion) into storage; if WebKit does not fire it, decide whether Detour should synthesise it (Chrome semantics: install, update with previousVersion, chrome_update never) from ExtensionManager.install and record the decision in docs/1password-integration-plan.md.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 docs/1password-integration-plan.md records whether onInstalled fires in the app on install, on update and on a background-recovery reload, with the log or storage evidence
- [x] #2 If WebKit does not fire it, Detour emits it with Chrome reason/previousVersion semantics exactly once per install or update and never on a plain reload, covered by tests
- [x] #3 If WebKit does fire it, testRuntimeOnInstalledIsNotDelivered is rewritten to explain why the harness differs, or flipped
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Measure in a Debug app (isolated DETOUR_DATA_DIR, temporary env-gated harness driving ExtensionManager.install / recoverFromBackgroundLoadFailure / setEnabled, API Explorer worker recording onInstalled into storage.local + console bridge) for: first install, second install, update, recovery reload, global and per-profile disable/enable, same-version reinstall, relaunch, Private profile.
2. Record the measurement in notes and docs/1password-integration-plan.md (with WebKit source explanation).
3. If WebKit's behaviour is not Chrome's: Detour owns the decision. Pure rule: per (profile, extension) ledger of the last version onInstalled was delivered for; no entry -> install, different version -> update+previousVersion, same -> nothing. Persisted in the app DB, seeded by migration for existing installs so an upgrade does not fire install.
4. Delivery: the service-worker polyfill shadows addListener/removeListener/hasListener on the native runtime.onInstalled event (suppressing WebKit's own dispatch, never replacing chrome/browser/runtime), and on each worker start claims the pending event over the polyfill bridge; native decides + advances the ledger atomically (exactly once), worker dispatches. ExtensionManager wakes the worker after install/update/enable/launch when an event is pending.
5. Tests: pure rule, ledger claim once / per profile / migration seed, polyfill JS (suppression, dispatch, worker-only). Update testRuntimeOnInstalledIsNotDelivered's explanation. API Explorer readout.
6. Remove the harness, run the suites, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Measurement 2026-09-12, macOS 26.6.2 (25G83), WebKit 21624.5.1.11.3, Debug build, isolated DETOUR_DATA_DIR=DetourVerify-task22, temporary env-gated AppDelegate harness, API Explorer worker recording onInstalled (reason, previousVersion, version, ms after worker start) to storage.local and the console bridge (-ExtensionConsoleLogPublic YES). Logs: /tmp/claude/task22-{install,install2,second,update3,relaunch}.log.
- First install into a profile whose controller has never loaded a context (fresh profile; also +21 s after launch): NOT delivered. WebKit starts the worker and fires runtime.onStartup instead ('worker start v3.0.0, onInstalled history: []' then 'runtime.onStartup').
- Install while the controller already has a context loaded >5 s earlier (primer extension installed 10 s before): delivered {reason:install}.
- Update 3.0.0 -> 3.0.1 (same key/id): delivered {reason:update, previousVersion:3.0.0}, persistent Default profile. In the non-persistent Private profile the same update delivers {reason:install} (no previousVersion).
- Background-recovery reload (Profile.recoverFromBackgroundLoadFailure): delivered {reason:install} - spurious.
- Global disable->enable and per-profile disable->enable: delivered {reason:install} - spurious.
- Reinstall of the same version: {reason:install}.
- Relaunch: onStartup only, no onInstalled (Default and Private).
Explanation from WebKit source (WebExtensionContextCocoa.mm determineInstallReasonDuringLoad, WebExtensionController.cpp): version or bundle hash differs from State.plist LastSeenVersion -> update; otherwise, if the controller is 'freshly created' (5 s window, which in the shipped build evidently starts at the controller's first context load) -> no install reason, onStartup; otherwise -> install. So every in-process reload/enable of a same-version context is an 'install', and the first context a controller ever loads never gets one. The TASK-20 test process hits the freshly-created window, which is why testRuntimeOnInstalledIsNotDelivered sees nothing. Decision: WebKit's event cannot be used as is; Detour suppresses it in workers and emits its own from a per-profile version ledger.

Implemented: RuntimeInstalledEvent.pending (pure rule), extensionInstalledEvent ledger (migration v8 seeds existing installs x saved profiles), AppDatabase.pending/claimRuntimeInstalledEvent (claim = decide + advance in one transaction), handler case runtime.claimInstalledEvent, worker polyfill runtimeOnInstalledJS (shadows add/remove/hasListener(s) on the native event, holds the wrapper, verifies visibility else restores and leaves it to WebKit; claims once per worker start via setTimeout 0), ExtensionManager.wakeForPendingInstalledEvent after launch load / install / enable. Harness re-run with the fix: fresh-profile first install -> one install; update -> one update(previousVersion 3.0.0); recovery reload, disable->enable, same-version reinstall -> nothing; worker history ended with exactly [install, update]; relaunch: Private profile (created after the install) got one install, update to 3.0.2 one update per profile, per-profile re-enable nothing. Harness reverted. Tests: RuntimeInstalledEventTests 11/11, ExtensionPolyfillTests 128 incl. 8 new, integration suites (WKExtensionIntegration, PolyfillIntegration, ProfileWiring, PageRehost, PermissionRestore) 100/100, full DetourTests 725/0 failures (TEST_RUNNER_DETOUR_DATA_DIR=DetourTests-task22). Limits: extension pages keep WebKit's event; same-version reinstall is not an update; WebKit's onStartup on a profile's first install left alone.

Merged onto main after TASK-24, which also registered a migration named v8: the ledger migration is renamed v9 (RuntimeInstalledEventTests migrates up to v8 before seeding; plan doc updated). Merge also wires wakeForPendingInstalledEvent into TASK-26's reconcile design: after reconcileExtensionContext in loadExtensionsIntoProfile and install, and in applyEnabledState .loaded.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Measured in the app (macOS 26.6.2, WebKit 21624.5.1.11.3): WebKit's runtime.onInstalled follows a per-load rule - version change -> update, else install unless the controller is within 5 s of its first load. So a profile's first-ever install gets nothing (onStartup instead), a later install and updates are right, and every same-version background-recovery reload or disable->enable replays install; the Private profile sees updates as installs; relaunch is correct. The test process sits in the 5 s window, which explains testRuntimeOnInstalledIsNotDelivered (doc comment rewritten). Detour now owns the event: the worker polyfill keeps listeners off WebKit's event object and claims the event from a per-(profile, extension) version ledger once per worker start; install once, update once with previousVersion, never on reload/relaunch/enable, never chrome_update; migration seeds existing installs so an upgrade does not replay install; ExtensionManager wakes the worker when an event is owed. Verified with the app harness before and after, RuntimeInstalledEventTests + ExtensionPolyfillTests additions, full DetourTests green. Findings and decision recorded in docs/1password-integration-plan.md.
<!-- SECTION:FINAL_SUMMARY:END -->
