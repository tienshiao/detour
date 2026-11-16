---
type: Component
title: Content blocking filter-list conversion
description: "EasyListParser, which turns Adblock Plus filter-list text into WebKit content-rule JSON: the three actions it emits in section order, what it skips (extended CSS, #@#, popup/redirect/CSP-style rules, $badfilter pairs), regex rewriting, rules with unsupported options such as $removeparam left out (TASK-351), uBO/AdGuard option aliases, their other modifiers and $match-case (TASK-371), and why every change to its output bumps rulesFormatVersion so installed lists are recompiled."
resource: ../../Detour/Browser/ContentBlocker/EasyListParser.swift
tags: [content-blocker, webkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T18:30:00Z }
sources:
  - id: parser
    resource: ../../Detour/Browser/ContentBlocker/EasyListParser.swift
    title: EasyListParser.swift
  - id: manager
    resource: ../../Detour/Browser/ContentBlocker/ContentBlockerManager.swift
    title: ContentBlockerManager.swift (initialize, shouldReuseCompiledList, loadAndCompileFromCache, fetchAndCompile)
  - id: blocker-tests
    resource: ../../DetourTests/ContentBlockerTests.swift
    title: ContentBlockerTests.swift (parser cases)
  - id: exception-tests
    resource: ../../DetourTests/ContentBlockerExceptionTests.swift
    title: ContentBlockerExceptionTests.swift (the rulesFormat reuse rule)
  - id: task-199
    resource: backlog:TASK-199
    title: $generichide / $elemhide exceptions compile to ignore-previous-rules and unblock all loads on those hosts
  - id: task-201
    resource: backlog:TASK-201
    title: Cosmetic rules with both included and excluded domains compile to a trigger WebKit rejects
  - id: task-351
    resource: backlog:TASK-351
    title: "Content blocking: a filter list's $removeparam line compiles into a block rule for the whole host"
  - id: task-371
    resource: backlog:TASK-371
    title: "Content blocking: parser gaps — uBO aliases, bare modifiers that become never-matching rules, $match-case ignored"
  - id: harness
    resource: ../../docs/harness/task199-harness.patch
    title: TASK-199 runtime harness (a URLProtocol serving the list URLs locally)
---

`EasyListParser` converts a filter list from Adblock Plus syntax to the rule
JSON `WKContentRuleListStore` compiles. It runs on the content blocker's parse
queue (see [rule-list compilation](./content-blocking-rule-compilation.md#threading))
and its output is what [content blocking](./content-blocking.md) attaches.
Its two subtle parts have their own pages:
[domain lists](./content-blocking-domain-lists.md) and
[exceptions and element hiding](./content-blocking-exceptions.md).

# What it emits

**Parse** (`EasyListParser`) emits `block`, `ignore-previous-rules` (for `@@`
exceptions) and `css-display-none` (for `##` element hiding) rules, ordered
by section, not by file order (`EasyListParser.Section`; the order and the
reason are in [exceptions and element hiding](./content-blocking-exceptions.md#how-the-parser-maps--options-task-199)).
A rule is a `ContentRule = [String: any Sendable]`, so a parsed list can be
handed between queues (TASK-231.3; see
[threading](./content-blocking-rule-compilation.md#threading)).

# What it skips

It skips what WebKit cannot express: extended CSS and snippet filters (`#?#`,
`#$#`), element-hiding exceptions (`#@#`), and blocking rules with `popup`,
`websocket`, `webrtc`, `csp`, `rewrite`, `redirect` or `ping` options. A
`$badfilter` line and the rule it names (the same line without the option)
are both dropped and counted as skipped.

## Options the parser does not support (TASK-351)

A network rule, block or `@@`, compiles only if every option is one the
parser supports (`EasyListParser.isSupportedOption`): the resource types,
`third-party`, `domain=`, `important`, `match-case`, `all`, the aliases
[below](#aliases-other-blockers-modifiers-and-match-case-task-371), the `@@`
options, `badfilter`, and the options whose rules are skipped on purpose
(`popup`, `websocket`, `webrtc`, `ping`, `csp`/`csp=`, `rewrite`/`rewrite=`,
`redirect`/`redirect=`). A rule with any other option is left out and
counted as skipped. Adblock Plus, uBlock Origin and AdGuard discard such a
rule too.

The reason is that every other modifier either changes what a rule does or
narrows what it matches: `$removeparam` strips a query parameter,
`$removeheader`, `$permissions`, `$header`, `$replace`, `$jsonprune`,
`$urltransform`, `$cookie`, `$hls` and `$stealth` rewrite or filter a
response, `$method=POST` limits a rule to one method, `$denyallow=` exempts
hosts, and `$redirect-rule` only lifts a redirect. Before TASK-351 the
parser accepted any `name=value` option and ignored the ones it did not
map, so `||host^$removeparam=x` compiled into a block rule for every load
from the host, and `@@||host^$removeparam=x` into a network exception that
unblocked them; a bare `$removeparam` was not recognised as an option, so
the line stayed a literal pattern that matched nothing.[^task-351]

Finding the `$` that starts the options (`isOptionList`): every token after
it must be a supported option, a `name=value` with an option-shaped name
(letters, digits, `-`, `_`), or a bare name from `unsupportedModifiers`
(`removeparam`, `cookie`, `stealth`, `redirect-rule`, and since TASK-371
the other blockers' modifiers [below](#aliases-other-blockers-modifiers-and-match-case-task-371)). Tokens are split
at commas not escaped with a backslash, since AdGuard and uBO escape the
commas inside a value (`$removeparam=/^(a|b)\,c/`). Any other token makes
the `$` part of the pattern: a bare word (`example.com/hit$value`), an
unshaped name (`/a$|b=c{1,3}/$script`), or a later non-option token
(`||site.example/banner$id=1,2$image`, where the options start at the last
`$`). An earlier draft stopped at the first unsupported option and so read
that last line as `$id=...` and left the rule out.

What it changed in the built-in lists, as fetched on 2026-11-15 (the copies
measured in [chunks](./content-blocking-chunks.md#how-close-the-lists-are)),
by dumping both parsers' rules and diffing them: no list has a
`$removeparam` line, and only `easyprivacy` changed, by two rules (56,555 →
56,553 parsed, 106 → 108 skipped). The other three lists came out identical,
rule for rule and in order.

- `||void.nicopr.fr/rec$method=POST`: was a block rule for every method,
  now left out (the user's decision, 2026-11-16).
- `@@||google-analytics.com/analytics.js$redirect-rule,script,domain=mond.how`:
  was a literal-pattern exception that matched nothing, now left out.

## Aliases, other blockers' modifiers and `$match-case` (TASK-371)

**Aliases.** uBlock Origin's and AdGuard's short names compile as the
Adblock Plus options they stand for, `~` forms included
(`EasyListParser.canonicalOption`): `$1p` and `$first-party` are
`~third-party` (so `~1p` is `third-party`), `$3p` is `third-party`, `$xhr`
`xmlhttprequest`, `$frame` `subdocument`, `$css` `stylesheet`, `$doc`
`document`, `$beacon` `ping` (a uBO name added in the review; not on uBO's
documentation page, unverified against its parser), and `$from=` is `domain=`. Every reader of a rule's options
(`optionTokens`, which `buildTrigger`, the `@@` mapping and the page-wide
exception use, and `isSupportedOption`) goes through the one function, so an
alias accepted as supported always has its option's effect; a check that
accepted an alias while the trigger ignored it would turn `||x^$3p,xhr` into
a block rule for every load from the host, the TASK-351 bug again. Before,
a bare alias was read as part of the pattern (a literal rule that matched
nothing) and, after TASK-351, a `$from=` rule was left out.[^task-371] Mapping
`$from=` is Claude's choice (not yet confirmed by the user); the
alternative is to keep leaving such rules out. `$to=` (the request's
domains) stays unsupported. A `$badfilter` line still names its target
textually, so `||x^$3p,badfilter` does not disable `||x^$third-party`.

**Other modifiers written without a value** are options too: the rule is
left out and counted as skipped, block rule and exception alike. The list
(`unsupportedModifiers`) comes from uBO's "Static filter syntax" and
AdGuard's "How to create your own ad filters" pages: AdGuard's
exception-only `$urlblock`, `$jsinject`, `$content`, `$extension`,
`$network`; uBO's `$popunder`, `$inline-script`, `$inline-font`, `$cname`,
the strict party options (`$strict1p`, `$strict3p`, `$strict-first-party`,
`$strict-third-party`, narrower than `$1p`/`$3p`, so not aliases) and the
deprecated `$empty`, `$mp4`, `$queryprune`; AdGuard's `$xmlprune` and
`$referrerpolicy`. Before, each became a literal pattern that matched
nothing and was counted as a rule. A bare word outside the list stays part
of the pattern (`example.com/hit$value`), as TASK-351 decided, so a
modifier those blockers add later reads as a never-matching literal until
it is listed. The no-op `$noop` and `$_` are not handled (left as they
were).

**`$match-case`** sets `url-filter-is-case-sensitive` to true, and on a
`$document` exception whose pages come from its pattern also
`top-url-filter-is-case-sensitive`. WebKit's default for both is false
(measured: before the fix a `/AdBanner.$match-case` rule blocked
`/adbanner.png` in a web view; a web view test now checks both keys,
the page condition on `/Shop/` and `/shop/`), which is how filter rules
match without the option; before, the option was accepted and ignored, so the rule matched
every case.

What it changed in the built-in lists: nothing. The four lists as fetched on
2026-11-15 (TASK-359's copies and the app's cache), dumped with both parsers
built standalone, came out identical rule for rule and in order; none uses
an alias, one of the modifiers above or `$match-case`. The format still
moved to 5, since the output for the same text changes.

The AdGuard URL Tracking list's `$removeparam` rules are not parsed here at
all; `TrackingParameterFilter` uses them (see
[the lists](./content-blocking.md#lists)).

# Regex rewriting

ABP regex literals are rewritten: `{n,m}` quantifiers (and `{n}`, `{n,}`) are
expanded into repeated atoms and `(a|b)` disjunctions into several rules,
because WebKit's rule regex supports neither.

# Domain lists

A domain list (`a.example,~b.example##`, `$domain=a|~b`) becomes one page
condition; see [domain lists](./content-blocking-domain-lists.md).

# Recompiling after a parser change

A compiled rule list in WebKit's store is reused at launch, and a refresh
only recompiles when the list text changed (an unchanged list answers 304),
so a parser fix would never reach an existing install. Every successful
compile records `ContentBlocker.<id>.rulesFormat` =
`EasyListParser.rulesFormatVersion` (2 since TASK-199, 3 since TASK-201, 4
since TASK-351, 5 since TASK-371); at launch a list
whose recorded format differs, or is missing (every install before
TASK-199), is recompiled from the cached text, and the lists found stay
attached until the new ones replace them
(`ContentBlockerManager.shouldReuseCompiledList(recordedFormat:)`).
**Bump `rulesFormatVersion` whenever the parser's output for the same text
changes.**

How the upgrade runs (`ContentBlockerManager`):

- `loadAndCompileFromCache` reads and parses the cached text on a utility
  queue (every list is parsed at the launch after a format change), then
  compiles (see [threading](./content-blocking-rule-compilation.md#threading)).
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
launch reused every list with no compile or fetch.[^task-199]

A chunk of a split list that failed to compile can keep the old format
behind a list recorded as current; see
[what splitting does not solve](./content-blocking-chunks.md#what-splitting-does-not-solve).

# Tests

- `ContentBlockerTests` - parser cases, and compiling each cached real list
  through WebKit.
- `ContentBlockerExceptionTests` - the sections and `@@` options (see
  [exceptions](./content-blocking-exceptions.md#tests)), the `rulesFormat`
  reuse rule, unsupported options (`$removeparam` in every form, as an
  exception, the other modifiers; the supported options and a literal `$`
  unchanged), and TASK-371's aliases (the same rules as their options, and
  what they block), other blockers' bare modifiers, and `$match-case`
  (trigger keys, a `$document` page condition, and a web view).
- `ContentBlockerDomainListTests` - domain lists and punycode (see
  [domain lists](./content-blocking-domain-lists.md#tests)).

# Related

- [Content blocking](./content-blocking.md) - the lists and the fetch, parse, compile pipeline.
- [Rule-list compilation](./content-blocking-rule-compilation.md) - what happens to the parser's output next.
- [Tracking parameters](./tracking-parameters.md) - where `$removeparam` rules from the AdGuard URL Tracking list are used.

[^task-199]: $generichide / $elemhide exceptions compile to ignore-previous-rules and unblock all loads on those hosts
[^task-351]: Content blocking: a filter list's $removeparam line compiles into a block rule for the whole host
[^task-371]: Content blocking: parser gaps — uBO aliases, bare modifiers that become never-matching rules, $match-case ignored
