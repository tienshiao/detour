---
id: TASK-10
title: >-
  Extensions: verify polyfill bridge sender by context base URL, not extension
  id
status: Done
assignee:
  - '@claude'
created_date: '2026-09-12 02:48'
updated_date: '2026-09-12 03:45'
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
- [x] #1 A bridge message from an extension page is attributed to the extension whose context base URL host matches the frame's security origin, regardless of the extensionID field in the body
- [x] #2 A message whose body claims a different extension id than the verified one is rejected and logged, with tests for the positive (matching) and negative (mismatched, unknown origin) cases
- [x] #3 The stale doc comment about uniqueIdentifier being the origin host is corrected
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add an origin resolver hook to ExtensionPolyfillHandler (closure: scheme+host -> extension id) that Profile installs against its extensionContexts, matching context.baseURL scheme and host.
2. verifiedExtensionID(from:) uses the resolver; the web-view entry point rejects messages whose frame origin cannot be resolved (no more fallback to the body id for popup/options/offscreen pages). Native path keeps the context-derived id.
3. Fix stale doc comments (handler + integration test) claiming uniqueIdentifier is the origin host.
4. Tests: unit tests with a stub resolver for matching, mismatched and unknown origins via the webkit.messageHandlers path; integration test wires the resolver to the test profile so real webkit-extension:// origins are verified.
5. Run ExtensionPolyfillTests + ExtensionPolyfillIntegrationTests.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Found by the 2026-09-11 code review of TASK-2 (a verifier probed the SDK: origin is a fresh UUID independent of uniqueIdentifier).

Fix: ExtensionPolyfillHandler gained extensionOriginResolver (scheme, host) -> extension id; Profile installs it against extensionContexts by context.baseURL scheme+host (Profile.extensionID(forOriginScheme:host:)). The web-view entry point now rejects with 'Unrecognized extension origin' when the frame origin resolves to no loaded context (no body-id fallback on that path); a resolved id that disagrees with the body id still hits the 'attempted to act as' rejection. Native-message path unchanged (context-derived id, body fallback only when the context maps to no profile). Stale uniqueIdentifier comments fixed in the handler and in ExtensionPolyfillIntegrationTests.
Validation: ExtensionPolyfillTests + ExtensionPolyfillIntegrationTests 98/98 pass (5 new unit tests: origin-attributed positive, mismatched claim, unknown origin, no resolver, resolver receives frame origin; 2 new integration tests against the real webkit-extension://<UUID> origin). ExtensionPermissionTests + WKExtensionIntegrationTests 37 pass, 6 pre-existing skips.

Code review (2026-09-11, --fix): closed the same hole on the native-message path — ExtensionManager now rejects a polyfill native message whose context is not listed in the profile's extensionContexts ('Unrecognized extension context') and handleNativeMessage/dispatch take a non-optional verified id (no body-id fallback anywhere). An empty body extensionID (polyfill stamps '' when chrome.runtime.id is unavailable in the frame) is treated as no claim rather than a mismatch. The unrecognized-origin rejection log is deduped per origin (first at .error, repeats at .debug) and keeps the host private, since the polyfill's console bridge runs in every frame of an extension-config web view, including extension tabs navigated to ordinary sites. Tests: native-bridge tests pass a verified id; new testWebViewMessageWithEmptyClaimedIDUsesVerifiedOrigin. 99/99 pass.

Post-review (/code-review --fix, 2026-09-11): verifiedExtensionID is now non-optional on both entry points; ExtensionManager's sendMessage delegate rejects a polyfill native message whose context maps to no loaded extension ('Unrecognized extension context') instead of passing nil; an empty body extensionID (polyfill stamps '' when chrome.runtime.id is unavailable) is treated as no claim rather than a mismatch; unrecognized-origin rejections are logged once per origin (host private) with a bounded set. Re-verified: ExtensionPolyfillTests, ExtensionPolyfillIntegrationTests, ExtensionPermissionTests, WKExtensionIntegrationTests: 136 tests, 0 failures, 6 pre-existing skips.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Bridge messages from extension web views (popup/options/offscreen) are now attributed by resolving the frame's webkit-extension://<UUID> origin against the owning Profile's loaded contexts instead of trusting the body's extensionID. Unresolvable origins are rejected, claimed-id mismatches are rejected and logged. Verified with new positive/negative unit and integration tests; all extension test classes pass.
<!-- SECTION:FINAL_SUMMARY:END -->
