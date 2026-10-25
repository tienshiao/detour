---
id: TASK-192
title: >-
  Media controls: a now-playing bar in the sidebar for media playing in a tab
  you have left
status: Done
assignee:
  - '@claude'
created_date: '2026-10-24 10:04'
updated_date: '2026-10-25 08:59'
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
- [x] #1 With media playing in a tab you have left, the sidebar shows the bar with favicon, previous, play/pause, next and mute; it hides when playback stops or the tab closes
- [x] #2 Clicking the favicon goes to the playing tab; play/pause and mute work for top-level media, iframes and Web Audio (or the limits are recorded)
- [x] #3 Previous/next use the page's Media Session handlers when present, with the fallback for other pages decided and recorded
- [x] #4 Hover expands the bar to show the title (and Media Session metadata when present) and a close button that dismisses it
- [x] #5 Control paths researched and recorded in the wiki (platform page), private API guarded; the show/hide rule is a pure function with tests; checked at runtime with a local media fixture
- [x] #6 No bar for a tab whose video entered picture in picture when it was left; the bar shows for playing tabs that did not (audio-only, no PiP-capable video, automatic PiP off for the site, PiP window closed)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-24 (user): in Arc the bar does not show up for YouTube. Likely reason: leaving a playing video tab puts the video into picture in picture, whose own window has the controls; the bar is for media that stays in the tab (audio such as SoundCloud, as in the hover screenshot).

Resolves the PiP interplay question: no bar for a tab whose video went into PiP when it was left. The bar does show for a playing tab that did not enter PiP: audio-only media, a page with no PiP-capable video, or a site with automatic PiP turned off (TASK-188). If the PiP window is closed while the tab keeps playing, the bar appears. Confirm against Arc with a YouTube tab whose PiP is closed, and with YouTube Music (audio-first) if available.

Decision (user, 2026-10-24): the bar shows for media playing in any space, not only the window's active space; clicking the favicon switches space and selects the tab. Planning choices: a normal window never shows a Private window's media and vice versa; each window decides for itself (a tab selected or a visible split pane in that window is excluded); if several tabs play, the most recently started one.

Built (2026-10-24/25, Opus subagents; resumed once after a session restart). Research (macOS 26.7, WebKit 21624.5.1.11.3; wiki/platform/media-controls.md, spike docs/harness/task192-media-spike.swift): setAllMediaPlaybackSuspended pauses/resumes everything incl. cross-origin iframes and Web Audio (page play() rejected while suspended; pauseAllMediaPlayback then unsuspend lifts it without resuming); _setPageMuted: (_WKMediaMutedState bitmask, read _mediaMutedState first) covers iframes and Web Audio and keeps _isPlayingAudio true; no WebKit API reports Media Session handlers/metadata, so a page-world wrapper plus an isolated-world reader posts to a handler only that world sees (4 actions, one-line text <= 200 chars, http(s) artwork; a page can only misreport its own tab); _isPictureInPictureActive is always NO, so a per-frame webkitpresentationmodechanged script reports PiP with a 2 s entering hold. Previous/next disabled without Media Session handlers (no seek fallback).

Rule: pure NowPlayingRule.tabToShow(_:visibleTabIDs:windowIsPrivate:now:) over NowPlayingCandidate(tabID, isPrivate, session, isHeld, isInPictureInPicture, dismissedSessionStart): the most recently started live run not visible in this window, not in PiP, same Private/normal kind, not dismissed; MediaPlaybackSession with a 1.75 s grace; dismissal (x) is per run (a short pause stays dismissed, a new run shows again), per tab across windows. Decisions: the compact bar takes space (the list area animates shorter; a list scrolled to its end stays at its end), hover expansion overlays; play/pause uses the page's Media Session play/pause when it has both, else suspend/resume; selecting the tab or showing it in another window lifts the bar's suspension (paused, not suspended); the sidebar speaker uses page mute too; bar width and radius match the row highlight (shared UIConstants.sidebarRowHighlightInset/Outset, defaultCornerRadius).

Review fixes (two passes): BrowserTab.isAudible (playing and not muted) for stale-tab sleep, sleep()'s guard, automatic PiP and the GPU recycler (page mute keeps _isPlayingAudio true; muted tabs behave as under the old script mute; a second review argued for isPlayingAudio in the recycler, rejected: a muted looping tab would hold it off until IOSurfaces run out, TASK-104); sleep pauses a muted playing tab first; the KVO stale-source guard; bar redraw only on change; artwork via MediaArtworkLoader (ephemeral sessions, separate for Private, no cookies, no URL cache, 2 MB cap, 4096 px header limit, decoded at 64 px, 0.25 s debounce, one fetch per tab, in-memory cache for normal profiles only); the Media Session report cleared at the native main-frame commit. Skipped: shadow-root and removed-iframe PiP detection (recorded limits), retrying a failed artwork URL, the wake-time mute fallback on a WebKit without _setPageMuted: (pre-existing), FaviconLoader's shared session for Private favicons (pre-existing, noted in the wiki).

TDD: NowPlayingRuleTests etc. red 34 of 42 failing, green; review-round tests written first (artwork loader 11, commit clearing 2, muted PiP 2, scroll anchor 4, muted sleep 1, stale KVO 1, lifted suspension 1). Tests: 381/381 (SpacePageScrollAnchor 4, MediaArtworkLoader 11, NowPlayingRule 27, MediaBridgeMessage 11, PageMediaControl 4, NowPlayingTab 20, SleepShowBudget 16, AutomaticPictureInPicture 13, TabStore 40, SidebarLayout 41, SplitTab 63, SidebarDragDrop 39, FaviconLinkBridge 8, BrowserTabWake 7, DevMode 42, GPUProcessRecyclePolicy 14, GPUProcessOrphanPolicy 21).

Runtime (docs/harness/task192-harness.patch; final runs 19-20 on the final code, screen unlocked throughout, identical behaviour): Media Session page shows title/artist/artwork within 0.03 s of leaving, prev/next run the page's handlers, pause/play/mute work; a video tab entering PiP shows no bar, exiting PiP shows it; automatic PiP off shows it; iframe and Web Audio pause/resume/mute; no-Media-Session page has prev/next disabled; another space's tab shows and the favicon switches space; hover expands, x dismisses until a new run; stop hides after the grace, close hides at once; a Private window shows only its own media; artwork requests carry no cookie and never enter URLCache, Private and normal use distinct sessions, a burst collapses, a 3.7 MB image is refused; navigating away clears the title at the commit; a muted video tab doesn't enter PiP; pausing from another window's bar leaves the video paused (not frozen) and the page's play() works; a muted playing tab is paused before sleep releases its web view; a 30-tab list scrolled to its end stays at its end as the bar appears, fade shadow correct, a drop at the end still lands. Not verified: closing the real PiP window with its own x (covered by script exit and the rule tests), a real pointer hover and drag, glass after a light/dark switch while the bar is on screen (stays light until the bar resizes; recorded).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Now-playing bar at the bottom of the sidebar for media playing in a tab you have left, in any space: favicon (goes to the tab), previous/next via the page's Media Session, play/pause and page mute covering iframes and Web Audio; hover shows title, artist and artwork with a dismiss button. No bar for a tab whose video went into picture in picture. Artwork fetched without cookies or disk cache; muted tabs sleep and skip PiP as before. 381 tests pass; final runtime harness clean.
<!-- SECTION:FINAL_SUMMARY:END -->
