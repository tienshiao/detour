---
type: Feature
title: Debugger API
description: chrome.debugger over an emulated subset of the Chrome DevTools Protocol — attachments and Chrome's rules for them, how an attachment ends, tab ids kept natively, the shared parked event channel, Page.captureScreenshot geometry, synthesized input and what keeps it in the tab, the user's Stop, and what differs from Chrome.
tags: [extensions, debugger, cdp, polyfill, events, claude-extension]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-08T02:30:00Z }
sources:
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift (debuggerJS)
  - id: handler
    resource: ../../Detour/Extensions/Runtime/ExtensionPolyfillHandler+Debugger.swift
    title: ExtensionPolyfillHandler+Debugger.swift
  - id: model
    resource: ../../Detour/Extensions/Runtime/ExtensionDebugger.swift
    title: ExtensionDebugger.swift (sessions, rules, lifecycle)
  - id: commands
    resource: ../../Detour/Extensions/Runtime/ExtensionDebugger+Commands.swift
    title: ExtensionDebugger+Commands.swift (dispatch, Page, screenshots)
  - id: parking
    resource: ../../Detour/Extensions/Runtime/ExtensionEventParking.swift
    title: ExtensionEventParking.swift
  - id: chromium
    resource: https://github.com/chromium/chromium/blob/main/chrome/browser/extensions/api/debugger/debugger_api.cc
    title: Chromium, debugger_api.cc
  - id: tests
    resource: ../../DetourTests/ExtensionDebuggerTests.swift
    title: ExtensionDebuggerTests (real contexts) and ExtensionDebuggerUnitTests
  - id: input
    resource: ../../Detour/Extensions/Runtime/ExtensionDebugger+Input.swift
    title: ExtensionDebugger+Input.swift (the Input domain)
  - id: drag-guard
    resource: ../../Detour/Browser/Window/AutomationDragGuard.swift
    title: AutomationDragGuard.swift
  - id: webkit-drag
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/mac/WebViewImpl.mm
    title: WebKit, WebViewImpl.mm (startDrag, mouse handlers)
  - id: webkit-menu
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/mac/WebContextMenuProxyMac.mm
    title: WebKit, WebContextMenuProxyMac.mm
  - id: chromium-input
    resource: https://github.com/chromium/chromium/blob/main/content/browser/devtools/protocol/input_handler.cc
    title: Chromium, input_handler.cc
  - id: input-tests
    resource: ../../DetourTests/ExtensionDebuggerInputTests.swift
    title: ExtensionDebuggerInputTests and ExtensionDebuggerInputUnitTests
  - id: task-input
    resource: backlog:TASK-132.14
    title: "Extensions: chrome.debugger input — Input.dispatchMouseEvent, dispatchKeyEvent, insertText"
  - id: task
    resource: backlog:TASK-132.13
    title: "Extensions: chrome.debugger attach/detach/sendCommand plumbing and Page.captureScreenshot"
---

# Summary

WebKit has no `chrome.debugger` and no Chrome DevTools Protocol (CDP). The
Claude extension drives pages through it (screenshots, input, evaluation,
dialogs, console and network events), so Detour emulates the methods it
sends, natively, one CDP domain at a time. TASK-132.13 is the plumbing and
`Page.captureScreenshot`; input (132.14), `Runtime.evaluate` and dialogs
(132.15) and console / network events (132.16) add domains.[^task]

# What the Claude extension does with it

Read from its 1.0.105 bundle: it attaches with `{tabId}` and version `"1.3"`
(detaching first, with its own timeout), checks `getTargets()` for
`attached` before re-attaching, and retries a command once after an error
containing "debugger is not attached" or "detached while handling command"
(lower-cased), so those texts matter. Before every command from the worker it
sends `Emulation.setFocusEmulationEnabled` and ignores any other error. It
registers `onEvent` / `onDetach` at module evaluation, which is why the worker
needed the namespace even before this task (the TASK-132.4 stand-in this
replaced). Screenshots: it measures `innerWidth`, `innerHeight`, `scrollX`,
`scrollY` and `devicePixelRatio` itself, asks for
`clip {x: scrollX, y: scrollY, width: innerWidth, height: innerHeight, scale}`
and compares the decoded image with `width × devicePixelRatio × scale`,
resizing on a mismatch.

# Chrome's rules, as followed

From Chromium's `debugger_api.cc`:[^chromium]

- One debugger per tab: a second attach, by the same extension too, fails
  "Another debugger is already attached to the tab with id: N.".
- The `debugger` permission implies every site, so no host permission is
  checked. Refused anyway: other extensions' pages, restricted schemes
  ("Cannot access a detour:// URL" for Detour's own), the gallery ("The
  extensions gallery cannot be scripted."). Allowed: blank pages, the error
  page (Chrome allows its own), files, data and blob URLs (a blob is judged by
  its origin), the extension's own pages.
- An explicit `detach()` fires no `onDetach`; nor does the extension
  unloading. The target closing fires `target_closed` (also used here for a
  navigation to a refused page and the tab leaving the profile), the user
  cancelling `canceled_by_user`; in-flight commands fail "Detached while
  handling command.".
- A CDP error reaches `lastError` as the JSON of `{code, message}`; an
  unknown method is `{"code":-32601,"message":"'X' wasn't found"}`.

# How a tab is named

`attach` resolves the extension's tab id through the
[tab id bridge](./tab-and-window-bridge.md) once, and sends both the handle
and the id. The session keeps the id: WebKit's tab id is one per tab across
the extension's worker and pages, so `detach`, `sendCommand` and every event
name the tab by that id alone, matched only against this extension's
sessions in this profile. That saves a bridge round trip per command (input
sends many) and lets an event reach a context that never resolved the tab.
A lie about the id from a context that bypasses the polyfill only confuses
its own extension: the handle, checked against the profile, decides which
tab is attached.

`getTargets` lists what `tabs.query({})` lists (WebKit's own query, not the
tab groups wrapper), resolving each tab, and reads `attached`, `title`, `url`
and `faviconUrl` natively. Target ids are `detour-tab-<handle>`.

# The attachment

`ExtensionDebugger` (process-wide, keyed by tab) owns the sessions. An attach
makes the tab *automation-attached*
(`TabAutomationOwner(extensionID, reason: "debugger")`), which wakes it,
exempts it from sleep and archive, and parks it hidden in a window when none
shows it, so an unselected tab can be captured and driven
(docs/webview-ownership.md). What ends a session:

| Trigger | Hook | onDetach |
|---|---|---|
| `detach()` | handler | none |
| extension unloaded (disabled, removed, reloaded) | `Profile.unloadExtension` | none |
| tab closed, slept as a Peek, moved to another profile | `ExtensionTabLifecycle.didClose` | `target_closed` |
| navigation to a refused page | the session's `tab.$url` sink | `target_closed` |
| the user's Stop | `TabAutomationStop` handler | `canceled_by_user` |
| `debugger` no longer active (Settings) | `permissionDecisionsDidChangeNotification` | `canceled_by_user` |

The Stop handler is registered at every attach rather than once, so a test
that clears `TabAutomationStop`'s handlers cannot leave a later attachment
unstoppable.

# Events

`ExtensionEventParking` is the parked-request channel extracted from the tab
group hub: per JS context a slot (pages too, held weakly by web view, at most
8 per extension), one background slot that a newer incarnation supersedes, a
backlog acknowledged by `seq`, and a wake for a background that has parked.
The debugger's channel is one per profile, registered with
`ExtensionDebugger`, with a 1000-event backlog (console and network events
will be frequent). Events go to the session's extension only, and a domain's
events only while it is enabled (`Page.enable`, …); a detach always goes.

# Page.captureScreenshot

Over `WKWebView.takeSnapshot`, which renders a parked (hidden) page fresh.
The viewport is read in Detour's own content world (`DetourDebugger`), so the
page cannot see or answer the question. Geometry, as Chrome: the clip is in
document CSS pixels (the scroll offset comes off), points per CSS pixel is
the view width over `innerWidth` (page zoom), and the image is
`clip.width × scale × devicePixelRatio` pixels (the viewport's CSS size ×
`devicePixelRatio` without a clip). The snapshot is asked at about that
resolution and drawn into a bitmap of exactly that size, then encoded off the
main actor (PNG, JPEG with white under transparency and Chrome's default
quality 80, WebP). A snapshot that does not answer in 15 s fails
"Unable to capture screenshot".

# Input

`Input.dispatchMouseEvent`, `Input.dispatchKeyEvent` and `Input.insertText`
are real NSEvents sent straight to the attached tab's web view, parked or
displayed, so the page sees trusted events (`isTrusted` true).[^task-input]
Never through `NSApp.sendEvent` or the window, which route by key window,
first responder and hit testing (see the tab parking notes in
[webview ownership](../../docs/webview-ownership.md)).

**Coordinates.** CDP's `x` / `y` are CSS pixels of the viewport. They are
mapped exactly as a screenshot is (view width over `innerWidth`), so a point
read off a screenshot lands on what the screenshot shows, at any page zoom.
The scroll offset does not enter: the coordinates are viewport-relative.

**One event at a time, answered after the page handled it.** WebKit queues
mouse and key events per page and sends the next one only after the page has
acknowledged the last. Measured: three key presses sent back to back,
followed by one script round trip, left one letter typed when the round trip
returned. So each session has a serial queue. An event is sent while nothing
is queued, and a script round trip in the `DetourDebugger` world behind it
returns after the page has handled it, because both go to the same process
in order. The command is answered then, given up after 10 s, as Chrome
answers when the renderer acks. A caller can screenshot right after a click
and see its effect.

**What is built how.**

| CDP | AppKit |
|---|---|
| left / right press, release, move with `buttons` | `NSEvent.mouseEvent` (a move with a button held is `…MouseDragged`) |
| middle, back, forward; `mouseWheel` | a `CGEvent` made into an NSEvent: the factory has no wheel events and gives other-button events button number 0. With no window, such an event reports its screen location as `locationInWindow`, so it is placed where the screen point equals the window point. Pixel wheel units, sign flipped (CDP's down is AppKit's negative) |
| `keyDown` / `rawKeyDown` / `keyUp` | `NSEvent.keyEvent` through `AutomationInput.sendKey`. Key code from `code`, else `windowsVirtualKeyCode`, else `key`; `nativeVirtualKeyCode` wins. Named keys carry AppKit's function-key characters (arrows with `.function` + `.numericPad`), so their bindings act on a `rawKeyDown` as Chrome's keydown does; only Enter's line break, which is text, is withheld. Control+letter carries the control character, which the text system's bindings match (also on a `rawKeyDown`). Shift+Tab is a back tab. A `rawKeyDown` of a character key carries no characters, so nothing is typed |
| a modifier key itself (`Shift`, `Meta`, …) | `flagsChanged` |
| `char`, `Input.insertText` | `NSTextInputClient.insertText` (WKWebView implements it without declaring it): `beforeinput` / `input`, no key events. Non-ASCII and emoji work |

**`commands`.** On a Mac, Chrome clients attach editing commands to a key
down (the Claude extension: `cmd+a` → `selectAll`, `backspace` →
`deleteBackward`, …). A key event sent to the view already performs the text
system's key bindings: arrows, Backspace, Ctrl+A (start of line) and Enter
work with no help. Running those commands again would do them twice. What
the key event does not do is a menu key equivalent. Measured: Cmd+A sent as
a key down reaches the page, but selects nothing on a parked page. On the
displayed one, WebKit hands it back unhandled, and AppKit would give it to
the menu. A parked view also answers `performKeyEquivalent` with false
before the page sees it, because it is not first responder. So only
`selectAll`, `copy`, `cut`, `paste` and `pasteAndMatchStyle` run, sent to the
web view itself, and only when the key down was not cancelled. As in Chrome,
a page that handles Cmd+A itself gets no second select-all. Cancellation is
read from a capture listener in Detour's own world on the main frame. A key
down into a subframe is not seen there, and its commands run regardless.
`undo` / `redo` run only on a parked page, whose edits have an undo manager
of their own. A displayed page's edits share the window's with the
browser's own actions, where undo could reopen a closed tab.

**Keeping it in the tab.** Three things the page asks of the app in answer
to input are the user's, not the extension's. Each is refused while that web
view is handling synthesized input (`AutomationInput.beginDispatch` …
`endDispatch`, from sending until the round trip returns).

- *First responder.* When the page focuses an element, WebKit asks the window
  to make the web view first responder. Measured: asynchronously, after the
  mouse event returns but before the round trip does. `BrowserWindow` refuses
  it, as it always does for a parked view. The page's element still gets
  focus and typing; `document.hasFocus()` stays false and `:focus` does not
  match, as on any page whose view is not first responder.
- *The context menu.* A synthesized right click opened WebKit's real menu.
  It is modal, appears over whatever the user is looking at even for a
  parked page, and holds the main thread until someone dismisses it. A
  test host sat in its tracking loop until killed. WebKit pops it up with a
  synthetic event of its own, so `willOpenMenu` cannot tell it apart. The
  UI-delegate SPI
  `_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:`
  answers nil, and WebKit shows nothing. The page still gets `contextmenu`.
  WebKit can ask after the page has answered the press, so a synthesized
  press is good for one withheld menu within 2 s, and a parked page never
  gets one. A tab no window has ever displayed has no UI delegate at all
  (only a displaying window wires one), so parking gives it
  `AutomationUIDelegate`, which implements only this SPI: its dialogs and
  everything else keep WebKit's no-delegate behaviour.
- *OS drags.* When a page drag begins (a draggable element, a link,
  selected text, an image), WebKit starts an AppKit drag with the mouse down
  that started it. The shipped WebKit uses the window's legacy
  `dragImage:at:offset:event:pasteboard:source:slideBack:`; newer ones use
  the view's `beginDraggingSession`. AppKit runs the drag with the real
  pointer. Measured: a test host sat in `NSCoreDragManager`'s drag loop
  waiting for a physical mouse-up, which would have dropped the drag
  wherever the user next released the button. `AutomationDragGuard`
  replaces both methods, on `BrowserWindow` and `BrowserWebView`, through the
  Objective-C runtime, because the session result is declared nonnull and
  the window method is deprecated. For a press that `sendMouse` sent,
  it makes no session and tells WebKit the drag ended with no drop, so the
  page gets `dragstart` then `dragend`. Selection, slider and canvas drags
  (plain mouse events) work. HTML drag and drop between elements does not.
  `Input.cancelDragging` succeeds, since there is never an OS drag to cancel.

- *Popup menus.* A synthesized click on a `<select>` opens WebKit's native
  popup, another modal menu, and WebKit has no delegate hook for it. A menu
  that begins tracking while synthesized input is being handled is closed
  from inside its own tracking loop by a zero-delay timer in the common modes.
  Cancelling it synchronously in `didBeginTracking` left the loop running. The
  main menu and menus answering the user's own press are left alone. The
  Claude extension sets a `<select>` from script rather than by clicking it.

Each refusal yields to the user. While AppKit is handling the user's own
mouse press in that window (`AutomationInput.userJustPressed`), the focus or
menu WebKit asks for is theirs. That also covers a synthesized right press
the page answered with `preventDefault`, which leaves its mark unconsumed.

A key down the page declines is handed back through `NSApp.sendEvent` and
dropped by `AutomationInput`'s monitor (TASK-132.3), so a declined Cmd+W
closes nothing.

# The indicator

A driven tab shows a small indicator in its sidebar row (tooltip
`Controlled by “<name>”`) and, while a window displays it, a capsule over the
top centre of the pane with the extension's name and Stop
(`AutomationIndicator.swift`, `BrowserWindowController+AutomationBanner.swift`).
Stop is `TabAutomationStop`: each owner reason registers what Stop does.
Things learnt building it:

- The capsule is a frame-laid subview of the tab's `WebViewContainerView`, so
  it moves with the pane, works in splits, and hides with a parked
  container; it never changes the web view's frame, so the page an extension
  drives does not resize when the user looks at it. It must be exempted from
  the container's corner clipping (`applyContentClipping`), and conform to
  `WindowDragPassThrough` to be clickable under the 38 pt drag strip.
- `fittingSize` of a view built on `GlassContainerView` came out about 49 pt
  wide (the label at zero width): size it from the parts' intrinsic sizes.
- A click posted with `NSApp.postEvent` reaches an `NSButton` in a window that
  is not key, in an app that is not active.
- A presented Peek hosts the bare web view, not its container: no capsule.

# Not like Chrome

- Tab targets only: no background pages, workers or `{extensionId}`, no child
  sessions (`sessionId`), no `Target.*`.
- Only the methods each domain file emulates; everything else is "wasn't
  found" (including `Emulation.setFocusEmulationEnabled`, which the Claude
  extension tolerates: it mutes and redraws the tab the same either way).
  A page the extension drives does not have focus (`document.hasFocus()`
  false), because its view is never made first responder for it.
- Input: no native context menu for a synthesized right click, and a
  `<select>`'s popup closes at once; no HTML drag
  and drop (a drag ends at once, with no drop); `char` is text input with no
  key events; `commands` other than the menu key equivalents are left to the
  text system's bindings; `undo` / `redo` only on a parked page; no touch,
  gesture or IME composition methods (`Input.dispatchTouchEvent`,
  `imeSetComposition`).
- `captureBeyondViewport` is not emulated: a clip past the viewport shows
  nothing there.
- The user's indicator is Detour's own (a sidebar row indicator and a
  capsule over the page with Stop), per tab rather than Chrome's
  browser-wide infobar.

# Tests

`ExtensionDebuggerTests` (worker and page): the gate both ways and a Settings
denial ending an attachment, attach / getTargets / detach including by
`targetId` with no `onDetach`, refusals in Chrome's words (unknown tab,
version, `extensionId`, double attach by the same and another extension,
`detour://`, another extension's page, its own page allowed), profile
isolation, unknown-method and not-attached errors in promise and callback
form, `target_closed` on close in both contexts, `canceled_by_user` on Stop,
release on unload, detach on navigation to an internal page, and screenshots
of the selected and a parked tab (size, pixels, clip with scale, JPEG
quality). `ExtensionDebuggerUnitTests`: versions, the URL rules, error texts,
screenshot parameters and geometry, encoding, reply-once, in-flight failure on
end, one debugger per tab, and event routing. `ExtensionPolyfillTests` pins
the namespace and the call shapes against a fake bridge.

`ExtensionDebuggerInputTests` (worker and page, parked and displayed tabs):
- a trusted click on the element at the point, also zoomed and scrolled;
- double and triple click, right click with no menu, a `<select>` popup
  closed, middle click, a drag
  that selects text, a draggable element's drag refused as an OS drag, and
  the wheel;
- typed keys with key, code and modifiers: arrows, Backspace, Cmd+A with its
  command (and not when the page cancels it), Ctrl+A, Enter submitting a
  form, Tab moving focus;
- `insertText` into an input, a textarea and contenteditable;
- the user typing in the selected tab while the extension types in a parked
  one;
- nothing reaching a field of the window's own: no first responder change,
  declined keys including Cmd+W dropped, no menu;
- parameter errors in Chrome's words, in both forms.

`ExtensionDebuggerInputUnitTests`: parameter parsing (including integers out of range, which would trap) and the event mapping.

The guards cover every window a driven tab can be shown in (`BrowserWindow`,
`QuickDetourWindow`) and every tab web view (the drag-session guard is on
`WKWebView`, since an extension's own page tab is a plain one).

Per mouse event there are two round trips (the viewport, then the
acknowledgement). Caching the viewport per session would halve that; not done.

[^task]: TASK-132.13 in Backlog.
[^task-input]: TASK-132.14 in Backlog; the measurements come from a temporary spike test on a parked and a displayed tab, 2026-11-07.
[^chromium]: chrome/browser/extensions/api/debugger/debugger_api.cc, read 2026-11-07.
