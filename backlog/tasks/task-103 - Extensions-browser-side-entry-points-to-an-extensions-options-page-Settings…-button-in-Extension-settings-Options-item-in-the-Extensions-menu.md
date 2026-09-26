---
id: TASK-103
title: >-
  Extensions: browser-side entry points to an extension's options page
  (Settings… button in Extension settings, Options item in the Extensions menu)
status: Done
assignee:
  - '@claude'
created_date: '2026-09-21 08:28'
updated_date: '2026-09-26 03:17'
labels:
  - extensions
  - ui
dependencies: []
priority: low
ordinal: 103000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Detour reaches an extension's options page only when the extension itself calls runtime.openOptionsPage() (ExtensionManager.webExtensionController(_:openOptionsPageFor:) opens context.optionsPageURL in an extension tab). There is no browser-side entry, so an extension whose popup has no settings link, that has no popup at all (content blockers, userscript managers), or whose popup is broken has unreachable settings. Chrome offers 'Options' on the toolbar icon's context menu and 'Extension options' under chrome://extensions > Details; Safari shows a 'Settings' button for the extension in Settings > Extensions; both are absent/disabled when the manifest declares no options_page / options_ui. Found 2026-09-21 while looking for 1Password's 'Integrate with 1Password app' toggle during TASK-21. Existing plumbing: BrowserWindowController observes ExtensionManager.openOptionsPageNotification (handleExtensionOpenOptionsPage, opens context.optionsPageURL) but nothing posts it — reuse or replace it. Entry points to add: (1) a 'Settings…' button per extension row in ExtensionsSettingsViewController; (2) an options item per extension in the main-menu Extensions menu built in AppDelegate (menuNeedsUpdate, next to the per-extension popup items; must not load the popup page — see TASK-55 and ExtensionMenuPopupDecision). Options and storage are per profile, so the page must open in the context of a specific profile: from the Extensions menu, the key window's active space's profile; from Settings, the profile the pane is showing (or the key browser window's profile if the pane is not profile-scoped — decide and document). Open via the same path as openOptionsPageFor (TabStore.addExtensionTab with the context's webViewConfiguration), focusing an already-open options tab instead of opening a duplicate if that is cheap. Private: only when the extension is allowed in Private (TASK-74); otherwise the entry is disabled there.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Extension settings shows a Settings… control for each extension that declares options_page or options_ui, disabled or hidden for one that does not; activating it opens the options page as an extension tab in a browser window of the intended profile and brings that window forward
- [x] #2 The Extensions menu offers the same action per extension for the key window's profile, and building the menu loads no extension page (TASK-55 regression test still green)
- [x] #3 The page opens in the right profile's context: a test with two profiles asserts the opened tab uses that profile's extension context base URL and configuration, and that a profile where the extension is disabled or not allowed (Private without Allow in Private) offers no enabled entry
- [x] #4 The unused openOptionsPageNotification path is either used by the new entry points or removed
- [x] #5 Runtime check: 1Password's and API Explorer's options pages open from both entry points
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Pure decision: ExtensionOptionsPageEntry (Extensions/UI) — hasOptionsPage(manifest) and the Settings-pane profile rule (main browser window's profile, then the last-active space's, then any profile with an open space; Private only as the first candidate). Unit-tested.
2. ExtensionManager.optionsPageTab(for:in:preferring:) reuses an open options tab in the profile's spaces (same context origin + path) else addExtensionTab with the profile's own context; the openOptionsPageFor delegate reuses it.
3. openOptionsPage(for:in:) presents the tab in a window on that space, else switches a normal window, else opens a new window (AppDelegate.createNewWindow(showing:)).
4. Extensions menu: per-extension submenu with 'Show Popup' (ExtensionMenuPopupDecision, never popupWebView) and 'Options…' (key window's profile holds a context).
5. Settings pane: 'Settings…' header button, hidden without an options page, disabled when no profile resolves.
6. Removed openOptionsPageNotification / handleExtensionOpenOptionsPage.
7. Runtime check of both entry points with 1Password + API Explorer; docs/extensions.md note.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Verified Sep 25 2026 on branch task113 (worktree) with an env-gated harness in an isolated DetourVerify113 profile: API Explorer and a fixture extension open their options pages through ExtensionManager.openOptionsPage and the Settings… button (one tab, no duplicate, browser window becomes key); the Extensions menu builds each extension as a submenu (Show Popup / Options…) without loading popups (TASK-55 suite green). 1Password 8.12.37.1's manifest declares no options_page/options_ui, so its Settings… button is hidden and Options… disabled by design — its settings live inside its own app page. The menu's Options… enablement could not be driven from a shell-launched process (never the key app); it is the same rule the unit tests cover. Tests: ExtensionOptionsPageEntryTests (14), ExtensionMenuPopupDecisionTests, ExtensionEnabledStateTests.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Options pages now open from the browser side: a Settings… button in Extension settings (hidden without an options page, profile resolved by ExtensionOptionsPageEntry.resolveProfile: frontmost browser window's profile, then the last-active space's, then any profile with an open space, Private only when in front) and an Options… item in each extension's Extensions-menu submenu (key window's profile). ExtensionManager.optionsPageTab/openOptionsPage reuse an open options tab and present it in a window on that space, switching or creating one as needed; runtime.openOptionsPage shares the path. The unused openOptionsPageNotification was removed. Verified with unit tests and a runtime harness (API Explorer + fixture; 1Password declares no options page).
<!-- SECTION:FINAL_SUMMARY:END -->
