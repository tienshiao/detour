---
id: TASK-267
title: >-
  Extensions: management.uninstallSelf with showConfirmDialog can show its
  app-modal alert again and again with no user action
status: Done
assignee:
  - '@claude'
created_date: '2026-11-07T00:12:00Z'
updated_date: '2026-11-07T01:52:00Z'
labels:
  - extensions
  - security
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionManager.swift
  - Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
priority: medium
type: bug
ordinal: 314000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

`ExtensionManager.uninstallSelf` (TASK-257) shows an app-modal NSAlert with no user-gesture check (the polyfill has no gesture signal). The only guard is `pendingUninstallSelfConfirmations`, which stops two alerts stacking but not a new one right after Cancel. A worker on a timer or a loop can therefore keep the user in a cycle of modal alerts, and the alert names the extension with its own manifest-controlled display name, at a moment the extension chooses.

The `history` / `management` `permissions.request` prompt (TASK-260) also appears without a gesture, but a denial is saved and later requests are refused without asking, so it cannot loop the same way.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 After the user cancels an uninstallSelf confirmation, further uninstallSelf calls with showConfirmDialog from that extension are refused without an alert for a period (or the session), with Chromium's cancel error
- [x] #2 uninstallSelf without showConfirmDialog is unaffected
- [x] #3 Tests cover cancel followed by an immediate second request, using uninstallSelfConfirmationAnswerOverride
- [x] #4 The polyfill-layer wiki records the rule
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. ExtensionManager: add a clock seam (var now: () -> Date = Date.init, as in ExtensionPolyfillHandler/QuickDetourIdleMonitor) and a per-extension 'cancelled at' map. When the confirmation is cancelled, record now(); a later uninstallSelf with showConfirmDialog from that extension within the cooldown is refused at once with Chromium's kUninstallCanceledError text, without an alert. showConfirmDialog false is not checked against it. uninstall(id:) forgets the entry.
2. Decision: timed, 10 minutes, per extension, measured from the Cancel. Chrome avoids the loop with a user-gesture requirement (kGestureNeededForUninstallError), which still lets a user retry at once; Detour has no gesture signal. A session-long block would refuse a deliberate retry until relaunch; 10 minutes caps a looping worker at one alert per 10 minutes, long enough to open Settings and remove or disable it. Elapsed time outside [0, cooldown) (clock set back) does not refuse.
3. Tests (ExtensionManagementSelfTests): direct cancel then immediate second request refused without asking, asked again after the clock passes the cooldown, another extension unaffected; real-context test: after a cancel the next request from page and worker, promise and callback, is refused with the cancel text without an alert; showConfirmDialog false during the cooldown still uninstalls; adjust the existing four-form cancel test to advance the clock between forms.
4. Wiki polyfill-layer.md table rows; API Explorer result text mentions the cooldown; run ExtensionManagementSelfTests.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decision: timed cooldown, 10 minutes per extension, measured from the Cancel (ExtensionManager.uninstallSelfCancelCooldown; clock seam ExtensionManager.now, the codebase's () -> Date convention). Chrome stops the loop with a user-gesture requirement (kGestureNeededForUninstallError), which still allows an immediate deliberate retry; the polyfill has no gesture signal. A session-long block would refuse a deliberate retry until relaunch; 10 minutes caps a looping worker at one alert per period and leaves time to remove or disable it in Settings. Refusal text is Chromium's kUninstallCanceledError, same as Cancel. A time before the Cancel (clock set back) does not refuse; a forward wall-clock jump ends the period early (accepted; a monotonic clock was considered in review and left for consistency with the seam). uninstall(id:) forgets the Cancel; a Cancel on an extension uninstalled while its alert was up is not recorded (review fix).
Tests: ExtensionManagementSelfTests 12/12 passed (twice, before and after the review fix), including new testACancelledDialogIsNotShownAgainInsideTheCooldown (direct: immediate refusal synchronous and unasked, still refused at cooldown-1 s, another extension asked, asked again at the cooldown, clock set back does not refuse) and testAfterACancelTheNextDialogsAreRefusedUnaskedFromBothTransports (real context: page + worker, promise rejection + callback lastError, then showConfirmDialog false still uninstalls). The existing four-form cancel test now advances the injected clock past the cooldown before each call.
/code-review --fix: 1 bug fixed (Cancel recorded after an uninstall-while-alert-up); skipped: wall clock vs monotonic (design), tearDown leaves cooldown entries for UUID-suffixed test ids (harmless), hard-coded '10 minutes' in API Explorer comment and wiki.
Runtime (/verify, isolated DETOUR_DATA_DIR DetourVerifyT267, throwaway seeded probe extension): the Debug build loaded the probe, whose worker called uninstallSelf({showConfirmDialog:true}); the real alert appeared (captured: 'Uninstall "T267 Cooldown Probe"?', Cancel / Uninstall). NOT verified at runtime: the Cancel -> immediate refusal leg. The dev app's windows were not on the current screen/Space, AX listed no windows, and a PID-posted Escape did not reach the alert, so Cancel could not be pressed safely; the app was killed by PID and the data dir and defaults keys removed. That leg is covered by the tests above.
API Explorer: the uninstallSelf button's comment notes the cooldown (the button's behaviour needs no code change).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
After the user cancels a management.uninstallSelf confirmation, the extension's further requests for the dialog are refused for 10 minutes without an alert, with Chromium's cancel error (promise rejection / runtime.lastError); calls without showConfirmDialog are unaffected. ExtensionManager gains uninstallSelfCancelCooldown, a per-extension Cancel time, and a now() clock seam. Tests cover cancel followed by an immediate second request (direct and from both transports in both forms). Wiki polyfill-layer and permissions pages record the rule and why it is timed. Runtime: the real alert was shown from a seeded worker; the Cancel leg was not exercised in the app (input could not reach the alert).
<!-- SECTION:FINAL_SUMMARY:END -->
