---
id: TASK-228.2
title: >-
  Automation: extension testing tools on the MCP endpoint, so an external suite
  can measure extension compatibility and catch regressions
status: To Do
assignee: []
created_date: '2026-11-14T01:26:00Z'
labels:
  - tooling
  - automation
  - extensions
dependencies:
  - TASK-228.1
references:
  - TASK-228.1
  - wiki/extensions/testing-extensions.md
  - wiki/playbooks/seeding-extensions.md
  - wiki/extensions/polyfill-layer.md
  - TASK-132
parent_task_id: TASK-228
priority: medium
type: feature
ordinal: 393000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested 2026-11-14. The user plans a separate test repo holding many third-party extensions, with scenarios for each. It will drive Detour through the MCP endpoint from TASK-228.1 to raise extension compatibility step by step and catch regressions. 228.1 is scoped to testing Detour's own UI (windows, tabs, menus, screenshots). It cannot install extensions or reach their contexts, and it gives no signal for what an extension tried and failed to use.

Why each piece matters to that suite:
- Seeding by hand does not scale. A hand-seeded extension needs extensionPermission rows or its worker never loads (wiki/playbooks/seeding-extensions.md).
- Much of an extension's behaviour lives outside tabs: the action popup, the options page, the side panel (TASK-132) and the service worker. 228.1 addresses input to "an element of a tab".
- Running JS and reading the console are in TASK-228 AC #2 but not in 228.1. The suite needs them for assertions and for collecting failures.
- A compatibility score needs a signal that no hand-written assertion gives: chrome.* calls that reach a missing or stubbed API, manifest keys Detour ignores, and worker start failures. The polyfill layer sees these calls.
- Running hundreds of extensions in a row is flaky without wait primitives.

Same gate as 228.1: reachable only with the endpoint turned on, and the test-run switch only with an isolated DETOUR_DATA_DIR. Whether the install and permission-grant tools ever appear in a Release build is a product decision for the user (they bypass the user's consent prompt). Until the user decides, they are limited to the isolated test-run mode.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A client can install an extension from an unpacked folder or a CRX path, list installed extensions with their state (enabled, granted permissions, load errors), enable, disable and uninstall one, and grant or revoke its permissions without a prompt
- [ ] #2 A client can open and target an extension context (the action popup, the options page, the side panel where supported, and the service worker) with the same input, JS-evaluation and screenshot tools it uses for tabs
- [ ] #3 A client can evaluate JavaScript in a tab or extension context and get the result or the thrown error
- [ ] #4 A client can read console messages and uncaught errors (including unhandled rejections) from tabs and from each extension context, filtered by extension and by time since a marker
- [ ] #5 A client can get a per-extension compatibility report: chrome.* / browser.* members accessed that are missing or stubbed (with call counts), manifest keys or permissions Detour ignores or does not support, and worker start or crash failures
- [ ] #6 A client can wait, with a timeout, for a tab or context to finish loading, for a selector to match, and for an extension's worker to start
- [ ] #7 The install and permission-grant tools are refused unless the endpoint runs in the isolated DETOUR_DATA_DIR test-run mode (until the user decides on Release exposure), and Private windows and the Private profile stay unreachable
- [ ] #8 Tests cover each tool's happy path and its errors (an unknown extension or context, a context that is not open, an invalid CRX or manifest, a timeout), and the gate refusals
- [ ] #9 The wiki testing-extensions playbook shows an end-to-end run against fixture extensions from TestExtensions/: install, drive a popup and a content script, read the console, and fetch the compatibility report
<!-- AC:END -->
