---
type: Feature
title: "Automation endpoint: Private windows"
description: The "Allow agents to use Private windows" opt-in of the automation endpoint, which covers what is hidden and refused while it is off (Private browser windows, Private Quick Detour and quarantine windows, their spaces, menus and extension contexts), what it opens when on, what turning it off again undoes, and what stays out of reach whatever the setting.
tags: [automation, mcp, security, privacy]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:12Z }
sources:
  - id: task-228-5
    resource: backlog:TASK-228.5
    title: "Automation: per-client approval prompt and tokens, and a Private-window opt-in, for the MCP endpoint"
  - id: task-228-7
    resource: backlog:TASK-228.7
    title: "Automation: run_menu_item and right clicks match what the user sees (live titles, row labels), and Quick Detour windows and Settings can be addressed"
  - id: windows
    resource: ../../Detour/Automation/AutomationWindows.swift
    title: AutomationWindows.swift (window kinds, who reaches which, Settings' Automation section)
  - id: approval-tests
    resource: ../../DetourTests/AutomationClientApprovalTests.swift
    title: AutomationClientApprovalTests and AutomationPrivateAccessTests
---

Private windows, spaces and tabs are reachable through the [automation
endpoint](./automation-endpoint.md) only while the user turns on "Allow
agents to use Private windows" (Settings > General > Automation;
`AutomationAllowPrivate` in the data directory's defaults suite, off by
default; a test run turns it on only through the same key, never through a
tool).[^task-228-5]

# How it is read

The setting is read at every check, never cached: the tools through
`AutomationEnvironment.allowsPrivate` (the controller points it at its
defaults), page capture and the extension channel, console and stub counts
through `AutomationPrivateAccess.isAllowed`. Turning it off refuses again
from the next call.

Which windows count as Private is decided in one place,
`AutomationWindows` (see [window kinds](./automation-endpoint-windows.md)):
a Private browser window, a Quick Detour window on the Private profile, and
a quarantine window (`AutomationWindows.privateQuickDetourAccess =
.privateOptIn`).[^windows] Listing, refusal by id, menus over a window, the
Window menu's entries, `set_window_frame` (by id or `window_number`),
`resolvePage`, extension popups over a window and input by `context` all ask
that one predicate, and a window's access is the strictest along its chain
of sheets and child windows.

# Off, on, and off again

- **Off**: Private windows (Private browser windows, Quick Detour windows on
  the Private profile and quarantine windows) and Private spaces are left
  out of `list_windows` (`hidden_private_windows` counts them) and
  `list_spaces`, and refused by id (`private_unreachable`, whose message
  says the user can allow it). Menus stay out too: a menu that opened over
  a Private window (the person's context menu there, or the menu bar while
  one is in front and Detour is active) is refused by `list_menu` and
  `choose_menu_item`, and the Window menu's entries for Private windows
  (titled with their page) are neither listed nor run. This errs towards
  refusing: an agent's own menu opened while a Private window is in front
  is refused too. Whether a menu opened over a Private window is noted when
  it opens; whether that matters is asked at the call.
- **On**: every tool reaches them; windows and spaces carry
  `is_private: true`. A Private Quick Detour or quarantine window is listed
  and takes screenshots, input and menu commands like any Quick Detour.
  Page capture is installed in the live pages of Private spaces and in new
  ones. A route into a Private window is followed by `open_url`.
- **Turned off again**: refused at once; capture is removed from Private
  pages and their records forgotten; the Private profile's worker parks are
  stopped (waiting commands fail), its endpoint-opened popups closed, its
  extension console and stub counts forgotten. Changing the key from
  outside (`defaults write`) changes what the tools allow at once (checked
  at runtime), but only the Settings switch installs or removes capture.
  "At once" means from the next call: a call already running into a
  Private tab (a long `type_text` with `interval_ms`, an `evaluate_js`)
  finishes, as one does after Disconnect, Revoke or Turn Off.

Private Quick Detour and quarantine windows follow the setting by the
user's decision on TASK-228.7 (2026-11-14); the first cut had kept them
unreachable whatever the setting.[^task-228-7] Checked at runtime on
2026-11-15 (`docs/harness/task228-7-private-quick-detour-checks.py`, the
setting from a launch argument): a quarantine opened by a routed click was
left out of `list_windows` and refused by `screenshot` and `hit_test` by id
with the setting off, and listed (`kind: quarantine`, `is_private: true`)
and captured with it on.

# Extension contexts in the Private profile

The Private profile's extension contexts follow the setting, but only when
named (`popup:<ext>@<Private profile id>`): a client that names no profile
resolves exactly as before. Its workers that were answered `stop` while the
setting was off park only at their next start, as with turning the
endpoint on. See [extension contexts](./automation-endpoint-extensions.md).

# Out of reach whatever the setting

- **The Private profile as a target** of `install_extension`,
  `set_extension_enabled` or a permission: those skip the user's prompts.
- **Page capture in Quick Detour and quarantine pages**, which are not tabs
  of a space and so no page tool's context.

# `open_url` and quarantines

`open_url` never opens a quarantine, with the setting on or off: Link
Routes never quarantine a typed URL (`LinkRouteResolver`, decision of
2026-10-26), so a route into a quarantine does not apply and the URL opens
in a new tab of the window's space (`AutomationToolsTests.testOpenURLNeverOpensAQuarantine`,
and checked at runtime). A click on a routed link can still open one, as a
person's does. The user chose on 2026-11-15 that a quarantine route in
`open_url` should follow the setting; it is moot while typed URLs are never
quarantined, and the guard in `open_url` refuses one only while the setting
is off, should that change.[^task-228-7]

# Tests

`AutomationPrivateAccessTests` (listing, a page tool, an input tool and a
menu tool with the setting off, on and off again; capture installed in and
removed from Private pages, never in a Private Quick Detour page; the
Private profile never an install target, its contexts following the
setting) and `AutomationWindowKindsTests` (Private Quick Detour and
quarantine windows off and on); details in [the endpoint's
tests](./automation-endpoint-tests.md).[^approval-tests]

# Related

- [Automation endpoint (MCP)](./automation-endpoint.md): the hub.
- [Window kinds](./automation-endpoint-windows.md): the predicate's home
  and the other window kinds.
- [Page tools and capture](./automation-endpoint-page-tools.md): capture in
  Private pages.
- [Quick Detour](./quick-detour.md) and [quarantine](./quarantine.md): the
  windows the Private kinds come from.

[^task-228-5]: Automation: per-client approval prompt and tokens, and a Private-window opt-in, for the MCP endpoint
[^task-228-7]: Automation: run_menu_item and right clicks match what the user sees (live titles, row labels), and Quick Detour windows and Settings can be addressed
[^windows]: AutomationWindows.swift (window kinds, who reaches which, Settings' Automation section)
[^approval-tests]: AutomationClientApprovalTests and AutomationPrivateAccessTests
