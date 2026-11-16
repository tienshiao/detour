---
type: Feature
title: "Automation endpoint: how input is delivered"
description: How the automation endpoint's clicks, keys and menu choices reach pages, native views, sidebar rows and AppKit's own controls inside Detour without HID events or activating the app, when a click makes its window key (the user's decision on TASK-228.10), the pointer-arrival hover, and the AppKit and WebKit traps met on the way (current-event hit tests, renumbered posted events, gesture-recognizer controls, a table that will not select in a window that is not key, key ordering).
tags: [automation, mcp, appkit, input]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T21:46:03Z }
sources:
  - id: input
    resource: ../../Detour/Automation/AutomationInput.swift
    title: AutomationInput.swift (delivery, keys, elements, the menu tracker)
  - id: task-228-1
    resource: backlog:TASK-228.1
    title: "Automation: an MCP endpoint in Detour, first slice for testing"
  - id: task-228-7
    resource: backlog:TASK-228.7
    title: "Automation: run_menu_item and right clicks match what the user sees (live titles, row labels), and Quick Detour windows and Settings can be addressed"
  - id: task-228-8
    resource: backlog:TASK-228.8
    title: "Automation: a click from the endpoint toggles a switch and opens a pop-up in Settings"
  - id: task-228-9
    resource: backlog:TASK-228.9
    title: "Automation: a left click on a sidebar row selects its tab, as a person's click does"
  - id: task-228-10
    resource: backlog:TASK-228.10
    title: "Automation: an endpoint click that brings a window forward hands web view ownership over correctly (test it)"
  - id: task-228-12
    resource: backlog:TASK-228.12
    title: "Automation: endpoint clicks select rows in the other table views (Archived Tabs list, Settings lists)"
  - id: task-364
    resource: backlog:TASK-364
    title: "Automation: select_tab then Cmd+W closed a different tab once (investigate)"
  - id: webkit-resend
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/mac/WebViewImpl.mm
    title: WebKit's WebViewImpl.mm (doneWithKeyEvent, performKeyEquivalent)
  - id: task-365
    resource: backlog:TASK-365
    title: "Tests: flaky in full runs — native pop-up menu click, Quick Detour profile switch, site search chip icon, Settings row skip"
  - id: sidebar-components
    resource: ../../Detour/Browser/Sidebar/SidebarComponents.swift
    title: SidebarComponents.swift (DraggableTableView, FocusGatedTableView)
  - id: tests
    resource: ../../DetourTests/MCPServerTests.swift
    title: MCPServerTests, AutomationHTTPTests, AutomationToolsTests, AutomationEndpointTests
---

Nothing the [automation endpoint](./automation-endpoint.md) sends is posted
at the HID level, so Detour never comes to the front and the person's
pointer never moves (`AutomationInput`).[^input] Events are handed to the
view, or routed through the window, inside the app. The exceptions are the
test-run staging tools, which bring Detour forward on purpose:
`set_window_frame activate=true`, and `open_ui settings`/`arc_import`, whose
windows activate the app when shown (see [capture
staging](./automation-endpoint-staging.md)). Since the person cannot see
where an agent clicks, Detour can draw it: [the agent
pointer](./automation-endpoint-agent-pointer.md).

# How each target is reached

- **A page** gets the events handed to its web view: `mouseDown(with:)`, a
  60 ms pause (WebKit takes a down and an up in the same turn as no click),
  `mouseUp(with:)`; keys through `keyDown(with:)` and `keyUp(with:)`, after
  the web view is made its window's first responder (which does not activate
  the app). The page sees trusted events (`isTrusted`) with the modifiers
  and US `event.code`s, while Detour is in the background.
- **A key the page gives back** goes to the window it was pressed in
  (TASK-364).[^task-364] A web view takes every key at once and asks the
  page; a key the page does not take, WebKit sends again through
  `NSApp.sendEvent`, the same event object
  (`WebViewImpl::doneWithKeyEvent`),[^webkit-resend] for the key
  equivalents and the menus, and AppKit hands that to the key window, which
  for an agent's key need not be the window it was pressed in. The endpoint
  marks every key-down it hands a view (`AutomationKeyResend`, in
  `AutomationInput.swift`, by `press`, `type` and `press_key`'s Cmd branch);
  a local key-down monitor, which `NSApp.sendEvent` runs, catches a marked
  event coming back. In its own window, when that window is key, it goes on
  as AppKit sends it, as a person's key does; otherwise it stops there and
  the window's main-menu key equivalent runs, resolved and validated in that
  window as `run_menu_item key=` does (`AutomationTools.runMenuKeyEquivalent`).
  A key with no menu item is dropped. The resend comes after `press_key` has
  answered, so its command acts on what the window holds when it arrives
  (a `select_tab` sent in between can change which tab Cmd+W closes), as
  AppKit's own resend does for a person's key; not guarded (TASK-400). The mark lives as long as the event
  (weak keys): the page answered after more than a second once at runtime.
  A Cmd key a native first responder declines at once
  (`performKeyEquivalent` false) goes to the same menu lookup
  (`menuKeyEquivalent`), and press_key awaits the command before it returns,
  so a later input in arrival order (a select_tab) cannot run first, as AppKit
  tries the menu next for a person's key (the user's decision, 2026-11-16;
  the alternative, rejected, was to leave it unhandled).
- **A native view** under a window point gets `mouseDown(with:)` directly,
  with the mouse-up posted to the app's queue first, where a control's
  tracking loop finds it. The view is hit-tested, and the press handled,
  with that press as `NSApp.currentEvent` (`AutomationInput.makeCurrent`:
  posted to the front of the queue and taken off with `nextEvent` in a
  run-loop mode of its own, so no other tool's pending run-loop work runs
  inside the call), as in AppKit's own dispatch (see the trap on a sidebar
  row's label). Checked at runtime with Detour in the background: the
  sidebar's Add Space button opened the space editor.
- **A table row** takes a left click and acts as for a person's click, with
  Detour in the background as when it is active: a sidebar row selects its
  tab, a pinned entry or (a folder's row) toggles the folder
  (TASK-228.9);[^task-228-9] an Archived Tabs row restores its tab, a
  command palette row runs (switches to the tab, opens the page), a Settings
  list row (Spaces, Profiles, Extensions, Site Search) selects
  (TASK-228.12).[^task-228-12] AppKit's table gives up on a press in a
  window that is not key unless it becomes a drag (see Traps), so every
  Detour table is an `AutomationTableView`,[^input] whose
  `needsPanelToBecomeKey` answers false while the endpoint hands it, or a
  view inside it, a press (`AutomationInput.isHandingPress(to:)`), and the
  table's own mouse-down selects and sends its click action. The flag is set
  on both routes: a press on a row's label goes through the window when the
  label takes a first click (the palette's rows) and reaches the table up
  the responder chain; a press the table hit-tests to itself (a sidebar,
  archive or Settings row) stays on the direct route, since the table
  delays window ordering. The table has to cooperate: the check is the
  table's own, it asks the window whether it is key, and the endpoint must
  leave the key window alone in the background, so nothing in the delivery
  alone gets past it short of swizzling AppKit. One base class rather than
  an override per table, so a new list gets it by being made from it. No
  select call stands in for the click: the table's own code runs (the
  clicked row, the drag check, the New Tab row opening the palette,
  Opt-Cmd-click's Quick Detour, a click action reading `clickedRow`). A
  person's press is untouched, so a row dragged out of a background window
  still drags without selecting first.[^sidebar-components] Which tables
  were affected is in Traps.
- **The pointer arrives before a left click on a native view**
  (`AutomationInput.pointerArrived`, then `pointerLeft` after the click): the
  views under the point, from the hit view down, that own a tracking area
  with `.mouseEnteredAndExited` holding the point get `mouseEntered`, the
  window is laid out, and the target is hit-tested and gated again
  (`retarget`); after the click they get `mouseExited`, unless they left the
  window. A person's pointer crosses a row before clicking it, so a control
  shown only on hover is there for the press: a tab row's close button closes
  the tab, where the click selected the row before (TASK-228.9; chosen by
  Claude, confirmed by the user on 2026-11-15).[^task-228-9]
  `.activeInActiveApp` is not honoured (the endpoint clicks in the
  background); an area the person's own pointer is in is left alone; the
  window's own hover zones (owned by the controller, not a view under the
  point) are never touched. Not for a right click (its menu runs until it
  closes) or a page. An agent cannot find such a control first: `hit_test`
  and screenshots show the row without it. The close button sits at the
  row's right end, 16 points wide.
- **A left press on a view that takes a first click** goes through the
  window's own routing instead (`NSWindow.sendEvent`, press and then, if
  still queued, the release), because AppKit's own controls track a click
  with gesture recognizers that only that routing feeds (see
  Traps).[^task-228-8] `AutomationInput.deliversThroughWindow` decides,
  inside the run-loop body:
  - the view's class has no `mouseDown` of its own between it and AppKit
    (such a view tracks the press itself, and is not even asked about a
    first click: Quick Detour's title-bar buttons read that question as
    "this press activates the window" and then drop the press);
  - it accepts first mouse for the press;
  - it does not delay window ordering for it (a sidebar row does);
  - and the window's hit test, with the press current, still finds the very
    view the tool checked (so the press never reaches a view the Settings
    gates did not see).

  Any other view, and every right click, keeps the direct route: the window
  drops a press on a view that does not take a first click while Detour is
  in the background or the window is not key, and most of Detour's own
  views do not. Checked at runtime in a test run: Settings > General's Peek
  switch toggles both ways (its stored `PeekEnabled` changes), Settings >
  Quick Detour's pop-up opens (`list_menu` lists it) and `choose_menu_item`
  changes the stored value; the sidebar's Back button (a `HoverButton`)
  still goes back with Detour in the background, and the app stays
  inactive.
- **Every event goes out from `RunLoop.main.perform`**, as `run_menu_item`'s
  actions do (see "A modal action and the main queue" in [the
  tools](./automation-endpoint-tools.md#traps)): a native context menu runs
  its whole tracking loop inside `rightMouseDown`, so the click answers
  `completed: false` after the wait while the menu stays open and the
  endpoint keeps answering.
- **Menus**: `AutomationMenuTracker` follows
  `NSMenu.didBeginTrackingNotification` and `didEndTrackingNotification` for
  every menu in the app; the newest one open is what `list_menu` shows.
  Choosing calls `performActionForItem(at:)` while the menu is still
  tracking (WebKit's items need their live menu), then `cancelTracking()`.
  `closeAll()`, which a click runs before its press, waits until the
  tracker has seen every menu end **and** the endpoint's press that opened
  one has returned (see the traps).

# Which window is key

The user's decision (2026-11-15, TASK-228.10): agent clicks behave like a
person's.[^task-228-10]

- With Detour active, a click in a window that is not key makes it key
  (`AutomationTools.bringForward`: `makeKeyAndOrderFront`, after the glide
  and its checks and before the hover and the press, then the target is
  checked again), on every route: a page, a view handed the press, a press
  routed through the window. Making the window key takes the key from a
  popover or sheet of it, as a person's click does.
- Between two browser windows showing the same tab the web view moves to
  the clicked window (`windowDidBecomeKey` claims it, see [web view
  ownership](../architecture/webview-ownership.md)) and the other shows the
  snapshot; a click on the snapshot's place then reaches the live page that
  replaced it.
- With Detour in the background a click never activates Detour or changes
  the key window, so the web view stays where it is and a click on a
  snapshot does nothing.
- `type_text`'s `selector` click does the same; typing alone never changes
  the key window.

Three choices Claude made in the implementation, all confirmed by the user
on 2026-11-15: a window on another macOS Space is never made key by an
agent click (no person could click it from where they are, and it would
switch their desktop); with Detour active a click on a snapshot reaches the
live page (a person's first click there would only bring the window
forward); and a row click in a window that is not key selects as well as
raises, which may be more than a person's first click does (see the
sidebar-row trap).[^task-228-10]

Before, only a press routed through the window could make it key. Checked
at runtime with two windows on one tab: in the background two clicks in the
window showing the snapshot left `app_active` false, no window key and the
snapshot where it was; active, a click on its page made it key, moved the
web view there and reached the page, and a click on the other window's row
moved it back. `AutomationEnvironment.isAppActive` and `makeKey` are
injectable because the XCTest host is never active and cannot make a
window key. The re-check of the gates after the glide, before the window is
made key, has no test (it needs a gate that flips mid-glide), and the
other-Space guard cannot be tested in the host.

# Traps

- **A sidebar row's label took a right click and opened nothing.** A
  view-based `NSTableView` answers `hitTest` with itself for a press on a
  row's label or icon, but only while the current event is a mouse press.
  With any other current event (in the test host it was an `appKitDefined`
  event left over), it answers with the `NSTextField` or `NSImageView`. Such
  a label inside a table does not pass `rightMouseDown` on to the row: in
  the test host, `label.rightMouseDown` and `window.sendEvent` both opened
  nothing, while the same event on the cell, the row or the table opened
  the row's menu. A real right click is hit-tested during dispatch, so it
  reaches the table. The endpoint hit-tested outside dispatch, so its right
  click reached the label (TASK-326's helper aimed at the row's background
  to get around it). Now the press is made current first.[^task-228-7] A
  plain label in a plain view does forward the click (standalone spike), so
  this is the table's doing. The release is made current after a bare
  `hit_test`: `NSMenu.popUpContextMenu` with a press current and no release
  queued waited for the release and stopped the main queue, which hung a
  test.
- **A context menu popped up by a test in a Quick Detour window stalled the
  main queue.** `NSMenu.popUpContextMenu` called from a `RunLoop.main.perform`
  block in a Quick Detour window held the main queue in the test host twice,
  with and without a release queued. The same call through a native view in
  a browser window does not. This is not explained. The test posts
  `didBeginTrackingNotification` by hand instead. At runtime, a right click
  on a Quick Detour's page through the endpoint (WebKit's menu) listed and
  closed normally.
- **Posting an event renumbers it and rounds its time.** `NSApp.postEvent`
  gives the event a new `eventNumber` (posted 1,000,001 came back as about
  16,900), so the check that took a leftover mouse-up off the queue never
  matched it. Its `timestamp` survives only to the nanosecond
  (725491.8170181251 came back as 725491.817018125), so an exact `==` on it
  fails too. Before the TASK-228.7 review the leftover mouse-up was
  therefore never taken; it is now handed to the view that took the press,
  as AppKit's dispatch does, which a view acting on `mouseUp` (such as the
  faux address bar's buttons) needs. `AutomationInput.sameTime` compares
  within a microsecond, and the input tools' own mouse events are made at
  least 10 µs apart so they stay told apart (`isSynthetic`). Its location
  and window come back as they were posted (checked in the test host,
  TASK-228.8). Every event the endpoint takes off the queue itself is taken
  in a run-loop mode of its own, never a common one, where `nextEvent`
  would run main-actor jobs and other tools' run-loop bodies inside the
  caller.
- **A tool's event displaces the person's as the current event.** The menu
  tracker reads the current event's window to tell a person's menu in a
  Private window, and WebKit opens a page's context menu some time after
  the right click. A `hit_test` in between left its own event current, so
  the menu looked as if it opened over the tool's window.
  `AutomationInput.makeCurrent` remembers the window of the person's event
  it displaced, and the tracker takes the strictest of both while a tool's
  event is current.
- **A direct text insert overtakes queued keys.** WebKit holds key events
  until the page has handled the previous ones, and `insertText(_:)` does
  not wait: "Ab!é" arrived as "Abé!".[^task-228-1] A character with no US
  key is sent as a key press carrying it (key code 0xFF, which the page
  reports as `code` "Unidentified"), so it stays in order. Also,
  WKWebView's `NSTextInputClient` conformance is not one a Swift `as?` cast
  sees.
- **`type_text` returns before the page has taken every key.** A test that
  made a native field first responder right after typing "hi" into a page
  got "oik" in the native field when it then typed "ok": the page's last
  key reached the new first responder. Not investigated further; wait for
  the page's value before moving the focus.
- **Hit tests behind an open menu are wrong.** With a context menu open, a
  hit test in the window found `NSMenuHighlightView`, and Escape sent to the
  window's first responder does not reach a tracking menu. Input tools close
  open menus first; `close_menu` closes one on its own.
- **AppKit's own controls ignore a press handed to `mouseDown`.** On this
  macOS (26, November 2026) `NSSwitch`, `NSButton` and `NSPopUpButton`, not
  subclassed, track a click with an `NSControlGestureRecognizer` that
  `NSWindow.sendEvent` feeds. Their `mouseDown(with:)` returns in about a
  millisecond without a tracking loop (an `nextEvent` swizzle in the test
  host saw none), so the queued release was still there, went to
  `mouseUp(with:)`, and nothing happened: a Settings switch never toggled
  and a pop-up never opened (TASK-228.8).[^task-228-8] A subclass that
  overrides `mouseDown` still tracks the old way
  (`_overridesRequireMouseDownFallback`, private), which is why
  `HoverButton` subclasses and test doubles worked. Through
  `window.sendEvent`, press and release, the recognizer begins on the press
  and the control acts on the release, with Detour inactive and the window
  not key. An earlier note said the test host moves posted events'
  locations and that this was why a button's action never fired there;
  probes showed the location unchanged, and the cause was this.
- **A switch acts only for a press on its pill.** `NSSwitch`'s view is wider
  than the pill it draws; a press at the view's left edge (inside its
  bounds, so `hit_test` reports `NSSwitch`) fails its own track hit test
  (`_hitTestForTrackMouseEvent:`, private, answered 0) and the recognizer
  does not begin, at runtime as a person's would not. Aim at the frame's
  centre that `hit_test` returns. Scanning for the first point that hits the
  switch made the first runtime checks of this fix look like failures.
- **A left click on a sidebar row selected nothing through the endpoint**
  (before TASK-228.9, on both routes).[^task-228-9] `-[NSTableView
  mouseDown:]` asks `_shouldAbortMouseDownAfterDragAttempt:` first: true
  when the window is not key, it can become key, and the table's
  `needsPanelToBecomeKey` is true (read from the disassembly). Then the
  table only tries a drag (`_performDragFromMouseDown:` takes the release
  off the queue and posts it back) and, unless Command is held or a cell
  takes the click through, returns without selecting. The endpoint's press
  always met it: no window is key while Detour is in the background. Probed
  in the test host by swizzling `nextEvent`, `postEvent` and
  `selectRowIndexes`: with the table answering false the same press
  selected the row, its selection tracking took the release, and the window
  stayed non-key. Not the click count, the timestamps or the current event.
  For a person, AppKit's own `_handleMouseDownEvent:isDelayedEvent:` does
  not make the window key at the press when the view delays window ordering
  (it blocks ordering and orders the window on the release,
  `_NXDoMouseUpWindowOrdering`), so a person's first click on a row of a
  window that is not key probably only brings the window forward; not
  checked with a real click. Every other table had the same trap
  (TASK-228.12, probed in the test host before the fix, Detour in the
  background):[^task-228-12] a click on an Archived Tabs row restored
  nothing, one on a command palette row ran nothing (the press, on the
  row's label, went through the window and reached the table up the
  responder chain, where the same check stopped it), and one on a Spaces,
  Profiles or Site Search row selected nothing. All three are plain
  `NSTableView`s and each delayed window ordering for the press (so the
  press stayed on the direct route); Spaces is a drag source, but Profiles,
  Site Search and the Archived Tabs list are not, so a table that is not a
  drag source delays it too. The Shortcuts and Link Routes lists select no row
  by design (`shouldSelectRow` false); their controls take the press
  themselves. The Downloads popover's list is out of reach (popovers are
  not addressable), and is an `AutomationTableView` all the same. See also [AppKit
  gotchas](../platform/appkit-gotchas.md).
- **A key pressed in a window that was not key acted in the key window**
  (TASK-364, measured through the endpoint before the fix).[^task-364] With
  Detour active and window 1 key, `press_key window_id=2 key=cmd+w` closed
  window 1's selected tab (window 2's stayed), and `press_key window_id=2
  key=x`, which the page in window 2 did not take, reached the page in
  window 1 as a trusted keydown, more than a second later. In the
  background, with no key window, the same Cmd+W closed nothing and still
  answered `handled: true` (the web view took the key; the page's answer
  comes later). `run_menu_item` never had this: it resolves the item in the
  named window's chain. `select_tab` was not involved: it selects in the
  window it names, key or not. The report that started the task was a
  script's mistake: `select_tab` called with `tab_id=` is refused
  (`invalid_arguments`, "Unknown argument(s): tab_id", exit 1 from
  `scripts/detour-mcp`), the script discarded the answer, and Cmd+W closed
  the tab still selected.
- **A menu's end is announced before its loop unwinds.** AppKit posts
  `didEndTrackingNotification` while the closed menu's tracking loop, and
  the press body that opened it (inside `rightMouseDown` or the pop-up's
  tracking), are still on the stack. The main queue drains in that loop,
  so `closeAll()`'s wait could resume there and the next click went on
  inside it: it posted its mouse-up and opened its menu while the first
  one's loop still ran. In a combined test run that second menu closed
  itself about 0.4 s after it opened, and the next `choose_menu_item` said
  `no_open_menu`. `runFromRunLoop` now counts the bodies it started that
  have not returned (`bodiesRunning`); the tracker notes that count when a
  menu opened by one of the endpoint's own presses begins tracking
  (`pressDepth`), and `closeAll()` also waits, within the same one-second
  cap, until fewer bodies run, so a body running around the menu (a
  click whose alert is up) is not waited for. It waits even when the menu
  has already ended (chosen from) and only its press is left; a press still
  running after the second is not waited on again. `testASecondRightClickOpensItsMenuWhileTheFirstStillUnwinds`
  slows the first menu's unwinding with a `didEndTracking` observer that
  runs the run loop; without the wait the second press ran nested inside
  the first (two bodies running).[^task-365]
- **Local event monitors do not see the endpoint's input.** AppKit runs
  `NSEvent.addLocalMonitorForEvents` handlers only for events going through
  `NSApp.sendEvent`, and the input tools hand events to views directly (that
  is what makes them work in the background). The window's web-click
  monitor, which places a download's flight (TASK-324), saw none of them,
  so a download started through the endpoint flew from the middle of the
  page. The tools now post `AutomationInput.didDeliverEventNotification`
  (object: the window, the event under `eventKey`) before each mouse-down
  and key-down, and that monitor listens to it too
  (`BrowserWindowController` is its only observer). Control-Tab's
  switcher, sidebar swipes and the hover card do not listen.

# Tests

`AutomationInputTests` (trusted clicks by selector, page point and window
point; typing; context menus; native views; `NSSwitch` and `NSPopUpButton`
with the window not key; right and left clicks on sidebar rows, the
hover-only close button, pinned entries, folders, the New Tab row; an
Archived Tabs row, a command palette row and a switch inside a table's
row, TASK-228.12;
TASK-228.10's two windows on one tab; the input errors), and
`AutomationWindowKindsTests`' Settings list row (TASK-228.12, which also
checks that every Settings pane's table is an `AutomationTableView`). The
tests that need an inactive host (the row selects, both TASK-228.10 tests)
first hand the host's activation away (`moveTestHostToBackground()`, see
[build and test](../playbooks/build-and-test.md#traps)) and skip only if
it is still the active app. Details in [the endpoint's
tests](./automation-endpoint-tests.md).[^tests]

# Related

- [Automation endpoint (MCP)](./automation-endpoint.md): the hub.
- [The tools](./automation-endpoint-tools.md): `click`, `type_text`,
  `press_key`, `hit_test` and the menu tools.
- [The agent pointer](./automation-endpoint-agent-pointer.md): the glide
  that runs before a click and the arrival order.
- [In-process UI automation](../playbooks/in-process-ui-automation.md): the
  techniques the input tools build on.
- [Web view ownership](../architecture/webview-ownership.md): what moves
  when a click makes a window key.

[^input]: AutomationInput.swift (delivery, keys, elements, the menu tracker)
[^task-228-1]: Automation: an MCP endpoint in Detour, first slice for testing
[^task-228-7]: Automation: run_menu_item and right clicks match what the user sees (live titles, row labels), and Quick Detour windows and Settings can be addressed
[^task-228-8]: Automation: a click from the endpoint toggles a switch and opens a pop-up in Settings
[^task-228-9]: Automation: a left click on a sidebar row selects its tab, as a person's click does
[^task-228-10]: Automation: an endpoint click that brings a window forward hands web view ownership over correctly (test it)
[^task-228-12]: Automation: endpoint clicks select rows in the other table views (Archived Tabs list, Settings lists)
[^task-364]: Automation: select_tab then Cmd+W closed a different tab once (investigate)
[^webkit-resend]: WebKit's WebViewImpl.mm (doneWithKeyEvent, performKeyEquivalent)
[^task-365]: Tests: flaky in full runs — native pop-up menu click, Quick Detour profile switch, site search chip icon, Settings row skip
[^sidebar-components]: SidebarComponents.swift (DraggableTableView, FocusGatedTableView)
[^tests]: MCPServerTests, AutomationHTTPTests, AutomationToolsTests, AutomationEndpointTests, and the other Automation suites
