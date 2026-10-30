---
type: Playbook
title: Testing extensions
description: Which kind of extension test proves what — pure rules, the polyfill in a bare web view, a real WebKit extension context, the production Profile wiring, a runtime check with API Explorer, and the signed build — with the fixtures and the traps.
tags: [extensions, testing, playbook, fixtures]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T02:15:18Z }
sources:
  - id: claude-md
    resource: ../../CLAUDE.md
    title: CLAUDE.md (Testing, Reminders)
  - id: support
    resource: ../../DetourTests/ExtensionTestSupport.swift
    title: ExtensionTestSupport.swift
  - id: unit
    resource: ../../DetourTests/ExtensionPolyfillTests.swift
    title: ExtensionPolyfillTests.swift
  - id: integration
    resource: ../../DetourTests/ExtensionPolyfillIntegrationTests.swift
    title: ExtensionPolyfillIntegrationTests.swift
  - id: wiring
    resource: ../../DetourTests/ExtensionPolyfillProfileWiringTests.swift
    title: ExtensionPolyfillProfileWiringTests.swift
  - id: setup
    resource: ../../DetourTests/TestEnvironmentSetup.swift
    title: TestEnvironmentSetup.swift
  - id: test-extensions
    resource: ../../TestExtensions
    title: TestExtensions directory
  - id: task-2
    resource: backlog:TASK-2
    title: Service worker restart (harness artifacts met on the way)
  - id: task-4
    resource: backlog:TASK-4
    title: Iframe autofill (content-script messaging in tests)
  - id: task-15
    resource: backlog:TASK-15
    title: The polyfill must not replace the chrome/browser globals
  - id: task-62
    resource: backlog:TASK-62
    title: Keep-alive in background pages (measurement legs, the user-script loop incident)
  - id: notes-testing
    resource: "Agent session notes, 2026-09-12 to 2026-10-03 (not in the repository)"
    title: Session notes on test runs and extension seeding
---

# When to use

You are adding or changing a Web Extension API, a polyfill module, a native
polyfill handler or a `WKWebExtensionControllerDelegate` method, or you need
to decide how much evidence a change to the extension runtime requires.

`CLAUDE.md` states the policy (every new or changed API needs tests in a
real extension context as well as JS-level unit tests, with permission
gating, isolation, both transports and both error forms covered, and an API
Explorer update). This page explains the test kinds that policy refers to.

# Steps

1. Pick the lowest level that can fail for the right reason, using the table
   below. Most API work needs levels 2, 3 and 4.
2. Write the tests, with the shared fixtures.
3. Add or update the API Explorer section.
4. Run the affected suites; see [build and test](../playbooks/build-and-test.md).
5. If the behaviour depends on WebKit's process model or timers, check it in
   the running app ([runtime verification](../playbooks/runtime-verification.md)).
6. If it depends on a real extension with a trusted native host, it needs the
   [signed build](../playbooks/signed-build-verification.md).

# What each level proves

| Level | Suites | Environment | Proves | Cannot prove |
|---|---|---|---|---|
| 1. Pure rules | `NativeHostKeepAliveTests`, `ConsoleBridgeLimiterTests`, `NativeConnectLogLimiterTests`, `ExtensionUpdatePolicyTests`, `CRX3VerifierTests`, `RuntimeInstalledEventTests`, `ExtensionActiveTabTests` | No WebKit; injected clock | Every ordering of a state machine or rule | That anything is wired to it |
| 2. Polyfill JS | `ExtensionPolyfillTests` | A bare `WKWebView` at `https://test.example.com` with a shim for `chrome.runtime` and a fake `connectNative`, then the real polyfill; `OriginMappingProfile` stands in for sender attribution | Module logic, callback and promise forms, the native handler's dispatch | WebKit's wrapper objects, the worker transport, sender verification by context |
| 3. Real context | `ExtensionPolyfillIntegrationTests`, `WKExtensionIntegrationTests` | A real `WKWebExtensionContext` in a controller built by the test | The patch coexists with native APIs and **survives garbage collection**; real worker round trips; a page cannot claim another extension's id | Detour's own controller configuration |
| 4. Production wiring | `ExtensionPolyfillProfileWiringTests`, `NativeMessagingEnforcementTests`, `ExtensionPrivateStoreTests`, `ExtensionOriginTrackingPreventionTests`, `NewProfileExtensionLoadTests` | `Profile.extensionController` and `Profile.loadExtensionContext`, `ExtensionManager` as delegate | That deleting the wiring in `Profile` or `ExtensionManager` fails a test; per-profile isolation; native hosts and ports | Behaviour over minutes, unless an env-gated leg is run |
| 5. Running app | API Explorer in an isolated profile | Debug build, `DETOUR_DATA_DIR` | Real windows, tabs, menus, timers | Anything needing a trusted native host |
| 6. Signed build | The real extension | `/Applications` build | What users get | Repeatability |

Level 2 exists because it is fast and precise; it is not sufficient. The
reasons are concrete: WebKit re-creates wrapper objects, so a patch that
works in a shim can vanish in a real context (see
[chrome runtime patching](./chrome-runtime-patching.md)), and a change that
replaced the `chrome` global passed every JS test while breaking all
page-to-worker messaging.[^task-15] The level-3 test
`testRuntimeSendMessageReachesWorkerRunningThePolyfill` now guards that.

# Fixtures

All in `ExtensionTestSupport.swift` unless noted.

| Fixture | Use |
|---|---|
| `makeTestExtension(id:manifestJSON:files:)`, `installTestExtension`, `loadTestContext` | Write an unpacked extension to a temp directory, save it, load it into a profile. Tests generate their extensions; they do not load `TestExtensions/` |
| `registerProbeTab(for:in:)` / `unregisterProbeTab` | Make a plain web view a tab WebKit knows. **Call it before the page loads** |
| `askWorker(from:message:transport:)` | One round trip to the worker, returning both `reply` and `lastError`. `.direct` from an extension page, `.contentScriptRelay` from a web page |
| `workerReplyIsEmpty` | A null reply means either "the worker answered nothing" or "WebKit could not reach it"; `"timeout"` means the callback never fired |
| `postRawPolyfillEnvelope` | Post to the bridge bypassing the polyfill, so a test can claim any extension id |
| `callbackOutcomeJS`, `promiseOutcomeJS` | Record how a call settled in callback form (`runtime.lastError`) and promise form |
| `FakeNativeMessagingHost` | A silent host process found through `DETOUR_NATIVE_MESSAGING_HOSTS_DIR` |
| `LoopbackHTTPServer` | Real http documents for frame tests; a different port is a different origin |
| `LoopbackWebSocketServer` | An echo server for the [relay](./websocket-relay.md) |
| `CRX3TestSupport.swift` | Builds signed CRX3 files in the test |

`TestEnvironmentSetup` wipes the extension table and the data directory's
`Extensions/` folder at bundle start and turns off
`ExtensionManager.loadsExtensionsIntoAddedProfiles`, so a test that creates a
profile gets no extensions unless it opts in.

# Long legs behind environment variables

`xcodebuild` forwards only variables prefixed `TEST_RUNNER_` to the test
host, and strips the prefix.

| Variable | What runs |
|---|---|
| `TEST_RUNNER_DETOUR_MEASURE_BACKGROUND_PAGE_UNLOAD=1` | Six background-page unload legs: three baseline legs, about 37 s, 127 s and 300 s,[^task-62] and three that close one of the background's ports (TASK-141), about 47 s, 128 s and 38 s; see [service worker unload rules](../platform/service-worker-unload-rules.md) |
| `TEST_RUNNER_DETOUR_MEASURE_WORKER_UNLOAD=1` (and `…_SECONDS`, default 300) | A worker held only by the keep-alive, then released |
| `TEST_RUNNER_DETOUR_MEASURE_PRIVATE_WORKER=1` (and `…_SECONDS`) | The Private-profile worker answering after 90 s instead of a few |
| `TEST_RUNNER_DETOUR_DATA_DIR=<name>` | A private data directory, needed when two test runs overlap |

These are measurements of WebKit's timers
([service worker unload rules](../platform/service-worker-unload-rules.md)).
Leave them off in normal runs.

# TestExtensions

| Directory | What it is |
|---|---|
| `hello-world` | Minimal MV3: classic service worker, content script, popup, `storage` |
| `hello-world-module` | The same with a `type: module` worker. The only one an automated test reads (`ModuleBundlerTests`) |
| `api-explorer` | One popup section per API, a background that logs events to storage |
| `1password/1password.crx` | A checked-in store CRX. No test references it |

Load one with Develop → Load Unpacked Extension, or seed it into an isolated
profile ([seeding extensions](../playbooks/seeding-extensions.md)).

API Explorer details that show up in logs and are easy to misread:

- A one-minute alarm, `api-explorer-heartbeat`, wakes the worker so idle
  unload and restart can be watched.
- Every worker start opens `wss://example.invalid` on purpose and logs the
  resulting error and 1006 close.
- It does **not** declare `nativeMessaging`, so its keep-alive probe is
  expected to report `installMode: 'none'`, `installDetail:
  'no-nativeMessaging-permission'`.
- Each `runtime.onInstalled` delivery is appended to
  `storage.local.onInstalledEvents`, and the history is logged at every
  worker start.

# Traps

- **Content-script messages reach the worker only from a registered tab.**
  Without `registerProbeTab` before the load, `runtime.sendMessage` from a
  content script goes nowhere. Old skip comments blaming the sandbox for
  this were wrong.[^task-4]
- **A message sent while the worker sleeps can be silently lost** in a test
  that does not wait for the worker.[^task-4]
- **WebKit hides ungranted API namespaces.** A hand-loaded or hand-seeded
  extension with no permission grants sees `chrome.alarms` (and others) as
  undefined; a top-level access throws and the background fails to load with
  only "The background content failed to load". That is the fixture, not the
  product.[^task-2]
- **`runtime.onInstalled` never arrives from WebKit in a test** that loads a
  context straight into a new controller; see
  [runtime.onInstalled](./runtime-installed-event.md).
- **Garbage-collection tests need a collection to happen.** They churn
  garbage in escalating rounds until a control `WeakRef` is cleared, and fail
  their own precondition ("no collection observed in N rounds") when none
  happens within 10 rounds. That failure is about the run, not the patch
  under test. The deterministic guard is the separate check that the object
  the polyfill holds is the one the API answers with.
- **Never mutate `WKUserContentController.userScripts` while iterating it.**
  The bridged array tracks the controller; a helper that re-added scripts in
  the loop never terminated and the test host reached 36 GB in 90 s.[^task-62]
  Snapshot plain values first.
- **Releasing a profile whose controller hosted a popup web view can crash
  the test host** seconds later, in another suite. Close the popup and keep
  torn-down profiles alive; see
  [WebKit test host traps](../platform/webkit-test-host-traps.md).
- **`DETOUR_DATA_DIR` isolates Detour's databases, not WebKit's storage
  directory**, which every run of the same bundle id shares.[^notes-testing]
  See [profile data removal](../architecture/profile-data-removal.md).
- **Log line text is not asserted anywhere.** After changing a log line that
  a playbook greps for, check it by eye.
- **Stale comments.** The class comment on `ExtensionPolyfillIntegrationTests`
  says service worker messaging cannot be tested in the test process; the
  same class contains real worker round trips.

# Related

- [Polyfill layer](./polyfill-layer.md) — what levels 2 to 4 exercise
- [Permissions](./permissions.md) — positive and negative permission cases
- [Build and test](../playbooks/build-and-test.md) — commands, one build at a time, the memory watchdog
- [Test host crashes](../playbooks/test-host-crashes.md) — "TEST FAILED" with zero failures
- [Debug harness](../playbooks/debug-harness.md) — driving the app for level 5
- [1Password integration](./1password-integration.md) — what only level 6 can show

[^task-2]: Service worker restart (harness artifacts met on the way)
[^task-4]: Iframe autofill (content-script messaging in tests)
[^task-15]: The polyfill must not replace the chrome/browser globals
[^task-62]: Keep-alive in background pages (measurement legs, the user-script loop incident)
[^notes-testing]: Session notes on test runs and extension seeding
