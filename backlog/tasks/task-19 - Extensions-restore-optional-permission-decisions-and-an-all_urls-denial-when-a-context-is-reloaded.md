---
id: TASK-19
title: >-
  Extensions: restore optional-permission decisions and an <all_urls> denial
  when a context is (re)loaded
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-12 17:29'
labels:
  - extensions
  - webkit
  - permissions
dependencies: []
documentation:
  - docs/1password-integration-plan.md
priority: medium
ordinal: 19000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Same class of bug as TASK-11, for two other row kinds. Profile.loadExtensionContext restores saved ExtensionPermissionRecord rows only for keys it finds in wkExt.requestedPermissions and wkExt.requestedPermissionMatchPatterns, and applies the '<all_urls>' row only when it is granted. But ExtensionManager.handlePermissionPrompt persists whatever WebKit prompted for: an API permission or match pattern listed under the manifest's optional_permissions / optional_host_permissions (requested at runtime via permissions.request) is saved as an .apiPermission / .matchPattern row and then never re-applied, and a user's denial of '<all_urls>' is saved but never re-applied. Because Profile.recoverFromBackgroundLoadFailure reloads a context mid-session (and every launch reloads it), the extension is re-prompted for optional permissions it was already granted, or loses them, and WebKit re-prompts for all-URLs access the user already refused. Fix on the restore side: walk wkExt.optionalPermissions and wkExt.optionalPermissionMatchPatterns as well as the requested sets, and apply a saved '<all_urls>' row whether granted or denied. Keep TASK-11's rule that rows outside the manifest's requested+optional sets stay inert (never widen a stale row). Verify which string WebKit reports for '<all_urls>' in requestedPermissionMatchPatterns / optionalPermissionMatchPatterns (pattern.string) so the explicit '<all_urls>' branch and the loop do not double-apply or disagree.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A granted optional API permission (manifest optional_permissions, granted via the promptForPermissions delegate) is granted on the context after unload+reload and after a fresh launch, without a new prompt
- [ ] #2 A denied optional API permission stays denied after reload; WebKit does not re-prompt for it
- [ ] #3 A granted or denied optional host match pattern (optional_host_permissions) is restored the same way
- [ ] #4 A denied '<all_urls>' row is applied as deniedExplicitly on reload; a granted one still restores as before
- [ ] #5 Rows whose key is in neither the requested nor the optional sets are still not applied (TASK-11 stale-row rule holds)
- [ ] #6 ExtensionPermissionRestoreTests cover each case above with positive and negative variants on a real Profile, and ExtensionPermissionTests cover the permission gating
<!-- AC:END -->
