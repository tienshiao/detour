---
type: Feature
title: Content blocking Clear Cache & Redownload
description: "What Settings > Content Blocking's Clear Cache & Redownload removes and refetches, and how a compile or look-up asked for before it is refused at every stage (compile tickets, ContentRuleStore's generation, CompileOutcome.superseded) so cleared lists cannot come back (TASK-202); refresh tokens for the Updating... state, what is still not handled, and the runtime runs online, offline and before the fix."
tags: [content-blocker, webkit, settings]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:39:06Z }
sources:
  - id: manager
    resource: ../../Detour/Browser/ContentBlocker/ContentBlockerManager.swift
    title: ContentBlockerManager.swift (clearCacheAndRedownload, FilterListCompileOrder, FilterListRefreshes)
  - id: rule-store
    resource: ../../Detour/Browser/ContentBlocker/ContentRuleStore.swift
    title: ContentRuleStore.swift (invalidateAll, generation, CompileOutcome)
  - id: threading-tests
    resource: ../../DetourTests/ContentRuleStoreThreadingTests.swift
    title: ContentRuleStoreThreadingTests.swift
  - id: task-202
    resource: backlog:TASK-202
    title: Clear Cache & Redownload can be undone by a compile that was already running
  - id: webkit-rule-list-store
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/APIContentRuleListStore.cpp
    title: WebKit APIContentRuleListStore.cpp (work queue per store path)
  - id: harness
    resource: ../../docs/harness/task202-harness.patch
    title: TASK-202 runtime harness (lists served by a URLProtocol)
---

Clear Cache & Redownload (Settings > Content Blocking) throws away every
compiled filter list and its cached text and fetches the lists again. The
hard part is the work already under way when it is pressed: since TASK-202
nothing asked for before the clear can record anything after it. Part of
[content blocking](./content-blocking.md); the compile pipeline it interrupts
is [rule-list compilation](./content-blocking-rule-compilation.md).

# What it does

`ContentBlockerManager.clearCacheAndRedownload` removes every compiled
list (`ContentRuleStore.invalidateAll`), the cached text and the bookkeeping
keys, then fetches every list unconditionally. Until TASK-202 nothing
stopped the work already under way: a compile waiting in `waitingCompiles`,
encoding, inside WebKit or searching for bad rules completed afterwards and
recorded its chunks and counts, and the manager its `rulesFormat`, all from
text that had just been deleted. With the redownload offline the cleared
lists came back, marked current, with no cache text, ETag or `lastFetch`
behind them. A compile already in WebKit also rewrote its file after
`invalidateAll`'s removal (WebKit's store runs compiles and removals on one
serial work queue per store path, in call order), so the next launch found
it.[^task-202]

The AdGuard URL Tracking list is cleared too, and redownloaded only while its
switch is on (see [the lists](./content-blocking.md#lists)).

# How earlier work is refused

Now two layers each refuse what was asked for before the clear:

| Stage at the clear | What stops it |
|---|---|
| Text chosen (a cache read or a download's text) but not yet handed to the store: parsing on the parse queue | `FilterListCompileOrder.supersedeTicketsTaken()`: every ticket taken before the clear is refused at `shouldStartCompile` ("Not compiling ...: ... or the cache was cleared"). A cache read that then finds its file deleted does not fall back to a download (`isSuperseded(ticket:)`); the clear's own redownload stands in for it. A download whose response arrives after the clear is not refused: its text is fresh from the server, so it is cached and compiled like the redownload's. |
| Handed to the store | `ContentRuleStore`'s `generation`, bumped by `invalidateAll`; `compile` keeps the generation it was called in. Waiting for its list: completes when dequeued, never encoded. Encoding: completes when the encoding comes back to main. Inside WebKit: the chunk's callback removes what WebKit wrote and completes only once the removal is done, so the next compile of the list (queued behind it) cannot be overtaken by the removal. Bad-rule search: stops probing, no cleaned list is compiled. |
| A launch look-up | `lookUpList` answered after the clear records nothing and removes what it found from WebKit's store (`invalidateAll` removes only the chunks in memory, so the next launch would find it), unless a compile of the list asked for since is running or has recorded the chunk. `initialize` tickets each look-up, so one answered after the clear neither compiles from cache nor downloads. |

A superseded compile completes `CompileOutcome.superseded`, distinct from
`.failed`: the manager treats `.failed` from a cache compile as "no usable
cache" and downloads the list, so a superseded one would have added a second
download beside the clear's. It does nothing for `.superseded`.

`refreshingIdentifiers` (Settings' "Updating...") is kept per refresh
(`FilterListRefreshes`): Update Now and Clear Cache & Redownload each
`begin` a refresh with a token, and every way its fetch ends (an error, a
304, a dropped or superseded compile, a compile) `end`s its own token. A
fetch from before a newer refresh of the same list, ending late, leaves the
newer one running. Before, a download dropped by the ticket check never
cleared its list's flag, and a superseded compile ending would have cleared
the redownload's.

Nothing removes one list from the store (switching a list off in a profile
only stops attaching it; the compiled list is shared by every profile), so
`invalidateAll` is the only invalidation and one store-wide generation is
enough. The queued compiles are not dropped from `waitingCompiles` at the
clear: they complete `.superseded` in turn, which keeps a list's compiles
strictly ordered (the redownload's compile waits for the superseded one's
removal).

# Not handled

Web views keep the rule lists they already have after the
clear until the next rules change (the redownload's compile posts it);
offline, the selected tab keeps blocking with the cleared lists while new
tabs get none. That predates TASK-202.

# Seen at runtime

Seen at runtime (`docs/harness/task202-harness.patch`, lists served by a
URLProtocol, the clear 1.5 s after easylist's launch compile was handed to
the store):[^task-202]

| Run | At the clear | Result |
|---|---|---|
| online | easylist and easyprivacy in WebKit, easylist-cookie encoding, urlhaus-filter parsing | each superseded at that stage (os_log "Discarded the compile of easylist: the rule lists were cleared while it ran", "... while it was encoded", "Not compiling urlhaus-filter from cache: ... or the cache was cleared"); one fetch per list; every list then the redownload's counts (71,319 / 56,313 / 25,082 / 102,778, three rules more than the cached text) with `rulesFormat` 3 |
| offline | the same | nothing compiled, no `rulesFormat`, no file in the rule list store, "Not loaded" in Settings, 4 fetches (the clear's) |
| offline, code before TASK-202 | the same | all four lists Active with `rulesFormat` 3 and their files back in the store, cache text gone, 8 fetches |

# Tests

`ContentRuleStoreThreadingTests`, for Clear Cache & Redownload (TASK-202):
an injected WebKit compile (`RuleListCompiler`) calls `invalidateAll`
while WebKit compiles or at the first bad-rule probe: the compile is
`.superseded`, records nothing and leaves nothing in WebKit's store (a new
store finds nothing); a compile asked for after the clear is kept even
though the superseded one finished later; compiles queued or encoding at
the clear never reach WebKit; a look-up answered after it records nothing;
tickets taken before it are refused; `FilterListRefreshes` tokens.

# Related

- [Rule-list compilation](./content-blocking-rule-compilation.md) - the two other ordering rules and the queues each stage runs on.
- [Content blocking chunks](./content-blocking-chunks.md) - `invalidateAll` among the list-level operations.
- [Settings panes](./settings-panes.md#content-blocking) - the Content Blocking pane that has the button.

[^task-202]: Clear Cache & Redownload can be undone by a compile that was already running
