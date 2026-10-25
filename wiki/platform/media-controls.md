---
type: Platform Quirk
title: Controlling a page's media from the app
description: "What WebKit on macOS 26.7 lets an embedder do to media playing in a page it is not showing — pause and resume (public suspend/resume, which covers iframes and Web Audio but blocks the page's own play until lifted), page mute (private _setPageMuted:, which keeps _isPlayingAudio true), Media Session handlers and metadata (no API: a page-world wrapper plus an isolated-world reader), and observing picture in picture (webkitpresentationmodechanged; _isPictureInPictureActive is always NO)."
tags: [webkit, media, media-session, picture-in-picture, private-api]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-25T08:30:00Z }
stale_after: 2027-04-01T00:00:00Z
sources:
  - id: spike
    resource: ../../docs/harness/task192-media-spike.swift
    title: TASK-192 media spike on macOS 26.7 (WebKit 21624.5.1.11.3)
  - id: wkwebview-private
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebViewPrivate.h
    title: WKWebViewPrivate.h (_setPageMuted:, _mediaMutedState, _isPictureInPictureActive, _pauseNowPlayingMediaSession:)
  - id: wkwebview-mm
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebView.mm
    title: WKWebView.mm (pauseAllMediaPlayback, setAllMediaPlaybackSuspended, _setPageMuted:, _isPictureInPictureActive)
  - id: session-manager
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/audio/MediaSessionManagerInterface.cpp
    title: MediaSessionManagerInterface.cpp (pause/suspend/resumeAllMediaPlaybackForGroup)
  - id: media-element
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebCore/html/HTMLMediaElement.cpp
    title: HTMLMediaElement.cpp (mediaState, computeCanProduceAudio, pageMutedStateDidChange)
  - id: audio-context
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebCore/Modules/webaudio/AudioContext.cpp
    title: AudioContext.cpp (pageMutedStateDidChange, mediaState)
  - id: page-proxy-cocoa
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Cocoa/WebPageProxyCocoa.mm
    title: WebPageProxyCocoa.mm (playPredominantOrNowPlayingMediaSession, pauseNowPlayingMediaSession)
  - id: testing-h
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebViewPrivateForTesting.h
    title: WKWebViewPrivateForTesting.h (_setNowPlayingMetadataObserver:, _requestActiveNowPlayingSessionInfo:)
  - id: page-media-control
    resource: ../../Detour/Browser/NowPlaying/PageMediaControl.swift
    title: PageMediaControl.swift
  - id: bridge
    resource: ../../Detour/Browser/NowPlaying/MediaSessionBridge.swift
    title: MediaSessionBridge.swift
  - id: tab-now-playing
    resource: ../../Detour/Browser/NowPlaying/BrowserTab+NowPlaying.swift
    title: BrowserTab+NowPlaying.swift
  - id: harness
    resource: ../../docs/harness/task192-harness.patch
    title: TASK-192 runtime harness
  - id: task-192
    resource: backlog:TASK-192
    title: "Media controls: a now-playing bar in the sidebar for media playing in a tab you have left"
---

The [now-playing bar](../features/now-playing-bar.md) pauses, resumes, mutes
and skips media in tabs the user is not looking at. WebKit's public API
covers part of that; the rest is one private call and a pair of user
scripts. Everything below was read in WebKit's `main` source and then
measured in a standalone `WKWebView` spike on macOS 26.7 (WebKit
21624.5.1.11.3) against local fixtures: an `<audio>` page with a Media
Session, a Web Audio oscillator, an `<audio>` in a cross-origin iframe, and a
`<video>`.[^spike]

# Behavior

## Pause and resume

| Call | Media elements | Cross-origin iframe | Web Audio | `_isPlayingAudio` | `requestMediaPlaybackState` |
|---|---|---|---|---|---|
| `setAllMediaPlaybackSuspended(true)` | paused, `pause` event fires | paused | context `interrupted` | false | `.suspended` |
| `setAllMediaPlaybackSuspended(false)` | the same elements play again | resumed | `running` | true | `.playing` |
| `pauseAllMediaPlayback` | paused | paused | context `suspended` | false | `.paused` (Web Audio: still `.playing`) |

- **Suspend and resume are a pair.** Suspension is an interruption of every
  `PlatformMediaSession` in the page's group (`beginInterruption(PlaybackSuspended)`);
  resuming ends it with `MayResumePlaying`, so exactly what was playing plays
  again — in every frame of the page's process and in Web Audio.[^session-manager][^spike]
- **A suspended page cannot play by itself.** The page's own
  `audio.play()` is rejected with `NotAllowedError` until the suspension is
  lifted.[^spike] A page that moves to its next track on its own while
  suspended fails to start it.
- **Lifting a suspension without resuming:** `pauseAllMediaPlayback` while
  suspended (it sets each session's state to restore to paused), then
  `setAllMediaPlaybackSuspended(false)`. Everything stays paused and the
  page's own `play()` resolves again.[^spike]
- **`pauseAllMediaPlayback` has no public counterpart.** Resuming after it
  needs script (`play()` on the element, `AudioContext.resume()`), which
  cannot reach a cross-origin iframe or a context the page did not expose.
  `setAllMediaPlaybackSuspended(false)` after it does nothing (the page was
  never suspended).[^spike]
- **`requestMediaPlaybackState` is coarse.** It reports `.paused` if *any*
  session is paused, and kept reporting `.playing` for a Web Audio page whose
  context `pauseAllMediaPlayback` had suspended.[^spike]
- **Media Session `play` / `pause` handlers work from native** (below) and
  leave the page in charge of its own state.

## Mute

- **Page mute is private:** `-[WKWebView _setPageMuted:]` takes a
  `_WKMediaMutedState` (`NSUInteger` options; audio is bit 0, the others mute
  camera, microphone and screen capture) and **replaces** the whole set, so
  the current value has to be read first from `_mediaMutedState`. Both answer
  `responds(to:)` on macOS 26.7.[^wkwebview-private][^spike]
- **It covers every frame and Web Audio.** Elements get it through the
  player (`player->setMuted(effectiveMuted())`), an `AudioContext` through
  its destination node (`destination().setMuted(page->isAudioMuted())`).[^media-element][^audio-context]
- **`_isPlayingAudio` stays true while page-muted** (measured for the top
  frame, the cross-origin iframe and Web Audio), because an element's
  `IsPlayingAudio` reads its own `muted`, not the page's. Script mute
  (`element.muted = true`) turns `_isPlayingAudio` off.[^media-element][^spike]
- **The page cannot see it:** `element.muted` stays false.[^spike]
- **It belongs to the web view**, not the document: it survives navigation,
  and a new web view (a woken tab) starts unmuted.

## Media Session

- **No API reports a page's handlers or metadata.** WebKit routes them to the
  system's Now Playing (MediaRemote) for the one app-wide now-playing session.
  `_setNowPlayingMetadataObserver:` and `_requestActiveNowPlayingSessionInfo:`
  are testing SPI tied to that session. `_pauseNowPlayingMediaSession:` and
  `_playPredominantOrNowPlayingMediaSession:` send a remote command to the
  page's *controls-manager video* only (`hasActiveVideoForControlsManager`),
  so they do nothing for audio.[^testing-h][^page-proxy-cocoa]
- **What works:** a page-world script wraps `MediaSession.prototype.setActionHandler`
  (and the `metadata` setters) at document start and announces each change
  with a DOM event; an isolated-world script reads `navigator.mediaSession.metadata`
  through its own wrappers (the native `MediaMetadata` is shared between
  worlds; `artwork[].src` arrives resolved to an absolute URL) and posts to a
  message handler that only that world can see. Native runs a handler by
  calling a function in the isolated world, which dispatches an event the
  page-world wrapper answers by calling the stored handler with
  `{ action }`.[^spike][^bridge]
- **DOM events cross worlds; a `CustomEvent`'s string `detail` crosses
  intact** (an object `detail` would be serialized).
- **User scripts are not subject to the page's CSP.**
- **A handler run from native can start media**: the page's `play` handler
  calling `audio.play()` resolved.[^spike]

## Picture in picture

- **`_isPictureInPictureActive` is always NO** for a video in PiP here: it
  reads the Touch Bar playback controls manager.[^wkwebview-mm][^spike]
- **`webkitpresentationmodechanged` fires synchronously** inside
  `webkitSetPresentationMode('picture-in-picture')`, with the new mode
  already set; the standard `enterpictureinpicture` follows about 0.1 s
  later. Leaving fires the mode change at once and `leavepictureinpicture`
  after the exit animation (about 0.7 s). Both routes (`webkitSetPresentationMode`
  and `requestPictureInPicture()`) fire both events.[^spike]
- **`_isPlayingAudio` stays true while a video plays in PiP.**[^spike]

# Why it matters here

The bar's play/pause and mute have to work on pages Detour knows nothing
about: a SoundCloud widget in an iframe, a Web Audio synth, a plain
`<audio>`. Its Previous and Next exist only as the page's Media Session
handlers. Its show/hide rule needs "is this tab's video in PiP", which no
WebKit property answers.

# Workaround

| Need | What Detour does |
|---|---|
| Pause from the bar | The page's Media Session `pause` handler when it has both `play` and `pause`; otherwise `setAllMediaPlaybackSuspended(true)` (`BrowserTab.togglePlayPauseFromBar`) |
| Resume from the bar | `setAllMediaPlaybackSuspended(false)` if the bar suspended it; else the page's `play` handler; else script `play()` on a paused, started element in a same-origin document |
| Let the page play again after the bar's pause | Selecting the tab runs `pauseAllMediaPlayback` then `setAllMediaPlaybackSuspended(false)` (`nowPlayingTabWasSelected`) |
| Mute (bar and sidebar speaker) | `PageMediaControl.setPageAudioMuted`, keeping the capture bits; re-applied to a woken tab's new web view; script `muted` only when the SPI is missing |
| Hide a control on a WebKit without the SPI | `PageMediaControl.canMutePage` (both selectors answer) hides the bar's mute button |
| Previous / Next | `MediaSessionBridge.invoke` runs the page's `previoustrack` / `nexttrack` handler; the button is disabled when the page has none |
| Metadata | Title, artist, album and artwork from the isolated-world reader; validated by `MediaBridgeMessage` |
| "Is the video in PiP" | The isolated script, in every frame, keeps the set of its videos in PiP from `webkitpresentationmodechanged` and reports per frame (a random token); `pagehide` reports the frame out. The tab is in PiP while any frame is, or while `enterPictureInPicture()` is waiting on its answer (up to 2 s) |

## Security model

The page writes everything the bar shows. `MediaBridgeMessage` keeps only
the four known actions, flattens text to one line of at most 200 characters,
and accepts artwork only as `http`/`https` URLs. Artwork is fetched outside
the page by `MediaArtworkLoader` on its own ephemeral session — no cookies
sent or stored, no URL cache, a 2 MB and 4096 px cap, one request per tab
with the newest URL winning after a 0.25 s debounce, memory-only cache for
normal profiles — so a page cannot make the app send the app's cookies or
fill its disk cache, nor fetch faster than it settles on a URL
([now-playing bar](../features/now-playing-bar.md#artwork)). Favicons, for
Private tabs too, still go through `URLSession.shared` (the app's cookie
jar and on-disk cache); that is outside TASK-192. The page-world half is visible to
the page: it can call or replace the wrapper, dispatch the change event
with a fake action list, or answer the invoke event itself — none of which
reaches beyond its own tab's display and its own handlers. The message
handler and the invoke function live in the `DetourMedia` content world, out
of the page's reach, and the handler drops messages from any other world.

# Limits

- **Media Session in an iframe is not read.** Only the main frame's
  session drives the bar; an embedded player that sets `navigator.mediaSession`
  in its own frame gets no Previous/Next and no metadata (play/pause and
  mute still work through suspension and page mute).
- **No seeking fallback.** A page without `previoustrack` / `nexttrack`
  gets disabled buttons, not a ±10 s seek: script cannot seek media in a
  cross-origin iframe, the glyphs promise a track change, and Arc dims them
  too.
- **A page suspended by the bar cannot start its next track by itself**
  until the user resumes it or selects the tab.
- **Pause from the bar in a page whose own player keeps state elsewhere**
  (no Media Session): the page sees ordinary `pause`/`play` events from the
  suspension, which most players follow.
- **A video in PiP inside a cross-origin iframe** is reported by that
  frame's script, but Detour's own automatic PiP never reaches such a video.
- **A video inside a shadow root is not seen entering PiP.**
  `webkitpresentationmodechanged` is not a composed event, so the
  document-level capture listener never hears a video in a shadow tree; such
  a tab counts as not in PiP and gets the bar while its PiP window is open.
- **An iframe removed while its video is in PiP** may never deliver the
  report its script posts on the way out (the frame is torn down), so the
  tab can stay marked in PiP — and off the bar — until the main frame
  navigates, whose commit clears every frame's PiP state.
- **The main-frame commit clears the Media Session report**, not the
  'document' message alone: a PDF or plugin document runs no user script
  and would otherwise keep the old page's title and Next.

# Related

- [Now-playing bar](../features/now-playing-bar.md) — the feature built on this.
- [Media and picture-in-picture](./media-and-pip.md) — automatic PiP on leaving a tab, and `_isPlayingAudio`.
- [Driving the Web Inspector](./web-inspector-control.md) — the same pattern of guarding private calls in one type.
- [Favicons](../features/favicons.md) — the loader the artwork reuses, and the other private-content-world bridge.
- [WebKit source lookup](./webkit-source-lookup.md) — how the sources above were read.

[^spike]: TASK-192 media spike on macOS 26.7 (WebKit 21624.5.1.11.3)
[^wkwebview-private]: WKWebViewPrivate.h (_setPageMuted:, _mediaMutedState, _isPictureInPictureActive, _pauseNowPlayingMediaSession:)
[^wkwebview-mm]: WKWebView.mm (pauseAllMediaPlayback, setAllMediaPlaybackSuspended, _setPageMuted:, _isPictureInPictureActive)
[^session-manager]: MediaSessionManagerInterface.cpp (pause/suspend/resumeAllMediaPlaybackForGroup)
[^media-element]: HTMLMediaElement.cpp (mediaState, computeCanProduceAudio, pageMutedStateDidChange)
[^audio-context]: AudioContext.cpp (pageMutedStateDidChange, mediaState)
[^page-proxy-cocoa]: WebPageProxyCocoa.mm (playPredominantOrNowPlayingMediaSession, pauseNowPlayingMediaSession)
[^testing-h]: WKWebViewPrivateForTesting.h (_setNowPlayingMetadataObserver:, _requestActiveNowPlayingSessionInfo:)
[^bridge]: MediaSessionBridge.swift
