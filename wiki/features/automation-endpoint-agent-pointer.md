---
type: Feature
title: "Automation endpoint: the agent pointer"
description: The visible agent pointer of the automation endpoint (TASK-228.11), a click-through child overlay window that glides an orange "Agent" arrow to each click and outlines the field keys go to, covering its timing, the checks run again after the glide, the arrival order of input and menu calls, where it is not drawn, how screenshots leave it out, and its setting and Debug override.
tags: [automation, mcp, appkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T06:21:26Z }
sources:
  - id: task-228-11
    resource: backlog:TASK-228.11
    title: "Automation: a visible agent pointer shows where the endpoint clicks and types"
  - id: agent-pointer
    resource: ../../Detour/Automation/AutomationAgentPointer.swift
    title: AutomationAgentPointer.swift (the setting, the overlay window, the glide, the arrival order)
  - id: tests
    resource: ../../DetourTests/MCPServerTests.swift
    title: MCPServerTests, AutomationHTTPTests, AutomationToolsTests, AutomationEndpointTests
  - id: task-228-13
    resource: backlog:TASK-228.13
    title: "Automation: choose_menu_item and close_menu wait in the input order while the agent pointer is on"
---

The [automation endpoint](./automation-endpoint.md)'s input never moves
the person's pointer ([how input is
delivered](./automation-endpoint-input.md)), so Detour draws where it acts
(TASK-228.11, `AutomationAgentPointer`).[^task-228-11][^agent-pointer] The
design was the user's (2026-11-15), after Claude in Chrome's virtual
cursor.

# How it works

- **A window of its own, not the page.** A borderless, clear overlay window
  (`AutomationAgentPointerWindow`) covering the target window's frame, added
  as its child window (`addChildWindow(_:ordered: .above)`), so it moves
  with the window and shows while Detour is in the background. It ignores
  mouse events, can never become key or main, is out of the Windows menu,
  `transient`, `ignoresCycle` and `fullScreenAuxiliary`. Its
  `sharingType` is left alone, so a full-screen recording shows it. An
  in-page cursor was rejected: the endpoint also clicks sidebar rows,
  menus, switches and Settings, and page scripts, `hit_test` and the page
  tools would see it.
- **A click** (`click`, and `type_text`'s `selector` click): after the
  arguments and gates are checked and open menus closed, the arrow, orange
  like the connected-agent capsule and tagged "Agent" (the tag moves to the
  arrow's left near the window's right edge), glides from where it last was
  in that window (the first time, from 40 points below and right of the
  point) in 150 ms, ripples, and then the click is delivered as before.
  Once in a run a client has staged a capture (`seed_world` or
  `set_window_frame`), the glide takes 600 ms, so a recording can follow it
  (`AutomationTools.stagingInUse`). With Reduce Motion (`MotionPreference`)
  it appears at the point, the ripple only fades, and nothing waits. It
  stays 3 s after the last click or key, then fades and leaves the parent's
  child windows; the next click glides from the same place. The user
  approved the 600 ms staging glide, the 3 s linger and the first glide's
  start on 2026-11-15.
- **The checks again after the glide** (`retarget`): the glide is a wait
  between the checks and the delivery, so the window must still be open and
  reachable (the Private setting is read again), a page must still be in
  it, and a window point is hit-tested again, with the gate on Settings'
  Automation section. A view put over the point meanwhile gets the click;
  the gate still refuses.
- **Arrival order** (`AutomationInputOrder`, `AutomationTools.inArrivalOrder`):
  while the pointer is on, `click`, `type_text`, `press_key`,
  `choose_menu_item` and `close_menu` run one at a time in the order the
  calls came. One client's calls are already in order (a connection is
  answered one request at a time, a batch in sequence), but another
  client's call sent during a click's glide would otherwise run before the
  click: keys delivered first (TASK-228.11), or a menu choice finding no
  menu yet and failing with `no_open_menu` (TASK-228.13; the tests show
  both without the order). So "right click, then choose an item" works
  across clients: the choice runs once the click is delivered and its menu
  open. The menu tools joined on the user's decision of 2026-11-15, which
  changes how they wait: `choose_menu_item`'s `timeout_ms` counts from its
  turn, not from its arrival, and while it waits for a menu that never
  opens, later input waits behind it (up to its timeout; chosen by Claude,
  not yet confirmed by the user: the alternative is to take the turn and
  then wait for the menu outside the order). `list_menu` and
  `hit_test` read only and stay out. An uncontended call awaits nothing;
  with the pointer off the tools run as before, and the menu tools never
  wait for a call holding the order. The order is not reentrant: nothing
  run in it calls another tool that uses it. Checked at runtime on
  2026-11-15 with two clients: a right click on a page with the 600 ms
  staging glide, and 150 ms into it `choose_menu_item` "Reload" with
  `timeout_ms` 100 from the other client chose it (answered 3 ms after the
  click; the page reloaded), then the same with `close_menu` (`closed`
  true); Detour stayed in the background.[^task-228-11][^task-228-13]
- **Typing** (`type_text`, `press_key`) outlines what takes the keys: a
  control (a field editor's field), or a page's focused element
  (`AutomationInput.focusedElementRect`, in the client content world,
  through open shadow roots), else the web view. The page's answer comes in
  while the keys are typed; nothing waits for it.
- **Not drawn** over a window that hangs off another (an extension popup's
  popover, a sheet: input by `context` into a popup gets no pointer) or
  while the window is closed, minimized, off every screen or on another
  Space: nothing waits for a glide nobody can see. A window covered by
  another app's windows still gets it. Browser, Quick Detour, quarantine
  and Settings windows all get it through the same routing.
- **Lifecycle.** One overlay per window, in a weak-keyed table, holding its
  window weakly; it hides when the window minimizes or leaves the screen
  and is closed and forgotten when the window closes
  (`WindowCloseReleaseTests` closes a window with the pointer and an
  outline showing). `set_window_frame window_number` never finds it, and
  `list_windows`, `hit_test` and the Window menu never see it.

# Screenshots leave it out

`source app` draws the target window's content view, which the overlay is
not in. `source screen` needed a change: ScreenCaptureKit's picture of one
window (`SCContentFilter(desktopIndependentWindow:)`) includes its child
windows, so the pointer was in it (seen at runtime). While an overlay is
over the window, the window is taken from its display instead, cropped to
the window's frame, with every window excluded but the window and its other
child windows (so the overlay, other apps' windows covering it and the
wallpaper are left out, a popover of the window kept;
`AutomationCapture.pointerFreeRegion`). `SCContentFilter(display:including:)`
with the window still drew the overlay, as if a window brought its children
along (checked twice at runtime). A window across two displays or on
another Space keeps the old path, pointer included. Checked at runtime: the
screenshot had no pointer while `screencapture -l` of the overlay, taken
right after, showed it. See [screenshots](./automation-endpoint-screenshots.md).

A full-screen recording (`screencapture -v` of the capture kit's virtual
display) does show it: on 2026-11-15 a click by selector, a click at a page
point and `type_text` into a field were recorded with the glide, the
ripple, the orange outline and the fade.[^task-228-11]

# The setting

Settings > General > Automation, "Show where agents click and type"
(`AutomationAgentPointerEnabled` in the data directory's defaults, read at
every call; off hides a pointer on screen). On by default for the user. In
a test run (`DETOUR_MCP=1` with an isolated data directory) it starts off,
so scripts and harnesses that never ask for it keep their speed (the user's
decision, 2026-11-15); a client turns it on with `set_debug_override
agent_pointer on` (Debug, test runs only) or the saved setting. The website
capture kit does (`docs/capture/capture.py`; its `--no-agent-pointer`
leaves it out), so the site's takes show where each click lands. The
XCTest host's tools have it off unless a test turns it on
(`AutomationEnvironment.showsAgentPointer`). The switch is in the
Automation section, which no input tool reaches.

# Tests

`AutomationAgentPointerTests` (off: a click and typing wait for nothing and
make no overlay; on: the 150 ms glide before the click, the overlay a
click-through child that is never key or main and no listed window, the
app's key and main windows unchanged; the staging glide and Reduce Motion;
`hit_test`, the first responder and a click through the pointer unchanged;
keys sent during a click's glide arriving after it; `choose_menu_item`
and `close_menu` sent during a right click's glide, with a timeout shorter
than the glide, acting on the menu that click opens, and with the pointer
off a click then a menu choice as before and the menu tools answering
while another call holds the order (both fail without the order); a view put over the
point during the glide getting the click while the Automation-section gate
still refuses; the outline on a page field and on a native field; a window
screenshot without the arrow; minimize and close; the setting's defaults,
the Debug override in test runs only, and the Settings switch) and
`WindowCloseReleaseTests`; see [the endpoint's
tests](./automation-endpoint-tests.md).[^tests]

# Related

- [Automation endpoint (MCP)](./automation-endpoint.md): the hub.
- [How input is delivered](./automation-endpoint-input.md): what happens
  after the glide.
- [Capture staging](./automation-endpoint-staging.md): what switches the
  glide to 600 ms.
- [Settings window](./settings.md): the General pane's switch.

[^task-228-11]: Automation: a visible agent pointer shows where the endpoint clicks and types
[^agent-pointer]: AutomationAgentPointer.swift (the setting, the overlay window, the glide, the arrival order)
[^tests]: MCPServerTests, AutomationHTTPTests, AutomationToolsTests, AutomationEndpointTests, and the other Automation suites
[^task-228-13]: Automation: choose_menu_item and close_menu wait in the input order while the agent pointer is on
