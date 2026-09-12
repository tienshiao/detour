---
id: TASK-12
title: >-
  Extensions: fail an in-flight offscreen.createDocument when its context
  unloads
status: To Do
assignee: []
created_date: '2026-09-12 02:48'
updated_date: '2026-09-12 06:57'
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
- [ ] #3 Tests cover the pending-create-then-stop sequence
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Found by the 2026-09-11 code review of TASK-2.

2026-09-11 code review (--fix): OffscreenDocumentHost.stop() now runs pending load completions, and the offscreen.createDocument completion in ExtensionPolyfillHandler checks that its host is still registered (guarding by identity) and replies 'Offscreen document was closed before it finished loading' otherwise, so a stopped/replaced host never reports success. The handler also builds the document from its own profile's context via the new extensionContextResolver rather than ExtensionManager.context(for:). AC #3 (a pending-create-then-stop test) is still open.
<!-- SECTION:NOTES:END -->
