---
type: Feature
title: Quick Detour title bar
description: "The Quick Detour window's title bar: the back button, the address capsule (profile pill, host, pinned extensions, Copy Link, site settings) that opens the palette, drags the window and fills with load progress, and the Open in button."
tags: [window, site-settings, extensions]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:00:09Z }
sources:
  - id: task-210
    resource: backlog:TASK-210
    title: "Quick Detour: page settings menu, draggable bar, Open In and palette text"
  - id: task-213
    resource: backlog:TASK-213
    title: "Site settings popover: host header, separate site switches, none in Quick Detour"
  - id: task-299
    resource: backlog:TASK-299
    title: "Address bars: the sidebar's and Quick Detour's icons in one order"
  - id: task-322
    resource: backlog:TASK-322
    title: "Quick Detour: back button, the whole address capsule opens the palette, and a loading indicator"
  - id: task-323
    resource: backlog:TASK-323
    title: "HoverButton: no hover background on a disabled button"
  - id: title-bar
    resource: ../../Detour/Browser/QuickDetour/QuickDetourTitleBar.swift
    title: QuickDetourTitleBar.swift
  - id: site-settings
    resource: ../../Detour/Browser/Sidebar/SettingsPopoverViewController.swift
    title: SettingsPopoverViewController.swift (forPage, the builder both windows use)
  - id: reference
    resource: ../../docs/little-window/arc-little-arc.png
    title: Arc's Little Arc, the visual reference
  - id: harness-322
    resource: ../../docs/harness/task322-harness.patch
    title: TASK-322 runtime harness and its results
---

The bar across the top of a [Quick Detour window](./quick-detour-window.md), after Arc's Little Arc (the reference image). It is the window's only chrome: there is no sidebar.

# Layout

The title bar, after the reference image, holds the traffic lights, a
**back button** (TASK-322), an address capsule with the **profile pill**
([its own page](./quick-detour-profile-pill.md)), the page's host in the centre, the
pinned extensions' buttons, Copy Link and the **site settings** button (the
main window's popover, [below](#the-bar-site-settings-and-handles)) at the
capsule's trailing edge, then **Open in <Space> ⌘O** at the right
([its own page](./quick-detour-open-in.md)). The
trailing icons are in the sidebar address bar's order (TASK-299, user
decision): host … extensions, Copy Link, Site Settings, with the same
tooltips and accessibility labels ("Copy Link", "Site Settings", an
extension's display name). Copy and Site Settings sit together at the
trailing edge, so they never move as extensions are pinned or unpinned;
extensions grow leftward from Copy. The bar's background, the whole
capsule apart from its buttons (since TASK-322; the host alone before) and
Open in's main part all drag the window, and a click on the capsule opens
the palette ([below](#back-the-whole-capsule-and-load-progress)). While a
page loads, the capsule fills with the load's progress.

# The bar: site settings and handles

TASK-210, the user's feedback on TASK-193.

**Site settings.** The puzzle button that listed the profile's extensions
in a menu is gone; in its place the slider button opens the main window's
site settings popover, `SettingsPopoverViewController`, built by the same
`forPage(url:blockedCount:profileID:pages:openExtension:)` the address bar
uses:[^site-settings] the page's host as its header, content blocking with
the page's blocked count, and the profile's extensions with their pin
toggles and Extension Settings…. Every switch acts on the profile the popover was
built for — the Quick Detour's (the main window's `activeSpace` profile
there, also now captured at build rather than read at click). Content
blocking takes effect per navigation, so toggling it reloads the pages
`pages` names that are on the switched site: the Quick Detour's one page;
the selected tab's split panes and Peek in the main window. The main
window's picture in picture and dev mode switches, in a section of their
own between dividers, are left out (`showsTabSwitches: false`, TASK-213):[^task-213]
they act on tab switching and on the sidebar's rows and the dev toolbar,
none of which a Quick Detour has. TASK-210 had kept them, storing the
site's setting with no effect in the window. An extension's name closes the popover and opens the
extension's popup on its pinned button, or on the settings button when it
is not pinned. Popovers on the bar use `preferredEdge: .maxY`: an `NSButton`
is flipped, so that is its bottom; TASK-193.1's `.minY` opened the pinned
extensions' popups above the button, out of the window (the settings
popover only came out below when there was no room above).

**Handles.** `QuickDetourBarButton` (the host and Open in's main part)
tracks a press itself: past 3 points of movement it hands the press to
`window.performDrag(with:)`, the original mouse-down, as `WindowDragView`
does; released on the button before that, it is a click. It accepts the
first mouse, so a background window can be dragged from it, but a first
press that does not move only brings the window forward: AppKit asks
`acceptsFirstMouse` only for a press on a window that is not key, and the
button remembers that press's timestamp, so a click on Open in to reach the
window never moves its page. The chevron, the pill and the icon buttons keep
their own clicks.

**Text.** The dropdown's other-profile items lost their "Reloads the page"
subtitle (the tooltip stays). The palette's prompt is "Search or enter a
URL" (`CommandPaletteView.placeholder`): there is no browser around it; the
main window keeps "Where do you want to go?".

# Back, the whole capsule, and load progress

TASK-322, the user's feedback of 2026-11-13.[^task-322]

**Back.** A `HoverButton` with `chevron.left` sits 76 points in, clear of
the zoom button (which ends at 72), and the capsule starts 6 points after
it. It follows the tab's `canGoBack` and calls `goBack`. It is dimmed by
hand: a tinted template image draws the same disabled as enabled, so
`setCanGoBack` sets the tint too. Disabled, it shows no hover background
(`HoverButton`, TASK-323). No forward button (Cmd+] and the mouse
button go forward) and no back-history menu: not asked for.

**The whole capsule.** `QuickDetourAddressCapsule.hitTest` hands every hit
its own controls do not take (the empty space, the lock, the gaps between
icons, the progress fill) to the host button, and the host's
`clickArea` is the capsule, so a release anywhere on it is a click. The host
was already a drag handle (TASK-210), so the capsule's empty space now drags
the window the same way: past 3 points it moves the window, released before
that it opens the palette. The pill and the icon buttons keep their presses.
The capsule keeps a hit if any view between it and the hit view is a button:
a `HoverButton` under the pointer shows a hover background, and that plain
subview is what the hit lands on; matching only the hit view's class sent a
real click on Copy Link to the palette (found at runtime, see
[AppKit gotchas](../platform/appkit-gotchas.md#hit-testing-and-mouse-events)).
The capsule lightens under the pointer (labelColor 0.06 → 0.09) to say it
is clickable.

**Load progress.** The capsule's background fills from the left with
`controlAccentColor` at 0.16, the width following the page's
`estimatedProgress`, as a sidebar row's progress bar does (Safari's
address bar does the same); the capsule clips it to its corners. The pure
rule is `QuickDetourTitleBar.displayedProgress(isLoading:estimatedProgress:)`:
nothing unless a load is in flight and below 1, and at least 0.1 while one
is, because WebKit's first estimate can lag the load starting. When the load
ends the fill fades out over 0.3 s; a generation counter stops a late fade
completion from emptying a load that began meanwhile. The window is shown,
so the sidebar's stalled-hidden-load rule (`isLoadProgressStalled`) does not
apply. On the fixture's trickling script WebKit's estimate sat at 0.5 for
the whole 10 s, so a slow page can hold half full.[^harness-322]

# Tests

Suites, counts and the runtime passes are on [Quick Detour tests and runtime checks](./quick-detour-tests.md).

# Related

- [Quick Detour](./quick-detour.md) — the hub: what the window is and the list of its pages.
- [Site settings](../architecture/site-settings.md) — the popover both windows build with `forPage`.
- [Sidebar overview](../sidebar/overview.md) — the sidebar address bar whose icon order the capsule shares.
- [AppKit gotchas](../platform/appkit-gotchas.md#hit-testing-and-mouse-events) — the hit-testing trap the capsule ran into.
- [Quick Detour Open in <Space>](./quick-detour-open-in.md) and [profile pill](./quick-detour-profile-pill.md) — the bar's two menus.
- [Quick Detour tests and runtime checks](./quick-detour-tests.md) — the suites, what was written first, and the runtime passes.

[^site-settings]: SettingsPopoverViewController.swift (forPage, the builder both windows use)
[^task-213]: Site settings popover: host header, separate site switches, none in Quick Detour
[^task-322]: Quick Detour: back button, the whole address capsule opens the palette, and a loading indicator
[^harness-322]: TASK-322 runtime harness and its results
