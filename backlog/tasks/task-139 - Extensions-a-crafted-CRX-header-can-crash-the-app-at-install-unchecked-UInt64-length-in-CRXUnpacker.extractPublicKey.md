---
id: TASK-139
title: >-
  Extensions: a crafted CRX header can crash the app at install (unchecked
  UInt64 length in CRXUnpacker.extractPublicKey)
status: In Progress
assignee: []
created_date: '2026-10-04 01:58'
updated_date: '2026-10-04 08:09'
labels: []
dependencies: []
references:
  - wiki/extensions/installer-and-crx.md
  - Detour/Extensions/Installer/CRXUnpacker.swift
priority: medium
ordinal: 162000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
CRXUnpacker.extractPublicKey (Detour/Extensions/Installer/CRXUnpacker.swift) reads a length-delimited field's length as a UInt64 varint and then computes `let end = offset + Int(length)` before the bounds check `guard end <= headerData.count`. Int(length) traps for a value above Int.max, and the addition can overflow for a large in-range value, so a CRX whose header carries an oversized length varint crashes the app instead of being rejected. The same file's extractFieldBytes and CRX3Verifier already guard with `length <= UInt64(data.count - offset)` (added in TASK-113's review); this outer loop was missed. extractPublicKey runs on the first-install path (CRXUnpacker line 60), on bytes that came from the network. Found by reading the code while writing wiki/extensions/installer-and-crx.md; no crash has been reproduced.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A CRX header with a length varint larger than the remaining header (including values above Int.max) is rejected without a crash, by a test that fails (traps) before the fix
- [x] #2 Every varint-to-Int conversion and offset addition in CRXUnpacker and CRX3Verifier is checked against the remaining byte count before use
- [x] #3 wiki/extensions/installer-and-crx.md is updated
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Tests first: CRXUnpacker.extractPublicKey on headers whose length varint is UInt64.max, Int.max+1, Int.max, Int.max-1, 2^32 and a small overrun, for fields 2, 3, 7 and 10000; and the same bytes through CRXUnpacker.unpack(data:).
2. Fix: compare the length with the remaining bytes as UInt64 before converting or adding.
3. Audit every varint-to-Int conversion and offset addition in CRXUnpacker and CRX3Verifier.
4. Update wiki/extensions/installer-and-crx.md.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Tests before the fix: testTheUnpackerRejectsOversizedHeaderFieldLengthsWithoutCrashing and testUnpackingAFileWithAnOversizedHeaderFieldLengthThrows both killed the test host ('Fatal error: Not enough bits to represent the passed value', three host restarts in the run). After the fix: CRX3VerifierTests 15/15.
Audit (AC #2): CRXUnpacker.extractPublicKey was the only unchecked site and now has the UInt64 guard. extractFieldBytes and CRX3Verifier.verify already had it. The container's header length is a UInt32, so 12 + Int(headerLen) cannot overflow, and is checked against the file size. readVarint stops at 64 bits of shift and only advances inside the data. DER.readElement reads at most 4 length bytes (below 2^32) and checks pos + length against the data. While there: CRXUnpacker.unpack read the version and header length with an aligned native-endian load; it now uses loadUnaligned + littleEndian like the verifier.
<!-- SECTION:NOTES:END -->
