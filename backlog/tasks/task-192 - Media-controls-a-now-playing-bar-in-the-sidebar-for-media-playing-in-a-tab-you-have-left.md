---
id: TASK-192
title: >-
  Media controls: a now-playing bar in the sidebar for media playing in a tab
  you have left
status: To Do
assignee: []
created_date: '2026-10-24 10:04'
updated_date: '2026-10-24 10:05'
labels:
  - media
  - sidebar
  - feature
dependencies: []
priority: medium
ordinal: 223000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the user 2026-10-24, modelled on Arc (docs/media-controls/arc-media-controls.png, docs/media-controls/arc-media-controls-hover.png).

**What Arc does.** While a tab other than the one you are looking at plays media, a compact bar sits at the bottom of the sidebar: the playing tab's favicon (click: go to that tab), previous, play/pause, next, and mute. Hovering the bar expands it with the page/track title and a close (×) button that dismisses the bar.

**What Detour has.** `BrowserTab.isPlayingAudio` (KVO on the private `_isPlayingAudio`) drives the row's speaker button; `toggleMute()` sets `muted` on the page's `<video>`/`<audio>` elements by script (misses cross-origin iframes and Web Audio); `pauseAllMediaPlayback` is used on the sleep/close paths. Leaving a playing tab enters picture in picture automatically (wiki/platform/media-and-pip.md; per-site switch in TASK-188).

**Proposed.**
- Show the bar when a tab in the window's active space (decide: or any space) is playing and is not the selected tab or a visible split pane; the most recently started one if several; it disappears when playback stops (with a short grace so pause/resume does not flicker) or the tab closes.
- Controls: favicon → select the tab (switching space if needed); play/pause; previous/next; mute; hover expands to title (+ artist/artwork from the page's Media Session metadata when present) and ×.
- Control paths to research and record (WebKit source + a spike): play/pause via the public `requestMediaPlaybackState` / `pauseAllMediaPlayback` / `setAllMediaPlaybackSuspended` vs resuming by script; mute via the private `_setPageMuted:` (covers iframes and Web Audio) vs the current script; previous/next and metadata via the page's `navigator.mediaSession` action handlers and `metadata` (needs a page-world user script to observe `setActionHandler`, or WebKit's own Media Session plumbing); fallback for pages without Media Session (seek -10 s/+10 s, or disable the buttons).
- Guard every private selector so a WebKit change hides a control instead of crashing.
- Interplay with automatic PiP: a video tab you leave goes into PiP today; decide whether the bar also shows for it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 With media playing in a tab you have left, the sidebar shows the bar with favicon, previous, play/pause, next and mute; it hides when playback stops or the tab closes
- [ ] #2 Clicking the favicon goes to the playing tab; play/pause and mute work for top-level media, iframes and Web Audio (or the limits are recorded)
- [ ] #3 Previous/next use the page's Media Session handlers when present, with the fallback for other pages decided and recorded
- [ ] #4 Hover expands the bar to show the title (and Media Session metadata when present) and a close button that dismisses it
- [ ] #5 Control paths researched and recorded in the wiki (platform page), private API guarded; the show/hide rule is a pure function with tests; checked at runtime with a local media fixture
- [ ] #6 No bar for a tab whose video entered picture in picture when it was left; the bar shows for playing tabs that did not (audio-only, no PiP-capable video, automatic PiP off for the site, PiP window closed)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-24 (user): in Arc the bar does not show up for YouTube. Likely reason: leaving a playing video tab puts the video into picture in picture, whose own window has the controls; the bar is for media that stays in the tab (audio such as SoundCloud, as in the hover screenshot).

Resolves the PiP interplay question: no bar for a tab whose video went into PiP when it was left. The bar does show for a playing tab that did not enter PiP: audio-only media, a page with no PiP-capable video, or a site with automatic PiP turned off (TASK-188). If the PiP window is closed while the tab keeps playing, the bar appears. Confirm against Arc with a YouTube tab whose PiP is closed, and with YouTube Music (audio-first) if available.
<!-- SECTION:NOTES:END -->
