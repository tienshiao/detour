---
id: TASK-73
title: >-
  Extensions: the Private profile's extension worker stalls in an ephemeral data
  store — find the cause and move Private extension pages off the default store
status: To Do
assignee: []
created_date: '2026-09-14 06:38'
updated_date: '2026-09-14 06:38'
labels:
  - extensions
  - webkit
  - privacy
  - 1password
dependencies: []
priority: high
ordinal: 73000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-09-13 (TASK-70): the shipped WebKit's WebExtensionControllerConfiguration::webViewConfiguration() never copies defaultWebsiteDataStore into the configuration extension web views are built from, so extension pages ran in WebKit's default data store. Profile now sets config.webViewConfiguration.websiteDataStore = dataStore for PERSISTENT profiles only. When the same was done for the Private (incognito) profile with its .nonPersistent() store, 1Password's worker never answered keep-alive ping #1 and WebKit unloaded it (SWServerRegistration::clear + SWServer::removeContextConnection ~40 s after start) and re-registered it (runRegisterJob 'No existing registration') every 60 s, forever (signed build 23:11, three cycles observed). So Private still uses the default store, which is persistent and on disk: anything the extension worker/popup stores while a Private window is used (1Password's IndexedDB item cache, localStorage, cookies on the extension pages' own requests) survives the window and the app, and the keeper skips incognito so session 1's launch pass also kills the worker once per launch (TASK-68 recovery restarts it ~90 s later). Investigate in the debug harness with an isolated data dir and ExtensionConsoleLogPublic set: apply the explicit ephemeral store to the incognito controller (drop the isIncognito guard in Profile's extensionController setup), start 1Password in the Private profile, and read the worker's console to see where it stalls before the keep-alive reply. Suspects, in order: IndexedDB/Cache Storage behaviour in a non-persistent session; WebKit's LastSeenBaseURL storage migration (_renameOrigin) with nothing to move in an ephemeral store; the WebSocket relay / native messaging port setup in that session. Then fix the cause, apply the explicit store to incognito, and keep the ITP keeper skipping it (an ephemeral session has no ITP database to purge from). Related: TASK-70 notes and docs/1password-integration-plan.md 'Tracking prevention purges the extension origin'. Until this lands, TASK-74's Chrome-style default (no extensions in Private unless the user opts in) closes the leak.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The stall's cause is identified and recorded in the task and in docs/1password-integration-plan.md, with the worker console evidence
- [ ] #2 With the incognito controller's webViewConfiguration.websiteDataStore set to the profile's non-persistent store, 1Password's worker in the Private profile answers keep-alive pings for at least 5 minutes with no SWServerRegistration::clear / re-register cycle (signed build)
- [ ] #3 Nothing under ~/Library/WebKit/com.detourbrowser.mac/WebsiteData/Default gains an origin for a Private-profile extension base URL after a Private session (grep the origin files), and the persistent profiles are unaffected (ExtensionOriginTrackingPreventionTests stay green)
- [ ] #4 A test loads a probe worker extension in an incognito profile and asserts its background answers a message after 60 s and that its web view configuration uses the profile's non-persistent store
<!-- AC:END -->
