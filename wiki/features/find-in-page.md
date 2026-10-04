---
type: Feature
title: Find in page
description: "The Cmd+F find bar: a per-window FindBarView driving WKWebView.find on the selected tab, with a match counter computed separately in JavaScript."
tags: [find, webkit, keyboard, window]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:42:36Z }
sources:
  - id: find-bar
    resource: ../../Detour/Browser/Window/FindBarView.swift
    title: FindBarView.swift
  - id: window-controller
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift (Find Bar Actions, FindBarDelegate)
  - id: app-delegate
    resource: ../../Detour/App/AppDelegate.swift
    title: AppDelegate.swift (Edit menu)
---

# What it does

Edit > Find... (Cmd+F) shows a small glass bar at the top-left of the content
area with a text field, previous and next buttons, a result label ("3 of 12"
or "Not found") and a close button. Typing searches the page as you type; Find
Next (Cmd+G) and Find Previous (Cmd+Shift+G) step through matches and wrap
around. Escape or the close button dismisses the bar
and returns focus to the page.

# How it works

`FindBarView` is a dumb view: it reports text changes and button clicks to its
`FindBarDelegate` and displays whatever label it is told to. Each
`BrowserWindowController` owns **one** find bar, added to
`contentContainerView` and hidden until used. All the logic is in the window
controller:

| Action | Method | Behaviour |
|---|---|---|
| Cmd+F | `showFindBar(_:)` | fades the bar in (0.2 s) and focuses the field, selecting its text |
| typing, Return in the field | `findBar(_:searchFor:backwards:)` → `performFind` | searches forward |
| Find Next / Previous | `findNext(_:)` / `findPrevious(_:)` | shows the bar if hidden, then searches with the field's text |
| Escape, close button | `dismissFindBar(_:)` | clears the field and counters, makes the selected tab's web view first responder, fades out (0.15 s) |

`performFind(_:backwards:)` does two independent things:

1. **Highlighting and scrolling** come from WebKit:
   `webView.find(text, configuration:)` with `wraps = true` and the requested
   direction, on `selectedTab?.webView`.
2. **The count** comes from Detour. For a *new* query (`text != lastFindQuery`)
   `countMatches` evaluates a script that lowercases `document.body.innerText`
   and counts non-overlapping occurrences of the lowercased query. The index
   starts at 1 and is incremented or decremented, wrapping at the count, on
   each later find of the same query.

The close button's key equivalent is Escape, which is how Escape reaches the
bar while the field has focus. The bar's height is taken from a `ToastView`'s
fitting size so the two stay in step.

# Edge cases

These follow from reading the code; none has a test.

- **Counter and highlight can disagree.** WebKit's find and the `innerText`
  count are separate computations. The count ignores subframes and text that
  `innerText` omits, and its case folding is JavaScript's `toLowerCase`. When
  WebKit finds a match but the script counts zero, the label reads "Not
  found" while a match is highlighted.
- **State is per window, not per tab.** `lastFindQuery`, `findMatchCount` and
  `findMatchIndex` live on the window controller, and selecting another tab
  neither hides the bar nor resets them. Searching the same text on the new
  tab is treated as "not a new query", so the count from the previous tab is
  reused until the text changes.
- **The target is the selected tab's web view.** In a
  [split](../tabs/split-tabs-hosting.md) that is the focused pane. A presented
  [Peek](../tabs/peek.md) is not searched: both `performFind` and the focus
  restore in `dismissFindBar` use `selectedTab?.webView`, not the Peek's.
- **Dismissal resets only Detour's state.** `dismissFindBar` clears the field
  and the counters and does nothing to the selection WebKit's find left in the
  page.
- **A snapshot cannot be searched.** A window that shows a tab as a snapshot
  has no web view to call `find` on; see
  [web view ownership](../architecture/webview-ownership.md).
- The query is escaped for a single-quoted JavaScript string (backslash,
  quote, newline) before it is interpolated into the counting script.

# Related

- [BrowserWindowController](../architecture/browser-window-controller.md) - owner of the find bar and its state.
- [Keyboard focus](../sidebar/keyboard-focus.md) - first responder handling around overlays.
- [Command palette](./command-palette.md) - the other overlay in the content area, with a fuller focus-restore path.
- [App shell](../architecture/app-shell.md) - the Edit menu items and their key equivalents.
