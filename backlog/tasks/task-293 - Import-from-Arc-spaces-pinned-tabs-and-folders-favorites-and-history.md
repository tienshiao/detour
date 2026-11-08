---
id: TASK-293
title: 'Import from Arc: spaces, pinned tabs and folders, favorites, and history'
status: To Do
assignee: []
created_date: '2026-11-08T06:59:00Z'
updated_date: '2026-11-08T07:54:00Z'
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
- [ ] #1 The on-disk formats the importer reads are documented in the wiki, with the Arc version they were checked against
- [ ] #2 A user can import from Arc (File menu and first-run) and choose which Arc profiles and spaces to bring over
- [ ] #3 Imported spaces keep their names, colors or emoji where Detour supports them, and land in a Detour Profile matching their Arc profile
- [ ] #4 Pinned tabs and folders keep their order and nesting; favorites become Detour Favorites on the matching profile
- [ ] #5 Browsing history is imported into the matching profile's history
- [ ] #6 What is not imported (logins and cookies, passwords, anything else) is told to the user in the import UI, not silently dropped
- [ ] #7 Importing twice does not duplicate spaces, pinned entries or favorites
- [ ] #8 A missing or unreadable Arc install fails with a clear message and changes nothing
- [ ] #9 Parsing and mapping are unit-tested against fixture files covering nested folders, multiple profiles and an empty sidebar
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 7 2026 (found while building the Arc hub, TASK-292.3; Arc's help center via the Wayback Machine, captures Oct 22-Nov 7 2026):
- Arc is being sunset on December 22, 2026 (announced Oct 22): Arc for macOS stops working that day, sign-in ends, accounts are deactivated and their data deleted within 30 days. The Browser Company points users to Dia, which imports Spaces, Favorites, pinned tabs, folders, bookmarks, history, passwords and extensions straight from Arc ("Arc Sunset: Key Dates and What to Expect", "Move from Arc to Dia"; Dia "finds your Arc data through the Arc app, so keep Arc installed until your import finishes").
- Arc now has an export: Arc › Settings › Advanced › Export Data saves "Arc Data Export.md", a section per Space listing Favorites, pinned tabs, folders and other sidebar tabs as links ("How Do I Export My Data from Arc?"). Folders also have Copy All Links (and, holding Option, Copy All Links as Markdown).
- Implications to weigh before scoping: importing Arc Data Export.md is a documented, stable format that survives the shutdown (a user can export now and import later), while reading Arc's own files works only as long as their format holds and people still have them; after Dec 22 nobody can open Arc to export, so the value of an importer is front-loaded into the next six weeks.
<!-- SECTION:NOTES:END -->
