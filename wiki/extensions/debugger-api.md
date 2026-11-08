---
type: Feature
title: Debugger API
description: chrome.debugger over an emulated subset of the Chrome DevTools Protocol — attachments and Chrome's rules for them, how an attachment ends, tab ids kept natively, the shared parked event channel, Page.captureScreenshot geometry, the user's Stop, and what differs from Chrome.
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
  extension tolerates).
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

[^task]: TASK-132.13 in Backlog.
[^chromium]: chrome/browser/extensions/api/debugger/debugger_api.cc, read 2026-11-07.
