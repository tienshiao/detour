---
id: TASK-132.4
title: >-
  Extensions: the Claude extension installs and its worker start-up completes
  (declarativeNetRequest session header rule)
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 23:07'
updated_date: '2026-10-04 03:08'
labels: []
dependencies: []
parent_task_id: TASK-132
priority: high
ordinal: 136000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
First gate: install the Web Store CRX and get through runtime.onInstalled / onStartup without a throw. onInstalled awaits declarativeNetRequest.updateSessionRules with a modifyHeaders rule (User-Agent, anthropic-client-platform, anthropic-client-version on requests to https://api.anthropic.com/*, resource types xmlhttprequest and other) with no try/catch, so a rejection skips the rest of start-up. docs/extensions.md lists declarativeNetRequest as unsupported while WebKit main implements updateSessionRules and modifyHeaders; whether the rule applies to requests made by the extension's own worker and pages is unknown. Also record every other missing API or constant the worker hits at start-up (runtime.OnInstalledReason, runtime.ContextType, tabGroups.Color and so on).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The extension installs from the Chrome Web Store with a permission prompt that names its permissions, and its service worker reaches the end of onInstalled with no uncaught error in the Extensions log
- [x] #2 declarativeNetRequest.updateSessionRules with the extension's modifyHeaders rule resolves
- [x] #3 A request from an extension context to the API host carries the three headers, or a documented fallback sets them, verified against a local fixture server
- [x] #4 docs/extensions.md states what declarativeNetRequest support Detour has
- [x] #5 API Explorer and tests cover session rules with modifyHeaders, including an extension without the permission
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Run the unmodified Claude extension in an isolated profile and record what its worker hits at load, onInstalled and onStartup.
2. Make declarativeNetRequest.updateSessionRules with a modifyHeaders rule resolve and take effect for the extension's own requests (WebKit first, a Detour-held fallback for what WebKit refuses or does not apply).
3. Add the constants the start-up path needs (runtime.OnInstalledReason, the declarativeNetRequest enums) and interim chrome.tabGroups / chrome.debugger stand-ins so the worker loads before TASK-132.12 / 132.13.
4. Tests, API Explorer section, docs; /code-review --fix; runtime check including the API Explorer popup; affected suites.
5. Still open: the Web Store install and permission prompt driven through the UI (acceptance criterion 1).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-03. Start-up record, unmodified Claude 1.0.98 before this task: module evaluation threw at assets/mcpPermissions-7tN0KmUi.js:2:134113 (static SESSION_GROUP_COLORS = [chrome.tabGroups.Color.BLUE, ...]), then at 2:182515 (chrome.debugger.onEvent.addListener); with those two stood in, onInstalled and onStartup threw in Ki at assets/service-worker.ts-V-8fXAa7.js:1:57044 (chrome.declarativeNetRequest.RuleActionType.MODIFY_HEADERS undefined), then at 1:57617 (WebKit: 'The header anthropic-client-platform is not recognized'), and runtime.OnInstalledReason was undefined. Not hit at start-up: sidePanel (feature-tested), identity, downloads, getContexts, ContextType.

What is true of declarativeNetRequest in Detour (each pinned by a test): the permission is granted and the namespace exists in worker and page (undefined without it); WebKit vends no enums; WebKit accepts modifyHeaders only for header names on its own list; an accepted rule changes requests from tab pages and extension pages but not the service worker's fetch; a block session rule works on tab pages (the docs' 'Not supported' was wrong).

Implemented: ExtensionHeaderRules.swift (pure rule parsing and matching); declarativeNetRequestJS (enums, updateSessionRules / getSessionRules wrapped in place on the rooted wrapper, fetch and XMLHttpRequest wrapped only when the namespace exists); handler messages declarativeNetRequest.updateHeaderRules / getHeaderRules / headerChanges with the permission gate and a host-access gate, per-extension in-memory store forgotten on unload; runtime.OnInstalledReason; interimNamespacesJS (chrome.tabGroups constants only, chrome.debugger onEvent/onDetach emitters that never fire, each only with its manifest permission, every method absent; replaced by TASK-132.12 / 132.13); permission descriptions for sidePanel, debugger, tabGroups, downloads, identity; API Explorer section; docs. WebKit gets every call first; Detour keeps only the header rules WebKit refuses and applies them to the extension's own requests.
Limits (in docs/extensions.md): a Detour-held rule does not reach tab pages; fetch-forbidden headers are not set in the worker; XHR can only add headers and send() is deferred; session rules only; every http(s) fetch from an extension holding the permission costs one native round trip (a keepalive fetch from a closing page may not be sent — reasoned, not measured); added headers ride redirects.

/code-review medium --fix: no high-severity findings; four low ones fixed (remove + re-add of a Detour-held rule now one bridge message; WebKit's XHR open() runs first; XHR misuse while a send waits throws InvalidStateError synchronously, new test; relative URLs resolve against document.baseURI); two left as documented limits (keepalive, redirects).

Runtime check on the post-review build: API Explorer popup, real in-process clicks — Probe, Fetch with no rule, Add Header Rule (heldByWebKit false), Get Session Rules, Fetch (worker fetch, popup fetch and popup XHR all carry the rule's User-Agent and x-api-explorer; fixture server saw the same), Add with WebKit-only names (heldByWebKit true), Remove (callback form), Fetch back to plain, interim Probe (both 'interim', nine colours, -1, no methods). The real unmodified Claude extension, fresh profile, nativeMessaging denied, no sign-in: worker loads, 'dispatching install to 1 listener(s)', two 'session header rules — kept 1' lines, 0 uncaught exceptions or unhandled rejections in 75 s. Claude-shaped rule against the in-process loopback server: worker fetch, page fetch, page XHR, a Request object and a POST all carried the three headers, no OPTIONS preflight.
Tests: 495 across the affected suites, 0 failures, 4 skipped (env-gated measurement legs), .claude/scratch/task132.4/90-final-suites.log.

Incidents and side findings: in one early run the extension connected to the user's real Claude Code native host for about 30 s (four small messages); every later run denied nativeMessaging. On install the extension opens https://claude.ai/login?... (redirect_uri chrome-extension://<id>/oauth_callback.html) by itself. Filed separately: TASK-134 (install event lost when the first load fails), TASK-150 (popup taller than the popover cannot scroll; found while exercising the API Explorer popup, fixed in its own commit).

Not verified: the Web Store CRX download and permission prompt in the UI (criterion 1's first half; the install was seeded the way ExtensionManager.install records it, and tests cover the id derivation and the prompt text for all 16 permissions); any Claude handler beyond start-up; the Private profile; updateDynamicRules; a signed build.
<!-- SECTION:NOTES:END -->
