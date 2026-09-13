---
id: TASK-56
title: >-
  Extensions: implement menuHasKeyEquivalent so key presses stop rebuilding the
  Spaces, Extensions and Develop menus
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 17:31'
updated_date: '2026-09-13 18:25'
labels:
  - extensions
  - menus
  - performance
dependencies: []
priority: low
ordinal: 56000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the TASK-55 review. AppDelegate is the NSMenuDelegate for the Spaces, Extensions and Develop menus (AppDelegate.swift, mainMenu setup ~319-360; menuNeedsUpdate ~442). Because the delegate does not implement menuHasKeyEquivalent(_:for:target:action:), AppKit calls menuNeedsUpdate on all three menus for every key-equivalent dispatch (every Cmd+key press in every window), not only when a menu opens. Each rebuild re-enumerates spaces, re-queries ExtensionManager.enabledExtensions(for:) per profile, redraws the extension icon images, and calls action(for: nil) on every extension context. TASK-55 removed the dangerous side effect (loading popup web views) but the rebuild itself remains: an O(extensions + spaces) menu rebuild per keystroke, and any future menu item whose enable decision touches WebKit state will re-open the same hole.

Implementing menuHasKeyEquivalent lets the delegate answer the key-equivalent query directly and skip the rebuild. The catch is the static shortcuts that live in these menus and must keep working: Spaces has Next Space / Previous Space (Cmd+Option+Right/Left arrows, F703/F702 with keyEquivalentModifierMask) and Develop has Web Inspector (Cmd+Option+I); the dynamic space/extension items have no key equivalents. The implementation should match the event against the static items only (walk menu.items, compare keyEquivalent + keyEquivalentModifierMask against the NSEvent, set target/action out-params) and return false otherwise, so the dynamic rebuild happens only when the menu actually opens. Note that returning false from menuHasKeyEquivalent tells AppKit no item in that menu matches, so an incomplete static match silently breaks a shortcut.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Pressing a Cmd+key shortcut (e.g. Cmd+T, Cmd+W) no longer triggers menuNeedsUpdate / updateSpacesMenu / updateExtensionsMenu / updateDevelopMenu; opening a menu still rebuilds it
- [x] #2 Next Space, Previous Space and Web Inspector shortcuts still dispatch to the key window controller with the same modifiers as before, and stay disabled when no browser window is key
- [x] #3 The Spaces menu still shows the current spaces with the active one checked, and the Extensions menu still lists the active profile extensions, when opened after spaces or extensions change
- [x] #4 Unit test covers the key-equivalent matcher for a static item hit, a modifier mismatch, and a key with no match; the TASK-55 ExtensionMenuPopupDecision tests keep passing
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add a pure matcher (Detour/App/MenuKeyEquivalentMatcher.swift): given an NSEvent and a list of NSMenuItems, return the static item whose keyEquivalent + keyEquivalentModifierMask match the event (compare charactersIgnoringModifiers case-insensitively where AppKit does, and the device-independent modifier flags), skipping separators, hidden items, and items with a nil action.
2. AppDelegate (NSMenuDelegate) implements menuHasKeyEquivalent(_:for:target:action:): run the matcher over menu.items; on a hit resolve the target via NSApp.target(forAction:to:from:), validate through NSMenuItemValidation when the target implements it (BrowserWindowController.validateMenuItem gates nextSpace/previousSpace), set target/action out-params and return true; otherwise return false without calling menuNeedsUpdate. The dynamic space/extension/inspector items carry no key equivalents so they never need to exist for dispatch.
3. Note in menuNeedsUpdate that it now runs only when a menu opens.
4. Tests: MenuKeyEquivalentMatcherTests covering a static hit (Cmd+Option+I, Cmd+Option+Right arrow), a modifier mismatch, a key with no match, and that separators/action-less items never match. Run ExtensionMenuPopupDecisionTests to confirm the menu decision still holds.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Code review of 416c0e0 (HEAD~1..HEAD, high effort, --fix). Empirical AppKit probe (Darwin 25.6, standalone binaries, production menu-bar shape with autoenablesItems on): a delegate that answers false from menuHasKeyEquivalent is NOT vetoing the menu — AppKit skips menuNeedsUpdate (the TASK-56 goal holds) but still scans the existing items itself, with its own layout handling, validation and submenu recursion. So the matcher is a fast path, not the sole path; a hit is dispatched without AppKit validating, a miss falls back to AppKit. The commit's comments and the test header encoded the opposite contract and were rewritten. Fixes applied: (1) the Develop menu no longer has a delegate — its inspector items are rebuilt from extensionsDidChangeNotification (every mutation path posts it) and once at setup — so the only letter shortcut (Cmd+Option+I) is matched natively by AppKit on every layout and OS; the delegate-driven menus now hold only the F702/F703 arrow equivalents, which the matcher handles exactly. (2) menuHasKeyEquivalent's true path now mirrors AppKit's tiered enable decision (validateMenuItem, else validateUserInterfaceItem, else isEnabled when autoenablesItems is off). (3) Stale TASK-55 comment in ExtensionMenuPopupDecision.swift and the 'rebuild only on open' wording corrected. (4) New tests against the real NSApp.mainMenu: only Spaces/Extensions are delegate-driven, Develop has no delegate and keeps Web Inspector, and after a rebuild every shortcut in a delegate-driven menu is a static Command-bearing function key the matcher answers (no dynamic item may carry one: it would exist only after a first open and be dispatched without an NSMenuItem sender). Residual: whether macOS 14/15 also fall back after a false is unverified (the matcher stays as insurance); after an install the Develop item title uses the manifest name until the next extensionsDidChange post, since wkExtension loads after that post. Efficiency claims about the per-keystroke scan were refuted by measurement (~6 µs/keystroke; consumed keystrokes never reach the menu search). Verified: xcodebuild test -only-testing MenuKeyEquivalentMatcherTests (15) + ExtensionMenuPopupDecisionTests (6): 21 passed, 0 failures.

Review (code-review --fix): probes compiled against this macOS (Darwin 25.6) showed a false from menuHasKeyEquivalent is not a veto: AppKit skips menuNeedsUpdate (the optimisation holds) but still scans the existing items itself, while a true is dispatched with no AppKit validation. Fixes folded into the commit: the Develop menu is no longer delegate-driven (rebuilt on extensionsDidChangeNotification, so Cmd+Option+I is matched natively on every keyboard layout); matcher hits validate through NSMenuItemValidation, NSUserInterfaceValidations or isEnabled mirroring AppKit tiers; comments state the verified contract; three tests run against the real main menu and pin the invariant that delegate-driven menus carry only static function-key shortcuts. AC #1-#3 rest on the AppKit probes plus the real-menu tests, not a manual app run.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
AppDelegate answers key equivalents for the Spaces and Extensions menus through menuHasKeyEquivalent with a pure MenuKeyEquivalentMatcher, so a Cmd+key press no longer rebuilds them; the Develop menu is static and rebuilt from extensionsDidChangeNotification. Verified with MenuKeyEquivalentMatcherTests (15) and ExtensionMenuPopupDecisionTests (6): 21 passed.
<!-- SECTION:FINAL_SUMMARY:END -->
