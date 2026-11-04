---
id: TASK-210
title: 'Quick Detour: page settings menu, draggable bar, Open In and palette text'
status: Done
assignee:
  - '@claude'
created_date: '2026-10-27 02:17'
updated_date: '2026-10-27 02:51'
labels:
  - window
  - feature
dependencies: []
priority: low
ordinal: 246000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Feedback after TASK-193 (user, 2026-10-26). Four changes to the Quick Detour window (Detour/Browser/QuickDetour/):

1. Page settings menu. The main window's address bar opens SettingsPopoverViewController (showSiteSettingsPopover in BrowserWindowController+TabSidebar.swift): per-site content blocking with the blocked count, Picture in Picture, Dev Mode, and the profile's extensions with pin toggles and Extension Settings…. Quick Detour's bar (QuickDetourTitleBar) only has an extensions button (puzzle piece) that lists extensions. Replace that button with the same page settings menu, acting on the Quick Detour page and its profile, so extensions stay reachable from it as in the main window. The pinned extension buttons stay in the bar.
2. Dragging. Only the bar's background moves the window (mouseDownCanMoveWindow); the URL (host button) and the Open In button take every press, which leaves little to grab. A press on either that moves past the drag threshold drags the window instead; a plain click still opens the palette or the Open In menu.
3. Open In menu: remove the 'Reloads the page' subtitle on other-space items (QuickDetourWindowController.swift, menuItem.subtitle).
4. Palette prompt: Quick Detour's palette has no browser around it, so its placeholder becomes 'Search or enter a URL'. The main window's palette keeps 'Where do you want to go?' (CommandPaletteView.swift).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Quick Detour's bar opens the main window's page settings menu (content blocking with count, Picture in Picture, Dev Mode, extensions with pin toggles) in place of the extensions-only button, and its switches act on the Quick Detour page's site and profile
- [x] #2 Toggling content blocking from the menu reloads the Quick Detour page, as it does in the main window
- [x] #3 Pressing and dragging on the URL or the Open In button moves the window; a click without movement still opens the palette or the Open In menu
- [x] #4 The Open In menu's other-space items no longer show 'Reloads the page'
- [x] #5 Quick Detour's palette shows 'Search or enter a URL'; the main window's palette text is unchanged
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extract the main window's site settings popover setup into SettingsPopoverViewController.forPage(url:blockedCount:profileID:pages:openExtension:), used by BrowserWindowController.showSiteSettingsPopover and by the Quick Detour.
2. Quick Detour bar: replace the puzzle (extensions menu) button with the slider Site Settings button opening that popover for the window's page and profile; content blocking reloads the page; an extension's name opens its popup on the pinned button (or the settings button).
3. QuickDetourBarButton for the host and Open in's main part: past a 3 pt drag threshold hand the press to window.performDrag(with:), otherwise click.
4. Drop the Open in dropdown's 'Reloads the page' subtitle (tooltip stays).
5. CommandPaletteView.placeholder; Quick Detour's palette says 'Search or enter a URL'.
6. Tests: QuickDetourTitleBarTests (new), Open In and extension tests updated; runtime harness light/dark.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Queued (user, 2026-10-26): ahead of TASK-194 (order: 210, 211, 194, 201, 202, 209).

TDD: UI-level change (bar, popover wiring, button tracking). Tests were written alongside the code rather than red first: the whitelist/reload rule is the existing per-profile ContentBlockerWhitelist logic moved into the shared builder; the button's click-vs-drag loop got its tests in the same pass (QuickDetourTitleBarTests).

Decisions:
- One builder (SettingsPopoverViewController.forPage) for both windows. The main window's switches now act on the profile captured when the popover was built (before: blocking/PiP/pin read activeSpace at click time; dev mode already captured).
- PiP and dev mode switches are shown as asked (AC #1). They store the per-site setting for the profile, but a Quick Detour has no tab switch and no dev toolbar, so they have no visible effect inside the window.
- The extension list is the same as the main window's (every enabled extension with an action); the old Quick Detour menu also hid extensions whose context was not loaded yet. Not kept, so both windows list the same.
- QuickDetourBarButton accepts the first mouse (a background window can be dragged from the host/Open in), but a first press that does not move only brings the window forward: clicking Open in to reach the window must not move its page (code-review finding). Tracked by the press's timestamp from acceptsFirstMouse.
- Popovers on the bar now use preferredEdge .maxY: NSButton is flipped, so TASK-193.1's .minY opened the pinned extensions' popups ABOVE the button, out of the window (found in the runtime check; fixed for both the settings popover and performExtensionAction).
- The press-vs-drag loop mirrors WindowDragView (3 pt, performDrag with the original mouse-down); not shared, since WindowDragView forwards clicks to siblings.

Code review (/code-review high --fix): 7 findings. Fixed: the settings popover is closed in letGo(of:) with the extension popovers; forPage computes isDevModeEnabled with a nil profile as before. Fixed after the review: the first-mouse click on Open in. Skipped: PiP/dev mode inert in the window (the AC asks for them), the duplicate drag loop with WindowDragView, the loaded-context filter, the button shown with no page (the popover still reaches the extensions).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Quick Detour's bar now opens the main window's site settings popover (slider button) in place of the extensions-only puzzle menu, built by a new shared SettingsPopoverViewController.forPage that the main window's address bar also uses. Its switches act on the Quick Detour's profile, and content blocking reloads the page. The host and Open in's main part are QuickDetourBarButtons: past 3 pt of movement a press drags the window (performDrag with the press); otherwise it is a click; a first press on a background window only brings it forward. The Open in dropdown lost its 'Reloads the page' subtitle (the tooltip stays). The Quick Detour palette says 'Search or enter a URL'. Also fixed: popovers on the bar opened above their (flipped) buttons, so they now use .maxY.

Tests (all passing, 167 in 11 suites): QuickDetourTitleBarTests 7 (new), QuickDetourOpenInWindowTests 17, QuickDetourExtensionTests 16 (+1: an extension chosen in the site settings acts on the page), QuickDetourProfileSwitchTests 23, QuickDetourEntryPointsTests 21, QuickDetourLauncherTests 12, QuickDetourArchiveTests 17, QuickDetourSidebarCopyTests 6, DevModeSiteOverrideTests 15, ContentBlockerWhitelistTests 22, SiteSettingsStoreTests 11.

Runtime (/verify, Debug build, DETOUR_DATA_DIR=DetourVerify2100, light and dark, docs/harness/task210-harness.patch):
- The bar's popover listed the host, the switches and the pinned probe extension. Its blocking switch whitelisted the site in Default only and reloaded the page, then back.
- The probe's name opened its popup below its button.
- The palette showed the new prompt; the main window's palette kept its text.
- The dropdown has no subtitles.
- Real HID drags from the host and from Open in moved the window (no palette, page not moved). A HID click on the host opened the palette.
- A first click on Open in in a background window only activated it; a first drag moved it.
- The main window's popover (shared builder) listed the same, and its toggle reloaded the tab.

Not verified: a page with blocked resources (count > 0); several displays; a person's own hand; a plain HID click on Open in's main part (covered by the unit test of the click path). Observed, not changed: the probe extension's popup stayed 126×126 and clipped its 220 px content (ExtensionPopoverController sizing, outside this task).
<!-- SECTION:FINAL_SUMMARY:END -->
