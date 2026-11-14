---
id: TASK-228.2
title: >-
  Automation: extension testing tools on the MCP endpoint, so an external suite
  can measure extension compatibility and catch regressions
status: To Do
assignee: []
created_date: '2026-11-14T01:26:00Z'
updated_date: '2026-11-14T06:41:00Z'
labels:
  - tooling
  - automation
  - extensions
dependencies:
  - TASK-228.1
  - TASK-228.4
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
- [ ] #10 Extensions are addressed by a stable identifier that survives relaunch and reinstall (extension ID, with lookup by manifest name), and extension contexts by kind plus extension (for example popup of X, worker of X), so a scenario written earlier still resolves. Run-specific tab and window IDs are never required to reach an extension context
- [ ] #11 The compatibility report and the console and error results are structured and stable in ordering, so a script can diff them against a saved baseline (no timestamps or run-specific IDs in the comparable fields)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Plan (lead, 2026-11-13), from a survey of Detour/Extensions on main:

Part 1: management, contexts, evaluation, console, waits (ACs #1-4, #6, #7, #10).
- Addressing: the 'extension' argument takes an extension id or an exact, case-insensitive manifest name (two matches give an ambiguity error). Contexts are popup:<ext>, options:<ext>, worker:<ext> and sidepanel:<ext>. sidepanel answers a clear 'not supported on this build' code: main has no side panel, only epic-claude-extension does. Contexts exist per profile. An optional profile_id argument picks one; the default is the only non-Private profile the extension is on in, else an ambiguity error. The Private profile is never reachable.
- install_extension {path: unpacked folder or .crx, profile_id?}. A folder goes to ExtensionManager.shared.install with source .unpacked. A CRX goes through CRXInstallGate.admit(crxData:downloadURL: fileURL, installed:) first, then install with its publicKey. It waits, with a timeout, for the context to load or fail, and returns id, name, version and errors.
- set_extension_enabled (global or per profile; the Private profile refused), uninstall_extension, set_extension_permission {permission: API name, match pattern or URL; granted}. These go through ExtensionManager.setPermissionDecision, with its inert-host-row caveat surfaced as a warning.
- list_extensions: state, per-profile enablement, granted and denied permission rows, and load errors. Record WKWebExtension.errors and the context errorsDidUpdate per extension; today they are only logged.
- The gate: install, uninstall, set_extension_enabled and set_extension_permission are refused (gate_closed) unless AutomationGate is in test-run mode. Listing, contexts, evaluation and console work whenever the endpoint is on.
- open_extension_context {extension, kind: popup|options, window_id}. Popup: ExtensionPopoverController's show path in that window (it must work with Detour in the background). popupWebView comes from context.action(for: tab). Options: openOptionsPage, a tab. close_extension_context.
- Evaluation: popup, options and extension pages use evaluate_js through callAsyncJavaScript (not bound by the page's CSP). The worker cannot run arbitrary JS: MV3's CSP forbids eval and new Function there, and WebKit exposes no worker evaluation. So worker:<ext> gets call_extension_api {path: 'chrome.storage.local.get', args JSON} and a global read through a Detour-private native-to-worker channel in the polyfill. Choose the channel and record why. Candidates: the parked request channel (ExtensionNotificationManager), or a hidden extension page relaying. Never a runtime.onMessage listener the extension's own listeners would also see. Never a Proxy on chrome/browser (wiki/decisions/never-replace-chrome-globals.md).
- Console: the polyfill's consoleJS already sends 'log' with the verified extension id (ExtensionPolyfillHandler 'log'). Add the sender's context kind and URL, uncaught errors and rejections, and feed the automation console buffer under that context while the endpoint is on. The output follows TASK-228.4's console_messages shape (seq cursor).
- wait_for gains worker_started (worker:<ext>) and works for popup and options contexts.

Part 2: compatibility report, determinism, playbook (ACs #5, #8, #9, #11).
- extension_compat_report {extension}. A Proxy is forbidden, so 'missing or stubbed members accessed' is built without one:
  (1) A static scan of the extension's JS for chrome.X.Y and browser.X.Y references, compared with what a live extension page of that extension has (typeof per member).
  (2) Polyfill stubs (privacy, webRequest listeners, sessions, storage.managed, action.getUserSettings, and the TASK-146 never-firing events) count their calls while automation is on.
  (3) TypeErrors in captured errors that name chrome.* or browser.* members.
  (4) Manifest keys and permissions Detour does not support, plus WKWebExtension.errors.
  (5) Worker start failures (backgroundContentFailedToLoad, recovery attempts).
  Sorted, with no timestamps or run IDs in the compared fields.
- The wiki testing-extensions playbook gets an end-to-end run against TestExtensions/api-explorer and hello-world: install, drive a popup and a content script, read the console, fetch the report.
- Tests: each tool's happy path and errors, the gate refusals, an invalid CRX and manifest, an unknown extension or context, a context that is not open, a timeout.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-14: the intended workflow is agent-authored scenarios replayed by a script runner in the external test repo, with an agent looking only at failures. Hence ACs #10 and #11: stable addressing and diffable reports. Structured output, error codes and the scripting client come from TASK-228.1 (ACs #12, #13).
<!-- SECTION:NOTES:END -->
