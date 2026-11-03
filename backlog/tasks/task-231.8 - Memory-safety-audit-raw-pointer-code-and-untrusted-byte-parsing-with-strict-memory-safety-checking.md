---
id: TASK-231.8
title: >-
  Memory safety: audit raw-pointer code and untrusted-byte parsing with strict
  memory safety checking
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T00:08:00Z'
updated_date: '2026-11-03T04:57:00Z'
labels:
  - concurrency
dependencies: []
references:
  - Detour/Extensions/Installer/CRX3Verifier.swift
  - Detour/Extensions/Installer/CRXUnpacker.swift
  - Detour/Extensions/Runtime/NativeMessagingHost.swift
parent_task_id: TASK-231
priority: low
type: chore
ordinal: 275000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Independent of the concurrency work. Swift 6.2 added opt-in strict memory safety checking (SE-0458), which flags unsafe constructs. Ten files use raw pointers or unsafe casts. Two of them parse bytes from outside the app: CRX3Verifier / CRXUnpacker (extension packages downloaded from the store) and NativeMessagingHost (length-prefixed frames from another process). The others are AppDelegate, BrowserTab, TabStore, WebKitStorageScope, ExtensionOriginInteractionKeeper, WebInspectorControl and DevMode.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The strict memory safety warning count for the Detour target is measured and recorded
- [x] #2 CRX parsing and native-messaging framing have no unchecked unsafe uses left: each is replaced by a bounds-checked equivalent or marked `unsafe` with a comment saying why it is in bounds
- [x] #3 Tests cover malformed input on both paths: a CRX whose header lengths exceed the file, and a native message whose length prefix exceeds the data received
- [x] #4 The task records whether the checking stays on for the whole target or was a one-time audit, and why
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Turn on SWIFT_STRICT_MEMORY_SAFETY (=-strict-memory-safety) for the Detour target only in project.yml, xcodegen, build into .derived, count and categorize the warnings per file.
2. CRX3Verifier / CRXUnpacker: replace the withUnsafeBytes loadUnaligned UInt32 reads and the Data(bytes:&) append with byte-wise little-endian reads/writes (bounds-checked Data subscripts); keep the parse results identical.
3. NativeMessagingHost: same for the read loop's length prefix (load(as:) -> byte decode), decodeMessage and encodeMessage; wire bytes identical. Factor the read loop's framing into a pure helper only if it lets tests reach it without changing behaviour.
4. Tests: CRX whose header length exceeds the file (verifier and unpacker, incl. UInt32.max and zipStart == count); native host whose length prefix exceeds the bytes it writes (real host process via DETOUR_NATIVE_MESSAGING_HOSTS_DIR, read loop reports Incomplete message read, no message delivered), plus decodeMessage on slices.
5. Decide whether checking stays on for the whole target (depends on count/noise); revert the setting if it is a one-time audit; record the decision and why.
6. Wiki page on strict memory safety + log line; /code-review --fix, /verify, affected suites; commit.

7. (Review) One container parser: CRXUnpacker.container(of:) returns the header and ZIP ranges; CRX3Verifier.verify and unpack(data:) both call it, so the archive the signature is checked over is the one extracted; the ZIP is passed as a slice (one copy fewer).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Measurement (AC #1), 2026-11-02, Xcode 27.2, Detour target in Swift 6 mode, SWIFT_STRICT_MEMORY_SAFETY: YES set on the Detour target only in project.yml (xcodegen, full build into .derived): 218 warnings in 57 files, all #StrictMemorySafety (215 'expression uses unsafe constructs', 2 for-in loops, 1 class with unsafe storage). 19 were in the three parsing files (CRX3Verifier 8, NativeMessagingHost 7, CRXUnpacker 4). The other 199, classified by pattern (approximate split): ~89 AppKit properties the SDK declares unsafe_unretained (view.window, superview, NSMenuItem.target, every read), ~29 Objective-C runtime (perform, unsafeBitCast of IMPs, objc_setAssociatedObject), ~24 raw bytes/pointers (withUnsafeBytes/loadUnaligned for UUID hashing and pid_t, stop.pointee), ~21 Carbon hot-key API, 4 String(format:), ~32 other (C pointer params passed nil, KVO context, Unmanaged CF results, withContiguousStorageIfAvailable in HistoryDatabase's title matcher). After the rewrite the three parsing files and the new Data+LittleEndian.swift report 0 (incremental build with the setting still on, all four recompiled).

Changes (AC #2): new Data.littleEndianUInt32(at:) / Data(littleEndianBytesOf:) (Detour/Browser/Shared/Data+LittleEndian.swift) read/write LE32 byte by byte through the bounds-checked subscript. CRX3Verifier + CRXUnpacker: version/header-length reads and the signed-message length append use them; offsets (fixed fields, header/zip subdata, readVarint, extractFieldBytes) count from startIndex so a Data slice parses as its own bytes (it used to trap on data[0..<4]). SecKeyCreateWithData's Unmanaged<CFError> out-param kept, marked unsafe with a comment (Create rule, taken over once with takeRetainedValue); SecKeyVerifySignature now gets nil instead of &error (the error was unused and the CFError it set leaked). NativeMessagingHost: read-loop prefix, encodeMessage and decodeMessage use the helpers (decodeMessage also startIndex-relative); the Debug-only DETOUR_NATIVE_MESSAGING_HOSTS_DIR read uses ProcessInfo.processInfo.environment instead of getenv+String(cString:) (checked with a standalone program: it sees later setenv/unsetenv). Wire bytes identical, pinned by tests.

Decision (AC #4): one-time audit; SWIFT_STRICT_MEMORY_SAFETY removed from project.yml again. Why: the check is module-wide (no per-file Swift flags in Xcode), and ~200 interop warnings (AppKit unsafe_unretained properties, Carbon, ObjC runtime) would each need an unsafe marker with nothing to say, and would bury the warnings that matter here, above all 'nearly matches optional requirement' (silent WebKit delegate loss). The outside-bytes code is now clean, so re-running the audit (recipe in wiki/platform/strict-memory-safety.md) shows a regression at once.

NativeMessagingHost behaviour: no change intended (same bytes, same disconnect reasons), but the read loop's code on the 1Password path changed, so a signed-build 1Password check is owed by the user as a precaution (not attempted here).

Re-measure after the review fixes (full rebuild with SWIFT_STRICT_MEMORY_SAFETY: YES, then removed again and regenerated): 199 warnings in 54 files, 0 in CRX3Verifier.swift, CRXUnpacker.swift, NativeMessagingHost.swift, Data+LittleEndian.swift. project.yml has no diff.

/code-review --fix (diff + the two new files): no correctness bugs. Fixed: the duplicated container parse (now CRXUnpacker.container(of:) -> Result<Container, CRXError>, the verifier maps each error to its old .malformed string); the extra ZIP copy (slices); the duplicated test container helper; a test calling the XCTest tearDown() override mid-test (private reset()); the redundant count == 4 guard in the read loop (readData(ofLength: 4) returns at most 4 bytes, so behaviour is the same). Skipped: the .echoes fake host carries no sleep token, so pkill-by-token cannot reach it (documented in the fixture; disconnect() and stdin EOF end it); ExtensionIDDerivationTests still reads the prefix with withUnsafeBytes (test target, not part of this change).

Tests (after the review fixes, sandbox off, load ~4): NativeMessagingFramingTests 8 (new), CRX3VerifierTests 27 (4 new), CRXInstallGateTests 27 incl. the real 1Password store CRX (TEST_RUNNER_DETOUR_REAL_CRX_FILES=aeblfdkhhhdcdjpifhhbdiojplfjncoa=TestExtensions/1password/1password.crx: 19.8 MB, admitted as webStore under its store id, version 8.12.8.26), ExtensionIDDerivationTests 11, ExtensionUpdaterTests 23, NativeMessagingEnforcementTests 11: 107 tests, 0 failures. The full suite was not run.

/verify: Debug build into .derived (dylib timestamp checked), launched with DETOUR_DATA_DIR=DetourVerify2318, hand-seeded TestExtensions/hello-world (extension + extensionPermission rows): 'Loaded extension Hello World', context loaded, worker ran (polyfill console lines, onInstalled delivered), no load failure. The PID was killed, the two defaults keys were deleted, and the data dir was removed. No UI changed. Not verified at runtime: a CRX install through the app UI (covered by CRXInstallGateTests on the real store file) and a live native host. A signed-build 1Password check of native messaging is owed by the user.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Strict memory safety checking (SE-0458, SWIFT_STRICT_MEMORY_SAFETY) was measured on the Detour target: 218 warnings in 57 files before, 199 in 54 after, almost all AppKit unsafe_unretained properties, the Objective-C runtime and Carbon. This was a one-time audit and the setting is not left on: it applies to the whole module only, and about 200 interop warnings would bury 'nearly matches optional requirement'. CRX parsing and native-messaging framing no longer use unchecked unsafe constructs. LE32 fields are read and written through the new Data.littleEndianUInt32(at:) / Data(littleEndianBytesOf:), offsets count from startIndex (a Data slice no longer traps), and one container parser (CRXUnpacker.container(of:)) serves the verifier and the unpacker. The only unsafe use left is SecKeyCreateWithData's Unmanaged CFError, which is marked and commented; a CFError leaked by SecKeyVerifySignature is fixed. The Debug host-dir override reads ProcessInfo.environment. The native-messaging wire bytes are unchanged, pinned by NativeMessagingFramingTests (real host processes: prefix past the data, truncated frame after good ones, 0 and over-1 MB prefixes, a short prefix, an echo round trip). New CRX tests cover header lengths past the file, short files, little-endian fields and slices. 107 tests in the six affected suites pass, including the real 1Password store CRX. /verify: build and isolated launch with a seeded extension loading. Owed: a signed-build 1Password check by the user (precaution: the read loop's code changed, not its behaviour). Wiki: platform/strict-memory-safety.md (new), plus installer-and-crx, native-messaging and log.
<!-- SECTION:FINAL_SUMMARY:END -->
