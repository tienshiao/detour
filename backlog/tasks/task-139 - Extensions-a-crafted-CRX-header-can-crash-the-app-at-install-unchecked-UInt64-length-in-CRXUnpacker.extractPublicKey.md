---
id: TASK-139
title: >-
  Extensions: a crafted CRX header can crash the app at install (unchecked
  UInt64 length in CRXUnpacker.extractPublicKey)
status: To Do
assignee: []
created_date: '2026-10-04 01:58'
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
- [ ] #1 A CRX header with a length varint larger than the remaining header (including values above Int.max) is rejected without a crash, by a test that fails (traps) before the fix
- [ ] #2 Every varint-to-Int conversion and offset addition in CRXUnpacker and CRX3Verifier is checked against the remaining byte count before use
- [ ] #3 wiki/extensions/installer-and-crx.md is updated
<!-- AC:END -->
