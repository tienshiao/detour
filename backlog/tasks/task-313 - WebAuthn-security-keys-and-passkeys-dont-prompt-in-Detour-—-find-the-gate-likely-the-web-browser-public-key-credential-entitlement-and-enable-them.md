---
id: TASK-313
title: >-
  WebAuthn: security keys and passkeys don't prompt in Detour — find the gate
  (likely the web-browser public-key-credential entitlement) and enable them
status: To Do
assignee: []
created_date: '2026-11-09T09:11:00Z'
labels:
  - webauthn
  - signing
dependencies: []
priority: medium
ordinal: 375000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The user's USB security key did not work on a site that asks for one: Detour did not appear to start the ceremony at all (no system sheet, no key blink).

Detour has no WebAuthn code; WKWebView handles navigator.credentials itself. In current WebKit (Source/WebKit/UIProcess/WebAuthentication/Cocoa/WebAuthenticatorCoordinatorProxy.mm) the UI process (Detour's own process) builds an ASAuthorizationController with a platform (passkey) request and a security-key request and lets AuthenticationServices show the system sheet. Most failures come back to the page as NotAllowedError with an empty message, so a page sees an instant failure.

Hypothesis, not yet measured: AuthenticationServices only accepts a relying party the app is associated with (Associated Domains) unless the app holds the managed entitlement com.apple.developer.web-browser.public-key-credential (macOS 13.3+, granted by Apple on request to browser apps). Detour.entitlements has only keychain-access-groups, so every site would be refused before any UI appears. That would match 'it didn't even try', and would affect passkeys as well as security keys.

Related: TASK-5 (1Password's passkey interception, which is the extension path, not the system one).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Measured on webauthn.io in an isolated Detour build: what navigator.credentials.create/get returns (error name and message), and what the WebAuthn / AuthenticationServices log lines say (log stream with --predicate on the Detour process), recorded in the task
- [ ] #2 The gate is identified with evidence (missing entitlement, a WebKit preference, a WKUIDelegate hook, or something else), with the WebKit or Apple source that shows it
- [ ] #3 If it is the entitlement: the request to Apple is written up for the user to submit, and the entitlement plus provisioning-profile changes are ready in project.yml / Detour.entitlements / the release scripts, without breaking Debug builds that lack the profile
- [ ] #4 With the gate removed, registering and signing in with a USB security key works on webauthn.io in a signed build, and a platform passkey (iCloud Keychain) does too, in a normal profile and in a Private window
- [ ] #5 A Quarantine window either supports WebAuthn or refuses it on purpose, and the choice is recorded
- [ ] #6 Wiki page on how WebAuthn reaches the system in Detour (the gate, the entitlement, how to verify), linked from wiki/index.md
<!-- AC:END -->
