---
id: TASK-293
title: 'Import from Arc: spaces, pinned tabs and folders, favorites, and history'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-08T06:59:00Z'
updated_date: '2026-11-14T01:36:00Z'
labels:
  - import
dependencies: []
references:
  - TASK-292.3
priority: medium
ordinal: 354000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Arc is no longer developed, and its users are a large share of the people who try Detour. The first thing they look for is a way to bring their setup across, and Detour has none: today they rebuild spaces, pinned tabs, folders and favorites by hand. The Switching from Arc hub (TASK-292.3) has to document that manual route until this exists, and should point to the importer once it ships.

What to verify before scoping (from memory during planning, not checked): Arc keeps its sidebar (spaces, pinned tabs, folders, favorites) in a JSON file under ~/Library/Application Support/Arc (StorableSidebar.json), and per-profile Chromium data (History, Bookmarks, Cookies, Login Data) under its User Data folder. Cookies and saved passwords are encrypted with a Keychain key ("Arc Safe Storage"), and WebKit has no supported way to bulk-load cookies into a WKWebsiteDataStore, so logins are probably out of scope; the task should say so plainly to users rather than half-import them. Arc profiles map naturally onto Detour Profiles and Arc spaces onto Detour Spaces, but the exact mapping (an Arc space's profile, folder nesting depth, split views, Little Arc state) is for the worker to work out.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The on-disk formats the importer reads are documented in the wiki, with the Arc version they were checked against
- [x] #2 A user can import from Arc (File menu and first-run) and choose which Arc profiles and spaces to bring over
- [x] #3 Imported spaces keep their names, colors or emoji where Detour supports them, and land in a Detour Profile matching their Arc profile
- [x] #4 Pinned tabs and folders keep their order and nesting; favorites become Detour Favorites on the matching profile
- [x] #5 Browsing history is imported into the matching profile's history
- [x] #6 What is not imported (logins and cookies, passwords, anything else) is told to the user in the import UI, not silently dropped
- [x] #7 Importing twice does not duplicate spaces, pinned entries or favorites
- [x] #8 A missing or unreadable Arc install fails with a clear message and changes nothing
- [x] #9 Parsing and mapping are unit-tested against fixture files covering nested folders, multiple profiles and an empty sidebar
- [ ] #10 The Switching from Arc hub (website src/pages/arc/) gets a migration section built around the importer, replacing the held-back manual guide in src/pages/arc/_move.md (user, Nov 7 2026: the hub leaves migration off until an import exists)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 7 2026 (found while building the Arc hub, TASK-292.3; Arc's help center via the Wayback Machine, captures Oct 22-Nov 7 2026):
- Arc is being sunset on December 22, 2026 (announced Oct 22): Arc for macOS stops working that day, sign-in ends, accounts are deactivated and their data deleted within 30 days. The Browser Company points users to Dia, which imports Spaces, Favorites, pinned tabs, folders, bookmarks, history, passwords and extensions straight from Arc ("Arc Sunset: Key Dates and What to Expect", "Move from Arc to Dia"; Dia "finds your Arc data through the Arc app, so keep Arc installed until your import finishes").
- Arc now has an export: Arc › Settings › Advanced › Export Data saves "Arc Data Export.md", a section per Space listing Favorites, pinned tabs, folders and other sidebar tabs as links ("How Do I Export My Data from Arc?"). Folders also have Copy All Links (and, holding Option, Copy All Links as Markdown).
- Implications to weigh before scoping: importing Arc Data Export.md is a documented, stable format that survives the shutdown (a user can export now and import later), while reading Arc's own files works only as long as their format holds and people still have them; after Dec 22 nobody can open Arc to export, so the value of an importer is front-loaded into the next six weeks.

Nov 12 2026, format survey on this Mac (Arc 1.172.1 build 90370, running; structure only, no page content read):
- ~/Library/Application Support/Arc/StorableSidebar.json, top-level version 1. The live state is sidebar.containers[1] = {spaces, items, topAppsContainerIDs}; containers[0] is {global:{}}. spaces/items/topAppsContainerIDs are Swift-encoded ordered maps: alternating [key, value, key, value]. firebaseSyncState and sidebarSyncState are sync shadows: here sidebarSyncState.lastSuccessfulSyncDate is Nov 2024 and holds 57 items vs 24 live, only 12 shared; ignore both.
- Space: id, title (absent on Arc's built-in personal space thebrowser.company.defaultPersonalSpaceID), profile = {default:true} | {custom:{_0:{directoryBasename:'Profile 1', machineID}}}, containerIDs ['unpinned', id, 'pinned', id] (newContainerIDs is the same as tagged enums), customInfo.iconType = {emoji_v2:'🏠', emoji:<codepoint>} or {icon:<symbol>}, customInfo.windowTheme {semanticColorPalette, background, primaryColorPalette{midTone, shaded, tintedLight, shadedDark}} with colours as {colorSpace, red, green, blue, alpha}.
- Item: id, parentID, childrenIds (order), title (user-renamed title or null), createdAt (seconds since 2001), data = {tab:{savedURL, savedTitle, timeLastActiveAt, savedMuteStatus, referrerID?, activeTabBeforeCreationID?}} | {list:{}} (folder, nests) | {itemContainer:{containerType:{spaceItems:{_0:spaceID}} | {topApps:{_0:<profile>}}}}. Binary also has splitView, easel and arcDocument cells (not present in this sidebar). Favourites = children of the topApps container for a profile (one per Arc profile, listed in topAppsContainerIDs as profile/containerID pairs).
- Profiles: names from User Data/Local State profile.info_cache[<dir>].name (Default, Profile 1..3 here); StorableProfiles.json lists the profile ids only.
- History: User Data/<profile dir>/History, Chromium history schema version 70 (urls, visits; visit_time in microseconds since 1601-01-01). Copying the file while Arc runs works; read the copy (immutable). Here: Default 142k visits, Profile 1 22k, Profile 2 0, Profile 3 31.
- Detour side: history.db visits are per space and expire after 90 days (AppDelegate expireOldVisits), so only the last 90 days are worth importing; favourites are per profile; pinned folders nest via parentFolderID; there is no first-run flow yet.

2026-11-14, AC review against main (a0cc9c3+):
#1 wiki/features/arc-import.md documents both formats, checked against Arc 1.172.1 (build 90370).
#2 File › Import from Arc… (AppDelegate.importFromArc) and the one-time launch offer sheet (TASK-293.5). The window has a checkbox for each Arc profile and space, and an "into" popup per profile.
#3 The planner keeps name, emoji and colour (ArcImportPlannerTests.testSpacesKeepNameEmojiAndColourWithDefaults). Each Arc profile goes to a new Detour profile by default, or a chosen existing one; a re-import follows the link (testAReImportGoesBackToTheLinkedProfileAndSpaceEvenAfterARename).
#4 testPinnedTreeKeepsOrderNestingAndSplits (reader and planner) and testFavouritesGoToTheirProfile.
#5 HistoryDatabase.importVisits imports the last 90 days per profile (ArcImportTabStoreTests.testHistoryIsImportedUnderTheSpaceOnceAndFeedsTheReaders).
#6 ArcImportText.notImported is shown in the window; the offer sheet fine print says what stays in Arc.
#7 testImportingTheSameDataAgainAddsNothing, plus the re-import planner tests.
#8 Read failures are typed ArcImportError (LocalizedError: arcNotFound, unreadable, unrecognizedFormat). The window shows the message, has no snapshot, and keeps Import disabled. ArcSidebarReaderTests.testMalformedFilesAreTypedErrors.
#9 Synthetic fixtures cover nested folders (testPinnedTreeKeepsOrderNestingAndTitles, export testDeeperHeadingsAndIndentedBulletsNest), several profiles (testProfilesAreNamedFromLocalStateAndCarryTheirFavourites) and an empty sidebar (testEmptySidebarGivesNoSpaces, testAnEmptySpaceAndAFileWithoutSpaces, testAnEmptySnapshotPlansNothing).
#10 waits on TASK-293.4: the website branch arc-import merges with the next release. Then 293 can be closed.
<!-- SECTION:NOTES:END -->
