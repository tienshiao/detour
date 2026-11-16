---
type: Concept
title: Content blocking exceptions and element hiding
description: "What WebKit does with an ignore-previous-rules exception (per list, undoes every earlier action, a document-only exception cannot keep the merged generic style sheet off), the section order EasyListParser emits so $generichide / $elemhide never unblock the network (TASK-199), how each @@ option maps, the file-order bug TASK-162 found, the options rejected, and the size and compile time before and after."
tags: [content-blocker, webkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:39:06Z }
sources:
  - id: parser
    resource: ../../Detour/Browser/ContentBlocker/EasyListParser.swift
    title: EasyListParser.swift (Section, parseExceptionRules, pageWideException, isRewritingOption)
  - id: exception-tests
    resource: ../../DetourTests/ContentBlockerExceptionTests.swift
    title: ContentBlockerExceptionTests.swift
  - id: task-199
    resource: backlog:TASK-199
    title: $generichide / $elemhide exceptions compile to ignore-previous-rules and unblock all loads on those hosts
  - id: task-162
    resource: backlog:TASK-162
    title: In a filter list, an exception rule does not undo the block rules that come after it
  - id: task-69
    resource: backlog:TASK-69
    title: The "Block content on this site" switch does not take effect
  - id: webkit-backend
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebCore/contentextensions/ContentExtensionsBackend.cpp
    title: WebKit ContentExtensionsBackend.cpp (per-list evaluation, global style sheet gate)
  - id: webkit-compiler
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebCore/contentextensions/ContentExtensionCompiler.cpp
    title: WebKit ContentExtensionCompiler.cpp (action merging, conditions)
  - id: harness
    resource: ../../docs/harness/task199-harness.patch
    title: TASK-199 runtime harness
---

WebKit has no exception that undoes only element hiding, or only one rule:
an `ignore-previous-rules` drops every earlier action of its own rule list.
[The parser](./content-blocking-filter-conversion.md) therefore emits a
filter list in sections, so each kind of `@@` exception sits after exactly
what it may undo (TASK-199). Part of [content blocking](./content-blocking.md).

# What WebKit does with an exception

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
  [domain lists](./content-blocking-domain-lists.md)).

The same WebKit rule has a consequence inside the parser: an EasyList `@@`
exception only cancels blocks from the **same** list. An exception in
EasyPrivacy cannot un-block something EasyList blocks. (It is also why the
per-site switch is not a rule list; see
[the per-site switch](./content-blocking-per-site-switch.md#why-the-per-site-switch-is-not-a-rule-list).)
In a list split into chunks, every chunk is its own rule list, which is what
[what a chunk holds](./content-blocking-chunks.md#what-a-chunk-holds) works
around.

# How the parser maps `@@` options (TASK-199)

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
| an option the parser does not support (`$removeparam`, `$redirect-rule`, `$cookie`, `$stealth`, `$method=`, ...) | Left out, like the block rule with it (TASK-351): ignoring the option made `@@\|\|host^$removeparam=x` unblock every load from the host; see [unsupported options](./content-blocking-filter-conversion.md#options-the-parser-does-not-support-task-351) |
| anything else | A network exception, after every block rule, so it applies wherever it stood in the file |
| `$badfilter` (any rule) | Not an exception: the line and the rule it repeats without `$badfilter` are both dropped |

The option names also accept their short forms (`$ehide`, `$ghide`, `$shide`).

## Before TASK-199

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

# Options rejected

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

# Size and compile time

`WKContentRuleListStore` compile of the 2026-10-12 lists, before and after.
Rules and sizes are from the app after the review (the upgrade run); the
compile times are from a standalone tool before the review (they vary by a
second or two between runs on a loaded machine):[^task-199]

| List | Rules compiled | Compiled size | Compile |
|---|---|---|---|
| `easylist` | 78,234 → 78,190 | 30,601,691 → 30,368,642 B | 3.7 → 3.7–3.9 s |
| `easyprivacy` | 56,212 → 56,209 | 24,103,137 → 23,886,825 B | 2.4–5.4 → 2.5–4.4 s |
| `easylist-cookie` | 25,022 → 25,022 (25,024 parsed, 2 stripped as bad) | 16,454,333 → 16,371,648 B | 1.9–2.3 → 1.7–1.8 s |
| `urlhaus-filter` | 24,676 (no exceptions) | unchanged | unchanged |

Slightly smaller: with the network exceptions after all block rules WebKit
merges more unconditioned actions.

# Gotchas

- **An exception reaches everything before it in its list.** WebKit has no
  cosmetic-only exception, so the parser's section order is what keeps
  `$generichide` / `$elemhide` away from the block rules; a new kind of rule
  has to go in the right section, and a page-wide exception must never be
  carried behind block rules (see
  [what a chunk holds](./content-blocking-chunks.md#what-a-chunk-holds)). A local
  fixture on `127.0.0.1` or `localhost` is blocked normally since TASK-199,
  but generic hiding is off there (EasyList's `$generichide` lines); use
  `lvh.me` (public DNS for 127.0.0.1) to see generic hiding.
- **`$important` is not absolute in a split list**, and **the element-hiding
  section has to fit in the first chunk**: the limits splitting adds, in
  [what splitting does not solve](./content-blocking-chunks.md#what-splitting-does-not-solve).

# Tests

`ContentBlockerExceptionTests` - the parser's sections and `@@` options
through `RuleListEvaluator` (a model of WebKit's per-list evaluation:
matching rules in list order, `ignore-previous-rules` dropping what came
before): `$generichide` / `$elemhide` / `$document` / `$popup`, non-domain
patterns, `domain=` without a pattern, `$important` winning over
exceptions, `$badfilter`, `$elemhide` before `$generichide`, redirect and
CSP exceptions left out, the real EasyList's generichide hosts; and four
real-`WKWebView` pages (127.0.0.1 with `$generichide`, `$elemhide`,
`$document`, and an unexcepted host) checking the blocked-load callback and
the computed `display` of a generic and a specific hidden element, with a
third-party image on the page. The same suite covers the split layout
keeping the element-hiding section in chunk 0
([chunks](./content-blocking-chunks.md)), the `rulesFormat` reuse rule
([recompiling](./content-blocking-filter-conversion.md#recompiling-after-a-parser-change))
and the mixed domain-list web view tests
([domain lists](./content-blocking-domain-lists.md#tests)).

# Related

- [Filter-list conversion](./content-blocking-filter-conversion.md) - the parser as a whole, and why a section change bumps `rulesFormatVersion`.
- [Content blocking chunks](./content-blocking-chunks.md) - how exceptions are carried into every chunk of a split list.
- [Domain lists](./content-blocking-domain-lists.md) - the page conditions cosmetic exceptions use.
- [WebKit source lookup](../platform/webkit-source-lookup.md) - how the rule-list evaluation was confirmed.

[^webkit-backend]: WebKit ContentExtensionsBackend.cpp (per-list evaluation, global style sheet gate)
[^webkit-compiler]: WebKit ContentExtensionCompiler.cpp (action merging, conditions)
[^task-199]: $generichide / $elemhide exceptions compile to ignore-previous-rules and unblock all loads on those hosts
[^task-162]: In a filter list, an exception rule does not undo the block rules that come after it
