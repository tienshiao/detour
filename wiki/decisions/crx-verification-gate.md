---
type: Decision
title: Extension updates must pass CRX3 verification
description: Why an extension update is installed only if its CRX3 signatures verify and its signing key derives the installed id, why a manifest with a key is classified as unpacked, and how the first-install path came to verify too.
tags: [extensions, updates, security, crx, decision]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T10:05:00Z }
sources:
  - id: verifier
    resource: ../../Detour/Extensions/Installer/CRX3Verifier.swift
    title: CRX3Verifier.swift
  - id: updater
    resource: ../../Detour/Extensions/Updates/ExtensionUpdater.swift
    title: ExtensionUpdater.swift
  - id: policy
    resource: ../../Detour/Extensions/Updates/ExtensionUpdatePolicy.swift
    title: ExtensionUpdatePolicy.swift
  - id: source
    resource: ../../Detour/Extensions/Model/ExtensionSource.swift
    title: ExtensionSource.swift
  - id: database
    resource: ../../Detour/Storage/Database.swift
    title: Database.swift (migration v17)
  - id: verifier-tests
    resource: ../../DetourTests/CRX3VerifierTests.swift
    title: CRX3VerifierTests.swift
  - id: updater-tests
    resource: ../../DetourTests/ExtensionUpdaterTests.swift
    title: ExtensionUpdaterTests.swift
  - id: task-113
    resource: backlog:TASK-113
    title: Check for and install extension updates
  - id: task-123
    resource: backlog:TASK-123
    title: Defer an update while the extension is busy
  - id: gate
    resource: ../../Detour/Extensions/Installer/CRXInstallGate.swift
    title: CRXInstallGate.swift
  - id: task-151
    resource: backlog:TASK-151
    title: A first install from a CRX does not verify its signature
  - id: task-157
    resource: backlog:TASK-157
    title: A CRX is called 'From the Chrome Web Store' by its download host; the store's publisher proof is not checked
---

# Context

Before updates existed, the only thing between a CRX file and an installed
extension was a person: a Chrome Web Store download is intercepted, unpacked
and shown in a confirmation prompt that lists its permissions. The id is
derived from the public key the CRX header *declares*; the signatures are
not checked.

An update is different. It is fetched in the background from a URL the
extension's own manifest names, replaces running code, and nobody is asked.
Whoever controls that URL, or sits in front of it, would choose what runs
with the extension's granted permissions.

# Decision

**An update candidate is installed only if it passes every step of one
gate**, in `ExtensionUpdater.performCheck`:

1. If the update server announced a SHA-256, the download must match it.
2. `CRX3Verifier.verify` must return `.verified`: every proof in the header
   verifies over `"CRX3 SignedData\0"` + length + signed header data + ZIP
   payload (RSA PKCS#1 v1.5 with SHA-256, or ECDSA P-256 with SHA-256), and
   one of the verified keys hashes to the header's `crx_id`.
3. The id that key derives must equal the installed extension's id.
4. The version must be strictly newer.

`ExtensionManager.applyUpdate` re-checks id and version when it installs, and
a copy staged for later keeps its verified key and is re-validated when
applied.

Steps 2 and 3 belong together. Comparing ids is only meaningful once the key
is known to have signed the file; that pair is what stops an update URL, or
a network position in front of one, from replacing an extension with a
different publisher's files. Every proof must verify: one bad proof among
good ones fails the whole file, following Chrome's verifier.

Two companion rules complete it:

- **Update URLs are https only**, at first install and at every update, so a
  newer manifest cannot move the poll onto plain http.
- **Added permissions never arrive silently.** An update whose manifest adds
  API permissions that carry an install warning, or host access not covered
  by a pattern the old one had, is installed *disabled* until the user
  accepts. See [updates](../extensions/updates.md).

## A manifest with a `key` is unpacked

Migration v17 had to classify extensions installed before the source was
recorded. A manifest `key` pins an unpacked extension's id to the same
32-letter shape a CRX gets, and a developer's copy of a store manifest
carries `update_url` too, so the two cannot be told apart. The migration
reads a keyed manifest as **unpacked**, which never polls. The wrong call in
the other direction would replace a developer's folder with the store's CRX
at the next poll; this way round only costs a store install its automatic
updates, and reinstalling from the store restores them.

New installs do not need the rule: the install site records the source (a
CRX download is classified by `ExtensionSource.classifyCRX`, a folder is
`unpacked`).

# Alternatives rejected

| Alternative | Why not |
|---|---|
| Classify a keyed manifest with `update_url` as a store install | See above: it risks overwriting a developer's working folder |
| Auto-update unpacked extensions | Chrome's developer-mode rule was chosen instead: nothing polls a folder, and an unpacked extension gets an explicit Reload that keeps its id[^task-113] |
| Let an update gain permissions silently | The chosen policy is Chrome's: install disabled until the user approves[^task-113] |
| Install a verified update the moment it arrives | Replacing a running context tears its pages down and restarts its worker, so a busy extension's update is staged instead[^task-123] |

# Consequences

- **The first-install path verifies too, since TASK-151.** When this
  decision was made it relied on the confirmation prompt alone and derived
  the id from the key the header declared. That let any site's CRX claim
  another extension's id by carrying its public key, and native messaging
  hosts authorise by id; an install over an installed id also inherited its
  enablement, permission decisions and storage. `CRXInstallGate` now applies
  step 2 of the gate above to a first install, derives the id from the
  verified key, refuses an id that is already installed (that is the
  updater's path) and refuses a manifest `key` that disagrees with the
  signing key.[^task-151] Refusing the disagreeing key, rather than ignoring
  it as Chrome's unpacker does by overwriting it, means no later reader of
  `manifest.key` can be led to a different id.
- The file is attacker-controlled input. The header parser bounds-checks a
  field length in 64 bits before converting it, after review found that a
  length above `Int.max` would trap.[^task-113]
- **A Web Store install must be signed by the store, since TASK-157.** The
  gate above proves who the *developer* is. It says nothing about the store,
  and "store" used to be decided by the host that served the bytes alone.
  Chrome asks more of a store file: a verified proof by the store's publisher
  key (`CRX3_WITH_PUBLISHER_PROOF`). Detour now asks the same in both places:
  a file served by a store host is admitted, called "From the Chrome Web
  Store" and recorded as `webStore` only with that proof, and an update of a
  `webStore` install is taken only with it — step 2 runs with
  `Format.publisherProof` for such an install. So the developer's key alone,
  leaked or held by whoever answers the update check, cannot replace a store
  install. A store-host file without the proof is refused rather than
  demoted to an ordinary CRX: the store signs everything it serves.
  The key's hash comes from Chromium's source and was confirmed in two real
  store files; see
  [installer and CRX](../extensions/installer-and-crx.md#what-from-the-chrome-web-store-means).[^task-157]
- Store hosts are matched exactly (`ExtensionSource.webStoreHosts`) or, in
  the migration, on a domain boundary: `clients2.google.com` is the store,
  `notgoogle.com` is not.
- Only ECDSA keys on P-256 are supported; another curve fails as
  `unsupportedKey`.
- A server-side update-check error is reported as a failure, not as "up to
  date".
- A staged copy is applied when the extension is idle, at the next launch,
  or on request, and is validated again at that point.[^task-123]

# Evidence

- `CRX3VerifierTests` builds signed CRX3 files in the test
  (`CRX3TestSupport.swift`): RSA and ECDSA, two proofs, a tampered payload, a
  corrupt signature, a valid proof for a key other than `crx_id`, one bad
  proof among good ones, malformed containers.
- `ExtensionUpdaterTests`: a CRX signed by another key is rejected, a
  download that does not match the announced hash is rejected, an announced
  version that is not newer is not downloaded.
- `ExtensionUpdateMigrationTests.testV17ClassifiesExistingInstalls`.
- The publisher proof: `CRX3VerifierTests` (a developer-only file fails the
  publisher format, a second proof by another key is not the publisher's,
  the publisher's key named over someone else's signature fails as a
  signature), `CRXInstallGateTests` (a store-host file without the proof is
  refused before anything is unpacked or looked up; a store-signed file from
  elsewhere is not a store file) and
  `ExtensionUpdaterTests.testAStoreInstallRefusesAnUpdateTheStoreDidNotSign`,
  all with a stand-in publisher key. The gated real-file test passes the
  1Password and Claude store CRXs through the production gate with the real
  key.[^task-157]
- At runtime on 2026-09-25 the real 1Password store CRX (18 MB, RSA) passed
  the verifier and derived the expected id, and a live update check against
  the store answered "no update".[^task-113]

# Related

- [Updates](../extensions/updates.md) — the updater, cadence, deferral and staging
- [Installer and CRX](../extensions/installer-and-crx.md) — unpacking and id derivation
- [Permissions](../extensions/permissions.md) — pending approval of added permissions
- [Native WebExtension with polyfills](./native-webextension-with-polyfills.md) — the architecture these installs run on

[^task-113]: Check for and install extension updates
[^task-123]: Defer an update while the extension is busy
[^task-151]: A first install from a CRX does not verify its signature
[^task-157]: A CRX is called 'From the Chrome Web Store' by its download host; the store's publisher proof is not checked
