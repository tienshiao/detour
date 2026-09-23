---
id: TASK-110
title: >-
  Website: replace the HTML feature mockups with real screenshots and loops; add
  Split Tabs and Favorites
status: In Progress
assignee:
  - '@claude'
created_date: '2026-09-23 07:52'
updated_date: '2026-09-23 08:43'
labels:
  - website
dependencies: []
priority: medium
ordinal: 110000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
detour-website (../detour-website, separate repo): the middle feature sections (Spaces, Pinned Tabs & Folders, Profiles) render hand-built HTML mockups. Replace them with crops of real Detour screenshots, montages or short MP4 loops, and add sections for Split Tabs and Favorites (both shipped since v0.1.0 but absent from the site). Decisions (user, Sep 23 2026): staged demo profile in an isolated data dir with public pages (no personal data); motion as <video autoplay muted loop playsinline> MP4 with a poster still; all five sections. Capture: screencapture now works for this shell host (Screen Recording granted); drive the demo app in-process with a temporary env-gated harness and record with screencapture -l / -v, encode with ffmpeg. Unreleased features (tab switching, History page, Private extension opt-in, external-app confirm) wait for the next release (separate task).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Staged demo profile: Spaces/Profiles/pinned folders/favourites/split seeded reproducibly in an isolated data dir, public pages only
- [x] #2 Spaces, Pinned Tabs & Folders and Profiles sections use real captures (still, montage or MP4 loop) instead of HTML mockups
- [x] #3 New Split Tabs and Favorites sections with copy and real captures
- [ ] #4 Loops are muted/autoplay/looping with a poster, respect prefers-reduced-motion, and stay small (target < 1.5 MB each); images have alt text and fixed dimensions
- [ ] #5 Page checked in a browser at desktop and phone widths
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Sep 23 2026: 2x captures via a temporary virtual display (CGVirtualDisplay) + in-process DemoStage harness (kit saved in docs/task-110/, not compiled into Detour). Site (uncommitted in ../detour-website): Spaces loop (644 KB), Pinned & Folders loop (187 KB), Favorites loop (238 KB), Split Tabs still (147 KB WebP), Profiles = two list crops from Settings (Spaces->Profile, Profiles) side by side in the card. Loops play only in view via IntersectionObserver, never with prefers-reduced-motion (poster shown). Checked in Chrome at 1440 wide and in a 390 px iframe (no horizontal overflow; media 350 px wide). Open: Profiles card is small/sparse; Spaces and Pinned loops open on the same Work+GitHub frame; captures come from main, so the Profiles pane shows the unreleased External apps row only if the crop includes it (current crops don't).

Fixed: the three loops had a ~9 pt dark strip on the left (virtual-display background + a neighbouring window) because the recording region came from the requested window frame, not the live one. Re-encoded with a 20 px left crop (spaces/pinned 1100x1360, favorites 1500x880; width attrs updated). Future captures: take the region from wins <pid> (docs/task-110/README.md).

Re-recorded per user feedback (corners lacked concentricity with the CSS 18px radius): whole-window captures with native corners + shadow over a virtual-display wallpaper of #F7F2EA, page adds no framing. Spaces 808 KB, Pinned 195 KB, Favorites 419 KB, Split still 205 KB (WebP with alpha shadow). Loop background decodes to 248,241,234 vs page 247,242,234 (tone curve in encode.sh). The old dark strip was the Dock on the virtual display. Details in docs/task-110/README.md.

Kit fix: the wallpaper command replaced the user's Aerial on every display/Space (restored from the store's untouched entries). demo.sh wallpaper now snapshots the store first, the harness refuses without the snapshot, demo.sh wallpaper-restore restores it.
<!-- SECTION:NOTES:END -->
