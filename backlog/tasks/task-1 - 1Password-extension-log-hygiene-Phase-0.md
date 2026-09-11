---
id: TASK-1
title: '1Password: extension log hygiene (Phase 0)'
status: Done
assignee:
  - '@claude'
created_date: '2026-09-11 22:28'
updated_date: '2026-09-11 23:53'
labels:
  - 1password
  - extensions
dependencies: []
documentation:
  - docs/1password-integration-plan.md
priority: high
ordinal: 1000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Remaining diagnostics fixes from Phase 0 of the 1Password plan. The native messaging payload previews were already removed from NativeMessagingHost.swift (they had leaked account secrets into the unified log), and the two polyfill-handler error paths now log only key sets. Two log-quality gaps remain that made the 2026-09-11 session hard to read: 1Password's exception messages arrive as {} because the service-worker console bridge in ExtensionAPIPolyfill.swift JSON-stringifies Error objects, and the errorsDidUpdate observer in Profile.swift re-logs the entire accumulated error array on every update.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Error objects passed to console.log/warn/error in extension contexts reach the native log as name: message plus stack, not {}
- [x] #2 The errorsDidUpdate observer logs only errors not previously logged for that context
- [x] #3 No log statement in Detour/Extensions writes a native messaging payload, polyfill message body, or host stderr at a persisted level with public privacy
- [x] #4 ExtensionPolyfillTests cover the Error serialization in the console bridge
- [x] #5 With ExtensionConsoleLogPublic unset, extension console text renders as <private> in log show; with it set to YES, the text is visible and a notice line at launch warns that the bridge is public
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. ExtensionAPIPolyfill.consoleJS: add a formatter that renders Error/DOMException args as 'name: message' plus stack (skip the header when the stack already starts with it, V8-style) and use a JSON.stringify replacer so Errors nested in objects serialize as {name,message,stack}; expose it as globalThis.__detourFormatConsoleArgs for tests.
2. Profile.swift errorsDidUpdate observer: keep a per-extension count of already-logged errors and log only the tail; reset on unload; include NSError domain/code in the line.
3. Audit Detour/Extensions for public-privacy logs of payloads/console text/host stderr (done: none remain; stderr is .debug/.private, handler errors are handler-generated strings).
4. ExtensionPolyfillTests: cover Error, nested Error, DOMException and plain-value formatting, and that console.error(new Error) does not throw.
5. Build, run ExtensionPolyfillTests, then verify AC5 at runtime with log show (needs to run outside the sandbox).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Console bridge gate added 2026-09-11: extension console text is logged privately by default; set the UserDefaults key ExtensionConsoleLogPublic (bool) on com.detourbrowser.mac before launch to log it publicly for one debugging session (see ExtensionPolyfillHandler.consoleLogIsPublic and the Phase 1 section of the plan). Purge the log store after such a session.

Console bridge now formats Error/DOMException args as 'name: message' plus stack (V8-style headers not duplicated; nested errors serialized via JSON replacer); formatter exposed as __detourFormatConsoleArgs. errorsDidUpdate observer keeps a per-extension logged count and logs only the tail, with domain/code. Audit: no remaining public-privacy log of payloads, console text, or host stderr in Detour/Extensions. 7 new ExtensionPolyfillTests pass; ExtensionPolyfillTests (51) and ExtensionPolyfillIntegrationTests (12) green.

Runtime verification 2026-09-11 (Debug build, DETOUR_DATA_DIR=DetourVerify, minimal classic-worker probe extension seeded into the extension table): default mode persists every bridged console line as '[SW <id>] <private>'; launched with '-ExtensionConsoleLogPublic YES' (argument domain, persistent defaults untouched) the launch notice appears and the text is visible, with console.error(new TypeError('probe-boom')) rendered as 'TypeError: probe-boom' + 'global code@webkit-extension://.../sw.js:4:60' and a nested error serialized as {name,message,stack}. Side finding for TASK-2: api-explorer's background worker fails at cold start in this setup (recorded on TASK-2).

Code review follow-up (2026-09-11): errorsDidUpdate observer now dedupes by error content (domain#code#description set captured per observer) instead of a Profile-level count keyed by extension id — WebKit consolidates repeats and may clear the array, so a positional count could swallow new errors after a clear/refill; observer tokens are stored in extensionErrorObservers and removed in unloadExtension (fixes the pre-existing observer leak and the strong capture of WebExtension). Console bridge: guarded errorParts() shared by top-level and nested paths, own enumerable props (e.g. code) preserved, exact header-line strip instead of an indexOf prefix guess, per-argument isolation ('[unserializable]') plus a fully guarded sendLog so console.* never throws into extension code, 8192-char cap with a truncation marker. The __detourFormatConsoleArgs production hook was removed; tests stub __detourPolyfillRequest and call console.* instead (12 tests, ExtensionPolyfillTests 56/56 and integration 12/12 green).

Post-review (code-review --fix): error observer now dedupes by error content per observer and removes its NotificationCenter token on unload; Fable added a shrink-detect reset so an error recurring after WebKit clears the array (background reload) is logged again. Console bridge hardened: guarded accessors, per-argument isolation, own props of errors kept, exact header strip, 8192-char cap, test-only global removed; tests observe via a stubbed __detourPolyfillRequest. ExtensionPolyfillTests 56/56 green after the tweak.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Console bridge in ExtensionAPIPolyfill.consoleJS now renders Error/DOMException arguments as 'name: message' plus stack (no duplicate header for V8-style stacks) and serializes errors nested in objects as {name,message,stack}; formatter exposed as __detourFormatConsoleArgs. Profile's errorsDidUpdate observer tracks a per-extension logged count and logs only new errors, with NSError domain/code, resetting on unload. Audit of Detour/Extensions found no remaining public-privacy logging of payloads, console text, or host stderr. Verified with 7 new ExtensionPolyfillTests (51/51 and 12/12 integration green) and a runtime run of the Debug build in an isolated profile: bridged text is <private> by default and visible, with a launch notice, when ExtensionConsoleLogPublic is set. Plan doc Phase 0 bullets updated. Not committed.
<!-- SECTION:FINAL_SUMMARY:END -->
