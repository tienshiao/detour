---
id: TASK-70
title: >-
  Extensions: WebKit tracking prevention deletes an extension origin's
  script-written storage (service-worker registration, IndexedDB, localStorage)
  on every ITP pass
status: To Do
assignee: []
created_date: '2026-09-14 03:57'
updated_date: '2026-09-14 04:07'
labels:
  - extensions
  - webkit
  - 1password
  - bug
dependencies: []
references:
  - Detour/Browser/Profile.swift
  - Detour/Extensions/Runtime/ExtensionManager.swift
documentation:
  - docs/1password-integration-plan.md
priority: high
ordinal: 70000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-09-13 while closing TASK-68 (production runs at 18:15 and 20:04, signed build, macOS 26.6.2). In both runs the Networking process logged, about one second after 1Password's worker activated, 'NetworkProcess::deleteAndRestrictWebsiteDataForRegistrableDomains started to delete and restrict data for session 1 with candidate domains - 9 domainsToDeleteAllCookiesFor, 0 domainsToDeleteAllButHttpOnlyCookiesFor, 706 domainsToDeleteAllScriptWrittenStorageFor' immediately followed by 'SWServerRegistration::clear' of 1Password's registration and 'SWContextManager::terminateWorker' — the worker dies under its still-loaded hidden background page (the TASK-68 symptom; its recovery in commit 03fe845 restarts the background about a minute later, but the data is gone). Service-worker registrations are script-written storage, and so are IndexedDB and localStorage: 1Password's '[Cache] The item cache has not been initialized yet' at every start in that profile fits its item cache being wiped. Only session 1 (the first profile loaded, Personal) was in the list so far; the other profiles' lists (52/625 domains for session 2) did not yet include the extension origin, which suggests the origin ages into the list, so every profile is expected to follow. ITP runs this pass at launch and then periodically (about hourly), so the kill repeats. Why the extension origin qualifies: extension pages are webkit-extension://<uuid> and the base URL is stable per profile (Profile.swift logs it at context load); ITP's user-interaction logging in WebCore's ResourceLoadObserver only records HTTP(S) documents (confirm), so clicks in the popup never count as first-party interaction, while the origin still enters the statistics table when its frames/resources load under sites, so after ITP's no-interaction window its script-written storage is purged. Candidate fixes: (1) at every extension context load, and daily while loaded, call the private -[WKWebsiteDataStore _logUserInteraction:completionHandler:] with the context's baseURL on the profile's data store (verified 2026-09-13 that WKWebsiteDataStore responds to it on macOS 26.6.2; Detour already uses a private selector for the Web Inspector) so the origin stays inside the interaction window and is never eligible; (2) check WebKit's source for an exemption of extension schemes or a sanctioned hook and prefer it if one exists; (3) do NOT disable tracking prevention for the profile. Verify in the signed build by watching the Networking 'deleteAndRestrictWebsiteDataForRegistrableDomains' lines and confirming no 'SWServerRegistration::clear' follows for the extension across two passes (launch and the next hourly pass).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 After the fix, the ITP pass at launch and the next periodic pass no longer clear a loaded extension's service-worker registration in any profile (Networking log: deleteAndRestrictWebsiteDataForRegistrableDomains with no SWServerRegistration::clear for the extension, and no Detour 'no reply' keep-alive error), verified in the signed build
- [ ] #2 An extension's IndexedDB and localStorage survive an ITP pass and a relaunch (probe extension in a test, and 1Password's item cache warm on restart in production)
- [ ] #3 A test drives an ITP pass against a profile data store with a loaded probe extension (WebKit's testing hooks for advancing ITP time / processing statistics) and asserts the registration and storage survive; a negative control shows an ordinary no-interaction origin is still purged
- [ ] #4 docs/1password-integration-plan.md records the mechanism and the fix; the TASK-68 recovery stays as the safety net
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Observation 2026-09-13 20:04-21:07 (production Networking pid 69959): only ONE tracking-prevention pass hit session 1, at launch (20:04:22.578, 9 cookie domains / 706 script-written-storage domains, followed by SWServerRegistration::clear 31); session 2's pass at 20:04:26.967 (52 / 625 domains) cleared nothing. No further pass in the next 63 minutes and the recovered workers kept answering every ping, so the purge is a launch-time event (plus whatever later reprocessing ITP schedules), not hourly as first assumed. Two 'deleteWebsiteDataForOrigins ... session 1' at 20:04:21.185/.222 precede it and are separate (origin-scoped removals at extension load; check Profile.swift:493).
<!-- SECTION:NOTES:END -->
