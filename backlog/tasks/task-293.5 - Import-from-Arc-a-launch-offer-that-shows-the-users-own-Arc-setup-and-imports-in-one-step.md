---
id: TASK-293.5
title: >-
  Import from Arc: a launch offer that shows the user's own Arc setup and
  imports in one step
status: Done
assignee:
  - '@claude'
created_date: '2026-11-13T09:25:00Z'
updated_date: '2026-11-13T20:16:00Z'
labels:
  - import
dependencies: []
parent_task_id: TASK-293
ordinal: 390000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The one-time Arc import offer (TASK-293.3) is a stock NSAlert with two paragraphs. For many users it is one of the first things Detour shows, so it should make a good first impression (user, Nov 13 2026). User decisions (Nov 13 2026): a custom sheet that reads Arc's sidebar first and shows the user's own spaces as chips (Arc's emoji and tint) with totals; the primary button 'Import Everything' imports every Arc profile with everything selected right in the sheet, which then shows the result; a secondary 'Choose…' opens the existing Import from Arc window; 'Not Now' declines.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The launch offer is a custom sheet: Arc's and Detour's icons, a headline, the user's Arc spaces as chips with their emoji and colour (overflow as '+N more'), and totals (spaces, pinned tabs, favourites, history)
- [x] #2 It says what stays in Arc (logins, passwords, extensions) and, before Arc's shutdown date, when Arc stops working
- [x] #3 Import Everything imports every Arc profile with everything selected (re-imports go where earlier ones went), the sheet then shows what was added and the history result, and the window switches to the first imported space
- [x] #4 Choose… opens the Import from Arc window; Not Now closes the sheet; the offer still shows only once, and an Arc install with nothing to import or that cannot be read shows no sheet
- [x] #5 The words and the offer rules are pure and unit-tested; the sheet is checked at runtime with /verify in light and dark mode against this Mac's Arc data
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 13 2026, implementation and checks:
- ArcImportOfferSheetController (programmatic AppKit sheet on the launch window); ArcImportOffer split into isDue/markShown + isWorthOffering; ArcImportOfferChipLayout (pure chip packing); ArcImportText offer words, resultLines/resultNotes (shared with the import window), count() groups thousands. AppDelegate reads the snapshot in the background before showing anything: unreadable -> nothing marked, a later launch retries; nothing worth offering -> marked, nothing shown.
- Runtime (isolated DetourVerify2935a-d, this Mac's Arc 1.172.1 data, System Events + screencapture -l): sheet showed Arc->Detour icons, Home/ISBX chips in Arc's tints, '2 spaces · 4 pinned tabs · 3 favorites · 90 days of history'; light and dark (system dark mode switched on for one capture, then back). Import Everything: 2 profiles, 2 spaces, 4 pinned in 2 folders, 3 favourites, 6 Today tabs, history 1,195 + 239 visits; Done closes. Found and fixed in pass 1: the space switch selected a Today tab and woke SoundCloud behind the sheet (now selectTab: false); fine print broke mid-sentence (now one line per sentence); result notes (left out, history of an Arc profile with no space) mixed into the summary (now small print below the card); '1195 visits' (now 1,195). Pass 2 confirmed all four. Choose… opens the Import from Arc window; Not Now closes; relaunch shows no offer.
- Tests: Arc suites 71/0 (ArcImportTextTests 15, Planner 19, TabStore 9, SidebarReader 19, ExportReader 9).
- Run data folders, scoped defaults suites and window/split-view defaults keys removed.
- Not checked: a Mac with more spaces than fit two chip rows (the '+N more' chip) at runtime, only in unit tests; the export-file path is unchanged.
- Not yet done: /code-review --fix and commit (waiting on the user).

Nov 13 2026, user wording review: the Today tabs line drops ', asleep until you open them'; the skipped-links note said '2 links only Arc can open are left out', which left people wondering what Detour can't open. It is now its own sentence that gives the reason: '2 links aren’t web pages (like arc:// pages), so they’re left out.' (the first wording, 'such as Arc’s own arc:// pages', wrapped 'left out.' onto a line of its own in the sheet); other skipped kinds stay a separate sentence ('1 Easel is left out.'). Both show in the import window too. Arc suites 71/0; result sheet rechecked at runtime (DetourVerify2935g, cleaned up).

Nov 13 2026, 'Today tabs' wording: the user (an Arc user) did not know the term. Arc's help centre article on pinned tabs (resources.arc.net/hc/en-us/articles/19231060187159) says Pinned Tabs / Unpinned Tabs and 'the Unpinned Section'; Arc's Dec 2023 release notes say Unpinned Tabs; 'Today' appears mainly in 2022-23 reviews (The Verge, TidBITS 'Arc 1.5 brings back Today tab syncing') and start.arc.net says 'today's tabs' in passing. Every user-facing 'Today tab(s)' is now 'unpinned' (space detail '6 unpinned', summary '6 unpinned tabs', the Bring checkbox 'Unpinned tabs', the export note); internal names unchanged. Arc suites 71/0; import window checked at runtime (DetourVerify2935h, cleaned up). The Internet Archive could not be reached from here (fetch tool blocks web.archive.org); the help centre returns 403 to direct fetches, so its wording comes from search-result excerpts.

Nov 13 2026, /code-review medium --fix: 8 findings, 4 fixed by the review (sheet refits after a failed import shows its status line; tests build expected numbers with formatted() so they pass in any locale; arcShutdown is the start of Dec 22 in the user's time zone, not UTC; the pinned count and '+N more' use formatted() like the other counts). Skipped, by design: an Arc with nothing worth offering marks the offer shown (an Arc whose sync has not finished on a new Mac would miss it; accepted); Import Everything uses the snapshot read at launch, not a fresh read; the dropped 'asleep until you open them' (user's call); the profile-name map duplicated between window and sheet (small; noted only). After the fixes: Arc suites + AppDatabaseTests 99/0; relaunch (DetourVerify2935i) showed the sheet with the same contents. Not exercised at runtime: the failed-import status line (applyArcImport throwing needs the store to change between plan and apply).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The one-time launch offer to import from Arc is now a custom sheet instead of a stock NSAlert, since for many people it is one of the first things Detour shows. Detour reads Arc's sidebar first, then shows Arc's and Detour's icons, the user's own spaces as chips in Arc's colours, totals, and what stays in Arc. Import Everything imports every profile with everything selected right in the sheet, which then shows what came over (left-out items in small print) while the window behind moves to the first imported space without waking a tab. Choose… opens the Import from Arc window. User wording review: 'unpinned tabs' instead of 'Today tabs' (Arc's help centre's term), and the skipped links say they aren't web pages. Tests: Arc suites + AppDatabaseTests 99/0. Runtime: light and dark, Import Everything, Choose…, Not Now, and a relaunch, against this Mac's real Arc data.
<!-- SECTION:FINAL_SUMMARY:END -->
