---
type: Feature
title: Content blocking Clear Cache & Redownload
description: "What Settings > Content Blocking's Clear Cache & Redownload removes and refetches, and how a compile or look-up asked for before it is refused at every stage (compile tickets, ContentRuleStore's generation, CompileOutcome.superseded) so cleared lists cannot come back (TASK-202); refresh tokens for the Updating... state, the old lists pages keep until each list compiles again (TASK-369), and the runtime runs."
tags: [content-blocker, webkit, settings]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T17:25:00Z }
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
  - id: task-369
    resource: backlog:TASK-369
    title: "Content blocking: between Clear Cache & Redownload and the next compile, open pages keep the old lists"
  - id: live-page-tests
    resource: ../../DetourTests/LivePageContentBlockingTests.swift
    title: LivePageContentBlockingTests.swift
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

# Pages between the clear and the recompile

Decided (TASK-369, Claude's choice, not yet confirmed by the user): until a
cleared list compiles again, pages keep blocking with its old rules, open
ones and ones opened meanwhile alike. Removing them would leave every page
unblocked for as long as the redownload takes (indefinitely offline), which
the user asked for no part of; they pressed Clear Cache & Redownload to get
fresh lists, not none.

`invalidateAll` keeps each list's chunks in memory (`clearedLists`): the
set its last completed compile or launch look-up gave (`completedLists`),
not what `compiledLists` holds at that moment, where a refresh still inside
WebKit has already recorded some of its new chunks beside the old ones
(found in review; a test holding back one of three chunks failed with the
first version, which read `compiledLists`). And `ContentRuleStore.attachableLists(forList:)` (what
`ContentBlockerManager.ruleLists(for:in:)` attaches) gives them for a list
that has no compiled chunk. A list's next compile drops them, and the
rules change it posts replaces them on every page
([attaching lists](./content-blocking.md#attaching-lists-to-web-views)).
They are only for attaching: `isCompiled`, the counts and Settings say the
list is cleared ("No active rules. Updating 4 lists..."), they are never
written anywhere, and a second clear before the recompile keeps the first
clear's. WebKit keeps applying a `WKContentRuleList` whose file was removed
from its store, in a new web view too. A list or the master switch turned
off in the gap still takes them off, as for a compiled list. A redownload
that fails (offline, or a list that no longer compiles) leaves them in use
until the app quits; the next launch has nothing.

Before, the clear posted no rules change, so open pages kept the old lists
only until the next one: the first list to compile again (or a switch
flipped in Settings) replaced every page's lists with the store's, which
held only that list, so the other three stopped blocking until theirs
compiled; a page opened in the gap got none. A test confirmed it: after a
clear and one list's recompile, a background page no longer blocked with
the other list.[^task-369]

Seen at runtime (real lists, a loopback page asking for EasyPrivacy's
`/1pixel.php` every 2 s in a background tab): Clear Cache & Redownload at
09:13:21, a new tab with the same page at :22; easylist-cookie compiled at
:24, easyprivacy :27, easylist :29, urlhaus-filter :45; neither tab ever
asked for `/1pixel.php` (a build before the `completedLists` change).
Again on the final build, after a relaunch so the lists came from the
launch look-up: Clear Cache at 09:27:37, a new tab at :38; easylist
recompiled at :43, easyprivacy :45; the new tab polled at :40, :42 and :44
and never asked for `/1pixel.php` (the screen locked at about :44, which
stopped the pages' timers, so the background tab's run is from the first
build only).[^task-369]

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

`LivePageContentBlockingTests`, for the pages in between (TASK-369): after
a clear and one list's recompile a background page still blocks with the
other list's old rules, and with its new ones once it compiles; a page
opened after the clear (cleared twice) blocks with the kept lists, and a
list switched off then stops blocking on it and on the background page; the
kept lists are not compiled and a store opened on the same folder finds
nothing. The first two failed before the change.
`ContentRuleStoreThreadingTests`: a clear after a launch look-up keeps the
chunks the look-up found; a clear while a refresh has two of three chunks
back keeps the previous compile's chunks.

# Related

- [Rule-list compilation](./content-blocking-rule-compilation.md) - the two other ordering rules and the queues each stage runs on.
- [Content blocking chunks](./content-blocking-chunks.md) - `invalidateAll` among the list-level operations.
- [Settings panes](./settings-panes.md#content-blocking) - the Content Blocking pane that has the button.

[^task-202]: Clear Cache & Redownload can be undone by a compile that was already running
[^task-369]: Content blocking: between Clear Cache & Redownload and the next compile, open pages keep the old lists
