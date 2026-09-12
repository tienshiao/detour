---
id: TASK-6
title: >-
  1Password: test whether a Developer ID Debug build is trusted by
  BrowserSupport
status: To Do
assignee: []
created_date: '2026-09-11 22:28'
updated_date: '2026-09-12 00:33'
labels:
  - 1password
  - dev-loop
dependencies: []
documentation:
  - docs/1password-integration-plan.md
priority: low
ordinal: 6000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The iteration loop today is scripts/deploy-1password-test.sh: Release build, sign, copy to /Applications, relaunch. project.yml already signs the Debug configuration with the same Developer ID identity and hardened runtime, and 1Password's trust record (settings.json, browsers.other-trusted-apps) is keyed by bundle id but stores the path /Applications/Detour.app. Unknown whether BrowserSupport (browser_verification/apple.rs) accepts a Debug build running from DerivedData at a different path. If it does, the Release build and copy can be dropped from the loop and 1Password can be tested straight from Xcode. BrowserSupport logs per host process live under ~/Library/Group Containers/2BUA8C4S2C.com.1password/Library/Application Support/1Password/Data/logs/BrowserSupport/ (grep for Detour).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Documented result in docs/1password-integration-plan.md: whether a Debug build launched from DerivedData connects to 1Password, and what BrowserSupport logged for the verification
- [ ] #2 If trusted, scripts/deploy-1password-test.sh or CLAUDE.md describes the faster loop
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-09-11 data point (obtained during TASK-2 work): a Debug build of HEAD running from DerivedData (Developer ID signed, hardened runtime per project.yml) is NOT trusted. BrowserSupport log 1Password_rCURRENT.log: 'Verifying browser "/Users/.../Library/Developer/Xcode/DerivedData/Detour-.../Build/Products/Debug/Detour.app/..."' -> 'parent browser was not valid' (browser_verification/apple.rs:53) -> 'Browser support error: UnsupportedBrowser'. Detour's side logs 'Connected to native host' and sends the first frame before the host exits. Still untested: the same Debug configuration copied to /Applications/Detour.app (separates the path check from the configuration check), and whether the trust record path is what matters. TASK-7 (dev bridge) remains relevant unless that variant passes.
<!-- SECTION:NOTES:END -->
