---
id: TASK-339
title: >-
  Extensions settings: every permission has a readable name (no raw 'privacy' or
  'favicon')
status: Done
assignee:
  - '@claude'
created_date: '2026-11-15T05:14:00Z'
updated_date: '2026-11-15T05:31:00Z'
labels:
  - extensions
  - settings
dependencies: []
references:
  - TASK-338
  - Detour/Browser/Settings/ExtensionsSettingsViewController.swift
  - wiki/extensions/permissions.md
priority: low
type: bug
ordinal: 414000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-338's captures: the Extensions pane lists API Explorer's permissions with readable names ("Store data locally", "Read your browsing activity"), except two that show the raw manifest name, "privacy" and "favicon". The permission-to-text table has no entry for them, and any other unmapped permission would show the same way.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 "privacy" and "favicon" show readable names in the Extensions pane, worded like the others
- [x] #2 Every permission Detour knows about (the manifest permissions the polyfill and WebKit support) has an entry, checked by a test that walks the known list
- [x] #3 An unknown permission still shows something readable (its name, made legible) rather than nothing; tests cover it
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add readable names for privacy, favicon and background (the known permissions without one), worded like the others.
2. describe() falls back to the name made legible (camelCase and dots split, sentence case) for UI; management.getPermissionWarningsByManifest keeps returning the raw name for an unknown permission (its tested behaviour).
3. Test: every known permission (WebKit's WKWebExtension.Permission constants, the polyfill's and stubbed ones, background) has its own entry; the fallback for unknown names; the API output unchanged.
4. Runtime: the Extensions pane with API Explorer shows the new names; wiki permissions page; commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Added readable names for the known permissions that lacked one: privacy ('Read and change privacy settings'), favicon ('Read the icons of websites') and background ('Run in the background'). describe() falls back to the name made legible (camelCase, dots and underscores split, sentence case, acronyms kept: tabGroups 'Tab groups', readURLs 'Read URLs'), used by the Extensions pane, the install, update and request prompts. management.getPermissionWarningsByManifest keeps an unknown permission's manifest name, as ExtensionManagementSelfTests expects. Tests: ExtensionPermissionDescriptionsTests (4, new: every known permission — WebKit's 16 WKWebExtension.Permission constants, the polyfill's and stubbed ones, background, 27 in all — has its own description; privacy and favicon; the fallback; the API output) and ExtensionManagementSelfTests: 16 tests, 0 failures; with the Settings and extension suites 193 tests, 0 failures. Runtime (DetourVerify-340-*, removed): API Explorer's switches in Settings > Extensions read 'Read and change privacy settings' and 'Read the icons of websites' through Accessibility, 0 unnamed. Review (code-review medium, shared run with TASK-340 and the icon change): acronyms now kept in the fallback; separators-only names left as they are.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Every permission Detour knows has a readable name in Settings and the prompts (privacy, favicon, background added), and an unknown one reads as its name in words instead of the raw manifest string; the extension API's warnings keep returning an unknown name as before. Tested by walking the known permissions.
<!-- SECTION:FINAL_SUMMARY:END -->
