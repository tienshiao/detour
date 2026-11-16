---
id: TASK-281
title: >-
  Native messaging: a broken host manifest in Chrome's or Chromium's folder
  hides a valid one in Detour's own folder
status: Done
assignee:
  - '@claude'
created_date: '2026-11-07T09:35:00Z'
updated_date: '2026-11-16T08:37:00Z'
labels:
  - extensions
  - native-messaging
dependencies: []
references:
  - Detour/Extensions/Runtime/NativeMessagingHost.swift
  - wiki/extensions/native-messaging.md
priority: low
type: task
ordinal: 328000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up from the TASK-264..277 review-fix batch (2026-11-06/07). Found while doing TASK-266.

Manifests are searched in Chrome's, Chromium's, Detour's, then /Library's folder, and since TASK-266 the first manifest file found decides (Chrome's rule): a file there that fails validation is a refusal, not a reason to keep looking. Chrome only searches its own folder, so the rule never makes one vendor's broken file hide another's; in Detour it does. A user who installs a host for Detour but has a stale or broken Chrome manifest for the same name gets a refusal. Decide whether Detour's own folder is searched first, or whether a refusal from another browser's folder falls through.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The search order and the first-file-decides rule are a deliberate choice, recorded with its reason in the native-messaging wiki page
- [x] #2 If the behaviour changes: a valid manifest in Detour's folder is used when Chrome's folder holds a broken one for the same host name, with a test
- [x] #3 1Password's real host manifest still connects (signed build, or recorded as owed)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. NativeMessagingHost.searchDirectories: build the list from a pure static function searchDirectories(home:systemLibrary:override:) in the decided order: (Debug only) DETOUR_NATIVE_MESSAGING_HOSTS_DIR, then ~/Library/Application Support/Detour/NativeMessagingHosts, Google/Chrome, Chromium, then /Library/Google/Chrome. The env override keeps its behaviour (Debug only, read on every lookup, searched first).
2. Move the directory walk into a static discoverManifest(named:in:) so tests can run the production walk over a temporary home laid out like the real one; the first file found still decides (a broken one ends the search).
3. Tests in NativeHostManifestValidationTests: the order list (with and without the override, and the live property under a set override); Detour's valid manifest wins over a broken and over a valid one in Chrome's folder; Chrome's folder is used when Detour's has none; Chrome before Chromium; /Library last; a broken manifest in Detour's folder still ends the search. No test touches the real folders.
4. Wiki: native-messaging (table, decided-order paragraph becomes the record with the reason), 1password-integration (Chrome's folder is no longer the first searched), other pages that state the order; wiki-lint; log line.
5. AC #3 (1Password real host connects) recorded as owed: needs a signed build and the user.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-15, the user's decision: search Detour's own NativeMessagingHosts folder first, then Chrome's and Chromium's, then /Library; the first file found still decides. A host installed for Detour always wins; Chrome's folder stays the fallback that lets hosts like 1Password work without installing for Detour. (Context given: every other Chromium browser reads only its own folder.)

Implemented (2026-11-16): NativeMessagingHost.searchDirectories now builds its list from the pure searchDirectories(home:systemLibrary:override:): (Debug only) DETOUR_NATIVE_MESSAGING_HOSTS_DIR, then ~/Library/Application Support/Detour/NativeMessagingHosts, Google/Chrome, Chromium, then /Library/Google/Chrome. The override is unchanged: Debug only, read from ProcessInfo on every lookup, ignored when empty, searched before every other folder. The directory walk moved into the static discoverManifest(named:in:) (the instance method calls it with the live list); the first file found still decides (TASK-266), so a broken file in any folder hides the folders after it, but another browser's file can no longer hide a host installed for Detour.

Tests (one xcodebuild run after the review fix, -only-testing): NativeHostManifestSearchOrderTests 10/0 (new: the order list with and without the override and the live property under a set override; Detour's valid manifest wins over a broken and over a valid one in Chrome's folder; Chrome's used when Detour's has none; then Chromium's; /Library last; a broken file in Detour's folder, or in Chrome's when Detour's has none, ends the search; nothing anywhere is not found) — the walk is the production one over a temporary root laid out like the real folders, no test reads or writes a real NativeMessagingHosts folder. Also NativeHostManifestValidationTests 18/0, NativeMessagingEnforcementTests 27/0, NativeMessagingHostLifecycleTests 40/0, NativeMessagingFramingTests 12/0, NativeHostKeepAliveTests 17/0, ExtensionPolyfillProfileWiringTests 54 passed / 13 skipped (gated) / 0 failed. Total 191 executed, 13 skipped, 0 failures.

Code review (/code-review medium --fix, forked): no correctness bugs. Fixed: the walk tests placed each manifest by its index in the production list, so they moved with the order they were meant to check; they now spell each folder's path out (directory(for:)). Not fixed, recorded: a stale or broken manifest in Detour's own folder now hides a valid one in Chrome's (the intended consequence of the user's decision; nothing in docs, scripts or the website tells users to copy a manifest there); the live-list test needs a Debug test build (as every suite using the override does).

Runtime: launch smoke only. Debug build from .derived, launched through launch-detour.sh with DETOUR_DATA_DIR=DetourVerify-281 and DETOUR_NATIVE_MESSAGING_HOSTS_DIR pointing at an empty scratch folder; ran 12 s, no native-messaging log lines from its pid until the SIGTERM line, stopped by pid, its two defaults keys and its data folder removed. The manifest search was not exercised in the running app (no nativeMessaging extension in the isolated profile; deliberately not seeded so nothing could reach a real host); it is exercised by the tests above in the Detour test host.

OWED (AC #3): a signed-build check by the user that 1Password still connects to its desktop app. The lookup for com.1password.1password changes only if a com.1password.1password.json exists in ~/Library/Application Support/Detour/NativeMessagingHosts; TASK-266 recorded that folder as absent on 2026-11-06 (not re-checked here: the brief keeps checks away from the real folders). AC #3 checked on the 'recorded as owed' clause, as TASK-266's AC #5 was.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Native host manifests are now searched in Detour's own NativeMessagingHosts folder first, then Chrome's, Chromium's and /Library/Google/Chrome (the Debug-only DETOUR_NATIVE_MESSAGING_HOSTS_DIR still comes before all of them, unchanged), as the user decided on 2026-11-15. The first file found still decides (Chrome's rule, TASK-266), so a stale or broken manifest in Chrome's or Chromium's folder no longer hides a host installed for Detour, and Chrome's folder stays the fallback that lets 1Password work without installing for Detour. The order is built by a pure function and the walk is a static function, so 10 new tests run the production walk over a temporary root laid out like the real folders. Tests: 191 across 7 native-messaging suites, 0 failures (13 gated skips). Wiki native-messaging (order table, the decision and its reason, tests) and 1password-integration updated. Owed: a signed-build check that 1Password still connects (affected only if a 1Password manifest sits in Detour's own folder). Risk recorded: a stale manifest in Detour's folder now hides Chrome's valid one, by design.
<!-- SECTION:FINAL_SUMMARY:END -->
