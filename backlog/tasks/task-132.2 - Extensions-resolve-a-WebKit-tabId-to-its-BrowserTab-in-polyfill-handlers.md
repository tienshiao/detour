---
id: TASK-132.2
title: 'Extensions: resolve a WebKit tabId to its BrowserTab in polyfill handlers'
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 23:07'
updated_date: '2026-10-04 00:04'
labels: []
dependencies: []
parent_task_id: TASK-132
priority: high
ordinal: 134000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Polyfilled APIs that take a tabId (tabs.group, tabGroups, chrome.debugger) need the BrowserTab behind it, and WebKit exposes no lookup from its tab identifier. No handler in ExtensionPolyfillHandler does this today. Candidate: the polyfill reads chrome.tabs.get(tabId) and chrome.windows.getAll() and sends the window ordinal and tab index, which map onto the arrays Detour itself returns from openWindowsFor and BrowserWindowController.extensionTabs; native validates (URL) and returns a stable token the polyfill caches per tabId. Must work from the service worker (sendNativeMessage) and from extension pages (message handler), and in reverse (BrowserTab to tabId) for events and for groupId on Tab objects.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A handler given a tabId from tabs.query gets the right BrowserTab for normal, pinned, favourite and Peek tabs, in a window that is not key, and for an unselected tab
- [x] #2 A tabId of a closed tab, or one from another profile's context, is refused with an error and never resolves to a different tab
- [x] #3 Resolution stays correct after tabs are reordered, moved between spaces, or the window switches space between two calls
- [x] #4 Tests cover the positive and refused cases
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Mechanism (validated 2026-10-03 with the standalone probe in .claude/scratch/task132.1-sidepanel-spike.m, macOS 26.7): tabs.getZoom(tabId) needs neither the tabs permission nor host access, fails with 'Tab not found' for an unknown id, and returns the tab delegate's zoomFactor(for:) value unclamped (a negative number came through). So the tab itself can answer with a private handle.

1. Native registry: every BrowserTab gets a process-unique positive integer handle on first use; handle -> BrowserTab is held weakly. Lookup validates the tab is still placed (space tab, pinned entry, favourite backing tab or Peek) and belongs to the asking profile.
2. BrowserTab.zoomFactor(for: context): normally the web view's pageZoom (1 for a tab with no web view, which is what WebKit's default would report). While a resolve is armed for that context it consumes one arm and returns -handle.
3. Polyfill handler messages: tabs.armResolve (adds one arm for the calling extension context, expiring after a few seconds), tabs.disarmResolve, and a lookup used by tests and later APIs.
4. Polyfill JS (preamble, worker and pages): __detourResolveTab(tabId) -> Promise<handle>, serialised per JS context, arm -> getZoom -> negative means handle; cache tabId <-> handle and drop it on tabs.onRemoved. chrome.tabs.getZoom is wrapped so a genuine call that steals an arm (negative answer) re-arms for the resolver and asks again, and so never shows a negative zoom to the extension.
5. Reverse: __detourTabIdForHandle(handle) from the cache, with an async fallback that walks tabs.query({}).
6. Tests: registry unit tests; integration tests in a real extension context for normal, pinned, favourite, Peek and unselected tabs, a closed tab, another profile's context, and reorder / move between spaces.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented 2026-10-03 (Opus agent, reviewed by the main session).
- Native: ExtensionTabHandleRegistry.swift (weak handle table, per-context arm counter with 5 s expiry and a cap of 32, placement check, profile check); BrowserTab.zoomFactor(for:) consumes an arm and answers -handle, otherwise the web view's pageZoom (1 with no web view; a sleeping tab is never woken); handler messages tabs.armResolve / tabs.disarmResolve / tabs.describeHandle and ExtensionPolyfillHandler.resolveTabHandle(_:), the entry point for the later tabId-taking handlers. Every refusal reads the same to the extension; the reason goes to the log.
- Polyfill: tabResolveJS — __detourResolveTab(tabId, {fresh}), __detourTabIdForHandle, __detourFindTabIdForHandle (non-enumerable); tabs.getZoom wrapped in place and rooted.
- Deviation from the plan: the getZoom wrapper does not hand a stolen arm back. Doing so livelocks (the resolver has already re-armed, so the returned arm is surplus and the genuine call's re-ask consumes it again). A negative answer is the handle of the tab that was asked about, so the wrapper reads that tab's zoom through tabs.describeHandle instead; the resolver retries up to 5 times.
- tabs.onRemoved is listened to only from the first cache entry, so an extension that never resolves a tab is not woken on every tab close.
- Limits: the async reverse walk uses tabs.query({}), which lists only each window's active space, so a tab in a space no window shows is found only if it was resolved before. Any extension in the profile can describe any handle in that profile (placement, selected, zoom, tab UUID; no URL or title).
- WebKit behaviour met on the way (existing, unchanged): a window whose activeTab is not among its tabs lists no tabs at all; WebKit learns of a new window only at context load or when it becomes key, because Detour does not call didOpenWindow otherwise.

Verification: final run of ExtensionPolyfillTests, ExtensionPolyfillIntegrationTests, ExtensionPolyfillProfileWiringTests, ExtensionTabLifecycleTests, ExtensionActiveTabTests, ExtensionTabHandleRegistryTests, ExtensionTabResolveTests: 344 tests, 0 failures, 4 skipped (the env-gated TASK-62 measurement legs), log newer than every source file. One earlier run had a single failure in testStorageManagedInRealExtensionContextSurvivesGarbageCollection ('no collection observed in 10 rounds', the test's own GC precondition, at load average ~98); it passed on rerun and in the final run. Runtime: the app builds and launches in an isolated profile and the hello-world extension's worker starts with the new polyfill and gets onInstalled. API Explorer's worker fails to load when the extension is seeded straight into the database, identically in a baseline build of the pre-change tree (7 'failed to load' lines in both), so that is not from this change; not investigated further. Not verified: a key window, Private windows, a signed build.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Polyfill handlers can now turn a WebKit tab id into its BrowserTab. The polyfill arms a resolve, calls tabs.getZoom(tabId), and the tab WebKit resolved the id to answers with a private handle instead of its zoom; the handle maps back to the tab natively, refusing closed, unplaced and other-profile tabs. Works from the service worker and from extension pages, with no permissions, for normal, pinned, favourite and Peek tabs, selected or not. A genuine tabs.getZoom never sees a handle. Covered by 40 new tests (registry unit tests, real-context round trips from both transports, refusals, reorder / space move / space switch); the seven affected suites pass (344 tests). Later tabId-taking handlers should call ExtensionPolyfillHandler.resolveTabHandle(_:) natively and __detourResolveTab(tabId) in the polyfill.
<!-- SECTION:FINAL_SUMMARY:END -->
