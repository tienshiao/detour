---
id: TASK-293.6
title: >-
  Website: guide pages for the next release (spaces made in the sidebar, Quick
  Detour, downloads, Arc import), on branch arc-import
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14T01:38:00Z'
updated_date: '2026-11-14T02:36:00Z'
labels:
  - website
dependencies:
  - TASK-289
references:
  - TASK-293.4
parent_task_id: TASK-293
priority: medium
ordinal: 394000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The next release (after 0.4.3) changes things the website describes. TASK-289 moves making and editing a Space into the sidebar editor, so features/spaces.md and features/profiles.md still send people to Settings › Spaces. TASK-322 adds a back button, a clickable address capsule and load progress to Quick Detour. TASK-324 animates downloads and fixes Download Linked File. TASK-293 adds Import from Arc. The pages and the index have to match the release on the day it ships. Following the website pattern, the work waits on a branch (arc-import, together with TASK-293.4) that is rebased and fast-forwarded onto website main right before publish-release.sh.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Every user-facing change since v0.4.3 is checked against the website (guide pages, features index, shortcuts, Arc hub, home), and each one is either updated or recorded as needing no change
- [x] #2 spaces.md and profiles.md describe making and editing a Space in the sidebar editor (+, Edit Space…, Create Space / Done, Cancel), with names checked against the code
- [x] #3 Screenshots that show the old flow are replaced by real captures from the release build, or listed in this task as still owed
- [x] #4 The site builds on the branch
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-14: website branch arc-import, commit 677691d (on top of TASK-293.4 ce06598 and the Arc hub Spaces row fix 7da38ed). Astro build: 23 pages.

User-facing changes since v0.4.3, each checked against the site:
- TASK-289 (Spaces made and edited in the sidebar): spaces.md updated (Arc box, Create a Space rewritten as the editor steps, Edit uses the editor plus Undo Edit Space; the Settings › Spaces still moved under Reorder/Delete, where Settings still applies). profiles.md updated (Arc box; Give a Space a Profile goes through Edit Space… and Done; Settings › Spaces with Change Profile? kept as the other way). Arc hub row fixed (7da38ed). No change needed: favorites.md and profiles.md FAQ (Settings › Spaces still lists each Space's Profile and can change it); private-browsing.md (Manage Spaces… still unavailable in Private). Names checked in SpaceEditorView, SpaceChoiceGridView (Custom Color…, All Emoji…) and TabStore (Add Space / Edit Space undo names).
- TASK-322 (Quick Detour back button, clickable capsule, load progress): quick-detour.md "Use the window" updated. Shortcuts unchanged.
- TASK-324 (download toss; Download Linked File works again): features index Downloads line mentions the flight. split-tabs.md FAQ already says Download Linked File, and that is correct again.
- TASK-293 (Import from Arc): Arc hub section (TASK-293.4); features index "Switching from Arc" line names File › Import from Arc…. No change needed: web-extensions.md "importing extensions from another browser" is still not in Detour; shortcuts (the menu item has no key).
- TASK-323 (disabled hover): nothing to document.
- Home page and shortcuts page: no change needed (no key changes; home blurbs still hold).

Media (AC #3), still owed:
1. quick-detour.mp4 + quick-detour-poster.webp show the old title bar (no Back button, no progress fill). Re-record the same TextEdit scene at 2x.
2. spaces.md has no picture of the new editor. Add a 2x still or a short loop (Create Space with the toss) to "Create a Space". docs/task-289 captures are 1x (240 px wide), too small for the site.
3. Optional: a still of the Arc launch offer or the import window for the Arc hub, made with demo Arc data, never the user's own.
Still valid: spaces.mp4 (switching unchanged), profiles-spaces.webp (the Settings › Spaces list looks the same; compared with docs/task-289/settings-spaces.png), profiles-list.webp.

2026-11-14 media: captured from a Debug build of main 06a0d22 with the docs/task-110 kit (DETOUR_DATA_DIR DetourCap2936; fake Arc folder; wallpaper and virtual display restored; data dir, suite, suffixed keys and WebsiteDataStore folders removed). On website arc-import 909c6e1: quick-detour.mp4 (2440x1700, 7.9 s, 376 KB) + poster re-taken with the Back button and the capsule load progress, aria label updated; spaces-editor.webp (1400x1760, 92 KB) in Spaces › Create a Space. Build passes. Held back for a user decision: arc-import-offer.webp and arc-import-result.webp (the offer sheet shows Arc's real app icon, and docs/feature-pages.md says no Arc logos). These are kept in the session scratchpad captures-2936. Kit updates committed to docs/task-110.

2026-11-14, user decision: use the Arc offer stills on the Arc hub, even though the sheet shows the Arc app icon. Website arc-import e37752a adds arc-import-offer.webp (under Import into Detour) and arc-import-result.webp (after the steps), and a line in step 3 about "(Arc)" on a taken profile name (ArcImportPlanner.uniqueProfileName). docs/feature-pages.md records the exception to the no-Arc-logos rule. Build passes. Not checked in a browser: how the two 2280 px landscape stills sit in the hub's body column.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Website updated for 0.4.4. Spaces and Profiles pages describe the sidebar space editor (TASK-289); Quick Detour describes the Back button, the clickable address capsule and load progress (TASK-322); the features index mentions the download toss (TASK-324) and Arc import. Every user-facing change since v0.4.3 was checked against the site; the rest needed no change (listed in the notes). Media from a Debug build of main 06a0d22 with the docs/task-110 kit: a re-taken quick-detour.mp4 and poster, spaces-editor.webp, and arc-import-offer.webp / arc-import-result.webp on the Arc hub (user decision: allowed although the sheet shows the Arc icon; docs/feature-pages.md records the exception). Deployed with the 0.4.4 release (website bceeca8); live pages checked with curl. Not checked in a browser after deploy: layout of the two wide Arc stills in the hub column (they rendered in the local preview the user looked at).
<!-- SECTION:FINAL_SUMMARY:END -->
