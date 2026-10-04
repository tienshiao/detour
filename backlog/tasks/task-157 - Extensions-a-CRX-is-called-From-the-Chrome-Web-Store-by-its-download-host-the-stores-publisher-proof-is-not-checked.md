---
id: TASK-157
title: >-
  Extensions: a CRX is called 'From the Chrome Web Store' by its download host;
  the store's publisher proof is not checked
status: In Progress
assignee: []
created_date: '2026-10-04 09:14'
updated_date: '2026-10-04 09:53'
labels:
  - extensions
  - security
dependencies: []
references:
  - Detour/Extensions/Installer/CRX3Verifier.swift
  - Detour/Extensions/Installer/CRXInstallGate.swift
  - wiki/decisions/crx-verification-gate.md
priority: medium
ordinal: 180000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Left open by TASK-151 (2026-10-04), which made a first install pass CRX3 signature verification.

CRX3Verifier checks that every proof in the header verifies and that one verified key matches crx_id. It does not check WHO signed beyond that. A Web Store CRX carries two proofs: the developer's and the store's own (the publisher key). Chrome's verifier, for store installs and updates, additionally requires a proof whose key hash is the store's publisher key hash (VerifierFormat CRX3_WITH_PUBLISHER_PROOF in components/crx_file/crx_verifier.cc).

Detour decides 'store' from the URL the bytes were served from (ExtensionSource.webStoreHosts): the install prompt then says 'From the Chrome Web Store.' and the install is recorded as source webStore, which makes it poll the store for updates. A file served from a store host is in practice a store file, so this is hardening and a truthful prompt, not a known hole: with the publisher proof checked, 'from the store' would mean the store signed it, for the first install and for every update of a webStore install.

Both real store files checked in TASK-151 (1Password, Claude) passed the verifier; confirm that they carry the publisher proof, and take the publisher key hash from Chromium's source.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The store's publisher key hash is taken from Chromium's source and confirmed against real store CRX files; the task records both
- [x] #2 A CRX is treated as a Web Store install (prompt wording, source webStore) only when a verified proof is the store's publisher key; a file from a store host without it is refused or treated as a non-store CRX by a stated rule
- [x] #3 An update for a webStore install is accepted only with the publisher proof; tests cover a correctly signed developer-only CRX offered as a store update
- [x] #4 Tests build CRX files with and without a stand-in publisher proof (the publisher key is injectable); the gated real-file test still passes for 1Password and Claude
- [x] #5 docs/extensions.md, wiki/extensions/installer-and-crx.md and wiki/decisions/crx-verification-gate.md are updated
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Key hash from Chromium, confirmed in the real 1Password and Claude store files (AC #1, recorded).
2. CRX3Verifier.verify(crxData:format:) with Chrome's two formats: .developerProof (today's check) and .publisherProof(keyHash:) — also one verified proof's key hashes to keyHash. Format.webStore carries the real hash; the hash is the injection point for tests.
3. Tests first, against a verifier that accepts the format but does not enforce it yet; then enforce.
4. Rule for the install gate: 'from the Chrome Web Store' = served by a store host AND signed by the store. CRXInstallGate.verify(crxData:downloadURL:) holds a store-host file to the store's format and refuses it without the proof (not demoted to a non-store CRX); any other file needs the developer's proof and is never a store file. The verdict (CRXInstallGate.Origin) travels with the result and is what the prompt prints and what ExtensionSource.classifyCRX(fromWebStore:) records.
5. ExtensionUpdater: an update of a .webStore install is verified with the store's format; any other CRX install with the developer's.
6. Gated real-file test through the production gate with the real key; docs and wiki.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
AC #1, 2026-10-04.
Chromium: components/crx_file/crx_verifier.cc at 3b505743bc9f8871e748b0dc79fff94d5a3c2416 (2026-09-22), kPublisherKeyHash, 'The SHA256 hash of the DER SPKI "ecdsa_2017_public" Crx3 key' = 61f7f2a6bfcf74cd0bc1fe2497cc9b04254c658f79f2145392867ea8366367cf. VerifyCrx3 sets found_publisher_key when any proof's key hashes to it, verifies every proof, and returns ERROR_REQUIRED_PROOF_MISSING when the format requires the publisher key (CRX3_WITH_PUBLISHER_PROOF) and none was found.
Real store files, downloaded 2026-10-04 from https://clients2.google.com/service/update2/crx?response=redirect&…&x=id%3D<id>%26uc (served by clients2.googleusercontent.com), headers parsed by hand:
- 1Password 18,749,599 bytes, crx_id aeblfdkhhhdcdjpifhhbdiojplfjncoa: three proofs — RSA b5e40962…b43786b0, RSA 041b53a7…b0cc7927 (the crx_id key, the developer's), ECDSA 61f7f2a6…366367cf (the publisher key).
- Claude 6,918,124 bytes, crx_id fcoeoabgfenejglbffodgkkbkcdhcgfn: three proofs — RSA b5e40962…b43786b0 (the same key as in 1Password's file), RSA 52e4e016…792c1a54 (the crx_id key), ECDSA 61f7f2a6…366367cf (the publisher key).
Both carry the publisher proof, as an ECDSA P-256 proof (header field 3), which CRX3Verifier already verifies.

The rule (AC #2), decided 2026-10-04: 'from the Chrome Web Store' is two facts together — a store host served the bytes (ExtensionSource.webStoreHosts, the final URL of the fetch) AND a verified proof in the file is the store's publisher key.
- Store host + the proof: admitted; the prompt says 'From the Chrome Web Store.'; source webStore.
- Store host without the proof: REFUSED ('The file was served from a Chrome Web Store address but is not signed by the Chrome Web Store, so it was not installed.'), before anything is unpacked or the installed list is consulted. Chosen over demoting it to a non-store CRX: the store signs everything it serves, so such a file is not what its address says, and Chrome refuses it too (ERROR_REQUIRED_PROOF_MISSING).
- Any other host, or a file on disk: the developer's proof is enough, as before, and it is never a store file even when it carries the store's proof (a re-hosted or saved store CRX is a CRX from that site or disk; it polls only an update_url its manifest names).
- Update (AC #3): an install whose source is webStore is verified with the store's format; a file signed by the developer's key alone fails as 'the file is not signed by the Chrome Web Store' and nothing is installed or staged. Other CRX installs update on the developer's proof.

Code: CRX3Verifier.verify(crxData:format:) with Format.developerProof / .publisherProof(keyHash:) (Chrome's CRX3 / CRX3_WITH_PUBLISHER_PROOF) and Format.webStore for the real hash; Failure.noPublisherProof. CRXInstallGate.verify(crxData:downloadURL:storeFormat:) returns the verdict as CRXInstallGate.Origin (.webStore / .unverifiedStoreHost / .site / .file), which replaces originDescription(downloadURL:) and is what the prompt and the alerts print; ExtensionSource.classifyCRX(fromWebStore:manifestUpdateURL:) records it. ExtensionUpdater takes storeFormat (default .webStore). An alert for a file that fails verification names a store host as a host ('From <host>, but not verified as signed by the Chrome Web Store.').

Tests.
- Before enforcement (the format accepted but ignored): CRX3VerifierTests, CRXInstallGateTests, ExtensionUpdaterTests, ExtensionUpdateMigrationTests — 76 tests, 13 assertion failures in 6 tests: a developer-only file and a file with another key's second proof passed the publisher format; a store-host file without the proof was admitted (three hosts), looked up and unpacked; the default gate accepted a stand-in store key; a store install took a developer-only update.
- After: those four suites plus StagedExtensionUpdateTests, ExtensionUpdatePolicyTests, ExtensionUpdateDeferralTests, ExtensionRuntimeUpdateAvailablePolyfillTests, ExtensionRuntimeUpdateCheckPolyfillTests, ExtensionIDDerivationTests, UpdateManifestTests: 124 tests, 0 failures, with the gated real-file test ON.
- The stand-in publisher is a P-256 key generated in each test; its hash is passed as storeFormat (gate) and to ExtensionUpdater(storeFormat:). The updater fixture is a store install, so its update files now carry the stand-in proof; testACRXSignedByAnotherKeyIsRejected's second half was changed to a store-signed file of another publisher so that it still reaches the id check.
- Real files (TEST_RUNNER_DETOUR_REAL_CRX_FILES, the two files above) through the PRODUCTION gate with the real key hash, as store downloads: 1Password 8.12.38.34 admitted as aeblfdkhhhdcdjpifhhbdiojplfjncoa, origin webStore; Claude 1.0.98 admitted as fcoeoabgfenejglbffodgkkbkcdhcgfn, origin webStore.

Known limits, recorded in wiki/extensions/installer-and-crx.md: an install recorded as webStore before this change is not re-checked (its next update is); a copy already staged under the old rule is applied without the publisher check.
Epic branch: the touched files merge cleanly into its working tree (git merge-file simulation).
Not done here: the install through the UI (prompt and refusal alert wording) — runtime check at batch integration. Review happens at batch integration too.
<!-- SECTION:NOTES:END -->
