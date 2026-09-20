---
id: TASK-75
title: >-
  Extensions: origin patterns with a port make chrome.permissions calls throw in
  WebKit, so 1Password never shows its menu on sites served from a non-default
  port
status: In Progress
assignee:
  - '@claude'
created_date: '2026-09-14 06:51'
updated_date: '2026-09-20 23:46'
labels:
  - extensions
  - 1password
  - bug
dependencies: []
priority: high
ordinal: 75000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-09-13 during the TASK-4 trial (signed build a68e26e) on a fixture at http://127.0.0.1:8471/: at page load WebKit logged 'Exception thrown: Invalid call to permissions.contains(). The origins value is invalid, because http://127.0.0.1:8471/* is not a valid pattern' and 1Password's inline menu appeared on none of the page's forms, including a plain top-level login form. Chrome match patterns accept a port in the host part; WebKit's WKWebExtensionMatchPattern rejects them (WebExtensionMatchPattern parses scheme://host/path only). 1Password builds the origin pattern of every page it sees and calls permissions.contains({origins: [...]}) (and presumably permissions.request when it asks for access) before working on the page, so the throw aborts its per-page setup. Any site on a non-default port is affected: local development servers, intranet tools, anything at host:8080. Fix in the polyfill (Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift, a new permissionsJS module patched onto the native chrome.permissions namespace with __detourHoldWrapper like chrome.action/webRequest — see docs/chrome-runtime-patching.md): wrap contains/request/remove (callback and promise forms), and for each string in details.origins strip an explicit port from the host part ('http://127.0.0.1:8471/*' → 'http://127.0.0.1/*', 'https://host:8443/path' → 'https://host/path'), leaving patterns without a port untouched, then forward to the native function. Semantics: Chrome grants are host-scoped in practice too (a <all_urls> or host_permissions grant covers every port), and WebKit's own grants are per host, so dropping the port asks WebKit the question it can answer. Log once per page (console bridge) when a pattern was rewritten so the diag shows it happened. Precedent: __detourWebNavFrames for wrapping a native namespace member and keeping its nativeness reading. Also worth checking in the same task whether Profile.applySavedHostAccessDecisions and ExtensionsSettingsViewController choke on saved patterns with ports (WKWebExtension.MatchPattern(string:) throws for them, Profile.swift:311/392 silently skip).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A polyfill test (ExtensionPolyfillTests, shim with a fake native chrome.permissions that records its calls) shows permissions.contains/request/remove receive origins with the port removed and other origins unchanged, in both callback and promise forms, and that the wrapper survives a re-run of the polyfill
- [x] #2 A real-context test (ExtensionPolyfillIntegrationTests or ExtensionPermissionTests) calls chrome.permissions.contains({origins: ['http://127.0.0.1:<port>/*']}) from a probe worker and gets a boolean back instead of a thrown 'not a valid pattern' error; the negative control without the wrapper still throws
- [ ] #3 In the signed build, 1Password's inline menu appears on the top-level form of the TASK-4 fixture page served on a non-default port (rerun the TASK-4 trial afterwards)
- [x] #4 docs/1password-integration-plan.md records the incompatibility and the rewrite rule
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. New polyfill module permissionsOriginPortJS in ExtensionAPIPolyfill.swift: wrap native chrome.permissions.contains/request/remove (callback + promise forms), strip an explicit port (:digits or :*) from the authority of each string in details.origins (IPv6 literal aware; patterns without a port and non-string entries untouched; details object copied, never mutated), forward to the native function. Idempotent on re-run (marker on the wrapper), rooted with __detourHoldWrapper('permissions'), install marker + diag entry, one console log per realm when a rewrite happened. Patch browser.permissions too if it is a distinct object.
2. Tests: ExtensionPolyfillTests shim (fake native permissions recording calls), real-context test with probe worker + negative control.
3. Check Profile.applySavedHostAccessDecisions / ExtensionsSettingsViewController for saved patterns with ports.
4. API Explorer extension coverage + docs/1password-integration-plan.md + docs/chrome-runtime-patching.md.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-09-20: implemented in 668e8d8 (permissionsOriginPortJS). chrome.permissions === browser.permissions in WebKit (one namespace object), so one patch covers 1Password's browser.* calls; a distinct second object is handled and unit-tested anyway. WebKit's native contains throws SYNCHRONOUSLY for a ported pattern (not a rejection) — a caller with only .catch() blows up at the call site, matching the 1Password failure. permissions.contains answers from granted patterns only (an explicit deny under a granted <all_urls> still answers true).
Saved-pattern check: a ported .matchPattern key can only reach the DB via a Settings toggle on a raw manifest host_permissions string; WebKit drops such a pattern from requestedPermissionMatchPatterns, so the row is inert either way and normalising would only widen it — left alone, pinned by ExtensionPermissionTests.testPortedHostPermissionNeverBecomesAnAskablePattern.
Code review: added 'define-failed' status when WebKit refuses the write (+ test). Known divergence kept by design: request/remove of a ported pattern act on the whole host (symmetric; prompt shows the host pattern); Chrome treats host:port as narrower. Documented in docs/chrome-runtime-patching.md.
Validation: ExtensionPolyfillTests + ExtensionPolyfillIntegrationTests + ExtensionPermissionTests 239 tests green on main. Runtime (isolated DetourVerify75, two probe MV3 extensions, page on 127.0.0.1:8475): promise + callback forms answer true for the granted ported pattern and false for an ungranted one, native negative control throws 'not a valid pattern', rewrite logged once per worker realm, wrapper survives 60 s + GC churn, getAll unaffected. Tip: launch with --args -ExtensionConsoleLogPublic YES to read bridged console text in the unified log.
OWED (user): AC #3 — signed build, 1Password inline menu on the TASK-4 fixture page served on a non-default port.
<!-- SECTION:NOTES:END -->
