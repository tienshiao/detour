---
id: TASK-3
title: >-
  1Password: polyfill stubs for privacy, onAuthRequired, management.setEnabled,
  getUserSettings (Phase 2)
status: Done
assignee:
  - '@claude'
created_date: '2026-09-11 22:28'
updated_date: '2026-09-12 08:33'
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
- [x] #1 chrome.privacy.services.passwordSavingEnabled, autofillEnabled, autofillCreditCardEnabled and autofillAddressEnabled each expose get/set/clear/onChange; get resolves with levelOfControl not_controllable and set/clear resolve without error
- [x] #2 chrome.webRequest.onAuthRequired exists with addListener/removeListener/hasListener in the service worker even when WebKit does not provide it
- [x] #3 chrome.management.setEnabled resolves successfully and changes nothing
- [x] #4 chrome.action.getUserSettings resolves with an isOnToolbar boolean
- [x] #5 API Explorer exercises each new API and ExtensionPolyfillTests cover them, including that privacy stubs are absent when the privacy permission is not declared
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. privacyJS module (new, in ExtensionAPIPolyfill): installs chrome.privacy only when chrome.privacy is absent AND chrome.runtime.getManifest().permissions includes 'privacy'; privacy.services.{passwordSavingEnabled, autofillEnabled, autofillCreditCardEnabled, autofillAddressEnabled} are ChromeSetting objects with get() -> {value: false, levelOfControl: 'not_controllable'}, set()/clear() resolving undefined, onChange event emitter; callback and promise forms.
2. webRequestStubJS: when chrome.webRequest is absent, define chrome.webRequest = { onAuthRequired, onBeforeRequest, onCompleted, onErrorOccurred... } minimal: at least onAuthRequired with addListener/removeListener/hasListener (extra filter/extraInfoSpec args accepted and ignored); when chrome.webRequest exists but lacks onAuthRequired, add only that event. Service-worker and page contexts alike.
3. management.setEnabled: native dispatch case in ExtensionPolyfillHandler replying true (no-op; Detour has no other-channel builds to disable). Log at info.
4. action.getUserSettings: only when chrome.action exists and getUserSettings is not a function, add getUserSettings resolving {isOnToolbar: true} (callback + promise). Record in _polyfillDiag.apis whether each of the four was native or polyfilled.
5. Tests in ExtensionPolyfillTests: privacy present with permission (JS path via a registered extension whose manifest declares privacy; the bare web view shim must expose chrome.runtime.getManifest), absent without; webRequest.onAuthRequired listener API; management.setEnabled resolves via native bridge; action.getUserSettings shape. API Explorer: add privacy/webRequest/management.setEnabled/action.getUserSettings probes to popup + background; add 'privacy' to its manifest permissions.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented: privacyJS (installs chrome.privacy only when absent and the manifest declares privacy; no-op ChromeSettings, levelOfControl not_controllable), webRequestStubJS (full event-emitter namespace when chrome.webRequest is absent, or only onAuthRequired added to a native object; listeners never fire), actionUserSettingsJS (getUserSettings -> {isOnToolbar: true} only when chrome.action lacks it), native management.setEnabled no-op case. Diag records apis.privacy / apis.webRequest / apis.actionGetUserSettings as native|polyfill|absent. Runtime probe in a real WKWebExtensionContext on macOS 26 (2026-09-12): no native chrome.webRequest and no native action.getUserSettings, so both stubs are live. API Explorer gained Privacy, Web Request and Management sections plus an action Get User Settings button, and the privacy permission. 117 tests green across the three polyfill suites; app builds.

Code review (medium) decisions: webRequest stub now gated on the webRequest manifest permission (Chrome leaves the namespace undefined otherwise; feature-detecting extensions must not see a never-firing stub); management.setEnabled gated on the management permission like getAll, with a negative test; API Explorer manifest gains management and webRequest; the two new modules get per-module try/catch so a throw records an install error instead of skipping later modules; remaining fixed sleeps in ExtensionPolyfillTests replaced by navigation waits. Declined: persisting the widened origin pattern instead of the prompt URL (WebKit's widening rule is internal; current approach is tested), and a module-install abstraction for three modules. Cross-task finding on TASK-11 (Settings listed site-access rows the restore would skip) fixed alongside via WebExtension.canAskForAccess(to:), committed separately. Offscreen load-failure finding is TASK-18.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added the four cheap API gaps 1Password hits, each installed only where WebKit leaves a gap: chrome.privacy.services.{passwordSavingEnabled, autofillEnabled, autofillCreditCardEnabled, autofillAddressEnabled} as no-op ChromeSettings (get -> value false / levelOfControl not_controllable; set/clear resolve; onChange emitter), present only when the manifest declares privacy; chrome.webRequest stub with never-firing event emitters (onAuthRequired and the rest) only when the manifest declares webRequest, or just onAuthRequired added to a native namespace; chrome.action.getUserSettings -> {isOnToolbar: true} only when chrome.action lacks it; native management.setEnabled no-op gated on the management permission. _polyfillDiag records native/polyfill/absent per module. Probed in a real WKWebExtensionContext (macOS 26, 2026-09-12): WebKit provides neither chrome.webRequest nor action.getUserSettings. Tests: ExtensionPolyfillTests (positive and negative per gate, JS and native-bridge paths), an integration probe pinning the environment; API Explorer gained Privacy, Web Request and Management panels and the privacy/webRequest/management permissions. 147 tests green across five extension suites; app builds.
<!-- SECTION:FINAL_SUMMARY:END -->
