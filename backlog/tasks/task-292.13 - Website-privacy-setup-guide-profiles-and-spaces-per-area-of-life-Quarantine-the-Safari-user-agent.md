---
id: TASK-292.13
title: >-
  Website: privacy setup guide (profiles and spaces per area of life,
  Quarantine, the Safari user agent)
status: In Progress
assignee: []
created_date: '2026-11-08T21:35:00Z'
updated_date: '2026-11-08T23:22:00Z'
labels:
  - website
dependencies:
  - TASK-216
parent_task_id: TASK-292
priority: medium
ordinal: 373000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A guide page for privacy-conscious users on setting up Detour (user request, Nov 8 2026): separate profiles, each with its own cookies, history and extensions, and spaces for areas of life (Work, Personal, Banking, …), e.g. a Banking profile with no extensions; Link Routes sending bank and work domains to their spaces; Quarantine as the Default (or per app) for links from other apps; the Safari user agent in Settings › Profiles (after TASK-216: Safari's exact string, no Detour token, frozen macOS version); content blocker lists (EasyPrivacy); Private windows (data cleared when the last one closes, since 0.4.1) and which extensions are allowed in Private; search suggestions off. Says plainly what Detour does not hide (IP address, fonts, hardware, time zone: see wiki/platform/webkit-privacy-protections.md) and links Quarantine, Private Browsing, Profiles, Spaces, Link Routes and Content Blocker guides. Facts checked against the release that ships TASK-216; held on a website branch until then (as with next-release for 0.4.1). Media capture to schedule with the TASK-311 re-capture: Settings › Profiles with Work/Personal/Banking profiles and the User Agent set to Safari; a sidebar with those spaces; Settings › Links with bank-domain routes and Quarantine as the Default; a link from Mail opening in a quarantine window (loop); the content blocker lists.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 /features/privacy/ (or a fitting path) follows the guide template: H1 + lede, media, step-by-step setup, what Detour does and does not protect, FAQ, related features, download
- [x] #2 Every setting name, menu path and default is checked against the release build that ships TASK-216
- [ ] #3 Media captured in an isolated DETOUR_DATA_DIR with seeded profiles, spaces and routes (no personal data), meeting the TASK-110 size and reduced-motion rules, at most 1800 px wide
- [x] #4 Linked from the features index, the Quarantine, Private Browsing and Profiles pages, and the home page if it fits; in the sitemap
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026: draft written on website branch privacy-guide (worktree ../dw-privacy; 61e04eb + c13288c, extensions' background work line), /features/privacy/, linked from the features index, Quarantine, Private Browsing and Profiles; builds, in the sitemap; no media yet (captures per the shot list). Held for the release that ships TASK-216. Not yet checked at desktop/390 px in a browser.

Released with Detour 0.4.2 (build 10, tag v0.4.2, app 5fbad23) on Nov 8 2026; website main 7b78e8c deployed and checked live. /features/privacy/ live (200), linked from the features index, Quarantine, Private Browsing and Profiles. Facts checked against the released code (agent report + lead edits for TASK-216/312). Open: #3 media (shot list in the description; schedule with TASK-311's Link Routes re-capture) and a look at desktop and 390 px widths.
<!-- SECTION:NOTES:END -->
