---
id: TASK-292.5
title: 'Website: guide pages for Pinned Tabs & Folders, Profiles and Favorites'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-08T06:59:00Z'
updated_date: '2026-11-08T09:08:00Z'
labels:
  - website
dependencies:
  - TASK-292.2
parent_task_id: TASK-292
priority: medium
ordinal: 346000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The remaining headline features, written to the pilot template (TASK-292). Profiles is the page for the "multiple accounts on the same site" and "separate work and personal browsing" searches. Captures come from the staged demo profile and kit in docs/task-110 (public pages only, no personal data, every launch with DETOUR_DATA_DIR set).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Each page follows the template from the pilot (H1 + lede, media, what/why, how-to steps, FAQ, related features, download) with its own title tag and meta description pairing the feature name with the generic search phrase
- [x] #2 Steps, menu paths and shortcuts on each page were checked against the current release build
- [x] #3 Images and loops have alt text or aria-labels describing what is on screen, fixed dimensions, and loops meet the TASK-110 size and reduced-motion rules
- [x] #4 Pages are in the sitemap and linked from the home page entry for the feature
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026 (agent, website worktree branch task-292.5, commit 12e9b1c, not pushed or merged): pages /features/pinned-tabs/, /features/profiles/ and /features/favorites/ written to the template, with 'How ... work →' links added to the three home page sections. Also in the commit: split-tabs.md and docs/feature-pages.md now say File › Pin Tab (see below), and image media takes an optional displayWidth (content.config.ts and [id].astro), so the 448-px profiles-list crop shows at 360 px instead of being scaled up to 900.

Runtime check: a v0.4.0 Debug build in a throwaway worktree with a temporary harness (App/DocsHarness.swift, a hook in AppDelegate and a clickedRow override, never committed), local fixture pages served from 127.0.0.1:8726. Confirmed:
- The File menu item's static title is Pin/Unpin Tab, but validateMenuItem renames it to 'Pin Tab' or 'Unpin Tab' whenever it is shown, with ⌘D. Pinning through it pins the tab at the end of the pinned section, and its address becomes the pinned URL.
- Tab row menu 'Pin Tab'. Pinned row menu: Copy Link, Share…, Duplicate, Move to, Rename…, Unpin Tab. Unpin Tab puts the tab at the top of the tab list.
- Empty-area menu: Edit Space…, Delete Space, New Folder. New Folder creates 'New Folder'. Folder menu: New Nested Folder, Rename… (starts inline editing), Delete Folder, which keeps the contents (they move up a level).
- ⌘W on a pinned tab keeps the row and leaves it dormant: its button changes from 'Close Tab' (minus) to 'Remove Pin' (xmark). Clicking the dormant tab reloads the pinned URL.
- Same-host link: the tab stays on its site and its title becomes '/ Inner A'. Other-host link opens a Peek, and ⌘W closes the Peek first.
- A pinned split row's menu: Copy URL, Separate Tabs. The pair was pinned through store.pinSplitGroup, not by a drag.
- Private window: Pin/Unpin is disabled, and the row menu has only Copy URL, Share…, Duplicate.
- Favorites, through the bar's payload gate (favoritableTabPayload) and the sidebar drop delegate, not a real NSDraggingInfo drag: lone tabs and pinned entries are accepted, folders and splits refused. The tab leaves the list. Tile menu: Remove from Favorites only, which also closes the page. Click selects the favorite. Double-click goes back to the favorite's URL. Other-host link opens a Peek. ⌘W leaves the tile dormant. A Space on the same Profile shows the same tiles and the same live tab; a Space on another Profile shows none.
- Settings › Profiles: list rows show 'Private Windows' and 'N Space(s)'. Rows: Name, Search engine [Google, DuckDuckGo, Bing, Yahoo, Ecosia, Kagi], Search suggestions, Archive tabs after [12 hours default, 24 hours, 7 days, 30 days, Never], Sleep tabs after [15 minutes, 30 minutes, 1 hour default, 2 hours, Never], Per-tab isolation, Block content + EasyList (ads), EasyPrivacy (trackers), Cookie notices, Malicious URLs, Identify as [Detour, Safari, Custom], External Apps 'Saved permissions' + Clear. The Private profile shows 'This profile is used for Private Windows.' and hides Archive and External Apps; its − button is disabled.
- + opens a sheet (Profile name, Create/Cancel). − on a Profile in use gives 'Cannot Delete Profile' / 'Default is used by 2 spaces. Remove or reassign those spaces first.'
- Settings › Spaces Profile menu [Default | Client X]. Changing it gives 'Change Profile?' with Cancel and Change. A fresh data dir starts with a Profile named Default and a Space '🏠 Home'.

Code-only (not run): dragging tabs into the pinned section or onto a folder; folder collapse on click; drag-reorder of favorites and dragging a tile back to the tab list or pinned section; Undo of a removed pinned tab ('Delete Tab'); Move to keeping a pinned tab pinned; the 'Drop to add favorite' hint (label string only); no favorites limit (4 per row); pinned tabs and favorites are never archived and skip the idle sleep timer; per-tab isolation uses a non-persistent store per tab; deleting a Profile removes its data and favorites and clears the undo stack; a profile change reloads the Space's tabs.

Bug found (runtime-confirmed): Private-window cookies and localStorage survive closing every Private window and come back in the next Private window during the same app run. The Private profile's lazy .nonPersistent() store is created once per process (Profile.swift:168) and is never replaced when the Private session ends. The lead was told, since this matters for TASK-292.7's Private Browsing page. The Profiles page only says Private records no history and saves nothing to disk.

Browser check (Chrome, local dist/ build): all three pages at desktop width; at 390 px the three pages and the home page have scrollWidth 390, with only the decorative arrow SVG clipped, as on the pilot. The Profiles settings table wraps cleanly at 390 px. The home page shows five 'How … work →' links. Sitemap lists all five feature pages. Related ids private-browsing and content-blocker assume TASK-292.7's ids.

Data dirs used: DetourDocs2925, DetourDocs2925b, DetourDocs2925c, DetourDocs2925d. Their NSWindow Frame / NSSplitView defaults keys and Application Support folders were deleted. The harness stays in the app worktree (scratchpad agent-2925/app) for the lead to remove.

Nov 8 2026: merged into the website (98c6431), reviewed with the TASK-292.7 batch (/code-review medium --fix on e9c97b4..HEAD: 8 overstated claims corrected in a0a35d5, e.g. Per-tab isolation still records history, deleting a Profile happens at once, a closed pinned split side closes rather than sleeps), pushed with the user's approval (6451d0a..a0a35d5) and live: /features/pinned-tabs/, /features/profiles/, /features/favorites/ answer 200, in the sitemap, linked from the home sections. Agent worktrees and branches removed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Guide pages for Pinned Tabs & Folders, Profiles and Favorites are live, written to the pilot template, reusing the existing pinned and favorites loops and the Profiles settings crops (a new displayWidth option keeps the small crop sharp). Facts were checked in the v0.4.0 code and in a running v0.4.0 build (menus, folder and favorites behavior, Settings › Profiles labels); the runtime check also found the Private-session data bug (TASK-298, now fixed on main) and that the File menu shows Pin Tab/Unpin Tab, which corrected the Split Tabs page and the template doc. Reviewed with the TASK-292.7 batch; drag-and-drop paths and a few behaviors were confirmed in code only (listed in the notes).
<!-- SECTION:FINAL_SUMMARY:END -->
