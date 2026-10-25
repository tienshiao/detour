---
type: Platform Quirk
title: AppKit gotchas
description: A collection of AppKit behaviours that cost debugging time in Detour — first responder and key-view loop, split and stack view layout, hit testing, table views under a drag session, popovers — each with where it bit and what to do instead.
tags: [appkit, platform, focus, layout, drag-and-drop, hit-testing]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-25T02:30:00Z }
stale_after: 2027-04-01T00:00:00Z
sources:
  - id: task-189
    resource: backlog:TASK-189
    title: "Settings: fix the window's spacing and clipping"
  - id: task-186-3
    resource: backlog:TASK-186.3
    title: "Dev mode: capture buttons in the dev toolbar"
  - id: task-186-2
    resource: backlog:TASK-186.2
    title: "Dev mode: an under-construction toolbar above the page with the URL"
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
  - id: task-169
    resource: backlog:TASK-169
    title: A hover-revealed sidebar sometimes stays open instead of hiding again
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
| Esc reaches a responder as a raw `keyDown` or as `cancelOperation(_:)`, depending on how AppKit interprets the event. | Esc-closes-Peek | Override both |
| An `NSMenuDelegate` that does not implement `menuHasKeyEquivalent` gets `menuNeedsUpdate` on **every** key-equivalent dispatch. Returning `false` from it is not a veto (AppKit scans the existing items itself); returning `true` is trusted with no validation.[^task-56] | Spaces and Extensions menus were rebuilt on every Cmd+key press | `MenuKeyEquivalentMatcher`; see [app shell](../architecture/app-shell.md) |

# Layout

| Behavior | Where it bit | Do instead |
|---|---|---|
| `NSSplitView.setPosition(_:ofDividerAt:)` resizes the divider's two neighbours **from their current frames**, preserving their far edges. It does not re-tile. A pane carrying a stale frame from an earlier hosting collapses to zero width and nothing repairs it until the window resizes.[^notes-harness] | A split re-formed with a pane on the other side showed a dead white half (the "zero-width pane" bug) | Frame both panes explicitly, then call `setPosition` (`applySplitFraction`, using `splitPaneRects`). `splitViewDidResizeSubviews` self-repairs with `panesAreMistiled` rather than committing broken geometry as the new fraction |
| `NSSplitView` overwrites its panes' autoresizing masks while tiling. | A web view container returned to single hosting kept a fixed size instead of following window resizes | `resetSplitPaneChrome` restores `[.width, .height]` |
| Auto Layout constraints on a `WKWebView`'s container break the docked Web Inspector. | Web view hosting | Web view containers are frame-based: `container.frame = contentContainerView.bounds`, and split panes sit in an `NSSplitView`, which frames its children directly. A throwaway spike on 2026-07-11 confirmed the inspector docks inside a pane and survives divider moves.[^design] See [split tabs hosting](../tabs/split-tabs-hosting.md) |
| `NSStackView.edgeInsets` on the **cross axis** are hugging-priority constraints only. In a height-constrained column the bottom inset silently collapses while the top survives.[^task-113] | Update banner in the Extensions settings pane: the button sat on the border | Add your own required constraints for insets that must hold; pin the content's bottom to the container. Measure in the running app rather than judging by eye |
| An `NSBox` with `boxType = .separator` has no intrinsic width. In a horizontal `NSStackView` given only a height, it can be stretched to take the stack's slack and turns into a horizontal line; with one separator in the dev toolbar it happened to stay narrow, with two (TASK-186.3) one stretched to 473 pt and pulled the link button to the URL.[^task-186-3] | Dev toolbar trailing groups | Constrain both dimensions (`addTrailingGroup` gives each separator width 1, height 14); the frame is then about 5 pt wide around a 1 pt alignment rect |
| `NSBox`'s content view is sized by autoresizing, so the box does not grow to an Auto Layout content's fitting height.[^task-113] | Same banner | A plain layer-backed container (`TintedBannerView`) |
| A window's content view whose constraints cap its height (content pinned top and bottom with required `==`, nothing that stretches, inside a scroll view's document that must be at least the visible height) gives the window a maximum size: AppKit resizes the window to it the moment the view becomes `contentViewController`'s view, with no animation.[^task-189] | Settings: shrinking onto the Content Blocking pane snapped instead of animating | Pin the last item with `<=` plus a low-priority `==`, or let something in the column stretch |
| Setting `contentMaxSize` below the window's current content height (or `contentMinSize` above it) resizes the window at once.[^task-189] | Settings window, setting a pane's bounds before animating to its height | Widen the bounds to cover the current height, animate, then set the final bounds in the completion |
| `fittingSize` does not run the two-pass layout a wrapping `NSTextField` needs, so a wrapping label without `preferredMaxLayoutWidth` measures as one line. A constant wrap width is wrong as soon as the label's real width differs, for example a column 17 pt narrower under "always show scroll bars", and the last line is cut.[^task-189] | Settings panes' natural heights | Give the label a definite width and take the wrap width from it in `setFrameSize` (invalidate the intrinsic size and re-measure the container when it changes), starting from an estimate so the first measurement is right (`SettingsWrappingLabel`) |
| `NSGridView` has one `rowSpacing`, and a hidden row still has to be skipped by whatever spacing you add. Help text that should sit closer to its control than the row gap cannot get it from `rowSpacing`.[^task-189] | Settings: Profiles' help rows 4 pt below their control, rows 10 apart | `rowSpacing = 0` and each row's `topPadding` set from a rule that knows which rows are visible (0 for the first visible row); a hidden row then contributes nothing |
| A required width on the window's content view locks the window's width; without it, a label's compression resistance (750) beats the window's size (500) and a long string widens the window.[^task-189] | Settings: a long extension name widened the window to 1104 | Lock the width, and give long labels `.byTruncatingTail` and low compression resistance so they give way first |
| A button's frame is larger than its height constraint: the constraint applies to the alignment rect. A 24 pt button measured 31 pt tall.[^task-126][^notes-hittest] | The Downloads button's hover circle was derived from the frame | State sizes that must be exact (`HoverButton.fixedHoverSize`); do not derive them from `bounds` |
| Traffic lights sit inside the sidebar area only if the window has a toolbar. | Window setup | An empty unified `NSToolbar` (`setupToolbar`) |
| During a fullscreen transition the title-bar container is reparented into an auxiliary window before `styleMask` reports `.fullScreen`. Converting a standard window button's frame then gives a plausible but wrong rect. | Title-bar control alignment in the sidebar | Check `zoomButton.window === window` before converting (`alignTitleBarControls`) |
| `NSSplitViewController.toggleSidebar(nil)` and `setPosition(0, …)` both flip `isCollapsed` and fire its KVO **synchronously** inside the call. The split view's autosave is applied when the controller's view loads, and written back on AppKit's own deferred schedule — including after the window closes.[^task-39] | Sidebar mode attribution; a flaky autosave test | Make state logic independent of KVO timing ([visibility and auto-hide](../sidebar/visibility-and-auto-hide.md)). In tests poll for the autosave write and let the close-time write land before removing the key |
| `toggleSidebar(nil)` twice in one run loop turn, collapse then expand, ends **collapsed**: each call flips `isCollapsed` synchronously, then a third KVO (`true`) arrives after both returned. Expand then collapse in one turn, and either order 50 ms apart, behaved as asked (standalone probe, macOS 26).[^task-169] | Tests that put a window into auto-hide mode and revealed the sidebar at once saw it "hide" in 0.1 s | Let a collapse settle for a run loop turn before expanding; in the app the stray collapse is adopted as external, which leaves a consistent hidden state |

# Hit testing and mouse events

| Behavior | Where it bit | Do instead |
|---|---|---|
| A plain `NSView` that exists only to carry a tracking area still takes every click inside it. Tracking areas do not depend on hit-testing.[^task-126] | A 20 pt edge hover strip covered the left of the Downloads button; clicks there moved the window (TASK-126) | Return `nil` from `hitTest` (`ClickThroughView`). To find such a view, map `hitTest` over the window's theme frame on a 1 pt grid ([UI probes](../playbooks/ui-probes.md)) |
| …but a drag destination should not do that. A nil-returning `hitTest` could exclude a view from AppKit's (undocumented) drag-destination discovery. | `SplitDropZoneView` | No `hitTest` override there; the view exists only while a drag session is live, so there are no clicks to pass through |
| A view with `mouseDownCanMoveWindow == true` moves the window from any point no subview claims. A control narrower than its drawn hover shape leaves a rim that drags the window. | Bottom-bar buttons | Make the frame cover what is drawn (28 pt wide for a 27 pt circle) |
| A table view that is a drag source delays window ordering on **every** mouse-down so a row can be dragged out of a background window. A mouse-down that instead moves the window then drags a background window around underneath the others. | Sidebar list, empty area below the rows | `shouldDelayWindowOrdering(for:)` returns `false` when the point is not on a row (`DraggableTableView`) |
| `WindowDragView` forwards a click that did not drag by calling `mouseDown` and then a synthesized `mouseUp` on the view under it. An `NSButton` under the strip cannot take that: its `mouseDown` tracks the real event queue for a mouse-up the strip already consumed.[^task-186-2] | Dev mode's toolbar sits inside the content area's top 38 pt | Adopt `WindowDragPassThrough`: the strip's `hitTest` returns nil over such a view, so its controls get the events directly ([dev mode](../features/dev-mode.md#the-dev-toolbar)) |
| `WindowDragView.mouseDown` runs a nested `trackEvents` loop. Entered from inside a Swift `Task` (events delivered with `window.sendEvent`), AppKit throws from `nextEventMatchingMask` and the app aborts.[^notes-inprocess] | In-process UI automation | Deliver synthetic events with `NSApp.postEvent(_:atStart:)`; see [in-process UI automation](../playbooks/in-process-ui-automation.md) |
| Tracking areas do not reliably send `mouseExited` when scrolling moves a view from under the pointer, and send nothing while a drag session is active.[^commit-b9ef265] | Hover backgrounds stuck on rows after scrolls and drags; a hover-revealed sidebar that stayed open (TASK-169) | Do not let state hang on one exit event: re-derive it from `mouseLocationOutsideOfEventStream` (`recheckHover()` after scrolls, batch updates and drag end; the sidebar's pointer sample, see [visibility and auto-hide](../sidebar/visibility-and-auto-hide.md)) |
| `mouseMoved` events posted with `NSApp.postEvent` do not produce `mouseEntered` or `mouseExited`, even for an `.activeAlways` tracking area.[^task-169] | Trying to drive hover from a harness | Call the code the tracking area would call; say that the pointer never moved |
| A view's `bounds` are not what is on screen while it slides in: the sidebar's bounds reached past the window's edge during the reveal animation, and a pointer outside the window tested as inside them. `visibleRect` was empty then, and equal to the bounds once settled.[^task-169] | "Is the pointer over the sidebar" during a hover reveal | Test against `visibleRect` |
| A `Timer` scheduled in the default run loop mode does not fire while AppKit tracks a context menu; a `DispatchQueue.main.asyncAfter` block does (it ran in `NSEventTrackingRunLoopMode`). `NSMenu.didBeginTrackingNotification` and `didEndTrackingNotification` are posted for a context menu too.[^task-169] | The sidebar's hide delay collapsed it under an open context menu | Use a default-mode `Timer` for anything that must wait for a menu or drag to finish |
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
| A `.semitransient` popover whose anchor collapses under it can stay shown and post no `didClose` (seen in a standalone probe, not reproduced in the app).[^task-127] Ordering its parent window out, or minimizing it, also leaves it `isShown` with no `didClose`; it returns with the window. A shown popover with no remaining reference stays alive and shown. Removing the anchor's view from the hierarchy closes it, with `didClose`.[^task-169] | A hold keyed on `didClose` could stick | Keep popovers weakly and ask `isShown` when the answer matters (`refreshSidebarPopoverHold`) |
| For an animated popover `didShow` was posted about 0.5 s after `show(relativeTo:of:preferredEdge:)` returned; `isShown` and the child-window relation were true as soon as it returned.[^task-169] | The sidebar's popover hold starts late | Known gap, unfixed |

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
[^task-126]: The Downloads button's left and bottom edges do not respond to clicks
[^task-127]: With auto-hide on, the downloads popover disappears when the sidebar hides
[^task-128]: On launch the sidebar's hidden Search Archive field holds keyboard focus instead of the page
[^task-129]: Favorite drop hint without a layout shift, and drops that land from the release point
[^task-130]: Keyboard focus stays behind on a tab list whose page has slid off screen
[^task-131]: A focused tab list loses keyboard focus when the space list changes
[^task-169]: A hover-revealed sidebar sometimes stays open instead of hiding again
[^design]: Split tabs design (sections 5 and 11)
[^commit-b9ef265]: Sidebar: ID-based drag payloads, pure drop resolver, drag fixes
[^notes-keyloop]: Key-view loop probe findings
[^notes-hittest]: Hit-test and resize-region probe findings
[^notes-harness]: Runtime debug harness notes (zero-width split pane root cause)
[^notes-inprocess]: In-process UI verification notes
[^task-186-2]: Dev mode: an under-construction toolbar above the page with the URL
[^task-186-3]: Dev mode: capture buttons in the dev toolbar
[^task-189]: Settings: fix the window's spacing and clipping
