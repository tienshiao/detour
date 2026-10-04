---
type: Platform Quirk
title: AppKit gotchas
description: A collection of AppKit behaviours that cost debugging time in Detour — first responder and key-view loop, split and stack view layout, hit testing, table views under a drag session, popovers — each with where it bit and what to do instead.
tags: [appkit, platform, focus, layout, drag-and-drop, hit-testing]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T19:22:07Z }
stale_after: 2027-04-01T00:00:00Z
sources:
  - id: task-132-8
    resource: backlog:TASK-132.8
    title: Host an extension's per-tab side panel beside the tab's content
  - id: window
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift
  - id: sidebar-vc
    resource: ../../Detour/Browser/Sidebar/TabSidebarViewController.swift
    title: TabSidebarViewController.swift
  - id: components
    resource: ../../Detour/Browser/Sidebar/SidebarComponents.swift
    title: SidebarComponents.swift
  - id: drag-view
    resource: ../../Detour/Browser/Shared/WindowDragView.swift
    title: WindowDragView.swift
  - id: drop-zone
    resource: ../../Detour/Browser/Window/SplitDropZoneView.swift
    title: SplitDropZoneView.swift
  - id: ext-settings
    resource: ../../Detour/Browser/Settings/ExtensionsSettingsViewController.swift
    title: ExtensionsSettingsViewController.swift
  - id: app-delegate
    resource: ../../Detour/App/AppDelegate.swift
    title: AppDelegate.swift (menuHasKeyEquivalent)
  - id: design
    resource: ../../docs/split-tabs-design.md
    title: Split tabs design (sections 5 and 11)
  - id: commit-b9ef265
    resource: commit:b9ef265
    title: "Sidebar: ID-based drag payloads, pure drop resolver, drag fixes"
  - id: task-39
    resource: backlog:TASK-39
    title: Collapsing the sidebar by dragging its divider leaves Toggle Sidebar out of sync
  - id: task-56
    resource: backlog:TASK-56
    title: Implement menuHasKeyEquivalent so key presses stop rebuilding the Spaces, Extensions and Develop menus
  - id: task-76
    resource: backlog:TASK-76
    title: Keys a web page declines reach the end of the responder chain and play the unhandled-key beep
  - id: task-77
    resource: backlog:TASK-77
    title: Keys the extension popup page declines still play the unhandled-key beep
  - id: task-78
    resource: backlog:TASK-78
    title: After Cmd+L and Return the page does not regain keyboard focus
  - id: task-113
    resource: backlog:TASK-113
    title: Check for and install extension updates
  - id: task-126
    resource: backlog:TASK-126
    title: The Downloads button's left and bottom edges do not respond to clicks
  - id: task-127
    resource: backlog:TASK-127
    title: With auto-hide on, the downloads popover disappears when the sidebar hides
  - id: task-128
    resource: backlog:TASK-128
    title: On launch the sidebar's hidden Search Archive field holds keyboard focus instead of the page
  - id: task-129
    resource: backlog:TASK-129
    title: Favorite drop hint without a layout shift, and drops that land from the release point
  - id: task-130
    resource: backlog:TASK-130
    title: Keyboard focus stays behind on a tab list whose page has slid off screen
  - id: task-131
    resource: backlog:TASK-131
    title: A focused tab list loses keyboard focus when the space list changes
  - id: notes-keyloop
    resource: "Agent session notes, 2026-10-02 (not in the repository)"
    title: Key-view loop probe findings
  - id: notes-hittest
    resource: "Agent session notes, 2026-10-01 (not in the repository)"
    title: Hit-test and resize-region probe findings
  - id: notes-harness
    resource: "Agent session notes, 2026-07 to 2026-09 (not in the repository)"
    title: Runtime debug harness notes (zero-width split pane root cause)
  - id: notes-inprocess
    resource: "Agent session notes, 2026-09-19 (not in the repository)"
    title: In-process UI verification notes
---

# Behavior

These are things AppKit does that its documentation does not make obvious,
collected from bugs and probes in this project. Each row gives the
behaviour, where Detour met it, and what the code does instead. Several were
measured on macOS 26; re-check an entry before relying on it after a major
macOS update. WebKit's counterparts live on their own pages, listed under
Related.

# First responder and the keyboard

| Behavior | Where it bit | Do instead |
|---|---|---|
| `NSWindow.makeFirstResponder(view)` does **not** consult `acceptsFirstResponder`. It also returns `true` when the view's `becomeFirstResponder` declines — the window itself becomes first responder.[^task-130][^notes-keyloop] | An off-screen sidebar list gated only with `acceptsFirstResponder` could still be focused programmatically (TASK-130) | Override `becomeFirstResponder` as well (`FocusGatedTableView`). In tests assert on `window.firstResponder`, never on the return value |
| The key-view loop is built **once**, when the window is first shown. Views created later have `nextKeyView == nil`.[^notes-keyloop] | A review asserted that Tab from a page reached off-screen sidebar controls. Measured: it cannot — web views and space-page tables are not in the loop (TASK-130) | Measure with the key-view probe ([UI probes](../playbooks/ui-probes.md)) before "fixing" Tab order. Gate focus by state, not by editing the loop |
| With no `initialFirstResponder`, AppKit focuses the window's first key view the first time the window is shown — even a window that is not key.[^task-128][^notes-hittest] | The off-screen archive search field took focus at launch and swallowed typing (TASK-128) | `showWindow` override hands focus to the page once ([keyboard focus](../sidebar/keyboard-focus.md)) |
| Removing the first-responder view from the window leaves the **window** as first responder. Nothing is focused and keys go nowhere.[^task-131] | Dismissing the command palette (TASK-78); rebuilding sidebar pages (TASK-131); switching away from a tab | Hand focus on explicitly: `restoreWebContentFocus()`, or carry it to the replacement view |
| `canBecomeKeyView` is false for `NSScrollView` / `NSClipView` and, with Full Keyboard Access off, for buttons. Full Keyboard Access cannot be forced for one process: the `-AppleKeyboardUIMode 2` launch argument and swizzling `isFullKeyboardAccessEnabled` both had no effect.[^notes-keyloop] | Full Keyboard Access behaviour of the sidebar is unmeasured | Gate buttons with `refusesFirstResponder` anyway; say "unmeasured" in notes |
| The last responder's `keyDown` calls `noResponderFor(keyDown:)`, which is `NSBeep()`. `WKWebView` re-dispatches every key the page declines up the chain, so each one beeped: arrows at a scroll limit, letters with no field focused, YouTube hotkeys with the player unfocused.[^task-76] | TASK-76 | `BrowserWindowController.keyDown` returns without calling `super` when `keyWasDeclinedByWebContent(firstResponder:)` — the first responder is a `WKWebView` or inside one. Native first responders still fall through and beep. `noResponderFor` beeps only for `keyDown:`; WebKit's editor-command replay is already silenced by its own `WKResponderChainSink` |
| A popover's window has no window controller, so its responder chain ends at the popover window itself: web view → content view controller → popover window → beep. This is TASK-77's analysis from the code; which object receives the fall-through has not been confirmed at runtime.[^task-77] | Extension popups: keys the popup page declines still beep. `ExtensionPopoverController` has no key handling. An override of `noResponderFor` on the view controller would not be reached | Confirm the terminating responder first (a breakpoint on `NSBeep`), then end the chain there with `keyWasDeclinedByWebContent` |
| When a page focuses an element (an `autofocus` field, `focus()`), WebKit's web process sends `MakeFirstResponder` and the `WKWebView` makes itself first responder — with no user input, and for a web view that is merely on screen. A mouse press in the page asks the same way.[^task-132-8] | An extension side panel took the keys from the tab as soon as its page loaded; a focus test failed 4 runs in 6 (TASK-132.8) | For a web view that must not take focus on its own, `_setShouldSuppressFirstResponderChanges:` (SPI, guard with `responds(to:)`), and take first responder in `mouseDown` yourself, since the suppression covers clicks too (`ExtensionSidePanelWebView`) |
| Esc reaches a responder as a raw `keyDown` or as `cancelOperation(_:)`, depending on how AppKit interprets the event. | Esc-closes-Peek | Override both |
| An `NSMenuDelegate` that does not implement `menuHasKeyEquivalent` gets `menuNeedsUpdate` on **every** key-equivalent dispatch. Returning `false` from it is not a veto (AppKit scans the existing items itself); returning `true` is trusted with no validation.[^task-56] | Spaces and Extensions menus were rebuilt on every Cmd+key press | `MenuKeyEquivalentMatcher`; see [app shell](../architecture/app-shell.md) |

# Layout

| Behavior | Where it bit | Do instead |
|---|---|---|
| `NSSplitView.setPosition(_:ofDividerAt:)` resizes the divider's two neighbours **from their current frames**, preserving their far edges. It does not re-tile. A pane carrying a stale frame from an earlier hosting collapses to zero width and nothing repairs it until the window resizes.[^notes-harness] | A split re-formed with a pane on the other side showed a dead white half (the "zero-width pane" bug) | Frame both panes explicitly, then call `setPosition` (`applySplitFraction`, using `splitPaneRects`). `splitViewDidResizeSubviews` self-repairs with `panesAreMistiled` rather than committing broken geometry as the new fraction |
| `NSSplitView` overwrites its panes' autoresizing masks while tiling. | A web view container returned to single hosting kept a fixed size instead of following window resizes | `resetSplitPaneChrome` restores `[.width, .height]` |
| Auto Layout constraints on a `WKWebView`'s container break the docked Web Inspector. | Web view hosting | Web view containers are frame-based: `container.frame = contentContainerView.bounds`, and split panes sit in an `NSSplitView`, which frames its children directly. A throwaway spike on 2026-07-11 confirmed the inspector docks inside a pane and survives divider moves.[^design] See [split tabs hosting](../tabs/split-tabs-hosting.md) |
| `NSStackView.edgeInsets` on the **cross axis** are hugging-priority constraints only. In a height-constrained column the bottom inset silently collapses while the top survives.[^task-113] | Update banner in the Extensions settings pane: the button sat on the border | Add your own required constraints for insets that must hold; pin the content's bottom to the container. Measure in the running app rather than judging by eye |
| `NSBox`'s content view is sized by autoresizing, so the box does not grow to an Auto Layout content's fitting height.[^task-113] | Same banner | A plain layer-backed container (`TintedBannerView`) |
| A button's frame is larger than its height constraint: the constraint applies to the alignment rect. A 24 pt button measured 31 pt tall.[^task-126][^notes-hittest] | The Downloads button's hover circle was derived from the frame | State sizes that must be exact (`HoverButton.fixedHoverSize`); do not derive them from `bounds` |
| Traffic lights sit inside the sidebar area only if the window has a toolbar. | Window setup | An empty unified `NSToolbar` (`setupToolbar`) |
| During a fullscreen transition the title-bar container is reparented into an auxiliary window before `styleMask` reports `.fullScreen`. Converting a standard window button's frame then gives a plausible but wrong rect. | Title-bar control alignment in the sidebar | Check `zoomButton.window === window` before converting (`alignTitleBarControls`) |
| `NSSplitViewController.toggleSidebar(nil)` and `setPosition(0, …)` both flip `isCollapsed` and fire its KVO **synchronously** inside the call. The split view's autosave is applied when the controller's view loads, and written back on AppKit's own deferred schedule — including after the window closes.[^task-39] | Sidebar mode attribution; a flaky autosave test | Make state logic independent of KVO timing ([visibility and auto-hide](../sidebar/visibility-and-auto-hide.md)). In tests poll for the autosave write and let the close-time write land before removing the key |

# Hit testing and mouse events

| Behavior | Where it bit | Do instead |
|---|---|---|
| A plain `NSView` that exists only to carry a tracking area still takes every click inside it. Tracking areas do not depend on hit-testing.[^task-126] | A 20 pt edge hover strip covered the left of the Downloads button; clicks there moved the window (TASK-126) | Return `nil` from `hitTest` (`ClickThroughView`). To find such a view, map `hitTest` over the window's theme frame on a 1 pt grid ([UI probes](../playbooks/ui-probes.md)) |
| …but a drag destination should not do that. A nil-returning `hitTest` could exclude a view from AppKit's (undocumented) drag-destination discovery. | `SplitDropZoneView` | No `hitTest` override there; the view exists only while a drag session is live, so there are no clicks to pass through |
| A view with `mouseDownCanMoveWindow == true` moves the window from any point no subview claims. A control narrower than its drawn hover shape leaves a rim that drags the window. | Bottom-bar buttons | Make the frame cover what is drawn (28 pt wide for a 27 pt circle) |
| A table view that is a drag source delays window ordering on **every** mouse-down so a row can be dragged out of a background window. A mouse-down that instead moves the window then drags a background window around underneath the others. | Sidebar list, empty area below the rows | `shouldDelayWindowOrdering(for:)` returns `false` when the point is not on a row (`DraggableTableView`) |
| `WindowDragView.mouseDown` runs a nested `trackEvents` loop. Entered from inside a Swift `Task` (events delivered with `window.sendEvent`), AppKit throws from `nextEventMatchingMask` and the app aborts.[^notes-inprocess] | In-process UI automation | Deliver synthetic events with `NSApp.postEvent(_:atStart:)`; see [in-process UI automation](../playbooks/in-process-ui-automation.md) |
| Tracking areas do not reliably send `mouseExited` when scrolling moves a view from under the pointer, and send nothing while a drag session is active.[^commit-b9ef265] | Hover backgrounds stuck on rows after scrolls and drags | `recheckHover()` from `mouseLocationOutsideOfEventStream`, called after scrolls, batch updates and drag end |
| On macOS 26 the sidebar is inset 8 pt from the window edge, and the window's resize region is only the bottom 3 pt plus the rounded-corner cutout.[^task-126][^notes-hittest] | Suspected, wrongly, of eating the Downloads button's clicks | Probe rather than assume |

# Table views and drag sessions

| Behavior | Where it bit | Do instead |
|---|---|---|
| A batch update that removes and inserts rows, issued inside `acceptDrop` while the drag session is still live, aborts the drop and strands the session mid-drag. | Split create and break drops | Defer the table update one run-loop turn (`performDropTransaction` → `applyPendingState`); see [drag and drop](../sidebar/drag-and-drop.md) |
| `moveRow(at:to:)` keeps the row's cell view, closures and all. Moves in one batch are applied sequentially.[^commit-b9ef265] | Close and mute buttons dead after a pin and unpin round trip | Reconfigure every visible cell after a batch update; sort moves by destination ascending (`diffSidebarState`) |
| `NSDraggingDestination` methods are declared on `NSView`'s interface, so an override compiles, but the superclass may not implement them. An unguarded `super.draggingExited` raises unrecognized-selector during drag teardown, which aborts the session before the source's `endedAt` callback. | `DraggableTableView` | Guard with `NSTableView.instancesRespond(to:)` before calling `super` |
| The table delegate is not told when a drag leaves the table. | Split-edge highlight left behind | Override `draggingExited` / `draggingEnded` on the table and call back (`onDragTargetingEnded`) |
| The drag APIs do not give the data source the originating mouse event. | Deciding which half of a split row was grabbed | Record the point in `mouseDown` (`lastMouseDownPoint`) |
| `.sourceList` drop feedback can mark a whole row or a gap, nothing finer. | Split-edge drops | Draw your own overlay |
| The session's drag image disappears the moment a drop is accepted, and `animatesToDestination` needs the destination to exist now.[^task-129] | Dropped rows appeared to travel from their origin | Take the image over as an overlay view and animate it yourself (`beginDropLanding`) |
| A view at `alphaValue` 0 still receives drags. | Favorite drop hint after it faded out | Set `isHidden` once the fade completes |

# Popovers

| Behavior | Where it bit | Do instead |
|---|---|---|
| Collapsing the view a popover is anchored to takes the popover away with it.[^task-127] | Downloads popover vanished when an auto-hidden sidebar hid | Hold the sidebar open while a popover is up |
| `NSPopover` does not expose its positioning view. Its window is a child of the presenting window, but only from `didShow`; at `willShow` it is not yet.[^task-127] | Deciding which popovers belong to the window | Observe `NSPopover.didShowNotification` and test `popover.contentViewController?.view.window?.parent === window` |
| A `.semitransient` popover whose anchor collapses under it can stay shown and post no `didClose` (seen in a standalone probe, not reproduced in the app).[^task-127] | A hold keyed on `didClose` could stick | Known gap, unfixed |

# Appearance and capture

| Behavior | Where it bit | Do instead |
|---|---|---|
| A `CGColor` assigned to a layer is resolved once and does not follow light / dark changes. | Dividers, hover backgrounds, drop hints, split pane borders | Re-resolve in `viewDidChangeEffectiveAppearance` or `updateLayer`, inside `performAsCurrentDrawingAppearance` |
| `contentView.cacheDisplay(in:to:)` renders web content but leaves the sidebar blank.[^notes-harness] | Capturing the sidebar for verification | Render the sidebar's layer instead; see [in-process UI automation](../playbooks/in-process-ui-automation.md) |

# Why it matters here

Detour's chrome is hand-built AppKit: a source-list table inside a custom
page strip, a split view that hosts web views with frames rather than
constraints, popovers anchored to a sidebar that can hide. The entries above
share three lessons:

- **Probe before fixing.** The Tab-order finding and the resize-region
  suspicion were both wrong as stated; measuring in the running app changed
  what the bug was.
- **Prefer state the code owns** over AppKit's implicit state: the key-view
  loop, KVO timing, the lifetime of a drag session.
- **Leave a comment at the site** when a fix depends on undocumented
  behaviour. Most rows above point at such a comment; removing the code
  without reading it reintroduces the bug.

When adding an entry, keep the three columns — what AppKit does, the task or
file where it was met, the replacement — and footnote evidence that came
from a probe or a measurement.

# Related

- [Keyboard focus](../sidebar/keyboard-focus.md) — the rules built on the first-responder entries.
- [Sidebar drag and drop](../sidebar/drag-and-drop.md) — the table-view and drag-session entries in context.
- [Visibility and auto-hide](../sidebar/visibility-and-auto-hide.md) — collapse attribution and the popover hold.
- [Split tabs hosting](../tabs/split-tabs-hosting.md) — `NSSplitView` hosting of web views.
- [UI probes](../playbooks/ui-probes.md) and [debug harness](../playbooks/debug-harness.md) — how these were measured.
- [WKWebView delegate order](./wkwebview-delegate-order.md), [hidden web view load stalls](./hidden-webview-load-stalls.md), [WebKit test host traps](./webkit-test-host-traps.md) — the WebKit-side quirks.
- [App shell](../architecture/app-shell.md) — menus and key equivalents.

[^task-39]: Collapsing the sidebar by dragging its divider leaves Toggle Sidebar out of sync
[^task-56]: Implement menuHasKeyEquivalent so key presses stop rebuilding the Spaces, Extensions and Develop menus
[^task-76]: Keys a web page declines reach the end of the responder chain and play the unhandled-key beep
[^task-77]: Keys the extension popup page declines still play the unhandled-key beep
[^task-113]: Check for and install extension updates
[^task-132-8]: Host an extension's per-tab side panel beside the tab's content
[^task-126]: The Downloads button's left and bottom edges do not respond to clicks
[^task-127]: With auto-hide on, the downloads popover disappears when the sidebar hides
[^task-128]: On launch the sidebar's hidden Search Archive field holds keyboard focus instead of the page
[^task-129]: Favorite drop hint without a layout shift, and drops that land from the release point
[^task-130]: Keyboard focus stays behind on a tab list whose page has slid off screen
[^task-131]: A focused tab list loses keyboard focus when the space list changes
[^design]: Split tabs design (sections 5 and 11)
[^commit-b9ef265]: Sidebar: ID-based drag payloads, pure drop resolver, drag fixes
[^notes-keyloop]: Key-view loop probe findings
[^notes-hittest]: Hit-test and resize-region probe findings
[^notes-harness]: Runtime debug harness notes (zero-width split pane root cause)
[^notes-inprocess]: In-process UI verification notes
