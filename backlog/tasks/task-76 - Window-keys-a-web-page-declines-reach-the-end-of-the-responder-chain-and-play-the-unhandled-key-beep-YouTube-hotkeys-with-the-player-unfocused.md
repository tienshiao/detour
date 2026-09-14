---
id: TASK-76
title: >-
  Window: keys a web page declines reach the end of the responder chain and play
  the 'unhandled key' beep (YouTube hotkeys with the player unfocused)
status: Done
assignee:
  - '@claude'
created_date: '2026-09-14 07:03'
updated_date: '2026-09-14 08:03'
labels:
  - window
  - bug
dependencies: []
priority: medium
ordinal: 76000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported 2026-09-14: on youtube.com, pressing the player hotkeys (arrow keys to seek, < and > to change speed) while the player is NOT focused plays macOS's 'unhandled key' sound (NSBeep); with the player focused the keys work silently. Safari does not beep. Mechanism: WKWebView sends every keyDown to the web process first; when the page does not handle it (YouTube's document-level handler ignores those keys without player focus, and left/right arrows cannot scroll a page with no horizontal overflow) WebKit re-dispatches the event up the responder chain (WebViewImpl::doneWithKeyEvent → _web_superKeyDown) — content container → NSWindow → BrowserWindowController. BrowserWindowController.keyDown (Detour/Browser/Window/BrowserWindowController.swift ~line 2222, the Esc-closes-peek override) ends in super.keyDown; NSWindowController is the last responder, so NSResponder.keyDown calls noResponderFor(keyDown:) which is NSBeep. Any unhandled key in web content therefore beeps: arrows at scroll limits, letters/punctuation with no focused editable, media hotkeys on sites that gate them on focus. Safari swallows keys its web content declined. Fix: in BrowserWindowController.keyDown, when the event was declined by web content — the window's firstResponder is a WKWebView (or a descendant of the content container / peek / split panes) — return without calling super, so the chain ends silently; keep the Esc-closes-peek branch and keep beeping (super) when the first responder is a native control such as the sidebar, so a genuinely unhandled key there still gives feedback. Check the same for cancelOperation/doCommandBySelector paths (a typed character declined by the page may arrive as insertText/doCommandBySelector rather than keyDown — verify with a breakpoint on NSBeep or the AppKit 'unhandled key' log). Test: a BrowserWindowController unit test that installs a BrowserWebView as first responder and sends a keyDown the web view re-dispatches (call the controller's keyDown directly with a synthetic NSEvent) asserting super is not reached — expose a small seam (e.g. an injectable beep/fallthrough hook) rather than trying to observe NSBeep.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 On youtube.com with the player unfocused, arrow keys and < > produce no system beep in Detour (manual check in the signed build); the keys still work when the player is focused
- [x] #2 A key that no web content handles (e.g. a letter on a page with no focused field) produces no beep, matching Safari
- [x] #3 Esc still closes the peek overlay and keys pressed with a native view focused (sidebar) keep their previous behaviour
- [x] #4 A unit test covers that a keyDown re-dispatched from a web view first responder stops at the window controller without falling through to NSResponder
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add a pure decision in BrowserWindowController (or a small free function in Window/): given the window's firstResponder, a key event is 'declined by web content' when the first responder is a WKWebView or a view inside one (split panes, peek web view); such events end at the controller silently instead of reaching NSResponder.keyDown (the NSBeep).
2. BrowserWindowController.keyDown: keep the Esc-closes-peek branch first; then if the event was declined by web content, return; otherwise super.keyDown as today.
3. Verify with the harness or a breakpoint that a declined typed character (e.g. '>' with no editable focused) also arrives as keyDown and not through a separate doCommandBySelector/insertText path that beeps; if it does, cover that path the same way.
4. Tests: unit-test the decision (web view first responder → swallow; NSTableView/sidebar first responder → fall through; nil → fall through) and, if a BrowserWindowController can be built in the test host as other suites do, a controller-level test with an injectable fall-through hook asserting super is not reached for a web-view-declined key and is reached for a native one.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented (b6ccb7d + review fixes): BrowserWindowController.keyDown returns after the Esc/peek branch when the window's first responder is a WKWebView or a view inside one (keyWasDeclinedByWebContent), so page-declined keys stop at the controller instead of NSResponder.keyDown → noResponderFor → NSBeep; native first responders still fall through. No second beep path: WebKit's editor-command re-dispatch is wrapped in WKResponderChainSink and noResponderFor beeps only for keyDown. Tests: UnhandledKeyFallthroughTests (4) incl. a real controller with a FallthroughProbe on nextResponder. Review found two related items left for separate tasks: the extension popover's WKWebView lives in a bare NSViewController inside an NSPopover whose window ends the chain, so keys its page declines still beep; and after Cmd+L → Return dismissing the command palette focus is not returned to the page (pre-existing).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Page-declined keys re-dispatched by WebKit reached the end of the responder chain and NSResponder.keyDown beeped. BrowserWindowController.keyDown now returns, after the Esc-closes-peek branch, when the window's first responder is a WKWebView or a view inside one; native first responders still fall through. Verified by the user on youtube.com in the signed build (no beep with the player unfocused) and by UnhandledKeyFallthroughTests (4), including a real controller observed through a probe on nextResponder. No second beep path exists (WebKit's editor-command re-dispatch is wrapped in WKResponderChainSink). Follow-ups: extension popups (TASK-77) and command-palette focus return (TASK-78).
<!-- SECTION:FINAL_SUMMARY:END -->
