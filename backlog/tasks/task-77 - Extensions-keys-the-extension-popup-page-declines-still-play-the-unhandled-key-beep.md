---
id: TASK-77
title: >-
  Extensions: keys the extension popup page declines still play the
  unhandled-key beep
status: To Do
assignee: []
created_date: '2026-09-14 08:03'
labels:
  - extensions
  - window
  - bug
dependencies: []
priority: medium
ordinal: 77000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Left over from TASK-76 (2026-09-14). TASK-76 silenced page-declined keys for browser windows by ending the responder chain in BrowserWindowController.keyDown. The extension popup (Detour/Extensions/UI/ExtensionPopoverController.swift, ~line 170) hosts its WKWebView in a bare NSViewController inside an NSPopover; the popover's window has no window controller, so a key the popup page does not handle bubbles webView → view controller → _NSPopoverWindow → nil nextResponder → NSResponder.noResponderFor(keyDown:) → NSBeep. (WebKit's own fullscreen window is not affected: WKFullScreenWindowController overrides noResponderFor.) Fix: end the chain for web-declined keys the same way — reuse BrowserWindowController.keyWasDeclinedByWebContent — at whatever responder actually terminates the popover's chain; the review noted that overriding noResponderFor on the view controller would NOT be reached because the popover window, not the view controller, ends the chain, so first confirm at runtime (breakpoint on NSBeep or the AppKit unhandled-key log) which object receives the fall-through, then override keyDown there (a small NSPopover/contentViewController subclass or the popover window's next responder). Keep Esc dismissing the popover and keep native fields inside the popup (search boxes) beeping when they decline a key.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Pressing a key the popup page does not handle (an arrow key or letter with no focused field in 1Password's popup) produces no beep in the signed build; Esc still closes the popup
- [ ] #2 A test builds the popover controller, makes its web view the first responder and sends a synthetic keyDown, asserting the fall-through to NSResponder is not reached (probe on the terminating responder), and that a native NSTextField first responder still falls through
<!-- AC:END -->
