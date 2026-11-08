---
id: TASK-132.14
title: >-
  Extensions: chrome.debugger input — Input.dispatchMouseEvent,
  dispatchKeyEvent, insertText
status: Done
assignee:
  - '@claude'
created_date: 2026-10-03 23:09
updated_date: '2026-11-08T04:44:00Z'
labels: []
dependencies:
  - TASK-132.13
parent_task_id: TASK-132
priority: high
ordinal: 146000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deliver CDP input to an attached tab as real (trusted) events by synthesising NSEvents for its web view. Mouse: type mousePressed / mouseReleased / mouseMoved / mouseWheel, x and y in CSS pixels of the viewport, button, buttons, clickCount, modifiers, deltaX, deltaY. Keys: type keyDown / rawKeyDown / keyUp / char with key, code, windowsVirtualKeyCode, text, modifiers, commands. insertText goes through the text input client. Must work on an unselected, automation-attached tab without moving the real pointer, the key window or first responder of the user's own tab.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A click at page coordinates fires pointer and mouse events with isTrusted true on the element at that point, at any page zoom and scroll offset
- [x] #2 Double and triple click, right click, drag (press, move, release) and wheel scrolling work
- [x] #3 Typed keys reach the focused element with correct key, code and modifiers, including Enter, Tab, arrows, Backspace and Cmd/Ctrl shortcuts such as select-all
- [x] #4 insertText inserts into inputs, textareas and contenteditable, including non-ASCII text
- [x] #5 Input to an unselected attached tab reaches it while the user keeps typing in the selected tab undisturbed
- [x] #6 Input never reaches Detour's own chrome (sidebar, palette) or another tab
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Spike (temporary test) on a parked and a displayed tab: ordering, focus, Cmd keys, Ctrl/arrows/Backspace, multi-clicks, wheel, middle button, zoom and scroll, insertText; read WebKit (WebViewImpl startDrag, WebContextMenuProxyMac) and Chromium input_handler.cc.
2. ExtensionDebugger+Input.swift: parse CDP params in Chrome's words; map to NSEvents (DOM code/windows VK to kVK, function-key characters, control characters, flagsChanged for modifier keys); CGEvent-made wheel and other-button events; CSS-to-view mapping shared with screenshots.
3. Per-session serial queue: one event at a time, answered after a script round trip behind it (WebKit queues input and sends the next only when the page acked the last).
4. Containment: AutomationInput.sendMouse + dispatch window; BrowserWindow refuses first responder to a web view while it handles synthesized input; context menu SPI returns no menu then; AutomationDragGuard refuses the OS drag session for a drag started by a synthesized press and tells WebKit it ended.
5. commands: only menu key-equivalent commands (selectAll/copy/cut/paste; undo/redo on parked pages) run, when the main frame's key down was not cancelled; the rest are the text system's bindings, which the key event already performs.
6. Tests (unit + integration, both transports, parked and displayed), API Explorer input controls, docs/wiki, /code-review, /verify.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Spike findings (2026-11-07):
- Back-to-back events plus one script round trip leave only the first handled: WebKit queues input until the page acks. So there is one event in flight per session, with a round trip after each.
- A click in a displayed page moves first responder asynchronously, before the round trip returns. BrowserWindow refuses it while the event is being handled.
- A synthesized right click opens WebKit's real modal menu, even for a parked page. It stuck a test host in the menu's tracking loop. WebKit pops it with its own synthetic event and can ask after the page answered. Fix: the getContextMenuFromProposedMenu SPI returns nil (parked always; displayed once per synthesized press within 2 s). A never-displayed parked tab has no uiDelegate at all; it gets AutomationUIDelegate, which implements only that SPI.
- The shipped WebKit starts drags with NSWindow dragImage:at:offset:event:pasteboard:source:slideBack:, not beginDraggingSession. A test host sat in NSCoreDragManager's loop waiting for a physical mouse-up. AutomationDragGuard refuses both APIs for a drag begun by a synthesized press and ends WebKit's drag (dragend).
- Cmd+A sent as a key down selects nothing on a parked page (WebKit calls it handled). A parked view's performKeyEquivalent returns false, because it is not first responder. So menu-equivalent commands are run explicitly, unless the main-frame key down was cancelled. Bindings-based commands (Backspace, arrows, Ctrl+A) already work from the key event.
- NSEvent's factory gives otherMouseDown button number 0. Other buttons and the wheel come from CGEvents, placed so their screen point equals the window point.

Review (/code-review --fix): 10 findings, 4 fixed by the reviewer. Out-of-range integers trapped; the window drag guard was missing on QuickDetourWindow; the session drag guard is now on WKWebView, so extension page tabs are covered; Quick Detour got the focus refusal and the menu SPI.
I fixed 4 more:
- a <select>'s modal popup (NSMenu didBeginTracking during dispatch is cancelled from inside the tracking loop);
- the user's own press is exempt from the focus and menu refusal (also covers a stale synthesized right press after a cancelled contextmenu);
- rawKeyDown Control+letter keeps its control character, so its binding runs;
- rawKeyDown Enter types no line break.
Left: two round trips per mouse event (viewport plus acknowledgement), noted in the wiki.
Also found: a never-displayed parked tab has no uiDelegate. It gets AutomationUIDelegate (context-menu SPI only); 132.15 was told, for dialogs.
Tests:
- ExtensionDebuggerInputTests 8/8 (worker and page, parked and displayed), ExtensionDebuggerInputUnitTests 16/16.
- Regression run, 649 tests, 0 failures, 1 skipped (the existing process-assertion probe): Quick Detour suites, CommandPaletteFocus, parking (both classes), indicator (3 classes), ExtensionDebugger, ExtensionDebuggerUnit, ExtensionPolyfill, WebKitDelegateReachability, SplitTab, ExtensionInterimNamespaces.
Runtime (/verify, isolated profile DetourVerify13214-1, API Explorer, harness docs/harness/task132.14-harness.patch):
- The worker drove parked Bravo (2 clicks, typed 'Typed by Claude ünï 🎉', double click selected 'gamma', a right click with contextmenu and no native menu, wheel 120) while 'hello from the user' was typed into Alpha with posted key events. Each field got exactly its own text; first responder stayed on Alpha's web view.
- With the command palette open, a page drove displayed Alpha (click, typed 'ext', Cmd+A selected it, right click): the palette's field editor kept first responder; refusedDrivenFR=1, suppressedMenus=2, no menu tracked.
- Captures: the window, and Bravo via CDP.
- Defaults keys and the data dir were deleted.
Not verified: a 2x display, the real Claude extension (TASK-132.20), HTML drag and drop (refused by design), IME composition. The full suite was not run.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Input.dispatchMouseEvent, Input.dispatchKeyEvent and Input.insertText (plus Input.cancelDragging) for chrome.debugger.
- Real NSEvents go straight to the attached tab's web view, parked or displayed, so the page gets trusted events. CSS viewport coordinates use the screenshot mapping, so they hold at any zoom.
- One event at a time per session, each answered once the page has handled it.
- Keys map from code / windowsVirtualKeyCode / key to Mac key codes with AppKit's function-key and control characters; modifier keys become flagsChanged. Middle, back and forward buttons and the wheel are CGEvent-made.
- What a synthesized event cannot take from the user (all yield to the user's own press): first responder, the native context menu (WebKit SPI, plus AutomationUIDelegate for never-displayed parked tabs), a <select>'s modal popup, and OS drag sessions (AutomationDragGuard on the legacy window drag the shipped WebKit uses and on beginDraggingSession).
- Of the Mac commands, only the menu key equivalents run, when the key down was not cancelled.
Tests: 8 integration, 16 unit; a 649-test regression run is green. The runtime check in the app passed.
Limits: no HTML drag and drop, no touch, gesture or IME, the driven page has no focus, undo and redo only on parked pages.
<!-- SECTION:FINAL_SUMMARY:END -->
