---
id: TASK-266
title: >-
  Native messaging: a host manifest without allowed_origins admits every
  extension
status: Done
assignee:
  - '@claude'
created_date: '2026-11-07T00:12:00Z'
updated_date: '2026-11-07T02:12:00Z'
labels:
  - extensions
  - native-messaging
  - security
dependencies: []
references:
  - Detour/Extensions/Runtime/NativeMessagingHost.swift
priority: medium
type: bug
ordinal: 313000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

`NativeMessagingHost.connect()` (NativeMessagingHost.swift ~180-186) validates the origin only inside `if let allowedOrigins`, so a manifest that omits the key lets any extension with `nativeMessaging` start the host. Chrome treats a manifest without `allowed_origins` as invalid. The manifest's `type` is not checked to be `stdio`, and a relative `path` resolves against the app's working directory instead of being refused (Chrome on macOS requires an absolute path).

Host manifests live in user-writable directories (Detour's and Chrome's NativeMessagingHosts), so the check is the only thing tying a host to the extensions it was installed for.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A host manifest with no allowed_origins, or a non-array one, is refused and no process is spawned
- [x] #2 A host manifest whose type is not stdio is refused
- [x] #3 A host manifest whose path is not absolute is refused
- [x] #4 The refusals reach the extension as Chrome's errors (one-shot rejection / port disconnect with lastError) and are logged
- [x] #5 1Password's real host manifest still connects (checked in a signed build or recorded as owed)
- [x] #6 Tests cover each refusal and the valid case
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Replace the Codable NativeHostManifest with a pure parse (JSONSerialization) that refuses, as Chrome's NativeMessagingHostManifest::Parse does: not a JSON object, missing/non-string name or path, type other than "stdio", allowed_origins missing / not an array / with a non-string entry. Unreadable or invalid files map to the same refusal.
2. connect(): invalid manifest -> refused before the origin check (Chrome RESULT_NOT_FOUND); origin not listed -> forbidden; then a non-absolute path -> refused (Chrome checks it after the origin, macOS has no relative form); then the executable check. Each refusal logged with the host name and reason; nothing spawned.
3. Errors reach the extension in Chrome's wording: manifest missing/invalid/relative path = "Specified native messaging host not found.", origin = "Access to the specified native messaging host is forbidden.", binary missing = "Failed to start native messaging host." (both delivery paths already pass connect()'s error through).
4. Built-in hosts (detourPolyfill, keep-alive anchor, WebSocket relay) are decided in nativeHostAccess before any NativeMessagingHost exists: unaffected.
5. Tests: pure parse unit tests (each refusal + valid), host-level connect tests against FakeNativeMessagingHost with edited manifests (no process spawned; relative path that DOES resolve to the executable from the cwd), and real-extension-context tests in NativeMessagingEnforcementTests for promise, callback lastError and connectNative port forms.
6. Read-only check of the real manifests on this Mac (pass/fail only); wiki native-messaging page; signed-build 1Password check recorded as owed.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Real host manifests on the development Mac (read only, checked with a script that printed pass/fail per check, not contents; 2026-11-06). Search directories: ~/Library/Application Support/Google/Chrome/NativeMessagingHosts, ~/Library/Application Support/Chromium/NativeMessagingHosts, ~/Library/Application Support/Detour/NativeMessagingHosts (absent), /Library/Google/Chrome/NativeMessagingHosts.
- com.1password.1password (Chrome dir): PASS on every new check (type stdio, absolute path, allowed_origins a list of strings) and it lists chrome-extension://aeblfdkhhhdcdjpifhhbdiojplfjncoa/, the id of 1Password as installed in Detour; path executable.
- com.anthropic.claude_code_browser_extension (Chrome and Chromium dirs): PASS.
- com.apple.passwordmanager (/Library/Google/Chrome, symlink into the system cryptex): PASS.
- com.1password.1password7 and 2bua8c4s2c.com.agilebits.1password (Chrome dir, legacy 1Password 7 hosts): pass the new checks, but their binaries are not installed, so they already failed (and still fail) at the executable check; unchanged by this task.
Detour's own hosts (detourPolyfill, detourKeepAliveAnchor, detourWebSocketRelay) are decided by name in ExtensionManager.nativeHostAccess before any NativeMessagingHost is created, so they never reach the manifest checks. expectedOrigin is chrome-extension://<Detour's extension id>/, the Chrome-derived id; there is no special mapping for 1Password.

Decisions:
- Chrome's order and result codes (native_process_launcher.cc): manifest validity (parse) -> origin (forbidden) -> absolute path (not found) -> launch. An invalid manifest ends the directory search, as Chrome loads the first manifest it finds.
- Errors the extension sees now carry Chrome's wording for every connect() refusal, the existing ones too: no/invalid manifest and relative path 'Specified native messaging host not found.', origin 'Access to the specified native messaging host is forbidden.' (was 'Extension <id> is not in the native host's allowed_origins'), binary missing 'Failed to start native messaging host.' (was 'Native messaging host binary not found at <path>'). Extensions written for Chrome (1Password) may key on Chrome's text; the specifics stay in the native-messaging log (log.error with host name and reason).
- An empty allowed_origins list is a valid manifest that admits nobody (forbidden), as in Chrome. description (required by Chrome) is not checked: it has no bearing on who may start the host, and refusing on it could break a hand-written manifest for no security gain.
- Wildcard origins are not specially refused (Chrome refuses the manifest); with an exact-match contains they never match, so the extension gets forbidden instead of not found.

Code review (/code-review --fix, forked): 8 findings, 6 fixed — a file whose name is not the host's now ends the search (Chrome: the first file found decides), an invalid host name gets Chrome's 'Invalid native messaging host name specified.', the rate-limited connectNative log line uses NativeMessagingError.logDetail (the specific cause) instead of the generic text, the redundant stored 'type' and an unused fixture property removed, wiki aligned. Not fixed, recorded: the error-level refusal log lines are not rate limited (the origin and binary lines already were not; connectNative attempts go through NativeConnectLogLimiter, one-shots do not); an invalid manifest in the Chrome/Chromium directory now hides a valid one in Detour's own directory (Chrome's first-file-decides rule, kept deliberately); allowed_origins entries are matched exactly rather than parsed as URL patterns (pre-existing: chrome-extension://<id>/* works in Chrome, is forbidden in Detour).

Tests (after the review fixes, one run, xcodebuild -only-testing): NativeHostManifestValidationTests 18/0 (new), NativeMessagingEnforcementTests 24/0 (5 new: promise, callback lastError and connectNative port for no allowed_origins, non-list allowed_origins, type socket, relative path, and a manifest not listing the extension), ExtensionPolyfillProfileWiringTests 53 passed / 13 skipped (gated) / 0 failed (1 new: the same refusals from a service worker), NativeMessagingHostLifecycleTests 20/0, NativeMessagingFramingTests 12/0, ExtensionPermissionTests 44/0, NativeHostKeepAliveTests 17/0, NativeConnectLogLimiterTests 8/0. Total 209 executed, 0 failures. The relative-path tests use a path that does resolve to the fake host's executable from the test host's working directory (asserted), so only the refusal keeps it from running.

Runtime (/verify): Debug build into .derived, launched only through launch-detour.sh with DETOUR_DATA_DIR=DetourVerify266; started cleanly, no native-messaging log lines, no errors; killed by PID, its defaults keys and data dir removed. The manifest path itself was not exercised in the running app (no nativeMessaging extension in the isolated profile); it is exercised by the tests above, which run the production delegate in the Detour test host with real WebKit contexts.

OWED (AC #5): a signed-build check that 1Password still connects to its desktop app. Not done here; the real com.1password.1password manifest was checked read-only and passes every new check and lists 1Password's id.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Native host manifests are now validated as Chrome validates them before any host process starts: allowed_origins must be present and a list of strings (a manifest without it used to admit every extension with nativeMessaging), type must be "stdio", path must be absolute (checked after the origin, Chrome's order), and the first manifest file found decides (an invalid one or one naming another host ends the search). Every connect() refusal reaches the extension in Chrome's wording on the one-shot promise, the callback's runtime.lastError and the connectNative port: not found / forbidden / failed to start / invalid name; the specifics go to the native-messaging log. Detour's own hosts (polyfill, keep-alive anchor, WebSocket relay) are decided by name before this path and are unaffected. Tests: 209 run across 8 suites, 0 failures, including 24 new. The real host manifests on this Mac (1Password, Claude Code, Apple Passwords) pass the new checks. Owed: a signed-build check that 1Password still connects. Follow-ups: rate-limit the per-attempt refusal log lines for one-shot calls; parse allowed_origins as URL patterns as Chrome does.
<!-- SECTION:FINAL_SUMMARY:END -->
