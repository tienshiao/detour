---
id: TASK-22
title: >-
  Extensions: verify runtime.onInstalled is delivered in the app, or emit it
  ourselves
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-12 19:07'
labels:
  - extensions
  - webkit
  - 1password
dependencies: []
priority: medium
ordinal: 22000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-20 (commit 985a445) measured that WebKit never delivers runtime.onInstalled to a background service worker in a context loaded programmatically in the test process: the worker answers every other message, its own in-worker record of the event never appears, and a storage marker written by the listener never lands while a marker written by a plain handler in the same run does. Setting context.uniqueIdentifier and a controller delegate changed nothing. The test testRuntimeOnInstalledIsNotDelivered pins the measurement. Unknown whether the app is affected: if WebKit also withholds it on a real install/update/launch, every extension that does first-run setup in onInstalled (1Password included; the polyfill also has an onInstalled emitter) never runs it. Determine what the app sees on a real install and on a context reload, with the API Explorer worker recording onInstalled details (reason, previousVersion) into storage; if WebKit does not fire it, decide whether Detour should synthesise it (Chrome semantics: install, update with previousVersion, chrome_update never) from ExtensionManager.install and record the decision in docs/1password-integration-plan.md.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 docs/1password-integration-plan.md records whether onInstalled fires in the app on install, on update and on a background-recovery reload, with the log or storage evidence
- [ ] #2 If WebKit does not fire it, Detour emits it with Chrome reason/previousVersion semantics exactly once per install or update and never on a plain reload, covered by tests
- [ ] #3 If WebKit does fire it, testRuntimeOnInstalledIsNotDelivered is rewritten to explain why the harness differs, or flipped
<!-- AC:END -->
