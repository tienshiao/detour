---
type: Overview
title: Claude extension epic
description: The in-flight epic to make Anthropic's Claude extension install, sign in and drive pages in Detour — what the extension needs, the sub-task map, and the decisions and measurements so far. None of this code is on main.
tags: [extensions, epic, side-panel, tab-groups, debugger, planning]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:41Z }
stale_after: 2026-12-06T00:00:00Z
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
  - id: task-132-5
    resource: backlog:TASK-132.5
    title: tabs.create and windows.create with chrome://newtab open a blank new tab
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
  - id: task-132-11
    resource: backlog:TASK-132.11
    title: Colour stripe on tab rows that belong to a tab group
  - id: task-132-12
    resource: backlog:TASK-132.12
    title: tabs.group, tabs.ungroup, chrome.tabGroups and groupId on tabs
  - id: task-132-13
    resource: backlog:TASK-132.13
    title: chrome.debugger plumbing and Page.captureScreenshot
  - id: task-132-14
    resource: backlog:TASK-132.14
    title: chrome.debugger input (dispatchMouseEvent, dispatchKeyEvent, insertText)
  - id: task-132-15
    resource: backlog:TASK-132.15
    title: chrome.debugger Runtime.evaluate and JavaScript dialog handling
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
  - id: task-132-24
    resource: backlog:TASK-132.24
    title: A parked tab keeps the dev toolbar after it navigates away from a development URL
  - id: task-132-25
    resource: backlog:TASK-132.25
    title: A scrolling action popup shrinks back when its content gets shorter
  - id: task-132-26
    resource: backlog:TASK-132.26
    title: "Wiki: refresh the Claude extension epic page from the merged code"
  - id: task-132-27
    resource: backlog:TASK-132.27
    title: tabs.update with a url on a sleeping tab reports success but never navigates
  - id: task-132-28
    resource: backlog:TASK-132.28
    title: Differential test of Runtime.evaluate's completion-value rewrite
  - id: commit-sidepanel
    resource: commit:208bbd8
    title: Epic-branch commit recording the TASK-132.1 spike result
  - id: commit-resolve
    resource: commit:fef7505
    title: Epic-branch commit for TASK-132.2 (tab id resolution)
  - id: commit-parking
    resource: commit:96756a5
    title: Epic-branch commit for TASK-132.3 (automation-attached tabs)
  - id: commit-side-panel-code
    resource: commit:a7e20592
    title: Epic-branch commit for TASK-132.8 (chrome.sidePanel and the hosted panel)
  - id: commit-get-contexts
    resource: commit:b6dac1b1
    title: Epic-branch commit for TASK-132.9 (runtime.getContexts)
  - id: commit-tab-groups
    resource: commit:80003b38
    title: Epic-branch commit for TASK-132.10 (tab group model in TabStore)
  - id: commit-tab-groups-api
    resource: commit:79c2ce01
    title: Epic-branch commit for TASK-132.12 (chrome.tabGroups)
  - id: commit-debugger
    resource: commit:8576caa6
    title: Epic-branch commit for TASK-132.13 (chrome.debugger and Page.captureScreenshot)
  - id: branch-head
    resource: commit:528ce5f3
    title: Head of epic-claude-extension (commit dated 2026-11-07) when this page was refreshed on 2026-11-15
  - id: runtime-check
    resource: "Runtime check, 2026-10-04 (isolated profile, harness in docs/harness/task132.8-harness.patch on the epic branch)"
    title: Runtime check of the side panel with the real Claude extension, signed out
---

# Summary

Epic TASK-132 aims to make Anthropic's Claude extension (Chrome Web Store id
`fcoeoabgfenejglbffodgkkbkcdhcgfn`; reviewed at 1.0.98 when the epic was
planned, 1.0.105 by November 2026) install, sign in, open its side panel and
drive pages in Detour. It needs three things WebKit does not provide at
all — a side panel, tab groups and `chrome.debugger` — plus a handful of
smaller APIs.

**All code for the epic lives on the branch `epic-claude-extension`, not on
`main`.** Most pages in this wiki describe `main`. This page was refreshed on
2026-11-15 from the branch's copies of the TASK-132 tasks (their notes exist
only there until the branch merges) at branch head
`528ce5f3`;[^branch-head] it was not re-checked line by line against the
branch's code. `main` was last merged into the branch on 2026-11-07. New
tasks for the epic are still committed to `main` first, so task numbers
cannot collide.

## Pages that arrive with the merge

The branch documents most of what has been built in pages of its own. They
do not exist on `main` yet, so they are named here by path rather than
linked; read them with `git show epic-claude-extension:wiki/<path>`.

| Page on the branch | Covers |
|---|---|
| `extensions/side-panel.md` | `chrome.sidePanel` as built: tab and global panels, hosting, the layout view (132.8) |
| `decisions/polyfilled-side-panel.md` | Why the side panel is a polyfill; the spike's evidence (132.1) |
| `playbooks/side-panel-runtime-check.md` | Checking the panel with the real extension |
| `extensions/runtime-get-contexts.md` | `runtime.getContexts` and `ContextType` (132.9) |
| `extensions/command-shortcuts.md` | Manifest `commands` dispatched through `performCommand(for:)` |
| `tabs/tab-groups.md` | The `TabStore` group model, its invariants, placement rule, undo, persistence, sidebar stripe (132.10, 132.11) |
| `extensions/tab-groups-api.md` | `chrome.tabGroups`, `tabs.group` / `ungroup`, `groupId` (132.12) |
| `extensions/debugger-api.md` | `chrome.debugger` over an emulated CDP: attach, screenshots, input, `Runtime.evaluate`, dialogs, console and network events, Stop (132.13–132.16) |

The branch also updates existing pages, among them
[tab and window bridge](./tab-and-window-bridge.md),
[polyfill layer](./polyfill-layer.md),
[chrome runtime patching](./chrome-runtime-patching.md),
[popup and options UI](./popup-and-options-ui.md) and
[web view ownership](../architecture/webview-ownership.md), and carries its
own revision of this page (dated 2026-10-04). This copy was built from that
revision and adds to it, so the two conflict at the merge and this one
supersedes it.

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

It has no action popup. On install it opens the claude.ai login page by
itself.[^task-132-4]

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
  `performCommand(for:)`, and `main` never calls it (its
  `AutomationCompatReport` says as much). The branch dispatches it (the
  branch's `extensions/command-shortcuts.md`).
- **WebKit vends `declarativeNetRequest` but no enums**, accepts
  `modifyHeaders` only for header names on its own list, and does not apply
  an accepted rule to the service worker's own `fetch`. A block session rule
  does work on tab pages.[^task-132-4]
- **WebKit redacts the URL and title of any tab whose scheme is not a
  match-pattern scheme** (`about:`, `chrome:`), whatever the extension's
  permissions, so a blank tab reports `url: ''`.[^task-132-5]
- **`WebExtensionWindow::tabs()` returns nothing unless the window names an
  active tab that is in the list.** Detour reports no active tab when nothing
  is selected, which is a normal state, so such a window's tabs vanish from
  `tabs.query` and `windows.getAll`. By-id calls and tab events still
  work.[^task-132-21] Seen again in the 132.12 runtime check.[^task-132-12]
- **WebKit learns of a window only at context load or when it becomes key**,
  because Detour calls `didOpenWindow` nowhere else and never
  `didCloseWindow`.[^task-132-22]

# Product decisions

Recorded in the epic task on 2026-10-03, unless dated:

- Tab groups first appear as a colour stripe on member rows. Header rows,
  collapse and drag come later. 2026-10-04: one stripe on the sidebar row,
  nowhere else.[^task-132-11]
- The extension must be able to drive tabs that are not selected, from the
  first version.
- A space per tab group was rejected: opening the panel groups the current
  tab at once, which would move it to another space.
- Nothing may raise the priority of hidden tabs in general. Any hold on a
  hidden tab must be scoped to a tab with a live extension attachment and
  dropped when that ends.[^task-132-3]
- 2026-11-07: a tab opened from a grouped tab joins the opener's group when
  it lands next to it, and undo of closing a group's last tab recreates the
  group.[^task-132-10]
- 2026-11-07: `Runtime.evaluate` uses an in-house tokenizer for completion
  values. Vendoring acorn was proposed and not done, because shipping
  third-party code is the user's call; 132.28 is the test that would show
  whether it is needed.[^task-132-15]

# Sub-task map

As of 2026-11-15. "On the branch" means the task's code is committed to
`epic-claude-extension`; "open" lists what its notes say is still unchecked.

| Task | Subject | Depends on | Where it stands |
|---|---|---|---|
| 132.1 | Spike: native side panel or polyfill | | On the branch: polyfill chosen |
| 132.2 | Resolve a WebKit tab id to its `BrowserTab` in polyfill handlers | | On the branch |
| 132.3 | Automation-attached tabs: renderable and drivable while unselected | | On the branch |
| 132.4 | Install and worker start-up; `declarativeNetRequest` session header rule | | On the branch; Web Store install through the UI checked |
| 132.5 | `chrome://newtab` in `tabs.create` / `windows.create` opens a blank tab | | On the branch |
| 132.6 | `chrome.runtime` on `externally_connectable` pages | | On the branch; open: a real sign-in |
| 132.7 | `identity.getRedirectURL` and `launchWebAuthFlow` | | Not started |
| 132.8 | Host a per-tab side panel beside the tab's content | 132.1 | On the branch |
| 132.9 | `runtime.getContexts` and `runtime.ContextType` | 132.8 | On the branch |
| 132.10 | Tab group model in `TabStore`, with persistence | | On the branch |
| 132.11 | Sidebar colour stripe on grouped rows | 132.10 | On the branch; open: the stripe during a live drag |
| 132.12 | `tabs.group` / `ungroup`, `chrome.tabGroups`, `groupId` on tabs | 132.2, 132.10 | On the branch; open: the real extension's group (needs sign-in) |
| 132.13 | `chrome.debugger` plumbing and `Page.captureScreenshot` | 132.2, 132.3 | On the branch |
| 132.14 | Debugger input: mouse, key, `insertText` | 132.13 | On the branch |
| 132.15 | Debugger `Runtime.evaluate` and JavaScript dialogs | 132.13 | On the branch |
| 132.16 | Debugger console and network events | 132.13 | On the branch |
| 132.17 | `chrome.downloads` | | Not started |
| 132.18 | `windows.create({type: 'popup'})` as a chromeless window | | Not started |
| 132.19 | Sidebar group header rows: collapse, rename, recolour, drag | 132.11 | Not started |
| 132.20 | End-to-end check in a signed build | most of the above | Not started; the next step |
| 132.21 | A window with nothing selected reports no tabs | 132.23, 132.12 | Not started |
| 132.22 | Announce window open and close to WebKit | 132.23 | Not started |
| 132.23 | Design: report each space as a WebKit window | | Design discussion only |
| 132.24 | A parked tab keeps the dev toolbar after navigating off a dev URL | | Filed 2026-11-04 from the merge of `main` |
| 132.25 | A scrolling action popup does not shrink back | | Filed 2026-11-04, lost in the merge of `main` |
| 132.26 | Refresh this page from the merged code | | Filed; this page's November refresh covers it only from task notes |
| 132.27 | `tabs.update` with a url on a sleeping tab reports success, never navigates | | Filed 2026-11-07 |
| 132.28 | Differential test of `Runtime.evaluate`'s completion-value rewrite | | Filed 2026-11-08, on `main` only |

Read a task with `backlog task view TASK-132.N --plain`, or its branch copy
with `git show epic-claude-extension:backlog/tasks/<file>`.

**What remains** before the epic can be called working: nothing has been
checked with the extension signed in, in any build. That blocks the closing
half of the Cmd+E toggle, 132.6's sign-in and 132.12's session group, and is
what 132.20 does in a signed build. 132.27 matters for the agent: a tab of
its group that the sleep policy put to sleep silently stops following
`tabs.update`.[^task-132-27] `chrome.identity` (132.7) does not exist yet;
132.4 found it is not called at start-up, only when the extension
re-authorises. The tab group migration is numbered v23 on the
branch and has to be renumbered when the epic merges.[^task-132-10]

# Decisions and measurements so far

## Side panel: a polyfill, hosted by Detour (132.1, 132.8)

Detour defines `chrome.sidePanel` itself and hosts the panel page in its own
web view built from the context's configuration, the way
[offscreen documents](./offscreen-documents.md) are hosted. The probe
confirmed that the own property sticks in both the worker and an extension
page (`chrome === browser` there), and that a web view built from
`context.webViewConfiguration` runs the controller's user scripts, so it gets
the polyfill and the profile's data store.[^commit-sidepanel]

How the code met the consequences the spike listed:[^commit-side-panel-code]

- The module and the native handler are both gated on the manifest's
  `sidePanel` permission, which WebKit does not know.
- The panel is not a `BrowserTab`: no sidebar row, never the selected tab,
  never reported to WebKit.
- The Claude extension sets tab-specific options
  (`sidepanel.html?tabId=N`), so its panel is a *tab panel*: it shows only
  with its tab and only in the window that owns the tab's live web view.
- `setOptions` and `open` are called back to back without awaiting; the
  polyfill serialises the calls of one context so they arrive in order.

The task asked to reuse the split view's hosting ("frame-based NSSplitView,
divider, remembered fraction"). The code is frame-based with a draggable
divider, but it is a custom `SidePanelLayoutView` rather than an
`NSSplitView`, and it remembers one width in points for all panels rather
than a fraction.[^commit-side-panel-code]

Still true, and not worked around: WebKit grants no `activeTab` on
interaction with the panel.[^task-132-8] WebKit is still developing its own
side panel, so the probe should be re-run on new macOS releases.

## `runtime.getContexts` and the Cmd+E toggle (132.9, 132.8)

The extension's `toggle-side-panel` handler calls
`runtime.getContexts({contextTypes: [SIDE_PANEL]})`, then `setOptions` and
`open` without awaiting, then reads each context's `documentUrl` to see
whether a panel for that tab is already open;[^task-132-9] if one is, it sends
the panel page `{type: "close_side_panel", tabId}`.[^runtime-check] Detour
provides `runtime.getContexts`, sends its request in the call itself so the
answer cannot include the panel the same handler is about to open, and
dispatches the shortcut.[^commit-get-contexts]

Checked with the real extension, signed out: Cmd+E opened the panel; pressed
again, the worker found the panel and the page received `close_side_panel`,
but the panel stayed open, because the listener that calls `window.close()`
is part of the extension's signed-in components and the "Log in" screen does
not mount it. With a stand-in listener of the same body the panel closed and
the next press opened a fresh page.[^runtime-check] The closing half of the
toggle is unverified with the real extension until it is checked signed in.

## Start-up: header rules Detour holds (132.4)

The unmodified extension's worker first threw on `chrome.tabGroups.Color`
and `chrome.debugger.onEvent` at module evaluation, then on the missing
`declarativeNetRequest` enums and on WebKit refusing its custom header
name.[^task-132-4] The branch adds the enums and `runtime.OnInstalledReason`;
WebKit gets every rule first, and Detour keeps only the header rules WebKit
refuses and applies them to the extension's *own* `fetch` and XHR. Limits
recorded: a Detour-held rule does not reach tab pages, session rules only,
and every http(s) fetch from an extension holding the permission costs a
native round trip. The interim `tabGroups` / `debugger` stand-ins this task
added have since been replaced by 132.12 and 132.13.

Checked: a real Web Store install through the UI (all 16 permissions in the
prompt), then the worker through `onInstalled` with no uncaught error in
70 s, with native messaging pointed at shadow manifests so no real Anthropic
host could connect.[^task-132-4]

## `chrome://newtab` (132.5)

`chrome://newtab` (any case, with or without the slash) opens the same blank
`about:blank` tab `tabs.create({})` opens, from `tabs.create`,
`windows.create` and `tabs.update`; any other `chrome:` URL is refused before
anything opens. Before this, WebKit passed `chrome:` URLs through and Detour
sent them down the external-application path. Reporting
`chrome://newtab/` back to the extension was rejected because WebKit would
redact it anyway.[^task-132-5]

## Sign-in bridge for `externally_connectable` (132.6)

Measured on macOS 26.7: WebKit puts `browser.runtime` on every web page and
decides delivery per message; a refused or unanswered message resolves
`undefined` with no error. claude.ai's login page tries an internal
extension id first and treats any reply other than `{success: false}` as
signed in, so WebKit's silent `undefined` would end its loop before the real
extension is asked: Chrome's "Receiving end does not exist" error is
required. The branch installs a shim that gives listed pages
`chrome.runtime`, scoped by Detour's table of loaded contexts, extending an
existing `window.chrome` and leaving an existing `chrome.runtime`
alone.[^task-132-6] Checked with the real extension signed out (ping answered,
unknown id fails as in Chrome); a real sign-in has not been done.

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

## Tab groups (132.10, 132.11, 132.12)

The model (branch page `tabs/tab-groups.md`): a `TabGroup` (title, one of
Chrome's nine colour names, collapsed) lives in `Space.tabGroups`;
membership is `BrowserTab.tabGroupID`, like a split. Every mutation keeps
members contiguous, a split pair wholly in or out, only normal tabs, and no
empty group; one pure placement rule decides where an entering tab lands and
which group it joins. Not done on purpose: closed-tab records keep no group,
and the archive timer can archive an idle grouped tab out of its
group.[^commit-tab-groups][^task-132-10]

The sidebar draws a 3 pt stripe in the gutter left of each member row,
joined into one bar per group. Chrome's colour names are drawn as the macOS
system colours of the same name; resolved against the vibrant sidebar,
`systemBlue` came out `#4584F2` on unselected rows and `#5199FA` on the
selected one, so the stripe resolves against plain aqua / dark aqua to avoid
a seam.[^task-132-11]

The API (branch page `extensions/tab-groups-api.md`): group ids are random
per session (a counter leaked how many groups other profiles made);
`groupId` on Tab objects and `tabs.query({groupId})` are only for extensions
declaring `tabGroups`, because each decoration resolves tabs through the
tab-id bridge; `tabs.group` / `ungroup` are ungated, as in Chrome. Not like
Chrome: no moving groups between windows, and a tab opening straight into a
group reaches `onCreated` ungrouped, then `onUpdated({groupId})`.[^commit-tab-groups-api][^task-132-12]

## `chrome.debugger` over an emulated CDP (132.13–132.16)

Detailed on the branch page `extensions/debugger-api.md`. In short:[^commit-debugger]

- Attaching makes the tab automation-attached (132.3), so unselected tabs can
  be captured and driven. One debugger per tab, Chrome's attach rules and
  error texts; unknown CDP methods fail with CDP's "wasn't found". The user
  sees a driven tab (sidebar indicator, a capsule over the page) and can Stop
  it.[^task-132-13]
- `Page.captureScreenshot` follows Chrome's geometry (CSS size × `clip.scale`
  × device pixel ratio), because the extension resizes on a mismatch.[^task-132-13]
- Input goes as real `NSEvent`s straight to the attached tab's web view,
  parked or displayed, so the page sees trusted events. A synthesized event
  never takes first responder, the context menu, a `<select>` popup or an OS
  drag session from the user. Limits: no HTML drag and drop, touch, gestures
  or IME; the driven page has no focus.[^task-132-14]
- `Runtime.evaluate` runs in the page's main world through
  `callAsyncJavaScript` (CSP-proof, top-level await) with V8-shaped results.
  The completion value comes from a tokenizer that rewrites the final
  statement; the value is lost after `if` / loops / `switch` / `try`, and
  132.28 is filed to test the rewrite against WebKit's own evaluation. With
  `Page` enabled, `alert` / `confirm` / `prompt` wait for
  `handleJavaScriptDialog`. Main frame only.[^task-132-15][^task-132-28]
- Console and network events: WebKit offers neither, so only an attached tab
  is instrumented for the session (page-world wrappers for console, `fetch`
  and XHR, plus resource timing), removed on detach. Main frame only, no
  status for subresources, no bodies or redirects, nothing from before the
  attach.[^task-132-16]

Each was checked at runtime in an isolated profile with a harness (132.13
and 132.14 through the API Explorer extension), none with the Claude
extension. Screenshot failures reported in the 132.15 and 132.16 checks were
the harness loop misreading its log line, not capture.[^task-132-16]

## Open design: a space as the WebKit window (132.23)

Today a `BrowserWindowController` is the `WKWebExtensionWindow` and reports
only its active space's tabs (see
[tab and window bridge](./tab-and-window-bridge.md)). Consequences for an
extension that keeps session tabs: switching a window's space swaps its whole
tab list with no events; a tab in a space no window shows belongs to no
window; a window changes profile, and so which contexts it belongs to, when
it switches to a space on another profile. 132.5 met another: an extension's
`windows.create` opens on the profile's most recently used space and reports
all of that space's tabs.[^task-132-5]

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

## Problems from merging `main` into the branch

The 2026-11-04 merge left two regressions: a parked tab keeps whatever dev
toolbar it had when parked,[^task-132-24] and a scrolling action popup no
longer shrinks back when its content gets shorter.[^task-132-25]

# Related

- [Extensions overview](./overview.md) — the system on `main` this extends
- [Polyfill layer](./polyfill-layer.md) and [chrome runtime patching](./chrome-runtime-patching.md) — the rules new namespaces must follow
- [Tab and window bridge](./tab-and-window-bridge.md) — how windows and tabs are reported to WebKit on `main`, which 132.21–132.23 would change
- [1Password integration](./1password-integration.md) — the previous extension-driven effort
- [Split tabs hosting](../tabs/split-tabs-hosting.md) — the frame-based hosting whose approach the side panel reuses
- [Sidebar row layout](../sidebar/row-layout.md) — where group stripes and headers must go through
- [Testing extensions](./testing-extensions.md) — the test bar each new API has to meet

[^task-132]: Epic: support the Claude extension (side panel, tab groups, chrome.debugger)
[^task-132-3]: Unselected tabs stay renderable and able to take synthesized input
[^task-132-4]: The extension installs and its worker start-up completes (declarativeNetRequest session header rule)
[^task-132-5]: tabs.create and windows.create with chrome://newtab open a blank new tab
[^task-132-6]: externally_connectable pages get chrome.runtime
[^task-132-8]: Host an extension's per-tab side panel beside the tab's content
[^task-132-9]: runtime.getContexts and runtime.ContextType
[^task-132-10]: Tab group model in TabStore
[^task-132-11]: Colour stripe on tab rows that belong to a tab group
[^task-132-12]: tabs.group, tabs.ungroup, chrome.tabGroups and groupId on tabs
[^task-132-13]: chrome.debugger plumbing and Page.captureScreenshot
[^task-132-14]: chrome.debugger input (dispatchMouseEvent, dispatchKeyEvent, insertText)
[^task-132-15]: chrome.debugger Runtime.evaluate and JavaScript dialog handling
[^task-132-16]: chrome.debugger console and network events
[^task-132-21]: A window with nothing selected reports no tabs to extensions
[^task-132-22]: Tell WebKit when a browser window opens or closes
[^task-132-23]: Design: report each space as a WebKit window
[^task-132-24]: A parked tab keeps the dev toolbar after it navigates away from a development URL
[^task-132-25]: A scrolling action popup shrinks back when its content gets shorter
[^task-132-27]: tabs.update with a url on a sleeping tab reports success but never navigates
[^task-132-28]: Differential test of Runtime.evaluate's completion-value rewrite
[^commit-sidepanel]: Epic-branch commit recording the TASK-132.1 spike result
[^commit-resolve]: Epic-branch commit for TASK-132.2 (tab id resolution)
[^commit-parking]: Epic-branch commit for TASK-132.3 (automation-attached tabs)
[^commit-side-panel-code]: Epic-branch commit for TASK-132.8 (chrome.sidePanel and the hosted panel)
[^commit-get-contexts]: Epic-branch commit for TASK-132.9 (runtime.getContexts)
[^commit-tab-groups]: Epic-branch commit for TASK-132.10 (tab group model in TabStore)
[^commit-tab-groups-api]: Epic-branch commit for TASK-132.12 (chrome.tabGroups)
[^commit-debugger]: Epic-branch commit for TASK-132.13 (chrome.debugger and Page.captureScreenshot)
[^branch-head]: Head of epic-claude-extension (commit dated 2026-11-07) when this page was refreshed on 2026-11-15
[^runtime-check]: Runtime check of the side panel with the real Claude extension, signed out
