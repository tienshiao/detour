---
id: TASK-12
title: >-
  Extensions: fail an in-flight offscreen.createDocument when its context
  unloads
status: Done
assignee:
  - '@claude'
created_date: '2026-09-12 02:48'
updated_date: '2026-09-12 17:55'
labels:
  - extensions
  - offscreen
dependencies: []
priority: low
ordinal: 12000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
OffscreenDocumentHost.load(...) runs its completion from the web view's didFinish; stop() (now called from Profile.unloadExtension via ExtensionPolyfillHandler.closeOffscreenDocument) clears loadCompletionHandlers without calling them, so a worker awaiting chrome.offscreen.createDocument at the moment its context unloads or reloads never gets a reply. The completion currently has no failure shape. Give the host a Result-style completion (or an explicit error path) so stop() rejects pending creates with a clear error, make the polyfill handler reply with that error, and make sure a create that resolves after the host was replaced by a new context's host does not report success against the wrong context.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Unloading or reloading a context while offscreen.createDocument is pending rejects the promise in the worker with a descriptive error instead of leaving it pending
- [x] #2 A create completing for a stopped host does not mark a document as existing for the extension (hasDocument stays false)
- [x] #3 Tests cover the pending-create-then-stop sequence
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Shared change with TASK-18 (one commit). AC #1/#2 landed in the 2026-09-11 review; this pass gives the host a Result-style completion with an explicit LoadError.closedBeforeLoad (so the closed case is a real failure rather than a success the handler has to second-guess) and adds AC #3: a test that issues offscreen.createDocument through handleNativeMessage and calls closeOffscreenDocument while the load is still in flight, asserting the request rejects with 'Offscreen document was closed before it finished loading' and that hasDocument stays false.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Found by the 2026-09-11 code review of TASK-2.

2026-09-11 code review (--fix): OffscreenDocumentHost.stop() now runs pending load completions, and the offscreen.createDocument completion in ExtensionPolyfillHandler checks that its host is still registered (guarding by identity) and replies 'Offscreen document was closed before it finished loading' otherwise, so a stopped/replaced host never reports success. The handler also builds the document from its own profile's context via the new extensionContextResolver rather than ExtensionManager.context(for:). AC #3 (a pending-create-then-stop test) is still open.

AC #3 closed together with TASK-18 in one change (same completion plumbing). The closed case is now an explicit failure rather than an indistinguishable success: stop() settles pending load completions with OffscreenDocumentHost.LoadError.closedBeforeLoad, and the handler's reply string for the closed/replaced case is that error's localizedDescription, so the wording lives in one place. closeOffscreenDocument keeps its unregister-then-stop order, which is what makes the handler's identity guard see the host is gone.

New test: DetourTests/ExtensionPolyfillProfileWiringTests.testPendingOffscreenCreateDocumentFailsWhenTheDocumentIsClosed — offscreen.createDocument goes through handleNativeMessage (createDocument registers the host and starts the load synchronously, so the request is genuinely in flight; the test asserts zero replies at that point), then closeOffscreenDocument runs. The request rejects with 'Offscreen document was closed before it finished loading', the hidden web view is released, hasDocument stays false, a later create succeeds, and the closed request was answered exactly once. AC #2's stronger form is also covered by TASK-18's testLateOffscreenLoadFailureDoesNotUnregisterANewerHost: a reply for a host that has been replaced reports the closed error and leaves the newer host registered.

Validation: xcodebuild -scheme Detour build => BUILD SUCCEEDED; env TEST_RUNNER_DETOUR_DATA_DIR=DetourTests-task18 xcodebuild -scheme DetourTests test => ExtensionPolyfillProfileWiringTests 13/13 pass, ExtensionPolyfillTests + ExtensionPolyfillIntegrationTests 133/133 pass.

2026-09-12 code review (--fix): tests now assert OffscreenDocumentHost.LoadError.closedBeforeLoad.localizedDescription rather than the literal string; see TASK-18 notes for the shared completion / concurrent-create / cancelled-navigation changes.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Pending offscreen.createDocument requests now fail with an explicit OffscreenDocumentHost.LoadError.closedBeforeLoad when the document is closed or its context unloads mid-load, and the handler's closed-case reply is that error's description (one source for the wording). AC #3 is covered by a new test that closes the document while a create is genuinely in flight and asserts the rejection message, the released web view, hasDocument staying false, a successful create afterwards, and exactly one reply.
<!-- SECTION:FINAL_SUMMARY:END -->
