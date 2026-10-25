---
id: TASK-195
title: 'Content blocking: keep a Private window''s per-site switch in memory only'
status: Done
assignee:
  - '@claude'
created_date: '2026-10-24 16:07'
updated_date: '2026-10-25 00:16'
labels:
  - content-blocker
  - privacy
  - site-settings
dependencies: []
priority: low
ordinal: 231000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up from TASK-188 (user decision 2026-10-24: a per-site switch set in a Private window lives in memory until the last Private window closes and is never written to disk). The picture in picture switch does this already (SiteSetting.persistsInPrivate = false). Content blocking still saves the Private profile's rows to browser.db (it always did, TASK-187 kept it), so a site visited in Private leaves its hostname on disk. Flip contentBlocking.persistsInPrivate, delete existing Private contentBlocking rows in a migration, and check the reload-on-toggle path still works in a Private window.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Turning content blocking off for a site in a Private window writes nothing to the database and lasts until the last Private window closes
- [x] #2 Existing Private contentBlocking rows are removed by a migration, with a test
- [x] #3 Non-Private profiles are unchanged
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Built (2026-10-24, Opus subagent): SiteSetting.persistsInPrivate is now false for every setting (kept as an exhaustive switch so a new setting must decide). Migration v19 deletes siteSetting rows with profileID = the Private id and setting = 'contentBlocking' (Private pictureInPicture and other profiles' rows stay). ContentBlockerManager: the per-navigation decision and the SPI call are one static configure(_:forNavigationTo:profileID:whitelist:) used by the instance method and by the real-WKWebView test (it used to copy the body).

Cache finding: nothing derived from the site list is cached. Since TASK-69 the per-site switch is not a compiled rule list: configure reads SiteSettingsStore on each main-frame navigation and sets _setContentBlockersEnabled:NO on that navigation's WKWebpagePreferences; compiled WKContentRuleLists are only the filter lists. Private web views are torn down in removeIncognitoSpace before discardPrivateSession() runs, so the existing direct call is the whole reset: no notification or rule-list rebuild needed.

TDD: red 9 failures in 5 tests across 4 suites (59 tests); the switch-back-on test passed already and stays as a guard. Green 204/204.

/code-review --fix: no correctness bugs; 3 cleanups fixed (the test now calls production configure instead of a copy; plain if instead of a negated guard; one ProfileRecord fixture). Skipped: the always-false persistsInPrivate branch (intended), the v19 test inserting today's ProfileRecord into a v18 schema (same as the v18 test), discardPrivateSession posting no notification (no listener cares; no Private window remains).

Tests after review: 204/204 (SiteSettingsStoreTests, AutomaticPictureInPictureTests, ContentBlockerWhitelistTests, DevModeSiteOverrideTests, AppDatabaseTests, TabStoreTests, ExtensionUpdateMigrationTests, ExtensionDatabaseTests, RuntimeInstalledEventTests, ContentRuleListChunkTests).

Runtime (docs/harness/task195-harness.patch; re-run after the review, log identical apart from random space ids; page /jquery.popunder.js blocked by a generic EasyList rule, served from http://lvh.me:8895 because 127.0.0.1 is unblocked by an EasyList  exception that Detour mis-compiles, see the follow-up task): a hand-built v18 database lost its Private contentBlocking row at launch, keeping the Private pictureInPicture and Default rows; Private window: switching blocking off wrote 0 rows, reloaded and the script loaded; switching back on cleared the in-memory override and blocked again; a normal window was still blocked, and switching off there wrote 1 row; after closing the last Private window a new Private window was blocked again with the switch on. Not verified: a Peek or the other pane of a split in a Private window (shared reload path).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Content blocking's per-site switch set in a Private window is now kept in memory only and forgotten when the last Private window closes; migration v19 removes Private content-blocking rows already on disk. Nothing else needed resetting: the switch is applied per navigation, not compiled. 204 tests pass; runtime harness clean after review.
<!-- SECTION:FINAL_SUMMARY:END -->
