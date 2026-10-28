---
id: TASK-224
title: >-
  Extensions: a normal-profile extension not allowed in Private can still open a
  Private window with windows.create({incognito: true})
status: To Do
assignee: []
created_date: '2026-10-28T07:56:00Z'
labels:
  - extensions
  - private
dependencies: []
references:
  - wiki/extensions/tab-and-window-bridge.md
  - wiki/extensions/private-profile-extensions.md
  - TASK-214
  - TASK-74
priority: low
ordinal: 260000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in TASK-214 (2026-10-28). ExtensionManager.opensPrivateWindow returns true whenever the call asks for incognito, whatever the extension's Private setting, so an extension the user has not allowed in Private (no profileExtension row for the incognito profile, see TASK-74) opens a Private window at an address of its choosing. WebKit reports the window only to contexts with access to Private data, so the caller gets undefined back and cannot see or script the window; the harm is that an extension the user kept out of Private can still put pages in front of them there. Chrome refuses windows.create({incognito: true}) from an extension without incognito access.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 windows.create({incognito: true}) from an extension not allowed in Private is refused with an error and opens no window, from both transports, as a promise rejection and as runtime.lastError
- [ ] #2 The same call from an extension allowed in Private still opens a Private window
- [ ] #3 The API Explorer's Create Private button shows the refusal when the extension is not allowed in Private
- [ ] #4 wiki/extensions/tab-and-window-bridge.md and wiki/extensions/private-profile-extensions.md record the rule
<!-- AC:END -->
