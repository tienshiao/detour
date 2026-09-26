---
id: TASK-123
title: >-
  Extensions: defer an update while the extension is busy and fire
  runtime.onUpdateAvailable
status: Done
assignee:
  - '@claude'
created_date: '2026-09-26 02:51'
updated_date: '2026-09-26 05:13'
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
- [x] #1 A verified update for an extension with an open extension page or a busy worker is staged, not installed; runtime.onUpdateAvailable fires in its background context with the new version
- [x] #2 The staged update installs when the extension becomes idle, when it calls runtime.reload(), or at the next launch, through ExtensionManager.applyUpdate
- [x] #3 An idle extension still updates immediately as in TASK-113; tests cover both paths and the API Explorer logs onUpdateAvailable
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. ExtensionUpdateDeferral (pure): Activity{openPages, popupOpen, liveNativeHosts, lastBackgroundRequestAt} → shouldDefer(now:) (busy = any open extension page/popup, a live native host, or background polyfill traffic within 60 s). Tested.
2. StagedExtensionUpdate: verified unpacked files moved to <data>/Extensions/<id>.staged with detour-staged.json {version, publicKey, stagedAt}; load/all/discard.
3. ExtensionManager: activity(for:) (extensionPageLocations per profile, activePopovers, liveNativeHosts, backgroundActivity timestamps fed by the polyfill handler), stagedUpdate(for:), applyStagedUpdate(for:) → applyUpdate, applyStagedUpdatesBeforeLoad() at launch (installer-level replace before records are read), onUpdateAvailable waiters (long-held polyfill replies from background contexts, keyed by profile+extension) + notifyUpdateAvailable.
4. ExtensionUpdater: performCheck stages instead of applying when shouldDefer (outcome .deferred(version:)), skips a download when an equal-or-newer staged copy exists, and a 30 s poll applies staged updates once idle (posts didFinishCheck with .updated).
5. Polyfill: onUpdateAvailable arms 'runtime.awaitUpdateAvailable' lazily on first addListener (background only; refused elsewhere), re-arms after each delivery; runtime.reload() → native 'runtime.reload' applies a staged update, else falls through to WebKit's reload. requestUpdateCheck reports deferred as update_available.
6. Settings/AppDelegate (Opus): 'ready to install, waits for idle' line + Install Now button; summary counts; docs.
7. Tests: deferral, staging, updater busy→deferred→idle→applied, reload and launch paths, polyfill onUpdateAvailable + reload; API Explorer already logs onUpdateAvailable.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Review (--fix): the reload heuristic misfired on any ordinary worker start — the extension's top-level addListener arms runtime.awaitUpdateAvailable at script evaluation, which is answered at once when a copy is staged, and the start-up claim runs on a later task, so backgroundContextDidStart saw a fresh delivery and installed the update on every event wake (defeating the deferral). Fix: the polyfill mints __detourContextInstance per evaluation and stamps it on the wait and the claim; a delivery to the same incarnation no longer counts as the one a reload followed. Also: uninstall discards the staged copy and parked waits; a check that finds a staged copy for an idle extension installs it instead of reporting .deferred; the detour-staged.json marker is removed from the installed copy (the installer copies the directory whole); resetUpdateAvailableStateForTesting renamed forgetUpdateAvailableState.

Design: WebKit's chrome.runtime.reload is a read-only static value of the runtime wrapper (an own property is masked, unlike static functions such as getURL), so it cannot be intercepted; a reload keeps the context's base URL (WebExtensionContext::reload = controller unload + load), so its only trace is the background restart. A restart within 15 s of an onUpdateAvailable delivery, from a different polyfill incarnation (__detourContextInstance), installs the staged copy; other reloads leave it for the idle poll. Busy = open pages/popup/live native hosts/background polyfill traffic in the last 60 s. Verified by tests (updater deferral suite, polyfill worker suite: 331 extension tests green on the second run; one unidentified failure in the first wide run did not recur). Not exercised at runtime in the app: the Settings 'Install Now' row and a real store update landing while an extension is busy.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Updates no longer tear down a busy extension. ExtensionUpdater stages a verified update (<data>/Extensions/<id>.staged) when ExtensionUpdateDeferral says the extension is in use, reports it as .deferred, and installs it once idle (30 s poll), at the next launch, via Settings > Install Now, or on the background restart that follows a runtime.onUpdateAvailable delivery (the extension's reload). onUpdateAvailable is delivered through a parked runtime.awaitUpdateAvailable request from the background context, re-armed after each delivery and suppressed for the incarnation it was already delivered to. Added-permissions policy unchanged. Follow-ups noted in the task: permission rows for launch-time applies, and keep-alive extensions only update at launch or Install Now.
<!-- SECTION:FINAL_SUMMARY:END -->
