---
type: Feature
title: runtime.getContexts
description: Detour's chrome.runtime.getContexts and runtime.ContextType — what is listed for each context type, how tab handles become WebKit's tab and window ids, why the request leaves in the call itself, and what cannot be reported.
tags: [extensions, runtime, polyfill, side-panel, contexts]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T18:50:00Z }
sources:
  - id: open-contexts
    resource: ../../Detour/Extensions/Runtime/ExtensionOpenContexts.swift
    title: ExtensionOpenContexts.swift (openContexts, ExtensionContextIdentity)
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift (runtimeGetContextsJS)
  - id: handler
    resource: ../../Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
    title: ExtensionPolyfillHandler.swift (the runtime.getContexts case)
  - id: popover
    resource: ../../Detour/Extensions/UI/ExtensionPopoverController.swift
    title: ExtensionPopoverController.swift (presentedPopups)
  - id: docs-extensions
    resource: ../../docs/extensions.md
    title: docs/extensions.md, "runtime.getContexts"
  - id: task-132-9
    resource: backlog:TASK-132.9
    title: runtime.getContexts and runtime.ContextType
  - id: task-132-1
    resource: backlog:TASK-132.1
    title: "Spike: can WebKit's native sidePanel be used (also probed runtime.getContexts)"
  - id: polyfill-tests
    resource: ../../DetourTests/ExtensionRuntimeGetContextsPolyfillTests.swift
    title: ExtensionRuntimeGetContextsPolyfillTests
  - id: integration-tests
    resource: ../../DetourTests/ExtensionRuntimeGetContextsTests.swift
    title: ExtensionRuntimeGetContextsTests
  - id: runtime-check
    resource: "Runtime check, 2026-10-04 (isolated profile, harness in docs/harness/task132.8-harness.patch)"
    title: Runtime check of the side panel with the real Claude extension, signed out
---

`chrome.runtime.getContexts(filter)` lists an extension's own live contexts,
and `chrome.runtime.ContextType` names their kinds. WebKit vends
neither.[^task-132-1] The Claude extension's shortcut handler reads both to
find out whether its [side panel](./side-panel.md) is already open, and threw
on the missing enum. Detour adds both to the `chrome.runtime` wrapper and
answers from what it hosts itself.

# What it does

Each context is `{contextType, contextId, frameId, incognito, tabId,
windowId}` plus `documentUrl` and `documentOrigin` where there is a document.
`ContextType` has Chrome's six values; `DEVELOPER_TOOLS` is never returned.

| `contextType` | What is listed | `tabId` / `windowId` | Document |
|---|---|---|---|
| `BACKGROUND` | The background, whenever the manifest declares one | -1 / -1 | None for a worker (`frameId` -1); the page's URL for a background page |
| `TAB` | An extension page in a tab, pinned entry, favourite or Peek that has a live web view | The tab / its window | The page |
| `POPUP` | The action popup while its popover is showing, however it was opened | -1 / the window the popover is attached to | The popup page |
| `OFFSCREEN_DOCUMENT` | The [offscreen document](./offscreen-documents.md), once loaded | -1 / -1 | The document |
| `SIDE_PANEL` | Every open side panel, on screen or hidden with its tab | -1 / its tab's window, or the window it belongs to | The panel page, query included |

All of Chrome's filters are honoured: `contextTypes`, `contextIds`, `tabIds`,
`windowIds`, `documentUrls`, `documentOrigins`, `documentIds`, `frameIds`,
`incognito`. A context matches when every filter given lists its value, so a
context without the value never matches a filter on it.

As seen with the real Claude extension: `getContexts({contextTypes:
[SIDE_PANEL]})` returned its panel with `documentUrl`
`…/sidepanel.html?tabId=<id>`, `tabId: -1` and the window's
`windowId`.[^runtime-check]

# How it works

## The native list

`ExtensionPolyfillHandler.openContexts(extensionID:)` builds the list from
what Detour hosts or presents, because WebKit tells the host nothing about an
extension's live documents. A handler belongs to one profile and is given a
verified extension id ([polyfill layer](./polyfill-layer.md)), so only the
calling extension's contexts in the calling profile are reachable. Any context
of the extension may ask, and there is no permission gate, as in Chrome.

- The background entry comes from the manifest, not from a running process.
- Tab pages come from `Profile.extensionPageLocations`; a sleeping tab has no
  document and is not a context.
- Popups come from `ExtensionPopoverController.presentedPopups`, which tracks
  every popover on screen, whether opened from a button, the Extensions menu
  or `action.openPopup()`.
- `contextId` is a UUID kept as an associated object on the thing that *is*
  the context for Detour: the web view, or the `WKWebExtensionContext` for the
  background (`ExtensionContextIdentity`). It lives exactly as long as that
  object.

## Handles become ids in the polyfill

Detour knows tabs, not WebKit's ids. The bridge therefore answers with tab
*handles*, and `runtimeGetContextsJS` translates them:

| Bridge field | Meaning | Becomes |
|---|---|---|
| `tabHandle` | The tab the context is a page of (`TAB` only) | `tabId`, through `__detourFindTabIdForHandle` |
| `windowTabHandle` | A tab that stands for the context's window: the tab itself, a panel's tab, the active tab of a window panel's or popup's window | `windowId`, as the `windowId` that `tabs.get` reports for that tab |

Either id is -1 when there is no handle or WebKit lists no such tab. That
includes a tab in a space no window shows, and a popup or window panel in a
window with nothing selected, which has no active tab to stand for it. This is
the same naming of a window by a tab that
[`sidePanel.open`](./side-panel.md) uses in the other direction.

Filters that need no id are applied first, so a call for one context type
resolves ids only for contexts of that type.

## The request leaves in the call itself

`getContexts` sends its bridge request synchronously, before anything is
awaited. The answer is therefore what was open at the moment of the call.
This is load-bearing for the Claude extension: its handler calls
`getContexts`, then `setOptions` and `open` without awaiting, then reads the
answer, and must not find the panel it has just asked for. A
[side panel](./side-panel.md) call resolves its tab id first, so it reaches
Detour later. `testTheRequestLeavesInTheCallItself` pins this.

A bad filter rejects without asking Detour.

## Patching `chrome.runtime`

Both members are added in place to the `chrome.runtime` wrapper WebKit vends,
only when absent. That wrapper is already pinned by `missingStubsJS`; this
module roots it a second time under `runtime` in `__detourHeldWrappers` (and a
distinct `browser.runtime` under `browserRuntime`), so a test can assert
`__detourHeldWrappers.runtime === chrome.runtime` before and after a
collection. See [chrome runtime patching](./chrome-runtime-patching.md).
`ContextType` is installed here and not with the other runtime constants,
because an enum without its API would make a feature test for the API lie.

The state is in `__detourPolyfillDiag.apis.runtimeGetContexts`: `polyfill`,
`native`, `absent`, `define-failed` or `polyfill-not-visible`.

# Edge cases

- No `documentId`: WebKit does not tell the host one, so a `documentIds`
  filter matches nothing.
- An extension frame inside a web page is not listed; frames are not
  enumerated.
- The background is listed whether or not its worker is running at that
  instant. WebKit does not say, and starts one on demand.
- `incognito` is the profile's, the same for every context in the answer.
- A tab that slept and woke has a new web view and so a new `contextId`.

# Tests

| Suite | Proves |
|---|---|
| [ExtensionRuntimeGetContextsPolyfillTests](../../DetourTests/ExtensionRuntimeGetContextsPolyfillTests.swift) | The enum, native members left alone, id resolution (and only for contexts the other filters keep), the filters, bad filters, callback form and `lastError`, the timing of the request |
| [ExtensionRuntimeGetContextsTests](../../DetourTests/ExtensionRuntimeGetContextsTests.swift) | A real extension from the worker and a page: the worker, a tab page and an open panel with their ids; a panel hidden with its tab; a window panel; the offscreen document; another extension's and another profile's contexts never returned; `incognito` in Private; survival of a garbage collection; the shortcut toggle built on it |

API Explorer has a "runtime.getContexts" section in its popup, and its side
panel page reports its own context.

# Related

- [Side panel](./side-panel.md) — the context this was added to find.
- [Command shortcuts](./command-shortcuts.md) — the handler that calls it.
- [Chrome runtime patching](./chrome-runtime-patching.md) — why the wrapper is rooted.
- [Tab and window bridge](./tab-and-window-bridge.md) — where WebKit's tab and window ids come from.
- [Popup and options UI](./popup-and-options-ui.md) — the popups listed as `POPUP`.

[^task-132-1]: Spike: can WebKit's native sidePanel be used (also probed runtime.getContexts)
[^runtime-check]: Runtime check of the side panel with the real Claude extension, signed out
