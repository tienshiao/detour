---
id: TASK-188
title: >-
  Picture in picture: a per-site switch for opening PiP automatically when you
  leave a playing tab
status: Done
assignee:
  - '@claude'
created_date: '2026-10-24 09:21'
updated_date: '2026-10-24 16:08'
labels:
  - media
  - feature
dependencies:
  - TASK-187
priority: low
ordinal: 215000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the user 2026-10-24 (Arc has a per-site picture-in-picture preference).

Today Detour enters PiP automatically for every site: `selectTab` calls `BrowserTab.enterPictureInPicture()` for the tab being switched away from when it is playing audio (wiki/platform/media-and-pip.md; TASK-79 for the close-path exception). There is no way to turn this off for a site where it is unwanted (music players, video calls, a background YouTube playlist).

Add a per-site switch, stored in the per-site settings table (TASK-187, setting `pictureInPicture`, default on), shown in the faux address bar's popover next to the content blocking and dev mode switches (TASK-186.5). Off for a site: leaving one of its playing tabs does not enter PiP. Decide: whether "off" also blocks a page's own PiP request (`requestPictureInPicture()` / the video's PiP button) or only the automatic one (proposed: only the automatic one); the site key and subdomain rule (follow whatever TASK-187 settles for the other switches).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The address bar popover has a picture-in-picture switch for the current site, default on
- [x] #2 With it off, switching away from a playing tab of that site does not enter PiP; with it on, behaviour is unchanged
- [x] #3 Stored per profile and site in the per-site settings table; the decision on page-initiated PiP is recorded
- [x] #4 The automatic-PiP decision is a pure rule with tests (playing / not playing / closing / site off)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Decisions (2026-10-24): the switch turns off only the automatic PiP on tab switch; a page's own requestPictureInPicture() / the video's PiP button still works. Site rule as content blocking: the host or any parent host, most specific row wins; switching off stores the current host = false, switching on clears every row covering the host (default on). Private (user, 2026-10-24): a choice made in a Private window is kept in memory only and dropped when the last Private window closes; content blocking still persists Private rows (follow-up task to move it).
Steps (tests first): 1. SiteSetting.pictureInPicture (+ coverage), SiteSettingsStore: Private memory-only for settings that do not persist in Private, discardPrivateSession, resetToDefault(forHost:) clearing covering rows. 2. Pure AutomaticPictureInPicture.shouldEnter(isPlayingAudio:leavesClosingTab:siteOverride:). 3. selectTab uses it for the outgoing tab and its Peek. 4. Site popover: a switch under content blocking. 5. TabStore.removeIncognitoSpace drops the Private session's in-memory settings when no Private space remains. 6. Runtime check: popover switch in light/dark, a playing tab of an off site does not enter PiP, an on site does.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
From TASK-187's review (2026-10-24): SiteSettingsStore persists every profile's rows, the Private profile's included (content blocking always did: the Private profile row is saved under its fixed id). ExternalAppPermissionStore by contrast keeps Private decisions in memory only. Decide here whether this setting's choice made in a Private window should outlive the session.

Implemented (2026-10-24): SiteSetting.pictureInPicture (host or parent host, most specific wins) with persistsInPrivate = false; SiteSettingsStore keeps the Private profile's values of such a setting in memory only (set and clear skip the database), resetToDefault(forHost:) clears every covering row, discardPrivateSession() runs from TabStore.removeIncognitoSpace when no Private space remains. Pure AutomaticPictureInPicture.shouldEnter(isPlayingAudio:leavesClosingTab:siteOverride:) used by selectTab for the outgoing tab and its Peek. Site popover: 'Picture in picture on tab switch' switch under content blocking's (disabled with no host); off stores host = false, on resets to the default; no reload. Decision recorded: only the automatic PiP is governed; a page's own requestPictureInPicture() / PiP button still works. Follow-up TASK-195: content blocking's Private rows still go to disk.
Tests first (AutomaticPictureInPictureTests 11; 8 failed against empty stubs). Review (/code-review --fix, 8 findings): fixed clear() deleting Private memory-only values from the DB, a dead tab.spaceID profile lookup with a wrong comment (the outgoing tab always resolves in the active space; a space switch leaves no previous tab, as before), the ?? precedence made explicit, the wiki row. Skipped: an observer instead of the TabStore hook, the lookup on every switch, moving store tests into SiteSettingsStoreTests. Tests: 108, 0 failures (AutomaticPictureInPictureTests, SiteSettingsStoreTests, ContentBlockerWhitelistTests, TabStoreTests, AppDatabaseTests).
Runtime (docs/harness/task188-harness.patch, local server with a playing test video, page hook titling webkitSetPresentationMode calls): no setting -> leaving the playing tab entered PiP; switch off via the popover (performClick) -> one row 127.0.0.1 pictureInPicture false, leaving did not enter PiP; switch on -> row removed, leaving entered PiP. Popover checked light and dark. Not checked at runtime: the Private memory-only path (unit tests cover it), a Peek's PiP.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The site popover has a 'Picture in picture on tab switch' switch (default on), stored per profile and site as the pictureInPicture site setting with content blocking's subdomain rule. With it off, switching away from a playing tab of that site (or its Peek) no longer enters PiP; a page's own PiP request is unaffected. Set in a Private window, it stays in memory and is dropped when the last Private window closes (content blocking's Private rows still persist: TASK-195). Tests 108/108; runtime check with a real playing video in light and dark.
<!-- SECTION:FINAL_SUMMARY:END -->
