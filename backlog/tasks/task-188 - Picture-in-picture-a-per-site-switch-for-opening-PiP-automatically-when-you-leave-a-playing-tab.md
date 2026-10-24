---
id: TASK-188
title: >-
  Picture in picture: a per-site switch for opening PiP automatically when you
  leave a playing tab
status: To Do
assignee: []
created_date: '2026-10-24 09:21'
labels:
  - media
  - feature
dependencies:
  - TASK-187
priority: low
ordinal: 215000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the user 2026-10-24 (Arc has a per-site picture-in-picture preference).

Today Detour enters PiP automatically for every site: `selectTab` calls `BrowserTab.enterPictureInPicture()` for the tab being switched away from when it is playing audio (wiki/platform/media-and-pip.md; TASK-79 for the close-path exception). There is no way to turn this off for a site where it is unwanted (music players, video calls, a background YouTube playlist).

Add a per-site switch, stored in the per-site settings table (TASK-187, setting `pictureInPicture`, default on), shown in the faux address bar's popover next to the content blocking and dev mode switches (TASK-186.5). Off for a site: leaving one of its playing tabs does not enter PiP. Decide: whether "off" also blocks a page's own PiP request (`requestPictureInPicture()` / the video's PiP button) or only the automatic one (proposed: only the automatic one); the site key and subdomain rule (follow whatever TASK-187 settles for the other switches).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The address bar popover has a picture-in-picture switch for the current site, default on
- [ ] #2 With it off, switching away from a playing tab of that site does not enter PiP; with it on, behaviour is unchanged
- [ ] #3 Stored per profile and site in the per-site settings table; the decision on page-initiated PiP is recorded
- [ ] #4 The automatic-PiP decision is a pure rule with tests (playing / not playing / closing / site off)
<!-- AC:END -->
