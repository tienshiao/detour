---
type: Platform Quirk
title: Strict memory safety checking (SE-0458)
description: What Swift 6.2's opt-in strict memory safety checking reports for the Detour target (218 warnings, most of them AppKit, Carbon and Objective-C runtime interop), why it was a one-time audit rather than a setting left on, how the code that parses bytes from outside the app was made clean, and how to run the audit again.
tags: [swift, memory-safety, build, security]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-03T04:48:28Z }
sources:
  - id: task-231-8
    resource: backlog:TASK-231.8
    title: "Memory safety: audit raw-pointer code and untrusted-byte parsing with strict memory safety checking"
  - id: le-bytes
    resource: ../../Detour/Browser/Shared/Data+LittleEndian.swift
    title: Data+LittleEndian.swift
  - id: verifier
    resource: ../../Detour/Extensions/Installer/CRX3Verifier.swift
    title: CRX3Verifier.swift
  - id: host
    resource: ../../Detour/Extensions/Runtime/NativeMessagingHost.swift
    title: NativeMessagingHost.swift
  - id: framing-tests
    resource: ../../DetourTests/NativeMessagingFramingTests.swift
    title: NativeMessagingFramingTests.swift
  - id: se-0458
    resource: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0458-strict-memory-safety.md
    title: "SE-0458: Opt-in Strict Memory Safety Checking"
---

# Behavior

Swift 6.2 can flag every use of a construct the compiler cannot prove
memory safe (SE-0458).[^se-0458] In Xcode the switch is the build setting
`SWIFT_STRICT_MEMORY_SAFETY` (`YES` passes `-strict-memory-safety`; `MIGRATE`
passes `-strict-memory-safety:migrate`, which adds fix-its). It only warns:
nothing changes at runtime, and an `unsafe` expression marker compiles with
the checking off too. A use is acknowledged by prefixing the expression with
`unsafe`; the proposal's convention, followed here, is a comment saying why
it holds.

Measured on the Detour target on 2026-11-02 (Xcode 27.2, the app in the
Swift 6 language mode): **218 warnings in 57 files**, all
`#StrictMemorySafety` — 215 "expression uses unsafe constructs but is not
marked with 'unsafe'", 2 for-in loops over unsafe sequences, and 1 class
"has storage involving unsafe types".[^task-231-8] Nineteen were in the
three files that parse outside bytes (below). The other 199, by what the
flagged expression touches (classified by pattern over the flagged source,
so the split is approximate; the totals are exact):

| Kind | Count | Examples |
|---|---|---|
| AppKit properties the SDK declares `unsafe_unretained` (imported as `unowned(unsafe)`) | 89 | `view.window`, `superview`, `NSMenuItem.target`, `makeFirstResponder` through `window?` — every read, including `guard let window` |
| Objective-C runtime | 29 | `perform(_:)`, `unsafeBitCast` of an IMP from `method(for:)`, `objc_setAssociatedObject` |
| Raw bytes and pointers | 24 | `withUnsafeBytes`/`loadUnaligned` (UUID hashing, a `pid_t` out of `Data`), `stop.pointee` in enumeration blocks |
| Carbon hot-key API | 21 | `RegisterEventHotKey`, `InstallEventHandler`, `EventHotKeyRef` storage |
| `String(format:)` (`CVarArg`) | 4 | colour hex strings |
| Other | 32 | C pointer parameters passed `nil` (`CGPath(…transform: nil)`, `cgImage(forProposedRect: nil…)`, KVO `context: nil`), `Unmanaged` CF results, `withContiguousStorageIfAvailable` in the history title matcher |

# Why it matters here

Two paths parse bytes from outside the app: the CRX container and its
protobuf header (a download, possibly from an update server an attacker
controls) and native-messaging frames (another process's stdout, which for
1Password carries vault data). Both read their little-endian `UInt32`
fields with `withUnsafeBytes { $0.loadUnaligned(as:) }` or `load(as:)`,
and wrote them with `Data(bytes: &value, count: 4)`. The lengths were
already checked before the reads, so none of this was an exploitable bug,
but nothing but that check stood between a short buffer and a read past
its end — and `load(as:)` (unlike `loadUnaligned`) also traps on a
misaligned address.[^task-231-8]

They now go through `Data.littleEndianUInt32(at:)` and
`Data(littleEndianBytesOf:)` (`Data+LittleEndian.swift`), which read and
write one byte at a time through `Data`'s bounds-checked subscript: a
short buffer is `nil`, never an out-of-bounds read.[^le-bytes] The wire
bytes are unchanged (`NativeMessagingFramingTests` pins the prefix, and
round-trips messages through a real echoing host process).[^framing-tests]
While there, every offset in the CRX readers and `decodeMessage` became
relative to `startIndex`, so a `Data` slice is parsed as its own bytes;
before, a slice with a non-zero `startIndex` trapped on `data[0..<4]`. The
container's fixed fields are now read in one place,
`CRXUnpacker.container(of:)`, which both the verifier and the unpacker call,
so the archive the signature is checked over is the archive that is
extracted. After the change the target reports 199 warnings in 54 files,
none of them in these files.

What was left in those three files after the rewrite, and why:

- `CRX3Verifier`, RSA keys: `SecKeyCreateWithData` takes an
  `Unmanaged<CFError>` out-parameter, which cannot be expressed safely. It
  is marked `unsafe`: the error follows the Create rule and is taken over
  once with `takeRetainedValue()`. `SecKeyVerifySignature` used to get the
  same `&error` and never released what it set (a CFError leaked per failed
  verification); it now passes `nil`, since any failure is reported as
  `badSignature` anyway.[^verifier]
- `NativeMessagingHost.searchDirectories` read the Debug-only host
  directory override with `getenv` + `String(cString:)`. It reads
  `ProcessInfo.processInfo.environment` instead, which (checked with a
  standalone program on macOS 26) sees a later `setenv`/`unsetenv`, as the
  tests that point it at a fake host need.[^host]

## Why the setting is not left on

It was a one-time audit; `project.yml` does not set it.[^task-231-8]

- The check is per module (a frontend flag); Xcode has no per-file Swift
  flags, so it cannot be scoped to the parsing code.
- Left on for the target, it adds about 200 warnings that are AppKit,
  Carbon and Objective-C runtime interop, each needing an `unsafe` marker
  with nothing to say beyond "AppKit declares this property
  `unsafe_unretained`". That noise would bury the warnings that matter in
  this app, above all "nearly matches optional requirement", the only sign
  that a WebKit delegate method has stopped being called (see
  [Swift concurrency checking](./swift-concurrency-checking.md)).
- The code that handles outside bytes is now free of unsafe constructs, so
  re-running the audit shows at once whether a change brought one back.

# Workaround

To run the audit again: add `SWIFT_STRICT_MEMORY_SAFETY: YES` to the
Detour target's `settings.base` in `project.yml` (never on the xcodebuild
command line: it would reach GRDB and Sparkle), `xcodegen generate`, build
into `.derived` (a changed setting rebuilds every file), and collect
`grep -E '^/.*: warning: .*#StrictMemorySafety' | sort -u`. Remove the
setting and regenerate afterwards. `CRX3Verifier.swift`,
`CRXUnpacker.swift`, `NativeMessagingHost.swift` and
`Data+LittleEndian.swift` should report nothing.

For new code that parses bytes from outside the app: read fixed-width
fields with `littleEndianUInt32(at:)` (or a sibling written the same way),
compare every length against the bytes that remain before converting or
adding it (see [Installer and CRX](../extensions/installer-and-crx.md)),
and count offsets from `startIndex`.

# Related

- [Swift concurrency checking](./swift-concurrency-checking.md) — the other compiler checking turned on in the same epic, and the warning this one would drown.
- [Installer and CRX](../extensions/installer-and-crx.md) — the CRX container and header the verifier parses.
- [Native messaging](../extensions/native-messaging.md) — the framing the read loop parses.

[^task-231-8]: TASK-231.8
[^le-bytes]: Data+LittleEndian.swift
[^verifier]: CRX3Verifier.swift
[^host]: NativeMessagingHost.swift
[^framing-tests]: NativeMessagingFramingTests.swift
[^se-0458]: SE-0458
