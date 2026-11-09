---
id: TASK-313
title: >-
  WebAuthn: security keys and passkeys don't prompt in Detour — find the gate
  (likely the web-browser public-key-credential entitlement) and enable them
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-09T09:11:00Z'
updated_date: '2026-11-09T09:42:00Z'
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

## Gate 1 fixed (2026-11-09)

The user has an individual developer account (the entitlement form asks for an organization's Account Holder), so gate 2 is on hold; the user asked to fix gate 1.

- User registered the explicit App ID com.detourbrowser.mac and made a Developer ID profile ('Detour Developer ID', expires 2044-11-04, lists the Developer ID Application certificate A7A97209…, which itself expires 2027-02-01: renewing it means regenerating the profile). Committed at signing/Detour_Developer_ID.provisionprofile.
- New scripts/sign-app.sh, used by build-release.sh and deploy-1password-test.sh. It checks the profile (explicit App ID, team, ProvisionsAllDevices, expiry, the signing certificate listed, every entitlement granted), signs Sparkle's helpers first by Sparkle's recipe, embeds the profile, and signs the app with com.apple.application-identifier and team-identifier plus the expanded keychain group. --check mode runs before build-release.sh bumps the version. It replaces codesign --deep --entitlements, which had stamped Detour's keychain entitlement on Autoupdate, Updater.app, Downloader.xpc and Installer.xpc in every release.
- /code-review --fix: 8 findings, 6 fixed. The identifier post-check was vacuous because the keychain group is the same string; identity choice when two certificates share a name; the early check now validates the profile, not just that the file exists; relative app path; locale-dependent expiry parse; pipefail/SIGPIPE in the checks; find on a missing Frameworks folder. Skipped: Downloader.xpc keeps the entitlements of an already --deep-signed input (a release always builds clean, and the post-check stops loudly).

**Verified:**
- Refusals: missing profile, the wildcard dev profile, an iOS profile.
- A clean Release build (private DerivedData) signed with sign-app.sh: application identifier and team ID in the signature; Sparkle's helpers have no Detour entitlements; Autoupdate keeps the identifier 0.4.0 shipped; Gatekeeper (spctl, unnotarized) accepts; the app launches with DETOUR_DATA_DIR and runs (twice, before and after the review fixes). Defaults keys and data dir removed after.
- The spike, signed as com.detourbrowser.mac with the profile: gate 1 passes; the agent now logs 'Client tried to use web-browser-only options.', 'Application with identifier 58MN2R524R.com.detourbrowser.mac is not associated with domain webauthn.io', 'Client is not properly entitled for this request. Rejecting.' Gate 2 is measured.

**Not verified:** a notarized DMG and a Sparkle update from a profile-signed build. The next release is the first; check that 0.4.2 updates to it and that the updated app can update again.

**Remaining:** gate 2. Options: the request form (the docs ask for an organization account, so an individual account may be refused or may need enrolling as an organization, which needs a D-U-N-S number), or the _WKWebAuthenticationPanel SPI fallback for USB keys only.

2026-11-09: the user's deploy-1password-test.sh run (incremental Release build, so the 0.4.2 app's --deep-signed helpers) stopped at the post-check: Downloader.xpc carried Detour's entitlements via --preserve-metadata=entitlements (the review's skipped finding 8). Fix: every Sparkle helper is now signed with no entitlements (the artifact's Downloader.xpc has an empty set; Detour is not sandboxed). A copy of that exact build now signs cleanly, with empty entitlements on all four helpers.
<!-- SECTION:NOTES:END -->
