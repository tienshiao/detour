---
id: TASK-414
title: >-
  Website: guide pages for 0.5.0 (space shortcuts, customizable shortcuts,
  palette commands, local servers, cross-profile Quick Detour, clean links, back
  to opener)
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-20T02:57:00Z'
updated_date: '2026-11-20T03:01:00Z'
labels:
  - website
dependencies:
  - TASK-295
  - TASK-327
priority: medium
ordinal: 495000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
0.5.0 shipped 2026-11-19 with the website stating only the new version. Pages that no longer match the app (../detour-website, edits on a branch for the user's review, deployed only when the user says so):
- Spaces guide (src/content/features/spaces.md: limits list line 28, FAQ 'Is there a shortcut to jump to a specific Space?', shortcuts table) and the Arc hub (src/pages/arc/index.astro:42) say there are no shortcuts that jump to a space by number; ⌃1–⌃9 ship in 0.5.0 (TASK-295 AC #7).
- Keyboard Shortcuts page (src/pages/shortcuts.astro): ⌃1–⌃9, and that shortcuts can be changed in Settings › Shortcuts (TASK-327 AC #7); ⌘[ / back swipe on a child tab returns to its opener (TASK-325/331).
- Command palette guide: browser commands, the > prefix, the chip for parameterised commands (TASK-320); local servers when typing localhost/a port/127.0.0.1 (TASK-411), also Quick Detour and dev mode.
- Quick Detour guide: history from every profile, rows labelled with profile and space, opened in their own profile (TASK-409).
- Privacy / Content Blocker guides: Copy URL and Share… strip tracking parameters, the AdGuard URL Tracking list and its switch in Settings › Content Blocking (TASK-326/329/337).
Every claim is checked against the app's code (menu titles, setting labels, shortcuts).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The Spaces guide, Arc hub and Keyboard Shortcuts page list ⌃1–⌃9 and no longer call jump-to-space missing
- [x] #2 The Keyboard Shortcuts page says shortcuts can be changed in Settings › Shortcuts
- [ ] #3 The command palette, Quick Detour, privacy and content blocker guides describe the 0.5.0 behaviour listed in the description
- [ ] #4 Wording checked against the code; the site builds; the branch is reviewed by the user before it is deployed
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-19: website branch guides-0.5.0 (commit 60d6843, not pushed or deployed), 8 files:
- spaces.md: ⌃1–⌃9 moved from 'not in Detour' to 'same as Arc'; FAQ answer; Switch Spaces step; shortcuts row. Arc hub: removed the not-in-Detour line, Spaces row says ⌃1–⌃9 as in Arc, Command Bar row says the palette runs commands.
- shortcuts.astro: Spaces menu row ⌃1…⌃9 with a note (first nine by name, Mission Control can take ⌃N); a paragraph on Settings › Shortcuts (taken keys refused with the holder named; Undo/Redo/Cut/Copy/Paste/Select All fixed; Restore Defaults); menu tables now render notes; palette rows for > and command chips; Back's opener behaviour.
- command-palette.md: lede, description, Arc box (notInDetour emptied: commands such as Show Archived Tabs run from the palette), FAQ on commands, sections Run a command and Open a local web server, list and shortcut rows.
- quick-detour.md: cross-profile history (labels, opens in the row's profile, typed text uses the last window's profile), local servers, FAQ.
- privacy.md (step 6) and content-blocker.md (new section): Copy URL/Copy Link/Share… strip tracking parameters, the AdGuard switch; Update the lists sentence fixed for the redesigned rows (no In List/Active columns any more).
- features index: Sleeping Tabs (memory pressure), Undo (page typing), Keyboard Shortcuts (customizable), new Clean Links and Local Servers entries.
Checked against code: BrowserCommands.swift (titles, default keys, jumpToSpace), AppDelegate.updateSpacesMenu, SpaceJump order, ContentBlockerSettingsViewController and ProfilesSettingsViewController labels, ShortcutsSettingsViewController (Restore Defaults), the wiki's palette/tracking-parameters/keyboard-shortcuts/tab-opener pages, TASK-409/411 summaries. npm run build: 23 pages; anchors and new rows checked in dist/. Not done: a visual check in a browser; the user's review; deploy. Automation (MCP) left off the site pending the user's decision.
<!-- SECTION:NOTES:END -->
