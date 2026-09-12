---
id: TASK-13
title: >-
  Extensions: give ExtensionPolyfillHandler a profile back-reference; resolve
  origins and contexts through it
status: Done
assignee:
  - '@claude'
created_date: '2026-09-12 03:50'
updated_date: '2026-09-12 07:41'
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
- [x] #1 ExtensionPolyfillHandler is constructed with its owning Profile and has no settable resolver; a message from an extension page is attributed via the profile's loaded contexts
- [x] #2 offscreen.createDocument/hasDocument/closeDocument operate on the context loaded in the handler's own profile, never on another profile's context; a test with the same extension loaded in two profiles shows the document is created in the sender's profile
- [x] #3 A test builds a real Profile, touches extensionController, loads a context, and confirms the handler attributes that context's webkit-extension origin to the extension with no test-side wiring (deleting the production wiring fails the test)
- [x] #4 Existing ExtensionPolyfillTests and ExtensionPolyfillIntegrationTests still pass after being ported to the new construction
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. ExtensionPolyfillHandler: add init(profile:) with private(set) weak var profile; delete extensionOriginResolver and extensionContextResolver. verifiedExtensionID(for:) -> profile?.extensionID(forOriginScheme:host:); offscreen.createDocument resolves context via profile?.extensionContext(for:) only (no ExtensionManager.context(for:) fallback). Nil profile => reject, never fall back.
2. Profile.extensionController: construct ExtensionPolyfillHandler(profile: self); remove closure wiring.
3. ExtensionPolyfillTests (bare WKWebView at https://test.example.com): add a test-only Profile subclass overriding extensionID(forOriginScheme:host:) to map that origin to test-polyfill-extension; construct handler with it; port the resolver-based negative tests (unknown origin, no resolver) to a profile that resolves nothing / a released (nil) profile. Native-bridge tests construct with a retained throwaway Profile.
4. ExtensionPolyfillIntegrationTests: create the test profile before the handler and construct ExtensionPolyfillHandler(profile: testProfile); drop the hand-installed resolver.
5. New tests (TDD, write first): (a) production wiring: real Profile via TabStore.addProfile, touch extensionController, loadExtensionContext(ext) with a temp extension, load test.html in a web view built from context.webViewConfiguration, post a raw bridge message via webkit.messageHandlers.detourPolyfill, expect success with no test-side wiring. (b) two profiles, same extension loaded in both, lastActiveSpaceID pointing at profile A's space, offscreen.createDocument sent through profile B's handler => B's offscreenHosts entry web view URL host equals B's context baseURL host, and A has no offscreen host. (c) negative: handler whose profile was released rejects with Unrecognized extension origin.
6. Run ExtensionPolyfillTests, ExtensionPolyfillIntegrationTests, ExtensionPermissionTests; then code-review, fix, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented: ExtensionPolyfillHandler.init(profile:) with weak back-reference; extensionOriginResolver/extensionContextResolver removed; offscreen.createDocument resolves only via profile.extensionContext(for:). Tests ported (OriginMappingProfile seam in ExtensionPolyfillTests; integration suite constructs with its profile). New ExtensionPolyfillProfileWiringTests cover production wiring, offscreen in sender's profile, and no cross-profile fallback. First run: 123 tests green across the four extension suites. Code review (medium) raised: (1) offscreen load failure never replies, pre-existing -> filed TASK-18; (2) sessions.restore/search.query still pick the space globally -> fixing here with tests; (3) fixed sleeps in new tests -> navigation waits; (4) duplicated helpers -> shared ExtensionTestSupport; (5) makeHandler bookkeeping -> removed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
ExtensionPolyfillHandler is now constructed with a weak back-reference to its owning Profile (init(profile:)); the extensionOriginResolver and extensionContextResolver closures are gone. Sender origins are attributed via profile.extensionID(forOriginScheme:host:), and offscreen.createDocument resolves the context only via profile.extensionContext(for:), with no ExtensionManager.context(for:) fallback. Review follow-up in the same change: sessions.restore and search.query now act in one of the handler's profile's spaces (targetSpace()) instead of the global last-active space. Tests: new ExtensionPolyfillProfileWiringTests (production wiring with zero test-side resolver, offscreen document created in the sender's profile and refused when its context is not loaded there, search/restore land in the sender's profile), shared ExtensionTestSupport (navigation-completion waits replacing fixed sleeps, raw envelope poster), existing polyfill/integration suites ported. Verified: 126 tests green across ExtensionPolyfillTests, ExtensionPolyfillIntegrationTests, ExtensionPolyfillProfileWiringTests, ExtensionPermissionTests; app target builds. Pre-existing offscreen load-failure bug found in review filed as TASK-18.
<!-- SECTION:FINAL_SUMMARY:END -->
