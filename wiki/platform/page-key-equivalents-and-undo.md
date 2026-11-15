---
type: Platform Quirk
title: A page's key equivalents and its undo
description: How a WKWebView on macOS hands a Cmd key to the page first and gives the ones the page leaves back to AppKit (re-sent through NSApp.sendEvent, so the main menu gets them once; no Cocoa delegate callback), where WebKit keeps a page's edits for undo (the view's undoManager, by inheritance the window's) and when it drops them (the view changing windows, a tab switch) — read in WebKit's source and measured for TASK-345.
tags: [webkit, keyboard, undo, menus, responder-chain]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-15T21:00:00Z }
stale_after: 2027-06-01T00:00:00Z
sources:
  - id: task-345
    resource: backlog:TASK-345
    title: "Undo and redo: a page gets ⌘Z and ⇧⌘Z first, and Edit › Undo/Redo reach the page's own undo while editing"
  - id: task-333
    resource: backlog:TASK-333
    title: "Pages: Shift+Cmd+Z (Redo) in a page is never matched by BrowserWebView's interception"
  - id: webviewimpl
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/mac/WebViewImpl.mm
    title: WebViewImpl.mm (performKeyEquivalent, doneWithKeyEvent, keyDown, registerEditCommand)
  - id: page-proxy
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebPageProxy.cpp
    title: WebPageProxy.cpp (handleKeyboardEvent, keyEventHandlingCompleted)
  - id: page-client
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/mac/PageClientImplMac.mm
    title: PageClientImplMac.mm (canUndoRedo, executeUndoRedo)
  - id: webview
    resource: ../../Detour/Browser/Window/BrowserWebView.swift
    title: BrowserWebView.swift (its own undo manager)
  - id: window
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift (browserUndo:, undoTarget)
  - id: tests
    resource: ../../DetourTests/PageUndoRoutingTests.swift
    title: PageUndoRoutingTests.swift
  - id: harness
    resource: ../../docs/harness/task345
    title: TASK-345 runtime checks (drive.py, undo.html fixture)
  - id: feature
    resource: ../tabs/tab-lifecycle.md
    title: Tab lifecycle (Reopening and undo)
---

# A page's key equivalents

Read in WebKit's source on `main` (2026-11-15) and measured in Detour's Debug
build on macOS 26 with real key events (TASK-345):

1. AppKit offers a Cmd key to the key window's views (`performKeyEquivalent`)
   before the main menu. `WebViewImpl::performKeyEquivalent`, when the web
   view is the window's first responder, sends the key to the web process and
   returns YES at once: the page sees it before any menu. When the web view
   is not the first responder it hands the key straight on (NSView's
   `performKeyEquivalent`, so NO).
2. When the page is done, `WebPageProxy::keyEventHandlingCompleted` calls
   `doneWithKeyEvent(event, handled)`. Handled (the page called
   `preventDefault`) ends there. Not handled, WebKit sets
   `m_keyDownEventBeingResent` and re-sends the same event with
   `[NSApp sendEvent:]`. On that pass its `performKeyEquivalent` falls to
   NSView's at once, so the main menu gets the key; if no item takes it,
   `keyDown:` sees the resent event and passes it to NSResponder (a beep).
3. There is no Cocoa delegate callback for an unhandled key: the
   `didNotHandleKeyEvent` UI client hook is implemented only for the C API
   (`WKPageUIClient`), not by `UIDelegate.mm`. The re-send through
   `NSApp.sendEvent` is the hand-off.

So a menu item is what "the page did not handle it" reaches. A view subclass
that overrides `performKeyEquivalent` sees the key twice (before the page,
then on the re-send) and cannot tell the passes apart; acting there would act
before the page, or twice. TASK-345 removed `BrowserWebView`'s ⌘Z/⇧⌘Z
override for that reason: Edit > Undo and Redo now get the keys the page
leaves, once.

The re-send needs a key window for the menu's target: with the app in the
background (the automation endpoint's input), the key reaches the page but
Edit > Undo finds no target and nothing more happens. A page whose process is
gone swallows the key (read in the source, not measured: WebKit returns YES before it knows); that holds for
every menu shortcut, not only undo.

# A page's edits and undo

- `WebViewImpl::registerEditCommand` registers each edit with
  `[view undoManager]`, and `executeUndoRedo` (the page's
  `document.execCommand('undo')`) runs that manager.
- `WKWebView` does not override `undoManager`, so it is NSResponder's: the
  next responder's, up to the window's own (Detour's window controller is not
  asked: `NSWindow.undoManager` consults only its delegate's
  `windowWillReturnUndoManager:`). Measured before TASK-345: after
  `execCommand('insertText')` in a contenteditable the web view's
  `undoManager` was the window's (same object, `canUndo`, action "Typing"),
  and `TabStore.undoManager` had nothing. One stack for both panes of a split
  and the window's own text fields (the palette, rename fields): one page's
  undo, or its `execCommand('undo')`, could reach the other pane's edits or
  a field's.
- `BrowserWebView` now overrides `undoManager` with its own, so each page's
  edits stay with that page. WebKit registers into it
  (`PageUndoRoutingTests.testAPagesEditsLandOnItsOwnUndoManager`), and its
  action names give Edit > Undo's title ("Undo Typing").
- WebKit drops a page's edits whenever its view moves into or out of a
  window (`WebViewImpl::viewWillMoveToWindowImpl` and
  `PageClientImpl::viewWillMoveToAnotherWindow` call
  `clearAllEditCommands`), and on page close and web process exit. A tab
  switch removes the web view from the window, so after switching away and
  back the page has nothing to undo: measured, ⌘Z in the still-focused
  contenteditable reached the page and changed nothing, and Edit > Undo was
  "Undo", disabled (Detour's list untouched, as AC #2 of TASK-345 wants).
- Edit > Undo in Detour is `browserUndo:`, not AppKit's `undo:`. Its target
  is decided by `BrowserWindowController.undoTarget` (through
  `BrowserWebView.editingPage(in:)`, which Quick Detour windows use too, with
  no browser undo behind it): the focused page's own
  undo when the window's first responder is a `BrowserWebView` whose
  `isEditingWebContent` is set (the `editableFieldFocus` script message),
  else `TabStore.undoManager`; never the page while another window (Settings,
  an extension's popup) has the keys, since Edit > Undo then falls through to
  the main window. The first-responder check matters: a field keeps DOM
  focus when the keys move to the palette or the find bar, and no focusout
  says so.
- The flag comes from the `editableFieldFocus` script (every frame; a field
  in an open shadow root counts, followed down from its host):
  `focusin`/`focusout`; the top document's state when it loads, returns from
  the back/forward cache or gets window focus again (a tab shown again,
  whose messages went nowhere while no window hosted it); and, on ⌘Z / ⇧⌘Z
  itself (`key` "z" or `code` "KeyZ"), the state of the frame the key goes
  to, posted from a `keydown` listener capturing on `window`, ahead of the
  page's own document listeners. That message travels on the same
  connection as WebKit's "not handled" reply, ahead of it, so the menu reads
  where focus was when the key was pressed, whatever focusin/focusout missed
  (a focused element removed, focus moving between frames, a page that stops
  `focusout`). Measured: with a page that swallows every `focusout` at window
  capture, typing in its input, clicking out to the body and pressing ⌘Z
  reopened a tab and left the text, three times out of three; without the
  key's report the stale flag would have undone the typing. Detour no longer
  clears the flag when a window stops hosting the page. A page's own window
  capture listener that stops propagation would still hide the key's report
  (not measured). The message needs the window's `editableFieldFocus` handler
  on the page: an owned page gets it when the window hosts it, and a Peek's
  page when the window claims the Peek (before TASK-345 a Peek had none, so
  its fields never counted as editing).

# Measured (TASK-345)

Real ⌘Z and ⇧⌘Z (`CGEventPostToPid`, `docs/harness/task345/drive.py`) with Detour frontmost, a fixture page
with a `preventDefault` "canvas", an `<input>` and a contenteditable, closed
tabs on Detour's list: the canvas counted each key once and Detour's list was
untouched; with the body focused the page logged the key and exactly one
closed tab came back (⇧⌘Z re-closed exactly one); in the input and the
contenteditable ⌘Z / ⇧⌘Z and Edit > Undo / Redo undid and redid the typing,
titled "Undo Typing" / "Redo Typing", and with the page's stack empty ⌘Z
changed nothing (Detour's list kept its closes); with the palette or the find
bar focused (the page's input still focused in the DOM) ⌘Z reopened a tab and
left the page's text alone; with the focused `<input>` removed by the page,
⌘Z reached the page and then reopened exactly one tab. Clicking the sidebar's tab list does not take the
keys from the page (the list never takes focus, TASK-174), so ⌘Z then is the
page's. In a Quick Detour window (opened with Open Link in Quick Detour, its
input focused, typed into) ⌘Z reached the page and nothing else happened
before the follow-up (Edit > Undo answered only in browser windows); since
it, a Quick Detour and a quarantine window (opened by a Link Route from a
`target=_blank` link; a plain same-host click is not routed) run their
page's own undo the same way, titled "Undo Typing"/"Redo Typing", with the
browser's closed tabs left closed.

Two traps met on the way: posting keys while the person at the Mac had
another app in front left Detour inactive, and the re-sent key then did
nothing (check `app_active` after each key); and two tabs closed with the
endpoint's `run_menu_item` landed in one undo group (both came back with one
⌘Z), where two real ⌘W presses make two. Unrelated to undo: an input's
"xyz" once read "Xyz" after the palette took the keys (macOS's automatic
capitalization on focus loss, most likely; TASK-333 saw "ab" become "Ab"),
so the checks compare text without case.

From the source only, not measured: a page whose web process is gone
swallows the key; the docked Web Inspector (a plain `WKWebView`) leaves ⌘Z
to the browser's undo.
