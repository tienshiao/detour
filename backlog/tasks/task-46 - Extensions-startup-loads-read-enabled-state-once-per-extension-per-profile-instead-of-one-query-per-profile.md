---
id: TASK-46
title: >-
  Extensions: startup loads read enabled state once per extension per profile
  instead of one query per profile
status: To Do
assignee: []
created_date: '2026-09-13 05:38'
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
- [ ] #1 loadExtensionsIntoProfile issues one enabled-state query per profile regardless of the number of installed extensions
- [ ] #2 reconcileExtensionContext behaviour is unchanged for every caller: same contexts loaded/unloaded, same result for enabled, disabled, and globally-disabled extensions
- [ ] #3 setEnabled toggles still observe fresh enabled state (no stale read during a toggle), covered by the existing ExtensionEnabledStateTests
- [ ] #4 A test asserts the per-profile query count (or equivalent) so the per-extension reads cannot creep back
<!-- AC:END -->
