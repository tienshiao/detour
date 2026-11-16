---
type: Feature
title: Settings Learn more links
description: "The Learn more links from Settings to the website's guide pages (TASK-292.11): GuidePage shared with the Help menu, SettingsGuideLink opening the page in a Detour tab rather than the default browser, its alignment and hugging, where each link sits, and which guides are not linked."
resource: ../../Detour/Browser/Settings/SettingsGuideLink.swift
tags: [settings, help, appkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:14Z }
sources:
  - id: task-292-11
    resource: backlog:TASK-292.11
    title: "Settings: Learn more links from feature settings to their guide pages"
  - id: guide-link
    resource: ../../Detour/Browser/Settings/SettingsGuideLink.swift
    title: SettingsGuideLink.swift (the Learn more link)
  - id: help-menu
    resource: ../../Detour/App/HelpMenu.swift
    title: HelpMenu.swift (GuidePage, HelpLinks)
  - id: guide-link-tests
    resource: ../../DetourTests/SettingsGuideLinkTests.swift
    title: SettingsGuideLinkTests.swift
---

# What it does

The [Settings window](./settings.md) links each feature that has a guide
page on the website to it (TASK-292.11).[^task-292-11] The pages are
`GuidePage` in [HelpMenu.swift](../../Detour/App/HelpMenu.swift): its raw
value is the site's slug, and its URL is `HelpLinks.detourHelp.url` (the
Help menu's guide index, https://detourbrowser.com/features/) plus
`<slug>/`, so the Help menu and Settings share one definition. Only pages
that exist are listed (all 11 answered 200 on 2026-11-14).

# How it works

The link is `SettingsGuideLink`, a borderless `NSButton` in `linkColor`
with a pointing-hand cursor, accessibility role link, label "Learn more
about <page>" and identifier `learnMore.<slug>`. Its action calls
`SettingsGuideLink.open`, which is `AppDelegate.openHelpPage`: the page
opens as the Help menu's do, in a new selected tab of the frontmost normal
browser window (which comes forward over Settings), or a new window. Not a
`.link` attribute in a text field, which would open through NSWorkspace in
the default browser. Tests replace `open` to record the URL.

- A borderless button draws its title 2 pt further in than a label draws
  its text, so its `alignmentRectInsets` take 2 pt off each side and its
  text lines up with the text above it.
- Its vertical hugging is required: with the default, a list pane held
  taller than its content (Links at its 400 pt minimum) gave the spare
  height to the link button instead of the list, and in dark mode the
  captures showed the top link centred in a 70 pt gap
  (`testSpareHeightNeverStretchesALink`).

# Where the links are

| Where | Page | Placement |
|---|---|---|
| Spaces, Links, Quick Detour, Profiles, Search, Extensions, Content Blocking | spaces, link-routes, quick-detour, profiles, site-search, web-extensions, content-blocker | `guidePage` on the pane: the [pane container](./settings-pane-container.md#header) puts "Learn more about <page>" (12 pt) 4 pt under the description, or 20 pt below the toolbar in a pane without one (Quick Detour, Extensions); the body starts 12 pt below it (a form 20 pt), and `naturalContentHeight` counts it |
| General › Peek | peek | a link line of the Peek row, under its help |
| Links › Default | quarantine | in the Default's footnote, which is where the pane explains Quarantine |
| Profiles › Tabs, Content Blocking, Extensions | tab-archiving, content-blocker, web-extensions | "Learn more" as the section header's accessory (`ProfileSettingsSection.guidePage`); Tab Archiving covers sleeping too, so Private keeps it |
| Profiles › the Private profile's note | private-browsing | in the first section's footnote, "This profile is used for Private Windows." |

Not linked, because no Settings belong to them: command-palette,
favorites, pinned-tabs, split-tabs, recent-tabs, history, dev-mode (its
switch is in the sidebar's settings popover) and privacy (a setup guide
across several panes). Copy URL has no guide page. Shortcuts has none
either: the website's shortcuts page (Help > Keyboard Shortcuts,
`HelpLinks.keyboardShortcuts`, not a `GuidePage`) does not cover
customizing them yet.

# Tests

`SettingsGuideLinkTests`: `GuidePage` URLs under the Help menu's guide
index, which links each pane has, a click handing its URL to the opener,
the link under the description or in its place, the natural height
counting it, and spare height never stretching a link.[^guide-link-tests]
A Learn more click was not checked at runtime after TASK-338 (the link is
the pane container's and did not change).

# Related

- [Settings window](./settings.md) - the panes that carry the links.
- [App shell](../architecture/app-shell.md) - the Help menu and `openHelpPage`.

[^task-292-11]: TASK-292.11
[^guide-link-tests]: SettingsGuideLinkTests.swift
