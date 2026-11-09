---
type: Platform Quirk
title: WebAuthn goes through AuthenticationServices
description: Why security keys and passkeys fail instantly in a WKWebView browser — WebKit hands every navigator.credentials request to AuthenticationServicesAgent, which refuses an app without an application identifier (fixed for Detour with a Developer ID provisioning profile) and then any relying party the app is not associated with unless Apple grants the managed com.apple.developer.web-browser.public-key-credential entitlement; the log lines for each gate, the spike that measures them, and what was ruled out.
tags: [webkit, webauthn, passkeys, signing, entitlements]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-09T09:40:00Z }
stale_after: 2027-05-01T00:00:00Z
sources:
  - id: task-313
    resource: backlog:TASK-313
    title: "WebAuthn: security keys and passkeys don't prompt in Detour"
  - id: coordinator
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebAuthentication/Cocoa/WebAuthenticatorCoordinatorProxy.mm
    title: WebAuthenticatorCoordinatorProxy.mm (performRequest, constructASController, the error mapping)
  - id: platform-have
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WTF/wtf/PlatformHave.h
    title: PlatformHave.h (HAVE_WEB_AUTHN_AS_MODERN, HAVE_UNIFIED_ASC_AUTH_UI on macOS)
  - id: entitlement
    resource: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential
    title: com.apple.developer.web-browser.public-key-credential
  - id: request-form
    resource: https://developer.apple.com/contact/request/macos-browsers-passkeys/
    title: Apple's request form for the macOS browser passkeys entitlement
  - id: spike
    resource: ../../docs/harness/task313-webauthn-spike.swift
    title: WebAuthn spike (a WKWebView app that calls navigator.credentials on webauthn.io)
  - id: sign-app
    resource: ../../scripts/sign-app.sh
    title: sign-app.sh (the profile checks and inside-out signing)
---

A page's `navigator.credentials.create()` or `.get()` in a WKWebView never
reaches a USB key or the iCloud Keychain on its own. WebKit's UI-process half
(running in Detour's own process) builds an `ASAuthorizationController` with a
platform (passkey) request and a security-key request and lets
AuthenticationServices show the system sheet.[^coordinator] On macOS both of
WebKit's paths do this: the modern one (`HAVE(WEB_AUTHN_AS_MODERN)`, preference
`WebAuthenticationASEnabled`, on by default) and the legacy one behind it
(`ASCAgentProxy`).[^platform-have] So whatever AuthenticationServicesAgent
decides about the *app* decides every page's ceremony, and no WebKit
preference gets around it.

# The two gates

The agent checks the calling process before it shows anything. A refusal
comes back as `ASAuthorizationError` 1004, which WebKit turns into a
`NotAllowedError` with its generic message, within a few milliseconds. To the
user, the browser "didn't even try".

| Gate | Log line (subsystem `com.apple.Safari`, category `Authorization`) | What passes it |
|---|---|---|
| 1. An application identifier | `Attempted to perform authorization from process without application identifier.` | `com.apple.application-identifier` in the signature, which a Developer ID app gets only from an embedded provisioning profile |
| 2. Any relying party | `Client tried to use web-browser-only options.` then `Application with identifier <id> is not associated with domain <rp>` and `Client is not properly entitled for this request. Rejecting.` | the managed entitlement `com.apple.developer.web-browser.public-key-credential`, or the site in the app's Associated Domains (`webcredentials:`), which a browser cannot list for the whole web |

The "web-browser-only options" are WebKit's: it builds its requests with
`createCredential…RequestWithClientData:` (it passes the page's origin and
challenge as `ASPublicKeyCredentialClientData`), the browser form of the
API.[^coordinator] Both gates were measured on webauthn.io for a security-key
registration and a passkey registration (TASK-313).[^task-313]

## Gate 1: the provisioning profile

Detour's releases were signed by `codesign` straight from
`Detour.entitlements`, with no profile, so they had no application identifier
(and shipped the keychain group as the literal, unexpanded
`$(AppIdentifierPrefix)com.detourbrowser.mac`). Since TASK-313,
`scripts/sign-app.sh` embeds a Developer ID profile for the explicit App ID
`com.detourbrowser.mac` as `Contents/embedded.provisionprofile` and adds
`com.apple.application-identifier` and `com.apple.developer.team-identifier`
from it.[^sign-app] The profile lives in `signing/`. Rules that came out of it:

* **Only the app gets Detour's entitlements.** `codesign --deep --entitlements`
  stamps them on every nested binary; with an application identifier in them,
  Sparkle's Autoupdate, Updater.app and XPC services would claim Detour's
  identity without a profile and macOS would refuse to launch them. Nested
  code is signed first, with no entitlements at all. Sparkle's recipe keeps
  Downloader.xpc's, but they are empty in the artifact (they matter only to a
  sandboxed app), and preserving them carried the old `--deep` entitlements
  over when an incremental build re-signed the previous release's app
  (`deploy-1password-test.sh` builds without `clean`). (Sparkle's artifact
  signs Autoupdate ad hoc with an application identifier of its own; that must
  not survive a Developer ID signature either.)
* **The profile lists the signing certificate.** A profile names the
  certificates it accepts. When the Developer ID Application certificate is
  renewed, the profile has to be regenerated with the new one, or the signed
  app does not launch. `sign-app.sh` compares the identity's SHA-1 against the
  profile and refuses before signing.
* **The profile spells the keychain entitlement `keychain-access-groups`**;
  `Detour.entitlements` spells it `com.apple.security.keychain-access-groups`.
  The script's check maps one to the other.

Gate 1 alone changes nothing a user can see: every site is then refused at
gate 2.

## Gate 2: the browser entitlement

Apple grants `com.apple.developer.web-browser.public-key-credential` (macOS
13.3+) on request, through a form, to the Account Holder of an
*organization* developer account, and reviews the app against browser
criteria: it declares the http and https schemes, offers a URL field or
search at launch, and loads a URL as given.[^entitlement][^request-form] Once
granted, it is a managed capability on the App ID, and a regenerated profile
carries it.

# Ruled out

* **A WebKit preference.** Turning `WebAuthenticationASEnabled` off selects
  the legacy path, which still goes through the same agent.
* **WebKit's own CTAP stack.** WebKit can talk to USB keys over HID itself,
  but only through the private `_WKWebAuthenticationPanel` SPI, with the app
  intercepting `navigator.credentials` in page script. It would cover
  security keys only (no passkeys) and rest on SPI. Not tried; kept as the
  fallback if the entitlement cannot be had.

# How to check

* **From the log**, after a failed attempt (sandbox off):
  `log show --last 1h --style compact --predicate 'subsystem == "com.apple.Safari" AND category == "Authorization"'`.
  The first error line names the gate.
* **With the spike**,[^spike] which needs no Detour build: compile it with
  `swiftc … -module-cache-path $TMPDIR/mc`, wrap it in an `.app` with a
  bundle ID (a bare binary has no identity at all), sign it, run it with the
  sandbox off and an argument `create` (passkey), `xplat` (security key) or
  `get`. It prints the page's result, error name and milliseconds. To test a
  profile, give the bundle the profile's bundle ID, embed the profile and
  sign with its certificate and an entitlements file holding its application
  and team identifiers. `get` reports `The document is not focused.` unless
  the window is frontmost.
* **The signed app launches**: run the signed Release build's binary with a
  `DETOUR_DATA_DIR` and check it is still running after a few seconds. A
  profile that does not match the signature kills it at launch.

# Related

- [Release and website playbook](../playbooks/release-and-website.md) — where `sign-app.sh` runs and the profile prerequisite.
- [Signed-build verification](../playbooks/signed-build-verification.md) — the test deployment, signed the same way.
- [WebKit source lookup](webkit-source-lookup.md) — how the WebKit sources above were read.

[^task-313]: WebAuthn: security keys and passkeys don't prompt in Detour
[^coordinator]: WebAuthenticatorCoordinatorProxy.mm (performRequest, constructASController, the error mapping)
[^platform-have]: PlatformHave.h (HAVE_WEB_AUTHN_AS_MODERN, HAVE_UNIFIED_ASC_AUTH_UI on macOS)
[^entitlement]: com.apple.developer.web-browser.public-key-credential
[^request-form]: Apple's request form for the macOS browser passkeys entitlement
[^spike]: WebAuthn spike (a WKWebView app that calls navigator.credentials on webauthn.io)
[^sign-app]: sign-app.sh (the profile checks and inside-out signing)
