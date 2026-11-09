---
id: TASK-313
title: >-
  WebAuthn: security keys and passkeys don't prompt in Detour — find the gate
  (likely the web-browser public-key-credential entitlement) and enable them
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-09T09:11:00Z'
updated_date: '2026-11-09T09:18:00Z'
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
- [x] #1 Measured on webauthn.io in an isolated Detour build: what navigator.credentials.create/get returns (error name and message), and what the WebAuthn / AuthenticationServices log lines say (log stream with --predicate on the Detour process), recorded in the task
- [x] #2 The gate is identified with evidence (missing entitlement, a WebKit preference, a WKUIDelegate hook, or something else), with the WebKit or Apple source that shows it
- [ ] #3 If it is the entitlement: the request to Apple is written up for the user to submit, and the entitlement plus provisioning-profile changes are ready in project.yml / Detour.entitlements / the release scripts, without breaking Debug builds that lack the profile
- [ ] #4 With the gate removed, registering and signing in with a USB security key works on webauthn.io in a signed build, and a platform passkey (iCloud Keychain) does too, in a normal profile and in a Private window
- [ ] #5 A Quarantine window either supports WebAuthn or refuses it on purpose, and the choice is recorded
- [ ] #6 Wiki page on how WebAuthn reaches the system in Detour (the gate, the entitlement, how to verify), linked from wiki/index.md
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. User: confirm the developer account type. The entitlement request form requires the Account Holder of an organization account. Then submit the request at https://developer.apple.com/contact/request/macos-browsers-passkeys/ (draft text to be written by Claude).
2. User: register the explicit App ID com.detourbrowser.mac and create a Developer ID provisioning profile for it, adding the managed capability once Apple grants it.
3. Release signing: build-release.sh embeds the profile as Contents/embedded.provisionprofile and signs with a release entitlements file that has com.apple.application-identifier, com.apple.developer.team-identifier, the browser entitlement and an expanded (or removed) keychain group. Debug builds keep working without the profile.
4. Verify in a signed build with the spike, then Detour: a USB key and an iCloud passkey on webauthn.io in a normal profile and in Private. Decide Quarantine.
5. Wiki page, release note.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Findings (2026-11-09)

**Measured.** The system log holds the user's real attempts in production Detour (/Applications/Detour.app, pid 39802, 2026-11-09 00:55:40 to 00:57:44, 8 requests). Every one was refused by AuthenticationServicesAgent before any UI:
```
AuthenticationServicesAgent [com.apple.Safari:Authorization] Attempted to perform authorization from process without application identifier.
Detour [com.apple.Safari:Authorization] ASAuthorizationController credential request failed with error: Error Domain=com.apple.AuthenticationServices.AuthorizationError Code=1004
```
WebKit maps 1004 to NotAllowedError with an empty message, so the page fails at once: the 'didn't even try' symptom. A standalone WKWebView spike (docs/harness/task313-webauthn-spike.swift, ad-hoc signed .app with a bundle ID) reproduces it on webauthn.io: platform create fails after 130 ms, cross-platform (security key) create after 6 ms, both with the same two log lines. Query: `log show --predicate 'subsystem == "com.apple.Safari" AND category == "Authorization"'` (sandbox off).

**Gate 1: no application identifier.** scripts/build-release.sh re-signs the app with Developer ID straight from Detour/Resources/Detour.entitlements. There is no provisioning profile in the bundle, so the signature carries no com.apple.application-identifier / com.apple.developer.team-identifier. Side finding: the shipped keychain-access-groups value is the literal string `$(AppIdentifierPrefix)com.detourbrowser.mac` (codesign does not expand Xcode variables). No Swift code uses the keychain; the entitlement dates from b3c7505 (1Password bring-up).

**Gate 2: the browser entitlement (from source and docs, not yet measured).** WebKit (WebAuthenticatorCoordinatorProxy.mm, HAVE(WEB_AUTHN_AS_MODERN) on macOS) builds ASAuthorizationPlatform/SecurityKeyPublicKeyCredentialProvider requests with createCredential*RequestWithClientData:, the browser form of the API. Apple's docs: com.apple.developer.web-browser.public-key-credential (macOS 13.3+) 'lets your app make registration and assertion requests for passkeys and security keys for any relying party identifier'. It is a managed capability: the Account Holder of an organization's developer account requests it at https://developer.apple.com/contact/request/macos-browsers-passkeys/, and Apple reviews it (the app must declare http/https in Info.plist, open with a URL field, and load URLs as given). Without it, an app with an application identifier can only use RPs in its Associated Domains (webcredentials:), so fixing gate 1 alone gives users nothing.

**No way around it in WebKit.** The legacy path (WebAuthenticationASEnabled off, HAVE(UNIFIED_ASC_AUTH_UI)) also goes through ASCAgentProxy, so the same agent checks apply. WebKit's own CTAP-over-HID stack is reachable only through the private _WKWebAuthenticationPanel SPI, with Detour intercepting navigator.credentials in page JS. That would cover USB keys only, rest on SPI, and was not tried; rejected unless Apple refuses the entitlement.

**Could not test gate 2 locally.** The only Mac profile on disk (wildcard F392Y686HF.*, team 58MN2R524R) lists only expired development certificates, so the spike signed with the current Apple Development certificate was refused at launch.
<!-- SECTION:NOTES:END -->
