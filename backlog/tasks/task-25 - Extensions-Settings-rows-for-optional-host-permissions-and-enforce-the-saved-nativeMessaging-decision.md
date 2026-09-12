---
id: TASK-25
title: >-
  Extensions: Settings rows for optional host permissions, and enforce the saved
  nativeMessaging decision
status: Done
assignee:
  - '@claude'
created_date: '2026-09-12 19:07'
updated_date: '2026-09-12 23:13'
labels:
  - extensions
  - settings
  - permissions
dependencies:
  - TASK-19
priority: low
ordinal: 25000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Two gaps recorded during TASK-19 (f0a7ab0). (1) Decisions on optional_host_permissions, including sub-patterns granted at a permissions.request prompt, are now durable across reloads, but ExtensionsSettingsViewController renders toggles only for permissions/optional_permissions and site-access URL rows, so an optional host decision (a Deny in particular) cannot be reversed from Settings. Add rows for optional host patterns and for saved sub-pattern rows, driven by the saved .matchPattern rows gated by WebExtension.askableMatchPatterns, with toggles that write the row and re-apply to the loaded context. (2) The saved nativeMessaging decision is persisted but enforced nowhere: Profile.loadExtensionContext grants nativeMessaging unconditionally so the polyfill bridge works, and ExtensionManager.nativeHostAccess only checks the manifest. Decide whether a saved denial should block real native hosts (connectUsing/sendNativeMessage to non-built-in hosts) while the built-in detourPolyfill and detourWebSocketRelay hosts stay allowed, and implement it with positive and negative permission tests.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Settings lists each optional host pattern and each saved sub-pattern decision with its current status; toggling writes the row and takes effect on the loaded context without a relaunch
- [x] #2 A saved nativeMessaging denial blocks real native hosts and leaves the built-in hosts working, with positive and negative tests; or the decision not to enforce it is recorded in the plan doc and the row is no longer written
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Part 2 (nativeMessaging, decision already made: a saved denial blocks real hosts, built-ins stay allowed)
1. ExtensionManager.nativeHostAccess gains a savedDecision (autoclosure) input and a .deniedByUser case, checked after the built-in host names and the manifest gate; instance helper reads the saved row (fail closed on unknown status).
2. Both spawn paths (sendMessage toApplicationWithIdentifier, connectUsing) reject .deniedByUser with Chrome's 'Access to the specified native messaging host is forbidden.' NSError before any NativeMessagingHost is created.
3. liveNativeHosts / activeMessagingHosts keep the port / reply handler next to the host so a denial can tear down already-connected hosts: kill the process, disconnect the port with the forbidden error, release keep-alive, fail a pending one-shot reply.
4. Profile keeps granting nativeMessaging unconditionally; comments updated.
Part 1 (Settings rows)
5. ExtensionManifest parses optional_host_permissions; WebExtension exposes the saved sub-pattern rows that are restorable but not listed in the manifest.
6. Factor the match-pattern + URL restore loops out of Profile.loadExtensionContext into a reusable applier; ExtensionManager.setPermissionDecision writes the row and re-applies to every loaded context (host rows re-run the full grant-then-deny pass so the live state equals the post-relaunch state; nativeMessaging goes to the native-host enforcement instead of the context).
7. ExtensionsSettingsViewController: optional host pattern rows, saved sub-pattern rows section, nativeMessaging row reflects enforcement (absent = on), toggles route through setPermissionDecision.
Tests / docs
8. Pure gate tests (positive/negative), real-spawn tests with a fake host via DETOUR_NATIVE_MESSAGING_HOSTS_DIR (granted spawns, denied blocks + error, built-ins unaffected, deny disconnects a live host), setPermissionDecision re-apply tests on a loaded context.
9. API Explorer probe, docs/1password-integration-plan.md decision record.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Enforcement: ExtensionManager.nativeHostAccess(hostName:manifestPermissions:savedDecision:) adds .deniedByUser after the built-in host names and the manifest gate; the saved decision is an autoclosure read from the DB only for real hosts (AppDatabase.permissionStatus now fails closed on an unknown raw status). Both delegate spawn paths (sendMessage toApplicationWithIdentifier, connectUsing) refuse before a NativeMessagingHost exists. Error: NSError DetourExtension/-1 'Access to the specified native messaging host is forbidden.' (Chrome's wording). WebKit surfaces it as a rejected sendNativeMessage promise, and for a refused connectNative as port.error ('Invalid call to runtime.connectNative(). Access to ... forbidden.'), not runtime.lastError.
Disconnect on deny: liveNativeHosts keeps the port next to the host; disconnectRealNativeHosts(for:) kills the process, disconnects the port, releases keep-alive once per host, and rejects any in-flight one-shot reply (OneShotNativeRequest, reply-once). WebKit does not surface the error passed to MessagePort.disconnect(throwing:) on an established port, so the extension sees a plain onDisconnect. Side fix: a one-shot host that exits without replying now settles the promise with 'Native host has exited.' instead of hanging.
Settings: ExtensionManager.setPermissionDecision is the single toggle entry point. Host rows clear the toggled key and re-run the extracted Profile.applySavedHostAccessDecisions so live state == post-relaunch state. WebKit quirk found and pinned (testWebKitAllHostsGrantDoesNotEraseAllHostsDenial): for <all_urls> neither .unknown nor a grant removes an existing denial, so pattern keys are filtered out of both dictionaries directly. nativeMessaging row reads ON unless a denial is saved (matches enforcement). Optional host patterns listed under Optional:, restorable sub-pattern rows under 'Requested sites:' (WebExtension.savedSubPatternDecisionKeys, gated by askableMatchPatterns).
NativeMessagingHost.searchDirectories is now computed per lookup so tests can set DETOUR_NATIVE_MESSAGING_HOSTS_DIR in-process.
Validation: all Extension*/WK*/NativeHost*/NativeMessagingEnforcementTests classes, 366 tests, 0 failures, 0 skipped (TEST_RUNNER_DETOUR_DATA_DIR=DetourTests-task25). No fake-host sleep processes left behind. Settings UI itself not exercised live (screen/AX automation is blocked for the shell host); its logic is covered via setPermissionDecision and savedSubPatternDecisionKeys.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Settings now lists each optional_host_permissions pattern (under Optional:) and each restorable saved sub-pattern decision (under Requested sites:), and every permission toggle goes through ExtensionManager.setPermissionDecision, which writes the row and re-applies it to every loaded context immediately (host rows re-run the saved host-access restore after clearing the toggled key, so the live state matches the next launch). A saved nativeMessaging denial is now enforced at host dispatch: real hosts are refused in both WebKit delegate paths with Chrome's forbidden error and nothing is spawned, hosts already running are torn down on deny, and the built-in detourPolyfill / detourWebSocketRelay hosts ignore the decision; the context still grants nativeMessaging unconditionally. Decision and the 1Password consequence recorded in docs/1password-integration-plan.md; API Explorer gained native messaging probes and an optional host permission. Verified with 366 tests across all Extension*/WK*/NativeHost* classes plus the new NativeMessagingEnforcementTests (real fake-host spawns), 0 failures.
<!-- SECTION:FINAL_SUMMARY:END -->
