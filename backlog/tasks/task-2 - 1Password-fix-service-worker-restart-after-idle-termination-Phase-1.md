---
id: TASK-2
title: '1Password: fix service worker restart after idle termination (Phase 1)'
status: To Do
assignee: []
created_date: '2026-09-11 22:28'
updated_date: '2026-09-11 23:31'
labels:
  - 1password
  - extensions
  - webkit
dependencies: []
documentation:
  - docs/1password-integration-plan.md
priority: high
ordinal: 2000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The single blocker for day-to-day 1Password use. On 2026-09-11 WebKit terminated the 1Password service worker about two minutes after its last activity (15:01:14); its three native messaging ports closed and Detour SIGTERMed the BrowserSupport processes. Every restart attempt afterwards (once per minute, a fresh WebContent process logging addRegistration) hung and timed out after ~30 s with WKWebExtensionError "The background content failed to load due to an error". The worker never ran again that session. Chrome also terminates idle workers and 1Password reconnects on wake, so the goal is a working restart, not preventing termination. Root cause unknown. Ordered experiments are in the plan: (1) api-explorer classic worker idle test to separate WebKit-general from 1Password-specific; (2) offscreen document WKWebView kept alive by OffscreenDocumentHost as a lingering client of the worker scope; (3) flip ExtensionManager.useModuleBundler to bundle the module worker into a classic script; (4) call WKWebExtensionContext.loadBackgroundContent on background-load failure; (5) keep-alive while a native port is open only as a last resort. Log filter for the run is in the plan; log show must run outside the Claude Code sandbox.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 After the 1Password service worker is idle-terminated by WebKit, the next extension event starts it again and it reconnects its native messaging ports without relaunching Detour
- [ ] #2 1Password autofill still works 15 minutes after launch with no interaction in between
- [ ] #3 The api-explorer extension service worker also survives an idle termination and restart
- [ ] #4 Root cause and the chosen fix are recorded in docs/1password-integration-plan.md
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Data point from TASK-1 verification (2026-09-11, Debug build, isolated DETOUR_DATA_DIR=DetourVerify profile): TestExtensions/api-explorer classic worker fails at COLD START, not just after idle: WebKit fetches background.js and the imported _detour_polyfill.js successfully, creates the worker, then ~2 ms later logs ServiceWorkerContainer::jobFailedWithException 'Job 15 failed with error <private>' and terminates it; WKWebExtensionContextErrorDomain code=6 follows. A minimal probe extension (classic worker containing only console.* calls) loads and runs fine with the same injected polyfill, so the failure is in api-explorer's own background.js evaluation (some top-level API access throwing), not the polyfill. Experiment (1) in the plan should first get api-explorer loading at all; the exception text is <private> in the unified log, so read it via the console bridge or Web Inspector.
<!-- SECTION:NOTES:END -->
