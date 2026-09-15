---
id: TASK-80
title: >-
  Extensions: polyfill chrome.storage.managed — 1Password 8.12.37 throws on its
  absence during init, so the worker never connects to the desktop app and the
  popup spins forever
status: Done
assignee:
  - '@claude'
created_date: '2026-09-15 03:29'
updated_date: '2026-09-15 03:42'
labels:
  - extensions
  - 1password
  - bug
dependencies: []
priority: high
ordinal: 80000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-09-14 on a machine running 1Password 8.12.37.1 (the working machine had 8.12.26.40). The popup showed only a spinner and Detour never connected to the native host. With ExtensionConsoleLogPublic set, the worker console showed '[unhandled rejection] TypeError: undefined is not an object (evaluating browser.storage.managed.onChanged)' (background.js:85) and then '[Sls] Not attempting to connect to desktop app: initialization hasn't finished' on every popup open. Cause: 8.12.37 added a Credential Intelligence managed-config monitor (class with readManagedConfig / reevaluateConfigAndNotifyListeners) whose initialize() calls browser.storage.managed.onChanged.addListener(...) and browser.storage.managed.get synchronously inside 1Password's async background initialize, before initializeNativeAppConnection. WebKit's WKWebExtension has no storage.managed, so the TypeError rejects the whole initialize: 'Finished initializing 1Password' never runs, the native app connection is never made, and the popup waits forever. Fix: a polyfill module that adds a read-only, always-empty managed StorageArea to the native chrome.storage (Detour has no enterprise policy source), rooted with __detourHoldWrapper and checked for visibility the way actionUserSettingsJS does, only when chrome.storage exists and lacks managed.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 chrome.storage.managed exists in worker and extension pages when WebKit's chrome.storage lacks it: get() resolves {} (or the supplied defaults object), getBytesInUse() resolves 0, set/remove/clear reject with a read-only error (lastError in callback form), onChanged has addListener/removeListener/hasListener and never fires
- [x] #2 A native storage.managed is left untouched, and nothing is installed when chrome.storage is absent (no storage permission); _polyfillDiag.apis records native/polyfill/absent/not-visible
- [x] #3 ExtensionPolyfillTests cover the positive and negative cases, and an integration test in a real WKWebExtensionContext asserts the module installs and the patch survives a garbage collection
- [x] #4 API Explorer exercises storage.managed
- [x] #5 1Password 8.12.37.1 in the signed build logs 'Finished initializing 1Password', connects to the native host, and the popup opens
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. storageManagedJS module in ExtensionAPIPolyfill: patch an empty read-only managed StorageArea onto native chrome.storage when it lacks one, hold the wrapper, verify visibility, diag marker. 2. ExtensionPolyfillTests: stub shape and both call styles, lastError on callback writes, native left alone, absent without chrome.storage. 3. Integration test in a real WKWebExtensionContext: installs and survives a collection, storage.local still native. 4. API Explorer probe (background + popup). 5. docs/1password-integration-plan.md Phase 2 entry with the diagnosis. 6. User verifies in the signed build.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Diagnosis 2026-09-14 (signed build, macOS 27.0, 1Password 8.12.37.1): with ExtensionConsoleLogPublic set, every worker start logged [unhandled rejection] TypeError evaluating browser.storage.managed.onChanged and then [Sls] Not attempting to connect to desktop app: initialization hasn't finished; no native host was ever started by Detour (the BrowserSupport processes running belonged to Arc). In background.js the monitor's initialize() (guarded only by isSafari/isFirefox-style checks) is called synchronously in the main async initialize right before initializeNativeAppConnection. The concurrent 'WASM is not initialized' rejection is a benign startup race. Implemented storageManagedJS (Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift) and diag apis.storageManaged; tests: 4 new in ExtensionPolyfillTests, 1 in ExtensionPolyfillIntegrationTests (real context reports 'polyfill' on macOS 27, patch survives a GC, storage.local stays native). ExtensionPolyfillTests + ExtensionPolyfillIntegrationTests: 188 tests, 0 failures. API Explorer: Storage Managed section. Note: tests had to run with -derivedDataPath outside ~/Library/Developer/Xcode/DerivedData because macOS App Management blocks writing into the existing Detour.app bundle there. Also seen, not in scope: chrome.windows.getCurrent from the worker yields undefined (callback reads A.id -> uncaught TypeError in 1Password's SignInWith setup) because the polyfill's windows.get finds no window.

Signed build 2026-09-14 20:36 (pid 19118): with the fix the worker logs '👍 Finished initializing 1Password', Detour connects to com.1password.1password and sends NmRequestAccounts; the host answers BrowserVerificationFailed / 'Disconnected from Desktop app due to UnknownBrowser' because this machine's 1Password has no trust grant for Detour yet (browsers.other-trusted-apps is per machine). The signature is valid Developer ID 58MN2R524R with hardened runtime. AC #5 waits for the user to add Detour as a trusted browser in 1Password and re-test.

Signed build 2026-09-14 20:40, after the user added Detour as a trusted browser in 1Password: NmRequestAccounts round trips succeed (1-58 ms), no BrowserVerificationFailed, popup works. Code review (/code-review --fix) of the working tree: no findings, nothing changed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
1Password 8.12.37 calls browser.storage.managed.onChanged.addListener/get synchronously inside its background initialize, before the desktop-app connection; WebKit has no storage.managed, so the TypeError aborted init and the popup spun forever (8.10.80.23 never touches storage.managed). Added storageManagedJS to ExtensionAPIPolyfill: an empty read-only managed StorageArea (get -> {} or defaults, getBytesInUse 0, getKeys [], set/remove/clear reject 'This is a read-only store.' with lastError in callback form, never-firing onChanged) patched onto the native chrome.storage only when it lacks one, wrapper rooted and visibility-checked; diag apis.storageManaged. Tests: 4 unit (stub, lastError, native untouched, absent) + 1 real-context integration (installs on macOS 27, survives GC, storage.local stays native); ExtensionPolyfillTests + ExtensionPolyfillIntegrationTests 188/0 failures. API Explorer Storage Managed section; docs/1password-integration-plan.md Phase 2 entry. Verified in the signed build: init finishes and the native connection works once 1Password trusts Detour on the machine (a separate, per-machine grant).
<!-- SECTION:FINAL_SUMMARY:END -->
