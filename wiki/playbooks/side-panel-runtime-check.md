---
type: Playbook
title: Side panel runtime check
description: How to check an extension side panel in the running app — open it through the real click and Cmd+E paths, prove a tab switch does not reload it, and exercise the Claude extension's shortcut toggle while signed out with a stand-in close listener.
tags: [playbook, extensions, side-panel, runtime, harness]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T19:22:07Z }
sources:
  - id: runtime-check
    resource: "Runtime check, 2026-10-04 (isolated profile, harness in .claude/task132.8-harness.patch; not in the repository)"
    title: Runtime check of the side panel with API Explorer and the real Claude extension, signed out
  - id: panel
    resource: ../../Detour/Extensions/Runtime/ExtensionSidePanel.swift
    title: ExtensionSidePanel.swift (the panels a harness reads, the close reasons it logs)
  - id: dispatch
    resource: ../../Detour/Extensions/Runtime/ExtensionCommandDispatch.swift
    title: ExtensionCommandDispatch.swift (the ext-commands log line)
  - id: window-side
    resource: ../../Detour/Browser/Window/BrowserWindowController+SidePanel.swift
    title: BrowserWindowController+SidePanel.swift (displayedSidePanel)
  - id: api-explorer
    resource: ../../TestExtensions/api-explorer
    title: API Explorer (Side Panel and runtime.getContexts sections, sidepanel.html)
  - id: task-132-8
    resource: backlog:TASK-132.8
    title: Host an extension's per-tab side panel beside the tab's content
---

The [side panel](../extensions/side-panel.md) suites drive real windows that
are never shown, and call the command dispatch directly. This is the
procedure for what they cannot see: the real click and key paths, the docked
Web Inspector, and a real extension's page. It was run once, on
2026-10-04.[^runtime-check]

# When to use

- After changing panel hosting, `reconcile`, the focus rule, the divider or
  [command dispatch](../extensions/command-shortcuts.md).
- To check the Claude extension's Cmd+E toggle without an account.

# Steps

## 1. Set up

1. Seed the extension into an isolated profile
   ([seeding extensions](./seeding-extensions.md)), with its permission rows.
   API Explorer covers the API from a popup and from the worker; the real
   Claude extension covers the toggle.
2. Serve two or three plain pages on loopback and open them as tabs, so the
   panel has real pages beside it.
3. Drive the rest from a [debug harness](./debug-harness.md). The open panels
   are `profile.sidePanels.panels(for: extensionID)`; what a window shows is
   `windowController.displayedSidePanel`; the frames are
   `windowController.contentAreaView.frames`.

## 2. Open through the real entry point

- Claude: a posted click on its pinned toolbar button
  ([in-process UI automation](./in-process-ui-automation.md)); fall back to
  `performClick` if the events do not fire it.
- API Explorer: its popup's "Side Panel" buttons, with and without "via
  worker".

Expect the log line `Opened the side panel of <id> (tab panel)` in the
`ext-sidepanel` category ([reading runtime logs](./reading-runtime-logs.md)).

## 3. Prove a tab switch does not reload the panel

1. In the panel's web view set a marker:
   `globalThis.__harnessMarker = 'marker-' + Date.now()`.
2. `selectTab` another tab: no panel displayed, the panel still in
   `panels(for:)`.
3. `selectTab` back: the same web view object, in the window, and the marker
   still there.

An empty marker means the page was loaded again. Use the same read after a
close and reopen, where a fresh page is the expected result.

## 4. Press the shortcut

The window must be key for a key equivalent to route:

```swift
NSApp.activate(ignoringOtherApps: true)
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(pageWebView)
// keyDown then keyUp: modifierFlags [.command], characters "e", keyCode 14
NSApp.postEvent(event, atStart: false)
```

Expect `Performed a command shortcut of <id>` in the `ext-commands` category.

## 4b. Keyboard focus

With the app active and the tab's web view first responder:

1. Click a field in the panel page (a real mouse event on the panel web
   view). The window's first responder becomes the `ExtensionSidePanelWebView`
   and `document.activeElement` is the field; post plain key events and read
   the field's value.
2. Make the tab's web view first responder again, then call `blur()` and
   `focus()` on the field from the panel page. The first responder must stay
   the tab's web view: the page asking for focus is suppressed.
3. Post a shortcut without Command (API Explorer's Option+Shift+E) with the
   page focused, and look for `Performed a command shortcut` in the
   `ext-commands` log category and the worker's `commands.onCommand` line.

All three held on 2026-10-04.[^runtime-check]

## 5. The Claude toggle, signed out

Before the second press, record what the panel page is sent, and what the
worker will see:

```js
globalThis.__harnessMessages = [];
chrome.runtime.onMessage.addListener((m) => { globalThis.__harnessMessages.push(m); });
await chrome.runtime.getContexts({ contextTypes: [chrome.runtime.ContextType.SIDE_PANEL] });
```

Press Cmd+E with the panel open. Signed out, the panel **stays open**, and
`__harnessMessages` holds `{type: "close_side_panel", tabId}`: Detour
delivered the worker's message, and nothing in the page acted on it. Then
install a stand-in with the body of the extension's own listener:

```js
const own = Number(new URLSearchParams(location.search).get('tabId'));
chrome.runtime.onMessage.addListener((m) => {
  if (m.type === 'close_side_panel' && m.tabId === own) window.close();
});
```

Press Cmd+E again: the panel closes, logged as `Closed the side panel of
<id>: its page called window.close()`. A third press opens it with an empty
marker, a fresh page.

## 6. The docked Web Inspector

In the harness only: `webView.value(forKey: "_inspector")`, then perform
`show`. It is docked when the web view's superview gains a second subview and
the web view's frame shrinks. Check a single tab with a panel, a split with a
panel, and the panel's own page; what was seen is on
[split tabs hosting](../tabs/split-tabs-hosting.md).

# Traps

- **The signed-out Claude panel has no close listener.** The "Log in" screen
  does not mount the components that own it. A panel that survives Cmd+E
  there is not a Detour bug; without the stand-in the toggle's closing half
  cannot be checked short of signing in.
- **Activating the app takes focus from whoever is at the machine.** Do it
  only for the shortcut steps, and deactivate afterwards.
- **A locked screen** drops posted events and blanks captures
  ([in-process UI automation](./in-process-ui-automation.md)).
- **Telling the two web views apart** in a first-responder dump: a tab's is a
  `BrowserWebView`, a panel's a plain `WKWebView`.
- **A narrow pane gets a detached inspector**, which looks like a docking
  regression and is not.
- The harness and its logs are not in the repository; this page and the
  suites are the reference.

# Related

- [Side panel](../extensions/side-panel.md) — the rules being checked.
- [Command shortcuts](../extensions/command-shortcuts.md) — the key path.
- [Runtime verification](./runtime-verification.md) — build, launch, isolate.
- [Debug harness](./debug-harness.md) — the pattern the steps run in.
- [Seeding extensions](./seeding-extensions.md) — getting the extension into the profile.
- [Testing extensions](../extensions/testing-extensions.md) — what the suites already prove.

[^runtime-check]: Runtime check of the side panel with API Explorer and the real Claude extension, signed out
