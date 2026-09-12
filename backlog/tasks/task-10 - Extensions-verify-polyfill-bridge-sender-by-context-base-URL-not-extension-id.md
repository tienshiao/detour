---
id: TASK-10
title: >-
  Extensions: verify polyfill bridge sender by context base URL, not extension
  id
status: To Do
assignee: []
created_date: '2026-09-12 02:48'
labels:
  - extensions
  - security
dependencies: []
priority: high
ordinal: 10000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
ExtensionPolyfillHandler.verifiedExtensionID(from:) derives the trustworthy sender of a bridge message (popup/options web views) from the frame's security origin, assuming the origin host equals the extension id set as WKWebExtensionContext.uniqueIdentifier. It does not: WebKit assigns each context a webkit-extension://<random UUID>/ base URL (confirmed 2026-09-11; every launch logs a different UUID for the same extension). So the lookup never matches, the function returns nil, and dispatch falls back to the self-reported extensionID in the message body. That id gates permission-checked polyfill calls (history.search, management.getAll, native messaging routing, offscreen hosts), so any extension page can act as another installed extension. Fix: resolve the frame's origin host against the loaded contexts of the profile that owns the handler (Profile.extensionContexts, matching context.baseURL.host), return that extension id, and treat a mismatch between the verified id and a claimed id as a rejection (the existing 'attempted to act as' path). Consider also verifying service-worker-originated messages via the WKWebExtensionContext passed to the delegate (already the case in handleNativeMessage) so both entry points are trustworthy.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A bridge message from an extension page is attributed to the extension whose context base URL host matches the frame's security origin, regardless of the extensionID field in the body
- [ ] #2 A message whose body claims a different extension id than the verified one is rejected and logged, with tests for the positive (matching) and negative (mismatched, unknown origin) cases
- [ ] #3 The stale doc comment about uniqueIdentifier being the origin host is corrected
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Found by the 2026-09-11 code review of TASK-2 (a verifier probed the SDK: origin is a fresh UUID independent of uniqueIdentifier).
<!-- SECTION:NOTES:END -->
