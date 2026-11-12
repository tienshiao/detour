---
id: TASK-293.1
title: >-
  Import from Arc: read Arc's sidebar, profiles and history on this Mac and the
  Arc Data Export file
status: Done
assignee:
  - '@claude'
created_date: '2026-11-12T09:22:00Z'
updated_date: '2026-11-12T11:00:00Z'
labels:
  - import
dependencies: []
parent_task_id: TASK-293
ordinal: 384000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The importer takes two sources (user, Nov 12 2026): Arc's own files on this Mac (direct import, works only while Arc and its data are still there; Arc stops working Dec 22 2026) and the Markdown file Arc's Settings › Advanced › Export Data writes (survives the shutdown, but carries only links: no profiles, history or IDs). Both have to come out as one source-neutral snapshot so the mapping (TASK-293.2) and the window (TASK-293.3) don't care which one was read. The survey of the on-disk format is in TASK-293's notes.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 One pure, nonisolated snapshot model covers both sources: Arc profiles (name, directory), spaces (title, emoji or icon, colour, profile), each space's pinned tree (folders nested to any depth, tabs, split views) and unpinned tabs in Arc's order, favourites per profile
- [x] #2 The direct reader parses StorableSidebar.json from sidebar.containers only (the sync shadows are ignored), names profiles from User Data/Local State, and reads each profile's History from a copy, limited to visits newer than Detour's history retention
- [x] #3 The export reader parses Arc Data Export.md into the same snapshot, checked against a file exported from Arc 1.172 or later
- [x] #4 Unknown item kinds (Easels, Notes, anything new) and unreadable entries are counted and named in the snapshot instead of failing the whole read; a missing or unreadable Arc install or file is a typed error
- [x] #5 Unit tests against synthetic fixtures: nested folders, several profiles, an empty sidebar, a split view, an unknown item kind, Arc's built-in untitled personal space, and an export file
- [x] #6 Wiki page on both formats with the Arc version they were checked against, linked from wiki/index.md
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Detour/Import/Arc/ArcImportSnapshot.swift: nonisolated Sendable value model (profiles with favourites and an optional History file, spaces with pinned/unpinned node trees: tab, folder, split; skipped items; typed ArcImportError).
2. ArcSidebarReader: StorableSidebar.json (+ Local State names) -> snapshot. Ordered-map decoding of the alternating arrays, tree walk by childrenIds with a cycle/depth guard, title = renamed title ?? savedTitle ?? host, emoji_v2 / symbol icon, colour from primaryColorPalette.midTone, built-in personal space title fallback, unknown kinds -> skipped.
3. ArcHistoryReader: copy History (+ -wal/-journal) into a temp dir, open read-only with GRDB, visits newer than a cutoff joined to urls, hidden/non-web skipped, Chromium time -> Date; streamed in batches for the writer in 293.2.
4. ArcExportReader: Arc Data Export.md -> snapshot (one synthetic profile, keys derived from space title + folder path + URL). Needs a real exported file from the user to pin the layout.
5. Tests with inline synthetic fixtures + a GRDB-built History fixture; wiki page features/arc-import.md.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 12 2026: ArcImportSnapshot, ArcSidebarReader, ArcHistoryReader written (Detour/Import/Arc/), ArcSidebarReaderTests 18/0. Real-data probe (swiftc, counts only) on Arc 1.172.1: 4 profiles (Default named from Arc's placeholder -> 'Default'), favourites 1/2/0/0, 2 spaces with emoji and colours, space 1 = 1 folder with 3 tabs + 8 unpinned tabs, 2 unusable-URL tabs reported as skipped; all 4 profiles have History. No split view exists in this Arc, so the splitView item shape (data key 'splitView', panes as childrenIds) is from Arc's class names, not seen on disk yet. Waiting on the user for an Arc Data Export.md and a split view to re-read. Not committed yet (review + verify first).

Nov 12 2026 (later): the user made a split view and an export.
- Split view on disk: data {splitView: {itemWidthFactors: [paneItemID, 0.5], focusItemID, layoutOrientation: 'horizontal', timeLastActiveAt, customInfo}}, panes are its childrenIds (tab items). Reader now keeps the first pane's width share (ArcSplit.leadingFraction).
- Arc Data Export.md (Arc 1.172.1): '# <space title>', blank line, '## Favorites' then '- <url>' lines, '## <folder>' per folder; URLs only (no titles, profiles, splits, ids); arc:// URLs included. Matched against the live sidebar: the Favorites list = the space's PROFILE favourites followed by the space's Today tabs (split panes flattened), with no separator.
- User decision: in an export, links that open the Favorites list of two or more spaces (shared lead, same order) are favourites; the rest are the space's Today tabs; with one space nothing is a favourite; the window must say this is a best guess. Known miss on the real export: Profile 1's second favourite (only space on that profile) becomes a Today tab.
- ArcExportReader written; lenient about layouts not yet seen (### nests, non-link bullets open folders, [title](url) and <url>). ArcExportReaderTests 7/0, ArcSidebarReaderTests 18/0. Real export probe: 1 favourite, Home = News folder (3) + 7 Today tabs, ISBX = 1 Today tab, 2 arc:// skipped.
- Waiting on a second export with a top-level pinned tab and a nested folder to pin down where Arc writes those.

Nov 12 2026, close-out:
- Second export (user added a top-level pinned tab and a folder inside News): top-level pinned tabs are written into ## Favorites between the favourites and the Today tabs, with no marker (so from an export they come over as Today tabs under the shared-lead rule); a nested folder is a ### section after its parent's links. Fixture updated to this layout.
- /code-review medium --fix: 8 findings, 5 fixed (history copy opened read-write so a copied hot journal or WAL can be recovered, the original is never opened; javascript:/about:/mailto:/data:/blob:/tel: bullets read as links and skipped instead of opening folders; only the first top-level '## Favorites' of a space is the Favorites list; a bad shared favourite is skipped once; doc comment no longer names a nonexistent flag; +2 tests). Left: (6) a subtree cut off by the depth-64 guard is not reported as skipped (only a corrupt file reaches it); (7) parse() called directly reports a placeholder source from a relative path (read() always replaces it); (8) Arc splits of more than 2 panes reach the mapping as N-pane ArcSplit with the first pane's share of all N: TASK-293.2's mapping decides (its AC already says first two as a split, the rest plain). No test for the hot-journal recovery (needs a crafted hot journal).
- Tests: ArcSidebarReaderTests 18/0, ArcExportReaderTests 9/0 (27/0).
- /verify: Debug build into .derived, launched with DETOUR_DATA_DIR=DetourVerify2931 (dylib timestamp = this build): app stayed up, created 1 space + 2 profiles, no errors in its output; quit by PID; its defaults keys and data folder removed. The readers are not called from the app yet, so there is nothing else to observe at runtime.
- Real data (counts only, swiftc probes, nothing committed): direct read and both exports match the live sidebar.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Arc import readers (Detour/Import/Arc/): ArcImportSnapshot (source-neutral model with stable source keys), ArcSidebarReader (StorableSidebar.json's live sidebar container, profile names from Local State, split views with width share, unsupported items and non-web URLs reported as skipped), ArcHistoryReader (Chromium History read from a private copy, visits newer than a cutoff, subframes/hidden/non-web skipped) and ArcExportReader (Arc Data Export.md; the shared-lead rule splits favourites from Today tabs, user decision). Formats documented in wiki/features/arc-import.md against Arc 1.172.1, measured on this Mac's Arc data and two real exports. 27 unit tests on synthetic fixtures; app builds and launches clean in an isolated profile. Follow-ups noted: depth-guard subtree not reported, N-pane splits decided in TASK-293.2.
<!-- SECTION:FINAL_SUMMARY:END -->
