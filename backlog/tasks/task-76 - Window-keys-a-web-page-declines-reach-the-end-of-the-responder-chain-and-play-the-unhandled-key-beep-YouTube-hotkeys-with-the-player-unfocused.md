---
id: TASK-76
title: >-
  Window: keys a web page declines reach the end of the responder chain and play
  the 'unhandled key' beep (YouTube hotkeys with the player unfocused)
status: To Do
assignee: []
created_date: '2026-09-14 07:03'
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
- [ ] #1 On youtube.com with the player unfocused, arrow keys and < > produce no system beep in Detour (manual check in the signed build); the keys still work when the player is focused
- [ ] #2 A key that no web content handles (e.g. a letter on a page with no focused field) produces no beep, matching Safari
- [ ] #3 Esc still closes the peek overlay and keys pressed with a native view focused (sidebar) keep their previous behaviour
- [ ] #4 A unit test covers that a keyDown re-dispatched from a web view first responder stops at the window controller without falling through to NSResponder
<!-- AC:END -->
