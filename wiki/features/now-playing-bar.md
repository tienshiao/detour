---
type: Feature
title: Now-playing bar
description: "The media bar at the bottom of the sidebar for audio playing in a tab the user has left, in any space (modelled on Arc): favicon, Previous, Play/Pause, Next and Mute, expanding on hover to the title, artist, artwork and a dismiss button; the pure rule that decides which tab it shows, how each window evaluates it, and what the controls do."
tags: [sidebar, media, media-session, picture-in-picture, tabs, ui]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-25T08:30:00Z }
sources:
  - id: rule
    resource: ../../Detour/Browser/NowPlaying/NowPlayingRule.swift
    title: NowPlayingRule.swift (MediaPlaybackSession, NowPlayingCandidate, NowPlayingRule)
  - id: tab
    resource: ../../Detour/Browser/NowPlaying/BrowserTab+NowPlaying.swift
    title: BrowserTab+NowPlaying.swift
  - id: bridge
    resource: ../../Detour/Browser/NowPlaying/MediaSessionBridge.swift
    title: MediaSessionBridge.swift
  - id: message
    resource: ../../Detour/Browser/NowPlaying/MediaBridgeMessage.swift
    title: MediaBridgeMessage.swift
  - id: control
    resource: ../../Detour/Browser/NowPlaying/PageMediaControl.swift
    title: PageMediaControl.swift
  - id: window
    resource: ../../Detour/Browser/Window/BrowserWindowController+NowPlaying.swift
    title: BrowserWindowController+NowPlaying.swift
  - id: view
    resource: ../../Detour/Browser/Sidebar/NowPlayingBarView.swift
    title: NowPlayingBarView.swift
  - id: sidebar-vc
    resource: ../../Detour/Browser/Sidebar/TabSidebarViewController.swift
    title: TabSidebarViewController.swift (setNowPlaying)
  - id: artwork
    resource: ../../Detour/Browser/NowPlaying/MediaArtworkLoader.swift
    title: MediaArtworkLoader.swift
  - id: artwork-tests
    resource: ../../DetourTests/MediaArtworkLoaderTests.swift
    title: MediaArtworkLoaderTests.swift
  - id: page
    resource: ../../Detour/Browser/Sidebar/SpacePageView.swift
    title: SpacePageView.swift (layout keeps a list at its end)
  - id: rule-tests
    resource: ../../DetourTests/NowPlayingRuleTests.swift
    title: NowPlayingRuleTests.swift
  - id: tab-tests
    resource: ../../DetourTests/NowPlayingTabTests.swift
    title: NowPlayingTabTests.swift
  - id: message-tests
    resource: ../../DetourTests/MediaBridgeMessageTests.swift
    title: MediaBridgeMessageTests.swift
  - id: control-tests
    resource: ../../DetourTests/PageMediaControlTests.swift
    title: PageMediaControlTests.swift
  - id: harness
    resource: ../../docs/harness/task192-harness.patch
    title: TASK-192 runtime harness
  - id: ui-constants
    resource: ../../Detour/Browser/Shared/UIConstants.swift
    title: UIConstants.swift (sidebarRowHighlightInset, sidebarRowHighlightOutset)
  - id: arc
    resource: ../../docs/media-controls/arc-media-controls.png
    title: Arc's bar, compact and hovered (arc-media-controls.png, arc-media-controls-hover.png)
  - id: task-192
    resource: backlog:TASK-192
    title: "Media controls: a now-playing bar in the sidebar for media playing in a tab you have left"
---

While a tab the user has left plays audio, a glass card sits at the bottom
of the sidebar, just above the downloads/spaces/+ bar: the playing tab's
favicon, Previous, Play/Pause, Next and Mute. Hovering it grows it upward
with the title (the page's Media Session title, else the tab's), the artist
and artwork when the page provides them, and a × that dismisses it. It is
Arc's bar, minus Arc's colours.[^arc][^task-192]

# What it does

- **Which tab.** Media playing in any space — not only the window's active
  one — that this window is not showing; the most recently started if
  several. Each window decides for itself, so a tab selected (or a visible
  split pane) in this window never appears on its own bar.[^task-192]
- **Not for picture in picture.** A tab whose video went into PiP when it
  was left gets no bar: the PiP window has the controls. The bar does show
  for audio-only media, a page with no PiP-capable video, a site whose
  automatic PiP is off, and a tab whose PiP window was closed while it kept
  playing.[^task-192]
- **Private and normal never mix.** A normal window looks only at normal
  spaces (and their profiles' favourites); a Private window only at its own
  space.
- **Hides** about 1.75 s after the tab goes quiet (`NowPlayingRule.grace`,
  so a pause, resume or track change does not flicker it), and at once when
  the tab closes or sleeps.
- **Favicon:** selects the tab, switching space when it is not in the
  active one (the active space first, since a favourite shows in every space
  of its profile).
- **Play/Pause:** reflects `isPlayingAudio`. A tab the bar paused stays on
  the bar however long it is quiet, so it can be resumed there.
- **Previous/Next:** the page's own `previoustrack` / `nexttrack` Media
  Session handlers; disabled (dimmed) when the page has none — no seeking
  fallback.
- **Mute:** the whole page, iframes and Web Audio included; hidden on a
  WebKit without the private call. The sidebar row's speaker button uses the
  same path. A muted tab still counts as playing for the bar (it keeps its
  Unmute), but not as audible for sleep or automatic PiP
  ([media and PiP](../platform/media-and-pip.md)), so leaving a muted video
  tab shows the bar rather than a PiP window.
- **×:** hides the current playback run until the tab starts playing anew.

How each control reaches the page, and its limits, is in
[controlling a page's media](../platform/media-controls.md).

# How it works

## The rule

`NowPlayingRule` is pure and unit-tested.[^rule][^rule-tests]

- `MediaPlaybackSession` is one *run* of audible playback: `startedAt`, and
  `stoppedAt` (nil while audible). `next(_:isPlaying:isHeld:now:grace:)`
  folds each `isPlayingAudio` change into it: audible again within the grace
  (or at any time while the bar holds it paused) continues the run, later
  starts a new one.
- `NowPlayingCandidate` per tab: `isPrivate`, the run, `isHeld` (the bar
  paused it), `isInPictureInPicture`, `dismissedSessionStart`.
- `tabToShow(_:visibleTabIDs:windowIsPrivate:now:)` keeps live runs (audible,
  held, or quiet for less than the grace) of tabs of the window's kind that
  are not visible, not in PiP and not dismissed, and returns the latest
  `startedAt`.
- `nextExpiry(_:now:)` is when a quiet run's grace ends, so the window can
  look again then.

**Dismissal** stores the run's `startedAt` on the tab. The same run — the
page's own short pause, a track change — stays dismissed; a new run (quiet
for longer than the grace, then audible) shows again. Dismissing the newest
tab reveals the next most recent.

## The tab

`BrowserTab` keeps the run (updated from `isPlayingAudio`'s `didSet`), the
page's `MediaSessionReport`, the set of frames reporting a video in PiP,
the bar's hold and suspension flags, and the dismissal
([BrowserTab+NowPlaying.swift](../../Detour/Browser/NowPlaying/BrowserTab+NowPlaying.swift)).
Every change posts `BrowserTab.nowPlayingDidChangeNotification`. Releasing
the web view (`releaseWebView`: sleep, close, retarget) resets all of it,
so the tab leaves the bar without a grace.[^tab]

`enterPictureInPicture()` marks the tab as entering PiP before its script
runs and until a frame reports PiP, the script finds no video, or 2 s pass:
otherwise the bar would flash up for the moment between leaving a video tab
and WebKit's report.

## The window

`BrowserWindowController+NowPlaying.swift` gathers every tab the window can
switch to, builds candidates, and asks the rule; `visibleTabIDs` is the
selected tab and its split partner. It re-evaluates (coalesced to one per
run-loop turn) on any tab's notification, on every `selectedTabID` change,
from `selectTab` and `refreshSplitHostingIfNeeded`, and on a timer at
`nextExpiry`. It also subscribes to the shown tab's title and favicon and
loads the artwork through `MediaArtworkLoader` (below). It redraws the bar
only when the model changed. Bar actions arrive through
`TabSidebarDelegate.tabSidebar(_:didRequestNowPlaying:tabID:)`.[^window]

Every evaluation also lifts the bar's suspension from the tabs this window
shows (`liftMediaSuspensionFromBar`): another window's bar may have paused
a tab this one has on screen, where no selection would lift it, and a
suspended page cannot play by itself. The media stays paused but playable,
and the hold keeps the tab on the pausing window's bar.

## Artwork

The page names the artwork URL and can change it at will, and the app makes
the request, so `MediaArtworkLoader` fetches it on its own ephemeral
`URLSession` (a separate one for Private tabs, so no connection or TLS
session is shared with a normal window's fetch): no cookies sent or accepted (`httpCookieAcceptPolicy = .never`,
`httpShouldSetCookies = false`, no cookie storage), no credentials, no URL
cache. Responses over 2 MB are refused (declared length, or counted as they
arrive), as is an image whose header names a side over 4096 px; ImageIO
decodes straight to 64 px (the bar's 28 pt at 2x). A tab has at most one request: it waits 0.25 s
before starting, and a newer URL replaces a waiting one and cancels one in
flight, whose result is dropped; windows asking for the same tab's same
URL share it. Images are cached in memory for normal profiles only, never
on disk; a Private tab's are not kept. ImageIO reads no SVG, so SVG
artwork is not shown.[^artwork]

Favicons are another matter: `FaviconLoader` still fetches them on
`URLSession.shared` — the app's cookie jar and on-disk URL cache — for
Private tabs too. Out of TASK-192's scope.

## Navigation

A main-frame commit (`nowPlayingDocumentDidCommit`, from both the tab's and
the window's `didCommit`, error pages included) forgets the page's Media
Session report and its PiP frames at once. The new page's script also posts
'document', but a document no user script runs in (a PDF, a plugin
document) never would, and the bar kept the old title and an enabled Next.
The new document's messages arrive after the commit, so the clear never
wipes them; a page restored from the back-forward cache re-reports on
`pageshow`. The playback run is not touched: it follows `_isPlayingAudio`.
A same-document navigation (`pushState`) does not commit and keeps the
session.[^tab]

`selectTab` calls `nowPlayingTabWasSelected()` on the incoming tab (both
panes of a split): a page the bar suspended gets its suspension lifted while
staying paused, and the hold clears.

## The view

`NowPlayingBarView` is a `GlassContainerView` card with the rows' corner
radius (`UIConstants.defaultCornerRadius`, 6 pt). The sidebar pins its
bottom 4 pt above the bottom bar and its sides at
`UIConstants.sidebarRowHighlightInset` (10 pt): the same inset as a row's
highlight — `TabRowView.selectionRect` reads the constant, and
`TabCellView.rowHighlightRect` widens the cell by
`UIConstants.sidebarRowHighlightOutset` (6 pt) inside the source list's
16 pt cell inset — so the bar lines up with the rows. Measured on window
captures: the bar and a selected row both span the same 200 pt. Its height
is the card's (34 pt, 74 expanded), so when hover grows it by the title row
it grows upward over the bottom of the tab list, and its tracking area
grows with it.[^view][^harness]

**Layout decision:** the compact bar takes space. `setNowPlaying` animates
the page clip's bottom constraint up by the compact height plus gaps while
the bar fades in (0.22 s), and back on hide. Rows keep their positions —
only how much of the list is visible changes — so nothing jumps, and the
list's last row can always be scrolled clear of the bar. The hover
expansion overlays the list instead: it is transient, and reflowing the
list under the pointer would move what the user is aiming at. Arc does the
same.[^sidebar-vc][^arc]

**A long list scrolled to its end stays at its end.** The clip view keeps
its top offset when the page shrinks, so the bar appearing would slide the
last row behind it: measured with 30 tabs, the list's visible height went
604 → 562 pt while the offset stayed at 536 of a new maximum 578, leaving 4
of the last row's 36 pt visible. `SpacePageView.layout()` now checks
whether the list was at its end before each layout pass and, if so, scrolls
to the new end after it — every frame of the 0.22 s animation, so the last
row rides up with the list's edge. A list scrolled anywhere else, or one
short enough not to scroll, keeps its offset. When the bar hides, the clip
view already clamps to the new end. The list's bottom fade shadow is pinned
to the page's bottom, so it moves with the clip (window y 82–94 pt with the
bar, the bar's top at 78) and is shown only when rows are hidden below.
While expanded, the bar overlays the bottom rows (a hit test on the last
row's lower quarter lands on the bar) without moving them; collapsed, the
row is hit again. The 4 pt gap between the list and the bar hits the
sidebar container. A drop below the last row with the bar showing
validates (`.move`) and moves the tab to the end.[^page][^harness]

Every control has an accessibility label (and tooltip): "Go to <title>",
"Previous Track", "Play"/"Pause", "Next Track", "Mute"/"Unmute",
"Dismiss"; the card is a group labelled "Now Playing: <title>, <artist>".

# Edge cases

- **Peek:** a Peek is not a store tab, so a Peek playing behind its host
  gets no bar (it enters PiP with its host).
- **Both windows showing nothing of it:** two normal windows both show the
  bar for the same tab; dismissal is per tab, so × in one hides it in both.
- **The page pauses inside the grace:** Play then tries a Media Session
  `play` handler, else script `play()` on a paused, started element in a
  same-origin document.
- **A bar-paused tab can be slept** by the stale-tab sweep (it is not
  audible); sleeping takes it off the bar.
- **Light/dark switch while the bar is on screen:** the glass keeps the old
  appearance's material until the card is resized (an expand or collapse
  redraws it). Re-setting the glass view's corner radius or a half-point
  resize on `viewDidChangeEffectiveAppearance` did not help; recorded in the
  harness header.[^harness]
- **The fade-out's completion** hides the view; until then `hitTest` ignores
  clicks on a bar under half opacity.

# Tests

- [NowPlayingRuleTests](../../DetourTests/NowPlayingRuleTests.swift):
  sessions, grace, hold, visibility and splits, any space, most recent,
  PiP (and PiP closed), Private/normal both ways, dismissal semantics,
  expiry.
- [MediaBridgeMessageTests](../../DetourTests/MediaBridgeMessageTests.swift):
  untrusted page reports — allowlisted actions, bounded one-line text, web
  artwork only and which size is chosen, main-frame-only session messages.
- [PageMediaControlTests](../../DetourTests/PageMediaControlTests.swift):
  the guard and the bit arithmetic; this WebKit mutes and reads back.
- [NowPlayingTabTests](../../DetourTests/NowPlayingTabTests.swift): the
  bridge in a real web view (metadata and handlers reported, a handler run
  from native, the handler invisible to the page, forged reports limited to
  known actions, a new document clears, a native commit clears at once and
  the next page's session survives its commit), page mute, the run, PiP
  bookkeeping and the entry timeout.
- [MediaArtworkLoaderTests](../../DetourTests/MediaArtworkLoaderTests.swift):
  the session keeps no cookies or cache, no Cookie header from the app's
  jar, the size cap (declared and streamed), non-200, decoding bounds,
  debounce, newest wins, shared fetches, per-tab independence, memory cache
  for normal profiles only.
- [SpacePageScrollAnchorTests](../../DetourTests/SpacePageScrollAnchorTests.swift):
  a list at its end stays there when the page shrinks or grows; one
  scrolled elsewhere or at its top keeps its offset.
- [AutomaticPictureInPictureTests](../../DetourTests/AutomaticPictureInPictureTests.swift):
  a muted playing tab does not enter PiP, an unmuted one does.
- Runtime: [the TASK-192 harness](../../docs/harness/task192-harness.patch)
  with local audio, video, cross-origin-iframe and Web Audio fixtures; its
  header lists the steps and results.

# Related

- [Controlling a page's media](../platform/media-controls.md) — the WebKit calls and scripts behind each control.
- [Media and picture-in-picture](../platform/media-and-pip.md) — automatic PiP when leaving a tab, which decides who gets no bar.
- [Sidebar overview](../sidebar/overview.md) — the sidebar the bar sits in.
- [Split tabs](../tabs/split-tabs.md) — why both panes count as visible.

[^arc]: Arc's bar, compact and hovered (arc-media-controls.png, arc-media-controls-hover.png)
[^task-192]: Media controls: a now-playing bar in the sidebar for media playing in a tab you have left
[^rule]: NowPlayingRule.swift (MediaPlaybackSession, NowPlayingCandidate, NowPlayingRule)
[^rule-tests]: NowPlayingRuleTests.swift
[^tab]: BrowserTab+NowPlaying.swift
[^window]: BrowserWindowController+NowPlaying.swift
[^view]: NowPlayingBarView.swift
[^sidebar-vc]: TabSidebarViewController.swift (setNowPlaying)
[^harness]: TASK-192 runtime harness
[^artwork]: MediaArtworkLoader.swift
[^page]: SpacePageView.swift (layout keeps a list at its end)
