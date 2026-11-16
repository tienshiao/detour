---
id: TASK-371
title: >-
  Content blocking: parser gaps — uBO aliases, bare modifiers that become
  never-matching rules, $match-case ignored
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
updated_date: '2026-11-16T21:45:00Z'
labels:
  - content-blocking
  - filter-lists
dependencies: []
references:
  - wiki/features/content-blocking-filter-conversion.md
priority: low
type: task
ordinal: 452000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-351's agent. (1) uBO aliases $1p, $3p, $xhr, $frame are read as part of the pattern (literal rules that never match); $from= is now skipped. (2) Bare modifiers not in unsupportedModifiers ($urlblock, $jsinject, $network, $popunder) also become literal never-matching rules, counted against the per-list cap and not as skipped. (3) $match-case is ignored, so such a rule matches more than intended. None appear in the built-in lists today.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The aliases map to their ABP options
- [x] #2 Unknown bare modifiers are skipped and counted
- [x] #3 $match-case is honoured or the rule skipped
- [x] #4 Parser tests cover each; rulesFormatVersion bumped if output changes
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Failing tests first (ContentBlockerExceptionTests, new MARK TASK-371): aliases give the same rules as their ABP options (1p/first-party/~1p, 3p/~3p, xhr/~xhr, frame/~frame, css, doc, from=) plus an evaluator check; uBO/AdGuard bare modifiers (urlblock, jsinject, network, popunder, content, extension, inline-script, ...) are left out and counted; $match-case sets url-filter-is-case-sensitive (and top-url-filter-is-case-sensitive on a $document page condition); a web view case shows WebKit honours it.
2. EasyListParser: one canonicalOption(_:) used by optionTokens, buildTrigger and isSupportedOption (aliases, from= -> domain=, value case kept); extend unsupportedModifiers from the uBO static-filter-syntax and AdGuard modifier docs; match-case -> case-sensitive trigger keys. Bare words outside the catalogue still stay part of the pattern (/hit$value).
3. rulesFormatVersion 4 -> 5; before/after rule dump of TASK-359's four list copies with TASK-351's standalone tool; explain every difference (none expected).
4. Wiki filter-conversion page, log; Backlog notes.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Failing first (ContentBlockerExceptionTests on the unchanged parser, 6 new tests, 75 assertion failures): aliases gave literal-pattern rules ($1p/$3p/$xhr/$frame/$css/$doc) and $from= rules were left out (21); aliased rules did not block what their options block (3); 21 bare modifiers each added a literal rule and no skip (42); $match-case rules matched every case and had no case-sensitive key (6), nor the $document page condition (2); in a WKWebView /AdBanner.$match-case blocked /adbanner.png (1) — so WebKit's url-filter-is-case-sensitive default is false.

Fix (EasyListParser): one canonicalOption(_:) (aliases 1p/first-party -> ~third-party, 3p -> third-party, xhr, frame, css, doc, beacon -> ping; from= -> domain=; ~ forms inverted) used by optionTokens, which buildTrigger now reads instead of re-splitting the options, and by isOptionList; unsupportedModifiers extended from uBO's Static filter syntax and AdGuard's modifier docs (urlblock, jsinject, content, extension, network, popunder, inline-script, inline-font, cname, strict1p/3p, strict-first/third-party, empty, mp4, queryprune, xmlprune, referrerpolicy); $match-case writes url-filter-is-case-sensitive true, and top-url-filter-is-case-sensitive on a $document exception's if-top-url. Bare words outside the catalogue stay part of the pattern (/hit$value, TASK-351's tested rule). rulesFormatVersion 4 -> 5.

Rule diff (TASK-351's standalone dump tool, HEAD parser vs new, sorted-key JSON per rule): TASK-359's four copies (easylist 73,252, easyprivacy 56,553, fanboy-cookiemonster 25,109, urlhaus-filter-online 109,083) and the app's cached copies (75,032 / 56,551 / 25,109 / 109,048) are byte-identical before and after — none uses an alias, a listed modifier or $match-case (option survey). So no change to explain; the bump is because the output for the same text changes.

Chosen by Claude (not yet confirmed by the user): $from= maps to domain= (uBO and AdGuard document it as the alias); alternative: keep leaving such rules out as TASK-351 did. Also chosen: $css, $doc, $first-party and (from the review) $beacon mapped besides the four named aliases; $noop/$_ left as before; $badfilter still matches its target textually (an alias spelling does not disable the full spelling).

Tests: ContentBlockerExceptionTests 39, ContentBlockerTests 11, ContentBlockerDomainListTests 16, TrackingParameterFilterTests 40 (1 pre-existing skip): 106 run, 0 failures (after the review). Before the review also ContentRuleStoreThreadingTests, ContentRuleListChunkTests (2 gated skips), ContentBlockerWhitelistTests: 184 run, 0 failures. No UI change, no /verify; not verified at runtime: the launch-time recompile from format 4 to 5 (TASK-199's mechanism, tested by testACompiledListIsReusedOnlyWhenItsFormatIsCurrent).

Code review (/code-review medium --fix, 5 findings): fixed $beacon alias (review), isSupportedOption no longer canonicalises twice (review); I extended testMatchCaseIsHonouredInAWebView to the $document page condition (WebKit took every rule; /shop/ blocked, /Shop/ allowlisted). Left: $badfilter alias matching (behaviour TASK-351 documents), the 1.5 s settle sleep in the web view test (no event to wait for an unblocked load).

Chosen by Claude (not yet confirmed by the user): unknown bare modifiers are a catalogue of the names uBO and AdGuard document (unsupportedModifiers), so a bare word outside it ($foo) still compiles to a never-matching literal; alternative: treat any option-shaped trailing $word as an option, as ABP and uBO do, which would reverse TASK-351's tested /hit$value rule. The catalogue includes ordinary words (content, network, extension, empty, mp4): a $ before one now reads as the option separator.

Chosen by Claude (not yet confirmed by the user): rulesFormatVersion bumped to 5 although the four built-in lists parse byte-identically, following the wiki rule (bump whenever the output for the same text changes); cost: every install re-parses and recompiles all four lists once at the next launch; alternative: no bump (only custom text using these options would differ).

User decisions 2026-11-16: confirmed: $from= maps to domain=; $css, $doc, $first-party and $beacon mapped besides the four named aliases; unknown bare modifiers are a catalogue of the names uBO and AdGuard document (unsupportedModifiers), not any option-shaped trailing $word; rulesFormatVersion bumped to 5. $noop/$_ left literal and $badfilter matching its target textually are filed as TASK-396.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
EasyListParser now maps uBO/AdGuard option aliases ($1p/$first-party, $3p, $xhr, $frame, $css, $doc, $beacon, $from=, with ~ forms) to their Adblock Plus options through one canonicalOption every option reader uses; leaves out and counts rules with the other bare modifiers those blockers document ($urlblock, $jsinject, $network, $popunder, ...) instead of compiling never-matching literal rules; and honours $match-case (url-filter-is-case-sensitive, plus top-url-filter-is-case-sensitive on a $document page condition; WebKit's default is case-insensitive, measured). rulesFormatVersion 4 -> 5. Six new tests failed first (75 assertions) and pass now; 106 content-blocker tests pass after the review. The four built-in lists parse byte-identically before and after (none uses these options). Mapping $from= to domain= is Claude's choice, to confirm. Not runtime-verified: the format-5 recompile at launch (existing mechanism, tested).
<!-- SECTION:FINAL_SUMMARY:END -->
