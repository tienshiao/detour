---
type: Concept
title: Content blocking chunks
description: "How a filter list over WebKit's 150,000-rule cap is compiled as several rule lists and kept together (ContentRuleListChunks, the list-level ContentRuleStore operations, chunkCount in defaults), what each chunk holds so an @@ exception reaches block rules in every chunk (TASK-155), how close the shipped lists are to the cap, and what splitting does not solve."
tags: [content-blocker, webkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:59:43Z }
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
  - id: task-359
    resource: backlog:TASK-359
    title: "Content blocking: an open Quick Detour window keeps the rule lists it was created with"
---

WebKit is given at most 150,000 rules as one rule list. A longer filter list
is compiled as several rule lists ("chunks"), and everything that handles a
list has to treat the chunks as one. No shipped list has reached the cap, so
this is a safeguard rather than a path every install takes. Part of
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

No list is near the cap. Parser output for the lists as fetched on
2026-10-04; the copies fetched on 2026-10-02 gave 74,973 / 56,146 / 25,002 /
9,571, which are also the counts the installed app had recorded:[^task-145]

| List | Parsed rules | Compiled | Share of the cap |
|---|---|---|---|
| `easylist` | 75,661 | 75,661 | 50.4% |
| `easyprivacy` | 56,158 | 56,158 | 37.4% |
| `easylist-cookie` | 25,010 | 25,008 (2 stripped as invalid, fixed by TASK-201: see [domain lists](./content-blocking-domain-lists.md#how-many-rules-this-touches)) | 16.7% |
| `urlhaus-filter` | 9,605 | 9,605 | 6.4% |

Later counts are on the
[domain lists](./content-blocking-domain-lists.md#how-many-rules-this-touches)
(2026-10-26) and [exceptions](./content-blocking-exceptions.md#size-and-compile-time)
(2026-10-12) pages. `urlhaus-filter` grows fastest: 9,605 parsed rules on
2026-10-04, 24,676 compiled on 2026-10-12 and 102,775 parsed on 2026-10-26,
about two thirds of the cap, so "no list is near the cap" held less well by
the end of October than this table shows. Re-measuring every list's count
and recording it here is planned in TASK-359.[^task-359]

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
  about 24,000 rules, a sixth of the cap; no shipped list reaches the cap at
  all, so this was left alone in TASK-199's review. (Before TASK-199 an unsplit list
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
  listing WebKit's store. The lists above have been at half the cap or less,
  so no install is expected to have one.

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
- `ContentBlockerExceptionTests` - the split layout keeping the element-hiding
  section in chunk 0.

# Related

- [Rule-list compilation](./content-blocking-rule-compilation.md) - the compile each chunk goes through.
- [Exceptions and element hiding](./content-blocking-exceptions.md) - the section order the chunk layout depends on.
- [Content blocking](./content-blocking.md#where-state-lives) - the chunk identifiers and defaults keys among the rest of the state.

[^task-145]: A filter list over 150,000 rules attaches only its first chunk
[^task-155]: In a split filter list an exception in a later chunk than its block rule does not apply
[^task-359]: Content blocking: an open Quick Detour window keeps the rule lists it was created with
