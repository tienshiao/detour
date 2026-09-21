---
id: TASK-101
title: >-
  Extensions: 1Password's inline menu does not open from a form inside a
  cross-origin iframe
status: To Do
assignee: []
created_date: '2026-09-21 08:12'
labels:
  - extensions
  - 1password
  - bug
dependencies:
  - TASK-4
documentation:
  - docs/1password-integration-plan.md
priority: medium
ordinal: 101000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by TASK-4 in the signed build on 2026-09-21 (761c4b6, 1Password 8.12.26.40). Fixture: top page http://127.0.0.1:8471/ embedding a login form from http://localhost:8472/ in an iframe. 1Password's content script runs in the cross-origin frame and draws its control inside the username input, but clicking the control does nothing — no inline menu. The same control on the top-level form of the same page opens the menu ('No items to show'), so the worker, native messaging and the port-pattern rewrite (TASK-75) are fine. Not yet diagnosed. Suspects, in order: (1) the inline menu is an extension-page iframe (web_accessible_resources, webkit-extension://…) that the content script inserts into the page — in a cross-origin subframe WebKit may refuse to load it, or its 'inline-menu/<id>' runtime port never connects (the worker logs '[PortManager] inline-menu/… opened from peer' for the working case; compare); (2) frame-targeted messaging: the worker positions/opens the menu via tabs.sendMessage(tabId, msg, {frameId}) or asks the TOP frame to host the menu and needs the subframe's offset — check sender.frameId / getFrame parentFrameId for the cross-origin frame and whether the top frame's script receives the request; (3) permissions.contains for the frame's origin (http://localhost:8472/* → rewritten to http://localhost/*) answering false because only the top page's host was granted. Reproduce with ExtensionConsoleLogPublic set, click the control in the iframe and read the worker + WebKit Extensions log for the 2 s after the click; a default-port fixture (two hostnames on :80 are not available locally, so use the rewrite) is fine. This task diagnoses and fixes; if the cause is in WebKit and cannot be worked around, record that and close.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The cause is identified with log evidence from a click on the control in the cross-origin iframe (what 1Password sends, what arrives, what WebKit rejects) and recorded in docs/1password-integration-plan.md
- [ ] #2 A test reproduces the underlying mechanism with a probe extension (cross-origin subframe content script: port/message to the worker, frame-targeted reply, and loading a web-accessible extension page inside that subframe), with a negative control
- [ ] #3 If the fix touches extension permissions or host access, positive and negative permission tests are added; API Explorer covers any API whose behaviour changed
- [ ] #4 Signed build: clicking the 1Password control in the fixture's cross-origin iframe opens the inline menu
<!-- AC:END -->
