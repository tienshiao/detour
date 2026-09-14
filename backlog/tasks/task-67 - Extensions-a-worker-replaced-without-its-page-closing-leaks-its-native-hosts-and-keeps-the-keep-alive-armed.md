---
id: TASK-67
title: >-
  Extensions: a worker replaced without its page closing leaks its native hosts
  and keeps the keep-alive armed
status: In Progress
assignee:
  - '@claude'
created_date: '2026-09-14 01:45'
updated_date: '2026-09-14 03:21'
labels:
  - extensions
  - 1password
  - bug
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionManager.swift
  - Detour/Extensions/Runtime/NativeHostKeepAlive.swift
documentation:
  - docs/1password-integration-plan.md
priority: high
ordinal: 67000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during the TASK-21 production run (2026-09-13, signed build, pid 46243, 1Password 8.12.26.40, macOS 26.6.2). When a 1Password background worker is replaced without WebKit closing its background page first, Detour never learns that the old worker's native messaging ports ended. The old BrowserSupport host processes keep running as children of Detour, and they stay in `liveNativeHosts`, so `NativeHostKeepAliveState` keeps counting them for that (controller, extension) key. The keep-alive then stays armed for a worker that has no live host, so WebKit is never allowed to idle-unload it, and each such replacement leaks one host process.

Observed sequence: at 18:38:41 the user quit the 1Password desktop app; all three helpers sent a final frame (103 + 52 bytes). At 18:38:49 WebKit ran `WebPageProxy::loadServiceWorker` for all three profiles and the workers initialised from scratch. The log has no `WebPageProxy::close` or `workerTerminated` for the old workers and no NM EOF/EXIT for their hosts. Detour logged `Keep-alive port ... superseded by a newer one` three times, and each new port was immediately `Keep-alive armed ... 1 native host(s) connected` before the new worker had connected anything, so the armed count came from the old host. Later restarts in the same profile logged `2 native host(s) connected` (18:39:49, 18:40:49) and `3 native host(s) connected` (18:42:49). At 18:44 `ps` showed 10 BrowserSupport processes with ppid Detour for three workers, including the three spawned at 18:15:49 and 18:18:49 for workers that no longer existed.

What replaced the worker at 18:38:49 is not known. Candidates: 1Password called `runtime.reload()` when the desktop app went away (native, not logged by Detour), or WebKit restarted the service worker without closing its page. The superseded-port path in `ExtensionManager` (the `.polyfillHost` case of `connectUsing`) is where Detour already notices that a new context of the same extension appeared.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The mechanism that replaced the workers at 18:38:49 is identified (runtime.reload, WebKit worker restart, or other) and reproduced in a test or the debug harness
- [x] #2 When a new background context of an extension appears in a profile, native hosts owned by the context it replaced are disconnected and their processes exit
- [x] #3 The keep-alive armed count for the new context counts only hosts that context connected; a test covers a replacement with 1 and with 2 old hosts
- [x] #4 A normal host disconnect and a context unload still release each host exactly once (existing TASK-16 tests stay green)
- [ ] #5 Production check: after quitting the 1Password desktop app, ps shows no BrowserSupport child of Detour older than the current workers
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Mechanism (AC #1): WebKit's WebExtensionContext::unload() (both the shipped-era source and main) clears m_nativePortMap without calling reportDisconnection, and chrome.runtime.reload() is implemented as controller unload+load, so a worker that calls runtime.reload() leaves every native port Detour holds for it (keep-alive, hosts, relays) without a disconnect callback. Leading candidate for 18:38:49: 1Password calling runtime.reload() after the desktop app went away. Reproduce in ExtensionPolyfillProfileWiringTests: a probe worker holding a FakeNativeMessagingHost port is told to call chrome.runtime.reload(); without the fix the old host process stays alive and liveNativeHostCount stays put after the new worker's keep-alive port supersedes the old one. 2. Fix (AC #2/#3): in the .polyfillHost supersede path of connectUsing, treat the arrival of a new keep-alive port while the old one is still open as a replaced background context: tear down every live host and relayed socket registered under that (controller, extension) key (kill the host process, disconnect its WebKit port, drop the relay sessions), reset the keep-alive state, then accept the new port. Factor the teardown with closeExtensionPorts. The polyfill opens its keep-alive port before any extension code runs, so at supersede time every registered connection belongs to the replaced context. 3. Tests: replacement with 1 and with 2 old hosts (fake host processes exit, count restarts at 0, the new context's own hosts arm it with the right count); existing TASK-16/25/62 tests stay green (AC #4). 4. Log the teardown and record the mechanism in docs/1password-integration-plan.md. 5. AC #5 (production ps check) is the user's after deploy.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Mechanism confirmed (AC #1), 2026-09-13 test run: a worker probe holding 2 ports to a FakeNativeMessagingHost called chrome.runtime.reload(). WebKit fired NO disconnect handler for any of them — Detour's log went straight from 'Keep-alive port ... superseded by a newer one' to 'Keep-alive armed ... 2 native host(s) connected' 0.5 s after the replacement started, then 4 live hosts and 4 sleep processes (pids 59444, 59445 from the first generation still alive). The old hosts were only released at test teardown, via Profile.unloadExtension -> closeExtensionPorts. The test fixture survived the reload intact: the extension page kept working, the context object stayed the same, and WebKit started the replacement worker itself within ~0.5 s (the nudge in the helper was never needed). This is exactly the production shape at 18:38:49.

Fix (AC #2/#3): ExtensionManager.tearDownNativeConnections(for:disconnectingPortsWith:) is now the single teardown for a (controller, extension) key — relays torn down, live hosts removed from the registry, keep-alive reset with .contextUnloaded, then each host process killed and (when an error is given) its port disconnected. closeExtensionPorts calls it with no error (WebKit closes an unloaded context's ports itself); the .polyfillHost supersede path calls it with ExtensionManager.replacedBackgroundContextError() and logs 'Replaced background context of <ext>: tore down N stale native host(s) and M relayed WebSocket(s)'.

Tests (AC #3), in ExtensionPolyfillProfileWiringTests: testRuntimeReloadTearsDownTheReplacedContextsNativeHost (1 host), testRuntimeReloadTearsDownEveryNativeHostOfTheReplacedContext (2 hosts) — both assert the first generation's pids are gone, liveNativeHostCount and state.connectedHosts equal the new context's count, and it is armed — and testASupersededKeepAlivePortTearsDownTheReplacedContextsRelayedSocket (relay session ended on supersede). FakeNativeMessagingHost gained processIDs() so 'the old ones exited' can be said about specific processes.

AC #4: NativeHostKeepAliveTests, ExtensionPolyfillProfileWiringTests, ExtensionPolyfillTests, NativeMessagingEnforcementTests, ExtensionPermissionTests — 261 tests, 0 failures, 3 skipped (the long measurement legs). Committed as 63abb97; docs/1password-integration-plan.md Phase 1 item 1 records the WebKit behaviour. AC #5 stays open: it is the production ps check after the next deploy.

Code review (medium, --fix) on 63abb97: applied — tearDownNativeConnections doc now says one-shot sendNativeMessage hosts are not swept (activeMessagingHosts records no controller; pre-existing gap, follow-up candidate), and the supersede branch documents its known over-reach: registries are per extension, not per context, so a connectNative port a still-open popup/options page holds is torn down with the background's on a WebKit-internal background restart (a runtime.reload closes those pages too, so it costs nothing there). A per-context fix needs a signal a native port does not carry — left as reported. Test fixture dedup: makeWorkerExtension wraps makeBackgroundPageExtension (.serviceWorker), startNativeHostProbe calls startMeasurement.

Production run 2 (2026-09-13 20:04-20:20, commit 3b8d8f4): when WebKit unloaded the dead worker's page at 20:06:52 the keep-alive port closed, Detour killed its host (pid 69970 gone) and the 20:07:22 worker spawned a new one (71002); ps at 20:20 shows exactly three BrowserSupport children for three workers. The supersede path did not fire in this run (no runtime.reload happened), so AC #5's quit-the-desktop-app check is still the user's.
<!-- SECTION:NOTES:END -->
