---
type: Feature
title: "Automation endpoint: screenshots"
description: How the automation endpoint's screenshot tool draws a window, a sidebar or a page inside Detour (source app) or takes the window server's picture through ScreenCaptureKit (source screen), why in-app captures cannot draw glass materials, and the set_appearance and Debug-only set_debug_override tools used with it.
tags: [automation, mcp, capture, appkit]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:12Z }
sources:
  - id: capture
    resource: ../../Detour/Automation/AutomationCapture.swift
    title: AutomationCapture.swift and AutomationTools+Capture.swift (window, sidebar and page pictures, ScreenCaptureKit)
  - id: task-228-1
    resource: backlog:TASK-228.1
    title: "Automation: an MCP endpoint in Detour, first slice for testing"
  - id: tests
    resource: ../../DetourTests/AutomationCaptureTests.swift
    title: AutomationCaptureTests
---

The [automation endpoint](./automation-endpoint.md)'s `screenshot` returns
a PNG of a window's content (any kind, Settings on any endpoint), a browser
window's sidebar (`part`; another kind is `unsupported_window`) or a tab's
page (`context`), as image content and/or written to `save_to` (an existing
file only with `overwrite`), at `scale` 1 or 2, never above the
display's.[^capture]

# Two sources

| `source` | How | Grant | Limits |
|---|---|---|---|
| `app` (default) | Drawn inside Detour: the window's content through `cacheDisplay` plus the sidebar redrawn from its layer; a page from WebKit's snapshot | none; works with Detour in the background | no shadow and no glass (see Traps); a tab never shown has no picture (see [page tools](./automation-endpoint-page-tools.md#traps)) |
| `screen` | The window server's picture through ScreenCaptureKit (`SCContentFilter(desktopIndependentWindow:)`, shadow ignored) | Screen Recording, checked with `CGPreflightScreenCaptureAccess` and never prompted, else `permission_denied`; a test run launched from a terminal that has the grant inherits it | exact, also with Detour in the background |

Neither shows the [agent pointer](./automation-endpoint-agent-pointer.md),
which is a window of its own: while it is up, `source screen` takes the
window from its display with every other window excluded instead.

A tab shown once keeps its frame after the window moves on, and its
screenshot works with no window (checked in tests and at runtime).

# Appearance and Debug overrides

- `set_appearance`: light, dark, or following the system, for all of
  Detour (`NSApp.appearance`), until quit or the next call.
- `set_debug_override` (Debug builds only; absent from Release, checked on
  a Release build: its tool list and its binary's strings):
  `reduce_motion` (this process, via `MotionPreference`, which every Reduce
  Motion read goes through), `space_toss_hop` and `space_toss_gravity`
  (the data directory's defaults keys `SpaceCelebration` already read in
  Debug), `automation_indicator` and `agent_pointer` (test runs only; see
  [capture staging](./automation-endpoint-staging.md) and [the agent
  pointer](./automation-endpoint-agent-pointer.md)); `default`
  clears.[^task-228-1]

# Traps

- **In-app captures cannot draw window-server materials.** `cacheDisplay`
  draws the content view (web content included, even with Detour in the
  background) but leaves the sidebar blank, so the sidebar is drawn again
  from its layer. Neither path reproduces the sidebar's glass
  (`NSGlassEffectView` or `NSVisualEffectView`, composited by the window
  server with backdrop filters and blend modes): in dark mode the captured
  sidebar comes out light while the real one is dark (compared with
  `screencapture -l` of the same window), and glass panels drawn over the
  content (the command palette, find bar, toasts, hover cards) come out as
  blank boxes. Redrawing the views stacked above the sidebar from their
  layers was tried and made it worse: the palette's full-window view painted
  the whole sidebar white. Use `source: "screen"` for the exact
  picture.[^task-228-1]
- **A bitmap context is in pixels.** `NSGraphicsContext(bitmapImageRep:)`
  does not scale to the rep's `size`; drawing a 1x capture into a 2x rep
  without a CTM scale filled only its bottom-left quarter.

# Tests

`AutomationCaptureTests` (window, sidebar and page PNGs as image content and
on disk, scale 2, the page's own colours from WebKit's snapshot, light and
dark, the Debug overrides and that they exist only in Debug, and the
errors); see [the endpoint's tests](./automation-endpoint-tests.md).[^tests]

# Related

- [Automation endpoint (MCP)](./automation-endpoint.md): the hub.
- [Capture staging](./automation-endpoint-staging.md): website captures,
  which record the screen outside the app.
- [In-process UI automation](../playbooks/in-process-ui-automation.md):
  captures before the endpoint.

[^capture]: AutomationCapture.swift and AutomationTools+Capture.swift (window, sidebar and page pictures, ScreenCaptureKit)
[^task-228-1]: Automation: an MCP endpoint in Detour, first slice for testing
[^tests]: AutomationCaptureTests
