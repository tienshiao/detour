---
id: TASK-158
title: >-
  Extensions: remove CRXUnpacker.extractPublicKey and UnpackResult.publicKey,
  the unverified key nothing uses
status: To Do
assignee: []
created_date: '2026-10-04 09:14'
labels:
  - extensions
dependencies: []
references:
  - Detour/Extensions/Installer/CRXUnpacker.swift
  - wiki/extensions/installer-and-crx.md
priority: low
ordinal: 181000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Raised 2026-10-04 by the code review of TASK-151.

Since TASK-151 both install paths take the extension's key from CRX3Verifier (the verified key). CRXUnpacker.unpack still calls extractPublicKey on every CRX and returns its result as UnpackResult.publicKey: the key the header merely declares, with a fallback to the last key in the header when crx_id matches none. No production code reads the field; only tests do. The parser runs on untrusted bytes (it was the crash site of TASK-139) and the field is an identity that must not be used, so both are surface without a purpose.

Keep readVarint and extractFieldBytes, which CRX3Verifier uses.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 CRXUnpacker no longer parses the header for a key: extractPublicKey and UnpackResult.publicKey are gone, and unpack returns the directory
- [ ] #2 Tests that used the unverified key (ExtensionIDDerivationTests, CRX3VerifierTests, the TASK-139 bounds tests) are rewritten against CRX3Verifier or removed with the reason recorded; the oversized-length cases stay covered for the verifier
- [ ] #3 wiki/extensions/installer-and-crx.md and wiki/decisions/crx-verification-gate.md no longer describe the function
<!-- AC:END -->
