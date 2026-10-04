---
type: Component
title: Extension installer and CRX handling
description: How an extension gets from a Chrome Web Store download or an unpacked folder into Detour's data directory — CRX3 unpacking, signature verification, Chrome-compatible id derivation, and what the installer records.
resource: ../../Detour/Extensions/Installer
tags: [extensions, install, crx, security]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:49:13Z }
sources:
  - id: installer
    resource: ../../Detour/Extensions/Installer/ExtensionInstaller.swift
    title: ExtensionInstaller.swift
  - id: unpacker
    resource: ../../Detour/Extensions/Installer/CRXUnpacker.swift
    title: CRXUnpacker.swift
  - id: verifier
    resource: ../../Detour/Extensions/Installer/CRX3Verifier.swift
    title: CRX3Verifier.swift
  - id: source
    resource: ../../Detour/Extensions/Model/ExtensionSource.swift
    title: ExtensionSource.swift
  - id: navigation
    resource: ../../Detour/Browser/Window/BrowserWindowController+Navigation.swift
    title: BrowserWindowController+Navigation.swift (CRX download interception)
  - id: database
    resource: ../../Detour/Storage/Database.swift
    title: Database.swift (migration v17)
  - id: task-113
    resource: backlog:TASK-113
    title: Check for and install extension updates
  - id: notes-updates
    resource: "Agent session notes, 2026-09-26 (not in the repository)"
    title: Extension updates — design decisions and what the real 1Password CRX taught
  - id: id-tests
    resource: ../../DetourTests/ExtensionIDDerivationTests.swift
    title: ExtensionIDDerivationTests
  - id: verifier-tests
    resource: ../../DetourTests/CRX3VerifierTests.swift
    title: CRX3VerifierTests
---

Installing an extension means producing a private copy of its files under
`<data>/Extensions/<id>/`, deciding its id, and writing an `extension` row.
Three types do it: `CRXUnpacker` opens a CRX3 file, `CRX3Verifier` checks its
signatures, and `ExtensionInstaller` copies and records. Loading the result
into WebKit is [ExtensionManager](./extension-manager.md)'s job.

# How it works

## Ways in

| Entry | Path |
|---|---|
| Chrome Web Store | A user script on `chromewebstore.google.com` (`Space.chromeWebStoreEarlyScript` and its DOM fallback) turns "Add to Chrome" into a navigation to the store's `update2/crx?response=redirect…` URL. `decidePolicyFor navigationResponse` cancels any response with MIME type `application/x-chrome-extension` or a `.crx` path and calls `handleCRXDownload`. |
| Any other `.crx` link | The same interception |
| Unpacked folder | Develop → Load Unpacked Extension…, or Settings → Extensions |
| Update, unpacked reload, staged update | [Updates](./updates.md) |

`handleCRXDownload` fetches the file itself with `URLSession` and a Chrome
user agent (it shows as a manual item in [Downloads](../features/downloads.md)),
unpacks it, shows the manifest's permissions in a confirmation alert, and only
then calls `ExtensionManager.install`.

## CRX3 layout

```
"Cr24" | version = 3 (LE32) | header length N (LE32) | N bytes of protobuf header | ZIP
```

The header (`CrxFileHeader`) carries RSA proofs in field 2 and ECDSA proofs in
field 3, each an `AsymmetricKeyProof { public_key, signature }`, and
`signed_header_data` in field 10000, whose field 1 is the 16-byte `crx_id`. A
store CRX carries more than one key (the store's and the developer's). The
extension's key is the one whose SHA-256 begins with `crx_id`.

`CRXUnpacker.unpack` checks the magic and version, extracts the ZIP with
`/usr/bin/unzip` into a temporary directory, checks `manifest.json` exists, and
returns the directory with the key `extractPublicKey` picked. The caller
removes the directory.

## Extension id

`ExtensionInstaller.deriveExtensionID(from:)` is Chrome's algorithm: SHA-256
of the DER public key, first 16 bytes, each nibble mapped to `a`–`p`, giving 32
letters. The id is chosen in this order:

1. `Options.forcedID` — an unpacked reload keeps its id;
2. the CRX's public key;
3. the manifest's `key` field (base64 DER);
4. a fresh UUID.

Reusing Chrome's id is not cosmetic. A native messaging host manifest lists
`allowed_origins` by extension id, so Detour's copy of 1Password passes that
check because it has the id Chrome gives it
([native messaging](./native-messaging.md)).

## What the installer does

`ExtensionInstaller.install(from:publicKey:options:)`:

1. parses `manifest.json` and refuses anything but `manifest_version` 3;
2. derives the id;
3. refuses a source folder that *is* the installed copy (a reload from there
   would delete the files it is about to copy);
4. replaces `<data>/Extensions/<id>/` with a copy of the source;
5. saves the `extension` row, including `source`, `updateURL`, `sourcePath`,
   the enabled flag and any pending permission approval from `Options`.

It loads nothing and touches no context.

## Source classification

`ExtensionSource` records where the files came from, which decides how the
extension can move to a newer version:

| Source | Set when | Updates |
|---|---|---|
| `webStore` | The CRX was downloaded from a store host (`ExtensionSource.webStoreHosts`) | Polled at the manifest's `update_url`, or the store's update2 endpoint when it declares none |
| `crx` | Any other CRX | Polled only at an `update_url` its manifest names; without one it never updates |
| `unpacked` | A folder | Never polled; reloaded from `sourcePath` on request |

Only an `https` `update_url` is kept (`pollableUpdateURL`), at first install
and at every update, so a newer manifest cannot move the poll onto plain http.

Migration v17 classified installs that predate the column. One rule there is a
deliberate trade: **a manifest with a `key` on disk reads as unpacked even when
it also has `update_url`**. A keyed unpacked extension and a store install have
the same id shape and a developer's copy of a store manifest carries
`update_url` too, so the two cannot be told apart. Guessing "store" wrongly
would replace a developer's folder with the store's CRX at the next poll;
guessing "unpacked" wrongly only costs a store install its auto-update.
See [CRX verification gate](../decisions/crx-verification-gate.md).

## Signature verification

`CRX3Verifier.verify(crxData:)` follows Chrome's `crx_verifier.cc`:

- the signed message is `"CRX3 SignedData\0"` + little-endian
  `UInt32(signed_header_data.count)` + `signed_header_data` + the ZIP;
- **every** proof in the header must verify — RSA with PKCS#1 v1.5 / SHA-256
  through Security, ECDSA with P-256 / SHA-256 through CryptoKit;
- one verified key must hash to `crx_id`; that key is the result.

`SecKeyCreateWithData` wants the inner PKCS#1 `RSAPublicKey`, while CRX3
headers carry the SubjectPublicKeyInfo wrapper, so the verifier unwraps it with
a small DER reader (`DER.pkcs1RSAPublicKey`). The real 1Password store CRX
(18 MB, RSA) passes and derives the expected id.[^task-113]

# Invariants

- An update is taken only from a CRX whose signatures verify and whose key
  derives the installed id. That is what stops an update URL, or a network
  position in front of one, from replacing an extension with another
  publisher's files.
- The first-install path does **not** verify signatures.
  `CRXUnpacker.extractPublicKey` returns the *declared* key. The user confirms
  a first install by hand; an update installs unattended.
- The installed copy is Detour's to modify (the polyfill import and the
  manifest edit, see [Polyfill layer](./polyfill-layer.md)); the source folder
  is never written.

# Gotchas

- Lengths in the CRX header are attacker-controlled varints. `Int(length)`
  traps above `Int.max`, so they are bounds-checked as `UInt64` first. A
  review of the update work found this as a remote crash;
  `testAFieldLengthAboveIntMaxIsMalformedNotACrash` guards the verifier.[^task-113]
  The outer loop of `CRXUnpacker.extractPublicKey` (first-install path) still
  converts with `Int(length)` before its bounds check; its helper
  `extractFieldBytes` has the `UInt64` check.
- Without a `crx_id` match `extractPublicKey` falls back to the last key in
  the header.
- Requests to the store go out with a Chrome user agent, which its endpoints
  expect, and a `prodversion`, which the store gates newer manifests on.
- A real-store check can be scripted: the download URL is
  `clients2.google.com/service/update2/crx?response=redirect&prodversion=…&acceptformat=crx3&x=id%3D<id>%26uc`.[^notes-updates]

# Tests

- [ExtensionIDDerivationTests](../../DetourTests/ExtensionIDDerivationTests.swift) — the id algorithm against a known value, and key extraction.
- [CRX3VerifierTests](../../DetourTests/CRX3VerifierTests.swift) — RSA and ECDSA, tampering, a valid proof for the wrong key, one bad proof among good ones, malformed containers. `CRX3TestSupport` builds signed CRX3 files in the test.
- `ExtensionUpdateMigrationTests` — the v17 classification.

# Related

- [Updates](./updates.md) — the unattended path that uses the verifier.
- [CRX verification gate](../decisions/crx-verification-gate.md) — why updates must verify and keyed manifests are unpacked.
- [ExtensionManager](./extension-manager.md) — what happens after the files are in place.
- [Permissions](./permissions.md) — the rows written at install.

[^task-113]: Check for and install extension updates
[^notes-updates]: Extension updates — design decisions and what the real 1Password CRX taught
