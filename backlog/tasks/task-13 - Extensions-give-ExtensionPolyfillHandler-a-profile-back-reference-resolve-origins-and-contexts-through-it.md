---
id: TASK-13
title: >-
  Extensions: give ExtensionPolyfillHandler a profile back-reference; resolve
  origins and contexts through it
status: To Do
assignee: []
created_date: '2026-09-12 03:50'
labels:
  - extensions
  - security
dependencies: []
priority: medium
ordinal: 13000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
ExtensionPolyfillHandler is created inside Profile.extensionController but does not know which Profile owns it. Two consequences found by the 2026-09-11 code review of TASK-10: (1) sender-origin verification is an optional closure (extensionOriginResolver) that Profile installs; a handler built without it silently rejects every popup/options/offscreen message, and no test exercises the production wiring in Profile.extensionController (both test suites hand-install their own resolver), so deleting the wiring leaves the suite green while the app breaks. (2) offscreen.createDocument resolves the WKWebExtensionContext via ExtensionManager.shared.context(for:), which prefers the last-active space's profile; an extension enabled in two profiles can therefore have its offscreen document built in the wrong profile's controller and data store while this profile's offscreenHosts tracks it (wrong cookies, wrong teardown on unloadExtension). Fix: construct the handler with a weak reference to its Profile (init parameter), derive the verified id from profile.extensionID(forOriginScheme:host:), look up contexts via profile.extensionContext(for:), and remove the closure. The handler's other ExtensionManager.shared.extension(withID:) uses (manifest/permission lookups) are global by design and may stay.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 ExtensionPolyfillHandler is constructed with its owning Profile and has no settable resolver; a message from an extension page is attributed via the profile's loaded contexts
- [ ] #2 offscreen.createDocument/hasDocument/closeDocument operate on the context loaded in the handler's own profile, never on another profile's context; a test with the same extension loaded in two profiles shows the document is created in the sender's profile
- [ ] #3 A test builds a real Profile, touches extensionController, loads a context, and confirms the handler attributes that context's webkit-extension origin to the extension with no test-side wiring (deleting the production wiring fails the test)
- [ ] #4 Existing ExtensionPolyfillTests and ExtensionPolyfillIntegrationTests still pass after being ported to the new construction
<!-- AC:END -->
