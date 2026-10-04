---
type: Component
title: App shell
description: "AppDelegate and main.swift — launch and termination, window creation, the menu bar built in code, the key-equivalent fast path, Sparkle, and every launch-time environment switch."
resource: ../../Detour/App/AppDelegate.swift
tags: [architecture, app, menus, sparkle, startup]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:30:20Z }
sources:
  - id: app-delegate
    resource: ../../Detour/App/AppDelegate.swift
    title: AppDelegate.swift
  - id: main
    resource: ../../Detour/App/main.swift
    title: main.swift
  - id: matcher
    resource: ../../Detour/App/MenuKeyEquivalentMatcher.swift
    title: MenuKeyEquivalentMatcher.swift
  - id: info-plist
    resource: ../../Detour/Resources/Info.plist
    title: Info.plist
  - id: recycler
    resource: ../../Detour/Browser/GPUProcessRecycler.swift
    title: GPUProcessRecycler.swift (environment overrides)
  - id: task-56
    resource: backlog:TASK-56
    title: Implement menuHasKeyEquivalent so key presses stop rebuilding the Spaces and Extensions menus
  - id: task-55
    resource: backlog:TASK-55
    title: Building the Extensions menu must not load extension popups
  - id: task-41
    resource: backlog:TASK-41
    title: Stop the test host writing the production app's UserDefaults and starting Sparkle
---

# Role

`Detour/App/` is three files: `main.swift` (entry point), `AppDelegate.swift`
(launch, windows, the whole menu bar) and `MenuKeyEquivalentMatcher.swift` (a
pure helper for menu shortcuts). There is no storyboard, no `@main`, and no
main menu nib.

# How it works

## Entry point

`main.swift` ignores `SIGPIPE` process-wide, then creates `NSApplication`,
installs an `AppDelegate` and runs. The signal matters: writing to a native
messaging host whose process has exited would otherwise terminate the app
with signal 13. With `SIG_IGN` the write returns `EPIPE` and the caller
handles it. See [native messaging](../extensions/native-messaging.md).

## Launch and termination

The launch order is listed on the [architecture overview](./overview.md).
The parts that belong to the shell:

- The first window is created and shown **before** `restoreSession()`; it is
  given its space and tab afterwards.
- `applicationShouldTerminate` asks "Quit Detour?" when any window is open.
- `applicationWillTerminate` clears the undo stack and calls
  `TabStore.saveNow()`.
- `applicationShouldTerminateAfterLastWindowClosed` is false; reopening the
  app with no visible window makes a new one.

## Windows

`AppDelegate.windowControllers` is the strong reference that keeps window
controllers alive; a `willCloseNotification` observer per window removes the
entry.

| Method | Makes |
|---|---|
| `createNewWindow()` | A normal window on the default space with nothing selected, then `newTab(nil)`, which opens the command palette in new-tab mode rather than creating a tab. |
| `createNewWindowWithURL(_:)` | A normal window with one tab on that URL. |
| `createNewWindow(showing:)` | A normal window on a given space with no tab added; the caller selects what it opened there. |
| `createNewIncognitoWindow()` | A [Private window](./incognito.md), also followed by `newTab(nil)`. |

`assignDefaultSpace(to:)` picks, in order: the key browser window's space
(unless that window is Private), `TabStore.lastActiveSpaceID`, the first
non-incognito space.

`application(_:open:)` accepts only `http` and `https` URLs and opens each in
the key window's active space, or in a new window when there is none. The app
declares itself a handler for those schemes and for HTML documents in
`Info.plist`.

`NSApplication.frontmostBrowserWindowController` (an extension at the bottom
of the file) returns the browser window the user is looking at even when
Settings is key. Use it for toasts and anything triggered from a non-browser
window.

## The menu bar

`setupMainMenu()` builds every menu in code. Items whose action is a
`BrowserWindowController` selector have a nil target, so they resolve through
the responder chain to the key window's controller, which validates them in
`validateMenuItem`.

| Menu | Contents | Dynamic? |
|---|---|---|
| App | About, Check for Updates… (only when Sparkle runs), Settings… | No |
| File | New Tab, Open Location…, Close Tab, Reopen Closed Tab, Pin/Unpin Tab, New Window, New Private Window | No |
| Edit | Undo/Redo (the **browser** undo manager), Cut/Copy/Copy URL/Paste, Find | No |
| View | Toggle Sidebar, Reload, zoom | No |
| Navigate | Back/Forward, Previous/Next Tab, Show All History, Archived Tabs | No |
| Spaces | Next/Previous Space, one item per space, Manage Spaces… | `menuNeedsUpdate` |
| Extensions | One submenu per enabled extension (Show Popup, Options…), then three static items | `menuNeedsUpdate` |
| Develop | Web Inspector, Load Unpacked Extension…, per-extension inspect and reload items | Rebuilt on a notification |
| Window | Minimize, Zoom | No |

Dynamic items are tagged (`spacesMenuTag`, `extensionMenuTag`,
`extensionInspectorTag`) so a rebuild removes exactly what it added.

Two rules for anything that builds an extension menu item:

- **Never read `action.popupWebView`.** It is created lazily, so reading it
  loads the extension's popup page. The decision goes through
  `ExtensionMenuPopupDecision`, which cannot see it (TASK-55).
- The menus autoenable, so a nil `action` is what disables an item.

See [popup and options UI](../extensions/popup-and-options-ui.md).

## Key equivalents without rebuilding menus

AppKit asks a menu's delegate about key equivalents on every Cmd+key press.
A delegate that does not implement
`menuHasKeyEquivalent(_:for:target:action:)` gets `menuNeedsUpdate` instead,
so the Spaces and Extensions menus were rebuilt on every keystroke:
re-enumerating spaces, re-querying each profile's enabled extensions and
redrawing icons (TASK-56).

`AppDelegate` implements the method with `MenuKeyEquivalentMatcher`, a pure
function over the menu's existing items. What the two answers mean was
checked against AppKit with standalone probes on macOS 26, not
assumed:[^task-56]

| Answer | AppKit then |
|---|---|
| `false` | Skips `menuNeedsUpdate` but still scans the menu's existing items itself, with its own keyboard-layout handling and validation. Not a veto. |
| `true` | Performs the returned action on the returned target with **no validation of its own**. |

So the matcher is a fast path that errs towards `false`, and the `true` path
re-implements AppKit's enable decision (`menuItemIsEnabled`:
`validateMenuItem`, else `validateUserInterfaceItem`, else `isEnabled`).
Without that, Next Space would fire with no browser window key.

Whether macOS 14 and 15 also fall back after a `false` is not
verified.[^task-56]

Invariants the tests pin against the real main menu:

- Only **Spaces** and **Extensions** have a delegate.
- Every shortcut in a delegate-driven menu is a static, layout-independent
  function key (the arrow keys `\u{F702}` / `\u{F703}`).
- **Dynamic items carry no key equivalent.** One would exist only after the
  menu was first opened, and a hit would be dispatched without an
  `NSMenuItem` sender.

The Develop menu has no delegate on purpose. Its dynamic items depend only on
the extension list, so they are rebuilt from
`ExtensionManager.extensionsDidChangeNotification`. That keeps its one letter
shortcut (Cmd+Option+I) matched natively by AppKit on every keyboard layout.

## Sparkle

`SPUStandardUpdaterController` is created with
`startingUpdater: AppDelegate.startsUpdater`, which is true only when the
process is not the XCTest host **and** runs in the default data directory.
Sparkle keeps its schedule in `SU*` keys of the bundle id's defaults domain,
which test and verification runs share with the production app; an updater
started there would schedule checks on the production app's behalf (TASK-41).

When the updater does not start, "Check for Updates…" is left out of the menu
entirely and one `notice` is logged at launch, so a run that never checks is
distinguishable from one that does.

The feed URL and the EdDSA public key are `SUFeedURL` and `SUPublicEDKey` in
`Info.plist`. Producing a release and its appcast is on
[release and website](../playbooks/release-and-website.md). Extension updates
are a separate mechanism: [updates](../extensions/updates.md).

## Launch switches

Everything that changes behaviour at launch, on `main`:

| Switch | Kind | Effect |
|---|---|---|
| `DETOUR_DATA_DIR` | Environment | Name of the data directory under Application Support (default `Detour`). Scopes the databases, WebKit storage identifiers, autosave names and content blocker storage, and stops Sparkle. See [persistence](./persistence.md). |
| Any variable starting `XCTest` | Environment (set by the test runner) | `AppDelegate.isRunningUnitTests`. Skips the pending profile data removal retry, the history sweep of deleted spaces, extension update checks and Sparkle. |
| `DETOUR_SLEEP_SHOW_BUDGET` | Environment, positive integer | Shows before a tab qualifies for the short sleep rule (default 50). |
| `DETOUR_SLEEP_SHOW_BUDGET_GRACE_SECONDS` | Environment, seconds | How long such a tab must be off screen (default 900). |
| `DETOUR_GPU_RECYCLE_SOFT_LIMIT`, `…_HARD_LIMIT` | Environment, positive integer | IOSurface counts (defaults 12,000 and 15,000). |
| `DETOUR_GPU_RECYCLE_INACTIVE_GRACE_SECONDS`, `…_USER_IDLE_SECONDS`, `…_MIN_INTERVAL_SECONDS`, `…_CHECK_SECONDS` | Environment, seconds | Recycle policy timings (defaults 300, 60, 3600, 120). |
| `DETOUR_NATIVE_MESSAGING_HOSTS_DIR` | Environment, **DEBUG builds only** | An extra native messaging manifest directory, searched first. |
| `ExtensionConsoleLogPublic` | `UserDefaults` bool | Logs bridged extension console text publicly. Off by default because that output can contain secrets. |

A non-positive or unparseable value for the numeric switches is ignored
rather than disabling the rule. The sleep and GPU switches exist for runtime
harnesses; see [sleeping and archiving](../tabs/sleeping-and-archiving.md),
[GPU IOSurface limit](../platform/gpu-iosurface-limit.md) and
[reading runtime logs](../playbooks/reading-runtime-logs.md).

There is no debug automation hook in `AppDelegate` on `main`. Runtime
harnesses are applied as patches; see
[debug harness](../playbooks/debug-harness.md).

# Gotchas

- Edit > Undo is `browserUndo`, not AppKit's `undo:`. The window controller
  retitles it from `TabStore.undoManager`, and it is the page's own text undo
  only while an editable field is focused.
- "Toggle Sidebar" is Cmd+S and "Pin/Unpin Tab" is Cmd+D; both displace
  shortcuts a web app might expect.
- The `extensionsDidChangeNotification` handler does not assume the main
  thread: it rebuilds the Develop menu directly on main and dispatches to
  main otherwise.
- After an install the Develop item's title uses the manifest name until the
  next `extensionsDidChange` post, because the WebKit extension object loads
  after that post.[^task-56]
- `inspectExtensionOffscreen` moves the offscreen document's web view into a
  visible window so the Web Inspector can attach, then calls a private
  `_inspector` selector.

# Tests

`MenuKeyEquivalentMatcherTests` (including the tests against the real
`NSApp.mainMenu`), `ExtensionMenuPopupDecisionTests`,
`ExtensionOptionsPageEntryTests`, `ProductionDefaultsIsolationTests`,
`UserDefaultsScopeTests`.

# Related

- [Architecture overview](./overview.md) — the launch sequence in context.
- [BrowserWindowController](./browser-window-controller.md) — the target of most menu actions.
- [Profile data removal](./profile-data-removal.md) — why the test host skips parts of launch.
- [AppKit gotchas](../platform/appkit-gotchas.md) — more AppKit behaviour found the hard way.
- [Build and test](../playbooks/build-and-test.md) — how the environment switches reach a test run.

[^task-56]: Implement menuHasKeyEquivalent so key presses stop rebuilding the Spaces and Extensions menus
