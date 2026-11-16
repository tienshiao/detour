---
type: Concept
title: Content blocking chunks
description: "How a filter list over WebKit's 150,000-rule cap is compiled as several rule lists and kept together (ContentRuleListChunks, the list-level ContentRuleStore operations, chunkCount in defaults), what each chunk holds so an @@ exception reaches block rules in every chunk (TASK-155), how close the shipped lists are to the cap, a real list padded past the cap run through the chunk path (TASK-370), and what splitting does not solve."
tags: [content-blocker, webkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T18:10:00Z }
sources:
  - id: rule-store
    resource: ../../Detour/Browser/ContentBlocker/ContentRuleStore.swift
    title: ContentRuleStore.swift (ContentRuleListChunks, ContentRuleStore)
  - id: manager
    resource: ../../Detour/Browser/ContentBlocker/ContentBlockerManager.swift
    title: ContentBlockerManager.swift (ruleLists(for:in:))
  - id: chunk-tests
    resource: ../../DetourTests/ContentRuleListChunkTests.swift
    title: ContentRuleListChunkTests.swift
  - id: exception-tests
    resource: ../../DetourTests/ContentBlockerExceptionTests.swift
    title: ContentBlockerExceptionTests.swift (the split layout keeping the element-hiding section in chunk 0)
  - id: task-145
    resource: backlog:TASK-145
    title: A filter list over 150,000 rules attaches only its first chunk
  - id: task-155
    resource: backlog:TASK-155
    title: In a split filter list an exception in a later chunk than its block rule does not apply
  - id: task-199
    resource: backlog:TASK-199
    title: $generichide / $elemhide exceptions compile to ignore-previous-rules and unblock all loads on those hosts
  - id: task-370
    resource: backlog:TASK-370
    title: "Content blocking: exercise the over-cap chunking on a real list (urlhaus-filter is at 73% of the cap and growing)"
  - id: task-359
    resource: backlog:TASK-359
    title: "Content blocking: an open Quick Detour window keeps the rule lists it was created with"
---

WebKit is given at most 150,000 rules as one rule list. A longer filter list
is compiled as several rule lists ("chunks"), and everything that handles a
list has to treat the chunks as one. No shipped list has reached the cap;
`urlhaus-filter`, the closest, was at 72.7% of it on 2026-11-15 and growing
([how close](#how-close-the-lists-are)). The chunk path has been run on
real lists padded past the cap, in a gated test
([a real list past the cap](#a-real-list-past-the-cap)). Part of
[content blocking](./content-blocking.md); the compile itself is
[rule-list compilation](./content-blocking-rule-compilation.md).

# Lists over the rule cap

WebKit is given at most 150,000 rules as one rule list
(`ContentRuleStore.defaultMaxRulesPerList`). A longer filter list is compiled
in chunks of at most that size: chunk 0 under the list's identifier, chunk N
as `<id>-<N>`. The arithmetic is the pure functions of
`ContentRuleListChunks`: what each chunk holds (next section), the
identifiers of a list, and the stale identifiers a longer previous compile
left. Each chunk is an independent rule list in WebKit's store, so
`ContentRuleStore` keeps the set together:

| Operation | Rule |
|---|---|
| `compile(identifier:rules:)` | Compiles every chunk. When at least one compiled it records the list's chunk count, removes stale chunks, and completes `.compiled` with all of the list's chunks. When none did, the list is left as it was (`.failed`). Cleared meanwhile: `.superseded` (see [Clear Cache & Redownload](./content-blocking-clear-cache.md)). |
| `cachedLists(forList:)` | Every compiled chunk, in order. This is what a web view gets. |
| `compiledRuleCount(forList:)`, `isCompiled(list:)` | The sum over the chunks, an exception the chunks repeat counted once; compiled when any chunk is. Settings shows these. |
| `lookUpList(identifier:)` | The launch path: looks up as many chunks as the last compile recorded. |
| `invalidateAll()` | Removes every chunk and forgets rule counts and chunk counts. Supersedes every compile and look-up asked for before it. |

The chunk count of a list lives in defaults as
`ContentBlocker.<id>.chunkCount`, written only when it is above 1, so a list
that has never been split has exactly the keys it had before.

Disabling a list and the per-site switch need no chunk-specific code. The
window removes **all** rule lists from the web view and re-applies what the
profile still has on, and the per-site switch turns off every rule list for
the navigation. Both are covered by web view tests with a rule in the last
chunk.

Until TASK-145 only the first chunk was attached, counted and looked up at
launch, and a list that shrank kept its old later chunks in WebKit's store
for good.[^task-145]

## How close the lists are

Parser output for the lists as fetched on 2026-11-15, counted with
`EasyListParser` (`rulesFormatVersion` 3) built standalone with `swiftc`,
and each list compiled whole through a temporary `WKContentRuleListStore`
by the same tool (the TASK-145 method, plus the compile):[^task-359]

| List | Parsed rules | Lines skipped | Compiled | Share of the cap |
|---|---|---|---|---|
| `easylist` | 73,252 | 3,562 | 73,252 (2.5 s) | 48.8% |
| `easyprivacy` | 56,555 | 106 | 56,555 (2.2 s) | 37.7% |
| `easylist-cookie` | 25,109 | 273 | 25,109 (1.5 s) | 16.7% |
| `urlhaus-filter` | 109,083 | 1 | 109,083 (7.3 s) | 72.7% |

Every list compiled in one piece, with no rule stripped. Compile times are
from one run on a loaded machine. The Debug app, launched minutes later on
a fresh isolated data directory, recorded the same counts in its
`ruleCount` and `compiledRuleCount` keys, except `easylist` at 73,255
(its copy was fetched later and was 72 bytes longer).

Earlier counts, for the trend (parsed unless noted; each parser version of
its day; the first two columns from TASK-145):[^task-145]

| List | 2026-10-02 | 2026-10-04 | 2026-10-12 (compiled, after TASK-199) | 2026-10-26 | 2026-11-15 |
|---|---|---|---|---|---|
| `easylist` | 74,973 | 75,661 | 78,190 | 71,316 | 73,252 |
| `easyprivacy` | 56,146 | 56,158 | 56,209 | 56,310 | 56,555 |
| `easylist-cookie` | 25,002 | 25,010 | 25,022 | 25,079 | 25,109 |
| `urlhaus-filter` | 9,571 | 9,605 | 24,676 | 102,775 | 109,083 |

The 2026-10-12 counts are from the
[exceptions](./content-blocking-exceptions.md#size-and-compile-time) page,
the 2026-10-26 ones from the
[domain lists](./content-blocking-domain-lists.md#how-many-rules-this-touches)
page. The three EasyList-family lists move by a few percent between
fetches. `urlhaus-filter` is the one that grows: about tenfold from early
October to 2026-10-26, then 6% more in the 20 days to 2026-11-15. Its
growth decides when the chunk path first runs on a real list in the app; at the late
October to mid November pace it would reach the cap in a few months, but
the earlier jump shows the pace is not steady.

## A real list past the cap

`ContentRuleListChunkTests` has two gated legs
(`TEST_RUNNER_DETOUR_REAL_LIST_CHUNKS=1`; see
[build and test](../playbooks/build-and-test.md#5-environment-variables-for-the-test-host))
that take a downloaded list, pad it past the cap, and run it through the
same path the app uses (TASK-370):[^task-370]

1. The list text is read from the test data directory's cache, or else
   the app's (`~/Library/Application Support/Detour/ContentBlocker/`), and
   never written. The leg skips itself when the list is not there.
2. Padding lines `||p<n>.chunk-padding.invalid^$all` (urlhaus-filter's
   shape) go before and after the real text, so the 150,000-rule boundary
   falls in the middle of the real block rules: both chunks hold real
   rules. One padding exception, `@@||p0.chunk-padding.invalid/allowed`,
   exempts a URL of a block rule in the first chunk.
3. `ContentRuleStore` at the production cap compiles it into a temporary
   rule list store. Then a new store looks it up as at launch, and
   `ContentBlockerManager.ruleLists(for:in:)` attaches it to a `WKWebView`
   that loads one padding URL from each chunk and the exempted URL.
   Only `.invalid` hosts are loaded, so a probe that is not blocked never
   reaches a real (malware) host.

Result on 2026-11-16, with the copies in the test data directory's cache
(`DetourTests/ContentBlocker/`, downloaded by the test host on 2026-11-15;
not the copies counted above), `rulesFormatVersion` 4, Debug test host:

| List | Real rules (carried exceptions) | Padded | Chunks | Compile | Test |
|---|---|---|---|---|---|
| `urlhaus-filter` | 109,048 (0) | 205,524 | 150,000 + 55,525 | 8.2 s | 38 s |
| `easylist` | 74,992 (546) | 188,223 | 150,000 + 38,770 | 4.4 s | 17 s |

Both chunks of each list compiled with no rule stripped (the store's count
equals the parsed count), were found again by the relaunched store, and
blocked their own probe, reported under their own identifier (`<id>` and
`<id>-1`). The exempted URL was not blocked: the exception, which in list order
would be in the second chunk only, reached the block rule in the first. A
chunk of exactly 150,000 rules compiles; 150,005 do not (WebKit: "Too many
rules in JSON array", measured with a standalone compile). The test host
peaked at about 1.2 GB resident; parsing the padded urlhaus-filter (12 MB
of real text) in the Debug build took 15.6 s, the larger part of the leg.

What it does not cover: urlhaus-filter has no exceptions, so its leg checks
the slicing only; the EasyList leg adds 546 real carried exceptions and its
element-hiding section (the leg checks that no hiding rule is laid out
after the first chunk), but no element hiding is checked in the web view. A real rule is never loaded (its host
would be a live malware or ad host); the real rules are checked by
compiling them.

# What a chunk holds

An `ignore-previous-rules` rule (an `@@` exception) only undoes rules earlier
in its **own** rule list (see
[what WebKit does with an exception](./content-blocking-exceptions.md#what-webkit-does-with-an-exception)).
Chunks that were plain slices of the list would lose every exception that
landed in another chunk than the block rule it was written for, so
`ContentRuleListChunks.chunks(of:maxRulesPerList:isException:)` lays a split
list out differently (TASK-155):

- the rules that are not exceptions are sliced in list order;
- every slice is followed by **all the list's exceptions**, in list order,
  so in each chunk the exceptions come after, and undo, that chunk's block
  rules;
- a slice holds the cap less the exceptions it carries, so no chunk exceeds
  the cap.

With a cap of 4, `b0 b1 x0 b2 b3 b4 b5 b6` (`x0` an exception) becomes
`[b0 b1 b2 x0] [b3 b4 b5 x0] [b6 x0]`.

One kind of exception is not carried (TASK-199): a **page-wide** exception
(`url-filter` `.*`) ahead of the list's first block rule, which is how the
parser writes `$generichide` and `$elemhide`. In list order it undoes only
the element hiding before it; behind a chunk's block rules it would undo
those too, on every page it names. So it keeps its place, and the
element-hiding section, which the parser puts first, stays together at the
start of the first chunk. `ContentRuleListChunks.chunks(ofCompiledRules:maxRulesPerList:)`
is the wrapper `compile` uses; `$document` allowlists are page-wide too, but
come after the block rules and are carried like any exception.

| Case | Rule |
|---|---|
| A list within the cap | One chunk in list order, exactly as before TASK-155. Nothing is moved. |
| Rule count | `Chunk.countedRuleCount` is how many of a chunk's rules its list's count includes: the repeated exceptions count in the first chunk only. The list's count is therefore the number of distinct rules compiled, and "Active" equals "In List" for a split list that compiled whole. A bad rule the bisection strips lowers the count only where it was counted. |
| Exceptions near the cap | The chunks carry at most half the cap (`maxCarriedExceptions`, 75,000), the first in list order. Each chunk then keeps room for at least as many block rules and the number of chunks at most doubles. Exceptions beyond that are left out of a split list and logged as an error (`droppedExceptionCount`); "Active" is then lower than "In List". |
| A split list of only exceptions | One chunk of the carried exceptions. It undoes nothing, but the compile does not read as a failure. |

Before TASK-155 the chunks were slices of the list in order, and a web view
test with a cap of 2 showed the exempted URL blocked: the exception was the
third of three rules and its block rule the first.[^task-155] Half the cap
was chosen for the bound it gives; no real list has anything near 75,000
exceptions (EasyList as a whole is about 75,700 rules).

# What splitting does not solve

- **The element-hiding section has to fit in the first chunk.** It is not
  carried, so if it were longer than a chunk the hiding left in chunk 0 would
  not be undone by a cosmetic exception in chunk 1. EasyList's section is
  about 24,000 rules, a sixth of the cap, and EasyList itself is under half
  the cap, so this was left alone in TASK-199's review. (Before TASK-199 an unsplit list
  kept file order, so a network exception only undid the block rules above
  it; the parser now puts every network exception after every block rule, in
  split and unsplit lists alike.)
- **A chunk that fails to compile** even after bisection leaves the list
  active with the chunks that did compile. The "Active" count is then lower
  than "In List". A chunk an earlier compile left under the same identifier
  stays in use. After a parser change that chunk is from the old format while
  the list records the new one (`rulesFormat` is written when any chunk
  compiled), so it is not recompiled until the list text changes. Not
  handled: it needs a split list and a chunk that fails twice.
- **`$important` is not absolute in a split list.** The parser puts the
  `$important` block rules last, after the `$document` allowlists, but a
  split list still appends the carried exceptions to every chunk, behind
  them, so a network exception can undo an `$important` rule there. Within
  the cap (every shipped list) nothing comes after them.
- **A later chunk left by a build older than TASK-145** has no recorded
  chunk count behind it. The list reads as one chunk, so that chunk is not
  attached, and it is removed only if a later compile reuses its identifier
  and then drops it. Stale chunks are found from the recorded count, not by
  listing WebKit's store. No list has been over the cap (the
  [counts above](#how-close-the-lists-are)), so no install is expected to
  have one.

# Gotchas

- **A split list is several rule lists.** Anything that handles "the list
  `<id>`" has to go through the list-level functions of `ContentRuleStore`,
  never a single identifier. The blocked counter is unaffected: WebKit
  reports per rule list, and the tab counts a URL once per page.

# Tests

- `ContentRuleListChunkTests` - the chunk arithmetic, the layout of a split
  list (every chunk ends with the exceptions, no chunk over the cap, a
  repeated exception counted once, exceptions beyond half the cap left out),
  and a store with an injected cap of 2 rules over a private temporary rule
  list store: every chunk compiled, cached, counted, found by a new store,
  and applied for a profile; stale chunks removed when a list shrinks;
  `invalidateAll`; and in a real `WKWebView` a rule of the last chunk blocks,
  an exception exempts a block rule of an earlier and of a later chunk, a
  disabled list's chunks are all detached, and a whitelisted navigation is
  not blocked by any chunk.
  Two gated legs compile a real list padded past the production cap
  ([above](#a-real-list-past-the-cap)).
- `ContentBlockerExceptionTests` - the split layout keeping the element-hiding
  section in chunk 0.

# Related

- [Rule-list compilation](./content-blocking-rule-compilation.md) - the compile each chunk goes through.
- [Exceptions and element hiding](./content-blocking-exceptions.md) - the section order the chunk layout depends on.
- [Content blocking](./content-blocking.md#where-state-lives) - the chunk identifiers and defaults keys among the rest of the state.

[^task-145]: A filter list over 150,000 rules attaches only its first chunk
[^task-155]: In a split filter list an exception in a later chunk than its block rule does not apply
[^task-359]: Content blocking: an open Quick Detour window keeps the rule lists it was created with
[^task-370]: Content blocking: exercise the over-cap chunking on a real list (urlhaus-filter is at 73% of the cap and growing)
