---
type: Feature
title: Dev toolbar
description: "The striped toolbar above a dev-mode page (TASK-186.2/.4): its controls (site settings, the URL that opens the palette, Copy URL as loaded, the capture group, Console, Network and the element picker), ordered trailing groups, the layout rule that keeps it inside the tab's container above a docked Web Inspector (only the web view's top edge moves; pure DevToolbarLayout), the corner masks, which panes show it and when they re-decide, and its effect on snapshots, the find bar, the toast and the drag strip."
tags: [dev-mode, web-inspector, layout, webkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:39:04Z }
sources:
  - id: toolbar-view
    resource: ../../Detour/Browser/DevMode/DevToolbarView.swift
    title: DevToolbarView.swift
  - id: toolbar-layout
    resource: ../../Detour/Browser/DevMode/DevToolbarLayout.swift
    title: DevToolbarLayout.swift
  - id: container
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift (WebViewContainerView, the toolbar's host)
  - id: window-toolbar
    resource: ../../Detour/Browser/Window/BrowserWindowController+DevToolbar.swift
    title: BrowserWindowController+DevToolbar.swift
  - id: window-controller
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift (copyURL, updateFindBarPlacement, toastTopInset, liveSnapshot, removeContentViews)
  - id: drag-strip
    resource: ../../Detour/Browser/Shared/WindowDragView.swift
    title: WindowDragView.swift (WindowDragPassThrough)
  - id: inspector-group
    resource: ../../Detour/Browser/DevMode/DevToolbarInspectorGroup.swift
    title: DevToolbarInspectorGroup.swift
  - id: inspector-control
    resource: ../../Detour/Browser/DevMode/WebInspectorControl.swift
    title: WebInspectorControl.swift
  - id: capture-group
    resource: ../../Detour/Browser/DevMode/DevToolbarCaptureGroup.swift
    title: DevToolbarCaptureGroup.swift
  - id: toolbar-tests
    resource: ../../DetourTests/DevToolbarLayoutTests.swift
    title: DevToolbarLayoutTests.swift
  - id: hosting-tests
    resource: ../../DetourTests/DevToolbarHostingTests.swift
    title: DevToolbarHostingTests.swift
  - id: inspector-tests
    resource: ../../DetourTests/WebInspectorControlTests.swift
    title: WebInspectorControlTests.swift
  - id: harness-1862
    resource: ../../docs/harness/task186-2-harness.patch
    title: TASK-186.2 runtime harness
  - id: harness-1864
    resource: ../../docs/harness/task186-4-harness.patch
    title: TASK-186.4 runtime harness
  - id: webkit-inspector
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Inspector/mac/WebInspectorUIProxyMac.mm
    title: WebInspectorUIProxyMac.mm (inspectedViewFrameDidChange, platformDetach)
  - id: arc-toolbar
    resource: ../../docs/dev-mode/arc-dev-toolbar.png
    title: Arc's dev toolbar (reference image)
  - id: task-186-2
    resource: backlog:TASK-186.2
    title: "Dev mode: an under-construction toolbar above the page with the URL"
  - id: task-186-4
    resource: backlog:TASK-186.4
    title: "Dev mode: toolbar buttons that toggle the Web Inspector's Console and Network tabs"
  - id: task-326
    resource: backlog:TASK-326
    title: "Copy URL: Shift-Cmd-C copies the URL with tracking parameters removed"
  - resource: ./copy-url.md
    title: Copy URL (the entry-point table and the TASK-326 decision)
  - resource: ./dev-mode.md
    title: Dev mode (DevMode.isActive, the per-site switch)
---

A 30 pt bar across the top of a [dev-mode](./dev-mode.md) tab's web content,
modelled on Arc's (faint diagonal stripes on a light bar).[^arc-toolbar] It
shows the page's URL[^task-186-2] and holds the developer's buttons: site
settings, Copy URL, two captures and three Web Inspector toggles. It lives
inside the tab's container, laid out by frames, so WebKit's docked Web
Inspector keeps working.

# What it does

Left to right: an info button (`info.circle`, "Site Settings"), the page's
URL in 11 pt monospace, truncated in the middle, and a trailing stack
holding the copy button (`link`, "Copy URL"), after a hairline the capture
group: Capture Visible Area (`camera`) and Capture Full Page
(`rectangle.expand.vertical`), and after another the Web Inspector group:
Console (`terminal`), Network (`globe`) and Select Element (`scope`), as in
Arc.[^toolbar-view][^capture-group][^inspector-group]

| Control | Does |
|---|---|
| Info | Opens the site settings popover (the one behind the address bar's slider button) under the info button, without the address bar's hover buttons showing |
| URL | Opens the command palette prefilled with the URL, navigating the tab in place (a new tab while a Peek is up), anchored at the toolbar |
| Copy | Copies the toolbar's own pane's URL as loaded, tracking parameters included (TASK-326, the user's decision: Copy URL elsewhere strips them, see [Copy URL](copy-url.md)),[^task-326] with the "URL copied" toast, through the browser window's `copyURL(_:asLoaded: true)` (the address bar's button goes through it too, without `asLoaded`, and strips) |
| Capture Visible Area | Puts a PNG of this pane's visible page on the clipboard ("Screenshot copied"); Option-click saves it to Downloads ([captures](./dev-toolbar-captures.md)) |
| Capture Full Page | The same for the whole document ("Full-page screenshot copied") |
| Console | Opens this pane's inspector on Console; closes it when it already shows Console; switches to Console when it shows another tab |
| Network | The same for the Network tab |
| Select Element | Toggles WebKit's element picker; the button is tinted with the accent colour while it is on. Picking an element opens the inspector on Elements |
| Background | Moves the window (`performDrag`), as the drag strip it sits in would |

A click on a control in the unfocused pane of a split focuses that pane
first (`makeFirstResponder` on its web view), so the palette and the popover
act on it; they stop if the pane did not take focus. The inspector buttons
and the capture buttons focus the pane too but act on their pane's own web
view either way: the call names its web view, so it cannot land on the
other pane.

**Decisions** (user, TASK-186.2):[^task-186-2] the URL opens the palette (no
inline editing); the info button opens the site popover; no toolbar inside a
Peek panel (the Peek's web view is bare, never in a container) while the
host's stays under the overlay; window fullscreen keeps the toolbar;
element (video) fullscreen needs nothing.

# How it works

## Trailing groups

Groups are added with `addTrailingGroup(_:order:)`, which puts a hairline
separator (fixed at 1 x 14 pt: with two groups an unsized separator
stretched across the bar, see [AppKit gotchas](../platform/appkit-gotchas.md#layout))
before each group and keeps them in `TrailingGroupOrder`
(`.capture` before `.inspector`), so the capture group lands between the
link and the inspector whichever is added first. Every button
carries an accessibility label; the bar is an accessibility toolbar.

## The inspector buttons

TASK-186.4.[^task-186-4] The buttons use private WebKit API kept in one
type, `WebInspectorControl`;[^inspector-control] the calls, the guards and
what was rejected are on
[Driving the Web Inspector](../platform/web-inspector-control.md).
The decision is the pure `InspectorToggle.action(isVisible:currentTab:requested:)`:
closed → `.show(tab)`, open on that tab → `.close`, open on another or an
unknown tab → `.switchTo(tab)`. `WebInspectorToggler` reads the frontend's
selected tab when the inspector is open, opens a closed one where WebKit
last had it (docked by default, on the saved side) and waits for the
frontend to load before picking Network; a second press while it is still
opening retargets that open. A button whose calls this WebKit lacks is left
out. Console and Network show no pressed state: the user can switch tabs
inside the inspector without the app hearing of it.

## Where it lives, and the layout rule

The toolbar is a subview of the tab's `WebViewContainerView`, a sibling of
the web view, laid out by frames.[^container] Nothing outside the container
knows about it: a split pane, an ownership-transfer snapshot of the
container and the PiP hold all carry it.

**Only the web view's top edge moves.** Showing the toolbar sets the web
view's height to `container.height − 30 − webView.minY`, keeping its x,
width and bottom; hiding it gives the 30 pt back. This is what makes it work
with the docked Web Inspector, which is the web view's other sibling.
WebKit re-frames the inspected web view itself whenever the inspector docks,
undocks, resizes or the container resizes, and it keeps the web view's top
(`NSMaxY`) where it was, "so banners in Safari still work"
(`inspectedViewFrameDidChange`, `platformDetach`).[^webkit-inspector] So the
toolbar behaves like a Safari banner:

- **Bottom dock:** the inspector takes the bottom; the web view's `minY`
  rises and the toolbar keeps the full width.
- **Left or right dock:** the inspector spans the container's full height
  and the web view narrows, so the toolbar follows the web view's x and
  width (it observes the web view's `frameDidChangeNotification`), never
  the container's.

The geometry is the pure `DevToolbarLayout.frames(containerBounds:webViewFrame:toolbarHeight:showsToolbar:)`
plus `toolbarFrame(containerBounds:webViewFrame:)` for the WebKit-driven
case.[^toolbar-layout] The container re-applies it in `resizeSubviews`:
autoresizing keeps the web view's margins, which holds the gap through a
window resize, but not when a container that showed the toolbar at zero
size (they are made at zero size and framed when hosted) is first sized.
A container whose page never needed the toolbar has none and is untouched,
so a non-dev tab lays out exactly as before.

**Corners.** The container rounds every subview to the pane's radius. While
the toolbar shows, it rounds only its top corners and the web view only its
bottom ones, so the two read as one card with no notch; all four come back
when it hides. The mask is in the layer's own coordinates, which AppKit
flips for `WKWebView` (a flipped view): there the bottom corners are the
`MaxY` ones. It is decided from `view.isFlipped`: the layer's
`contentsAreFlipped()` read unflipped while a split pane was being
re-hosted and rounded the page's top corners instead.[^harness-1862]

## Which panes show it

`BrowserWindowController+DevToolbar` decides, per pane this window hosts
(`hostedPaneTabs`: the selected tab, or both panes of its split, whose
containers are in this window), with `DevMode.isActive(for: tab.url,
profileID:)` for the window's profile.[^window-toolbar]

- **Claim:** `claimWebView` ends with `refreshDevToolbars()`, which decides
  every hosted pane, points its controls at this window (so whichever
  window owns the container drives it) and subscribes to each pane's
  `$url`. `removeContentViews` drops the subscriptions; a window showing a
  snapshot follows nothing.
- **Navigation:** the `$url` sink re-decides that pane, the unfocused one
  of a split included.
- **The per-site switch:** the window observes
  `SiteSettingsStore.didChangeNotification` too; for a `devMode` change on
  its profile it re-decides the hosted panes in the same turn (the switch
  is on [dev mode](./dev-mode.md#the-switch)).
- **Space or profile change:** goes through `selectTab`, hence a claim.

## Snapshots, the find bar and the toast

**Snapshots.** The handoff snapshot is of the container, so it includes the
toolbar. `liveSnapshot(for:)` (a second window showing a tab another window
hosts) now pictures the container too while it shows the toolbar; the bare
web view is 30 pt shorter and sat offset in the stand-in.

**Find bar.** It is pinned 12 pt below the content area's top, which is on
the toolbar. `updateFindBarPlacement()` moves it down by 30 pt while a
hosted pane's toolbar lies under its spot. That test is geometric, not "the
focused pane": the find bar sits over a split's left pane whichever pane is
focused, and a left-docked inspector moves the toolbar out from under it.

**Toast.** It sits at the content area's top right, over the capture and
inspector buttons when the pane there shows a toolbar; `toastTopInset()`
puts it 30 pt lower then, by the same geometric test as the find bar
(TASK-186.3, see [captures](./dev-toolbar-captures.md)).[^window-controller]

## The drag strip

The content area's top 38 pt is a `WindowDragView` over
everything, which forwards a click by calling `mouseDown` and then a
synthesized `mouseUp` on the view underneath. An `NSButton` cannot take that:
its `mouseDown` tracks the real event queue for a mouse-up the strip has
already consumed. Views that handle their own clicks adopt
`WindowDragPassThrough`, and the strip's `hitTest` returns nil over them, so
the event goes straight to the button.[^drag-strip]

# Edge cases

- A side-docked inspector stops about 66 pt below the window's top:
  WebKit intersects its frame with the window's `contentLayoutRect` (below
  the title bar). It does so with or without the toolbar.[^webkit-inspector][^harness-1862]
- The split separation and formation veneers snapshot the bare web view, so
  for their 0.22 s a dev-mode pane's card shows no toolbar.

# Tests

`DevToolbarLayoutTests` (21 tests, TASK-186.2): the pure layout with no
inspector, docked bottom, right and left, on-then-off returning the original
frame, a container resize, a web view that lost its gap, a container shorter
than the bar; and the container applying it (shown, hidden, never made, the
web view re-framed by someone else, resize, zero-size first, the corner
masks for an unflipped and a flipped web view, the label, the accessibility
labels, a trailing group).[^toolbar-tests] `DevToolbarHostingTests` (13, in a
Private window so the switch writes nothing): local and remote tabs,
navigation, switching tabs, the switch both ways, a split with one local
pane and its unfocused pane navigating, a Peek, the URL click (and focusing
the other pane first), the toast moving below a toolbar under its spot, the
copy button writing its own pane's URL to a private pasteboard
(`urlPasteboard`), and that URL keeping its tracking parameters while Copy
URL for the same tab strips them (TASK-326).[^hosting-tests]

`WebInspectorControlTests` (22, TASK-186.4): the toggle rule (closed,
same tab, other tab, unknown tab), the frontend's tab types, which buttons a
WebKit gets from the selectors it answers, a canary that this Mac's WebKit
answers all of them, the group's buttons and labels, a capture group added
later landing before it, no group without capabilities, the picker's tint,
and in a Private window the group installed once across claims and the
unfocused pane's buttons acting on that pane's web view (a recording
`webInspectorToggler`).[^inspector-tests]

The TASK-186.4 [harness](../../docs/harness/task186-4-harness.patch) pressed
the real buttons and logged the frontend's own selected tab after each:
Console from closed opened docked on Console, again closed it; Network from
closed opened on Network; Console on Network switched, Network on Network
closed; Console after the user picked Elements switched; two presses in one
turn opened on the second; a right-docked inspector closed and reopened
docked right; in a split the unfocused pane's Console docked an inspector in
that pane only; a 422 pt pane got its own inspector window. The picker
turned on and off with its tint; picking an element was not verified
(synthetic mouse events do not reach WebKit's overlay).[^harness-1864]

The TASK-186.2 [harness](../../docs/harness/task186-2-harness.patch) checked
in the running app, with `window.innerHeight` against the container: a
local tab (730 under a 30 pt bar in a 760 pt container), a remote one (760),
the same tab navigating away and back, the copy button and toast, a posted
click on the URL through the drag strip, a resize, a split with one local
pane, the info popover, the inspector docked bottom, right and left (the bar
following the web view's width, the switch toggling it while docked), the
switch, a Peek, the find bar at 42 pt, dark mode, and a second window's
snapshot lining up with the live view.[^harness-1862]

# Related

- [Dev mode](./dev-mode.md) — which pages are in dev mode, the per-site switch, the sidebar marking.
- [Dev toolbar captures](./dev-toolbar-captures.md) — the two capture buttons.
- [Driving the Web Inspector](../platform/web-inspector-control.md) — the private calls behind the inspector buttons.
- [Copy URL](./copy-url.md) — why the toolbar's link button copies the address as loaded.
- [Split tab hosting](../tabs/split-tabs-hosting.md) — the pane containers the toolbar sits in.
- [Find in page](./find-in-page.md) — the find bar that moves below the toolbar.

[^arc-toolbar]: Arc's dev toolbar (reference image)
[^task-186-2]: Dev mode: an under-construction toolbar above the page with the URL
[^toolbar-view]: DevToolbarView.swift
[^capture-group]: DevToolbarCaptureGroup.swift
[^inspector-group]: DevToolbarInspectorGroup.swift
[^task-326]: Copy URL: Shift-Cmd-C copies the URL with tracking parameters removed
[^task-186-4]: Dev mode: toolbar buttons that toggle the Web Inspector's Console and Network tabs
[^inspector-control]: WebInspectorControl.swift
[^container]: BrowserTab.swift (WebViewContainerView, the toolbar's host)
[^webkit-inspector]: WebInspectorUIProxyMac.mm (inspectedViewFrameDidChange, platformDetach)
[^toolbar-layout]: DevToolbarLayout.swift
[^harness-1862]: TASK-186.2 runtime harness
[^window-toolbar]: BrowserWindowController+DevToolbar.swift
[^window-controller]: BrowserWindowController.swift (copyURL, updateFindBarPlacement, toastTopInset, liveSnapshot, removeContentViews)
[^drag-strip]: WindowDragView.swift (WindowDragPassThrough)
[^toolbar-tests]: DevToolbarLayoutTests.swift
[^hosting-tests]: DevToolbarHostingTests.swift
[^inspector-tests]: WebInspectorControlTests.swift
[^harness-1864]: TASK-186.4 runtime harness
