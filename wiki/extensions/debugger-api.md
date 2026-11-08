---
type: Feature
title: Debugger API
description: chrome.debugger over an emulated subset of the Chrome DevTools Protocol — attachments and Chrome's rules for them, how an attachment ends, tab ids kept natively, the shared parked event channel, Page.captureScreenshot geometry, synthesized input and what keeps it in the tab, Runtime.evaluate under CSP with V8-shaped results, JavaScript dialogs and the frame model, console and network events from per-session page instrumentation, the user's Stop, and what differs from Chrome.
tags: [extensions, debugger, cdp, polyfill, events, claude-extension, csp, dialogs, input, console, network]
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
  - id: runtime
    resource: ../../Detour/Extensions/Runtime/ExtensionDebugger+Runtime.swift
    title: ExtensionDebugger+Runtime.swift and ExtensionDebuggerReplSource.swift (Runtime.evaluate)
  - id: dialogs
    resource: ../../Detour/Extensions/Runtime/ExtensionDebugger+Dialogs.swift
    title: ExtensionDebugger+Dialogs.swift and ExtensionDebugger+Frames.swift
  - id: v8
    resource: https://github.com/v8/v8/tree/main/src/inspector
    title: V8 inspector (value-mirror.cc, v8-runtime-agent-impl.cc, injected-script.cc)
  - id: pagehandler
    resource: https://github.com/chromium/chromium/blob/main/content/browser/devtools/protocol/page_handler.cc
    title: Chromium, page_handler.cc and components/javascript_dialogs/tab_modal_dialog_manager.cc
  - id: webkit
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Cocoa/UIDelegate.mm
    title: WebKit, UIDelegate.mm and FrameLoader::shouldClose
  - id: task15
    resource: backlog:TASK-132.15
    title: "Extensions: chrome.debugger Runtime.evaluate and JavaScript dialog handling"
  - id: instrumentation
    resource: ../../Detour/Extensions/Runtime/ExtensionDebuggerInstrumentationSource.swift
    title: ExtensionDebuggerInstrumentationSource.swift (the page and isolated scripts)
  - id: network
    resource: ../../Detour/Extensions/Runtime/ExtensionDebugger+Network.swift
    title: ExtensionDebugger+Network.swift
  - id: events-tests
    resource: ../../DetourTests/ExtensionDebuggerEventsTests.swift
    title: ExtensionDebuggerEventsTests.swift
  - id: task16
    resource: backlog:TASK-132.16
    title: "Extensions: chrome.debugger console and network events (Runtime.consoleAPICalled, Network.*)"
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

# Runtime.evaluate

What the Claude extension sends, from its bundle: `{expression, returnByValue: true, awaitPromise: true, replMode, timeout}`.
Its first try is `{code\n}` in REPL mode. It retries as `(async()=>{\ncode\n})()` outside REPL mode only when the answer is a
SyntaxError with a `scriptId`, no `stackTrace`, and a description matching `/Illegal return statement/`. Its tool tells the
model that top-level `await` works and that the last expression's value comes back.[^task15]

**What WebKit allows, measured** (a standalone WKWebView spike, page served with `Content-Security-Policy: script-src 'self'`):

| Path | Under that CSP | Page globals | Completion value | `await` |
|---|---|---|---|---|
| `eval` / `new Function` in the page world | refused (EvalError) | yes | yes | no |
| `evaluateJavaScript` of a raw script | runs | yes | by value only (a promise or node is "an unsupported type") | SyntaxError |
| `callAsyncJavaScript`, code as the body, page world | runs | yes | none (a function body; `return` is legal) | yes |
| `eval` / `new Function` in a named world | runs | no (DOM only) | yes | no |

So the code runs through `callAsyncJavaScript` in the page world as an async arrow function. Detour's `DetourDebugger`
world, where `eval` is never refused, does the checks that must not run the code:[^runtime]

1. **Syntax.** The code is compiled as a function body (`new Function`), then as a script (`eval('if (0) {…}')` inside
   a function, so `return` is illegal and `var`s stay local). In REPL mode the `await` words are blanked first: `await x`
   becomes `void  x`, at the same length. A failure is answered as V8 answers a compile error (no `stackTrace`, with a
   `scriptId`). The text is JSC's, except for "Illegal return statement" and V8's top-level-await message.
2. **The completion value.** `ExtensionDebuggerReplSource` tokenises the code: strings, templates with their holes,
   comments, and a regex told from division by the token before it. It then lists where the last statement of the list
   could start: the list's start, after a `;` or `}` of the list's own depth, or at a line break where ASI ends a
   statement (the next token cannot continue, the previous one does not ask for more). A final block is looked into
   recursively, which is the Claude extension's wrapper. Each rewrite `…; $c = (expr\n)` is compiled in Detour's world,
   latest start first, and the first that compiles is used; a start in the middle of a statement does not compile. If
   none compiles, the code runs unchanged, with an undefined value.
3. **The page** awaits the arrow and unboxes the value: it is returned in an array, so a promise is not adopted. In REPL
   mode the value is returned as it is, because V8 awaits only the REPL script's own promise
   (`ProtocolPromiseHandler::thenCallback` reads `.repl_result` and wraps it). Otherwise `awaitPromise` awaits it, with
   `Promise.resolve` semantics. The page then describes the value.

**Rejected alternatives:**
- `eval` in the page world when the CSP allows it: two behaviours depending on the site, and still no top-level await.
- `evaluateJavaScript`: by value only, no await.
- The named world alone: page globals are invisible.
- Vendoring a real parser (acorn): third-party code in the app. That is the user's decision, so it was left out for
  now. `ExtensionDebuggerEvaluation.prepare` is the one boundary such a parser would replace.
- Full spec completion rules (if/loop/try reset to undefined): not needed for what the extension sends.

**RemoteObject, as V8 builds it**[^v8]:
- With `returnByValue` (JSON mode), objects get `{type: "object", value}` with no subtype, className or description. A DOM
  node is `{}`, and so is a function's value. `toProtocolValue` keeps own enumerable properties and drops `undefined`
  ones; a non-finite number inside becomes null; depth is capped at 1000 ("Object reference chain is too long"). A symbol,
  or a bigint inside an object, is "Object couldn't be returned by value". These failures fail the command (-32000), as in
  Chrome.
- Top-level numbers carry a `description`. NaN, ±Infinity and -0 are `unserializableValue`. A bigint is
  `unserializableValue` "10n". null is `{type: "object", subtype: "null", value: null}`. undefined is `{type: "undefined"}`.
- Without `returnByValue`: type, subtype (array, node, regexp, date, map, set, weakmap, weakset, promise, typedarray,
  arraybuffer, dataview, generator, error), className, and description ("Array(3)", "div#id.a.b", "Map(1)", the function's
  source). There is no `objectId` (no remote object handles).
- An exception is wrapped as V8's `addExceptionToDetails` does: an Error is `{type, subtype: "error", className,
  description: "Name: message\n    at …"}`; anything else is described. `exceptionDetails` has `exceptionId`,
  `text: "Uncaught"`, line and column mapped back through the rewrite to the evaluated code, `scriptId`, `stackTrace`
  (page frames parsed from JSC's `name@url:line:col`, plus the evaluated code's frame), and `url` when a page script threw.
- `timeout`: V8 only times the synchronous part and answers `{"code":-32000,"message":"Execution was terminated"}`. Detour
  gives the same answer when the timeout passes, awaiting included, so a never-settling promise ends. WebKit cannot stop a
  running script: after the answer, a synchronous loop keeps the page's process busy.
- Errors outside the code: no web view gives "Cannot find default execution context"; a failed `callAsyncJavaScript`
  (navigated or closed) gives "Inspected target navigated or closed", which the Claude extension recognises.

**Not like Chrome**:
- Each evaluation is its own function. `let`/`const` never clash with an earlier evaluation (AC #4), but never persist
  either. Top-level `var` and function declarations are not globals.
- `eval` inside the code is still subject to the page's CSP. Chrome lifts the CSP for the evaluation
  (`allowUnsafeEvalBlockedByCSP`).
- The value is lost when the last statement is an if/loop/switch/try/label, or when a declaration follows the last
  expression.
- The description code uses the page world's own `Object` / `Promise`, so a hostile page can confuse it.

# Dialogs

From Chromium[^pagehandler]:
- With Page enabled, a dialog raises `Page.javascriptDialogOpening` and waits for `Page.handleJavaScriptDialog`. With
  nothing showing, that command fails -32602 "No dialog is showing".
- `Page.disable`, or the session going away with no browser dialog manager to leave the dialog to, runs the callback with
  `(false, "")` and reports nothing.
- A navigation cancels the dialog (`kTabNavigated`) and reports `javascriptDialogClosed`.
  The release happens when the load is issued (`BrowserTab.issue`, `goBack`, `goForward`), not at commit: a process held by a dialog reads no load, so a same-process navigation would never commit. Commit and a web process crash are backstops. A swipe gesture's history navigation is not hooked.
- `Page.getFrameTree` answers while a dialog is pending, from per-document facts kept by loader id, because page script cannot run under a dialog.
- Detour shows no browser dialog for such a tab, because its sheet is window-modal and would cover whatever tab the user
  is on. So it says `hasBrowserHandler: false` and always takes the no-manager branch.
- A prompt answered with accept and no `promptText` returns "" (Chromium's `prompt_override`).

The hook is one call at the top of each `alert` / `confirm` / `prompt` delegate method (`BrowserWindowController`,
`QuickDetourWindowController`, `ExtensionDebuggerDialogs.intercept`). It decides by the pure
`decision(pageEnabled:displayed:)`:
- Page enabled: the dialog is reported.
- Page not enabled and a window displays the tab: Detour's sheet, as before.
- Page not enabled and the tab is parked: answered at once, as Chromium answers a background tab's dialog
  (tab_modal_dialog_manager.cc: an alert is acknowledged, a confirm or prompt is suppressed). No sheet lands over the
  user's tab.

A tab is unaffected when no debugger holds it.

**A tab no window ever wired has no UI delegate.** Windows set `uiDelegate` only when they claim a web view, and WebKit
answers a delegate-less page's dialogs itself (`UIDelegate::UIClient::runJavaScriptAlert` and friends call the completion
at once). `parkForAutomation` therefore gives such a web view `AutomationUIDelegate`, which hands its dialogs to
`intercept` and otherwise gives WebKit's no-delegate answer, so nothing changes for a tab nobody drives. A window that
displays the tab replaces it (`wireOwnedWebView`). The completion handler is held until it is answered and is always
called once; WebKit raises if it is released uncalled.

**beforeunload is left out.** WebKit tells the web process whether the delegate responds to
`_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:`, and `FrameLoader::shouldClose`
returns early without dispatching `beforeunload` at all when it does not.[^webkit] The window is every tab's delegate,
so implementing the SPI there would make every tab start running its beforeunload handlers: a change for unattached tabs,
which the task ruled out. Pages navigate away as they do today. The Claude extension's beforeunload waiters are also
released by `frameNavigated`.

# Frames

Only a tab's main frame is modelled (`ExtensionDebugger+Frames.swift`).[^dialogs]
- The frame `id` is the tab's UUID as 32 hex digits, stable for the tab.
- `loaderId` is new at every main-frame commit. `BrowserTab.didCommitNavigation()` calls
  `ExtensionDebuggerFrames.tabDidCommit`, which costs a map lookup for a tab no debugger has seen.
- `Page.frameNavigated {frame, type: "Navigation"}` is sent once per commit while Page is enabled.
- WebKit commits nothing for a same-document navigation, so none is reported (no `navigatedWithinDocument`).
- `Page.getFrameTree` answers the main frame without children. The Claude extension compares its `loaderId` before and
  after a screenshot.
- `mimeType`, `isSecureContext` and `crossOriginIsolated` are read in Detour's world.
- `domainAndRegistry` is the last two host labels, because Detour has no public suffix list.
- A dialog names the main frame's id even when a child frame opened it.

# Console and network events

WebKit tells the app about neither console messages nor requests. An attached
tab is therefore instrumented for the length of the session, and no other tab
is.[^task16] Two document-start scripts, main frame only, are added to the tab's own
user content controller. Both also run in the document already there:

- **Page world** (`pageSource`): wraps the console methods, `fetch`, and
  `XMLHttpRequest.prototype.open` / `setRequestHeader` / `send`. It listens
  (capture, on `window`) for `error` and `unhandledrejection` /
  `rejectionhandled`. Arguments are described in the page with the same
  V8-shaped describer `Runtime.evaluate` uses (`describerSource`, shared since
  this task), captured at document start.
- **`DetourDebugger` world** (`isolatedSource`):
  - It hears the page half through a DOM `CustomEvent` with a string `detail`,
    named by the session's random token. A string crosses worlds, and the page
    cannot listen for a name it cannot guess.
  - It keeps the document's last 1,000 console reports, reads resource timing
    and element `error` events, and batches per microtask.
  - It posts to `detourDebuggerEvents`, a handler registered in that world only.
  - At start it says hello. Native answers with which of Runtime and Network
    are on, and says so again on every enable or disable.

On detach both scripts are removed: `_removeUserScript:` (SPI, checked with
`responds(to:)`), or else everything is removed and the rest put back. The
current document's halves also stop: the page half puts each original back,
unless the page has since replaced it. A tab showing an extension's own page
shares the extension's controller with its other pages, so it is not
instrumented. `Space.isTabUserContentController` tells which controllers were
made for one tab.

## Measured in WebKit (2026-11-07, a standalone WKWebView spike)

- A `Proxy` around a native function prints as `function ProxyObject() {
  [native code] }`, so proxies would give the wrappers away. Instead the
  wrappers are methods named as the originals, with the originals' `name` and
  `length`. A replaced `Function.prototype.toString`, itself disguised, prints
  the original for each.
- `new Error().stack` inside a wrapper gives `log@user-script:1:2:51`, then the
  caller (`global code@http://…/:1:51`). User-script frames are named
  `user-script:N`. Mind the colon: a `url:line:column` split reads the URL as
  `user-script:1`. These frames are dropped from the call frames, as are native
  ones.
- `PerformanceResourceTiming` and `PerformanceNavigationTiming` have no
  `responseStatus`. A subresource seen only through timing therefore has no
  status, and the document's status comes from the navigation response.
- A load that got no response (an unreachable host) makes no timing entry,
  only the element's `error` event. A 404 image makes both.
- An error thrown by a user script reaches `error` listeners as "Script error."
  with no error object, like a cross-origin script's.
- The isolated world sees the page's resource timing (`getEntriesByType`, a
  `PerformanceObserver`), since the timeline belongs to the document.

## Decisions

- **Instrument on attach, not on enable.** V8 keeps console messages whether
  or not anyone listens, and replays them on `Runtime.enable`. The Claude
  extension enables Runtime only when asked for console messages, so messages
  from before that call would otherwise be lost. Network is not replayed
  (Chrome does not):
  - reports wait in the document until it knows the state, then flow only
    while Network is on;
  - resource timing entries from before the enable are skipped;
  - a response whose request was never reported is dropped natively.
- **`fetch` returns a derived promise**, settled with the original's value or
  error. Attaching a rejection handler to the original instead would mark it
  handled, and the page would lose `unhandledrejection` for a failed request
  nobody awaited. The cost is settling one microtask later.
- **The document's request is native**, from three navigation callbacks:
  - `didStartProvisionalNavigation`: `requestWillBeSent`, with the method and
    headers the last policy request had for that URL.
  - The main-frame navigation response: `responseReceived` with the HTTP
    status. The three navigation delegates call
    `BrowserTab.didReceiveMainFrameResponse`.
  - `didFailProvisionalNavigation`: `loadingFailed`, with a `net::` text from
    the NSError.

  Its request id is the loader id, as in Chrome:
  `ExtensionDebuggerFrames.startProvisionalLoad` hands the commit the id the
  request already used.
- **A token per session.** A document kept in the back/forward cache from an
  earlier session posts with an old token and is ignored. On `pageshow` with
  `persisted` the isolated half says hello again: with the handler gone (no
  session) it takes its halves out; native answers a hello with an unknown
  token, from a web view a later session instruments, by stopping those halves
  and running the current session's; the same session's hello gets the
  current state, which may have changed while the document was cached.
- **A new web view is instrumented again.** A forced sleep keeps the
  attachment and wakes the tab with a new web view and controller;
  `BrowserTab.webView`'s `didSet` calls
  `ExtensionDebuggerInstrumentation.tabWebViewDidChange`.
- **The document request lives from its provisional start to its commit or
  failure**, not to its response: a response that becomes a download fails
  the provisional load (WebKit error 102), reported as `net::ERR_ABORTED`. Its
  `loadingFinished` comes from the isolated half at `DOMContentLoaded`, when
  the parser has the whole body.
- Rejected:
  - WebKit's Web Inspector protocol is close to CDP and has `Console` and
    `Network` domains, but there is no in-process client API the app can use.
  - A `WKURLSchemeHandler` sees only its own scheme.
  - A content rule list reports nothing back.

`docs/extensions.md` ("Console and network events") lists what is and is not
reported, field by field.

What the Claude extension reads:
- `consoleAPICalled`: `type`, each arg's `value` or `description`,
  `timestamp`, and the first call frame's place.
- `exceptionThrown`: `exceptionDetails` (`exception.description`, `text`,
  `url`, line, column, frames).
- `requestWillBeSent`: `requestId`, `request.url`, `request.method` and
  `documentURL`.
- `responseReceived`: `response.status`. A failed request it marks 503.

It keys each tab's lists by a host: the first frame's URL for console
messages, `documentURL` for requests. It empties a list when that host
changes.

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
- Runtime, dialogs and frames: their own lists above. Console and network:
  `docs/extensions.md` lists what is reported. In short: the main frame only,
  no subresource status, no bodies, no redirects, and no messages from before
  the attach.
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

TASK-132.15: `ExtensionDebuggerRuntimeTests` runs evaluations in a bare web view:
- WebKit's own `evaluateJavaScript` completion values as the oracle, plain and block-wrapped;
- REPL vs awaitPromise;
- V8's by-value and described shapes;
- thrown, rejected, compile-time and run-time SyntaxErrors;
- the extension's two-step retry, timeout, let/const;
- a CSP page that refuses eval.

`ExtensionDebuggerRuntimeExtensionTests` covers the same through the API from the worker and a page, plus:
- dialogs answered by the extension, with no sheet;
- Detour's sheet for unattached and displayed tabs, and an immediate answer for a parked tab without Page;
- release on detach and on close;
- frameNavigated once per navigation, with the loader id changing.

`ExtensionDebuggerRuntimeUnitTests` covers the tokeniser, the rewrite candidates, the position mapping, the messages and
the frame fields.

TASK-132.16: `ExtensionDebuggerEventsTests` (worker and page) covers:
- console methods with V8's types and argument shapes;
- an uncaught error and an unhandled rejection from the page's own script, with V8's stack text and frames;
- wrappers printing as native code;
- messages from a page's first script replayed on `Runtime.enable` after a navigation;
- nothing while disabled or after detach, and the originals back;
- fetch and XHR, including methods, bodies, headers, 200/404 statuses, failures, and an unhandled failed fetch still
  reaching the page;
- the document's request under its loader id, with its status (200, 404);
- images from resource timing, and an unreachable one failing;
- another tab of the space left untouched.

`ExtensionDebuggerEventsUnitTests` covers:
- `Network.enable`'s parameters;
- `net::` texts and resource types;
- the event shapes and the script templates;
- a second run in one document, and taking the wrappers out.

[^task]: TASK-132.13 in Backlog.
[^task-input]: TASK-132.14 in Backlog; the measurements come from a temporary spike test on a parked and a displayed tab, 2026-11-07.
[^task15]: TASK-132.15 in Backlog; the Claude extension 1.0.105 bundle (`mcpPermissions` chunk), read 2026-11-07.
[^runtime]: ExtensionDebugger+Runtime.swift, ExtensionDebuggerReplSource.swift.
[^dialogs]: ExtensionDebugger+Dialogs.swift, ExtensionDebugger+Frames.swift.
[^v8]: v8/src/inspector value-mirror.cc, injected-script.cc, v8-runtime-agent-impl.cc, read 2026-11-07.
[^pagehandler]: chromium content/browser/devtools/protocol/page_handler.cc and components/javascript_dialogs/tab_modal_dialog_manager.cc, read 2026-11-07.
[^webkit]: WebKit Source/WebKit/UIProcess/Cocoa/UIDelegate.mm, WebPageProxy.cpp, Source/WebCore/loader/FrameLoader.cpp, read 2026-11-07.
[^chromium]: chrome/browser/extensions/api/debugger/debugger_api.cc, read 2026-11-07.
[^task16]: TASK-132.16 in Backlog; ExtensionDebuggerInstrumentationSource.swift, ExtensionDebugger+Instrumentation.swift, ExtensionDebugger+Network.swift; the Claude extension 1.0.105 bundle's debugger event handler, read 2026-11-07.
