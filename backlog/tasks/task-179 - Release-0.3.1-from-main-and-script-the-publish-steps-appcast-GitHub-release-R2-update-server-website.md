---
id: TASK-179
title: >-
  Release 0.3.1 from main, and script the publish steps (appcast, GitHub
  release, R2 update server, website)
status: To Do
assignee: []
created_date: '2026-10-23 02:07'
labels:
  - release
  - website
dependencies: []
priority: medium
ordinal: 202000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Cut 0.3.1 from main (59 commits of fixes since v0.3.0, Oct 2 2026) and publish it through Sparkle and the website. Publishing used to be manual after build-release.sh: generate_appcast, then uploading the DMG, deltas and appcast.xml to the R2 bucket detour-updates (custom domain updates.detourbrowser.com, found Oct 22 via wrangler), a GitHub pre-release for the website's download link, and a hand edit + wrangler deploy of ../detour-website. scripts/publish-release.sh now does those steps, rerunnable, with a --dry-run.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 0.3.1 DMG is signed, notarized and stapled, and holds version 0.3.1 build 7
- [ ] #2 https://updates.detourbrowser.com/appcast.xml lists 0.3.1 first with release notes; the DMG and deltas are served
- [ ] #3 Tag v0.3.1 and a GitHub pre-release with the DMG exist
- [ ] #4 detourbrowser.com shows v0.3.1 with working download links and size
- [ ] #5 scripts/publish-release.sh and the release wiki playbook describe the full procedure
<!-- AC:END -->
