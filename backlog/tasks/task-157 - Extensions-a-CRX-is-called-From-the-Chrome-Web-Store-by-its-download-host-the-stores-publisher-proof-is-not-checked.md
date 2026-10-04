---
id: TASK-157
title: >-
  Extensions: a CRX is called 'From the Chrome Web Store' by its download host;
  the store's publisher proof is not checked
status: To Do
assignee: []
created_date: '2026-10-04 09:14'
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
- [ ] #1 The store's publisher key hash is taken from Chromium's source and confirmed against real store CRX files; the task records both
- [ ] #2 A CRX is treated as a Web Store install (prompt wording, source webStore) only when a verified proof is the store's publisher key; a file from a store host without it is refused or treated as a non-store CRX by a stated rule
- [ ] #3 An update for a webStore install is accepted only with the publisher proof; tests cover a correctly signed developer-only CRX offered as a store update
- [ ] #4 Tests build CRX files with and without a stand-in publisher proof (the publisher key is injectable); the gated real-file test still passes for 1Password and Claude
- [ ] #5 docs/extensions.md, wiki/extensions/installer-and-crx.md and wiki/decisions/crx-verification-gate.md are updated
<!-- AC:END -->
