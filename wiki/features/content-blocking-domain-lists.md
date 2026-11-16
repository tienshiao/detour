---
type: Concept
title: Content blocking domain lists
description: "How EasyListParser turns a filter rule's domain list (a.example,~b.example## or $domain=a|~b) into the one page condition WebKit allows per trigger: Adblock Plus's most-specific-domain rule, if-top-url label-complement patterns for an exclusion under an included domain, punycode domains, the options rejected, and the bad-rule counts per shipped list before and after TASK-201."
tags: [content-blocker, webkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:39:06Z }
sources:
  - id: parser
    resource: ../../Detour/Browser/ContentBlocker/EasyListParser.swift
    title: EasyListParser.swift (domainCondition, DomainCondition, sanitizeDomain)
  - id: webkit-parser
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebCore/contentextensions/ContentExtensionParser.cpp
    title: WebKit ContentExtensionParser.cpp (one condition per trigger, if-domain to page URL regex, lower-case ASCII domains)
  - id: task-201
    resource: backlog:TASK-201
    title: Cosmetic rules with both included and excluded domains compile to a trigger WebKit rejects
  - id: domain-list-tests
    resource: ../../DetourTests/ContentBlockerDomainListTests.swift
    title: ContentBlockerDomainListTests.swift
  - id: exception-tests
    resource: ../../DetourTests/ContentBlockerExceptionTests.swift
    title: ContentBlockerExceptionTests.swift (the mixed-list web view tests)
  - id: harness
    resource: ../../docs/harness/task201-harness.patch
    title: TASK-201 runtime harness
---

A filter rule can name the pages it applies to with a domain list
(`a.example,~b.example##sel`, `$domain=a|~b`). WebKit allows one page
condition per trigger, so [the parser](./content-blocking-filter-conversion.md)
turns every domain list, included and excluded domains together, into exactly
one condition (TASK-201). Part of [content blocking](./content-blocking.md).

# What WebKit accepts

WebKit takes **one** page condition per trigger: `if-domain`,
`unless-domain`, `if-top-url`, `unless-top-url`, `if-frame-url` or
`unless-frame-url`; a second one fails the whole compile ("more than one
condition", `JSONMultipleConditions`). `if-domain` and `unless-domain` are
compiled into page URL regexes (`[a-z][a-z+.-]*:\/\/([^/]*\.)*<domain>[:/]`
for a `*domain`), and a domain must be lower-case ASCII
(`JSONDomainNotLowerCaseASCII`).[^webkit-parser] Until TASK-201 the parser
gave a list with included **and** excluded domains both an `if-domain` and an
`unless-domain`; the bad-rule search then stripped the rule.[^task-201]

# Rules

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

## Excluding a subdomain with `if-top-url`

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
exceptions; see [exceptions and element hiding](./content-blocking-exceptions.md)),
and a pattern-less cosmetic exception
(`@@$generichide,domain=a|~sub.a`) takes the `if-top-url` as its page
condition.

# Options rejected

- **An `if-domain` rule followed by an `ignore-previous-rules` for the
  excluded subdomain**: it undoes every earlier action of the list on that
  page, not only this rule's (all hiding before it, or every block rule for
  the URL), so it is not a per-rule exclusion.
- **A document-only trigger** (`resource-type` `document`, the page's host in
  `url-filter`, `unless-domain` for the exclusion): WebKit keeps a document
  load's selectors for the new document, so it would work for hiding, but not
  for network rules, whose `url-filter` is the resource URL, and it would stop
  hiding in frames of other hosts.

# How many rules this touches

None of the four shipped lists has a mixed
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
out.

# Seen at runtime

With the fix the app compiles all four lists whole ("Active" equals "In
List"), and a list carrying `lvh.me,~sub.lvh.me##.t201-ad` and
`/t201-ad.js$domain=lvh.me|~sub.lvh.me` hid and blocked on lvh.me and
www.lvh.me and did neither on sub.lvh.me and x.sub.lvh.me
(`docs/harness/task201-harness.patch`).[^task-201] The change raised
`EasyListParser.rulesFormatVersion` to 3, so existing installs recompile (see
[recompiling after a parser change](./content-blocking-filter-conversion.md#recompiling-after-a-parser-change)).

# Tests

- `ContentBlockerDomainListTests` - `domainCondition` (exclusions outside
  the included domains dropped, an included domain excluded again, the
  `if-top-url` patterns matched against URLs on and off the included domain:
  near-miss labels, deeper exclusions, an included domain under an
  exclusion, query-string and suffix lookalikes), the parser's output for
  element hiding, `domain=` blocks and exceptions and a pattern-less
  `$generichide` (one condition, the right section, evaluated with
  `RuleListEvaluator`), punycode for internationalised domains, and every
  such rule compiled one by one through a real `WKContentRuleListStore`.
- `ContentBlockerExceptionTests` adds two web view tests: a mixed list
  compiles whole (no rule stripped) and hides and blocks on a.example and
  www.a.example, not on sub.a.example and x.sub.a.example.

# Related

- [Filter-list conversion](./content-blocking-filter-conversion.md) - the parser this condition is part of.
- [Exceptions and element hiding](./content-blocking-exceptions.md) - where domain-specific hiding and cosmetic exceptions sit in the output.
- [Rule-list compilation](./content-blocking-rule-compilation.md) - the bad-rule search that used to strip mixed-list rules.
- [Site settings](../architecture/site-settings.md) - a different host-or-parent matching rule, for the per-site switch.

[^webkit-parser]: WebKit ContentExtensionParser.cpp (one condition per trigger, if-domain to page URL regex, lower-case ASCII domains)
[^task-201]: Cosmetic rules with both included and excluded domains compile to a trigger WebKit rejects
