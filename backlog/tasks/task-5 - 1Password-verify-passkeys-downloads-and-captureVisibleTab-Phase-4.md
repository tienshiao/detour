---
id: TASK-5
title: '1Password: verify passkeys, downloads and captureVisibleTab (Phase 4)'
status: To Do
assignee: []
created_date: '2026-09-11 22:28'
labels:
  - 1password
  - extensions
dependencies:
  - TASK-2
documentation:
  - docs/1password-integration-plan.md
priority: low
ordinal: 5000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Verification pass once the service worker is stable. MAIN-world injection of inline/injected/webauthn-listeners.js appears to work (a [Webauthn] _handleGetCredential log line fired on 2026-09-11) but has not been confirmed on a real passkey flow. downloads.download/onChanged are used only for export flows. tabs.captureVisibleTab is used for on-screen QR code scanning. Basic-auth fill via webRequest.onAuthRequired asyncBlocking is out of scope: WebKit has no blocking request interception.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Signing in with a passkey on a passkey-enabled site (e.g. webauthn.io) goes through 1Password rather than the OS dialog
- [ ] #2 Exporting an item from the 1Password popup produces a file via chrome.downloads, or the gap is documented in the plan
- [ ] #3 Scanning a QR code shown on a page from the 1Password popup works, or the gap is documented in the plan
<!-- AC:END -->
