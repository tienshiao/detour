---
id: TASK-19
title: >-
  Extensions: restore optional-permission decisions and an <all_urls> denial
  when a context is (re)loaded
status: Done
assignee:
  - '@claude'
created_date: '2026-09-12 17:29'
updated_date: '2026-09-12 18:21'
labels:
  - extensions
  - webkit
  - permissions
dependencies: []
documentation:
  - docs/1password-integration-plan.md
priority: medium
ordinal: 19000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Same class of bug as TASK-11, for two other row kinds. Profile.loadExtensionContext restores saved ExtensionPermissionRecord rows only for keys it finds in wkExt.requestedPermissions and wkExt.requestedPermissionMatchPatterns, and applies the '<all_urls>' row only when it is granted. But ExtensionManager.handlePermissionPrompt persists whatever WebKit prompted for: an API permission or match pattern listed under the manifest's optional_permissions / optional_host_permissions (requested at runtime via permissions.request) is saved as an .apiPermission / .matchPattern row and then never re-applied, and a user's denial of '<all_urls>' is saved but never re-applied. Because Profile.recoverFromBackgroundLoadFailure reloads a context mid-session (and every launch reloads it), the extension is re-prompted for optional permissions it was already granted, or loses them, and WebKit re-prompts for all-URLs access the user already refused. Fix on the restore side: walk wkExt.optionalPermissions and wkExt.optionalPermissionMatchPatterns as well as the requested sets, and apply a saved '<all_urls>' row whether granted or denied. Keep TASK-11's rule that rows outside the manifest's requested+optional sets stay inert (never widen a stale row). Verify which string WebKit reports for '<all_urls>' in requestedPermissionMatchPatterns / optionalPermissionMatchPatterns (pattern.string) so the explicit '<all_urls>' branch and the loop do not double-apply or disagree.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A granted optional API permission (manifest optional_permissions, granted via the promptForPermissions delegate) is granted on the context after unload+reload and after a fresh launch, without a new prompt
- [x] #2 A denied optional API permission stays denied after reload; WebKit does not re-prompt for it
- [x] #3 A granted or denied optional host match pattern (optional_host_permissions) is restored the same way
- [x] #4 A denied '<all_urls>' row is applied as deniedExplicitly on reload; a granted one still restores as before
- [x] #5 Rows whose key is in neither the requested nor the optional sets are still not applied (TASK-11 stale-row rule holds)
- [x] #6 ExtensionPermissionRestoreTests cover each case above with positive and negative variants on a real Profile, and ExtensionPermissionTests cover the permission gating
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Empirically determine (probe test) how WebKit reports <all_urls> and optional sets from the manifest: pattern.string, requested vs optional membership, and whether WKWebExtension filters unsupported optional permission names.
2. Profile.loadExtensionContext: restore saved rows over requestedPermissions UNION optionalPermissions (API) and requestedPermissionMatchPatterns UNION optionalPermissionMatchPatterns (host), applying granted -> .grantedExplicitly and denied -> .deniedExplicitly. Keep nativeMessaging special-cased (always granted at context level, skipped by the loop).
3. Fold the explicit <all_urls> branch into the pattern loop if the probe confirms pattern.string == "<all_urls>" verbatim, so a denied <all_urls> restores too and there is no double-application; drop the now-unused allURLsPattern static. Gating stays TASK-11's stale-row rule: a row whose key is in neither the requested nor optional set is never applied.
4. Apply grants before denials so overlapping opposite decisions end fail-closed despite arbitrary Set iteration order.
5. Tests: extend the ExtensionPermissionRestoreTests fixture with permissions/optional_permissions; add positive+negative cases for optional API permissions, optional host patterns, denied/granted <all_urls>, stale rows outside requested+optional, and survival across unload+reload. Add DB-level gating cases to ExtensionPermissionTests.
6. Build Detour, run ExtensionPermissionRestoreTests + ExtensionPermissionTests, self-review the diff, finalize the task and commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## What changed

Profile.loadExtensionContext now restores saved rows over the union of the manifest's up-front and optional lists: requestedPermissions ∪ optionalPermissions for .apiPermission rows, requestedPermissionMatchPatterns ∪ optionalPermissionMatchPatterns for .matchPattern rows, granted -> .grantedExplicitly and denied -> .deniedExplicitly in both cases. nativeMessaging keeps its unconditional context-level grant and is skipped by the loop (the user's decision is enforced in the polyfill bridge). The explicit '<all_urls>' branch and the allURLsPattern static are gone, folded into the pattern loop.

## The <all_urls> string finding (probe test, macOS 15 SDK)

WebKit reports the literal pattern verbatim: pattern.string == "<all_urls>" in requestedPermissionMatchPatterns when the manifest lists it under host_permissions, and in optionalPermissionMatchPatterns when it lists it under optional_host_permissions — never expanded per scheme (no '*://*/*'), and WKWebExtension.MatchPattern(string: "<all_urls>") is set-equal to the reported member. Listing it in both manifest keys reports it only in the requested set (WebKit de-dupes). So the loop and the old explicit branch used the same key: folding them in cannot double-apply or disagree. Pinned as testWebKitReportsAllURLsVerbatimInBothPatternSets.

Corollary worth recording: because '<all_urls>' was already in requestedPermissionMatchPatterns for a manifest that asks for it, the old requested-pattern loop already restored that row for BOTH statuses — a denied '<all_urls>' was only lost when the manifest listed it under optional_host_permissions (confirmed: testDeniedAllURLsIsRestoredAsDenied passes pre-fix, testOptionalAllURLsDecisionsAreRestored fails pre-fix). The explicit branch's real effect was the opposite of a fix: it applied a granted '<all_urls>' row *ungated*, widening access for a manifest that no longer asks for all sites. Removing it closes that hole (testStaleHostPatternRowIsNotApplied).

Also observed: WKWebExtension filters manifest permission names it does not implement out of optionalPermissions (e.g. 'bookmarks' is dropped, 'cookies'/'webNavigation' kept). Such a row is never applied — and WebKit never prompts for it either, so no re-prompt results.

## Decisions

- Grants are applied before denials in the pattern loop: the sets are Sets, so iteration order is arbitrary; landing denials last makes the end state fail closed when two overlapping patterns carry opposite decisions.
- Gating is unchanged from TASK-11: a key in neither manifest set is never applied. One consequence accepted deliberately: a legacy '<all_urls>' grant belonging to an extension whose current manifest spells all-sites access as '*://*/*' is now skipped where the old ungated branch applied it — cost is at most one re-prompt, and the alternative is widening access the manifest does not justify.
- ExtensionPermissionTests holds DB-level, not context-level, permission coverage (the context path needs a real Profile, which lives in ExtensionPermissionRestoreTests), so the gating cases added there cover the restore's *inputs*: optional decisions are stored under exactly the same type/key as required ones (which is why the restore must consult both manifest sets), '<all_urls>' is an ordinary match-pattern row whose key is the literal string and whose latest answer replaces the previous one, and an unrecognised status raw value reads as .denied (fail closed).

## Validation

Build: xcodebuild -scheme Detour -configuration Debug build — BUILD SUCCEEDED, no new warnings.
Tests (isolated data dir DetourTests-task19): ExtensionPermissionRestoreTests 21 passed (12 new), ExtensionPermissionTests 26 passed (3 new), plus the other suites that load contexts — ExtensionPolyfillIntegrationTests 21, ExtensionPolyfillProfileWiringTests 10, WKExtensionIntegrationTests 20 (6 skipped): 98 executed, 0 failures.
Pre-fix control run: with Profile.swift reverted, 8 of the 12 new restore tests fail (15 assertions) — both optional API permission cases, both optional host pattern cases, the optional reload case, the optional '<all_urls>' case and both stale-row cases. The 4 that pass pre-fix pin behaviour that already worked (the WebKit reporting contract, required-permission restore, and granted/denied '<all_urls>' under host_permissions).

## Out of scope, noticed

- Settings (ExtensionsSettingsViewController) lists optional_permissions toggles (now honest, they were previously ON but never applied) but has no rows for optional_host_permissions, so an optional host decision cannot be reversed from Settings.
- The .url restore loop iterates DB order and is not grant-before-deny ordered like the pattern loop now is; left alone to keep this diff on TASK-19's scope.

Review follow-ups (TASK-19 hardening):

- Pattern restore is now match-gated and iterates the SAVED rows rather than the manifest sets. Reason: `permissions.request({origins})` makes WebKit prompt with the CALLER'S pattern verbatim (e.g. `https://mail.example/*`), gated only by whether some requested/optional manifest pattern subsumes it, and ExtensionManager saves the row under that sub-pattern's own string — which is in neither manifest set, so the old exact-string membership check silently dropped every such decision. A row is restorable iff some askable manifest pattern `matches` it; rows outside every manifest pattern stay inert (TASK-11's rule).
- The implicit activeTab content-script grant was MOVED ahead of the DB restore, so a saved denial for the same or a broader pattern is no longer overwritten by it.
- The `.url` loop now runs the same grants-then-denials two-pass ordering (WebKit widens each URL into an origin pattern, so two rows on one origin overlap) and gates on the hoisted askable-pattern set.
- Corrected rationale for grants-before-denials. Probed WKWebExtensionContext: granted and denied match patterns live in separate dictionaries, and writing a NON-all-hosts pattern REMOVES any entry in the opposite dictionary that the new pattern subsumes (deny `https://sub.example.com/*` then grant `*://*.example.com/*` empties the denied dict; the reverse order keeps the denial). `<all_urls>` is all-hosts and equality-only, so it does not erase narrower entries — and an all-hosts grant plus an all-hosts denial leaves BOTH entries present, with deny winning at query time. So denials go last because a later overlapping write erases the earlier entry from the other set, not because "the denial should land last" per se.
- Corrected the nativeMessaging comments: the context-level grant exists so the polyfill bridge can call sendNativeMessage, and the saved row is skipped so it cannot flip that grant. The previous claim that the user's decision is "enforced in the bridge" is false — `ExtensionManager.nativeHostAccess` gates real hosts on the MANIFEST declaration only, and the saved nativeMessaging decision is not enforced anywhere today. Follow-up candidate.
- New shared accessors: `WebExtension.askablePermissions` / `askableMatchPatterns` (requested ∪ optional; empty when wkExtension is nil; the ObjC properties bridge a fresh Set per access, so callers hoist them), a `canAskForAccess(to: MatchPattern)` overload, and `ExtensionPermissionStatus.contextStatus` (grant → .grantedExplicitly, anything else → .deniedExplicitly, fail closed).
- Tests (ExtensionPermissionRestoreTests, 29 total, all passing): the fixture can now emit a `content_scripts` entry. Added denial-vs-activeTab-grant (plus the no-saved-decision companion), permissions.request sub-pattern grant/denial under an optional `<all_urls>` plus the outside-every-manifest-pattern negative, opposite `.url` decisions on one origin failing closed in both save orders, and `testBroadGrantDoesNotEraseNarrowDenial` pinning the erase mechanism. `testLegacyRowsAreNotAppliedAsPatterns` now uses a narrow host permission (a legacy full-URL row stays inert only when the manifest does not cover it); a new companion documents that when the manifest DOES cover it the row is applied as its own exact-path pattern — narrower than the origin-wide grant a `.url` row produces. Verified `https://a.example/*`.matches(`<all_urls>`) is false, so `testStaleHostPatternRowIsNotApplied` still holds.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Profile.loadExtensionContext restores saved permission rows over the union of the manifest's up-front and optional lists (requestedPermissions ∪ optionalPermissions, requestedPermissionMatchPatterns ∪ optionalPermissionMatchPatterns), applying denials as .deniedExplicitly as well as grants, so a decision the user made at a permissions.request prompt is no longer re-prompted or dropped when a context reloads. The ungated explicit '<all_urls>' branch is folded into the pattern loop — WebKit reports that pattern verbatim as pattern.string in whichever set the manifest lists it in — which also stops a stale all-sites grant from widening access for a manifest that no longer asks for it. Grants land before denials so overlapping opposite decisions end fail closed; TASK-11's stale-row rule (a key in neither set is never applied) is unchanged. Verified with BUILD SUCCEEDED and 98 tests across the five extension suites (12 new restore tests, 3 new DB-level tests, 0 failures), plus a pre-fix control run in which 8 of the 12 new restore tests fail.
<!-- SECTION:FINAL_SUMMARY:END -->
