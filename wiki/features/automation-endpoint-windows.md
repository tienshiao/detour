---
type: Feature
title: "Automation endpoint: window kinds"
description: The four kinds of window a window_id of the automation endpoint names (browser, Quick Detour, quarantine, Settings), which tools reach which, why Settings takes input only in test runs and never in its Automation section, how menus and child windows inherit a window's reach, and the old harness workarounds this replaces.
tags: [automation, mcp, security]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:12Z }
sources:
  - id: task-228-7
    resource: backlog:TASK-228.7
    title: "Automation: run_menu_item and right clicks match what the user sees (live titles, row labels), and Quick Detour windows and Settings can be addressed"
  - id: windows
    resource: ../../Detour/Automation/AutomationWindows.swift
    title: AutomationWindows.swift (window kinds, who reaches which, Settings' Automation section)
  - id: tests
    resource: ../../DetourTests/MCPServerTests.swift
    title: MCPServerTests, AutomationHTTPTests, AutomationToolsTests, AutomationEndpointTests
---

Since TASK-228.7, the [automation endpoint](./automation-endpoint.md)'s
`window_id` names four kinds of window, all listed by `list_windows` with
their `kind`: browser windows, Quick Detour windows, quarantine windows (a
Quick Detour with a throwaway store) and Settings (while it is
open).[^task-228-7] No other window is addressable: the approval prompt,
sheets, alerts and popovers stay out of reach.

# Where it lives

`AutomationWindows` holds the classification.[^windows] It is the one place
that decides which windows are Private, so listing, refusal by id, menus
over a window, the Window menu's entries and `set_window_frame`'s
`window_number` all agree. Before, only `BrowserWindowController.isIncognito`
was asked, so a person's context menu in a Private Quick Detour was
listable.

`AutomationEnvironment.otherWindows` supplies the windows other than
browser windows. Live, it is `QuickDetourWindowController.openControllers`
plus a visible Settings window found in `NSApp.windows`. Asking
`SettingsWindowController.shared` would build Settings and all its panes.

`window_id` is a small stable number per window, one counter for every
kind, not `windowNumber`, which is only assigned once a window is on
screen. Settings keeps its id when closed and reopened.

# Who reaches which

| Kind | `run_menu_item`, `click`, `type_text`, `press_key` | `screenshot`, `hit_test` | Tools for spaces and tabs |
|---|---|---|---|
| `browser` | yes | yes (`part: sidebar` too) | yes |
| `quick_detour` | yes; a window point over the page reaches its web view | yes | `unsupported_window` |
| `quarantine`, or a Quick Detour on the Private profile | as `quick_detour` while the user allows agents to use Private windows, `private_unreachable` otherwise (see [Private windows](./automation-endpoint-private-windows.md)) | the same | `unsupported_window` while allowed, `private_unreachable` otherwise |
| `settings` | test runs only (`gate_closed` on the user's endpoint); never in the Automation section | yes, on any endpoint | `unsupported_window` |

A Quick Detour's page is not a tab of a space, so its `selected_tab_id` is
null and the page tools do not take it. What the window shows is in
`selected_tab_url` and `selected_tab_title`.

# Settings

Settings takes input only in a test run because its panes do what the tools
keep to test runs or to the user. On the user's endpoint they would let an
approved client turn extensions on (in Private too), change their
permissions, delete profiles and edit Link Routes, all without the prompts
that `install_extension` and `set_extension_permission` are gated for. In
a test run too, a click on a view in Settings > General's Automation
section, or keys or a command while something in it has the keyboard, is
`gate_closed`. That section carries
`AutomationWindows.automationSettingsIdentifier`, so no tool turns on
Private access, resets the token, allows a client or turns on the [agent
pointer](./automation-endpoint-agent-pointer.md). A window-point click
cannot reach the Settings toolbar, which is outside the content view, so
switch panes with `open_ui settings` (`pane`, see [capture
staging](./automation-endpoint-staging.md)).

# Menus and child windows

Choosing from an open menu is input too. The menu tracker notes, beside a
menu's Private access, how far it reaches into Settings
(`AutomationSettingsReach`): a menu opened over Settings (under the
person's press, or in front while Detour is active) is listed on any
endpoint, but `choose_menu_item` takes it only in a test run, and never
one opened while the Automation section has the keyboard or under a press
on it (`gate_closed`). While Detour is active with Settings key, that
refuses the agent's own menus over other windows too, as the Private
check errs towards refusing.

A window's reach is the strictest along its whole chain of sheets and child
windows (`AutomationWindows.ancestry`), so a popover on a popover of a
Private Quick Detour is refused as the window is. Extension pages
(`popup:`, `options:`) take the same window check as tabs, and input by
`context` asks the same predicate.

Known gap (found in the TASK-228.7 review): input by `context` into a popup
opened over a Quick Detour or quarantine window answers `not_displayed`,
because `resolve(context:)` looks for the popup's parent among browser
windows only. The window itself takes input by `window_id`.

# Harness workarounds this replaces

Checks written before TASK-228.7 work around these limits.
`docs/harness/task326-copy-url-checks.py` right-clicks a sidebar row's
background and skips its label and icon. `docs/harness/task327` drives
Settings through Accessibility (`axdrive.swift`) and posted key events.
TASK-320's Quick Detour checks could not reach the window at all. In a test
run, each of these can now go through the endpoint: `click` at a row's
label, `click`, `type_text` and `press_key` on Settings' `window_id`, and
`run_menu_item` on a Quick Detour's. The scripts and the `/verify` skill
have not been rewritten.

# Tests

`AutomationWindowKindsTests` (Quick Detour and Settings windows listed with
their kind and stable ids; Private Quick Detour and quarantine windows
hidden and refused, then reachable, with the setting off and on; a Quick
Detour's screenshot, hit test, click and a command through its own
responder chain; `unsupported_window`; Settings seen on any endpoint, input
refused outside a test run and in the Automation section); details in [the
endpoint's tests](./automation-endpoint-tests.md).[^tests]

# Related

- [Automation endpoint (MCP)](./automation-endpoint.md): the hub.
- [Private windows](./automation-endpoint-private-windows.md): the opt-in
  the Private kinds follow.
- [How input is delivered](./automation-endpoint-input.md): what a click
  or key does once a window is reached.
- [Quick Detour](./quick-detour.md) and [quarantine](./quarantine.md): the
  non-browser windows.

[^task-228-7]: Automation: run_menu_item and right clicks match what the user sees (live titles, row labels), and Quick Detour windows and Settings can be addressed
[^windows]: AutomationWindows.swift (window kinds, who reaches which, Settings' Automation section)
[^tests]: MCPServerTests, AutomationHTTPTests, AutomationToolsTests, AutomationEndpointTests, and the other Automation suites
