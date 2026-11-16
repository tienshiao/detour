---
type: Component
title: Content blocking rule-list compilation
description: "ContentRuleStore's compile of a parsed filter list into WKContentRuleLists: JSON encoding, the bad-rule bisection and its probe lists, which queue each step runs on (TASK-200: only WebKit's store calls, its synchronous JSON parse and the bookkeeping stay on main), the compiler-checked Sendable hand-offs, and the two ordering rules (one compile per list at a time, older text never replacing newer)."
resource: ../../Detour/Browser/ContentBlocker/ContentRuleStore.swift
tags: [content-blocker, webkit, concurrency]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:39:06Z }
sources:
  - id: rule-store
    resource: ../../Detour/Browser/ContentBlocker/ContentRuleStore.swift
    title: ContentRuleStore.swift (ContentBlockerStorage, ContentRuleStore)
  - id: manager
    resource: ../../Detour/Browser/ContentBlocker/ContentBlockerManager.swift
    title: ContentBlockerManager.swift (parse queue, FilterListCompileOrder)
  - id: threading-tests
    resource: ../../DetourTests/ContentRuleStoreThreadingTests.swift
    title: ContentRuleStoreThreadingTests.swift
  - id: task-200
    resource: backlog:TASK-200
    title: Serialise block-list rules to JSON and search for bad rules off the main thread
  - id: task-231-3
    resource: backlog:TASK-231.3
    title: Content-blocker list parsing and rule compilation are compiler-checked across threads
  - id: task-201
    resource: backlog:TASK-201
    title: Cosmetic rules with both included and excluded domains compile to a trigger WebKit rejects
  - id: webkit-rule-list-store
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/APIContentRuleListStore.cpp
    title: WebKit APIContentRuleListStore.cpp (main-thread asserts, JSON parsed on main, work queue per store path)
  - id: harness
    resource: ../../docs/harness/task200-harness.patch
    title: TASK-200 runtime harness (main-queue heartbeat)
---

`ContentRuleStore` turns a parsed filter list into compiled
`WKContentRuleList`s and keeps the record of what is compiled. The parser's
output comes from [filter-list conversion](./content-blocking-filter-conversion.md);
what it compiles is attached by [content blocking](./content-blocking.md).
A list over the rule cap is compiled as several rule lists
([chunks](./content-blocking-chunks.md)), and
[Clear Cache & Redownload](./content-blocking-clear-cache.md) can supersede a
compile at any stage.

# How it works

**Compile** (`ContentRuleStore`) encodes the rules to JSON and hands it
to `WKContentRuleListStore`. On a compile error it bisects the rules
(`findBadRules`, depth capped at 20, serial) to find and strip the
individually bad ones, then recompiles. A slice still failing at the depth
cap is marked bad as a whole. A list over the rule cap is compiled as several
rule lists; see [chunks](./content-blocking-chunks.md). Which queue each step
runs on is in "Threading".

A stripped rule lowers the list's count only where it was counted (see
[what a chunk holds](./content-blocking-chunks.md#what-a-chunk-holds)).

# Threading

Since TASK-200 the main queue does only what WebKit requires there and the
bookkeeping:[^task-200]

| Step | Queue |
|---|---|
| Read the cached text, parse it (`EasyListParser`, 1.3–1.8 s per list with `-O`) | the manager's serial parse queue (one list at a time; a missing cache file is checked on main first, so its fallback download doesn't wait behind other lists' parses) |
| Download (`URLSession.shared`), write the text to the cache | `URLSession`'s delegate queue |
| Parse a download | the same serial parse queue: one list's rules in memory at a time, so Clear Cache & Redownload and the post-upgrade recompile don't hold all four lists' parse results at once (the review's memory finding; parallel parsing was faster but rejected for peak memory) |
| Record the ETag, `lastFetch`, `ruleCount`, `rulesFormat`, `refreshingIdentifiers`; take and check the compile ticket | main |
| Split into chunks, encode each chunk to JSON (`ContentRuleStore.encodedRuleList`, about 270 ms for EasyList), slice and encode every bad-rule probe and the cleaned chunk | `ContentRuleStore`'s serial work queue (`com.detourbrowser.content-rule-store`, utility) |
| `WKContentRuleListStore` compile / look up / remove / list identifiers | main (the calls), WebKit's own work queue (the compile to bytecode, file I/O) |
| Record the compiled list and counts, attach (`reapplyRuleLists` → each window's user content controllers) | main |

The parse queue is `com.detourbrowser.content-blocker-parse` (utility).

The compiler checks these hand-offs (TASK-231.3):[^task-231-3] a rule is
`ContentRule = [String: any Sendable]`, not `[String: Any]`, so a parsed list
can cross from the parse queue to main and on to the work queue as a
`Sendable` value; `EasyListParser`, the chunking helpers and
`encodedRuleList` are `nonisolated`; the work queue's closures are
`@Sendable` and their continuations `@MainActor`. `any Sendable` changes no
runtime representation, so the JSON is byte-for-byte what it was.
`encodedRuleList` checks `JSONSerialization.isValidJSONObject` first: the
type admits any `Sendable` value, and a non-JSON one would otherwise raise an
Objective-C exception on the work queue instead of failing the compile.

## What WebKit requires

What WebKit requires (`APIContentRuleListStore.cpp`, main as of
2026-10):[^webkit-rule-list-store] `WKContentRuleListStore` is
`WK_SWIFT_UI_ACTOR`, and every store call (`compileContentRuleList`,
`lookupContentRuleList`, `removeContentRuleList`,
`getAvailableContentRuleListIdentifiers`) starts with
`ASSERT(RunLoop::isMain())` and completes on the main run loop, so the calls
stay on main. The public compile also **parses the JSON synchronously on the
calling (main) thread** (`parseRuleList` with `CSSSelectorsAllowed::Yes`, to
validate the CSS selectors) before dispatching the bytecode compile to the
store's work queue; only WebKit's own declarativeNetRequest path parses off
main. A rule the parse rejects (an invalid selector, or two conditions in one
trigger) fails synchronously inside the call. That parse is the part of a
compile left on main; sampled, it was 34 of 13,620 main-thread samples
across a recompile of all four lists, so it does not stall the UI.

## Ordering

Order is kept in two places:

- **One compile of a list at a time.** `ContentRuleStore.compile` (main
  only, `dispatchPrecondition`) queues a compile behind the running compile
  of the same list (`waitingCompiles`) and starts it once that one has
  completed, bad-rule search included. Without this, a compile still
  searching for bad rules recorded its list over a later compile that
  finished first (`easylist-cookie` searched on every compile for its 2
  bad rules until TASK-201 fixed them).
  Different lists compile independently; the work queue is serial, so the
  chunks of a list reach WebKit in order. (WebKit also fixed parallel
  compiles of one identifier failing, in 2025-07.)
- **Older text never replaces newer text.** Parsing is off main, so a
  cache compile read at launch could be ready after a download that arrived
  meanwhile and would be queued behind it. `FilterListCompileOrder` gives
  each compile a ticket on main when its text is chosen (a cache read when
  it starts, a download after its text is written to the cache), and a
  compile is dropped ("Not compiling ...: a compile of newer text has
  started") when a newer ticket of its list already started.

- **Clear Cache & Redownload wins over everything before it** (TASK-202):
  see [Clear Cache & Redownload](./content-blocking-clear-cache.md).

## Measured

Measured with the main-queue heartbeat (`docs/harness/task200-harness.patch`,
same scenarios as TASK-199, Debug build, load average 18–45): the upgrade
recompile of all four lists went from gaps of 486, 515 and 527 ms (TASK-199:
403, 511, 491) to none over 250 ms; a mid-session update of `easylist` and
`easylist-cookie` from 571 and 361 ms to none. What remains is the launch
tick (about 430–450 ms, with or without a compile) and the harness creating
its first test tab (WebContent launch, 250–650 ms). Rules are still freed on
main when a compile completes (28 samples per recompile).[^task-200]

# Gotchas

- **Bisection compiles probe lists into the real store.** Each probe uses the
  identifier `<id>-probe-<offset>-<count>` (with a chunk's identifier for
  `<id>` when the list is split) and is removed again when it compiles.
- **"No individual bad rules found"** means the full set fails while each
  half compiles (a combined state limit); the list is then not compiled at
  all.

# Tests

`ContentRuleStoreThreadingTests` - encoding of every chunk, every bad-rule
probe and the cleaned chunk off the main queue (an injected encoder records
the thread), the default encoding equal to the JSON given to WebKit before
and a compiled store file byte-identical to one compiled from it, a second
compile of a list waiting for the first's bad-rule search (the second's
list is kept), different lists not waiting for each other, and the
`FilterListCompileOrder` tickets. Its Clear Cache & Redownload cases are
listed in [Clear Cache & Redownload](./content-blocking-clear-cache.md#tests).

# Related

- [Content blocking chunks](./content-blocking-chunks.md) - the list-level operations for a list compiled as several rule lists.
- [Clear Cache & Redownload](./content-blocking-clear-cache.md) - the third ordering rule.
- [Filter-list conversion](./content-blocking-filter-conversion.md) - the parse step and the upgrade recompile.
- [Swift concurrency checking](../platform/swift-concurrency-checking.md) - the project's rules for the `Sendable` hand-offs.

[^task-200]: Serialise block-list rules to JSON and search for bad rules off the main thread
[^task-231-3]: TASK-231.3
[^webkit-rule-list-store]: WebKit APIContentRuleListStore.cpp (main-thread asserts, JSON parsed on main, work queue per store path)
