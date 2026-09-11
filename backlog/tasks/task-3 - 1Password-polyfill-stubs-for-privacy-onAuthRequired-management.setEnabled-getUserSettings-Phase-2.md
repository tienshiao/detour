---
id: TASK-3
title: >-
  1Password: polyfill stubs for privacy, onAuthRequired, management.setEnabled,
  getUserSettings (Phase 2)
status: To Do
assignee: []
created_date: '2026-09-11 22:28'
labels:
  - 1password
  - extensions
dependencies: []
documentation:
  - docs/1password-integration-plan.md
priority: medium
ordinal: 3000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Cheap API gaps 1Password hits. chrome.privacy.services.* is dereferenced without a chrome.privacy existence check in two 1Password functions and throws TypeError today (not fatal, but noisy and cheap to fix); Detour has no built-in password manager so a no-op ChromeSetting is honest. webRequest.onAuthRequired.addListener(fn, {urls}, ["asyncBlocking"]) is registered unguarded in the same block as 1Password's webNavigation listeners, so if WebKit lacks the event the rest of that block never runs. management.setEnabled has JS but no native dispatch case; 1Password only uses it to disable other 1Password channel builds, so a no-op is correct. action.getUserSettings is feature-detected; stub only if WebKit does not provide it. Per project convention each stub needs API Explorer coverage and tests.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 chrome.privacy.services.passwordSavingEnabled, autofillEnabled, autofillCreditCardEnabled and autofillAddressEnabled each expose get/set/clear/onChange; get resolves with levelOfControl not_controllable and set/clear resolve without error
- [ ] #2 chrome.webRequest.onAuthRequired exists with addListener/removeListener/hasListener in the service worker even when WebKit does not provide it
- [ ] #3 chrome.management.setEnabled resolves successfully and changes nothing
- [ ] #4 chrome.action.getUserSettings resolves with an isOnToolbar boolean
- [ ] #5 API Explorer exercises each new API and ExtensionPolyfillTests cover them, including that privacy stubs are absent when the privacy permission is not declared
<!-- AC:END -->
