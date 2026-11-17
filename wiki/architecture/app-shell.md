---
type: Component
title: App shell
description: "AppDelegate and main.swift — launch and termination, window creation, the menu bar built in code (with a pointer to the key-equivalent fast path), Sparkle, and every launch-time environment switch."
resource: ../../Detour/App/AppDelegate.swift
tags: [architecture, app, menus, sparkle, startup]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T10:05:16Z }
sources:
  - id: task-320
    resource: backlog:TASK-320
    title: "Command palette: browser commands (a shared command registry, also for AppleScript, Shortcuts and MCP)"
  - id: registry
    resource: ../../Detour/Commands/BrowserCommands.swift
    title: BrowserCommands.swift
  - id: dispatch
    resource: ../../Detour/Commands/CommandDispatch.swift
    title: CommandDispatch.swift
  - id: task-292-10
    resource: backlog:TASK-292.10
    title: "Help menu: open the Detour guide, keyboard shortcuts, Switching from Arc, release notes and issue reporting"
  - id: task-334
    resource: backlog:TASK-334
    title: "Menus: give the top-level menu items titles so App Shortcuts written as a menu path apply"
  - id: task-309
    resource: backlog:TASK-309
    title: "Dock menu: Show / Hide All Quick Detour Windows"
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
  - id: task-295
    resource: backlog:TASK-295
    title: "Spaces: keyboard shortcuts that jump straight to a space by its position (first through ninth)"
  - id: task-41
    resource: backlog:TASK-41
    title: Stop the test host writing the production app's UserDefaults and starting Sparkle
---

# Role

`Detour/App/` is five files: `main.swift` (entry point), `AppDelegate.swift`
(launch, windows, the whole menu bar), `MenuKeyEquivalentMatcher.swift` (a
pure helper for menu shortcuts), `HelpMenu.swift` (the Help menu's links)
and `BuildInfo.swift`. There is no storyboard, no `@main`, and no
main menu nib.

# How it works

## Entry point

`main.swift` ignores `SIGPIPE` process-wide, then creates `NSApplication`,
installs an `AppDelegate` and runs. The signal matters: writing to a native
messaging host whose process has exited would otherwise terminate the app
with signal 13. With `SIG_IGN` the write returns `EPIPE` and the caller
handles it. See [writing to a native host](../extensions/native-host-writing.md).

## Launch and termination

The launch order is listed on the [architecture overview](./overview.md).
The parts that belong to the shell:

- The first window is created and shown **before** `restoreSession()`; it is
  given its space and tab afterwards.
- `applicationShouldTerminate` asks "Quit Detour?" when any window is open.
  When Private windows have downloads still running the alert says how many
  will be cancelled, and Quit cancels them before terminating (see
  [downloads](../features/downloads.md)).
- `applicationWillTerminate` clears the undo stack, calls
  `TabStore.saveNow()` and then `DownloadManager.flushPendingSave()`, which
  writes a download state change still inside its save debounce.
- `applicationShouldTerminateAfterLastWindowClosed` is false; reopening the
  app with no visible window makes a new one.

## Windows

`AppDelegate.windowControllers` is the strong reference that keeps window
controllers alive; a `willCloseNotification` observer per window removes the
entry.

| Method | Makes |
|---|---|
| `createNewWindow()` | A normal window on the default space with nothing selected, then `newTab(nil)`, which opens the command palette in new-tab mode rather than creating a tab. |
| `createNewWindowWithURL(_:incognito:)` | A window with one tab on that URL; a Private one when `incognito` is true (a link routed to Private). |
| `createNewWindow(showing:)` | A normal window on a given space with no tab added; the caller selects what it opened there. |
| `createNewIncognitoWindow()` | A [Private window](./incognito.md), also followed by `newTab(nil)`. |

`assignDefaultSpace(to:)` picks, in order: the key browser window's space
(unless that window is Private), `TabStore.lastActiveSpaceID`, the first
non-incognito space. An extension's `windows.create` does not use it: its
window opens on the caller's profile's own space
([opening a window](../extensions/opening-tabs-and-windows.md#opening-a-window)).

Links from other apps arrive through `handleGetURLEvent` (the Get URL Apple
event, installed in `applicationWillFinishLaunching`, TASK-304) and
documents through `application(_:open:)`. Both call `openExternalURLs`,
which keeps only `http` and `https` URLs and routes each through
`resolveExternalLinkRoute` and `openLink` ([Link Routes](../features/link-routing-external-links.md):
a space, Quick Detour, quarantine or a new window). Links that arrive during
launch wait in `linksAwaitingLaunch` until the session is restored. The app
declares itself a handler for those schemes and for HTML documents in
`Info.plist`.

`NSApplication.frontmostBrowserWindowController` (an extension at the bottom
of the file) returns the browser window the user is looking at even when
Settings is key. Use it for toasts and anything triggered from a non-browser
window.

Not every window is a browser window: a [Quick Detour](../features/quick-detour.md)
window is a `QuickDetourWindowController`, kept alive by its own
`QuickDetourWindowController.openControllers` rather than
`windowControllers`, and not counted by the quit confirmation. Code that
casts the key window's controller to `BrowserWindowController` gets nil while
one is key; the menu actions it implements (Close Tab, Open Location…, Copy
URL, Reload, zoom, Back/Forward, Find, Web Inspector) reach it through the
responder chain and the rest are disabled.

## The menu bar

`setupMainMenu()` builds every menu in code, and since TASK-320 every item
is a view of a command of the [command registry](../features/browser-commands.md)
(`BrowserCommands`): `add(_:to:)` builds the item from the command (title,
key equivalent, action, tag, and the command's ID as the item's
`identifier`) and sets the target its responder calls for. The layout
(order, separators, which menus have a delegate) stays in `setupMainMenu`.
Items whose action is a window controller's have a nil target, so they
resolve through the responder chain to the key window's controller, whose
`validateMenuItem` answers the registry's rule for the command
(`BrowserCommands.validate`). Before the registry each controller answered
item by item; `MainMenuCharacterizationTests` pinned every item's title, key
equivalent, action, target, tag and enablement before the move and still
pass unchanged.

Each menu-bar item is titled as its menu (`AppDelegate.menuBarItem(for:)`,
the application menu and its item by the app's name), not left as
`NSMenuItem()`: AppKit matches a menu-path App Shortcut ("File->Close Tab")
against the parent items' titles, so on untitled items those never applied
(TASK-334[^task-334], [keyboard shortcuts](../features/keyboard-shortcuts.md#macos-app-shortcuts)).
The bar looks the same: it shows the submenu's title either way.

| Menu | Contents | Dynamic? |
|---|---|---|
| App | About, Check for Updates… (only when Sparkle runs), Settings…, Hide, Hide Others, Show All, Quit | No |
| File | New Tab, Open Location…, Open in Space (`openInSpace`, Cmd+O), Import from Arc…, Close Tab, Reopen Closed Tab, Pin/Unpin Tab, New Window, New Private Window, New Quick Detour Window (`newQuickDetourWindow`, which shows the Quick Detour launcher panel; its key equivalent is the global hotkey's shortcut, Opt-Cmd-N by default, set by `QuickDetourHotKey`, and pressing it while the panel is up closes it) | No |
| Edit | Undo/Redo (the **browser** undo manager, [browser undo](./browser-undo.md)), Cut/Copy/Copy URL/Paste, Select All, Find, Find Next, Find Previous | No |
| View | Toggle Sidebar, Reload, zoom | No |
| Navigate | Back/Forward, Previous/Next Tab, Show All History, Archived Tabs, Clear Archived Tabs | No |
| Spaces | Next/Previous Space, the first nine spaces (static items on ⌃1–⌃9, titled and hidden on open, TASK-295; see [browser commands](../features/browser-commands.md#spaces-by-position-task-295)), one item per later space, Manage Spaces… | `menuNeedsUpdate` |
| Extensions | One submenu per enabled extension (Show Popup, Options…), then three static items | `menuNeedsUpdate` |
| Develop | Web Inspector, Load Unpacked Extension…, per-extension inspect and reload items | Rebuilt on a notification |
| Window | Minimize, Zoom | No |
| Help | Detour Help, Keyboard Shortcuts, Switching from Arc, Release Notes, Report an Issue (TASK-292.10) | No |

Dynamic items are tagged (`spacesMenuTag`, `extensionMenuTag`,
`extensionInspectorTag`) so a rebuild removes exactly what it added. They
are still built by their own builders, with the actions of the registry's
parameterised commands (`space.switch`, `extension.show-popup`,
`extension.options`, `extension.inspect-offscreen`,
`extension.reload-unpacked`) and no identifier. Which extensions the
Extensions menu lists and which of their items are live is
`ExtensionMenuItems`, which the command palette's chip shares (TASK-320
AC #3). The Dock menu's two items are not built from the registry.

The **Help menu** is last and is registered as `NSApp.helpMenu`, which is
what makes macOS add its menu search field (Shift-Cmd-/). It is built in
[HelpMenu.swift](../../Detour/App/HelpMenu.swift) (`makeHelpMenuItem`); its
pages are defined once in `HelpLinks`: https://detourbrowser.com/features/,
/shortcuts/ and /arc/, and the GitHub project's
(https://github.com/tienshiao/detour, the repo scripts/publish-release.sh
publishes to) /releases and /issues/new. A page opens as a selected tab in
the active space of the frontmost normal browser window
(`NSApp.browserWindowControllersFrontToBack`, Private windows passed over;
Quick Detour and quarantine windows are not browser windows), or in a new
window (`createNewWindowWithURL`) when there is none; the choice is the pure
`HelpLinks.placement(windows:)`.
Settings' Learn more links (TASK-292.11) open the website's feature guides
(`GuidePage`, URLs under `HelpLinks.detourHelp`) through the same
`openHelpPage`; see
[Settings](../features/settings-learn-more-links.md).

The **Dock menu** (`applicationDockMenu`, built fresh each time macOS asks):
New Window, New Private Window, then, while any Quick Detour is open and not
all are minimized, one item flipping between Hide All and Show All Quick
Detour Windows (TASK-309, `addQuickDetourDockMenuItem`; see
[Quick Detour](../features/quick-detour-dock-menu.md)).

Two rules for anything that builds an extension menu item:

- **Never read `action.popupWebView`.** It is created lazily, so reading it
  loads the extension's popup page. The decision goes through
  `ExtensionMenuPopupDecision`, which cannot see it (TASK-55).
- The menus autoenable, so a nil `action` is what disables an item.

See [popup and options UI](../extensions/popup-and-options-ui.md).

## Key equivalents without rebuilding menus

The Spaces and Extensions menus answer key equivalents through
`AppDelegate.menuHasKeyEquivalent` and `MenuKeyEquivalentMatcher` instead of
being rebuilt on every keystroke (TASK-56); how, and what AppKit does with
the answers, is on
[keyboard shortcuts](../features/keyboard-shortcuts.md#key-equivalents-without-rebuilding-menus).

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
| Any variable starting `XCTest` | Environment (set by the test runner) | `AppDelegate.isRunningUnitTests`. Skips the pending profile data removal retry, the history sweep of deleted spaces, extension update checks, Sparkle, the leftover extension notification removal, `QuickDetourIdleMonitor`, the global hotkey, the automation endpoint and the Arc import offer. |
| `DETOUR_MCP`, `DETOUR_MCP_PORT` | Environment | Start the [automation endpoint](../features/automation-endpoint.md) for a test run (`AutomationGate`; `DETOUR_MCP=1` needs an isolated `DETOUR_DATA_DIR`). |
| `DETOUR_GLOBAL_HOTKEY` | Environment, Debug builds | Registers the Quick Detour global hotkey in a Debug build (`QuickDetourHotKey`). |
| `DETOUR_QUICK_DETOUR_IDLE_SECONDS` | Environment, **DEBUG builds only** | `QuickDetourIdleMonitor`'s idle time. |
| `DETOUR_TRACKING_FILTER_URL` | Environment, **DEBUG builds only** | `TrackingParameterList.listURL`. |
| `DETOUR_GPU_ORPHAN_CHECK_SECONDS`, `DETOUR_GPU_ORPHAN_MIN_AGE_SECONDS` | Environment, seconds | `GPUProcessOrphanReaper` timings (check default 30). |
| `DETOUR_SLEEP_SHOW_BUDGET` | Environment, positive integer | Shows before a tab qualifies for the short sleep rule (default 50). |
| `DETOUR_SLEEP_SHOW_BUDGET_GRACE_SECONDS` | Environment, seconds | How long such a tab must be off screen (default 900). |
| `DETOUR_GPU_RECYCLE_SOFT_LIMIT`, `…_HARD_LIMIT`, `…_EXHAUSTED_LIMIT` | Environment, positive integer | IOSurface counts (defaults 12,000, 14,000 and 16,384). |
| `DETOUR_GPU_RECYCLE_INACTIVE_GRACE_SECONDS`, `…_USER_IDLE_SECONDS`, `…_MIN_INTERVAL_SECONDS`, `…_CHECK_SECONDS` | Environment, seconds | Recycle policy timings (defaults 300, 60, 3600, 120). |
| `DETOUR_NATIVE_MESSAGING_HOSTS_DIR` | Environment, **DEBUG builds only** | An extra native messaging manifest directory, searched first. |
| `ExtensionConsoleLogPublic` | `UserDefaults` bool | Logs bridged extension console text publicly. Off by default because that output can contain secrets. |

An unparseable value for the numeric switches is ignored rather than
disabling the rule; the count and check-interval switches also ignore
non-positive values, the grace and interval seconds only negative ones. The sleep and GPU switches exist for runtime
harnesses; see [sleeping and archiving](../tabs/sleeping-and-archiving.md),
[GPU IOSurface limit](../platform/gpu-iosurface-limit.md) and
[reading runtime logs](../playbooks/reading-runtime-logs.md).

The MCP [automation endpoint](../features/automation-endpoint.md)
(`AutomationController`, enabled by the user's setting or by `DETOUR_MCP=1`
with an isolated data directory) starts at the end of launch; ad-hoc runtime
harnesses are still applied as patches; see
[debug harness](../playbooks/debug-harness.md).

# Gotchas

- Edit > Undo is `browserUndo`, not AppKit's `undo:`. The window controller
  retitles it from `TabStore.undoManager`, or from the focused page's own
  undo manager while an editable element in that page has focus, and runs
  that one (TASK-345, [A page's key equivalents and its undo](../platform/page-key-equivalents-and-undo.md)).
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
`NSApp.mainMenu`), `MainMenuCharacterizationTests` (the menu's items and
their enablement in every kind of window, and the registry's rule agreeing
with them), `BrowserCommandRegistryTests`, `ExtensionMenuPopupDecisionTests`,
`ExtensionOptionsPageEntryTests`, `ProductionDefaultsIsolationTests`,
`UserDefaultsScopeTests`.

# Related

- [Architecture overview](./overview.md) — the launch sequence in context.
- [BrowserWindowController](./browser-window-controller.md) — the target of most menu actions.
- [Profile data removal](./profile-data-removal.md) — why the test host skips parts of launch.
- [AppKit gotchas](../platform/appkit-gotchas.md) — more AppKit behaviour found the hard way.
- [Build and test](../playbooks/build-and-test.md) — how the environment switches reach a test run.

[^task-56]: Implement menuHasKeyEquivalent so key presses stop rebuilding the Spaces and Extensions menus
[^task-334]: TASK-334
