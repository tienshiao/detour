---
id: TASK-25
title: >-
  Extensions: Settings rows for optional host permissions, and enforce the saved
  nativeMessaging decision
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-12 19:07'
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
- [ ] #1 Settings lists each optional host pattern and each saved sub-pattern decision with its current status; toggling writes the row and takes effect on the loaded context without a relaunch
- [ ] #2 A saved nativeMessaging denial blocks real native hosts and leaves the built-in hosts working, with positive and negative tests; or the decision not to enforce it is recorded in the plan doc and the row is no longer written
<!-- AC:END -->
