---
id: TASK-292.11
title: 'Settings: Learn more links from feature settings to their guide pages'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-08T06:59:00Z'
updated_date: '2026-11-14T21:13:00Z'
labels:
  - website
dependencies:
  - TASK-292.5
  - TASK-292.6
  - TASK-292.7
  - TASK-292.8
parent_task_id: TASK-292
priority: low
ordinal: 352000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Settings panes for features with a guide page (Spaces, Profiles, Content Blocker, Link Routes, Quarantine, Site Search, Extensions and others) give no hint of how the feature works. A small Learn more link to the guide page closes that gap once the pages exist.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Each Settings pane or section whose feature has a guide page has a Learn more link to it, opening the same way as the Help menu items
- [x] #2 Link URLs come from the same single definition as the Help menu
- [x] #3 Checked at runtime with /verify
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. One definition: GuidePage (Detour/App/HelpMenu.swift, beside HelpLinks), raw value = the website slug; url = HelpLinks.detourHelp.url + <slug>/ (https://detourbrowser.com/features/<slug>/, trailingSlash always in the site's astro.config). Only pages Settings links. All checked live (HTTP 200) on Nov 14 2026.
2. SettingsGuideLink (Settings/SettingsGuideLink.swift): a borderless NSButton in link colour, pointing-hand cursor, accessibility label 'Learn more about <name>', identifier learnMore.<slug>. Its action calls SettingsGuideLink.open, which defaults to AppDelegate.openHelpPage (the Help menu's own opener: new selected tab in the frontmost normal window, else a new window). Tests replace the opener to record the URL.
3. Pane-level: SettingsPaneViewController.guidePage (next to paneDescription); the container puts the link under the description (controlToHelp), or at the top of a pane without one, and counts it in naturalContentHeight. Spaces -> spaces, Links -> link-routes, Quick Detour -> quick-detour, Profiles -> profiles, Search -> site-search, Extensions -> web-extensions, Content Blocking -> content-blocker.
4. Section-level: General > Peek -> peek (under its help); Links > Default caption -> quarantine (under the caption that explains Quarantine); Profiles sections Tabs -> tab-archiving, Content Blocking -> content-blocker, Extensions -> web-extensions (beside the section title, via the pure ProfileSettingsSection.guidePage); the Private profile's note -> private-browsing.
5. Not linked (no Settings for them): command-palette, favorites, pinned-tabs, split-tabs, recent-tabs, history, dev-mode (its switch is in the sidebar's settings popover, not Settings), privacy (a setup guide across panes). Copy URL has no guide page.
6. Tests: GuidePage URLs (exact, https, under the Help menu's base); every pane's links and their URLs via performClick with a recording opener; ProfileSettingsSection.guidePage. Run HelpMenuTests, SettingsPaneColumnsTests, SettingsPaneHeightTests, ProfileSettingsLayoutTests.
7. /verify: each pane via open_ui settings, screencapture light and dark; AXPress a link and check list_tabs for the URL in the isolated profile's window.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented (Nov 14 2026, @claude):
- GuidePage (Detour/App/HelpMenu.swift): the 11 guide pages Settings links, raw value = the website's slug (src/content/features), url = HelpLinks.detourHelp.url + <slug>/ (the site builds with trailingSlash always). All 11 answered HTTP 200 on Nov 14 2026. Copy URL has no guide page, so it is not linked.
- SettingsGuideLink (Settings/SettingsGuideLink.swift): borderless NSButton in linkColor, pointing-hand cursor, AX role link, label 'Learn more about <page>', identifier learnMore.<slug>. Action -> SettingsGuideLink.open = AppDelegate.openHelpPage, the Help menu's own opener (new selected tab in the frontmost normal window, else a new window; never the default browser: a text-field .link would have gone through NSWorkspace). alignmentRectInsets take 2 pt off each side: measured on screen, a borderless button draws its title 2 pt further in than a label, so the link's text now lines up with the text above it (x 21 = 21 after, 21 vs 23 before).
- Pane level: SettingsPaneViewController.guidePage; the container puts the link 4 pt under the description (20 pt below the toolbar without one), body 12 pt below, naturalContentHeight counts it. Spaces, Links (link-routes), Quick Detour, Profiles, Search (site-search), Extensions (web-extensions), Content Blocking (content-blocker).
- Section level (choices by Claude while the user was away, each a one-line change to flip): General > Peek under its help; Links > Default -> Quarantine under the caption that explains Quarantine; Profiles sections Tabs (tab-archiving, which also covers sleeping, so Private keeps it), Content Blocking, Extensions -> 'Learn more' beside the title (pure ProfileSettingsSection.guidePage); the Private profile's note -> private-browsing. Not linked (no Settings for them): command-palette, favorites, pinned-tabs, split-tabs, recent-tabs, history, dev-mode (its switch is in the sidebar popover), privacy (a setup guide across panes).
- General/Quick Detour rows untouched apart from one view appended to the Peek stack (TASK-328 next).
- Tests: new SettingsGuideLinkTests (9): GuidePage URLs under the Help menu's index, the slug list, which pages each of the 8 panes links (and that every GuidePage is linked), pane guidePage values, ProfileSettingsSection.guidePage, a performClick handing the URL to the opener (Spaces and every Profiles link), the AX label/identifier, the link under the description and in its place without one, the natural height counting it. Run with HelpMenuTests 8, SettingsPaneColumnsTests, SettingsPaneHeightTests, ProfileSettingsLayoutTests: 74 tests, 0 failures (before and after the review fixes). Links still fits its 400 pt minimum (existing test).
- /code-review medium --fix: 5 findings; fixed: the .momentaryChange button blanked its title while pressed (attributedAlternateTitle now = attributedTitle), a dead test condition. Left: the Private note row (now a stack) takes the centred row alignment (no label in that row, no visible change); naturalContentHeight restates the header spacing (extends the existing pattern); SpaceEditorView's All Emoji button has similar link styling (outside the diff).
- Runtime (/verify, DETOUR_DATA_DIR=DetourVerify-29211, DETOUR_MCP=1, open_ui settings + screencapture -l): every pane captured in light and dark, plus Profiles with Private and with Default selected and Extensions empty; no clipping at the bottom edges. Clicked via Accessibility AXPress (target/action, the same path as a click; no HID click, the pointer was not moved): all 11 links across two builds (spaces, link-routes, quick-detour, profiles, content-blocker x2, site-search on the final build; tab-archiving, private-browsing, quarantine, peek, web-extensions on the build before the 2 pt alignment and pressed-title fixes, which did not touch the action) each opened a selected tab with the right https://detourbrowser.com/features/<slug>/ in the isolated profile's browser window, which became key over Settings. Pages loaded in that isolated Detour only, never the default browser. Not checked: a real mouse click and the pointing-hand cursor on screen. Data dir and defaults keys removed.

Follow-up the same day, before handing back (all of it in the same commit):
- Bug found in the dark captures: in Links at its 400 pt minimum the top link button took the spare height (default vertical hugging, tied with the list's priority-250 height) and sat centred in a ~70 pt gap above Routes. Light mode happened to lay it out right. Fix: the link's vertical hugging is required. New test testSpareHeightNeverStretchesALink: it fails without the fix (link 73 pt and 373 pt tall instead of 15) and passes with it.
- Also run: AutomationStagingTests, ExtensionPermissionRestoreTests, SiteSearchPaletteTests (the other suites that build Settings panes). Final run: SettingsGuideLinkTests 10, HelpMenuTests, SettingsPaneColumnsTests, SettingsPaneHeightTests, ProfileSettingsLayoutTests plus those three: 176 tests, 0 failures.
- Final runtime pass on that build (DetourVerify-29211b): all 8 panes captured in light and dark, and all 16 captures viewed. Links in dark now matches light. The screen was locked partway through, so these captures show the window as inactive; the layout is unaffected. Quarantine's link pressed (AXPress) opened https://detourbrowser.com/features/quarantine/. The earlier passes are as recorded above. Defaults keys and the data directory were removed.
- The wiki's container description, natural-height formula, Quick Detour section and fixed pane heights were updated to include the link line, and so was the class comment.
- Not verified: a real mouse click, the pointing-hand cursor, and the pressed-state fix on screen (AXPress does not show it).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Settings now has Learn more links to the website's feature guides: under the description of Spaces, Links, Profiles, Search and Content Blocking, at the top of Quick Detour and Extensions, under General's Peek help, under the Links Default caption (Quarantine), beside the Profiles section titles Tabs, Content Blocking and Extensions, and under the Private profile's note (Private Browsing). URLs come from GuidePage, derived from the Help menu's HelpLinks.detourHelp (one definition), and open through AppDelegate.openHelpPage like the Help menu items (a tab in the front normal window, never the default browser). 9 new tests, 74 run with 0 failures; checked at runtime in light and dark with every link pressed through Accessibility.
<!-- SECTION:FINAL_SUMMARY:END -->
