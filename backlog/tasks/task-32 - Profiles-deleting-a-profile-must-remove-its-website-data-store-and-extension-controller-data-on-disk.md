---
id: TASK-32
title: >-
  Profiles: deleting a profile must remove its website data store and extension
  controller data on disk
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-13 01:41'
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
- [ ] #1 Deleting a profile removes its WKWebsiteDataStore for the profile identifier from disk (verified by WKWebsiteDataStore.allDataStoreIdentifiers no longer listing it, or equivalent), after releasing every web view and the extension controller that used it
- [ ] #2 If removal fails because the store is still in use or the app quits first, the removal is retried on the next launch before any profile loads, and never touches a profile that still exists
- [ ] #3 Extension storage for the deleted profile's controller is removed too, or the plan doc / task notes record the measured reason it cannot be
- [ ] #4 Tests cover the delete-then-remove ordering, the pending-removal retry, and that other profiles' data stores are untouched
<!-- AC:END -->
