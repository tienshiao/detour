---
type: Overview
title: Claude extension epic
description: The in-flight epic to make Anthropic's Claude extension install, sign in and drive pages in Detour — what the extension needs, the sub-task map, and the decisions and measurements so far. None of this code is on main.
tags: [extensions, epic, side-panel, tab-groups, debugger, planning]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T18:50:00Z }
stale_after: 2026-11-03T00:00:00Z
sources:
  - id: task-132
    resource: backlog:TASK-132
    title: "Epic: support the Claude extension (side panel, tab groups, chrome.debugger)"
  - id: task-132-1
    resource: backlog:TASK-132.1
    title: "Spike: can WebKit's native sidePanel be used"
  - id: task-132-2
    resource: backlog:TASK-132.2
    title: Resolve a WebKit tabId to its BrowserTab in polyfill handlers
  - id: task-132-3
    resource: backlog:TASK-132.3
    title: Unselected tabs stay renderable and able to take synthesized input
  - id: task-132-4
    resource: backlog:TASK-132.4
    title: The extension installs and its worker start-up completes (declarativeNetRequest session header rule)
  - id: task-132-6
    resource: backlog:TASK-132.6
    title: externally_connectable pages get chrome.runtime
  - id: task-132-8
    resource: backlog:TASK-132.8
    title: Host an extension's per-tab side panel beside the tab's content
  - id: task-132-9
    resource: backlog:TASK-132.9
    title: runtime.getContexts and runtime.ContextType
  - id: task-132-10
    resource: backlog:TASK-132.10
    title: Tab group model in TabStore
  - id: task-132-12
    resource: backlog:TASK-132.12
    title: tabs.group, tabs.ungroup, chrome.tabGroups and groupId on tabs
  - id: task-132-13
    resource: backlog:TASK-132.13
    title: chrome.debugger plumbing and Page.captureScreenshot
  - id: task-132-16
    resource: backlog:TASK-132.16
    title: chrome.debugger console and network events
  - id: task-132-20
    resource: backlog:TASK-132.20
    title: End-to-end check of the Claude extension in a signed build
  - id: task-132-21
    resource: backlog:TASK-132.21
    title: A window with nothing selected reports no tabs to extensions
  - id: task-132-22
    resource: backlog:TASK-132.22
    title: Tell WebKit when a browser window opens or closes
  - id: task-132-23
    resource: backlog:TASK-132.23
    title: "Design: report each space as a WebKit window"
  - id: commit-sidepanel
    resource: commit:208bbd8
    title: Epic-branch commit recording the TASK-132.1 spike result
  - id: commit-resolve
    resource: commit:fef7505
    title: Epic-branch commit for TASK-132.2 (tab id resolution)
  - id: commit-parking
    resource: commit:96756a5
    title: Epic-branch commit for TASK-132.3 (automation-attached tabs)
  - id: side-panel-code
    resource: ../../Detour/Extensions/Runtime/ExtensionSidePanel.swift
    title: ExtensionSidePanel.swift (the side panel as built)
  - id: runtime-check
    resource: "Runtime check, 2026-10-04 (isolated profile, harness in .claude/task132.8-harness.patch; not in the repository)"
    title: Runtime check of the side panel with the real Claude extension, signed out
---

# Summary

Epic TASK-132 aims to make Anthropic's Claude extension (Chrome Web Store id
`fcoeoabgfenejglbffodgkkbkcdhcgfn`, reviewed at version 1.0.98) install, sign
in, open its side panel and drive pages in Detour. It needs three things
WebKit does not provide at all — a side panel, tab groups and
`chrome.debugger` — plus a handful of smaller APIs.

**All code for the epic lives on the branch `epic-claude-extension`, not on
`main`.** Most pages in this wiki describe `main`. Three parts of the epic
have been ingested from the branch's code and have pages of their own:
the [side panel](./side-panel.md),
[`runtime.getContexts`](./runtime-get-contexts.md) and
[command shortcuts](./command-shortcuts.md). The rest of this page is built
from the Backlog tasks only; where it cites findings, they come from task
notes. New tasks for the epic are still committed to `main` first, so task
numbers cannot collide.

Re-check the task-derived parts against the branch before relying on them.

# What the extension uses

From its 1.0.98 bundle, as recorded in the epic task:

| Area | Calls |
|---|---|
| Side panel | `sidePanel.setOptions({tabId, path, enabled})`, `sidePanel.open({tabId})` from `action.onClicked` and the `toggle-side-panel` command (Cmd+E). With `chrome.sidePanel` undefined it posts a "Browser not supported" notification and stops |
| Tab groups | `tabs.group` / `ungroup`, `tabGroups.get` / `query` / `update`, `tabGroups.Color`, `TAB_GROUP_ID_NONE`, `tab.groupId`, `tabs.query({groupId})`. One group per session; its tools act only on tabs in the group |
| Debugger | `attach`, `detach`, `getTargets`, `sendCommand`, `onEvent`, `onDetach` with a small CDP surface: `Page.captureScreenshot`, `Page.handleJavaScriptDialog`, `Input.dispatchMouseEvent` / `dispatchKeyEvent` / `insertText`, `Runtime.evaluate`, `Network.enable`, and the matching events |
| Sign-in | `runtime.onMessageExternal` from claude.ai (`externally_connectable`), `identity.getRedirectURL` / `launchWebAuthFlow` |
| Start-up | `declarativeNetRequest.updateSessionRules` with a `modifyHeaders` rule, awaited in `onInstalled` with no try/catch |
| Other | `runtime.getContexts` + `ContextType.SIDE_PANEL`, `downloads.download` / `search` / `onChanged`, `tabs.create({url: 'chrome://newtab'})`, `windows.create({type: 'popup'})`, `connectNative` to two Anthropic hosts |

It has no action popup.

# WebKit facts behind the plan

- WebKit vends no `tabs.group`, `tabGroups`, `debugger`, `identity`,
  `downloads` or `runtime.getContexts`.[^task-132]
- WebKit gives `externally_connectable` web pages a `browser` global only,
  never `chrome`, so `chrome.runtime.sendMessage(<id>, …)` from claude.ai is
  undefined and sign-in cannot finish without help.[^task-132-6]
- **The native side panel is compiled out.** `ENABLE_WK_WEB_EXTENSIONS_SIDEBAR`
  is defined as 0 in WebKit, both at the shipped-era revision and on `main`.
  Measured on macOS 26.7 with a standalone probe: no
  `WebExtensionSidebarEnabled` feature exists to turn on, the `sidePanel`
  permission is not recognised (it is absent from
  `WKWebExtension.requestedPermissions`), `chrome.sidePanel` is undefined in
  pages and workers, and `sidebarForTab:` returns nil.[^commit-sidepanel]
- **Nothing fired an extension's command shortcut.** WebKit keeps the manifest
  `commands` and raises `commands.onCommand`, but only when the host calls
  `performCommand(for:)`, and Detour never did
  ([command shortcuts](./command-shortcuts.md)).
- **`WebExtensionWindow::tabs()` returns nothing unless the window names an
  active tab that is in the list.** Detour reports no active tab when nothing
  is selected, which is a normal state, so such a window's tabs vanish from
  `tabs.query` and `windows.getAll`. By-id calls and tab events still
  work.[^task-132-21]
- **WebKit learns of a window only at context load or when it becomes key**,
  because Detour calls `didOpenWindow` nowhere else and never
  `didCloseWindow`.[^task-132-22]

# Product decisions

Recorded in the epic task on 2026-10-03:

- Tab groups first appear as a colour stripe on member rows. Header rows,
  collapse and drag come later.
- The extension must be able to drive tabs that are not selected, from the
  first version.
- A space per tab group was rejected: opening the panel groups the current
  tab at once, which would move it to another space.
- Nothing may raise the priority of hidden tabs in general. Any hold on a
  hidden tab must be scoped to a tab with a live extension attachment and
  dropped when that ends.[^task-132-3]

# Sub-task map

| Task | Subject | Depends on |
|---|---|---|
| 132.1 | Spike: native side panel or polyfill | |
| 132.2 | Resolve a WebKit tab id to its `BrowserTab` in polyfill handlers | |
| 132.3 | Automation-attached tabs: renderable and drivable while unselected | |
| 132.4 | Install and worker start-up; `declarativeNetRequest` session header rule | |
| 132.5 | `chrome://newtab` in `tabs.create` / `windows.create` opens a blank tab | |
| 132.6 | `chrome.runtime` on `externally_connectable` pages | |
| 132.7 | `identity.getRedirectURL` and `launchWebAuthFlow` | |
| 132.8 | Host a per-tab side panel beside the tab's content | 132.1 |
| 132.9 | `runtime.getContexts` and `runtime.ContextType` | 132.8 |
| 132.10 | Tab group model in `TabStore`, with persistence | |
| 132.11 | Sidebar colour stripe on grouped rows | 132.10 |
| 132.12 | `tabs.group` / `ungroup`, `chrome.tabGroups`, `groupId` on tabs | 132.2, 132.10 |
| 132.13 | `chrome.debugger` plumbing and `Page.captureScreenshot` | 132.2, 132.3 |
| 132.14 | Debugger input: mouse, key, `insertText` | 132.13 |
| 132.15 | Debugger `Runtime.evaluate` and JavaScript dialogs | 132.13 |
| 132.16 | Debugger console and network events | 132.13 |
| 132.17 | `chrome.downloads` | |
| 132.18 | `windows.create({type: 'popup'})` as a chromeless window | |
| 132.19 | Sidebar group header rows: collapse, rename, recolour, drag | 132.11 |
| 132.20 | End-to-end check in a signed build | most of the above |
| 132.21 | A window with nothing selected reports no tabs | 132.23, 132.12 |
| 132.22 | Announce window open and close to WebKit | 132.23 |
| 132.23 | Design: report each space as a WebKit window | |

Read a task with `backlog task view TASK-132.N --plain`.

# Decisions and measurements so far

## Side panel: a polyfill, hosted by Detour (132.1, 132.8)

Detour defines `chrome.sidePanel` itself and hosts the panel page in its own
web view built from the context's configuration, the way
[offscreen documents](./offscreen-documents.md) are hosted. The spike's
evidence and the alternative it ruled out are in
[chrome.sidePanel is polyfilled](../decisions/polyfilled-side-panel.md); what
was built is on [side panel](./side-panel.md).[^commit-sidepanel]

How the code met the consequences the spike listed:

- The module and the native handler are both gated on the manifest's
  `sidePanel` permission, which WebKit does not know.
- The panel is not a `BrowserTab`: no sidebar row, never the selected tab,
  never reported to WebKit.
- The Claude extension sets tab-specific options
  (`sidepanel.html?tabId=N`), so its panel is a *tab panel*: it shows only
  with its tab and only in the window that owns the tab's live web view.
- `setOptions` and `open` are called back to back without awaiting; the
  polyfill serialises the calls of one context so they arrive in order.

One difference from the task's wording: the task asked to reuse the split
view's hosting, "frame-based NSSplitView, divider, remembered fraction". The
code is frame-based and has a draggable divider, but it is a custom
`SidePanelLayoutView` rather than an `NSSplitView`, and it remembers a width
in points, one for all panels, rather than a fraction.[^side-panel-code]

Still true, and not worked around: WebKit grants no `activeTab` on
interaction with the panel.[^task-132-8] WebKit is still developing its own
side panel, so the probe should be re-run on new macOS releases.

## `runtime.getContexts` and the Cmd+E toggle (132.9, 132.8)

The extension's `toggle-side-panel` handler calls
`runtime.getContexts({contextTypes: [SIDE_PANEL]})`, then `setOptions` and
`open` without awaiting, then reads each context's `documentUrl` to see
whether a panel for that tab is already open;[^task-132-9] if one is, it sends
the panel page `{type: "close_side_panel", tabId}`.[^runtime-check] Detour
provides
[`runtime.getContexts`](./runtime-get-contexts.md), sends its request in the
call itself so the answer cannot include the panel the same handler is about
to open, and dispatches the shortcut
([command shortcuts](./command-shortcuts.md)).

Checked with the real extension, signed out: Cmd+E opened the panel; pressed
again, the worker found the panel and the page received `close_side_panel`,
but the panel stayed open, because the listener that calls `window.close()`
is part of the extension's signed-in components and the "Log in" screen does
not mount it. With a stand-in listener of the same body the panel closed and
the next press opened a fresh page.[^runtime-check] The closing half of the
toggle is therefore unverified with the real extension until it is checked
signed in ([side panel runtime check](../playbooks/side-panel-runtime-check.md)).

## Tab id resolution through `tabs.getZoom` (132.2)

Polyfilled APIs that take a `tabId` need the `BrowserTab` behind it, and
WebKit exposes no lookup. The mechanism chosen: `tabs.getZoom(tabId)` needs
neither the `tabs` permission nor host access, fails for an unknown id, and
returns the tab delegate's zoom value unclamped. The polyfill arms a resolve
natively, calls `getZoom`, and the tab WebKit resolved the id to answers with
a negative private handle instead of its zoom; the handle maps back to the
tab natively, refusing closed, unplaced and other-profile tabs. A genuine
`getZoom` call never sees a handle.[^commit-resolve]

Recorded limit: the reverse lookup walks `tabs.query({})`, which lists only
each window's active space, so a tab in a space no window shows is found only
if it was resolved before.

## Attached tabs are parked hidden, with no priority change (132.3)

An attached tab that no window displays keeps its web view container *in* a
browser window at content-area size, hidden, at the bottom of the z-order.
The measurements behind that choice (macOS 26.7):[^commit-parking]

| Web view | `visibilityState`, timers | Trusted input | Snapshot |
|---|---|---|---|
| In the window, covered by a sibling | visible, full rate, foreground assertion | yes | fresh |
| In the window, `isHidden` | hidden, throttled, no foreground assertion | yes | fresh |
| In no window | hidden, throttled | `mousedown` but no `mouseup` or `click` | fresh |

So **input needs a window, not visibility**, and a hidden parked view is
drivable without raising that tab. Un-hiding the parked view is the single
switch that would make one tab foreground; it is kept in reserve.

Other findings recorded there:

- WebKit asks the window to make a web view first responder on a mouse press
  it receives, hidden or not. The window must refuse it for a parked view, or
  the user's own tab loses focus.
- WebKit re-sends a key the page declined through the application, so a
  declined synthesized key would be typed into the *visible* page or fire a
  menu item. Synthesized keys are remembered and dropped when they come back.
- WebKit queues mouse and key events separately; a key sent right after a
  click can arrive before the click moves focus.
- When Detour's window is occluded, every web view including the selected
  one is hidden to WebKit; snapshots and input still work.
- A parked tab holds a background assertion where an ordinary hidden tab
  drops to none. That is the one measured difference.

Attached tabs are exempt from sleep and archive. See
[sleeping and archiving](../tabs/sleeping-and-archiving.md),
[web view ownership](../architecture/webview-ownership.md) and
[hidden web view load stalls](../platform/hidden-webview-load-stalls.md) for
the `main` behaviour this builds on.

## Open design: a space as the WebKit window (132.23)

Today a `BrowserWindowController` is the `WKWebExtensionWindow` and reports
only its active space's tabs (see
[tab and window bridge](./tab-and-window-bridge.md)). Consequences for an
extension that keeps session tabs: switching a window's space swaps its whole
tab list with no events; a tab in a space no window shows belongs to no
window; a window changes profile, and so which contexts it belongs to, when
it switches to a space on another profile.

The proposal in favour is to make the **Space** the WebKit window: a tab's
window is its space and never changes on a space switch, a space switch is a
focus change, and an extension's `windows.create` yields a new space. Decided
so far: pinned tabs and favourites are reported as tabs of a space's window,
and a favourite's backing tab gets exactly one home space. Not reporting
favourite tabs is ruled out, because content scripts run in them regardless
and unreported tabs fail every `runtime.sendMessage`.[^task-132-23]

For a window with nothing selected, the approach agreed to try is a **masked
stand-in**: natively name a stand-in active tab so WebKit keeps the list, and
have the polyfill rewrite it to `active: false`, drop it from active queries,
and refuse or wrap calls that default to "the current tab". Three
alternatives stay recorded in the task as the fallback: leave it, an unmasked
stand-in, and a placeholder blank tab.[^task-132-21]

# Related

- [Extensions overview](./overview.md) — the system on `main` this extends
- [Polyfill layer](./polyfill-layer.md) and [chrome runtime patching](./chrome-runtime-patching.md) — the rules new namespaces must follow
- [1Password integration](./1password-integration.md) — the previous extension-driven effort
- [Split tabs hosting](../tabs/split-tabs-hosting.md) — the frame-based hosting whose approach the side panel reuses
- [Side panel](./side-panel.md), [runtime.getContexts](./runtime-get-contexts.md), [command shortcuts](./command-shortcuts.md) — the parts of the epic ingested from the code
- [Sidebar row layout](../sidebar/row-layout.md) — where group stripes and headers must go through
- [Testing extensions](./testing-extensions.md) — the test bar each new API has to meet

[^task-132]: Epic: support the Claude extension (side panel, tab groups, chrome.debugger)
[^task-132-3]: Unselected tabs stay renderable and able to take synthesized input
[^task-132-6]: externally_connectable pages get chrome.runtime
[^task-132-8]: Host an extension's per-tab side panel beside the tab's content
[^task-132-9]: runtime.getContexts and runtime.ContextType
[^side-panel-code]: ExtensionSidePanel.swift (the side panel as built)
[^runtime-check]: Runtime check of the side panel with the real Claude extension, signed out
[^task-132-21]: A window with nothing selected reports no tabs to extensions
[^task-132-22]: Tell WebKit when a browser window opens or closes
[^task-132-23]: Design: report each space as a WebKit window
[^commit-sidepanel]: Epic-branch commit recording the TASK-132.1 spike result
[^commit-resolve]: Epic-branch commit for TASK-132.2 (tab id resolution)
[^commit-parking]: Epic-branch commit for TASK-132.3 (automation-attached tabs)
