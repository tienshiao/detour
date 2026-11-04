---
type: Playbook
title: UI probes
description: Measurements to paste into a debug harness when clicks do not land, a window edge will not resize, or keyboard focus is somewhere unexpected — hit-test maps, resize-region probes, first-responder and key-view loop dumps, layout gaps.
tags: [playbook, harness, appkit, focus, hit-testing]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-10T07:45:28Z }
sources:
  - id: task-169
    resource: backlog:TASK-169
    title: A hover-revealed sidebar sometimes stays open instead of hiding again
  - id: task-126
    resource: backlog:TASK-126
    title: The Downloads button's left and bottom edges do not respond to clicks
  - id: task-127
    resource: backlog:TASK-127
    title: With auto-hide on, the downloads popover disappears when the sidebar hides
  - id: task-128
    resource: backlog:TASK-128
    title: On launch the sidebar's hidden search field holds keyboard focus
  - id: task-130
    resource: backlog:TASK-130
    title: Keyboard focus stays behind on a tab list whose page has slid off screen
  - id: window-controller
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift (setupEdgeHoverTracking, handleSidebarEvent)
  - id: visibility-state
    resource: ../../Detour/Browser/Window/SidebarVisibilityState.swift
    title: SidebarVisibilityState.swift
  - id: focus-tests
    resource: ../../DetourTests/SidebarPageFocusTests.swift
    title: SidebarPageFocusTests.swift
  - id: notes-probes
    resource: "Agent session notes, 2026-10-01 (not in the repository)"
    title: Session notes on hit-test and resize probes
  - id: notes-keyloop
    resource: "Agent session notes, 2026-10-02 (not in the repository)"
    title: Session notes on the key-view loop probe
  - id: notes-updates
    resource: "Agent session notes, 2026-09-25 (not in the repository)"
    title: Session notes on verifying the extension update UI
---

These are probes, not interactions: each one asks AppKit a question on a
grid or along a chain and writes the answer to the harness log as text. The
point is to measure before fixing. One reviewed claim ("Tab from the page
lands on an off-screen sidebar control") turned out to be false when the
key-view loop was actually dumped.[^notes-keyloop]

All of them run inside a [debug harness](./debug-harness.md), a couple of
seconds after launch.

# When to use

| Symptom | Probe |
|---|---|
| Part of a control does not respond to clicks | hit-test map |
| A window edge near a control resizes instead of clicking, or will not resize | resize-region probe |
| Typing goes to the wrong place after launch or after a view change | first-responder dump |
| Tab / Shift-Tab goes somewhere unexpected, or nowhere | key-view loop probe |
| Padding or alignment looks off | layout gaps |
| Auto-hide sidebar and popovers misbehave | injected visibility events |

# Steps

## Hit-test map

Hit-test a 1-point grid around the control from the window's theme frame
and print one character per point. Overlapping invisible views show up at
a glance.

```swift
guard let window = wc.window, let frameView = window.contentView?.superview else { return }  // NSThemeFrame
let b = button.convert(button.bounds, to: nil)          // window coordinates
var legend: [String: Character] = [:]
var letters = Array("abcdefghijklmnopqrstuvwxyz").makeIterator()
func symbol(for view: NSView?) -> Character {
    guard let view else { return " " }
    if view === button || view.isDescendant(of: button) { return "#" }
    var chain: [String] = []; var cur: NSView? = view
    while let c = cur, chain.count < 3 {
        chain.append("\(type(of: c))" + (c.mouseDownCanMoveWindow ? "(moves)" : "")); cur = c.superview
    }
    let key = chain.joined(separator: "<")
    if let ch = legend[key] { return ch }
    let ch = letters.next() ?? "?"; legend[key] = ch; return ch
}
for y in stride(from: Int(b.maxY) + 3, through: max(0, Int(b.minY) - 9), by: -1) {
    var row = ""
    for x in (Int(b.minX) - 9)...(Int(b.maxX) + 9) {
        row.append(symbol(for: frameView.hitTest(NSPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))))
    }
    log(String(format: "y=%3d ", y) + row)
}
for (k, v) in legend.sorted(by: { $0.value < $1.value }) { log("legend \(v) = \(k)") }
```

Reading it: `#` is the control, each letter is another view's class chain
(with `(moves)` where `mouseDownCanMoveWindow` is true, which is how a
click turns into a window drag). A column of some other letter down one
side of the control is a view lying on top of it.

What it found: the 20-point edge strip used for hover tracking lay over the
sidebar's leading edge and took the clicks on the left of the Downloads
button. The strip is now a `ClickThroughView` (see `setupEdgeHoverTracking`).[^task-126]
It also showed that an `NSButton`'s frame is taller than its height
constraint (alignment rect insets: 24 points constrained, 31 in the frame)
and that macOS 26 insets the sidebar 8 points from the window
edge.[^notes-probes]

## Resize-region probe

AppKit has two private selectors that say whether a point belongs to the
window's resize region:

- `-[NSThemeFrame _isInResizeRegion:]` — `BOOL` from a `CGPoint`
- `-[NSWindow _resizeDirectionForMouseLocation:]` — an integer from a `CGPoint`

```swift
typealias BoolFn = @convention(c) (AnyObject, Selector, NSPoint) -> Bool
let sel = NSSelectorFromString("_isInResizeRegion:")
if frameView.responds(to: sel) {
    let fn = unsafeBitCast(frameView.method(for: sel), to: BoolFn.self)
    // same grid as above: fn(frameView, sel, point) ? "R" : "."
}
```

Probe them in **separate launches**. Each works alone; calling both in one
grid pass crashed the app.[^notes-probes] Result on macOS 26: the resize
region is the bottom 3 points plus the rounded-corner cutout only, and it
does not reach the sidebar's bottom buttons.[^notes-probes][^task-126]
These are private API: harness only, never shipped.

## First-responder dump

Log the first responder with its superview chain right after `showWindow`
and again a second or two later:

```swift
func describeResponder() -> String {
    guard let window = wc.window else { return "no window" }
    let r = window.firstResponder
    var s = r.map { "\(type(of: $0))" } ?? "nil"
    if r === window { s += " (the window)" }
    if let v = r as? NSView {
        if v === wc.selectedTab?.webView { s += " = selected tab's web view" }
        if v.isDescendant(of: wc.tabSidebar.view) { s += " (inside the sidebar)" }
        var chain: [String] = []; var cur: NSView? = v
        while let c = cur, chain.count < 6 { chain.append("\(type(of: c))"); cur = c.superview }
        s += " chain=" + chain.joined(separator: "<")
    }
    return s + " key=\(window.isKeyWindow)"
}
```

A field editor shows up as an `NSTextView` whose `delegate` is the
`NSTextField`; print the field's placeholder to tell which one it is.

What it found: with no `initialFirstResponder`, AppKit focuses the
window's first key view when the window is first shown, even for a window
that is not key (an app launched with `open -g`). That is how a hidden
search field ended up holding focus at launch.[^task-128]

## Key-view loop probe

For each state of interest (first space, second space, archive page
showing, sidebar collapsed), dump:

1. `window.autorecalculatesKeyViewLoop` and `NSApp.isFullKeyboardAccessEnabled`;
2. every view under the theme frame where `acceptsFirstResponder` is true
   or `nextKeyView` is non-nil, with `canBecomeKeyView` and where
   `nextKeyView` points;
3. the chain from `window.initialFirstResponder` following `nextKeyView`
   (stop on a repeat);
4. where Tab really lands: `window.makeFirstResponder(nil)` then
   `window.selectNextKeyView(nil)` a few times, and
   `selectPreviousKeyView(nil)` once;
5. the same from the sidebar table and from the selected web view
   (`window.selectKeyView(following:)` / `preceding:` is what WebKit calls
   when Tab leaves the page).

For each view log its page (walk up to a `SpacePageView` or
`ArchivePageView`), whether it is on screen (`!visibleRect.isEmpty`),
`isHiddenOrHasHiddenAncestor` and its frame in window coordinates. An
off-screen view that still holds focus is the bug class to look for.

What it measured (2026-10-02):[^notes-keyloop]

- AppKit builds the loop once, when the window is first shown
  (`autorecalculatesKeyViewLoop` is false). It contains only views that
  existed then. Web views and the space pages' tables are created later
  and have `nextKeyView == nil`, so Tab from a page or a tab list goes
  nowhere.
- The real defect was focus left behind: a control keeps first responder
  when its page slides off screen and still answers arrow keys.[^task-130]
- `canBecomeKeyView` is false for `NSScrollView` and `NSClipView`, and for
  buttons when Full Keyboard Access is off. Behaviour with it on is
  unmeasured; it cannot be forced for one process.

To reproduce a left-behind focus, focus the list
(`window.makeFirstResponder(table)`), change the page
(`showArchivePage(animated: false)` or `setActiveSpace(id:)`), send a Down
arrow to `window.firstResponder` and log the selection before and after.

The conclusions are on [keyboard focus](../sidebar/keyboard-focus.md).

## Layout gaps

Log distances instead of judging a screenshot:[^notes-updates]

```swift
let c = container.convert(container.bounds, to: nil)
let t = title.convert(title.bounds, to: nil)
let bt = button.convert(button.alignmentRect(forFrame: button.bounds), to: nil)
log("top gap=\(c.maxY - t.maxY) bottom gap=\(bt.minY - c.minY)")
```

Then grep the app's stderr for `Unable to simultaneously satisfy`. Check
that the pane fits at rest before judging padding: in a fixed-size window
an overflowing column squeezes its lowest-priority view to zero first (the
Settings window was one until TASK-189; its panes now size to their content
and scroll as a whole). For a whole window in many states, light and dark, the
TASK-189 survey harness (`docs/harness/task189-survey-harness.patch`) dumps
every view's frame, alignment rect and baseline to JSON and derives clips,
truncations, gaps and baseline offsets from it.
See [settings](../features/settings.md) and
[AppKit gotchas](../platform/appkit-gotchas.md).

## Injected sidebar visibility events

Real tracking-area enter and exit cannot be synthesized: `mouseMoved`
events posted with `NSApp.postEvent` produced no `mouseEntered` or
`mouseExited`, even for an `.activeAlways` tracking area.[^task-169] Call
what the tracking areas would call, and replace or position the pointer:

```swift
wc.toggleSidebarAutoHide()
wc.sidebarPointerProbeForTesting = { false }   // or leave nil: the real pointer
wc.sidebarHoverZoneEntered(.edge)              // the reveal
wc.sidebarHoverZoneExited(.sidebar)            // an exit, if the case has one
// … then log wc.sidebarItem.isCollapsed and wc.sidebarVisibility over time
```

The pointer's real *position* can be part of the check without moving it:
read `NSEvent.mouseLocation` and place the window so that the sidebar is
away from the pointer, or under it. The second only tells something if
nobody moves the pointer in the meantime; the one attempt ended with the
pointer moved away a second later. The kept harness is
[docs/harness/task169-harness.patch](../../docs/harness/task169-harness.patch).[^task-169]

Popovers are `_NSPopoverWindow` child windows whose `parent` is the
browser window, so `wc.window?.childWindows` tells whether one is still
up.[^task-127] State the limit in the result: the events were injected,
the pointer never moved. See
[visibility and auto-hide](../sidebar/visibility-and-auto-hide.md).

# Traps

- **`makeFirstResponder` returning true proves nothing.** It does not
  consult `acceptsFirstResponder`, and it returns true even when
  `becomeFirstResponder` declines, in which case the window itself becomes
  first responder. Assert on `window.firstResponder`.[^notes-keyloop]
- **The probe changes what it measures.** Steps that call
  `makeFirstResponder` move focus; restore it, and run separate launches
  for separate questions.
- **A non-key window behaves differently.** `open -g` leaves the app in
  the background; call `window.makeKey()` in the harness when the question
  is about a key window, and log `isKeyWindow` with every line.
- **A unit test may be the better home.** A real, non-incognito window
  can be built in a test: add spaces to `TabStore.shared` under an
  existing profile, `BrowserWindowController(incognito: false)`,
  `setActiveSpace`, `showWindow`, and `deleteSpace` in tearDown
  (`SidebarPageFocusTests`).

# Related

- [Debug harness](./debug-harness.md) — where probes run.
- [In-process UI automation](./in-process-ui-automation.md) — sending the keys and clicks.
- [Keyboard focus](../sidebar/keyboard-focus.md) — what the focus probes established.
- [Visibility and auto-hide](../sidebar/visibility-and-auto-hide.md) — the state machine the injected events drive.
- [AppKit gotchas](../platform/appkit-gotchas.md) — the traps these probes uncovered.

[^task-126]: TASK-126
[^task-127]: TASK-127
[^task-128]: TASK-128
[^task-130]: TASK-130
[^task-169]: TASK-169
[^notes-probes]: Session notes on hit-test and resize probes
[^notes-keyloop]: Session notes on the key-view loop probe
[^notes-updates]: Session notes on verifying the extension update UI
