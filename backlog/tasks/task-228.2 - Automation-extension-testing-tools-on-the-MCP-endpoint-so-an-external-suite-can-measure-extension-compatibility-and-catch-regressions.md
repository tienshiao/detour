---
id: TASK-228.2
title: >-
  Automation: extension testing tools on the MCP endpoint, so an external suite
  can measure extension compatibility and catch regressions
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14T01:26:00Z'
updated_date: '2026-11-14T09:26:00Z'
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
- [x] #1 A client can install an extension from an unpacked folder or a CRX path, list installed extensions with their state (enabled, granted permissions, load errors), enable, disable and uninstall one, and grant or revoke its permissions without a prompt
- [x] #2 A client can open and target an extension context (the action popup, the options page, the side panel where supported, and the service worker) with the same input, JS-evaluation and screenshot tools it uses for tabs
- [x] #3 A client can evaluate JavaScript in a tab or extension context and get the result or the thrown error
- [x] #4 A client can read console messages and uncaught errors (including unhandled rejections) from tabs and from each extension context, filtered by extension and by time since a marker
- [x] #5 A client can get a per-extension compatibility report: chrome.* / browser.* members accessed that are missing or stubbed (with call counts), manifest keys or permissions Detour ignores or does not support, and worker start or crash failures
- [x] #6 A client can wait, with a timeout, for a tab or context to finish loading, for a selector to match, and for an extension's worker to start
- [x] #7 The install and permission-grant tools are refused unless the endpoint runs in the isolated DETOUR_DATA_DIR test-run mode (until the user decides on Release exposure), and Private windows and the Private profile stay unreachable
- [x] #8 Tests cover each tool's happy path and its errors (an unknown extension or context, a context that is not open, an invalid CRX or manifest, a timeout), and the gate refusals
- [x] #9 The wiki testing-extensions playbook shows an end-to-end run against fixture extensions from TestExtensions/: install, drive a popup and a content script, read the console, and fetch the compatibility report
- [x] #10 Extensions are addressed by a stable identifier that survives relaunch and reinstall (extension ID, with lookup by manifest name), and extension contexts by kind plus extension (for example popup of X, worker of X), so a scenario written earlier still resolves. Run-specific tab and window IDs are never required to reach an extension context
- [x] #11 The compatibility report and the console and error results are structured and stable in ordering, so a script can diff them against a saved baseline (no timestamps or run-specific IDs in the comparable fields)
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

2026-11-14, part 1 (ACs #1-4, #6, #7, #10, and #8 for these tools), commits 8b73747 (code + tests), 06106cf (wiki):
- Tools: list_extensions, install_extension (folder; CRX through CRXInstallGate.admit with a file URL, never updates, may replace an installed id), uninstall_extension, set_extension_enabled (profile or global), set_extension_permission (api / match_pattern / url, with warnings for inert host rows, undeclared API permissions, nativeMessaging), open_extension_context (popup / options / worker; sidepanel unsupported_context), close_extension_context, call_extension_api, read_extension_global. The four management tools answer gate_closed unless AutomationEnvironment.isTestRun (set from AutomationGate.Mode.testRun by the controller).
- Addressing: AutomationContextID gained .extension(kind, ref): popup|options|worker|sidepanel|extension:<id or exact manifest name>[@<profile uuid>]. A keyless unpacked folder installed again keeps its id (forcedID, as Reload). New codes: unknown_extension, ambiguous_extension, ambiguous_profile, unknown_profile, extension_disabled, context_not_open, unsupported_context, worker_not_running, install_failed.
- Page/input tools take popup:/options: (resolvePageTarget); console_messages takes worker:/popup:/options:/extension:; wait_for gained worker_started.
- Worker channel (decision): a parked native-message request, not a port (ports change WebKit's unload timing and TASK-141's port bookkeeping), not runtime.onMessage (the extension's listeners would see it), not a hidden relay page (cannot read worker globals), never a Proxy. Polyfill module (last in the bundle, background only) parks automation.awaitCommand, acks each command (automation.ack), re-parks, sends automation.result; dead parks found by a missing ack (1.5 s) -> loadBackgroundContent and redelivery (max 3). First version piggybacked the result on the next park: a never-settling call blocked every later one (caught by the integration test), so results now travel separately and commands run side by side. A worker started while automation was off was told stop and parks only at its next start (documented; worker_not_running message says so). Channel requests do not count as background activity (TASK-123).
- Console: the bridge now sends consoleLevel, origin, stack, sourceURL, line, column; AutomationExtensionConsole keeps them per extension+profile with context_kind (worker/popup/options/page), before the native cap; the bridge's in-page limiter still applies.
- ExtensionErrorLog records WKWebExtension load failures (launch and install), context load refusals and context errors per extension, for list_extensions.
- Tests: AutomationExtensionTests 9/0 (real installs through the endpoint into a test profile: gate, install/list/address, bad folder/manifest/CRX/profile, worker calls/reads/console/timeouts, closed channel, popup driven with the page and input tools, options, page refused the channel, enable/permissions/uninstall, side panel, two profiles) and AutomationExtensionChannelTests 10/0; ExtensionPolyfillTests.testConsoleBridgeSendsTheAutomationDetail; MCPServerTests (codes, context ids). Ran all Automation* suites, MCPServerTests, ExtensionPolyfillTests, ExtensionPolyfillIntegrationTests, ExtensionPolyfillProfileWiringTests, ExtensionManagementSelfTests, ExtensionNotificationEventDeliveryTests, ExtensionUpdateDeferralTests, ExtensionOptionsPageEntryTests, ExtensionPopoverSizingTests: all pass (372/0 and 98/0 runs). AutomationInputTests' popup:abcdef now expects unknown_extension. Test trap: a profile whose controller hosted a popup must be kept alive (WKProcessPool dealloc trap), as other suites do.
- Runtime (Debug build, DETOUR_DATA_DIR=DetourVerify2282/2282b, DETOUR_MCP=1, Detour in the background, fixture on 127.0.0.1:8792): installed hello-world and api-explorer (unpacked) through the endpoint, listed them, wait_for worker_started, storage set/get and chrome.runtime.id in the worker, opened both popups (evaluate_js, read_page elements, click #btn-query-all / #btn-active-tab showed the fixture tab, type_text, screenshots looked right), popup and worker console read (levels, uncaught + unhandledrejection with line/column), options opened in the background and in window 1 (read_page, call_extension_api), permission grant/deny, disable/enable per profile and globally, uninstall. Worker idle-unloaded after 70 s then called: answered in about 1.7 s, its console showed the restart. 1password.crx installed (crx, id aeblfdkhhhdcdjpifhhbdiojplfjncoa, no manifest/load errors), worker_started, then uninstalled. On the first run its worker connected to the installed 1Password app's browser helper, which refused the Debug build and exited (status 1); the second run used an empty DETOUR_NATIVE_MESSAGING_HOSTS_DIR and connected nowhere. Cleaned up both runs (SIGTERM by pid, WebKit stores from browser.db, data dirs, prefs domains/plists, window/split keys).
- Findings: hello-world's content script never injects in Detour (content-script matches are not requested patterns; set_extension_permission <all_urls> is saved but inert and says so) - relevant to part 2's playbook (drive a content script with API Explorer, which has host_permissions). Not checked at runtime: gate_closed in a user-enabled endpoint (tests), the Private refusals (tests), turning the endpoint on mid-session with running workers (documented limit).
- Not run: /code-review (the lead's). The verify skill (.claude/skills, not writable from the sandbox) does not list the extension tools yet; runtime-verification.md does.

Full suite after 8b73747: 4178 tests, 19 skipped, 0 failures (TEST SUCCEEDED).

2026-11-14, /code-review high --fix on 64b6466..358e41f: 9 findings, 7 fixed in the commit after 358e41f. Fixed:
- A pinned options page now closes.
- Popups the endpoint opened close whenever their context unloads.
- Private-profile load errors are left out.
- Launch read failures set loadFailed.
- A Settings uninstall forgets the console records.
- The channel's time-limit task is cancelled.
- One permission-decisions helper.
Not closable: an extension's own pages can send automation.awaitCommand, because WebKit does not say which page sent a native message, so they could disturb that extension's own commands. Only the comment was corrected. Kept as documented: wait_for worker_started answers timeout for a closed channel.
The review's own pass found that, with automation off, worker lifetime and keep-alive are unchanged: a native request is not WebKit activity, and automation.* skips noteBackgroundActivity.
After the fixes: AutomationExtension, Channel, ExtensionProfileScope, PageRehost, PolyfillProfileWiring and Updater tests passed, 140/0 with 13 skipped.
Owed: a signed-build 1Password check, since the polyfill now parks one automation request at every worker start.

2026-11-14, part 2 (ACs #5, #8, #9, #11), commits 2b3c1c2 (code + tests), a235411 (wiki, playbook, harness script), and the polyfill-layer note with these notes:
- extension_compat_report {extension, profile_id?, probe?, timeout_ms?}: (1) static scan of the installed copy's .js/.mjs (bounded, path order, Detour's _detour_* files and _metadata left out) for chrome.X.Y / browser.X.Y (also ?., ['x'], globalThis./window./self.), Chrome's published namespaces only; file roles (background / content_script / page / other) from the manifest and pages, followed through importScripts and import/export; each api checked in the worker (the channel's new 'probe' op: present, typeof, [native code]) and in a hidden probe page _detour_probe.html written into the installed copy and loaded from context.webViewConfiguration (polyfill runs, no extension script does; its console and stub calls are not recorded): available / missing / stubbed / not_checked. (2) ExtensionPolyfillStubs: one registry of the polyfill's stand-ins (privacy.*, webRequest events + handlerBehaviorChanged, action.getUserSettings, storage.managed, sessions.getRecentlyClosed/getDevices/onChanged, idle.onStateChanged, notifications.onButtonClicked, history events + getVisits + no-op writers, management events); a polyfill module after the stub modules wraps the polyfill's own functions (never native ones), and sends one automation.stubCalls batch per task; the handler keeps registry paths only, per extension/profile/path/context kind (AutomationExtensionStubCalls), and answers stop when automation is off or in the Private profile (the context then stops sending). (3) TypeErrors/ReferenceErrors in the recorded console naming chrome.*/browser.* (JSC wording). (4) Manifest keys against WebKit's parser (WebExtension.cpp on main, read 2026-11-14) and Detour's own (commands unsupported: Detour never calls performCommand(for:)); API permissions via WebKit's live requestedPermissions/optionalPermissions + the polyfill's list (privacy, webRequest stubbed); refused host patterns; WKWebExtension.errors. (5) Worker: started / start_error, failed_to_load, recovery_attempted (new ExtensionErrorLog.recordRecovery from Profile.recoverFromBackgroundLoadFailure), load errors.
- AC #11: everything outside run is sorted and run-independent (no profile ids, timestamps, absolute paths; webkit-extension://<extension id>); run holds profile_id and timing-dependent counts. list_extensions and console_messages take stable: true. Decision: the extension console (and stub counts) now start in the same main-actor turn as the channel opens, before the listener is ready, so a worker's start-up errors are kept.
- Tests: AutomationCompatReportTests 11/0 (pure parts + a real extension: references in worker and probe page, stubs called from the worker (native-message transport) and popup (message-handler transport), caught and uncaught TypeErrors, manifest findings, two reports equal outside run, probe false, unknown/turned-off extension, closed channel, the counts handler taking registry paths only and answering stop, stable list/console); ExtensionPolyfillTests +3 (counting and batching until stop, native functions left alone, runner probe). Part 1's tests already cover invalid CRX/manifest, unknown extension/context, context_not_open, timeouts and the gate (AC #8). Affected suites (AutomationExtension, Channel, Controller, Page, Tools, MCPServer, CompatReport, ExtensionPolyfill, Integration, ProfileWiring): 379 tests, 13 skipped, 0 failures. Full suite: 4192 tests, 19 skipped, 2 failures (ExtensionOriginTrackingPreventionTests.testTrackingPreventionPassSparesOriginsWithALoggedInteraction, SameDocumentVisitTests.testInPageNavigationsDuringALongLoadAreAllRecorded, both timeouts at load average 100-150); both suites re-run alone: 25/0.
- Runtime (AC #9): docs/harness/task2282-compat-run.py on the Debug build of 2b3c1c2, Detour in the background, empty DETOUR_NATIVE_MESSAGING_HOSTS_DIR: installed api-explorer, hello-world and vimium, workers started; popup's chrome.tabs.query saw the fixture tab; chrome.tabs.sendMessage from the popup reached API Explorer's content script (page outlined, reply {highlighted: true}); a real click on Query All Tabs; consoles, stable lists and reports read. Run twice, the second with --baseline: no differences. Reports: API Explorer missing bookmarks.getTree and tabs.move, stubs referenced action.getUserSettings, idle.onStateChanged (called), privacy.services, storage.managed, commands and bookmarks unsupported; Vimium missing bookmarks.getTree, runtime.getBrowserInfo, tabs.move. Cleanup checked (no data dirs, prefs domains/plists or window keys left).
- Findings: (a) a keyless unpacked extension gets a new random id in every new data directory, so baselines across runs name it by folder (the script does) or fixtures need a manifest key. (b) WebKit's autosized action popup does not scroll from script (scrollIntoView/scrollTo/scrollTop leave scrollY 0; API Explorer is 3617 points tall in a 600-point popover), so the input tools answer element_not_visible below 600 points; whether a person's wheel scrolls it was not checked; possibly worth a task. (c) No real fixture produced an API-naming runtime error; the integration test covers that part.
- Not done: /code-review (the lead's); the verify skill (not writable from the sandbox) does not list extension_compat_report; signed-build 1Password check owed (the polyfill now also runs the counting module in every extension context; with automation off a context that calls a stub sends one automation.stubCalls request, answered stop).

2026-11-14, /code-review high --fix on 9f3ca35..72f94ab (part 2): 10 findings, 9 fixed in 438188c.
- The stub-counting module sends no second batch while one waits for its reply, and a stop clears its counts: automation-off costs one stopped request at most.
- Wrapped stubs keep length and name.
- The probe page's load timer is cancelled.
- References are probed under every global used, and a stub object's nativeness is read from its first counted function.
- worker_started is false only when the worker did not start.
- Only warn/error records or named TypeErrors and ReferenceErrors count as runtime errors.
- Regexes are compiled once, with one origin-naming helper.
- A registry test checks every counted path.
Skipped: running the worker and page probes concurrently (needs a restructure); the 300 ms wait for stub batches (a heuristic).
Lead's check after the fixes: CompatReport, ExtensionPolyfill, AutomationExtension, Channel, PolyfillIntegration and MCPServer passed (488 tests, 0 failures). docs/harness/task2282-compat-run.py --vimium ran on a fresh Debug build, twice, the second with --baseline on the first. ALL PASSED, no differences, Detour in the background. Reports: API Explorer is missing bookmarks.getTree and tabs.move in the worker; stubbed: action.getUserSettings, idle.onStateChanged (called), privacy.services, storage.managed; commands key and bookmarks permission unsupported. Vimium is also missing runtime.getBrowserInfo, with stubbed history events. hello-world is clean.
The wiki records the batching and the both-globals probing.
Owed: a signed-build 1Password check, since every extension context now loads the channel and counting modules.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Extension testing tools on the MCP endpoint:
- Install an unpacked folder or a CRX, list, enable or disable, uninstall, and grant or revoke permissions without a prompt. Install, enable and permission tools are test runs only.
- popup:, options: and worker: contexts, addressed by id or manifest name, with an optional @profile. evaluate_js, read_page, input and screenshot work in the popup and options page.
- The worker gets call_extension_api and read_extension_global through a polyfill-parked native-message channel. MV3's CSP forbids eval there, and the channel is checked against the verified background context.
- Extension console with uncaught errors and rejections, and wait_for worker_started.
- extension_compat_report: a static chrome.*/browser.* scan checked live in the worker and in a probe page, the stub registry with call counts, API-naming errors, unsupported manifest keys and permissions, and worker failures. Results are stable and sorted for baseline diffs, with stable: true on list and console.
- Playbook in wiki/playbooks/extension-compat-run.md and docs/harness/task2282-compat-run.py.
Two reviews; 488 affected tests pass. The full suite (4192) had 2 load-induced timeouts in unrelated suites that pass alone.
Known limits:
- An extension's own pages can disturb its own channel commands.
- A worker started while automation was off is reachable only after its next start.
- Script cannot scroll the action popup.
- Content scripts' surface is not probed.
Owed: a signed-build 1Password check.
<!-- SECTION:FINAL_SUMMARY:END -->
