---
id: TASK-303
title: >-
  1Password: does it connect in Detour on a Mac where Chrome was never
  installed?
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-08T09:35:00Z'
updated_date: '2026-11-08T10:23:00Z'
labels:
  - extensions
  - 1password
  - investigation
dependencies: []
references:
  - TASK-292.8
priority: medium
ordinal: 364000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Detour finds a native messaging host by its manifest in four places (NativeMessagingHost.swift ~88-93): ~/Library/Application Support/Google/Chrome/NativeMessagingHosts, …/Chromium/NativeMessagingHosts, …/Detour/NativeMessagingHosts, and /Library/Google/Chrome/NativeMessagingHosts. 1Password works in Detour because the 1Password desktop app writes com.1password.1password.json into Chrome's folder. Nobody has checked whether 1Password writes that file when Chrome is not (and never was) installed. If it doesn't, the extension installs but never reaches the desktop app on such a Mac, and the website's Web Extensions page ("1Password works", TASK-292.8) is wrong for those people. Raised while writing that page (Nov 8 2026).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Determined on a Mac (or clean user account / VM) with no Chrome or Chromium ever installed: whether the 1Password desktop app writes a native messaging manifest anywhere Detour looks, and what Detour shows when it doesn't
- [x] #2 If it doesn't: a fix is agreed with the user (for example Detour installing or linking the manifest into its own NativeMessagingHosts folder, or a clear in-app explanation), filed as its own task
- [x] #3 The website's Web Extensions page states the requirement accurately
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026 (lead, static investigation on this Mac, 1Password 8 app in /Applications):
- 1Password's native-messaging installer (op-nm-installer, Rust, in Contents/Frameworks/index.node) carries a fixed list of manifest folders under ~/Library/Application Support: Mozilla, Google/Chrome, Google/Chrome Beta, Google/Chrome Canary, Google/Chrome Dev, Microsoft Edge (+ Beta, Canary, Dev), Vivaldi, Vivaldi Snapshot, Arc/User Data. Not in the list: Chromium, BraveSoftware (Chromium/NativeMessagingHosts here has only Claude Code's manifest).
- It writes to every folder in the list whether or not that browser is installed, creating the whole path: 'Vivaldi Snapshot/' was created on Nov 5 2026 14:15 holding only NativeMessagingHosts/com.1password.1password.json (same timestamp as the rewrite of every other manifest that day), and Vivaldi Snapshot was never installed (no bundle com.vivaldi.Vivaldi.snapshot anywhere per mdfind). Same for Microsoft Edge, Edge Beta/Canary/Dev, Vivaldi and Google/Chrome Canary/Dev: folders created Apr 17 2023 with nothing but NativeMessagingHosts, none of those browsers installed.
- Conclusion: on a Mac without Chrome, 1Password still writes ~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.1password.1password.json, the first folder Detour searches (NativeMessagingHost.swift ~90), so the extension reaches the desktop app. No Detour fix needed (AC #2 does not arise).
- If the manifest were missing, Detour's connectNative/sendNativeMessage fail with Chrome's 'Specified native messaging host not found.' (NativeMessagingError.manifestNotFound, ~1048-1057); there is no in-app explanation.
- Website (AC #3): the Web Extensions page states the real requirements (1Password app for Mac running, Detour added in its Settings › Browser) and does not claim Chrome is needed: accurate, no change.
- Not done: the literal clean-account check of AC #1 (a new macOS user with no Chrome, install 1Password, look for the file). The evidence above is from this Mac's history, not a clean account. Quick user check if wanted: new standard user, install 1Password, open it once, ls ~/Library/Application\ Support/Google/Chrome/NativeMessagingHosts.
<!-- SECTION:NOTES:END -->
