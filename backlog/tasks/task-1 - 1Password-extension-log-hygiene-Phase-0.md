---
id: TASK-1
title: '1Password: extension log hygiene (Phase 0)'
status: To Do
assignee: []
created_date: '2026-09-11 22:28'
updated_date: '2026-09-11 22:47'
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
- [ ] #1 Error objects passed to console.log/warn/error in extension contexts reach the native log as name: message plus stack, not {}
- [ ] #2 The errorsDidUpdate observer logs only errors not previously logged for that context
- [ ] #3 No log statement in Detour/Extensions writes a native messaging payload, polyfill message body, or host stderr at a persisted level with public privacy
- [ ] #4 ExtensionPolyfillTests cover the Error serialization in the console bridge
- [ ] #5 With ExtensionConsoleLogPublic unset, extension console text renders as <private> in log show; with it set to YES, the text is visible and a notice line at launch warns that the bridge is public
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Console bridge gate added 2026-09-11: extension console text is logged privately by default; set the UserDefaults key ExtensionConsoleLogPublic (bool) on com.detourbrowser.mac before launch to log it publicly for one debugging session (see ExtensionPolyfillHandler.consoleLogIsPublic and the Phase 1 section of the plan). Purge the log store after such a session.
<!-- SECTION:NOTES:END -->
