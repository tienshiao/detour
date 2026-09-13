---
id: TASK-36
title: >-
  Tests: stop the test host writing WebKit data into the production app's WebKit
  directory
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 03:21'
updated_date: '2026-09-13 04:16'
labels:
  - tests
  - storage
  - profiles
dependencies: []
priority: medium
ordinal: 36000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-32 work. The DetourTests host is Detour.app with bundle id com.detourbrowser.mac, so every WKWebsiteDataStore(forIdentifier:) and persistent WKWebExtensionController a test creates lands in ~/Library/WebKit/com.detourbrowser.mac/ — the same directory the production app in /Applications uses. DETOUR_DATA_DIR isolates only Detour's own databases. On 2026-09-12 this had accumulated 4,976 WebsiteDataStore and 3,408 WebExtensions directories (about 3.2 GB) from test runs and isolated verify runs; they were moved to the Trash by hand, keeping only the production profiles' directories. It also forces TASK-32's on-disk removal to be disabled outside the default data dir, because an isolated run cannot tell its identifiers from production ones. Fix the root cause: give the test host (and ideally isolated DETOUR_DATA_DIR runs) a WebKit directory of their own. Options to evaluate: a Debug/test bundle identifier (check the impact on Sparkle, keychain, the 1Password BrowserSupport trust work in TASK-6/TASK-7, and native messaging host manifests), a separate test-host app target, or having Profile use non-persistent stores and controllers when running under XCTest (check which tests genuinely need persistence, e.g. TASK-32's integration test). Tests that do create persistent identifier stores must remove them in tearDown.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A full DetourTests run leaves no new directories under ~/Library/WebKit/com.detourbrowser.mac/ (verified by counting before and after)
- [x] #2 Tests that need a persistent identifier store or extension controller still work and clean up what they create
- [x] #3 The chosen approach and its effect on Debug app runs (bundle id, Sparkle, keychain, native messaging, 1Password trust) are recorded in the task notes; if isolated DETOUR_DATA_DIR app runs also get their own WebKit directory, TASK-32's isolated-data-dir removal gate is revisited
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Audit shared persistent locations (WebKit identifier stores, extension controller dirs, ContentRuleLists, cookies, URLCache, UserDefaults, keychain). No baseline full run on the old code: it would create unrecorded random-id dirs in the production WebKit dir that could only be removed by enumerate-and-delete.
2. Keep the bundle id. WebKitStorageScope.identifier(profileID:dataDirectoryName:) returns the profile id in the default data dir and a UUIDv5 (fixed Detour namespace, data dir name, profile id) elsewhere. Profile.dataStore, Profile.extensionController and ProfileDataRemoval use it.
3. Migration v12 adds the webKitStorageIdentifier table to the data dir's browser.db. A non-default data dir records each identifier before WebKit creates the storage.
4. WebKitStorageScope.removeRecordedStorage removes recorded identifiers after refusalToRemove passes: non-default dir, recorded here, v5 and derived from the recorded profile id and this dir's name, not a production profile id (production browser.db read from a lock-free copy; skipped when unreadable). The store goes first as the in-use probe, then the extension controller data. TestEnvironmentSetup runs it at bundle start (live TabStore.shared profiles excluded) and at bundle end (after unloading extensions, clearing undo actions, resetting the store and swapping the kept profiles' store/controller for non-persistent ones).
5. TASK-32 gate: lifted for recorded derived identifiers; unrecorded ones are skipped with the pending row cleared. The default data dir's behaviour is unchanged.
6. The integration tests that built Configuration(identifier: UUID()) switch to recorded identifiers with a matching store.
7. Fix what keeps storage in use at bundle end (found by measuring): TabStore's restored dormant favourites captured their profile strongly (a retain cycle).
8. ContentRuleListStore: non-default data dirs use WKContentRuleListStore(url:) under the data dir, plus their own filter list cache and ContentBlocker defaults suite. ContentBlockerTests remove what they compile. Other UserDefaults keys are noted for review.
9. Unit tests, then two full DetourTests runs with before/after directory counts.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Audit (2026-09-12, before code changes; no full run on the old code, since it would create unrecorded random-id dirs in the production WebKit dir that could only be removed by enumerate-and-delete)

Counts in ~/Library/WebKit/com.detourbrowser.mac/ at start: WebsiteDataStore 2, WebExtensions 2 (Personal B0E91083, Work CA8C2B61), ContentRuleLists 7.

- WebsiteDataStore/ and WebExtensions/: every Profile in the test host (TabStore.shared default profile, TabStore.shared.addProfile, Profile(name:), TabStore(appDB:) stores) creates WKWebsiteDataStore(forIdentifier: profile.id) and WKWebExtensionController.Configuration(identifier: profile.id) lazily; WKExtensionIntegrationTests and ExtensionPolyfillIntegrationTests also built Configuration(identifier: UUID()) directly. All random ids in the production dir, never removed: the source of the 4,976 + 3,408 dirs. Isolated app runs (DetourVerify) did the same.
- ContentRuleLists/: ContentRuleStore used WKContentRuleListStore.default(), the production store. In the test host ContentBlockerManager.initialize looks up the production lists, recompiles into them when the shared lastFetch is over 24 h old, and compiles whitelist lists for test profile ids. ContentBlockerTests compiled test-* (removed) and fallback-* (never removed) lists there: ContentRuleList-fallback-easylist-cookie (16 MB, Sep 12 19:14) in the production dir is a leftover of that. Not removed by this work (not created by it); safe for the user to delete by hand.
- Filter list text cache: ContentBlockerManager hard-coded Application Support/Detour/ContentBlocker, ignoring DETOUR_DATA_DIR, so test/isolated runs downloaded into production's cache.
- WebKit default store (WebsiteData/, Caches/com.detourbrowser.mac/WebKit): tests using WKWebViewConfiguration() without a store (e.g. ProfileDataRemovalTests' favourite tabs) write WebKit's default persistent store. Production never browses in it (profiles use identifier stores). One fixed directory, no growth. Not changed.
- HTTP cookies / URLCache: URLSession.shared (FaviconLoader, FaviconSchemeHandler, SearchSuggestionsService, ContentBlockerManager fetch, the navigation HEAD probe) uses ~/Library/HTTPStorages/com.detourbrowser.mac and ~/Library/Caches/com.detourbrowser.mac/Cache.db, shared with production. Fixed-size, no growth, no credentials. Not changed.
- UserDefaults: the test host and isolated runs write the com.detourbrowser.mac domain: NSWindow Frame BrowserWindow (frame autosave), NSSplitView Subview Frames BrowserSplitView, Sparkle SU* keys (SPUStandardUpdaterController starts its updater in the test host and isolated runs too, so it may also run scheduled update checks), and ContentBlocker.<list>.{etag,lastFetch,ruleCount,compiledRuleCount}. The ContentBlocker keys describe the rule list store, so they move with it (below). Window frame, split view autosave and Sparkle are left for review: fixing them means changing autosave names or not starting Sparkle in non-default data dirs.
- Keychain: Detour has no SecItem usage. Sparkle's EdDSA check uses none. WebKit may keep HTTP auth/passkey credentials under the bundle id; no test exercises that. Keychain items, native messaging host manifests and the 1Password BrowserSupport trust (TASK-6/TASK-7) are keyed by bundle id, which is why the bundle id stays.

Design chosen (and why)
- Bundle id unchanged: Sparkle, keychain items, native messaging host manifests and the 1Password BrowserSupport trust (TASK-6/TASK-7) are keyed by it. Debug app runs in the default data dir behave exactly as before (same bundle id, same stores, same Sparkle/keychain/NM/1Password). A separate test-host target was not needed. Non-persistent stores under XCTest were rejected: persistence tests (TASK-32's integration test, storage.local, relaunch tests) need real stores, and isolated app runs (DetourVerify) would not be covered.
- WebKitStorageScope (Detour/Browser/WebKitStorageScope.swift) is the one place that names the storage. In the default data dir the identifier is the profile id, so production is untouched (tested with the Personal/Work ids). In any other dir it is a UUIDv5 over namespace 9DC6C971-6D72-44C8-9541-D6DEBE44E0A3 + "<data dir>/<profile id>". It is stable per data dir and can never equal a v4 production id. Isolated data dirs such as DetourVerify now get fresh stores (their old raw-id stores are no longer used).
- Records: migration v12, table webKitStorageIdentifier(identifier PK, profileID, createdAt) in the data dir's browser.db, written before WebKit creates the storage. It can't be derived from the profile table: tests create profiles outside it and the reset drops rows.
- Removal guard (refusalToRemove): non-default dir, recorded in this dir, version 5 and re-derivable from the recorded profile id and this dir's name, and not equal to any profile id in ~/Library/Application Support/Detour/browser.db. That DB is read from a byte copy taken while no -journal exists and size/mtime are stable, then opened read-only. The production app uses a rollback journal with immediate busy errors, so a shared lock from us could fail its writes. Unreadable means nothing is removed; a missing DB means no production profiles.
- TASK-32 gate (AC #3): lifted for recorded derived identifiers only. ProfileDataRemoval in an isolated dir removes a deleted profile's storage under its derived id when this dir recorded it (outcome .removed, record forgotten). An unrecorded profile gets .skippedUnrecordedStorage and the pending row is cleared. An unreadable production DB gives .failed and the row stays pending. Remover.forCurrentDataDirectory and .skippedIsolatedDataDirectory are gone; TabStore defaults to .webKit plus WebKitStorageScope.current. AppDelegate still skips the launch retry in the XCTest host as a second defence.
- ContentBlockerStorage: the default dir keeps WKContentRuleListStore.default(), UserDefaults.standard and Detour/ContentBlocker. Other dirs get <data dir>/ContentRuleLists via WKContentRuleListStore(url:), <data dir>/ContentBlocker, and the defaults suite com.detourbrowser.mac.<data dir> for the ContentBlocker.* keys. The first run in a new data dir downloads and compiles the four lists into the data dir (about 20 s in the background of the test host).

Measured while building it
- The first full run with only the derived ids and cleanup: 865 tests, 0 failures. The end cleanup removed 153 of 157 recorded ids; 4 were still in use ('in use (by network process)'), leaving WebsiteDataStore 6 / WebExtensions 3. A focused run's start cleanup then removed those 4 in 0.1 s, which proves start-of-run cleanup on real leftovers.
- Longer retries (about 32 s) and removeData(allWebsiteDataTypes) between attempts changed nothing, so neither was kept. A probe showed a released store is removable after 0.27 s, including overlapping and sequential store objects and two Profiles with one id. So the leftovers were real leaks. Weak-reference probes found two causes:
  1. TabStore.shared.undoManager actions capture spaces, and so profiles (ExtensionPolyfillProfileWiringTests search/sessions tests). The bundle end now clears them.
  2. A real app retain cycle: TabStore.restoreSession set favorite.onFaviconDownloaded capturing its profile strongly while profile.favorites held the favourite. Every restored profile with a dormant favourite leaked, and with it the store and controller. In production that means a deleted profile with favourites keeps its store in use, so TASK-32's removal fails and is only retried at the next launch. Fixed with [weak profile]. The new ProfileDataRemovalTests.testARestoredProfileWithADormantFavoriteIsReleased fails without the fix and passes with it.
- One remaining quirk: WebKit said 'in use (by network process)' even while UI objects still held the store, so that message does not prove the UI side is clean.

Verification (final code)
- Full run 1: before WebsiteDataStore 2 / WebExtensions 2 / ContentRuleLists 7, after 2 / 2 / 7. 866 tests, 0 failures, 0 skipped. Cleanup: start 0 recorded; end 157 recorded, 157 removed, 0 kept, 1.4 s.
- Full run 2: before 2 / 2 / 7, after 2 / 2 / 7. 866 tests, 0 failures, 0 skipped. Cleanup: start 0 recorded (run 1 left nothing); end 157 recorded, 157 removed, 0 kept, 1.3 s.
- The remaining production entries are exactly Personal/Work (both dirs), and ContentRuleLists mtimes are unchanged. The test data dir holds its own 4 compiled lists.
- Both runs used TEST_RUNNER_DETOUR_DATA_DIR=DetourTests-task36, with the log printing 'Test data directory: ~/Library/Application Support/DetourTests-task36/'.

Left for review (not changed)
- ContentRuleList-fallback-easylist-cookie (16 MB, Sep 12 19:14) in the production ContentRuleLists dir is an old ContentBlockerTests leftover. This work did not create it, so it was not removed; it is safe to delete by hand.
- The test host and isolated runs still write the com.detourbrowser.mac defaults domain: NSWindow Frame BrowserWindow, NSSplitView Subview Frames BrowserSplitView, and Sparkle SU* keys. SPUStandardUpdaterController also starts its updater in those processes. They also share the URLSession.shared cookie storage and URLCache (HTTPStorages/, Caches/com.detourbrowser.mac), and WebKit's default store (WebsiteData/) for tests using a bare WKWebViewConfiguration. None of these grow, and none is a correctness issue for production data beyond the window frame/split positions.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The test host and isolated DETOUR_DATA_DIR runs no longer leave WebKit data in the production app's ~/Library/WebKit/com.detourbrowser.mac/. The bundle id is unchanged.

Commits:
- 1d3b35f: WebKitStorageScope derives the WebKit identifier per data dir. It is the profile id in the default dir (production untouched) and a UUIDv5 of namespace + data dir + profile id elsewhere. Profile's store and controller and ProfileDataRemoval use it. Isolated dirs record identifiers (migration v12) and remove only recorded, re-derivable ids that are not production profile ids (production DB read from a lock-free copy). TestEnvironmentSetup cleans at bundle start and end. TASK-32's gate is lifted for recorded derived ids. Also fixes an app retain cycle (a restored dormant favourite's favicon callback held its profile) that kept deleted profiles' stores in use.
- d338518: the content blocker gets its own rule list store, filter cache and defaults suite per non-default data dir.

Verified: two full DetourTests runs, 866 tests and 0 failures each. The end cleanup removed 157/157 recorded ids. WebsiteDataStore/WebExtensions/ContentRuleLists counts were 2/2/7 before and after both runs. Window frame, split view and Sparkle defaults, URLSession cookies/cache, WebKit's default store, and a stale production fallback-easylist-cookie list are noted for review.
<!-- SECTION:FINAL_SUMMARY:END -->
