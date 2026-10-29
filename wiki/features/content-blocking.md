---
type: Feature
title: Content blocking
description: "The built-in blocker: EasyList-family filter lists compiled to WKContentRuleLists, per-profile list toggles, the per-site switch implemented through a WebKit preferences SPI, and the blocked-resource counter."
tags: [content-blocker, webkit, profiles, spi, privacy]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-27T09:30:00Z }
sources:
  - id: manager
    resource: ../../Detour/Browser/ContentBlocker/ContentBlockerManager.swift
    title: ContentBlockerManager.swift
  - id: rule-store
    resource: ../../Detour/Browser/ContentBlocker/ContentRuleStore.swift
    title: ContentRuleStore.swift (ContentBlockerStorage, ContentRuleStore)
  - id: parser
    resource: ../../Detour/Browser/ContentBlocker/EasyListParser.swift
    title: EasyListParser.swift
  - id: whitelist
    resource: ../../Detour/Browser/ContentBlocker/ContentBlockerWhitelist.swift
    title: ContentBlockerWhitelist.swift
  - id: navigation
    resource: ../../Detour/Browser/Window/BrowserWindowController+Navigation.swift
    title: BrowserWindowController+Navigation.swift
  - id: window-controller
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift (handleContentBlockerRulesChanged)
  - id: doc
    resource: ../../docs/content-blocking.md
    title: docs/content-blocking.md
  - id: task-69
    resource: backlog:TASK-69
    title: The "Block content on this site" switch does not take effect
  - id: task-36
    resource: backlog:TASK-36
    title: Stop the test host writing WebKit data into the production app's WebKit directory
  - id: whitelist-tests
    resource: ../../DetourTests/ContentBlockerWhitelistTests.swift
    title: ContentBlockerWhitelistTests.swift
  - id: blocker-tests
    resource: ../../DetourTests/ContentBlockerTests.swift
    title: ContentBlockerTests.swift
  - id: task-145
    resource: backlog:TASK-145
    title: A filter list over 150,000 rules attaches only its first chunk
  - id: chunk-tests
    resource: ../../DetourTests/ContentRuleListChunkTests.swift
    title: ContentRuleListChunkTests.swift
  - id: task-155
    resource: backlog:TASK-155
    title: In a split filter list an exception in a later chunk than its block rule does not apply
  - id: task-199
    resource: backlog:TASK-199
    title: $generichide / $elemhide exceptions compile to ignore-previous-rules and unblock all loads on those hosts
  - id: exception-tests
    resource: ../../DetourTests/ContentBlockerExceptionTests.swift
    title: ContentBlockerExceptionTests.swift
  - id: task-200
    resource: backlog:TASK-200
    title: Serialise block-list rules to JSON and search for bad rules off the main thread
  - id: threading-tests
    resource: ../../DetourTests/ContentRuleStoreThreadingTests.swift
    title: ContentRuleStoreThreadingTests.swift
  - id: webkit-rule-list-store
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/APIContentRuleListStore.cpp
    title: WebKit APIContentRuleListStore.cpp (main-thread asserts, JSON parsed on main, work queue per store path)
  - id: webkit-backend
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebCore/contentextensions/ContentExtensionsBackend.cpp
    title: WebKit ContentExtensionsBackend.cpp (per-list evaluation, global style sheet gate)
  - id: webkit-compiler
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebCore/contentextensions/ContentExtensionCompiler.cpp
    title: WebKit ContentExtensionCompiler.cpp (action merging, conditions)
  - id: webkit-parser
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebCore/contentextensions/ContentExtensionParser.cpp
    title: WebKit ContentExtensionParser.cpp (one condition per trigger, if-domain to page URL regex, lower-case ASCII domains)
  - id: task-201
    resource: backlog:TASK-201
    title: Cosmetic rules with both included and excluded domains compile to a trigger WebKit rejects
  - id: domain-list-tests
    resource: ../../DetourTests/ContentBlockerDomainListTests.swift
    title: ContentBlockerDomainListTests.swift
  - id: task-162
    resource: backlog:TASK-162
    title: In a filter list, an exception rule does not undo the block rules that come after it
  - id: task-202
    resource: backlog:TASK-202
    title: Clear Cache & Redownload can be undone by a compile that was already running
---

# What it does

Detour blocks ads, trackers, cookie notices and known-malicious URLs with
WebKit's `WKContentRuleList`. Four filter lists are fetched, converted from
AdBlock Plus syntax to WebKit rule JSON, compiled, and attached to each tab's
user content controller according to the tab's
[profile](../architecture/profiles-and-spaces.md). A per-site switch in the
sidebar's settings popover ("Block content on this site") turns blocking off
for one host in one profile, and the popover shows how many resources were
blocked on the current page.

# How it works

## Lists

| Identifier | Shown as | Profile toggle |
|---|---|---|
| `easylist` | EasyList (ads) | `isEasyListEnabled` |
| `easyprivacy` | EasyPrivacy (trackers) | `isEasyPrivacyEnabled` |
| `easylist-cookie` | Cookie notices | `isEasyListCookieEnabled` |
| `urlhaus-filter` | Malicious URLs | `isMalwareFilterEnabled` |

`Profile.isAdBlockingEnabled` is the master switch. The toggles live in
Settings > Profiles; list status and refresh live in Settings > Content
Blocking (see [settings](./settings.md)).

## Fetch, parse, compile

`ContentBlockerManager.shared.initialize()` runs at launch. For each list it
asks WebKit's store for an already compiled list; if there is one **and** it
was compiled from the parser's current output, it only checks whether a
refresh is due (24 hours since `lastFetch`). Otherwise it compiles from the
cached text file, and fetches when there is no cache. A list compiled from an
older parser output is recompiled even though nothing was fetched: see
"Recompiling after a parser change".

- **Fetch** is conditional (`If-None-Match` with the stored ETag,
  `If-Modified-Since`). A 304 only moves the timestamp. The fetch that stands
  in for a missing or uncompilable cache at launch is not
  (`fetchAndCompile(list:conditional: false)`): an unchanged list would
  answer 304 and leave nothing to compile, so a list found in an old format
  would stay attached as it was.
- **Parse** (`EasyListParser`) emits `block`, `ignore-previous-rules` (for `@@`
  exceptions) and `css-display-none` (for `##` element hiding) rules, ordered
  by section, not by file order (see "Exceptions and element hiding"). It skips
  what WebKit cannot express: extended CSS and snippet filters (`#?#`, `#$#`),
  element-hiding exceptions (`#@#`), and blocking rules with `popup`,
  `websocket`, `webrtc`, `csp`, `rewrite`, `redirect` or `ping` options. A
  `$badfilter` line and the rule it names (the same line without the option)
  are both dropped and counted as skipped. ABP
  regex literals are rewritten: `{n,m}` quantifiers are expanded into repeated
  atoms and `(a|b)` disjunctions into several rules, because WebKit's rule
  regex supports neither. A domain list (`a.example,~b.example##`,
  `$domain=a|~b`) becomes one page condition; see "Domain lists".
- **Compile** (`ContentRuleStore`) encodes the rules to JSON and hands it
  to `WKContentRuleListStore`. On a compile error it bisects the rules
  (`findBadRules`, depth capped at 20, serial) to find and strip the
  individually bad ones, then recompiles. A list over the rule cap is
  compiled as several rule lists; see the next section. Which queue each
  step runs on is in "Threading".

Every successful compile posts `.contentBlockerRulesDidChange`
(`reapplyRuleLists`); status changes post `.contentBlockerStatusDidChange` for
the Settings pane.

## Domain lists

WebKit takes **one** page condition per trigger: `if-domain`,
`unless-domain`, `if-top-url`, `unless-top-url`, `if-frame-url` or
`unless-frame-url`; a second one fails the whole compile ("more than one
condition", `JSONMultipleConditions`). `if-domain` and `unless-domain` are
compiled into page URL regexes (`[a-z][a-z+.-]*:\/\/([^/]*\.)*<domain>[:/]`
for a `*domain`), and a domain must be lower-case ASCII
(`JSONDomainNotLowerCaseASCII`).[^webkit-parser] Until TASK-201 the parser
gave a list with included **and** excluded domains both an `if-domain` and an
`unless-domain`; the bad-rule search then stripped the rule.[^task-201]

`EasyListParser.domainCondition(included:excluded:)` now gives one condition,
for element hiding and `domain=` alike, with Adblock Plus's rule that the
most specific listed domain decides for a page:

| Domain list | Condition |
|---|---|
| none | none |
| only included | `if-domain` |
| only excluded | `unless-domain` |
| an exclusion outside every included domain (`a.example,~b.example`) | dropped (a no-op): `if-domain` |
| an included domain also excluded (`a,~a`) | that domain dropped; none left: the rule is skipped (counted) |
| included domains none of which converts to ASCII | the rule is skipped, never widened to every page |
| an exclusion under an included domain (`a.example,~sub.a.example`) | `if-top-url`: patterns for the included domains less the excluded subtrees |

WebKit's URL regexes have no alternation and no lookahead, so "any subdomain
but `sub`" is spelled out as several `if-top-url` entries, walking the
exclusions as a tree of labels: the node's own host exactly, any host whose
next label is none of the node's children, and each child that is not
excluded itself, recursively. "Any label but `sub`" is `[^/.:s][^/.:]*`, `s`,
`s[^/.:u][^/.:]*`, `su`, `su[^/.:b][^/.:]*`, `sub[^/.:]+`. An included domain
under an exclusion (`a,~sub.a,in.sub.a`) is its own root, so it is back in.
Patterns are anchored, skip any user info (`([^/@]*@)?`; a label never
holds an `@`, so `http://x@sub.a.example/` stays excluded) and end in `[:/]`
like WebKit's own, so `http://evil.example/?u=http://a.example/` and
`a.example.evil.example` do not match. An exclusion with a label outside `[a-z0-9_-]` is ignored.

`if-top-url` keeps the trigger otherwise the same as `if-domain`: every load
of the page, every frame, never merged into the shared style sheet. A mixed
element-hiding rule is domain-specific (after the `$generichide`
exceptions), and a pattern-less cosmetic exception
(`@@$generichide,domain=a|~sub.a`) takes the `if-top-url` as its page
condition.

**Options rejected.** An `if-domain` rule followed by an
`ignore-previous-rules` for the excluded subdomain: it undoes every earlier
action of the list on that page, not only this rule's (all hiding before it,
or every block rule for the URL), so it is not a per-rule exclusion. A
document-only trigger (`resource-type` `document`, the page's host in
`url-filter`, `unless-domain` for the exclusion): WebKit keeps a document
load's selectors for the new document, so it would work for hiding, but not
for network rules, whose `url-filter` is the resource URL, and it would stop
hiding in frames of other hosts.

**How many rules this touches.** None of the four shipped lists has a mixed
domain list (copies of 2026-10-26: 0 element-hiding and 0 `domain=` rules
with both kinds), and the parser's output for them is unchanged apart from
the two rules below. Bad rules stripped per list, before and after, found by
bisecting each list through `WKContentRuleListStore` with a standalone
tool:[^task-201]

| List | Parsed | Stripped before | After |
|---|---|---|---|
| `easylist` | 71,316 | 0 | 0 |
| `easyprivacy` | 56,310 | 0 | 0 |
| `easylist-cookie` | 25,079 | 2 | 0 |
| `urlhaus-filter` | 102,775 | 0 | 0 |

`easylist-cookie`'s two were not mixed lists: their domain lists held
internationalised domains (`przesył-energii.pl`, `wanderwege-graubünden.ch`),
which `sanitizeDomain` turned into `przesy%C5%82-energii.pl` with
`URLComponents.percentEncodedHost` (percent-encoding, upper-case hex). It now
uses `encodedHost`, which is punycode (`xn--przesy-energii-lnc.pl`); a host
IDNA cannot encode (`xn--ü.de`) still comes back percent-encoded and is left
out. With the
fix the app compiles all four lists whole ("Active" equals "In List"), and a
list carrying `lvh.me,~sub.lvh.me##.t201-ad` and
`/t201-ad.js$domain=lvh.me|~sub.lvh.me` hid and blocked on lvh.me and
www.lvh.me and did neither on sub.lvh.me and x.sub.lvh.me
(`docs/harness/task201-harness.patch`).[^task-201]

## Lists over the rule cap

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
| `compile(identifier:rules:)` | Compiles every chunk. When at least one compiled it records the list's chunk count, removes stale chunks, and completes `.compiled` with all of the list's chunks. When none did, the list is left as it was (`.failed`). Cleared meanwhile: `.superseded` (see "Clear Cache & Redownload"). |
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

No list is near the cap. Parser output for the lists as fetched on
2026-10-04; the copies fetched on 2026-10-02 gave 74,973 / 56,146 / 25,002 /
9,571, which are also the counts the installed app had recorded:[^task-145]

| List | Parsed rules | Compiled | Share of the cap |
|---|---|---|---|
| `easylist` | 75,661 | 75,661 | 50.4% |
| `easyprivacy` | 56,158 | 56,158 | 37.4% |
| `easylist-cookie` | 25,010 | 25,008 (2 stripped as invalid, fixed by TASK-201: see "Domain lists") | 16.7% |
| `urlhaus-filter` | 9,605 | 9,605 | 6.4% |

### What a chunk holds

An `ignore-previous-rules` rule (an `@@` exception) only undoes rules earlier
in its **own** rule list (see "Why the per-site switch is not a rule list").
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

What splitting does not solve:

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

## Attaching lists to web views

`Space.makeWebViewConfiguration()` calls
`ContentBlockerManager.applyRuleLists(to:profile:)`, which adds the rule lists
of `ruleLists(for:in:)`: every compiled chunk of each enabled list when the
master switch is on, and nothing else. It adds no user script, so it is safe
to call again after `removeAllContentRuleLists()`.

On `.contentBlockerRulesDidChange`,
`BrowserWindowController.handleContentBlockerRulesChanged` removes and re-adds
the lists **only on the selected tab's panes, and only when this window owns
the web view**. Each tab has its own configuration, so other tabs keep the
lists they were created with until their web view is rebuilt (a wake) or they
are the selected tab when a later change is posted.

## The per-site switch

The whitelist is a persisted host set per profile: the
`contentBlocking = false` rows of the [site settings](../architecture/site-settings.md)
table (`siteSetting`), which replaced the `contentBlockerWhitelist` table in
migration v18 (TASK-187). `ContentBlockerWhitelist` keeps its API and reads
and writes `SiteSettingsStore.shared`. Enforcement is per **navigation**, the
way Safari's per-site content-blocker switch works:

1. Both navigation delegates implement the *preferences* variant,
   `webView(_:decidePolicyFor:preferences:)`. Returning a
   `WKWebpagePreferences` is the only way to change blocking for a page, and
   WebKit calls only one of the two variants.
2. For an allowed **main-frame** navigation whose host is covered by the
   navigating tab's profile's whitelist, `ContentBlockerManager.configure`
   calls the private `-[WKWebpagePreferences _setContentBlockersEnabled:NO]`.
   That disables every rule list for the document and all of its subresource
   and subframe loads.
3. The profile is the **navigating tab's** (`tab(owning:)?.owningProfile`),
   not the window's active space: the window stays delegate of a tab's web
   view after a space switch.
4. A tab no window has claimed yet is its own web view's navigation delegate
   for exactly this decision, so a background-opened tab gets the switch too.

Because the switch acts at navigation time, toggling it reloads every pane
this window shows for that host (split members and the Peek), not just the
display tab.

In a **Private window** the switch is kept in memory only (TASK-195): the
store writes no row for the Private profile, and the override is dropped when
the last Private window closes (`SiteSettingsStore.discardPrivateSession`).
Nothing is compiled or cached from the site list (the decision is
`ContentBlockerManager.contentBlockersEnabled(forNavigationTo:profileID:whitelist:)`,
read at each navigation), so the next Private window blocks everywhere with
no further reset. The toggle and its reload work as in any other profile.
Migration v19 removed the Private rows earlier builds had written
([site settings](../architecture/site-settings.md)).

Matching (`ContentBlockerWhitelist.covers`) is case-insensitive: a host is
covered by an exact entry or by an entry for a parent domain. Turning blocking
off stores the page's exact host, lowercased. Turning it back on removes
**every** entry covering the host, a parent-domain entry included; leaving the
parent would keep the site whitelisted and the switch would appear not to
take.

## The blocked counter

WebKit reports each load a rule list acted on through the private navigation
delegate callback
`_webView:contentRuleListWithIdentifier:performedAction:forURL:`, implemented
on `BrowserWindowController`. When the `_WKContentRuleListAction`'s
`blockedLoad` is true the owning tab calls `recordBlockedLoad(of:)`, which
counts a URL once per page: WebKit fires once per list that acted, and the
lists overlap. `BrowserTab.blockedCount` (`@Published`) resets in `load` and
on every committed navigation. A page with content blockers disabled produces
no callbacks at all.

# Exceptions and element hiding

## What WebKit does with an exception

Read from WebKit's source[^webkit-backend][^webkit-compiler] and confirmed
in a web view by `ContentBlockerExceptionTests`:

- Each rule list is evaluated on its own. For one load, the matching rules'
  actions are taken in list order, and an `ignore-previous-rules` drops
  **every** action before it: block, css-display-none, anything. Nothing
  after it is touched. There is no action that undoes element hiding only.
- `css-display-none` rules whose trigger is a bare `.*` (no condition, no
  flags) and that come before the list's first `ignore-previous-rules` are
  merged into one precompiled style sheet per list. That sheet is added to a
  document by **any** load of the page that did not see an
  `ignore-previous-rules` in that list, subresource loads included
  (`maybeAddContentExtensionSheet`). So an exception that only matches the
  document load (resource type `document`) does not keep generic hiding off:
  the page's first unexcepted image adds the sheet back.
- A rule with a condition (`if-domain`, `unless-domain`, `if-top-url`, ...)
  is never merged: each is its own action, evaluated on every load, and its
  condition patterns are compiled per rule. `if-domain` and `unless-domain`
  are compiled into top-URL patterns; a trigger takes one condition (see
  "Domain lists").

## How the parser maps `@@` options (TASK-199)

The parser emits its rules in this order (`EasyListParser.Section`):

1. generic hiding (`##sel`, and `~domain##sel`: no `if-domain`);
2. `$generichide` exceptions;
3. domain-specific hiding (`domain##sel`);
4. `$elemhide` exceptions;
5. block rules;
6. network exceptions;
7. `$document` allowlists;
8. `$important` block rules, which no exception after them can undo (Adblock
   Plus: `$important` wins over every exception, `$document` included).

A cosmetic exception is **page-wide**: `ignore-previous-rules` with
`url-filter` `.*` and a page condition, so it matches every load of the page
and the shared style sheet is never added there. Placed after the hiding it
means to undo and before every block rule, it cannot unblock anything. The
page condition is the rule's pattern applied to the page URL (`if-top-url`),
which also covers the patterns that are not a domain (`://127.0.0.1`,
`://192.168.`, `://localhost:`, `||bing.com/search?`,
`||www.google.*/search?`); a rule with no pattern
(`@@$generichide,domain=a|b`, which used to be skipped) uses its `domain=`
list as `if-domain`. A rule with both keeps the pattern and ignores
`domain=` (WebKit takes one condition), so it covers more pages than it
names; a known limit left by TASK-199's review, as none of the shipped
lists has such a rule.

| Option | Result |
|---|---|
| `$generichide` | Generic hiding off on the page; domain-specific hiding and all blocking still apply |
| `$elemhide` | All hiding off; blocking unchanged. Checked before `$generichide`, so a rule with both lands after the domain-specific hiding |
| `$document` | The old network exception (resource type `document`, the frame load itself) plus a page-wide exception at the end: nothing is blocked or hidden on the page. Before, only the document load was exempt. |
| `$genericblock`, `$specifichide` | Left out (none in the shipped lists). Undoing only generic blocks, or only domain-specific hiding, needs an order that the other exceptions already use the other way round |
| only `$popup`, `$websocket`, `$webrtc`, `$ping` or `$csp` | Left out. The parser compiles no block rule of those types and the options map to no resource type, so such an exception used to undo every block rule for its URLs: the shipped lists' 42 `$popup` exceptions included `@@||accounts.google.com^$popup` and `@@||ad.doubleclick.net/ddm/$popup,domain=...` |
| `$redirect`, `$redirect=`, `$rewrite`, `$rewrite=`, `$csp=` | Left out: they lift a rule that rewrites a load, and the parser compiles none of those (the shared `isRewritingOption`), so the exception would only undo block rules it was never meant to |
| anything else | A network exception, after every block rule, so it applies wherever it stood in the file |
| `$badfilter` (any rule) | Not an exception: the line and the rule it repeats without `$badfilter` are both dropped |

Before TASK-199 every `@@` rule was a plain `ignore-previous-rules` for the
URLs its pattern matched, in file order. EasyList's 169 `$generichide`
lines (127.0.0.1, localhost, 192.168.*, 10.0.0.*, accounts.google.com,
github.com, reddit.com, youtube.com, wikipedia.org, the Amazon stores and
more) therefore switched **network** blocking off for every same-host load on
those sites, and did not even keep generic hiding off reliably (the style
sheet came back with the first third-party load). Seen at runtime: a page on
127.0.0.1 or localhost ran `/jquery.popunder.js`, the same page on `lvh.me`
did not.[^task-199]

Network exceptions had the opposite problem in file order: one written above
a block rule it exempts did not apply. WebKit applies an
`ignore-previous-rules` only to the rules before it in its list, which
TASK-162 confirmed in a web view (a raw exception-then-block rule list blocks
the exempted script; block-then-exception does not). A scan of every network
exception in the 27 Oct 2026 copies (a standalone tool built from
`EasyListParser.swift` and the tests' `RuleListEvaluator`, comparing the file
order with the parser's output for the URL each exception names) found one
case: EasyList's ten `@@||thegay.com/...$domain=thegay.com` exceptions for the
site's jwplayer and its own scripts (lines 63463–63472) sit above
`||thegay.com^$script,domain=thegay.com` (line 63474), so the video player was
blocked until TASK-199. EasyPrivacy (849 checked) and EasyList Cookie (420)
had none. The scan approximates each exception's URL from its pattern
(`*` and `^` filled in), so it can miss cases; it found no false
ones.[^task-162]

### Options rejected

- **`unless-domain` on every generic hiding rule** (the domains of the
  `$generichide` lines). It turns the merged, precompiled generic style
  sheet into 13,600 conditioned rules evaluated on every load, and cannot
  express the non-domain patterns. Measured on EasyList (2026-10-12 copy):
  the compiled list grew from 30.6 MB to 76.8 MB and compiled in 14.9 s
  instead of 3.7 s, with only the `||host^` lines converted.
- **Dropping the cosmetic exceptions.** Simple and safe for blocking, but
  generic hiding would then run on GitHub, Google Docs, YouTube and the other
  sites EasyList lists because it breaks them.
- **A separate rule list for element hiding.** It works (lists are evaluated
  independently, so a cosmetic list's exceptions could not reach a network
  list), but doubles the rule lists per filter list and the chunk, count,
  look-up and removal bookkeeping in `ContentRuleStore`, for nothing the
  ordering does not already give.
- **An exception limited to the document load** (`resource-type`
  `document`, as some converters do): it does not keep the shared generic
  style sheet off (see above).

### Size and compile time

`WKContentRuleListStore` compile of the 2026-10-12 lists, before and after.
Rules and sizes are from the app after the review (the upgrade run); the
compile times are from a standalone tool before the review (they vary by a
second or two between runs on a loaded machine):

| List | Rules compiled | Compiled size | Compile |
|---|---|---|---|
| `easylist` | 78,234 → 78,190 | 30,601,691 → 30,368,642 B | 3.7 → 3.7–3.9 s |
| `easyprivacy` | 56,212 → 56,209 | 24,103,137 → 23,886,825 B | 2.4–5.4 → 2.5–4.4 s |
| `easylist-cookie` | 25,022 → 25,022 (25,024 parsed, 2 stripped as bad) | 16,454,333 → 16,371,648 B | 1.9–2.3 → 1.7–1.8 s |
| `urlhaus-filter` | 24,676 (no exceptions) | unchanged | unchanged |

Slightly smaller: with the network exceptions after all block rules WebKit
merges more unconditioned actions.

## Recompiling after a parser change

A compiled rule list in WebKit's store is reused at launch, and a refresh
only recompiles when the list text changed (an unchanged list answers 304),
so a parser fix would never reach an existing install. Every successful
compile records `ContentBlocker.<id>.rulesFormat` =
`EasyListParser.rulesFormatVersion` (2 since TASK-199, 3 since TASK-201); at launch a list
whose recorded format differs, or is missing (every install before
TASK-199), is recompiled from the cached text, and the lists found stay
attached until the new ones replace them
(`ContentBlockerManager.shouldReuseCompiledList(recordedFormat:)`).
**Bump `rulesFormatVersion` whenever the parser's output for the same text
changes.**

How the upgrade runs (`ContentBlockerManager`):

- `loadAndCompileFromCache` reads and parses the cached text on a utility
  queue (every list is parsed at the launch after a format change), then
  compiles (see "Threading").
- No cached text, or a cached text that does not compile: the list is
  fetched **unconditionally** (no `If-None-Match` / `If-Modified-Since`). With
  the saved ETag an unchanged list would answer 304 and the old-format list
  would stay attached.
- After a successful compile from cache it calls `refreshIfNeeded`, from the
  compile's completion, so a due refresh starts only once that compile is
  done. (Before TASK-199 a list compiled from cache was not checked for a
  refresh until the next launch.)

Seen at runtime (after the review, `docs/harness/task199-harness.patch`,
whose URLProtocol serves the list URLs locally): an old-format store logged
"Recompiling <id>: compiled from rules format 0, current 2" for all four
lists and read format 2 for every list after 16 s; a list whose cached text
was deleted while its saved ETag matched the server was fetched with no
conditional headers (200) and compiled; a list due a refresh fetched only
after its cache compile had finished, and compiled after that; the next
launch reused every list with no compile or fetch.

## Threading

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
  see the next section.

Measured with the main-queue heartbeat (`docs/harness/task200-harness.patch`,
same scenarios as TASK-199, Debug build, load average 18–45): the upgrade
recompile of all four lists went from gaps of 486, 515 and 527 ms (TASK-199:
403, 511, 491) to none over 250 ms; a mid-session update of `easylist` and
`easylist-cookie` from 571 and 361 ms to none. What remains is the launch
tick (about 430–450 ms, with or without a compile) and the harness creating
its first test tab (WebContent launch, 250–650 ms). Rules are still freed on
main when a compile completes (28 samples per recompile).

## Clear Cache & Redownload

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

Not handled: web views keep the rule lists they already have after the
clear until the next rules change (the redownload's compile posts it);
offline, the selected tab keeps blocking with the cleared lists while new
tabs get none. That predates TASK-202.

Seen at runtime (`docs/harness/task202-harness.patch`, lists served by a
URLProtocol, the clear 1.5 s after easylist's launch compile was handed to
the store):[^task-202]

| Run | At the clear | Result |
|---|---|---|
| online | easylist and easyprivacy in WebKit, easylist-cookie encoding, urlhaus-filter parsing | each superseded at that stage (os_log "Discarded the compile of easylist: the rule lists were cleared while it ran", "... while it was encoded", "Not compiling urlhaus-filter from cache: ... or the cache was cleared"); one fetch per list; every list then the redownload's counts (71,319 / 56,313 / 25,082 / 102,778, three rules more than the cached text) with `rulesFormat` 3 |
| offline | the same | nothing compiled, no `rulesFormat`, no file in the rule list store, "Not loaded" in Settings, 4 fetches (the clear's) |
| offline, code before TASK-202 | the same | all four lists Active with `rulesFormat` 3 and their files back in the store, cache text gone, 8 fetches |

# Why the per-site switch is not a rule list

The first implementation compiled a separate "whitelist" list of
`ignore-previous-rules` rules with `if-domain` triggers. It never worked.
WebKit evaluates each `WKContentRuleList` **independently** and merges their
Block results, so `ignore-previous-rules` only cancels rules in its *own*
list; the order the lists are added in is irrelevant (read from WebKit's
`ContentExtensionsBackend.cpp`).[^task-69] The old counter was wrong too: it
counted element `error` events from an injected script, which is every failed
image or script load, blocked or not. Together they produced "12 resources
blocked" on a page whose blocking was switched off.

`initialize()` still removes the retired `content-blocker-whitelist-<uuid>`
lists that earlier builds compiled; nothing else would ever delete them.

The same WebKit rule has a consequence inside the parser: an EasyList `@@`
exception only cancels blocks from the **same** list. An exception in
EasyPrivacy cannot un-block something EasyList blocks.

# Edge cases and gotchas

- **Two private selectors.** Both are guarded by `responds(to:)`. The
  preferences setter logs once and does nothing if WebKit drops it; the
  `blockedLoad` key is read through KVC, where an undefined key would raise an
  Objective-C exception on every blocked load.
  `testTheContentBlockerPreferencesSPIExists` fails if the setter disappears.
  Both were present on macOS 26.6.2.[^task-69]
- **A split list is several rule lists.** Anything that handles "the list
  `<id>`" has to go through the list-level functions of `ContentRuleStore`,
  never a single identifier; see "Lists over the rule cap". The blocked
  counter is unaffected: WebKit reports per rule list, and the tab counts a
  URL once per page.
- **Storage is shared by bundle identifier.** WebKit's default rule list store
  and the standard defaults domain belong to the bundle id, so a test host or
  an isolated `DETOUR_DATA_DIR` run would compile into, and refresh, the
  production app's lists. `ContentBlockerStorage.forDataDirectory(named:)`
  gives any non-default data directory its own store, cache directory and
  defaults suite.[^task-36]
- **Bisection compiles probe lists into the real store.** Each probe uses the
  identifier `<id>-probe-<offset>-<count>` (with a chunk's identifier for
  `<id>` when the list is split) and is removed again when it compiles.
- **"No individual bad rules found"** means the full set fails while each
  half compiles (a combined state limit); the list is then not compiled at
  all.
- **A subframe navigation never changes blocking.** `configure` is called only
  for the main frame, and the host that decides is the page's.
- **An exception reaches everything before it in its list.** WebKit has no
  cosmetic-only exception, so the parser's section order is what keeps
  `$generichide` / `$elemhide` away from the block rules (see "Exceptions and
  element hiding"); a new kind of rule has to go in the right section, and a
  page-wide exception must never be carried behind block rules. A local
  fixture on `127.0.0.1` or `localhost` is blocked normally since TASK-199,
  but generic hiding is off there (EasyList's `$generichide` lines); use
  `lvh.me` (public DNS for 127.0.0.1) to see generic hiding.
- **Port 9 (and WebKit's other restricted ports) never reach the content
  blocker.** A test page loading `http://127.0.0.1:9/x.js` reports no
  blocked load because WebKit refuses the port first; use an unused high
  port.

# Where state lives

| Data | Location |
|---|---|
| Raw list text | `<data directory>/ContentBlocker/<identifier>.txt` under Application Support |
| Compiled lists | WebKit's default `WKContentRuleListStore`, or `<data directory>/ContentRuleLists` for a non-default data directory. One rule list per chunk: `<id>`, `<id>-1`, … |
| Fetch metadata | defaults keys `ContentBlocker.<id>.lastFetch`, `.etag`, `.ruleCount`, `.rulesFormat` (parser output format of the last successful compile) |
| Compile metadata | defaults keys `ContentBlocker.<chunk id>.compiledRuleCount` per compiled chunk, and `ContentBlocker.<id>.chunkCount` for a list of more than one chunk |
| Whitelist | `siteSetting` rows (`contentBlocking`) in the [session database](../architecture/session-database.md); rows go with the profile; none for the Private profile, whose switch stays in memory |

# Tests

- `ContentBlockerWhitelistTests` - `covers` cases, toggle persistence and
  per-profile scope, the Private switch (nothing on disk, back on clears it,
  closing the last Private space turns blocking back on while a normal
  profile's switch stays), and two real-`WKWebView` tests: one `blockedLoad`
  callback with blocking on, none when the navigation's preferences disable
  content blockers; the counter's dedup and reset; an unclaimed tab is its web
  view's navigation delegate.
- `ContentBlockerTests` - storage isolation per data directory, parser cases,
  and compiling each cached real list through WebKit.
- `ContentBlockerExceptionTests` - the parser's sections and `@@` options
  through `RuleListEvaluator` (a model of WebKit's per-list evaluation:
  matching rules in list order, `ignore-previous-rules` dropping what came
  before): `$generichide` / `$elemhide` / `$document` / `$popup`, non-domain
  patterns, `domain=` without a pattern, `$important` winning over
  exceptions, `$badfilter`, `$elemhide` before `$generichide`, redirect and
  CSP exceptions left out, the real EasyList's generichide hosts; the split layout keeping the element-hiding section in chunk 0; the
  `rulesFormat` reuse rule; and four real-`WKWebView` pages (127.0.0.1 with
  `$generichide`, `$elemhide`, `$document`, and an unexcepted host) checking
  the blocked-load callback and the computed `display` of a generic and a
  specific hidden element, with a third-party image on the page.
- `ContentBlockerDomainListTests` - `domainCondition` (exclusions outside
  the included domains dropped, an included domain excluded again, the
  `if-top-url` patterns matched against URLs on and off the included domain:
  near-miss labels, deeper exclusions, an included domain under an
  exclusion, query-string and suffix lookalikes), the parser's output for
  element hiding, `domain=` blocks and exceptions and a pattern-less
  `$generichide` (one condition, the right section, evaluated with
  `RuleListEvaluator`), punycode for internationalised domains, and every
  such rule compiled one by one through a real `WKContentRuleListStore`.
  `ContentBlockerExceptionTests` adds two web view tests: a mixed list
  compiles whole (no rule stripped) and hides and blocks on a.example and
  www.a.example, not on sub.a.example and x.sub.a.example.
- `ContentRuleStoreThreadingTests` - encoding of every chunk, every bad-rule
  probe and the cleaned chunk off the main queue (an injected encoder records
  the thread), the default encoding equal to the JSON given to WebKit before
  and a compiled store file byte-identical to one compiled from it, a second
  compile of a list waiting for the first's bad-rule search (the second's
  list is kept), different lists not waiting for each other, and the
  `FilterListCompileOrder` tickets. For Clear Cache & Redownload (TASK-202),
  an injected WebKit compile (`RuleListCompiler`) calls `invalidateAll`
  while WebKit compiles or at the first bad-rule probe: the compile is
  `.superseded`, records nothing and leaves nothing in WebKit's store (a new
  store finds nothing); a compile asked for after the clear is kept even
  though the superseded one finished later; compiles queued or encoding at
  the clear never reach WebKit; a look-up answered after it records nothing;
  tickets taken before it are refused; `FilterListRefreshes` tokens.
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
- The switch itself was confirmed by hand on a signed build: off then reload
  shows 0 blocked; on restores blocking; state survives popover reopen, tab
  switch and relaunch.[^task-69]

# Related

- [Settings](./settings.md) - the Content Blocking pane and the per-profile toggles.
- [BrowserTab](../architecture/browser-tab.md) - the tab's own navigation delegate for unclaimed web views.
- [Profile data removal](../architecture/profile-data-removal.md) - storage scoping per data directory, and what goes when a profile is deleted.
- [WebKit test-host traps](../platform/webkit-test-host-traps.md) - other state the test host shares with the production app.
- [WebKit source lookup](../platform/webkit-source-lookup.md) - how the rule-list evaluation was confirmed.

[^task-36]: Stop the test host writing WebKit data into the production app's WebKit directory
[^task-69]: The "Block content on this site" switch does not take effect
[^task-145]: A filter list over 150,000 rules attaches only its first chunk
[^task-155]: In a split filter list an exception in a later chunk than its block rule does not apply
[^task-199]: $generichide / $elemhide exceptions compile to ignore-previous-rules and unblock all loads on those hosts
[^task-200]: Serialise block-list rules to JSON and search for bad rules off the main thread
[^task-201]: Cosmetic rules with both included and excluded domains compile to a trigger WebKit rejects
[^task-162]: In a filter list, an exception rule does not undo the block rules that come after it
[^task-202]: Clear Cache & Redownload can be undone by a compile that was already running
[^webkit-parser]: WebKit ContentExtensionParser.cpp (one condition per trigger, if-domain to page URL regex, lower-case ASCII domains)
[^webkit-rule-list-store]: WebKit APIContentRuleListStore.cpp (main-thread asserts, JSON parsed on main, work queue per store path)
[^webkit-backend]: WebKit ContentExtensionsBackend.cpp (per-list evaluation, global style sheet gate)
[^webkit-compiler]: WebKit ContentExtensionCompiler.cpp (action merging, conditions)
