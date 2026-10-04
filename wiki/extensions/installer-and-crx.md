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
  - id: task-139
    resource: backlog:TASK-139
    title: A crafted CRX header can crash the app at install
  - id: gate
    resource: ../../Detour/Extensions/Installer/CRXInstallGate.swift
    title: CRXInstallGate.swift
  - id: gate-tests
    resource: ../../DetourTests/CRXInstallGateTests.swift
    title: CRXInstallGateTests
  - id: task-151
    resource: backlog:TASK-151
    title: A first install from a CRX does not verify its signature
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
Four types do it: `CRX3Verifier` checks a CRX3 file's signatures,
`CRXInstallGate` decides whether a downloaded one may be offered for install,
`CRXUnpacker` opens it, and `ExtensionInstaller` copies and records. Loading the result
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
passes it through the install gate below, shows where it came from and the
manifest's permissions in a confirmation alert, and only then calls
`ExtensionManager.install`.

## The install gate

The interception has no host check: any site can serve a `.crx`. What the
file may claim is therefore decided by `CRXInstallGate.admit(crxData:installed:)`
before anything is unzipped or shown:[^task-151]

1. `CRX3Verifier.verify` must return `.verified`. The id is derived from the
   verified key, never from a key the header merely declares.
2. No installed extension has that id. The file is refused whatever its
   version: an install over an installed copy would inherit its per-profile
   enablement, saved permission decisions and storage. Moving to a newer
   version is the updater's job ([Updates](./updates.md)).
3. A manifest `key`, when present, equals the verified key (decoded leniently;
   an undecodable key counts as a mismatch).

A refusal is a `CRXInstallGate.Refusal`, shown as "Extension Not Installed"
with the reason and the origin. The lookup in step 2 is repeated after the
confirmation alert, because the alert runs a modal loop in which the same
file could have been installed.

The prompt's first line is `CRXInstallGate.originDescription(downloadURL:)`:
"From the Chrome Web Store." for a store host, otherwise the host by name
with "not from the Chrome Web Store". The URL is the final one of the
`URLSession` fetch (after its redirects), and the same URL feeds
`ExtensionSource.classifyCRX`.

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
- A first install is taken only from a CRX whose signatures verify, under
  the id of the verified key, and never over an installed extension. Native
  messaging hosts authorise by id, so an id must not be claimable by a file
  that merely carries another extension's public key.[^task-151]
- `CRXUnpacker.extractPublicKey` returns the key the header *declares*,
  without checking a signature. No install path uses it for the id any more;
  do not derive an id from `UnpackResult.publicKey`.
- The installed copy is Detour's to modify (the polyfill import and the
  manifest edit, see [Polyfill layer](./polyfill-layer.md)); the source folder
  is never written.

# Gotchas

- Lengths in the CRX header are attacker-controlled varints. `Int(length)`
  traps above `Int.max`, so they are bounds-checked as `UInt64` first. A
  review of the update work found this as a remote crash;
  `testAFieldLengthAboveIntMaxIsMalformedNotACrash` guards the verifier.[^task-113]
  The outer loop of `CRXUnpacker.extractPublicKey` was missed then: it computed
  `offset + Int(length)` before its bounds check, which traps above `Int.max`
  and overflows just below it, on bytes from the network. It now has the same
  `UInt64` check, guarded by
  `testTheUnpackerRejectsOversizedHeaderFieldLengthsWithoutCrashing`.[^task-139]
  The rule for any new parsing here: compare a length against the bytes that
  remain, as `UInt64`, before converting or adding it.
- Without a `crx_id` match `extractPublicKey` falls back to the last key in
  the header. That is one more reason its result is not an identity.
- "From the Chrome Web Store" in the prompt means the bytes came from a store
  host, not that the store's own key signed them. Chrome additionally
  requires the store's publisher proof for store installs; Detour does not
  check for it.
- Requests to the store go out with a Chrome user agent, which its endpoints
  expect, and a `prodversion`, which the store gates newer manifests on.
- A real-store check can be scripted: the download URL is
  `clients2.google.com/service/update2/crx?response=redirect&prodversion=…&acceptformat=crx3&x=id%3D<id>%26uc`.[^notes-updates]

# Tests

- [ExtensionIDDerivationTests](../../DetourTests/ExtensionIDDerivationTests.swift) — the id algorithm against a known value, and key extraction.
- [CRX3VerifierTests](../../DetourTests/CRX3VerifierTests.swift) — RSA and ECDSA, tampering, a valid proof for the wrong key, one bad proof among good ones, malformed containers. `CRX3TestSupport` builds signed CRX3 files in the test.
- [CRXInstallGateTests](../../DetourTests/CRXInstallGateTests.swift) — each refusal (a header key that did not sign the file, a forged proof beside a valid one, a tampered archive, unsigned, CRX2, truncated header, an installed id, a disagreeing manifest key), that nothing is unpacked or looked up for an unverified file, and the origin line. One test, off by default, runs real store files through the gate (`TEST_RUNNER_DETOUR_REAL_CRX_FILES`).
- `ExtensionUpdateMigrationTests` — the v17 classification.

# Related

- [Updates](./updates.md) — the unattended path that uses the verifier.
- [CRX verification gate](../decisions/crx-verification-gate.md) — why updates must verify and keyed manifests are unpacked.
- [ExtensionManager](./extension-manager.md) — what happens after the files are in place.
- [Permissions](./permissions.md) — the rows written at install.

[^task-113]: Check for and install extension updates
[^task-139]: A crafted CRX header can crash the app at install
[^task-151]: A first install from a CRX does not verify its signature
[^notes-updates]: Extension updates — design decisions and what the real 1Password CRX taught
