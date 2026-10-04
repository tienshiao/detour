---
id: TASK-132.6
title: >-
  Extensions: externally_connectable pages get chrome.runtime, so claude.ai can
  finish the Claude extension's sign-in
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 23:07'
updated_date: '2026-10-04 07:58'
labels: []
dependencies: []
parent_task_id: TASK-132
priority: high
ordinal: 138000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Sign-in opens https://claude.ai/oauth/authorize in a tab; claude.ai then calls chrome.runtime.sendMessage(<extension id>, {type: 'oauth_redirect', redirect_uri}) which the worker receives on runtime.onMessageExternal. WebKit installs only a `browser` global on web pages (WebExtensionControllerProxy::addBindingsToWebPageFrameIfNecessary), so chrome.runtime is undefined there and sign-in cannot finish. Provide chrome.runtime (sendMessage, connect) on pages matched by an enabled extension's externally_connectable.matches, backed by WebKit's web-page runtime. Contexts already use the Chrome id as uniqueIdentifier (Profile.swift).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 On a page matching externally_connectable, chrome.runtime.sendMessage(extensionId, msg) reaches runtime.onMessageExternal with the right sender origin and tab, and the reply comes back
- [x] #2 A page that matches no enabled extension's externally_connectable gets no chrome.runtime from Detour
- [x] #3 A message to an id that is not installed, or to an extension not enabled in that profile, fails the way Chrome's does (lastError / rejection), never delivered to another extension
- [x] #4 The page's own window.chrome, if it defines one, is not clobbered
- [ ] #5 Signing in to the Claude extension completes in the app
- [x] #6 Tests cover the positive and negative cases; API Explorer has an externally_connectable check
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Measure what WebKit puts on web pages and how it decides delivery; read claude.ai's public page scripts for how the page calls the extension.
2. Page-world user script, installed per profile only when a loaded extension lists pages: on a document matching a listed pattern define chrome.runtime (sendMessage, connect, lastError); forward listed ids to WebKit's browser.runtime captured at document start; answer every other id locally with Chrome's error.
3. Keep open tabs current when an extension loads, unloads, is enabled or disabled.
4. Tests (real contexts and the shim alone), API Explorer check, docs; /code-review --fix; runtime check; affected suites.
5. Open: an actual sign-in, which needs the user's account.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-04. Measured on macOS 26.7: WebKit puts browser.runtime (sendMessage, connect; no id, no lastError, no chrome) on EVERY web page; delivery is decided per message in the UI process (context loaded in that profile's controller, frame URL matches externally_connectable, extension has host access). The worker's sender has documentId, frameId, origin, tab, url and no id. A refused message (unknown id, not listed, unloaded, other profile, no host access) and an unanswered one both resolve undefined with no error after 0.1–0.5 s. Loopback http origins are accepted as patterns; <all_urls> and public-suffix patterns are dropped.

How claude.ai calls the extension (public login-page bundle, read without signing in): it reads the global chrome, calls chrome.runtime.sendMessage(id, {type: 'oauth_redirect', redirect_uri}, callback) and checks chrome.runtime.lastError; it tries an internal id (dngcpimnedloihjnnfngkgjoidhnaolf) before the public one and treats any reply other than {success: false} as signed in, undefined included. So WebKit's silent undefined for the uninstalled internal id would end the loop before the real extension is asked: Chrome's 'Receiving end does not exist' error for unreachable ids is required for sign-in.

Implemented: Detour/Extensions/Runtime/ExternallyConnectable.swift (pattern table, the shim JS, ExternallyConnectablePages), installed by Space.makeWebViewConfiguration, hooks in Profile.loadExtensionContext / unloadExtension, web views tracked at the BrowserTab seams. Exposure is scoped by Detour's table of loaded contexts (browser is on every page, so its presence scopes nothing); delivery stays WebKit's decision. An existing window.chrome is extended, an existing chrome.runtime is left alone. Open tabs are kept current by replacing the script on live content controllers and a DOM event for open documents.

/code-review medium --fix, treating the shim as hostile-page-facing: three findings fixed — the live update matched ids against webView.url (the pending URL during a provisional navigation), so the old page could receive ids listing the new one; it now checks location.href first. sendMessage with a trailing undefined threw; fixed. Comments and docs said the shim gives a page no ids; a listed page listening for the update event does see the ids that list it; wording corrected.
Found after the review and fixed with a guard test (testOtherExtensionsContentScriptsSurviveTheScriptReplacement, red with 11 failures, then green): removeAllUserScripts() leaves WebKit's extension content scripts in place, and they are in userScripts, so re-adding the whole snapshot duplicated them on every replacement (8 -> 22 scripts after three). The replacement now puts back only the scripts the call actually removed. That last change was not itself code-reviewed.

Runtime, post-review build: API Explorer external page and popup section by real in-process clicks (sender origin, url, frameId, tabId; unknown id fails as in Chrome; Show Received / Clear); enable/disable through ExtensionManager.setEnabled with a listed page open (open page gets Chrome's error while disabled and works again after, a page loaded while disabled has no chrome until reloaded, another extension's content scripts kept running once per document throughout); the real Claude extension on the login tab it opens itself: ping -> {success: true, exists: true} in promise and callback form, unknown id -> Chrome's error; on the pre-review build claude.ai's own loop replayed with a bogus state: internal id rejected, then the real worker answered {success: false, error: 'No sign-in in progress', notStartedHere: true}. nativeMessaging denied and the shadow hosts directory set in every run; no sign-in.
Tests: ExtensionExternallyConnectableTests 18, ExternallyConnectableShimTests 23; 748 tests across the affected suites, 7 skipped (env-gated), 0 failures (.claude/scratch/task132.6/50-final-suites.log).

Limits: a document created before the extension's context loads has no chrome.runtime until reloaded (including a tab restored at launch that wins the race); matching happens once per document; window.chrome now exists on listed pages; an extension that lists a page without host access gets nothing (WebKit); a listed extension with no listener answers undefined where Chrome errors.
Not verified: an actual sign-in (criterion 5) — the token exchange, the tabs.update on the sender's tab and the signed-in state; the Settings switch itself (its model call was used); IDN hosts.
<!-- SECTION:NOTES:END -->
