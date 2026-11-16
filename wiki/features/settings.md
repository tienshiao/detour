---
type: Component
title: Settings window
description: "The Settings window and its nine panes (General, Profiles, Spaces, Links, Quick Detour, Search, Extensions, Content Blocking, Shortcuts): what the window is, which pane edits what and how each opens, and the pages on its layout, height rule, grouped form, accessibility, Learn more links, panes and traps."
resource: ../../Detour/Browser/Settings
tags: [settings, appkit, profiles, spaces, layout]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:14Z }
sources:
  - id: window
    resource: ../../Detour/Browser/Settings/SettingsWindowController.swift
    title: SettingsWindowController.swift
  - id: container
    resource: ../../Detour/Browser/Settings/SettingsPaneViewController.swift
    title: SettingsPaneViewController.swift (pane container)
  - id: task-189
    resource: backlog:TASK-189
    title: "Settings: fix the window's spacing and clipping"
  - id: task-338
    resource: backlog:TASK-338
    title: "Settings: System Settings–style grouped rows, with labels on the left and switches and controls aligned on the right"
  - id: task-347
    resource: backlog:TASK-347
    title: "Settings: panes ordered by topic, and a tall pane opens at a design maximum height instead of the screen's"
  - id: columns-tests
    resource: ../../DetourTests/SettingsPaneColumnsTests.swift
    title: SettingsPaneColumnsTests.swift
---

# Role

`SettingsWindowController.shared` is one window with a preference-style
toolbar and nine panes. It holds no settings of its own: each pane reads and
writes model objects directly (`TabStore`, `Profile`, `ExtensionManager`,
`ContentBlockerManager`, `ExternalAppPermissionStore`, `LinkRouteStore`,
`ShortcutBindingStore`), and persistence happens in those owners. The
default browser is not stored by Detour at all.

There is a second, unrelated "settings" surface: the sidebar's settings
**popover** (`SettingsPopoverViewController`), which holds, under the
page's host, the per-site content-blocking switch, the picture in picture
and dev mode switches (not in a Quick Detour) and the extension list for
the current page. See [content blocking](./content-blocking.md) and
[popup and options UI](../extensions/popup-and-options-ui.md).

# The window

- Style mask `.titled, .closable, .resizable`, resizable **in height only**:
  `contentMinSize.width == contentMaxSize.width == 740`, and every pane's
  root view also holds a required `width == 740`, so no content can widen
  the window (a long extension name used to stretch it to 1104). Full screen
  is off (`.fullScreenNone`), tabbing disallowed.[^task-189]
- The nine view controllers are created once in `init` and kept in
  `panes`, in the toolbar order of `SettingsWindowController.paneOrder`:
  General, Profiles, Spaces, Links, Quick Detour, Search, Extensions,
  Content Blocking, Shortcuts. The order is by topic since TASK-347, the
  user's choice: profiles beside the spaces that use them, where links
  open, search, what pages may do, and the keyboard last.[^task-347]
  (Before, it was General, Spaces, Links, Quick Detour, Profiles, Search,
  Shortcuts, Extensions, Content Blocking.)
- Switching swaps `window.contentViewController` at the current size, then
  `fitWindow` animates to the new pane's height with the top edge fixed
  (moved only as far as needed to stay on the screen); see
  [Settings window height](./settings-window-height.md).
- `showWindow` fits the current pane before re-centring and activating.
- Every pane is a `SettingsPaneViewController`: a description and Learn
  more link at the top, then a body that either scrolls as a whole or holds
  a list and a detail column that scroll on their own; see
  [Settings pane container](./settings-pane-container.md). Since TASK-338
  every pane's settings are rows of a System Settings–style
  [grouped form](./settings-grouped-form.md), and the lists are drawn as its
  groups.[^task-338]

# Panes

| Pane | Body | Edits | Opened by | Details |
|---|---|---|---|---|
| General | scrolls as a whole | the default browser, Peek from pinned tabs, the automation endpoint and its clients | Detour > Settings… (Cmd+,), which opens whatever pane was last shown | [Settings panes](./settings-panes.md#general) |
| Profiles | list and detail column | each profile's search, tabs, content blocking, extensions, user agent, external-app permissions | toolbar only | [Profiles pane](./settings-profiles-pane.md) |
| Spaces | list and detail column | each space's name, emoji, colour, profile; order | the sidebar's add-space and edit-space actions (`showSpacesPane(selectSpaceID:)`), Spaces > Manage Spaces… (`openSpacesSettings`) | [Settings panes](./settings-panes.md#spaces) |
| Links | route list, Default fixed below | link routes and the Default | toolbar; Open Links Settings… in the blocked space-deletion alert (`showLinksPane(highlightingSpaceID:)`) | [Settings panes](./settings-panes.md#links) |
| Quick Detour | scrolls as a whole | the global hotkey, ⌥⌘-click, idle auto-close | toolbar; Settings > Shortcuts' Quick Detour row (`quickDetourPaneName`) | [Settings panes](./settings-panes.md#quick-detour) |
| Search | list | site searches | toolbar only | [Settings panes](./settings-panes.md#search) |
| Extensions | list and detail column | each extension's state, profiles, permissions, updates | Extensions > Manage Extensions…, the settings popover (`showExtensionsPane()`) | [Extensions pane](./settings-extensions-pane.md) |
| Content Blocking | scrolls as a whole | filter list downloads, the tracking-parameter list | toolbar only | [Settings panes](./settings-panes.md#content-blocking) |
| Shortcuts | list | every menu command's shortcut | toolbar only | [Settings panes](./settings-panes.md#shortcuts) |

Which panes take which body form and the toolbar order are checked by
`SettingsPaneColumnsTests`.[^columns-tests]

# Pages

- [Settings window height](./settings-window-height.md) - the height rule (natural height, opening no taller than 720 pt or the screen, list panes down to 400), refits, measured pane heights, the resize-animation traps.
- [Settings pane container](./settings-pane-container.md) - `SettingsPaneViewController`: description and link, the two body forms, natural height, `SettingsMetrics`, the wrapping label and the list group.
- [Settings grouped form](./settings-grouped-form.md) - `SettingsForm` (TASK-338): sections, groups, rows, their measured metrics, switches, and what AppKit does not give.
- [Settings accessibility](./settings-accessibility.md) - one accessible name per control and no label read twice (TASK-336, TASK-338, TASK-342).
- [Settings Learn more links](./settings-learn-more-links.md) - `GuidePage` and `SettingsGuideLink`: where each link sits and how it opens.
- [Settings panes](./settings-panes.md) - General, Spaces, Links, Quick Detour, Search, Shortcuts and Content Blocking.
- [Settings Profiles pane](./settings-profiles-pane.md) - sections, `ProfileSettingsLayout`, deletion rules, the per-profile extension switch.
- [Settings Extensions pane](./settings-extensions-pane.md) - the detail column, Uninstall below it, rebuilds that keep their state.
- [Settings layout traps and runtime checks](./settings-layout-traps.md) - AppKit layout traps met on the way and the harnesses that check the panes at runtime.

# Tests

Each page lists the suites for its part. The panes' behaviour is tested
through the model code they call: `TabStoreTests` and the profile and space
suites, `ExternalAppPermissionTests`, `ContentBlockerWhitelistTests`,
`ExtensionOptionsPageEntryTests`, and the extension update and permission
suites. Their layout is checked at runtime with the harnesses on
[Settings layout traps and runtime checks](./settings-layout-traps.md).

# Related

- [Profiles and spaces](../architecture/profiles-and-spaces.md) - the model the Spaces and Profiles panes edit.
- [Content blocking](./content-blocking.md) - lists, toggles and the per-site switch.
- [External apps](./external-apps.md) - the saved permissions the Profiles pane can clear.
- [Extension manager](../extensions/extension-manager.md), [permissions](../extensions/permissions.md), [updates](../extensions/updates.md) - what the Extensions pane drives.
- [Popup and options UI](../extensions/popup-and-options-ui.md) - the "Settings…" button and the sidebar's settings popover.
- [App shell](../architecture/app-shell.md) - the menu items that open the window.
- [Keyboard shortcuts](./keyboard-shortcuts.md) - the Shortcuts pane's behaviour.
- [Link routing](./link-routing.md) - the Links pane's behaviour.
- [Quick Detour](./quick-detour.md) - what the Quick Detour pane configures.
- [AppKit gotchas](../platform/appkit-gotchas.md) - the stack-view and layout traps in general form.

[^task-189]: TASK-189
[^task-338]: TASK-338
[^task-347]: TASK-347
[^columns-tests]: SettingsPaneColumnsTests.swift
