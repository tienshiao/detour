---
type: Playbook
title: In-process UI automation
description: How to click, type, swipe, switch appearance and capture views from inside the running app, what only external input can do, and why a locked screen silently breaks all of it.
tags: [playbook, harness, ui, automation, runtime]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-27T09:30:00Z }
sources:
  - id: task-169
    resource: backlog:TASK-169
    title: A hover-revealed sidebar sometimes stays open instead of hiding again
  - id: task-174
    resource: backlog:TASK-174
    title: "A space's tab list takes keyboard focus, so keys go to the list instead of the page after a click"
  - id: task-89
    resource: backlog:TASK-89
    title: Permanent in-process UI automation hook (debug builds only)
  - id: harness-189
    resource: ../../docs/harness/task189-survey-harness.patch
    title: TASK-189 survey harness (the Settings window; an alert answered from the modal run loop)
  - id: harness-185
    resource: ../../docs/harness/task185-harness.patch
    title: TASK-185 harness (posted Option-click, the real link menu)
  - id: verify-skill
    resource: ../../.claude/skills/verify/SKILL.md
    title: The /verify skill (observation channels and permission gotchas)
  - id: task110-readme
    resource: ../../docs/task-110/README.md
    title: TASK-110 capture kit
  - id: notes-inproc
    resource: "Agent session notes, 2026-09-19 (not in the repository)"
    title: Session notes on in-process UI verification
  - id: notes-harness
    resource: "Agent session notes, 2026-09-25 (not in the repository)"
    title: Session notes on the runtime debug harness
  - id: notes-keyloop
    resource: "Agent session notes, 2026-10-02 (not in the repository)"
    title: Session notes on the key-view loop probe
  - id: notes-probes
    resource: "Agent session notes, 2026-10-01 (not in the repository)"
    title: Session notes on hit-test and resize probes
  - id: notes-updates
    resource: "Agent session notes, 2026-09-25 (not in the repository)"
    title: Session notes on verifying the extension update UI
  - id: notes-capture
    resource: "Agent session notes, 2026-09-23 (not in the repository)"
    title: Session notes on screen capture for UI verification
  - id: task-191-4
    resource: backlog:TASK-191.4
    title: "TASK-191.4: route typed URLs and links clicked inside Detour"
  - id: task-194-followup
    resource: ../../docs/harness/task194-followup-harness.patch
    title: TASK-194 follow-up runtime harness (inactive app, occluded window, clicks handed to the web view)
---

Almost every interaction check can be done by the app on itself. What an
agent's shell usually cannot do is act on the app from outside: posting
`CGEvent`s needs the Accessibility grant and `screencapture` needs the
Screen Recording grant for the process that hosts the shell, and without
them events are silently dropped and captures come out black. Inside the
process none of that applies. This page lists what works from a
[debug harness](./debug-harness.md) and what does not.

# When to use

Whenever a runtime check involves a click, a modifier-click, a key
equivalent, a swipe, light/dark appearance, a second window, a split, or a
picture of the result. Do these from the harness before concluding that a
person has to try it by hand.

# Steps

## 1. Check the screen is unlocked — before every run

```bash
ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked
```

(Needs the sandbox off in a sandboxed shell.) With the screen locked,
WebKit does not paint, so captures are blank, and posted `NSEvent`s never
reach the page, so every click and key step silently does nothing.[^notes-inproc]
The screen can lock again in the middle of a session. One crash signature
belongs to this state and is not an app bug: a WebKit trap in
`ProcessThrottler::sendPrepareToSuspendIPC` (`EXC_BREAKPOINT`) a few
seconds after the first posted click on a native `<select>`, seen only in
locked runs.[^notes-inproc]

Still usable while locked: `evaluateJavaScript` (DOM dumps, `el.click()`,
dispatched `KeyboardEvent`s), native sheets (`window.attachedSheet`,
`endSheet(_:returnCode:)`) and `sqlite3` checks. Real-event, key-equivalent
and visual checks have to wait; report them as not run, never as passed.

## 2. Pick the lightest tool that goes through the real path

| Want | Do | Notes |
|---|---|---|
| Activate a link or button in a page | `webView.evaluateJavaScript("document.querySelector(…).click()")` | goes through the real link-activation policy[^notes-inproc] |
| A real mouse click at a point | `NSEvent.mouseEvent(with:…)` for down and up, `NSApp.postEvent(_:atStart: false)` | see the trap below about `sendEvent` |
| Point for a page element | `webView.convert(NSPoint(x: cssX, y: cssY), to: nil)` | `WKWebView` is flipped, so CSS pixels convert directly[^notes-inproc] |
| A real key or Cmd+key | `NSEvent.keyEvent(with:…)`, `NSApp.postEvent` | takes the true path: page `keydown` first, then the main menu |
| A key equivalent, menu only | `NSApp.mainMenu?.performKeyEquivalent(with: event)` | |
| A key to whatever has focus | `window.firstResponder?.keyDown(with: event)` | Down arrow: `keyCode` 125, characters `"\u{F701}"`, flags `[.function, .numericPad]`[^notes-keyloop] |
| A menu item or toolbar action | `NSApp.sendAction(_:to:from:)` | |
| A native button | `button.performClick(nil)` | |
| A button whose action runs an `NSAlert` with `runModal()` | before the click, add a one-shot `Timer` in `.common` mode that finds `NSApp.modalWindow`, looks up the alert's button by title and calls `performClick`; then click the button from `DispatchQueue.main.async` | the modal session runs `.common`-mode timers, so the alert is answered and the action carries on along its real path (Settings' Uninstall Extension)[^harness-189] |
| A native `<select>` | posted click opens its `NSMenu`; posted Down/Up arrows and Return choose | only with the screen unlocked[^notes-inproc] |
| A modifier-click on a link (Option, Shift, Cmd) | posted down and up with `modifierFlags: .option` (etc.) at the link | reaches `decidePolicy` with those flags, as a person's click does |
| The page's context menu, and choosing an item | a posted `rightMouseDown`/`Up` on the element; WebKit builds the menu and calls `BrowserWebView.willOpenMenu`, where a temporary hook can read the items and, from a `.common`-mode timer, `menu.performActionForItem(at:)` then `cancelTracking()` | performs WebKit's own items (they need its live menu), so the action takes the real path; only with the screen unlocked[^harness-185] |
| Dark mode | `NSApp.appearance = NSAppearance(named: .darkAqua)`, wait, capture | |
| Split, second window, Private window | create them through `TabStore` / `BrowserWindowController` | |
| A trackpad swipe between spaces | synthetic continuous scroll events, below | |
| Sidebar hover reveal/hide | `wc.sidebarHoverZoneEntered(.edge)` / `sidebarHoverZoneExited(.sidebar)`, with `sidebarPointerProbeForTesting` or a window placed relative to the real pointer ([UI probes](./ui-probes.md)) | real tracking-area enter/exit cannot be synthesized; posted `mouseMoved` events produce none[^notes-probes][^task-169] |

Posted mouse and key events, as used against the History page (a short
pause between down and up, and a longer one to let the page settle):

```swift
var eventNumber = 1
func mouse(_ type: NSEvent.EventType, _ css: NSPoint) {
    eventNumber += 1
    let p = webView.convert(css, to: nil)
    guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil,
                                     eventNumber: eventNumber, clickCount: 1,
                                     pressure: type == .leftMouseDown ? 1 : 0) else { return }
    NSApp.postEvent(e, atStart: false)
}
func key(_ code: UInt16, _ chars: String, flags: NSEvent.ModifierFlags = []) {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil,
                                    characters: chars, charactersIgnoringModifiers: chars,
                                    isARepeat: false, keyCode: code) {
            NSApp.postEvent(e, atStart: false)
        }
    }
}
```

Recompute element rectangles after every step that can reflow the page.

## 3. Swipes

The space-swipe handler can be driven with synthetic scroll events and no
privacy grant:[^notes-harness]

1. `CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0)`
2. set `.scrollWheelEventIsContinuous` to 1, `.scrollWheelEventScrollPhase`
   to 1 (began), 2 (changed) or 4 (ended), and
   `.scrollWheelEventPointDeltaAxis2` to the horizontal delta;
3. wrap it in `NSEvent(cgEvent:)` and call `scrollView.scrollWheel(with:)`
   on the page's scroll view.

Space the events about 16 ms apart, and pause before capturing a layer, or
the incoming page renders blank.

## 4. Capture

| Target | Method | Result |
|---|---|---|
| Window content, including web content | `view.bitmapImageRepForCachingDisplay(in:)` then `view.cacheDisplay(in:to:)` on `window.contentView` | works with no grant; the **sidebar comes out blank**[^notes-harness] |
| The sidebar | `wc.tabSidebar.view.layer?.render(in:)` into an `NSGraphicsContext(bitmapImageRep:)` | 1x image; crop or scale with `sips`[^notes-harness] |
| The Settings window | `cacheDisplay` in light mode | after switching to `darkAqua` its background renders transparent[^notes-updates] |
| True pixels, occluded windows, video | `screencapture -x -o -l <windowID>`, `screencapture -v` | needs Screen Recording for the shell's host process; check with one full-screen capture first (all black means no grant)[^notes-capture] |
| Retina captures on a 1x display | the virtual 2x display in [docs/task-110](../../docs/task-110/README.md) | see [release and website](./release-and-website.md) |

```swift
func snapSidebar(_ wc: BrowserWindowController, to url: URL) {
    let view = wc.tabSidebar.view
    guard let layer = view.layer,
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width),
                                     pixelsHigh: Int(view.bounds.height), bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
    layer.render(in: ctx.cgContext)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}
```

`CGWindowListCreateImage` does not compile against the current SDK (the
compiler points to ScreenCaptureKit).[^notes-harness]

Prefer a number to a picture when the question is layout: log
`view.convert(view.bounds, to: nil)` for the views in question and compare
edges ([UI probes](./ui-probes.md)).

# Traps

- **Do not deliver events with `window.sendEvent` from inside a Swift
  `Task`.** A click that lands on the window's top `WindowDragView` enters
  a nested event-tracking loop, and AppKit throws from
  `nextEventMatchingMask` (SIGABRT) when that loop is entered from a task
  frame. Post events with `NSApp.postEvent` instead.[^notes-inproc] See
  [AppKit gotchas](../platform/appkit-gotchas.md).
- **`mouseMoved(with:)` does not produce a `:hover` look** in a
  `cacheDisplay` capture.[^notes-inproc]
- **A posted click does not select an `NSTableView` row when the app is not
  active.** In a shell-launched instance and in the test host, a posted
  mouse-down and mouse-up on a sidebar row went through `NSWindow.sendEvent`
  (first responder moved to a list that accepted it) but the selection did
  not change; nor did it with `tableView.mouseDown(with:)` called directly
  and the mouse-up queued. Not tried in an active application. Make the
  selection with `selectRowIndexes` (it runs the delegate's selection
  handler) and use the posted click for what else the click does.[^task-174]
- **A posted plain click on a web view of an inactive app is swallowed; a
  Cmd-click is not.** In the TASK-191.4 run the user was in another app: the
  posted Cmd-clicks reached the page (macOS delivers a Cmd-click to a
  background window without activating it) and every plain click produced
  no navigation action at all. Activate Detour
  (`NSApp.activate(ignoringOtherApps: true)`) and make the window key before
  posting, check `NSApp.isActive` and the key window when the event goes
  out, and log both; even then an occasional first click after the window
  became key did not land and had to be re-posted, so confirm each click by
  its effect (the policy log line), not by having posted it.[^task-191-4]
  When activation is refused outright (macOS 26's cooperative activation:
  `NSApp.isActive` stays false while the person's app is in front), the
  new window also opens *behind* their windows, occluded, and WebKit paints
  nothing (a blank page in the capture). What worked (TASK-194 follow-up,
  2026-10-27): `window.orderFrontRegardless()` (no activation) to
  un-occlude it, Cmd-clicks posted as usual, and plain clicks handed to the
  web view itself — `webView.mouseDown(with:)`, a 0.1 s pause,
  `webView.mouseUp(with:)`, real `NSEvent`s at the element's point — which
  WebKit took as a user's click (an anchor jump, a `download` link). Do not
  set `window.level = .floating` from the harness `Task`: it trapped in
  `-[NSWMWindowCoordinator performTransactionUsingBlock:]` (SIGTRAP, exit
  133).[^task-194-followup]
- **A posted drag starts a real drag session that cannot be aimed.** Posted
  `leftMouseDown` and `leftMouseDragged` events on an `NSTableView` row begin
  a drag session, but the session tracks the real pointer, not the posted
  events: in the TASK-191.3 run it outlived the posted mouse-up, swallowed
  the next posted click, dropped wherever the pointer happened to be, and
  pop-up menus no longer opened for posted clicks afterwards. Drive drops
  with a stub `NSDraggingInfo` ([debug harness](./debug-harness.md)), and
  put any posted-drag probe last in a run.
- **A window drag needs the real pointer: post it at the HID tap.**
  Posted `NSEvent`s reach a view's tracking loop, so they show a drag
  *begins* (`performDrag(with:)` is called), but the window server follows
  the hardware pointer, so do not count on them to move the window (not
  measured). From the in-process harness, `CGEvent(mouseEventSource:
  mouseType:mouseCursorPosition:mouseButton:)` posted at `.cghidEventTap`
  — a move, a down, a dozen dragged steps 30 ms apart, an up, then
  `CGWarpMouseCursorPosition` back — moved a Quick Detour by the dragged
  distance, and the same with no movement was a click (TASK-210,
  2026-10-26). Global coordinates are top-left: flip `y` against the first
  screen's `maxY`. These are HID input, so the idle gate sees them: the
  next wait for 12 s of idle is the harness's own doing.
- **Posted mouse events in a unit test come back moved.** In the test host,
  an `NSEvent.mouseEvent(... windowNumber:)` through `NSApp.postEvent` and
  `nextEvent` returned with its location scaled and flipped (the round trip
  through screen coordinates), ordered window or not. A view's own tracking
  loop is testable by injecting its event source instead (TASK-210,
  `QuickDetourBarButton.nextPressEvent`).
- **A pop-up's item, through its real menu**: a posted mouse-down alone
  opens an `NSPopUpButton`'s menu; on `NSMenu.didBeginTrackingNotification`
  schedule a `.common`-mode timer that calls `menu.performActionForItem(at:)`
  then `cancelTracking()`. The pop-up selects the item and sends its action
  (TASK-191.3, every pop-up of the Links pane).
- **A popped-up `NSMenu` takes posted keys.** Its tracking loop reads the
  app's event queue, so Down arrows and Return posted from `.common`-mode
  timers (scheduled before the posted click that opens it) choose an item
  as a person would; Escape closes it. Section headers are skipped by the
  arrows (TASK-193.3, the Quick Detour's Open in dropdown).
- **Wait for the person to be idle.** When someone is using the machine,
  each activation takes the focus from them and their keystrokes land in
  Detour (TASK-193.3: stray text in a page's field, a letter before a typed
  URL that turned it into a search). Gate every activation and refocus on
  `CGEventSource.secondsSinceLastEventType(.combinedSessionState,
  eventType: CGEventType(rawValue: ~0)!)` (HID input only; `NSApp.postEvent`
  events do not count), e.g. 12 s, and log human input seen while posting.
  A region capture (`screencapture -R`) shows whatever is in front: one
  taken after the person brought their own window forward showed it, and
  had to be deleted.
- **A shell-launched instance is not the key application.** Anything
  enabled by `NSApp.keyWindow` (for example menu items validated against
  the key window) cannot be driven; say so.[^notes-updates]
- **Full Keyboard Access cannot be forced for one process.** Neither the
  `-AppleKeyboardUIMode 2` launch argument nor swizzling
  `NSApplication.isFullKeyboardAccessEnabled` changes
  `NSButton.canBecomeKeyView`.[^notes-keyloop]
- **Form state restore.** On reload and session restore WebKit restores
  `<select>` and date values after the page script has run. Internal pages
  have to re-sync their controls from state; a harness that reads a control
  right after load can read the pre-restore value.[^notes-inproc] See
  [internal pages](../features/internal-pages.md).
- **External input is unproven even with grants.** Before relying on
  posted `CGEvent`s from outside, test one click whose effect shows in the
  database. For a global hotkey and anything pressed while another app is
  in front, see [testing a global hotkey](./global-hotkey-testing.md):
  posted at the HID event tap from scratch tools, it worked (TASK-193.2).

# What still needs a person

- The real system keystroke path, when another app or a system shortcut
  may take the key first (keys posted at the HID event tap go through the
  window server's hotkey matching, but a person's key press is still the
  last word).
- Content that depends on the person's own accounts and data.
- Aesthetic judgement.

Everything else is either done, or reported as "not tested, testable
in-process". "Cannot be tested from here" is only true of the three items
above.

# Related

- [Debug harness](./debug-harness.md) — where this code lives.
- [Testing a global hotkey](./global-hotkey-testing.md) — input from outside the app, at the HID event tap.
- [UI probes](./ui-probes.md) — measurements rather than interactions.
- [Runtime verification](./runtime-verification.md) — launch and isolation.
- [Keyboard focus](../sidebar/keyboard-focus.md) — what the key tests are usually about.
- [Space paging](../sidebar/space-paging.md) — the swipe handler the synthetic events drive.

[^notes-inproc]: Session notes on in-process UI verification
[^notes-harness]: Session notes on the runtime debug harness
[^notes-keyloop]: Session notes on the key-view loop probe
[^notes-probes]: Session notes on hit-test and resize probes
[^task-169]: A hover-revealed sidebar sometimes stays open instead of hiding again
[^task-174]: A space's tab list takes keyboard focus, so keys go to the list instead of the page after a click
[^notes-updates]: Session notes on verifying the extension update UI
[^notes-capture]: Session notes on screen capture for UI verification
[^harness-189]: TASK-189 survey harness (the Settings window; an alert answered from the modal run loop)
[^harness-185]: TASK-185 harness (posted Option-click, the real link menu)
[^task-191-4]: TASK-191.4: route typed URLs and links clicked inside Detour
[^task-194-followup]: TASK-194 follow-up runtime harness (inactive app, occluded window, clicks handed to the web view)
