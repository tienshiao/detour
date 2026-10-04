---
id: TASK-158
title: >-
  Extensions: remove CRXUnpacker.extractPublicKey and UnpackResult.publicKey,
  the unverified key nothing uses
status: In Progress
assignee: []
created_date: '2026-10-04 09:14'
updated_date: '2026-10-04 09:56'
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
- [x] #1 CRXUnpacker no longer parses the header for a key: extractPublicKey and UnpackResult.publicKey are gone, and unpack returns the directory
- [ ] #2 Tests that used the unverified key (ExtensionIDDerivationTests, CRX3VerifierTests, the TASK-139 bounds tests) are rewritten against CRX3Verifier or removed with the reason recorded; the oversized-length cases stay covered for the verifier
- [x] #3 wiki/extensions/installer-and-crx.md and wiki/decisions/crx-verification-gate.md no longer describe the function
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Tests first: the oversized-length matrix moves to CRX3Verifier.verify (top-level fields, and the lengths inside a proof and inside signed_header_data, which go through extractFieldBytes); the tests that read UnpackResult.publicKey or call extractPublicKey are rewritten or removed.
2. CRXUnpacker.unpack returns the directory; extractPublicKey, UnpackResult and the header read go. readVarint and extractFieldBytes stay (CRX3Verifier uses them).
3. Callers (CRXInstallGate, ExtensionUpdater, tests), the CRX3Verifier doc comment, the two wiki pages.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Done 2026-10-04 on the batch branch, after TASK-157.
- CRXUnpacker.unpack(data:) and unpack(crxURL:) return the directory (URL). UnpackResult, extractPublicKey and the header read are gone, with the CryptoKit import; readVarint and extractFieldBytes stay for CRX3Verifier. Callers updated: CRXInstallGate.admit, ExtensionUpdater.performCheck, ExtensionUpdaterTests.
- No test was written to fail first: the task removes code and adds no behaviour. The coverage that guarded the removed parser moved to the verifier instead (below).
- Tests (AC #2): CRX3VerifierTests.testTheUnpackerRejectsOversizedHeaderFieldLengthsWithoutCrashing became testTheVerifierRejectsOversizedHeaderFieldLengthsWithoutCrashing — the same six lengths (UInt64.max, Int.max+1, Int.max, Int.max-1, 2^32, 3) on fields 2, 3, 7 and 10000, now through CRX3Verifier.verify, each '.malformed(field overruns header)'. New: testTheVerifierRejectsOversizedLengthsInsideAProofAndTheSignedHeader, the same lengths one level down (a proof's key and signature, the crx_id), which is where extractFieldBytes reads them. testUnpackingAFileWithAnOversizedHeaderFieldLengthThrows stays and now asserts the reason (the unpacker does not read the header; unzip refuses the archive). testAnRSASignedFileVerifiesAndYieldsTheDeclaredKey no longer compares UnpackResult.publicKey. ExtensionIDDerivationTests: the three extractPublicKey tests (a key from a hand-built header, empty data, malformed data) are removed with the function; the verifier's own tests cover a declared key among several proofs, a header without proofs and malformed containers.
<!-- SECTION:NOTES:END -->
