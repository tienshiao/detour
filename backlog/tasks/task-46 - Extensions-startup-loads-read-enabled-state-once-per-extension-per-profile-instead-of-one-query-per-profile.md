---
id: TASK-46
title: >-
  Extensions: startup loads read enabled state once per extension per profile
  instead of one query per profile
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 05:38'
updated_date: '2026-09-13 19:00'
labels:
  - extensions
  - efficiency
dependencies: []
priority: low
ordinal: 46000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
ExtensionManager.loadExtensionsIntoProfile (ExtensionManager.swift ~line 293) loops every installed extension and calls reconcileExtensionContext, which calls isEnabled(extensionID:inProfile:) -> AppDatabase.isExtensionEnabled, one SQLite read transaction per (profile, extension) pair, on the main thread, for every profile at launch and again whenever a profile is added mid-session. The base commit before TASK-38 issued a single AppDatabase.enabledExtensionIDs(for:) query per profile. The review's cache fix (commit 2ea2538) already routes enabledExtensions(for:) and pinnedExtensions(for:) through one query, but the startup reconcile loop still does per-extension reads. Fix shape suggested by the review: compute enabledExtensionIDs(for:) once per profile in loadExtensionsIntoProfile and pass the set into reconcileExtensionContext (add a parameter or an overload that takes a precomputed enabled set). Do NOT make isEnabled itself cache-backed: setEnabled invalidates the cache only after applyEnabledState, so a cache-backed isEnabled would read stale state mid-toggle. wakeForPendingInstalledEvent already short-circuits on in-memory checks for most extensions, so its ledger read is not part of this task. Found by the 2026-09-13 code review (verified PLAUSIBLE, efficiency).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 loadExtensionsIntoProfile issues one enabled-state query per profile regardless of the number of installed extensions
- [x] #2 reconcileExtensionContext behaviour is unchanged for every caller: same contexts loaded/unloaded, same result for enabled, disabled, and globally-disabled extensions
- [x] #3 setEnabled toggles still observe fresh enabled state (no stale read during a toggle), covered by the existing ExtensionEnabledStateTests
- [x] #4 A test asserts the per-profile query count (or equivalent) so the per-extension reads cannot creep back
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. In ExtensionManager.loadExtensionsIntoProfile compute AppDatabase.shared.enabledExtensionIDs(for: profile.id.uuidString) once and pass the set into a reconcileExtensionContext overload that takes the precomputed decision (shouldLoad: Bool) instead of calling isEnabled per extension. The existing call-time-reading overload stays for applyEnabledState / setEnabled so toggles never read a stale value.
2. Confirm enabledExtensionIDs(for:) has the same semantics as isExtensionEnabled (globally enabled AND no per-profile row turning it off) and note it at the call site.
3. Test: count the per-profile reads. Add an AppDatabase read counter (a debug-only hook or a static counter incremented by performRead, keyed by the label string) or an equivalent observable, and assert loadExtensionsIntoProfile with N>=3 installed extensions issues one enabled-state read; keep ExtensionEnabledStateTests green.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
loadExtensionsIntoProfile computes enabledExtensionIDs(for:) once and passes shouldLoad into a reconcileExtensionContext overload; the call-time-reading overload stays for setEnabled/applyEnabledState. DEBUG read counter in AppDatabase.performRead keyed by label; ExtensionStartupEnabledReadsTests (5) pins one read per profile and zero per-extension reads, verified non-vacuous by reverting the loop (3 reads for 3 extensions). Review: the enabled set is now served from the private cache shared with enabledExtensions(for:) so the toolbar read after extensionsDidChangeNotification does not repeat the query; enabledExtensionIDs(for:) selects ids only instead of decoding manifest blobs; dead fixture teardown removed. Tests after review: 65 across the startup, enabled-state, profile-load and defaults suites.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Startup reads a profile enabled-extension set once per profile instead of once per extension, through a shared cached query; behaviour of every reconcile caller unchanged. Verified by ExtensionStartupEnabledReadsTests, ExtensionEnabledStateTests and NewProfileExtensionLoadTests.
<!-- SECTION:FINAL_SUMMARY:END -->
