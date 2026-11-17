---
type: Reference
title: "Automation endpoint: the tools"
description: Every tool the automation endpoint offers (windows, spaces and tabs, menu commands, input, screenshots, page tools, extension tools, capture staging, Debug-only tools) with its arguments, gates and notes, the context argument, and the traps met with run_menu_item and the schemas (menu-bar titles, a shared item retitled per window, submenu actions, animated commands, modal actions and the main queue).
tags: [automation, mcp]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T19:10:00Z }
sources:
  - id: automation-dir
    resource: ../../Detour/Automation
    title: Detour/Automation (gate, credentials, HTTP, authorisation, MCP server, tools, endpoint)
  - id: task-228-1
    resource: backlog:TASK-228.1
    title: "Automation: an MCP endpoint in Detour, first slice for testing"
  - id: task-228-7
    resource: backlog:TASK-228.7
    title: "Automation: run_menu_item and right clicks match what the user sees (live titles, row labels), and Quick Detour windows and Settings can be addressed"
  - id: tests
    resource: ../../DetourTests/MCPServerTests.swift
    title: MCPServerTests, AutomationHTTPTests, AutomationToolsTests, AutomationEndpointTests
---

The tools of the [automation endpoint](./automation-endpoint.md), each with
a flat input schema, an output schema and the stable error codes described
on the hub.[^automation-dir] Gates: "test runs only" means `DETOUR_MCP=1`
with an isolated data directory ([turning it
on](./automation-endpoint-access.md)); "Debug" means absent from a Release
build.

# Windows, spaces, tabs and commands

| Tool | Does | Notes |
|---|---|---|
| `list_windows` | Windows with `window_id`, `kind` (`browser`, `quick_detour`, `quarantine`, `settings`), `window_number` (the CGWindowID), frame (AppKit's), `screen_bounds` (the window server's, top-left points) and `display_id`, key/main, `is_private`, active space, selected tab (a Quick Detour's page: its url and title, no tab id) | `window_id` is a small stable number per window, one counter for every kind. Private windows are left out unless allowed (`hidden_private_windows`). See [window kinds](./automation-endpoint-windows.md). |
| `list_spaces` | Spaces with profile, counts, the windows showing each | |
| `list_tabs` | A space's favourites, pinned entries (live or dormant) and tabs, in sidebar order, plus its pinned folders | `id` is what `select_tab` takes; `tab_id` and `context` are null for a dormant item. |
| `select_tab` | Selects an item as a row click does | The item is `id` (an item id or `tab_id` from `list_tabs`); an argument named `tab_id` is refused as unknown (`invalid_arguments`), as any misspelt one is (TASK-364). Selects in the window it names, key or not. Switches the window's space first; wakes a dormant pinned entry or favourite; `dormant_refused` when its extension keeps it dormant. |
| `open_url` | The palette's typed-URL path (`openTypedURL`): a new tab, or `in_place` | Link Routes apply as for a typed URL; `routed` says the URL went elsewhere. Never opens a quarantine (see [Private windows](./automation-endpoint-private-windows.md#open_url-and-quarantines)). |
| `run_menu_item` | A main-menu command by path or key equivalent, sent to that window's responder chain and validated there; any kind of window | Works with Detour in the background, where there is no key window. Each menu on a path is validated for the named window before it is matched (TASK-228.7), so a title that changes with the window is the one it shows there ("File > Unpin Tab" while that window's tab is pinned, whichever window validated the shared item last). See Traps. |

# Input and menus

How each is delivered: [how input is delivered](./automation-endpoint-input.md).

| Tool | Does | Notes |
|---|---|---|
| `click` | A click by element (`context` + CSS `selector`), by page point (`context` + CSS-pixel `x`, `y`) or by window point (`window_id` of any kind + `x`, `y`, the content's top-left origin); `button` left/right, `modifiers`, `count` 2 for a double click | Closes an open menu first. `completed` false: the click opened a menu or an alert that is still open. A right click on a sidebar row's label or icon opens the row's menu (TASK-228.7). A switch toggles and a pop-up opens (TASK-228.8): aim at the centre of the frame `hit_test` gives. A left click on a sidebar row selects it; at a window point it hovers the views under the point first, so a row's close button (shown on hover only, at the row's right end) closes the tab (TASK-228.9). With Detour active a click in a window that is not key makes it key first; in the background never (TASK-228.10). The [agent pointer](./automation-endpoint-agent-pointer.md), when on, glides there first. |
| `type_text` | Key presses for `text` into a tab's page (after clicking `selector`, if given) or a window's focused control; `interval_ms` paces them | US key codes; other characters as key presses with no physical key. |
| `press_key` | One key with modifiers (`return`, `shift+tab`, `cmd+a`) | A Cmd key goes through the target's key equivalents, then the window's main menu (`handled`; a page takes every key at once). A key a page does not take goes to the main menu of the window it was pressed in, even with another window key (TASK-364, see [input](./automation-endpoint-input.md)); menu commands are still `run_menu_item`. |
| `hit_test` | What a click at a window point would reach: view class, accessibility role and label, frame; any kind of window, Settings on any endpoint | Read-only; aims `click` without a screenshot. Hit-tests as AppKit's dispatch does, with the press as the current event: a sidebar row's label reports `DraggableTableView`. |
| `list_menu` | The open menu's items (index, title, enabled, checked, submenu, identifier); waits `timeout_ms` for one to open; `path` for a submenu | A page's context menu shows WebKit's `WKMenuItemIdentifier…` identifiers. |
| `choose_menu_item` | Chooses an item by title, index or identifier, then closes the menu | WebKit's own items run for real (Download Linked File downloaded at runtime). With the agent pointer on it waits its turn in the [input order](./automation-endpoint-agent-pointer.md) (TASK-228.13); `timeout_ms` counts from then. |
| `close_menu` | Closes the open menu without choosing | Waits its turn in the input order with the agent pointer on, as `choose_menu_item` does. |

# Screenshots and appearance

See [screenshots](./automation-endpoint-screenshots.md).

| Tool | Does | Notes |
|---|---|---|
| `screenshot` | A PNG of a window's content (any kind, Settings on any endpoint), a browser window's sidebar (`part`; another kind is `unsupported_window`) or a tab's page (`context`), as image content and/or written to `save_to` (an existing file only with `overwrite`); `scale` 1 or 2, never above the display's | `source` app (default): drawn inside Detour, no grant, works in the background, no shadow, but no glass. `source` screen: the window server's picture through ScreenCaptureKit, exact; needs Screen Recording (never prompted), else `permission_denied`. Neither shows the agent pointer. |
| `set_appearance` | Light, dark, or following the system, for all of Detour (`NSApp.appearance`) | Until quit or the next call. |
| `set_debug_override` | Debug builds only: `reduce_motion` (this process, via `MotionPreference`), `space_toss_hop` and `space_toss_gravity` (the data directory's defaults keys `SpaceCelebration` already read in Debug), `automation_indicator` (off hides the connected-agent capsule for a capture, TASK-228.3; test runs only, `gate_closed` on the user's own endpoint), `agent_pointer` (on or off whatever the setting says, TASK-228.11; test runs only, as the indicator's); `default` clears | Absent from Release (checked on a Release build: its tool list and its binary's strings). |

# Page tools

See [page tools and capture](./automation-endpoint-page-tools.md).

| Tool | Does | Notes |
|---|---|---|
| `evaluate_js` | Runs `expression` or `script` (a function body with `return`) in a tab's main frame, `world` page (default) or isolated (`WKContentWorld` "DetourAutomation": the DOM, not the page's globals); awaits promises | Result as JSON with its `type`; what JSON cannot hold is converted in the page (nodes `<div#id.class>`, cycles `[Circular]`, functions, undefined null). A throw is `script_error` with `error.details` {name, message, stack}; a syntax error too (from WebKit's exception). `timeout_ms` (default 10 s) gives `timeout`; the script runs on. Results over 1 MB are cut (`truncated`). |
| `read_page` | url, title, ready_state, viewport, and by `mode`: `text` (default, `innerText`), `html` (`outerHTML`), `elements`, `summary` | `selector` narrows; `max_length` cuts text and html, `max_elements` the list, with `truncated`. Elements: tag, role (explicit or implicit), name (aria-labelledby, aria-label, label, text, alt, title, placeholder), a selector unique in the document (`#id`, then `tag[data-testid|name|aria-label=…]`, then an `nth-of-type` path), rect in CSS pixels, visible (`checkVisibility`), in_viewport, disabled. Runs in the isolated world. The argument is `mode`, not `format` (see Traps). |
| `console_messages` | A tab's console calls, uncaught errors and unhandled rejections, all frames, after `after_seq`, filtered by `levels` | `stable: true` leaves out `seq` and `timestamp` and names extension origins by extension id. Also reads extension contexts. |
| `network_requests` | A tab's navigation and resource loads (Resource Timing) and its fetch and XHR calls, after `after_seq`, by `sources`, `failed_only` | See the page for the limits. |
| `wait_for` | Polls every 100 ms until `load` (not loading and readyState complete), `selector` (with `visible`), `expression` truthy (a throw counts as false; the last one is in the timeout's message) or `url` (a plain substring) | `timeout` after `timeout_ms` (default 10 s). Exactly one condition. |
| `wake_tab` | Loads a sleeping tab's page (`BrowserTab.wake()`) without selecting it | `woken` false when it was awake. |

# Extension tools

See [extension contexts](./automation-endpoint-extensions.md) and [the
compatibility report](./automation-endpoint-compat-report.md).

| Tool | Does | Notes |
|---|---|---|
| `list_extensions` | Installed extensions sorted by id (or one, by id or name): version, source, global switch, `loaded`/`load_failed`, per normal profile `turned_on`, `loaded`, `worker_parked`, `open_contexts`, `context_errors`; the manifest's permission lists, the saved decisions, WebKit's manifest warnings and every load error recorded this session | Reads whenever the endpoint is on. Load errors come from `ExtensionErrorLog`. `stable: true` is the diffable form. |
| `install_extension` | Test runs only. An unpacked folder or a `.crx`, turned on in `profile_id` (default: the only normal profile); waits for it to load | No prompt. A CRX goes through `CRXInstallGate` with a file URL (its developer signature), may replace an installed id, and never updates. A keyless folder installed again keeps its id. `install_failed` for no or a bad manifest or a refused CRX. |
| `uninstall_extension` | Test runs only. Settings' Uninstall, every profile, no prompt | Closes the endpoint's popups of it first. |
| `set_extension_enabled` | Test runs only. One normal profile's switch (`profile_id`) or the global one | The Private profile is `private_unreachable`. |
| `set_extension_permission` | Test runs only. Saves a grant or denial and applies it to every profile's context (`setPermissionDecision`): an API permission, a match pattern, or a URL with `type` url | `warnings` names a decision with no effect: a host outside the manifest's host patterns stays inert, an undeclared API permission is not restored next launch, `nativeMessaging` gates real hosts only. |
| `open_extension_context` | `kind` popup (in a window, at its button, with a click's user gesture), options (a tab, in the background or selected in `window_id`), worker (start it and wait for it to answer) | Returns the `context` string. `sidepanel` is `unsupported_context` on this build. |
| `close_extension_context` | Closes the endpoint's popup, or the options page's tab | `context_not_open` when it is not open. |
| `call_extension_api` | Calls the function at a dotted path (`chrome.storage.local.get`) with `args` (a JSON array as a string), awaits it, returns the result as `evaluate_js` does | In `worker:` through the channel; in a popup, options page or tab through `callAsyncJavaScript`. A missing member is a `TypeError` (`script_error`). |
| `read_extension_global` | Reads the value at a dotted path (`self.cache.size`) | How a worker's own globals are read. |
| `extension_compat_report` | What an extension uses that Detour lacks: its `chrome.*`/`browser.*` references checked in the worker and a page, the stubs it references or called, API-naming TypeErrors, unsupported manifest keys and permissions, worker failures | Whenever the endpoint is on (not gated: it installs nothing). `probe: false` skips the runtime checks. |

# Capture staging and Debug tools

See [capture staging](./automation-endpoint-staging.md).

| Tool | Does | Notes |
|---|---|---|
| `seed_world` | Test runs only. Builds a world from a fixture file into an empty data directory: profiles, favourites, spaces, pinned entries in nested folders, splits, tabs, history visits, Link Routes, the active space | `invalid_fixture` (with `details.path`), `not_empty` (with what is there). |
| `list_displays` | Displays with `display_id` (CGDirectDisplayID), `frame` and `visible_frame` in global top-left points, `scale`, `main`, `name`, pixel size | Virtual displays included. Read-only, whenever the endpoint is on. |
| `set_window_frame` | Test runs only. Moves and sizes a window from `list_windows` (`window_id`, any kind, TASK-228.7) or another Detour window (`window_number`: the Arc import window) in top-left points, global or relative to `display_id`; `activate` brings Detour to the front with the window key | Returns `frame`, `screen_bounds` (the window server's), `settled`, `is_key`, `app_active`, `window_number`. `unknown_window`, `unknown_display`; a sheet, the approval panel, and a Private window unless allowed, are refused. |
| `open_ui` | Debug builds and test runs only. `space_editor` (a draft: name, emoji, color, profile_id; new or `space_id`), `arc_offer` and `arc_import` (from `arc_folder`, a fake Arc folder in the data directory or a temporary folder: never in or under Arc's own, in any case spelling, and with no symbolic or hard links inside, which the reader would follow to Arc's files), `settings` (`pane`, `row`) | Returns the window the UI is in (`window_number`, `frame`, `screen_bounds`). Absent from Release (its tool list was checked on a Release test run). |
| `navigation_swipe` | Debug builds and test runs only (TASK-325). `state` reports each hosted pane's back-swipe mode, WebKit's gesture flag, rubber-band edges, history and opener; `begin` starts a swipe on a pane (`context`, `direction`, `progress`) with a scripted tracker and holds the veneer; `finish` completes it or springs it back through the trackpad swipe's completion code | Synthetic events cannot drive `NSEvent.trackSwipeEvent`; see [Back swipe to the opener](../tabs/back-swipe-to-opener.md). |

# GPU process tools

Always available while the endpoint is on (TASK-405).

| Tool | What it does | Notes |
|---|---|---|
| `gpu_process_stats` | WebKit's GPU process: `gpu_pid`, `total` IOSurface regions and `non_resident` ones (as the recycler counts them); `live_web_views`, `tab_processes`, `tab_process_footprint_mb`; `process_pools`, one per WebKit process pool with its `tab_web_views`, `web_processes` (processes holding a back/forward page included), `cached_processes`, `uses_web_process_cache`, `prewarms_processes_automatically`; `detail: true` adds `tabs` (`tab_id`, `host`, `web_process`, `pool`, `asleep`; Private tabs only with Private access) | Read-only. The region walk runs off the main thread. Pool data comes from WebKit SPI (`_allProcessPoolsForTesting`, `_webProcessCountIgnoringPrewarmedAndCached`, `_processCacheSize`); a missing selector gives null. |
| `trim_back_forward_cache` | Clears WebKit's back/forward cache of one tab (`context`) or of every live tab no window hosts (Private ones only with Private access), keeping history; returns the `trimmed` tab ids | `BrowserTab.clearBackForwardCache()`, the call TASK-408's timer uses. |

The experiment that uses both is `docs/harness/task405-gpu-experiment.py`;
its results are on [GPU process IOSurface limit](../platform/gpu-iosurface-limit.md).

# The `context` argument

Tools that act on page content take a `context`: a tab (`tab:<uuid>`, or a
bare tab id) of a non-Private space (or of a Private one while allowed),
normal or pinned, or a live favorite; or an extension context
(`popup:<ext>`, `options:<ext>`, `worker:<ext>`, `extension:<ext>`), which
goes in the same argument (`resolvePageTarget`). The page tools take a tab
whether or not a window shows it; the input tools need a window
(`not_displayed`); a sleeping tab is `tab_asleep` in both. Details: [page
tools](./automation-endpoint-page-tools.md#which-tabs) and [extension
contexts](./automation-endpoint-extensions.md#addressing).

# Traps

- **Menu-bar titles.** A menu-bar item's own title is AppKit's placeholder
  `NSMenuItem`; the bar shows its submenu's title, and the application menu's
  submenu has none (it is the app's name). Paths match on those.[^task-228-1]
- **A shared item's title is whichever window validated it last.**
  Pin/Unpin Tab is one File-menu item that `validateMenuItem` retitles for
  the window it is asked for. Matched without validating, "File > Unpin
  Tab" was refused while the item still read "Pin Tab" from another
  window's validation (TASK-320). `run_menu_item` now validates each
  level's items for the named window before matching.[^task-228-7] It does
  not use `NSMenu.update()`, which asks the key window's chain: with Detour
  in the background there may be no key window, or a different one.
- **An item with a submenu has an action.** AppKit gives it
  `submenuAction:`, which only its menu's own tracking may send; sending it
  raised `-[NSMenu submenuAction:]: unrecognized selector`. Such items are
  refused before their action is looked at.
- **Commands can finish later than they return.** Next Space animates the
  sidebar to the space and switches the window when the animation ends, so a
  script polls the state after `run_menu_item` rather than reading it at
  once.
- **A modal action and the main queue.** A command that runs a modal alert
  (Quit's confirmation) does not return until the alert closes. Sent from a
  main-queue block (`DispatchQueue.main.async`, or a main-actor job, which is
  one), it froze the whole endpoint: GCD does not drain the main queue inside
  one of its own blocks, so neither the wait's timer nor any other main-actor
  job ran. The command is sent from `RunLoop.main.perform` instead. The
  modal's nested run loop then drains the main queue, and `run_menu_item`
  answers `completed: false` after 1.5 s while other calls keep working. This
  was checked in the running app with Cmd+Q. The input tools send every
  event the same way.
- **A property named `format`** trips `MCPServerTests`' flat-schema walk,
  which refuses JSON Schema keywords anywhere, property names included; most
  validators would accept it, but `read_page` calls it `mode`.

# Tests

`AutomationToolsTests` (the tools against real windows on
`TabStore.shared`, including a Private window, a dormant pinned entry,
another space, validation through the window, Pin Tab and Unpin Tab matched
by the named window's title with neither window key, a slow command, and
`open_url` never opening a quarantine through a Link Route, with Private
allowed or not); every suite in [the endpoint's
tests](./automation-endpoint-tests.md).[^tests] `AutomationGPUToolsTests` covers the two GPU process tools.

# Related

- [Automation endpoint (MCP)](./automation-endpoint.md): the hub, with the
  layers and error codes.
- [Browser commands](./browser-commands.md): what `run_menu_item` runs.
- [Link Routes](./link-routing.md): what `open_url` applies to a new tab.

[^automation-dir]: Detour/Automation (gate, credentials, HTTP, authorisation, MCP server, tools, endpoint)
[^task-228-1]: Automation: an MCP endpoint in Detour, first slice for testing
[^task-228-7]: Automation: run_menu_item and right clicks match what the user sees (live titles, row labels), and Quick Detour windows and Settings can be addressed
[^tests]: MCPServerTests, AutomationHTTPTests, AutomationToolsTests, AutomationEndpointTests, and the other Automation suites
