---
id: TASK-268
title: >-
  Extensions: clearing a grant the extension removed writes the full page URL to
  the system log as public
status: Done
assignee:
  - '@claude'
created_date: '2026-11-07T00:12:00Z'
updated_date: '2026-11-07T01:42:00Z'
labels:
  - extensions
  - privacy
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionManager.swift
priority: low
type: bug
ordinal: 315000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

`ExtensionManager.clearRemovedGrants` (ExtensionManager.swift ~2238) logs `\(key, privacy: .public)` for every revoked record. For `.url` records the key is the page's full `absoluteString` from the site-access prompt (path and query included, which can carry tokens), so browsing data lands in the unified log readable by anyone with `log show`. The codebase's rule elsewhere is that schemes are public and hosts are not (e.g. `logRejectedOrigin`).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 No log line in the permission-decision paths prints a .url or match-pattern key with public privacy
- [x] #2 The line still says which extension and which record type was cleared
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Audit the permission-decision paths (clearRemovedGrants, setPermissionDecision, applySavedDecisions, handlePermissionPrompt + autoGrantLogLabel, permissions.request approval, Profile.applySavedHostAccessDecisions, Profile.loadExtensionContext) for URL / match-pattern keys logged public.
2. Add ExtensionPermissionType.logName and a pure helper that gives the publicly loggable part of a key: API permission names whole, <all_urls> whole, otherwise only the scheme (as logRejectedOrigin).
3. clearRemovedGrants logs extension ID, record type and the public part publicly, the full key .private. Profile's two stale-decision debug lines get the same treatment.
4. Small unit test for the helper in ExtensionPermissionTests; build, run the suite.
5. Runtime: seed an extension with a stale URL/pattern row in an isolated profile and read the debug line with log show, if feasible.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Audit of the permission-decision paths: clearRemovedGrants logged the full key public (fixed). Profile.applySavedHostAccessDecisions had two more: the stale match-pattern and stale URL debug lines logged the key public (fixed). setPermissionDecision and applySavedDecisions log nothing; handlePermissionPrompt's activeTab line logs only autoGrantLogLabel ('URLs' / 'match patterns') and the extension id; the permissions.request approval and removeOutsideWebKitPermissions log API permission names only (kept public); loadExtensionContext logs the context's own webkit-extension:// base URL, not browsing data (kept).

Change: ExtensionPermissionType gains logName and publicLogPart(ofKey:) (API permission name and <all_urls> whole, otherwise the scheme before '://', '(no scheme)' if none), the rule logRejectedOrigin follows. The three lines print extension id, record type and that part public, the full key .private.

A pure helper made a seam, so it has a unit test (ExtensionPermissionTests.testPublicLogPartKeepsOnlyTheSchemeOfHostAccessKeys); the log calls themselves have no seam and are checked at runtime.

Tests: ExtensionPermissionTests + ExtensionPermissionRestoreTests, 102 tests, 0 failures. The restore suite's removal cases print the new line, e.g. 'removed its grant of URL https (https://www.site.example/page)'; private values are visible there because the xcodebuild test host runs in Xcode's development logging mode.

Runtime: isolated profile DetourVerify268 with a seeded hello-world (content script narrowed to https://allowed.example/*) plus stale rows https://secret.example/inbox?token=abc123 (URL) and https://secret-pattern.example/* (pattern); log stream --level debug showed 'Skipping stale pattern decision https (<private>) for hello-world-268' and 'Skipping stale URL grant https (<private>) for hello-world-268'. Not seen at runtime outside the test host: the clearRemovedGrants line itself (needs the extension to call permissions.remove); it uses the same interpolation.

Code review (/code-review --fix): publicLogPart took everything before the first '://' as the scheme, so a key like 'data:text/html,<a href=https://…>' leaked its body; it now ends the scheme at the first ':' and prints it only if it is '*' or a plain scheme token (ASCII letter, then letters, digits, + or -; '.' left out so 'host.example:8080/x' is not taken for one), else '(no scheme)'. Four test cases added. The stale URL line now says 'decision' (it skips denials too). Kept: an API permission's line prints its name public and again private (harmless). A scheme-less 'localhost:8080/x' key would print 'localhost'; WebKit's prompt URLs always carry a scheme, so not handled.
Rerun after the fix: ExtensionPermissionTests + ExtensionPermissionRestoreTests, 102 tests, 0 failures. The runtime log check was done before the review fix (same interpolation; the helper change is covered by the unit test).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Log lines about saved URL and match-pattern decisions no longer put browsing data in the unified log as public. ExtensionPermissionType gains logName and publicLogPart(ofKey:) (API permission names and <all_urls> whole, otherwise only the scheme, the logRejectedOrigin rule); clearRemovedGrants and Profile.applySavedHostAccessDecisions' two stale-row debug lines print extension id, record type and that part public and the full key .private. Other permission-decision paths audited: none logs a URL or pattern key. Unit test for the helper; ExtensionPermissionTests + ExtensionPermissionRestoreTests 102/0; runtime: seeded isolated profile showed 'Skipping stale … https (<private>)'. The clearRemovedGrants line itself was seen only in the test host (which reveals private values under xcodebuild).
<!-- SECTION:FINAL_SUMMARY:END -->
