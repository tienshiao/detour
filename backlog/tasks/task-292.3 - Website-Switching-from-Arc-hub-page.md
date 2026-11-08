---
id: TASK-292.3
title: 'Website: Switching from Arc hub page'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-08T06:59:00Z'
updated_date: '2026-11-08T08:10:00Z'
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
- [x] #1 /arc/ is live with a table mapping Arc features to their Detour counterpart, each linking to its guide page where one exists
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

Nov 8 2026: callout now links Arc's own farewell page (https://arc.net/, states the Dec 22 2026 sunset) instead of the Wayback capture (user pointed it out). User approved; pushed website ba37d98 + 6451d0a (1139c7d..6451d0a); Cloudflare's Git build deployed. Live: /arc/ 200, in sitemap.xml, linked from the home hero eyebrow, the footer and the Spaces/Split Tabs Arc boxes. Rich Results Test on https://detourbrowser.com/arc/: crawled, Breadcrumbs 1 valid item.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The Switching from Arc hub is live at detourbrowser.com/arc/: Arc's December 22, 2026 shutdown (linking arc.net's farewell page), a table mapping 15 Arc features to Detour's (each Detour name links to its guide page once that page exists), what Arc had that Detour doesn't, what Detour has that Arc didn't (Quarantine, link routing by source app, no account), and an FAQ. The home page's "FOR ARC REFUGEES →" eyebrow, the site footer and the feature pages' Coming from Arc boxes link to it.

Arc claims come from Arc's own help center, read through the Wayback Machine, and arc.net; Detour claims from the v0.4.0 code. Reviewed (/code-review medium --fix, 5 of 9 applied), checked at desktop and 390 px, Rich Results Test valid. Per the user, the manual migration guide is left off until Detour can import from Arc: the draft stays unrendered in src/pages/arc/_move.md and the requirement moved to TASK-293. Corrections found along the way were applied to the epic and TASK-292.6/292.8 (Arc had Site Search, Developer Mode and the Control-Tab switcher).
<!-- SECTION:FINAL_SUMMARY:END -->
