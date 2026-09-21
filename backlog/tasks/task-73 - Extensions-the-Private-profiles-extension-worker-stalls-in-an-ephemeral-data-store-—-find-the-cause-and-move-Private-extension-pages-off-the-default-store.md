---
id: TASK-73
title: >-
  Extensions: the Private profile's extension worker stalls in an ephemeral data
  store — find the cause and move Private extension pages off the default store
status: In Progress
assignee:
  - '@claude'
created_date: '2026-09-14 06:38'
updated_date: '2026-09-21 00:20'
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
- [x] #1 The stall's cause is identified and recorded in the task and in docs/1password-integration-plan.md, with the worker console evidence
- [ ] #2 With the incognito controller's webViewConfiguration.websiteDataStore set to the profile's non-persistent store, 1Password's worker in the Private profile answers keep-alive pings for at least 5 minutes with no SWServerRegistration::clear / re-register cycle (signed build)
- [ ] #3 Nothing under ~/Library/WebKit/com.detourbrowser.mac/WebsiteData/Default gains an origin for a Private-profile extension base URL after a Private session (grep the origin files), and the persistent profiles are unaffected (ExtensionOriginTrackingPreventionTests stay green)
- [x] #4 A test loads a probe worker extension in an incognito profile and asserts its background answers a message after 60 s and that its web view configuration uses the profile's non-persistent store
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Hypothesis (2026-09-20, from WebKit source): the stall is WebKit's private-data gate, not IndexedDB/_renameOrigin/relay. WebExtensionContext::processes() — the set every event/port message is dispatched to — skips any frame whose page session isEphemeral() unless the context hasAccessToPrivateData (old revision fc3f603: unconditional skip; main adds an exception only for the controller's defaultWebsiteDataStore). With the background page on the ephemeral store and no private access (the Sep 13 experiment), no event ever reached the worker: keep-alive ping #1 (a native-port message) was never delivered, so no reply, no port activity, WebKit unloaded it. websiteDataStore(sessionID) likewise returns nullptr for a non-persistent store without private access. TASK-74 (f39e63f) now sets hasAccessToPrivateData on every context loaded into Private.
1. Drop the isIncognito guard in Profile.extensionController (webViewConfiguration.websiteDataStore = dataStore for incognito too; deleted profiles still excluded); keep the ITP keeper skipping incognito.
2. Test (AC4): probe worker extension in an incognito profile answers a message after 60 s (TEST_RUNNER_-gated long leg) and its web view configuration uses the profile's non-persistent store; negative control: without hasAccessToPrivateData the ephemeral worker gets no events (pins the cause).
3. Runtime harness: probe extension with a native-port keep-alive in Private, 5 min, no SWServerRegistration::clear cycle; grep WebsiteData/Default for the Private base URL origin (AC3).
4. Docs + task notes (AC1). AC2 with real 1Password in the signed build is the user's check.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-09-20: cause CONFIRMED and fixed (see commit 'run the Private profile's extension pages in its ephemeral store'). ExtensionPrivateStoreTests control pair: identical hand-loaded probe in the incognito profile's ephemeral store, hasAccessToPrivateData=false -> sendMessage comes back empty with no lastError for 20 s (WebKit's 'could not reach the worker'); true -> answered. 90 s env-gated leg (TEST_RUNNER_DETOUR_MEASURE_PRIVATE_WORKER=1): worker idle-unloaded and woke on message with chrome.storage.local intact inside the ephemeral store. ITP keeper needed no change (decides by store.isPersistent).
Validation: 77 tests green on main (ExtensionPrivateStoreTests, ExtensionOriginTrackingPreventionTests, ExtensionPrivateDefaultTests, NewProfileExtensionLoadTests, ExtensionPolyfillProfileWiringTests). Runtime, Debug build, isolated DetourVerify73, probe MV3 extension allowed in Private: controller + context webViewConfiguration store === profile.dataStore, non-persistent, hasAccessToPrivateData=true; 5 min 40 s of 20 s pings in a Private window 17/17 answered by one worker instance, 0 SWServerRegistration::clear, 0 terminateWorker, only the initial runRegisterJob per profile; normal window unaffected; byte scan (UTF-8 + UTF-16LE) of all of ~/Library/WebKit/com.detourbrowser.mac finds no Private marker/base-URL host during or after the run (Default profile's markers found = positive control), WebsiteData/Default listing unchanged; relaunch: Private markers gone, Default's readable; allow OFF unloads cleanly.
Observed, by design today: the Private profile, its ephemeral store and loaded contexts live until quit, so extension state survives closing the Private window (never reaches disk). Data written to WebsiteData/Default by Private extension pages in earlier builds is not cleaned up. Settings note/tooltip 'keep their data outside the private session' is now stale — left until the signed-build check.
OWED (user, signed build + real 1Password): AC #2 keep-alive >= 5 min with no clear/re-register cycle; AC #3 re-check on the production data dir.
<!-- SECTION:NOTES:END -->
