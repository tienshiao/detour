---
id: TASK-132.4
title: >-
  Extensions: the Claude extension installs and its worker start-up completes
  (declarativeNetRequest session header rule)
status: To Do
assignee: []
created_date: '2026-10-03 23:07'
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
- [ ] #2 declarativeNetRequest.updateSessionRules with the extension's modifyHeaders rule resolves
- [ ] #3 A request from an extension context to the API host carries the three headers, or a documented fallback sets them, verified against a local fixture server
- [ ] #4 docs/extensions.md states what declarativeNetRequest support Detour has
- [ ] #5 API Explorer and tests cover session rules with modifyHeaders, including an extension without the permission
<!-- AC:END -->
