---
id: TASK-74
title: >-
  Extensions: do not load extensions in the Private profile unless the user
  allows each one (Chrome's incognito default)
status: To Do
assignee: []
created_date: '2026-09-14 06:38'
updated_date: '2026-09-14 06:39'
labels:
  - extensions
  - privacy
dependencies: []
priority: high
ordinal: 74000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Decision 2026-09-13 (TASK-70 follow-up): until the Private profile's extension pages can run in its ephemeral store (TASK-73), every extension enabled in Private stores its data in WebKit's default, persistent data store — 1Password's item cache, localStorage and the cookies on the extension pages' own requests survive the Private window and the app. Adopt Chrome's default: extensions are OFF in the incognito profile unless the user opts in per extension ('Allow in Private'). Mechanics: the incognito profile already has per-profile enabled state (profileExtension rows, ExtensionManager.isEnabled(extensionID:inProfile:), setEnabled(id:profileID:enabled:), enabledExtensions(for:)); make the Private profile's default state disabled for every extension (existing installs included — a one-time migration that turns Private off for all current extensions, since today's implicit 'on' is the leak), and add an 'Allow in Private' switch per extension in ExtensionsSettingsViewController that flips only the incognito profile's row. Installing or updating an extension must not turn it on in Private (TASK-63 fixed the analogous nativeMessaging-grant overwrite). Show a short note next to the switch that extensions allowed in Private keep their data outside the private session until TASK-73 lands. Files: Detour/Extensions/Runtime/ExtensionManager.swift, Detour/Browser/Settings/ExtensionsSettingsViewController.swift, Detour/Storage/Database.swift (migration), Detour/Extensions/Storage/Models/ProfileExtensionRecord.swift.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A fresh install and an upgraded install both start with every extension disabled in the Private profile; the Private profile loads no extension context at launch (no 'Context loaded' for the incognito profile) and its Extensions menu and settings popover show none as active
- [ ] #2 Each extension has an 'Allow in Private' switch in Extension Settings that enables it in the incognito profile only; turning it on loads the context in Private without a relaunch, turning it off unloads it and closes its Private extension pages
- [ ] #3 Installing, updating or re-enabling an extension globally leaves its Private state untouched (tests with positive and negative cases, alongside ExtensionEnabledStateTests / ExtensionPermissionRestoreTests)
- [ ] #4 docs/1password-integration-plan.md and the settings note explain that extensions allowed in Private keep their storage in the default store until TASK-73
<!-- AC:END -->
