---
id: TASK-201
title: >-
  Content blocking: cosmetic rules with both included and excluded domains
  (a.example,~b.example##sel) compile to a trigger WebKit rejects
status: Done
assignee:
  - '@claude'
created_date: '2026-10-25 09:39'
updated_date: '2026-10-27 07:44'
labels:
  - bug
  - content-blocker
dependencies: []
priority: low
ordinal: 237000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-200 subagent 2026-10-25 while writing a sample list. EasyListParser gives a cosmetic rule whose domain list mixes included and excluded domains (e.g. `a.example,~b.example##.sel`) both an if-domain and an unless-domain in one trigger. WebKit allows only one such condition per trigger and rejects the rule ('more than one condition'). The bad-rule search then strips it, so the rule never applies. This may be why easylist-cookie compiles with 2 bad rules (not confirmed).

Fix direction: an included-plus-excluded list means 'on these domains, except these subdomains'. Options: emit the rule with if-domain only and add a following ignore-previous-rules-style exception (cosmetic-scoped, as TASK-199 does) for the excluded domains; or drop the excluded domains when they're not subdomains of an included one (the exclusion is then a no-op); or, when the excluded domains are subdomains of included ones, split into if-domain for the included and a whole-page cosmetic exception for the excluded. Check how network rules with $domain=a|~b are handled (same problem?). Count how many rules in the real lists are affected before and after.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Mixed included/excluded domain rules compile without WebKit rejecting them, and hide on the included domains but not the excluded ones (test with a real web view)
- [x] #2 The number of bad rules stripped from each real list is recorded before and after; easylist-cookie's 2 explained
- [x] #3 Network rules with mixed $domain= lists checked for the same problem
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Findings before coding (lists cached 2026-10-26, standalone parser+WKContentRuleListStore bisection tool):
- No shipped list has a mixed included/excluded domain list today: 0 cosmetic, 0 network rules in easylist, easyprivacy, easylist-cookie, urlhaus-filter.
- easylist-cookie's 2 bad rules are NOT mixed-domain rules: they are two element-hiding rules whose if-domain holds an IDN domain (przesył-energii.pl, wanderwege-graubünden.ch). sanitizeDomain 'punycodes' with URLComponents.percentEncodedHost, which percent-encodes (przesy%C5%82-energii.pl); WebKit rejects a domain that is not lower-case ASCII. Other lists: 0 bad rules.
- Network rules with $domain=a|~b go through buildTrigger and get the same two conditions (same rejection).

Plan (TDD, pure rule logic in EasyListParser):
1. One domain-condition function shared by element hiding and buildTrigger, with Adblock Plus semantics (the most specific listed domain wins):
   - exclusions not under any included domain are no-ops: dropped, the rule keeps a plain if-domain;
   - an included domain that is itself excluded is dropped; none left = the rule applies nowhere and is skipped;
   - exclusions under an included domain: the condition becomes if-top-url with regexes for 'the included domain and its subdomains except the excluded subtrees' (label-complement patterns, no disjunction since WebKit's regex has none). Same trigger shape as if-domain otherwise (every load, every frame).
   - only exclusions: unless-domain, as before.
2. Page-wide exceptions without a pattern accept the if-top-url condition too; element hiding with if-top-url goes in the domain-specific section.
3. sanitizeDomain uses URLComponents.encodedHost (punycode).
4. Bump rulesFormatVersion to 3.
Tests: parser shape, pattern matching against hosts, WebKit compile of the produced JSON, a real WKWebView page showing hidden on the included domain and visible on the excluded subdomain (hosts reached via a URLProtocol-free path: local fixture). Then re-run the bad-rule count per list after. Runtime: harness compiles a list with such a rule in the app (isolated DETOUR_DATA_DIR) against a local fixture.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented (TDD: ContentBlockerDomainListTests + two web view tests in ContentBlockerExceptionTests written first; red run: 13 domain-list tests and the 'applies on the included domain' web view test failed, WebKit rejected the mixed rules with 'A trigger cannot have more than one condition').
- EasyListParser.domainCondition(included:excluded:) -> DomainCondition (.everyPage/.ifDomain/.unlessDomain/.ifTopURL/.noPage), shared by element hiding and buildTrigger (domain=). ABP rule: most specific listed domain decides. Exclusions outside every included domain are dropped; an included domain that is also excluded is dropped (none left = rule skipped and counted); an exclusion under an included domain gives if-top-url patterns: per root, a walk over the exclusion label tree (own host exact, '([^/]*\.)*<label not among children>\.<suffix>[:/]', recurse into non-excluded children); 'label not in S' spelled out by a char trie ([^/.:s][^/.:]*, s, s[^/.:u][^/.:]*, ...). Anchored with ^ and WebKit's scheme regex.
- Element hiding with if-top-url is domain-specific (isGeneric checks if-top-url too); a pattern-less page-wide exception takes if-top-url as its page condition.
- sanitizeDomain: URLComponents.encodedHost (punycode) instead of percentEncodedHost (percent-encoding, upper-case hex: WebKit's JSONDomainNotLowerCaseASCII). This was the cause of easylist-cookie's 2 bad rules (przesył-energii.pl, wanderwege-graubünden.ch). Small default taken: fixed here, since the AC asks for the 2 to be explained and the before/after counts.
- rulesFormatVersion 3 (every list recompiles once from cache at the next launch).
- Counts (lists cached 2026-10-26, standalone parser + WKContentRuleListStore bisection tool): mixed domain lists in the shipped lists: 0 element hiding, 0 domain=. Bad rules stripped before/after: easylist 0/0, easyprivacy 0/0, easylist-cookie 2/0, urlhaus-filter 0/0. Parser output diff old vs new on all four lists: only the 2 IDN rules change.
- AC3 (network rules): yes, $domain=a|~b had the same problem (buildTrigger emitted both conditions); fixed by the same function, tested for block rules and @@ exceptions.
- Rejected: an if-domain rule plus a following ignore-previous-rules for the excluded subdomain (undoes all earlier actions of the list on that page, not just this rule's); a document-only trigger with the host in url-filter plus unless-domain (works for hiding only, not network rules; loses frames of other hosts).

Code review (code-review high --fix, 8 findings): fixed 5 — sanitizeDomain rejects encodedHost's percent-encoded fallback for hosts IDNA cannot encode (xn--ü.de); a list whose included domains all fail to sanitise is .noPage (rule skipped), never widened to every page (new domainCondition(ofEntries:)); page patterns skip user info (([^/@]*@)?) and label classes exclude @ so x@sub.a.example stays excluded; Set lookups in domainCondition; pageWideException switches on the domain condition instead of building a network trigger. Skipped 3: exclusions with non-plain labels (~*.sub.a.example) are ignored (meaning of a wildcard exclusion unclear; none in the shipped lists); splitting a rule into if-domain + if-top-url to cut pattern count (speculative, none in the shipped lists); a redundant >=2 assertion. After the fixes the real-list output still differs from the old parser only in the 2 IDN rules, and the bisection tool finds 0 bad rules in all four lists.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Rules whose domain list mixes included and excluded domains (a.example,~sub.a.example##sel, $domain=a.example|~sub.a.example) now compile with one page condition instead of an if-domain plus an unless-domain WebKit rejected. EasyListParser.domainCondition follows Adblock Plus (most specific listed domain wins): exclusions outside the included domains are dropped (plain if-domain), an included domain excluded again is dropped (rule skipped if none left), an exclusion under an included domain becomes if-top-url label-complement patterns (WebKit's regex has no alternation/lookahead). Same for element hiding, domain= block rules and exceptions, and pattern-less page-wide exceptions. easylist-cookie's 2 stripped rules turned out to be IDN domains percent-encoded by URLComponents.percentEncodedHost; now punycode via encodedHost. rulesFormatVersion 3.

Counts (lists of 2026-10-26): mixed domain lists in the shipped lists: 0. Bad rules stripped before/after: easylist 0/0, easyprivacy 0/0, easylist-cookie 2/0, urlhaus-filter 0/0; parser output otherwise unchanged.

Tests (after review): ContentBlockerDomainListTests 16, ContentBlockerExceptionTests 25 (2 new real-WKWebView tests), ContentBlockerTests 11 (real lists compiled), ContentBlockerWhitelistTests 22, ContentRuleListChunkTests 35, ContentRuleStoreThreadingTests 9: 118 tests, 0 failures. Every mixed rule compiled one by one through a real WKContentRuleListStore.

Runtime (docs/harness/task201-harness.patch, isolated DETOUR_DATA_DIR, lists served by a URLProtocol, fixture on 127.0.0.1 via lvh.me DNS): all four lists compiled with Active == In List (easylist-cookie 25,079/25,079); with lvh.me,~sub.lvh.me##.t201-ad and /t201-ad.js$domain=lvh.me|~sub.lvh.me the ad box was hidden and the script blocked on lvh.me and www.lvh.me, shown and run on sub.lvh.me and x.sub.lvh.me (logs + screenshots).

Not verified: the runtime harness ran on the build before the review fixes (user-info prefix, % rejection, .noPage for unsanitisable lists); those are covered by the unit and web view tests, which ran after. The one-time recompile at launch after the format bump was not timed (TASK-199/200 measured the same path).
<!-- SECTION:FINAL_SUMMARY:END -->
