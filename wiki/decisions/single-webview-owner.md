---
type: Decision
title: Single web view owner
description: When two windows show the same tab, one window hosts the live web view and the others show a snapshot, with hosting following window focus.
tags: [decision, architecture, webkit, multi-window]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T02:06:32Z }
sources:
  - id: ownership-doc
    resource: ../../docs/webview-ownership.md
    title: docs/webview-ownership.md
  - id: architecture-doc
    resource: ../../docs/architecture.md
    title: docs/architecture.md
  - id: window-controller
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift
  - id: browser-tab
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift
  - id: task-104
    resource: backlog:TASK-104
    title: GPU process IOSurface leak and the show budget
---

# Context

Two facts collide.

- Spaces and tabs are global objects in
  [TabStore](../architecture/tabstore.md), and each window chooses its own
  active space. Nothing stops two windows from showing the same space and
  selecting the same tab.
- A tab is one `BrowserTab` with one `WKWebView`, and a view has one
  superview. The same web view cannot be drawn in two windows.

`docs/webview-ownership.md` states the problem in those terms: non-owning
windows "need an alternative", and calls the resulting rule the most
critical architectural invariant in the app.

# Decision

One window at a time hosts a tab's web view. Any other window showing that
tab displays an `NSImageView` with a snapshot of it. Hosting moves to a
window when that window becomes key.

The mechanics are on
[web view ownership](../architecture/webview-ownership.md).

# Alternatives rejected

The design note records the choice of snapshots but does not list
alternatives it weighed. Two are implied by the context; neither is
documented as having been considered:

- **A second web view per window for the same tab.** A tab would then have
  two independent page states (scroll, form input, media, script state),
  which is no longer one tab.
- **Forbidding two windows on the same tab or space.** This would trade the
  invariant for a restriction on the "spaces are global, the active space is
  per window" model.

# Consequences

Seen in the code today.

**Ownership is derived, not stored.** `ownsWebView` asks whether the tab's
container is a descendant of this window's content area. A stored flag could
disagree with the view hierarchy; a derived one cannot.

**Every page action must first make sure the window hosts the view.**
Navigate, reload, back, forward and palette loads call
`ensureOwnsWebView()`.

**A non-key window shows a still image, dimmed to 50%.** It does not update.
Video in the tab keeps playing in the owning window only.

**"Has a superview" became a signal.** Other code reads a parented container
as "this tab is on screen somewhere": the sleep policy will not sleep such a
tab. Code that removes content has to leave containers unparented.

**Focus changes move views.** Each real transfer is a hidden-to-visible
transition for the page, which strands IOSurfaces in WebKit's GPU process
(TASK-104). Claims that find the container already in the window return
early and are not counted, because `windowDidBecomeKey` fires for popovers
closing and app switches too.

**The container, not the web view, is what moves.** WebKit docks the Web
Inspector as a sibling of the web view; wrapping both in `webViewContainer`
lets the inspector follow the tab between windows. For the same reason the
container is laid out with frames rather than Auto Layout.

**Delegates have to be handed around.** The hosting window is the web view's
navigation and UI delegate. A tab no window has claimed is its own
navigation delegate, and a closing window hands its web views back, or
background loads would run with no delegate at all. See
[BrowserTab](../architecture/browser-tab.md).

**Splits move as a unit.** Claiming either pane of a split takes both, and
windows match ownership notifications on group membership.

The Claude extension work needs unselected tabs to stay renderable while an
extension drives them (TASK-132.3), which touches this rule. That work is not
on `main` and is described only on
[Claude extension epic](../extensions/claude-extension-epic.md).

# Related

- [Web view ownership](../architecture/webview-ownership.md) — how it works.
- [BrowserWindowController](../architecture/browser-window-controller.md) — `selectTab` and the claim path.
- [Split tabs hosting](../tabs/split-tabs-hosting.md) — two panes in one host.
- [GPU IOSurface limit](../platform/gpu-iosurface-limit.md) — the cost of each show.
