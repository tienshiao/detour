---
id: TASK-55
title: >-
  Extensions: building the Extensions menu loads every extension's popup page,
  prompting 1Password to unlock at launch
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 08:45'
updated_date: '2026-09-13 10:06'
labels:
  - bug
  - extensions
  - 1password
dependencies: []
priority: high
ordinal: 55000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Observed 2026-09-13: on a fresh launch with 1Password locked in the desktop app, Detour triggers an Apple Watch unlock request with no visible popup and no user click; it seemed to coincide with opening a second window, but which window triggered it was unclear. An unlock request is 1Password's normal response to its popup page loading while the vault is locked — the bug is that the popup page loads without anyone opening it. Likely cause: AppDelegate builds the per-profile Extensions menu (AppDelegate.swift ~509) with 'context.action(for: nil)?.popupWebView != nil' to decide whether an item is clickable. WKWebExtension.Action.popupWebView is lazily created — reading it instantiates the popup WKWebView and loads the popup page — so every menu (re)build (per window / per profile switch) silently loads 1Password's popup, whose page immediately asks the desktop app to unlock. The menu already has the manifest fallback (ext.manifest.action?.defaultPopup); the WebKit check should be action.presentsPopup, which only inspects the popup path. Audit the other action(for:) touchpoints (ExtensionManager.iconImage ~759 reads badgeText/icon only — fine; ExtensionPopoverController ~58 and ExtensionManager.presentActionPopup ~1469 read popupWebView intentionally, on user or extension request) and add a guard that no popupWebView is read outside an explicit present. Verify with the Extensions-category log / WebKit 'Loaded popup' messages, or a test extension whose popup page logs on load, that launching Detour and opening a second window does not load any popup page.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The Extensions menu item is still enabled for extensions that declare a popup (via action.presentsPopup or the manifest default_popup) and disabled otherwise
- [x] #2 Unit test with a popup-declaring test extension asserts the menu decision does not touch popupWebView (e.g. the popup web view stays nil / the popup page's load hook is not hit until presented)
- [x] #3 Popup web views are read only from the explicit present paths (user click, browser.action.openPopup)
- [ ] #4 Launching Detour and opening a second window with 1Password enabled and locked does not create or load any extension popup web view, and no unlock prompt appears until the user opens the popup
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extract the menu's popup decision into a pure helper (ExtensionMenuPopupDecision / ExtensionMenu.hasPopup(action:manifestDefaultPopup:)) that takes a narrow protocol exposing only presentsPopup; WKWebExtension.Action conforms. The type shape makes popupWebView unreachable from the decision.
2. AppDelegate.updateExtensionsMenu uses the helper (presentsPopup || manifest default_popup) instead of reading popupWebView. Note in a comment that menuNeedsUpdate also fires on every key-equivalent dispatch, so the menu is rebuilt far more often than it is opened.
3. Audit action(for:) touchpoints: iconImage (badge/icon only), ExtensionPopoverController.show and presentActionPopup (explicit present paths) remain the only popupWebView readers; document the rule at those sites.
4. Tests: ExtensionMenuPopupDecisionTests with a spy action (presentsPopup true/false x manifest default_popup nil/non-nil); best-effort integration test with a popup-declaring test extension whose popup.html beacons to a loopback server, asserting the menu decision does not trigger the load and an explicit popupWebView read does.
5. AC #4 (real 1Password locked, second window) is a manual check for the user.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Cause confirmed: menuNeedsUpdate runs on every key-equivalent dispatch, and the menu read WKWebExtension.Action.popupWebView (lazily creates + loads the popup). Fix: ExtensionMenuPopupDecision.hasPopup over a narrow ExtensionActionPopupDeclaring protocol (presentsPopup only), so the decision cannot reach popupWebView by type. Audit: popupWebView is read only in ExtensionPopoverController.show (user click) and ExtensionManager.presentActionPopup (browser.action.openPopup). Tests: spy decision cases + an integration test with a popup-declaring extension whose popup.html beacons a loopback server (img beacon; inline fetch is blocked by the MV3 page CSP) — the menu decision triggers no load, an explicit popupWebView read does. Review moved LoopbackHTTPServer into ExtensionTestSupport for reuse. Review noted a follow-up: implementing menuHasKeyEquivalent(_:for:target:action:) would stop the per-keypress rebuild entirely, but needs the Spaces menu's static shortcuts handled — not filed. AC #4 is a manual check with 1Password locked.

Follow-up after the full suite: the integration test's popup web view lives in the extension controller's own configuration, and releasing the test profile in tearDown freed that WKProcessPool from inside an IPC dispatch — WebKit traps in MessageReceiverMap::invalidate (~WebProcessPool) and the test host crashed in the next suite (ExtensionPageFavoriteTests), so xcodebuild reported TEST FAILED with 0 failures and ~100 tests skipped. The test now closes the popup (action.closePopup()) and retains torn-down profiles for the life of the test process. Full suite: 991 tests, 0 failures.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Extensions menu no longer instantiates popup web views: the enabled/disabled decision uses action.presentsPopup (through ExtensionMenuPopupDecision) plus the manifest default_popup, so 1Password's popup page is not loaded (and no unlock prompt fires) until the user opens the popup. Verified with ExtensionMenuPopupDecisionTests (6 tests incl. a loopback beacon integration test), WKExtensionIntegrationTests and NewProfileExtensionLoadTests passing; AC #4 (real 1Password) left for manual verification.
<!-- SECTION:FINAL_SUMMARY:END -->
