---
id: TASK-32
title: >-
  Profiles: deleting a profile must remove its website data store and extension
  controller data on disk
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 01:41'
updated_date: '2026-09-13 02:12'
labels:
  - profiles
  - storage
  - privacy
dependencies: []
priority: medium
ordinal: 32000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-31 work. Profile.dataStore is WKWebsiteDataStore(forIdentifier: profile.id), and the profile's WKWebExtensionController is configured with the same identifier, but TabStore.deleteProfile / AppDatabase.deleteProfile never remove the on-disk data: cookies, local storage, IndexedDB, caches, service worker registrations and extension storage of a deleted profile stay on disk indefinitely. That is a privacy problem (the user expects deleting a profile to delete its logins) and unbounded disk use. Use WKWebsiteDataStore.remove(forIdentifier:) (async; it fails while any web view or controller still uses the store), so the deletion must first tear down everything holding the store: unloadAllExtensions (already called), close/release any web views and the extension controller, drop the lazy dataStore/controller references, then remove. Handle and log failure (e.g. retry at next launch by recording pending data-store removals in the DB, and removing them before any profile loads). Investigate whether extension controller data for the identifier has its own removal path (WKWebExtensionController.Configuration(identifier:) storage) and whether remove(forIdentifier:) covers it; record the finding. The incognito profile (non-persistent store) is never deletable and needs nothing.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Deleting a profile removes its WKWebsiteDataStore for the profile identifier from disk (verified by WKWebsiteDataStore.allDataStoreIdentifiers no longer listing it, or equivalent), after releasing every web view and the extension controller that used it
- [x] #2 If removal fails because the store is still in use or the app quits first, the removal is retried on the next launch before any profile loads, and never touches a profile that still exists
- [x] #3 Extension storage for the deleted profile's controller is removed too, or the plan doc / task notes record the measured reason it cannot be
- [x] #4 Tests cover the delete-then-remove ordering, the pending-removal retry, and that other profiles' data stores are untouched
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Measure WebKit on this macOS in a throwaway test: remove(forIdentifier:) timing while in use / after release, allDataStoreIdentifiers, on-disk dirs under ~/Library/WebKit/<bundle id>/, and where WKWebExtensionController.Configuration(identifier:) keeps extension storage.
2. Migration v11: pendingProfileDataRemoval(profileID PK, requestedAt). AppDatabase.deleteProfile records the pending removal in the same transaction as the row deletes and reports whether it deleted.
3. New ProfileDataRemoval (Browser/): injectable remover (extension controller data + WKWebsiteDataStore.remove), retry with backoff on in-use errors, one guarded function that never removes the incognito profile or any profile live in memory or in the profile table; clears the pending row on success.
4. TabStore.deleteProfile: flush the session so no stale space row blocks the DB delete, tear down favourite backing tabs, unloadAllExtensions, delete rows (+ pending record), drop the Profile, then schedule removal on a later main-actor turn. Audit other holders (palette, handler back-reference, ports/hosts/relays, offscreen, popovers, cached configs).
5. Launch: AppDelegate retries pending removals right after AppDatabase opens, before any window, extension manager or restoreSession can create a profile store/controller; skipped in the XCTest host (shared bundle id with production).
6. Tests: fake-remover unit tests for ordering, failure keeps pending, launch retry, live/incognito/other profiles untouched; one real WebKit integration test through TabStore.deleteProfile.
7. Record measurements in notes; run the new tests, AppDatabaseTests, TabStoreTests.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Measured on macOS 26 (Darwin 25.6, Xcode 26.3 / MacOSX26.2 SDK), in the DetourTests host (not sandboxed, bundle id com.detourbrowser.mac, so the same WebKit directory as the production app):
- Identifier stores live at ~/Library/WebKit/com.detourbrowser.mac/WebsiteDataStore/<lowercase uuid>/ (Cookies, LocalStorage, IndexedDB, CacheStorage, NetworkCache, Origins, ResourceLoadStatistics...). The directory and an allDataStoreIdentifiers entry appear as soon as WKWebsiteDataStore(forIdentifier:) is created.
- remove(forIdentifier:) fails with 'Data store is in use' while any WKWebsiteDataStore object (or a WKWebViewConfiguration/controller configuration holding one) for the identifier is alive, and with 'Data store is in use (by network process)' right after the last web view that used it is released; retried 250 ms later it succeeded (both with and without the private _close). A store that never hosted a web view (only created, or only a cookie set) is removable immediately. An identifier with no store returns success.
- After a successful removal allDataStoreIdentifiers no longer lists the id and the WebsiteDataStore/<uuid> directory is gone.
- Extension controller storage lives elsewhere: ~/Library/WebKit/com.detourbrowser.mac/WebExtensions/<UPPERCASE UUID>/<extension uniqueIdentifier>/{LocalStorage.db, State.plist} plus a StaleExtensionOriginsCleared marker. remove(forIdentifier:) does NOT remove it. There is no identifier-level removal API, but a fresh WKWebExtensionController(Configuration(identifier:)) lists data records for extensions that are not loaded (as documented) and removeData(ofTypes:from:) deletes LocalStorage.db; State.plist and the directory stay. The throwaway controller does not create the directory for an identifier that has none. So the removal empties storage through the API and then deletes WebExtensions/<UUID> by path (WebKit layout, not API).
- The existing test suites have leaked about 4300 WebsiteDataStore and 2800 WebExtensions directories under that shared bundle directory (every test that creates a Profile store or Configuration(identifier: UUID())). Not cleaned here: nothing may enumerate-and-delete in that directory.

Implementation:
- Migration v11: pendingProfileDataRemoval(profileID TEXT PK, requestedAt DOUBLE). AppDatabase.deleteProfile now returns Bool and records the pending removal in the same transaction as the row deletes (never for the Private profile id).
- Detour/Browser/ProfileDataRemoval.swift: Remover (injectable: removeExtensionData, removeWebsiteDataStore; .webKit is the real one). remove(_:) is the only caller: before each WebKit call it re-checks the id is not the Private profile, not in TabStore.profiles, and not in the profile table (an unreadable table refuses); refused ids have their pending row dropped. In-use failures retry after 0.25/0.5/1/2/4/8 s; the extension step is not repeated once done; success clears the row; exhaustion leaves it for next launch.
- TabStore.deleteProfile order: guards; saveNow() (a space moved off the profile within the 1 s save debounce still references it in the DB and would make the row delete refuse); tear down live favourite backing tabs (they outlive a deleted space); unloadAllExtensions (offscreen documents, keep-alive ports, native hosts, relayed WebSockets, background content); delete rows + record pending; drop the Profile from profiles; removal Task on a later main-actor turn (logs if the Profile is still retained). Returns the Task.
- Retainer audit: ExtensionPolyfillHandler.profile weak, WKWebExtensionController.delegate weak, TabStoreObserver weak, relay cookie provider weak, ExtensionManager port/host/relay registries cleared per context by closeExtensionPorts, no cached WKWebViewConfigurations, CommandPaletteView.profile is strong but transient and only ever the active space's profile (which a space uses, so undeletable). The integration test checks the Profile deinits after delete with a loaded context and a live favourite.
- Launch hook: AppDelegate.applicationDidFinishLaunching, right after AppDatabase/HistoryDatabase open and before ContentBlockerManager/ExtensionManager.initialize, the window (ExtensionManager.windowDidBecomeKey touches every profile's extensionController) and restoreSession. Skipped when XCTest* env vars are present (test host shares the WebKit directory); TestEnvironmentSetup drops leftover pending rows (DB only).

Not changed / follow-ups: undoing Delete Space or Edit Space after the profile is deleted rebuilds a space whose profile is nil (Space.dataStore force-unwraps) - pre-existing, does not recreate a store. saveNow logs 'Failed to save favorites: FOREIGN KEY' for a profile whose live favourite has no host space (pre-existing).

Tests: ProfileDataRemovalTests 12 (fake remover: ordering and release, only that profile, guard refusals, stale-DB-space flush, failure stays pending + launch retry, extension step retry, launch retry refuses stored/in-memory/Private/lower-case ids and drops invalid rows, re-check before each call, test-host detection; real WebKit: cookie + localStorage via a live favourite + extension storage.local deleted through TabStore.deleteProfile, identifier unlisted, both directories gone, other profile's store untouched then removed). AppDatabaseTests +1. ProfileDataRemovalTests+AppDatabaseTests+TabStoreTests+NewProfileExtensionLoadTests: 65 tests, 0 failures.

Review follow-up (data-dir gate). Hazard: WebKit keys identifier stores and extension controller directories by bundle id (~/Library/WebKit/com.detourbrowser.mac/), shared by every DETOUR_DATA_DIR, but the removal guard can only read the current data dir's profile table. A run on a copy of the production data (e.g. DetourVerify) that deletes a profile would pass the guard and wipe the production profile's cookies and extension storage.
Gate: ProfileDataRemoval.Remover.forCurrentDataDirectory(environment:) is the one decision point and TabStore.init's default. It returns .webKit only when DETOUR_DATA_DIR is unset or "Detour" (detourDataDirectoryName(environment:) now shared with detourDataDirectory()); otherwise a remover with skippedDataDirectory set whose closures do nothing, logging once per name at notice level. remove() checks it first and returns the new Outcome .skippedIsolatedDataDirectory, clearing the pending row (that data dir can never remove it, so it is not retried every launch); the profile rows are still deleted. The XCTest launch-retry skip stays as defence in depth. The real WebKit integration test passes .webKit explicitly and still only touches identifiers it creates.
Verify skill: .claude/skills/verify/SKILL.md (untracked, main checkout) should say that deleting a profile under an isolated DETOUR_DATA_DIR does not remove on-disk WebKit data, so on-disk removal can only be verified in the default data dir; not edited here.
Tests +4 in ProfileDataRemovalTests: default remover selection for unset / Detour / DetourVerify / DetourTests via injected env; skipped delete + launch retry with a fake remover (no calls, rows cleared); forCurrentDataDirectory's isolated remover through a TabStore; TabStore's default in the test host skips (XCTSkip if the host ever runs in the default dir). ProfileDataRemovalTests + AppDatabaseTests: 39 tests, 0 failures.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Deleting a profile now removes its on-disk WebKit data. TabStore.deleteProfile flushes the session, tears down live favourite backing tabs and every extension context, deletes the rows (AppDatabase.deleteProfile, which records a pending removal in the same transaction via new migration v11 table pendingProfileDataRemoval), drops the Profile, and then ProfileDataRemoval empties the extension controller storage through a throwaway WKWebExtensionController for the identifier, deletes the leftover WebExtensions/<UUID> directory, and calls WKWebsiteDataStore.remove(forIdentifier:), retrying in-use failures with backoff. One guarded function makes every WebKit call and refuses the Private profile and any profile present in memory or in the profile table. Pending rows are cleared on success and retried at launch from AppDelegate before any profile store or controller exists (skipped in the XCTest host, which shares the production WebKit directory). Measured: removal succeeds ~250 ms after the last web view is released, allDataStoreIdentifiers drops the id and WebsiteDataStore/<uuid> is deleted, but extension storage (WebExtensions/<UUID>) is not covered by remove(forIdentifier:). 12 ProfileDataRemovalTests (11 fake-remover, 1 real WebKit integration) and 1 AppDatabaseTests case added.
<!-- SECTION:FINAL_SUMMARY:END -->
