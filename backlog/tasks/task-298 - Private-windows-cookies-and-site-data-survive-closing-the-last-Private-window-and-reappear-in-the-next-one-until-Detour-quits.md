---
id: TASK-298
title: >-
  Private windows: cookies and site data survive closing the last Private window
  and reappear in the next one, until Detour quits
status: Done
assignee:
  - '@claude'
created_date: '2026-11-08T08:40:00Z'
updated_date: '2026-11-08T21:26:00Z'
labels:
  - private
  - privacy
  - bug
dependencies: []
references:
  - TASK-238
  - TASK-292.7
priority: high
type: bug
ordinal: 359000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by both website agents' runtime checks (TASK-292.5, TASK-292.7) on v0.4.0, Nov 8 2026: in a Private window, set a cookie and localStorage on a page; close every Private window; open a new Private window on the same page: document.cookie and localStorage still hold the values. They go away only when Detour quits. Chrome and Safari drop private data when the last private window closes, which is what users expect from "Private".

Cause: the built-in Private profile's `dataStore` is a lazy `.nonPersistent()` created once per process (Detour/Browser/Profile.swift ~168), and the profile object is reused for every Private session (its id is a constant). `TabStore.endPrivateSessionIfUnused()` (~2589) ends a session when nothing uses it (last Private window's space removed, last Private Quick Detour closed or switched profile) but discards only the session's site settings and the Private profile's extension notifications (TASK-238), never the website data. Quarantine is unaffected: each Quarantine window has its own fresh store (Quarantine.swift).

What makes the fix more than swapping the store: extensions allowed in Private keep their contexts loaded between sessions on the Private profile's store (see the TASK-238 comments and the extension-data-store notes: WebKit never copies defaultWebsiteDataStore into extension web views; the incognito worker was cycled on the ephemeral store), Private downloads, the Private profile's per-session state, and anything else that captured the old store (web view configurations, the extension controller's defaultWebsiteDataStore).

The website's Private Browsing page (detour-website src/content/features/private-browsing.md) and the home grid line currently describe the bug's behavior ("logins and cookies last until you quit Detour"); they change with the fix.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 After the last Private window and the last Private Quick Detour close, a new Private window starts with no cookies, localStorage, IndexedDB, cache or service workers from the previous Private session
- [x] #2 While a Private session is live, its Private windows still share one store (sign in once, signed in across them)
- [x] #3 Extensions allowed in Private keep working in the next Private session, and nothing they stored in the previous session's website data survives into it
- [x] #4 Normal profiles and Quarantine windows are unaffected
- [x] #5 Tests cover the session boundary (data set in session 1 is absent in session 2; present across two windows of one session)
- [x] #6 Checked at runtime with /verify: cookie and localStorage gone after closing all Private windows, kept across two open Private windows
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
User decision (Nov 8 2026): reset extensions too (Chrome's incognito-split behavior), not sites only.
1. Profile.resetPrivateSession() (Private profile only), started by TabStore.endPrivateSessionIfUnused() after its existing cleanup; chained so a second reset waits for one in flight; the Task is exposed for tests.
2. The reset: unload every loaded Private extension context through unloadExtension (ports, offscreen document, notifications, error observers), clear each one's extension storage in the non-persistent controller (fetchDataRecord + removeData, all extension data types), wipe the Private dataStore (all website data types, distantPast: cookies, local/session storage, IndexedDB, caches, service workers, for sites and extension origins alike), and only then reload the contexts still allowed in Private via the background-recovery sequence (loadExtensionContext, didReloadExtensionContext, loadBackgroundContent).
3. A new session that starts during the reset fails safe: its fresh data may be wiped by the in-flight removal, never the old data shown.
4. Tests (new PrivateSessionResetTests): cookie and data records gone after the last Private window closes; kept while a second Private window is open; an allowed extension is reloaded on a new origin with empty chrome.storage after the reset.
5. Wiki (architecture/incognito.md, extensions/private-profile-extensions.md, log), /code-review --fix, /verify (cookie and localStorage in a real Private window across a close and reopen), affected suites (Private/QuickDetour/extension private tests). Website text changes ship with the release that contains the fix.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026: implemented. Profile.resetPrivateSession / performPrivateSessionReset, called from TabStore.endPrivateSessionIfUnused: unloads every Private extension context (unloadExtension), clears each one's extension storage (shared helper removeExtensionData, also used by unloadExtension(removeData:)), removes all website data types from the Private dataStore (distantPast), then reloads the contexts still allowed in Private (loadExtensionContext, retargetExtensionPages from the old origin, didReloadExtensionContext, loadBackgroundContent only with background content). Resets chain through privateSessionReset.

Tests: new PrivateSessionResetTests (6): cookie and every data record gone after the last Private window closes; kept while a second Private window is open; next session empty and keeps its own data; a normal profile never resets; an allowed extension reloads on a new origin with empty chrome.storage; one disallowed mid-reset stays unloaded. Removing the reset hook makes the two website-data tests fail. ExtensionNotificationOrderingTests.testThePrivateSessionEndingTakesItsNotifications continues from a page of the reloaded context (the old origin is gone by design). Suites run after the review fixes: 19 suites, 349 tests, 0 failures (Private/Quarantine/Quick Detour/downloads/site settings/notifications/extension private, enabled-state, rehost, profile data removal and deletion undo).

/code-review medium --fix (9 findings): applied page retargeting after reload, background-content gate, shared storage-removal helper, test cleanup. Accepted: a Private session started during the reset can lose its first milliseconds of data (fails safe, never shows old data); an extension re-allowed or updated during the reset could have its fresh context's website data wiped; no timeout on WebKit's data callbacks; every Private session end restarts Private workers and their native hosts (intended, Chrome incognito-split behavior).

/verify (Debug build of this change, isolated DETOUR_DATA_DIR DetourVerify298, temporary harness, patch kept at docs/harness/task298-harness.patch): on https://example.com in real Private windows, cookie and localStorage set in window 1 were visible in window 2 and after window 2 closed (session live); closing window 1 started the reset; a new Private window saw neither (" | none"). Same run with the reset hook removed (DetourVerify298b): the new window still saw "t298=one | one". Defaults keys and data dirs of both runs removed.

Open: criterion 7 (website Private Browsing page and home grid line) is to change with the release that ships this fix; until then they describe v0.4.0.

Website: updated Private Browsing (lede, description, FAQ, body, table, extensions: cleared when the last Private window or Private Quick Detour closes), the Quarantine comparison, Web Extensions' Allow in Private line and the home grid line on website branch next-release (3db4d97), held for the release

Nov 8 2026 (user): closed with the app change shipped on main (pushed 6edaf24); the website criterion moved to TASK-311, which ships branch next-release with the app release. (removed criterion: the website page update, written on next-release)

Nov 8 2026: the user ran the post-release check list on the released 0.4.1 (signed build) and reported no problems. Check: Private session reset with 1Password allowed in Private: works in the next Private session, normal windows still signed in.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Ending the Private session (the last Private window or Private Quick Detour closes) now clears the Private profile's website data and resets its extensions: every Private extension context is unloaded, its extension storage removed, all website data types removed from the Private data store, then allowed extensions reload on a fresh origin. Covered by PrivateSessionResetTests (6) and a /verify run in real Private windows on example.com (cookie + localStorage gone in the next session). Accepted risks from review: a Private session started mid-reset may lose its first milliseconds of data (fails safe); an extension re-allowed during the reset could have its fresh context's data wiped. Website update on next-release (3db4d97), shipped by TASK-311.
<!-- SECTION:FINAL_SUMMARY:END -->
