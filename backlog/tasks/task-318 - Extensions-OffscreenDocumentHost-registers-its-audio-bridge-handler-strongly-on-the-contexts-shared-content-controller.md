---
id: TASK-318
title: >-
  Extensions: OffscreenDocumentHost registers its audio bridge handler strongly
  on the context's shared content controller
status: To Do
assignee: []
created_date: '2026-11-10T09:32:00Z'
labels:
  - extensions
  - memory
  - bug
dependencies: []
references:
  - TASK-315
  - Detour/Extensions/Runtime/OffscreenDocumentHost.swift
  - Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
  - Detour/Browser/Shared/WeakScriptMessageHandler.swift
priority: low
type: bug
ordinal: 380000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Noted by the TASK-315 code review (2026-11-10). OffscreenDocumentHost.load (OffscreenDocumentHost.swift:151-152) registers itself with config.userContentController.add(self, name: audioBridgeHandler). WKUserContentController retains the handler it is given (the TASK-315 leak: that is what kept closed browser windows alive). Here the configuration is the extension context's webViewConfiguration (ExtensionPolyfillHandler.swift ~1114), whose user content controller the comment at OffscreenDocumentHost.swift:148-150 says is shared with the service worker, so it lives as long as the extension context, not the offscreen document.

What releases it today: stop() removes the handler by name, and the two known teardowns go through it. ExtensionPolyfillHandler.closeOffscreenDocument(for:) (offscreen.closeDocument, and Profile.unloadExtension at Profile.swift:637) unregisters the host and then calls stop(). offscreenLoadCompletion captures the host weakly, which suggests the code expects the host to be freed once it is unregistered.

Risk: any path that drops a host from offscreenHosts, or drops the ExtensionPolyfillHandler or the profile, without stop() leaves the host (its hidden WKWebView's navigation delegate, its AVAudioPlayer) alive for the context's lifetime, and its handler keeps receiving audio bridge messages for that extension. Not yet checked: profile deletion while an offscreen document is open, a failed load's teardown, a context reload (extension update, chrome.runtime.reload), and whether a second host for the same extension can be registered before the first is stopped.

Suggested fix: register through WeakScriptMessageHandler (Browser/Shared, added in TASK-315), keep stop()'s removal, and audit the paths above.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A test drops an offscreen host the ways the app can (closeDocument, context unload, failed load, profile removal) and asserts a weak reference to it goes nil
- [ ] #2 The audio bridge handler no longer retains the host (WeakScriptMessageHandler or equivalent), or the task records why a strong one cannot leak
- [ ] #3 The offscreen and audio bridge API tests still pass, in a real extension context (ExtensionPolyfillIntegrationTests style)
<!-- AC:END -->
