---
type: Playbook
title: In-process UI automation
description: How to click, type, swipe, switch appearance and capture views from inside the running app, what only external input can do, and why a locked screen silently breaks all of it.
tags: [playbook, harness, ui, automation, runtime]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-10T07:45:28Z }
sources:
  - id: task-169
    resource: backlog:TASK-169
    title: A hover-revealed sidebar sometimes stays open instead of hiding again
  - id: task-89
    resource: backlog:TASK-89
    title: Permanent in-process UI automation hook (debug builds only)
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
| A real key or Cmd+key | `NSEvent.keyEvent(with:…)`, `NSApp.postEvent` | takes the true path: page `keydown` first, then the main menu. A key some loaded extension declares as a command goes to that extension when the menu does not take it ([command shortcuts](../extensions/command-shortcuts.md)); the window must be key |
| A key equivalent, menu only | `NSApp.mainMenu?.performKeyEquivalent(with: event)` | |
| A key to whatever has focus | `window.firstResponder?.keyDown(with: event)` | Down arrow: `keyCode` 125, characters `"\u{F701}"`, flags `[.function, .numericPad]`[^notes-keyloop] |
| A menu item or toolbar action | `NSApp.sendAction(_:to:from:)` | |
| A native button | `button.performClick(nil)` | |
| A native `<select>` | posted click opens its `NSMenu`; posted Down/Up arrows and Return choose | only with the screen unlocked[^notes-inproc] |
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
  database.

# What still needs a person

- The real system keystroke path, when another app or a system shortcut
  may take the key first.
- Content that depends on the person's own accounts and data.
- Aesthetic judgement.

Everything else is either done, or reported as "not tested, testable
in-process". "Cannot be tested from here" is only true of the three items
above.

# Related

- [Debug harness](./debug-harness.md) — where this code lives.
- [UI probes](./ui-probes.md) — measurements rather than interactions.
- [Runtime verification](./runtime-verification.md) — launch and isolation.
- [Keyboard focus](../sidebar/keyboard-focus.md) — what the key tests are usually about.
- [Space paging](../sidebar/space-paging.md) — the swipe handler the synthetic events drive.

[^notes-inproc]: Session notes on in-process UI verification
[^notes-harness]: Session notes on the runtime debug harness
[^notes-keyloop]: Session notes on the key-view loop probe
[^notes-probes]: Session notes on hit-test and resize probes
[^task-169]: A hover-revealed sidebar sometimes stays open instead of hiding again
[^notes-updates]: Session notes on verifying the extension update UI
[^notes-capture]: Session notes on screen capture for UI verification
