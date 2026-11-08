---
id: TASK-292.8
title: >-
  Website: guide pages for Link Routes, Quick Detour, Web Extensions and Dev
  Mode
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-08T06:59:00Z'
updated_date: '2026-11-08T09:30:00Z'
labels:
  - website
dependencies:
  - TASK-292.2
parent_task_id: TASK-292
priority: medium
ordinal: 349000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Links from other apps and power-user features, written to the pilot template (TASK-292). Link Routes, Quick Detour and Dev Mode have Arc counterparts (Air Traffic Control, Little Arc, Developer Mode, which Arc also turned on for localhost); per Arc's help center (Wayback Machine, see TASK-292.3 notes). The Web Extensions page sets expectations honestly: which extensions are known to work, which are known not to, and that support is in progress. Captures come from the staged demo profile and kit in docs/task-110 (public pages only, no personal data, every launch with DETOUR_DATA_DIR set).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Each page follows the template from the pilot (H1 + lede, media, what/why, how-to steps, FAQ, related features, download) with its own title tag and meta description pairing the feature name with the generic search phrase
- [ ] #2 Steps, menu paths and shortcuts on each page were checked against the current release build
- [ ] #3 Images and loops have alt text or aria-labels describing what is on screen, fixed dimensions, and loops meet the TASK-110 size and reduced-motion rules
- [ ] #4 Pages are in the sitemap and linked from the home page entry for the feature
- [ ] #5 The Web Extensions page says how to install a CRX and lists known working and known broken extensions as of its date
- [ ] #6 A Coming from Arc box appears only on pages whose feature Arc had in comparable form
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026 (agent, website worktree branch task-292.8, commit aa39dd6, not pushed): pages /features/link-routes/, /features/quick-detour/, /features/web-extensions/, /features/dev-mode/ (no media yet), each with a Coming from Arc box (Air Traffic Control, Little Arc, Extensions, Developer Mode, from the hub's help-center extracts); home grid entries 16/20/21/24 link to them (existing TASK-292.7 CSS, none added). docs/feature-pages.md: Developer Mode and extensions moved to the 'Arc had it' list (it listed Dev Mode and Site Search as never in Arc; the Arc hub and Arc's help center say otherwise; may conflict with TASK-292.6's branch on that one line).

Runtime check (v0.4.0 tag, Debug build, temporary harness Detour/App/DocsHarness2928.swift + one-line AppDelegate hook in the scratchpad app worktree, not committed; DETOUR_DATA_DIR DetourDocs2928; python http.server on 127.0.0.1:8798): File menu New Quick Detour Window ⌥⌘N, Open Quick Detour in Space ⌘O (disabled with a browser window key; 'Open in 🏠 Home' while a Quick Detour is key; ⌘L enabled there). Extensions menu Add Extensions…/Manage Extensions…/Check for Extension Updates; with an extension, its submenu Show Popup/Options…. Develop: Web Inspector ⌥⌘I, Load Unpacked Extension…, Reload "<name>". Settings > Quick Detour: hotkey checkbox + ⌥⌘N recorder (off in the isolated dir, Debug message), help texts, ⌥⌘-click checkbox on, idle Never/1 hour/6 hours (selected)/12 hours/1 day. Settings > Links: description, Routes/New Route/empty text, Default 'Open other links in' = Most Recent Space, targets spaces + Most Recent Space/Private Window/Quick Detour/Quarantine; URL condition Domain is/Contains/Is equal to/Any URL; From app Any App/running apps/Choose…. A route 'Domain is' empty + From app was refused (TASK-302 confirmed). Resolver: Domain is github.com → Work for external/typed/clicked incl. gist.github.com, stay from Private and from Work; app-only TextEdit → quickDetour for external, stay typed; Contains+Notes → Work only from Notes; Is equal to ignores #fragment, → Private window also typed; Default Work routes typed and clicked; Default Quick Detour external only. Real path: openExternalURLs from Notes switched the window to Work with the tab; from TextEdit opened a Quick Detour (900x640, pill Default, 'Open in 💼 Work ⌘O'). Launcher via the menu action: panel 560x321, key, floating, history suggestions; closed opens nothing. Quick Detour window: bar Profile pill / host 'Go somewhere else' / Site Settings / Copy Link / Open in 🏠 Home ⌘O / 'Open in Another Space'; open-in menu grouped by profile with the reload tooltip for another profile; profile menu with Private last; in no space; Open in via File menu moved it into Home and closed the window; closing one by hand → archive 'Quick Detour · example.com/?b'; Private window in front → Private Quick Detour, 'Open in Private Window', no dropdown. Dev Mode on http://localhost:8798: active, toolbar Site Settings/address/Copy URL/Capture Visible Area/Capture Full Page/Console/Network/Select Element, one hazard border in the sidebar; Capture Visible Area put PNG+TIFF on a private pasteboard; rule true for localhost:3000, app.localhost, 127.0.0.1, 127.1.2.3, [::1], 0.0.0.0, myapp.test, false for 192.168.1.20, printer.local, example.com, file:. Site Settings popover: 'Dev mode for this site' switch; turning it on for example.com showed the toolbar. Local unpacked MV3 test extension: Settings > Extensions shows name/version/'Loaded unpacked from…'/Reload/Enabled/Allow in Private (off)/Permissions with switches/Uninstall Extension, list +/-; Settings > Profiles > Extensions switch per profile (Private off); popover row with 'Pin to address bar'.
Code only: global hotkey from another app, ⌥⌘-click on links and sidebar tabs, idle auto-close timing, Open in to another profile reloading, Add Extensions… opening the store tab and the 'Add to Chrome' hijack, the CRX install prompt text ('From the Chrome Web Store.', Permissions/Site access), signature gate, automatic update schedule (~5 h), pending-permission and staged updates, uninstall alert, pinned buttons in the address bar on hover, capture toast text and Option-click save, Console/Network/Select Element actions, 1Password (wiki + 1Password's support page for Settings > Browser > Add Browser), the known-broken list (wiki: webRequest stub, no sidePanel/tabGroups/debugger/identity/downloads in WebKit; MV2 refused in ExtensionInstaller). The brief's 'declarativeNetRequest not available' was left out: WebKit vends that namespace natively (docs/chrome-runtime-patching.md), so the page doesn't claim it.

Browser check: Chrome at 1462 px (pages, extension lists, Arc box, FAQ) and 390 px iframes of the four pages, home and /arc/: scrollWidth 386 everywhere; home grid links 16/20/21/24 present; /arc/ links all four; all four in dist/sitemap.xml. A two-column status table on the Web Extensions page squeezed at desktop width and became two lists.
Cleanup: removed WebsiteDataStore 33ec675e-5977-5cc1-9d5f-691d3ca51c7e and 4d4b55ee-d5cf-57a9-a5ad-a402c17b57ac (created 01:23:14 by the run), the NSWindow Frame / NSSplitView keys for DetourDocs2928, the com.detourbrowser.mac.DetourDocs2928 suite and ~/Library/Application Support/DetourDocs2928. Left for the lead (outside the allowed deletions): ~/Library/WebKit/com.detourbrowser.mac/WebExtensions/33EC675E-…/ and 4D4B55EE-…/ (same run, hold the test extension's CC00F5C2-… folder).
<!-- SECTION:NOTES:END -->
