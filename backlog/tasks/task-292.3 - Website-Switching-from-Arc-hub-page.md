---
id: TASK-292.3
title: 'Website: Switching from Arc hub page'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-08T06:59:00Z'
updated_date: '2026-11-08T07:59:00Z'
labels:
  - website
dependencies:
  - TASK-292.2
documentation:
  - docs/little-window
  - docs/air-traffic-control
parent_task_id: TASK-292
priority: medium
ordinal: 344000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Arc is no longer developed and its users search for a replacement ("Arc browser alternative", "browser like Arc for Mac"). Detour is no longer pitched as an Arc clone (TASK-292), so this hub is the one place written for Arc users: it maps what they relied on to Detour and is honest about gaps. Known mappings from planning: Spaces, Profiles, pinned tabs and folders, Favorites, Command Bar -> Command Palette, Peek, Split View -> Split Tabs, auto-archive -> Tab Archiving, Little Arc -> Quick Detour (docs/little-window), Air Traffic Control -> Link Routes (docs/air-traffic-control). Not in Detour: Boosts, Easels, Arc Max, among others. Detour has no Arc importer today, so moving over is manual; whether to build one is a separate decision.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 /arc/ is live with a table mapping Arc features to their Detour counterpart, each linking to its guide page where one exists
- [x] #2 The page lists what Arc had that Detour does not, and what Detour has that Arc did not
- [x] #3 Statements about Arc are factual and verifiable; no Arc logos, screenshots or styling
- [x] #4 Feature pages with a Coming from Arc box link to the hub, and the hub is linked from the home page
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 7 2026 (from TASK-292.2): Arc's help center (resources.arc.net) answers 403 to scripted fetches, but the Wayback Machine has it: archive.org/wayback/available?url=resources.arc.net/hc/en-us/articles/<id> gives the latest capture, web.archive.org/web/<ts>id_/<url> the original page (gzip). About 220 article URLs captured (CDX: web.archive.org/cdx/search/cdx?url=resources.arc.net/hc/en-us/articles/*&collapse=urlkey). Checked so far: Split View (Dec 2025 capture: ⌘⇧+ or drop a tab in the center; side by side or top-and-bottom; no maximum stated, the 'four' comes from TechCrunch/How-To Geek), Spaces (Jul 2026: + in the sidebar creates one; switch by icon, two-finger swipe, ⌃1/⌃2…, ⌘T + name; theme and icon per Space; Share Space as a link; Air Traffic Control routes), Keyboard Shortcuts (Jul 2026; key column did not extract from the table).

Nov 7 2026: user decision: leave the migration guide off the hub until Detour can import from Arc ("It is a weak article until we have an import process in place"). The former criterion "explains how to move from Arc by hand" moved to TASK-293. The drafted guide is kept, not rendered, in the website's src/pages/arc/_move.md.

Built (website commit, local): src/pages/arc/index.astro (mapping table from data, linking Detour names to /features/<id>/ when the page exists; ids used: spaces, profiles, pinned-tabs, favorites, split-tabs, quick-detour, link-routes, command-palette, site-search, peek, tab-archiving, recent-tabs, dev-mode, web-extensions), shutdown callout linking Arc's announcement (Wayback capture), Arc-only and Detour-only lists, FAQ, BreadcrumbList. Hero eyebrow "FOR ARC REFUGEES →" and a footer link go to /arc/; the guide pages' Arc boxes link to it automatically.
Sources: Arc help center via Wayback (Sunset Key Dates/FAQ, Export, Move to Dia, Sync, Little Arc, Air Traffic Control, Auto Archive, Peek, Pinned Tabs, Favorites, Profiles, Folders, Site Search, Developer Mode, Tab Switcher, Extensions, Boosts, Easels, Arc Max, Mini Player, Library, Previews, Live Folders, Share, Passwords, Account, ad blocking/MV3); extracted text in the session scratchpad (arc/hub). Detour facts: an Explore agent over the v0.4.0 code (file:line), plus the TASK-292.2 runtime check. Arc-did-not-have claims kept to what the sources support (content blocker listed as Detour's, without claiming Arc lacked one: Arc's Dec 2025 article said one was in the works).
Review (/code-review medium --fix, 9 findings): applied Favorites wording, Peek row (other-site links only), batch-open tip, Arc 'Password' label, phone-width wrap; two flagged as unsourced are sourced in the first download batch (stacked splits: Arc's Split View article; ⌃1/⌃2: Arc's Spaces article). Left: generating the table from the feature pages' arc data (most pages don't exist yet).
Browser check: desktop and 390 px (no horizontal scroll; the mapping table stacks into "<name> in Arc / Detour name / note" rows).
<!-- SECTION:NOTES:END -->
