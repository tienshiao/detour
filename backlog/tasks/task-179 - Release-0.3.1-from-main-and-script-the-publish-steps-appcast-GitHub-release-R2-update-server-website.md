---
id: TASK-179
title: >-
  Release 0.3.1 from main, and script the publish steps (appcast, GitHub
  release, R2 update server, website)
status: Done
assignee: []
created_date: '2026-10-23 02:07'
updated_date: '2026-10-23 02:18'
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
- [x] #1 0.3.1 DMG is signed, notarized and stapled, and holds version 0.3.1 build 7
- [x] #2 https://updates.detourbrowser.com/appcast.xml lists 0.3.1 first with release notes; the DMG and deltas are served
- [x] #3 Tag v0.3.1 and a GitHub pre-release with the DMG exist
- [x] #4 detourbrowser.com shows v0.3.1 with working download links and size
- [x] #5 scripts/publish-release.sh and the release wiki playbook describe the full procedure
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-22: build-release.sh 0.3.1 → build 7, notarization 2dff0271-e576-428f-b1c0-781f8ea42ee7 Accepted, stapled. publish-release.sh --dry-run passed (DMG app 0.3.1 (7), signature valid; appcast first item 0.3.1 with 5 deltas 7-2..7-6; generate_appcast dropped the 0.2.1 item and moved 2 old files to build/old_updates). Fixed one thing it showed: the notes heading's apostrophe was escaped (687c79a). Real run: Release commit 54ab99f + tag v0.3.1 pushed; GitHub pre-release v0.3.1; R2 uploads (DMG, 5 deltas, appcast last); website commit 08ee5cf pushed and deployed (version 8b675de3). Checked live with curl: appcast lists 0.3.1 first with notes, Detour7-6.delta served, GitHub DMG 200 at 11139826 bytes, detourbrowser.com shows v0.3.1 · 10.62 MB. Not checked: an actual Sparkle update from an installed 0.3.0 (Check for Updates… in a normal run). No app code changed, so no tests or /verify were run; the release is main at 5ff14db + the version bump.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Released 0.3.1 (build 7) from main through Sparkle (R2 bucket detour-updates behind updates.detourbrowser.com), a GitHub pre-release and the website. scripts/publish-release.sh now automates everything after build-release.sh (rerunnable, --dry-run); the release wiki playbook documents where each artifact goes. Verified live with curl; an in-app Sparkle update from 0.3.0 was not tried.
<!-- SECTION:FINAL_SUMMARY:END -->
