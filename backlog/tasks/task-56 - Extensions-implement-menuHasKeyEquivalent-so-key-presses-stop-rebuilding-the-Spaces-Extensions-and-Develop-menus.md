---
id: TASK-56
title: >-
  Extensions: implement menuHasKeyEquivalent so key presses stop rebuilding the
  Spaces, Extensions and Develop menus
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-13 17:31'
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
- [ ] #1 Pressing a Cmd+key shortcut (e.g. Cmd+T, Cmd+W) no longer triggers menuNeedsUpdate / updateSpacesMenu / updateExtensionsMenu / updateDevelopMenu; opening a menu still rebuilds it
- [ ] #2 Next Space, Previous Space and Web Inspector shortcuts still dispatch to the key window controller with the same modifiers as before, and stay disabled when no browser window is key
- [ ] #3 The Spaces menu still shows the current spaces with the active one checked, and the Extensions menu still lists the active profile extensions, when opened after spaces or extensions change
- [ ] #4 Unit test covers the key-equivalent matcher for a static item hit, a modifier mismatch, and a key with no match; the TASK-55 ExtensionMenuPopupDecision tests keep passing
<!-- AC:END -->
