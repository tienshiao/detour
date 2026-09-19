---
id: TASK-90
title: >-
  Extensions: 1Password worker stuck in a desktop-app reconnect loop pins the
  WebKit Networking process (IndexedDB abort storm)
status: To Do
assignee: []
created_date: '2026-09-19 19:51'
updated_date: '2026-09-19 19:52'
labels:
  - bug
  - extensions
  - performance
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
  - Detour/Extensions/Runtime/ConsoleBridgeLimiter.swift
priority: medium
ordinal: 90000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Observed live on 2026-09-19 (production /Applications build, up ~4 days): com.apple.WebKit.Networking at ~88% CPU (108 CPU-minutes), a WebContent process at ~20%. Unlike the Sep 12 incident this is NOT YouTube (its IndexedDB files were last written 11 minutes earlier and idle).

Attribution (read-only: ps, sample, lsof, log show, strings on a WAL):
- Networking sample: hot in WebCore::IDBServer::UniqueIDBDatabase::takeNextRunnableTransaction, reached almost entirely via NetworkStorageManager::abortTransaction -> UniqueIDBDatabase::abortTransaction -> handleTransactions (874 of 879 NetworkStorageManager samples). That function scans the database's pending-transaction list, so cost grows with the backlog: a steady stream of transactions, each abort paying O(pending).
- The only IndexedDB being written: WebsiteDataStore/ca8c2b61... (profile 'Work'), origin host 7001c112-4a7f-49d0-9c1c-17728a7a0bec (an extension origin), databases 'b5x' and 'b5x-diagnostics' (object store 'logs', 11 MB, WAL growing ~29 KB / 30 s). b5x = 1Password; it is the only installed extension (aeblfdkhhhdcdjpifhhbdiojplfjncoa).
- The busy WebContent (PID 58728, 14.5 h old) is a service-worker process (ProcessSuspension log: workerType=service) with IDBTransaction / IDBClient::TransactionOperation JS frames.
- Detour's own log: category extension-polyfill, '[SW aeblfdkh...]' at a flat 20 lines/second, ALL level error (1211 in 60 s). Message text is redacted (ExtensionConsoleLogPublic is read once per launch, and relaunching would clear the state). The 100/s ConsoleBridgeLimiter cap never engages at 20/s.
- The same lines are in 1Password's diagnostics DB; the WAL tail shows a repeating cycle: '[AppIntegration] Desktop app connection attempt failed: PortClosed' / 'Desktop app port disconnected. Error: None' / '[DesktopApp] Caught exception that was thrown by invoke while connecting to desktop' / 'Connecting to desktop failed gracefully - resetting connecting state' / 'Initiation failed - B5X is not connected to desktop app', interleaved with repeated backend start-up lines ('WASM: Initializing XAM backend', 'XAM: [] Hello, world! :)', 'AP: <1> initialized') - i.e. the background keeps re-initialising and retrying the native connection.
- Native hosts: Detour (PID 1306) has exactly two 1Password-BrowserSupport children, both 16.5 h old (PIDs 47229/47231, spawned alongside worker processes 47228/47230). The looping worker process 58728 is ~2 h YOUNGER than those hosts and no new host has been spawned since; Detour logged nothing about native messaging in the sampled minute. So the Work-profile worker was replaced and its replacement cannot get a desktop-app port, while the old hosts are still alive. Same family as TASK-67 (worker replaced without its page closing leaks its native hosts) and TASK-68 (unload without a relayed socket), both Done - this looks like a remaining path.

So: root cause is on our side of the boundary (native port lifecycle after a worker replacement), the amplifier is 1Password's unthrottled retry + per-line IndexedDB logging, and the CPU burn is WebKit's O(pending) transaction scheduling. We control the first, can guard against the second, and can only observe the third.

Work to do:
1. Root cause: reproduce a worker replacement in the Work profile and find why connectNative from the new worker yields PortClosed with no host spawn and no Detour log line (is the request reaching ExtensionManager at all? is the keep-alive / host bookkeeping still bound to the dead worker? is it per-profile - Personal appears healthy?). Every connectNative attempt and its outcome must be logged (rate-limited) so the next incident is diagnosable from 'log show' alone.
2. Guardrail independent of the cause: detect a sustained extension error/console flood (the limiter already counts per extension) or sustained helper CPU, and react - at minimum a rate-limited log line naming the extension + profile; consider a one-shot worker restart and/or a user-visible notice. Consider a sustained-rate cap in ConsoleBridgeLimiter (burst 100, then a few per second) so a 20/s error loop does not cost 1200 unified-log writes a minute for hours.
3. Decide whether Detour should surface helper-process CPU attribution at all (a debug menu item that dumps: top helper PIDs, open IndexedDB origins with decoded names, service-worker PIDs) - the manual playbook took ~10 commands.

Immediate workaround for the user: kill the looping WebContent process (or toggle 1Password off/on in the Work profile); WebKit restarts the worker.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The PortClosed reconnect loop is reproduced (or the production evidence is explained) and its cause in Detour's native-messaging / worker-replacement handling is identified and fixed, with a regression test
- [ ] #2 A replaced background worker can open a native port: the new worker's connectNative spawns (or is attached to) a host, and hosts belonging to the dead worker are terminated
- [ ] #3 Every connectNative attempt and failure is logged with extension id and profile, rate-limited, without secrets
- [ ] #4 A sustained extension console/error flood is detected and reported once per incident with extension id and profile; the chosen reaction (log only / worker restart / user notice) is recorded in the task
- [ ] #5 Sustained console-bridge traffic below the 100/s burst cap is bounded (e.g. token bucket) and covered by ConsoleBridgeLimiterTests
- [ ] #6 Positive and negative tests accompany any change to native-messaging permission or host lifecycle handling
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-09-19 12:52: all measurements above are the release build (filtered by processIdentifier 1306 = /Applications/Detour.app; Networking PID 1380 started 7 s after it). The user reports seeing similar errors in a DEBUG build running from Xcode at the same time; after they stopped it, the release build's loop continued unchanged (20 errors/s, Networking ~86%, worker 58728 ~22%), so the release build has the problem on its own. Hypothesis to test as a TRIGGER, not yet shown: a debug build launched without DETOUR_DATA_DIR shares the bundle id, hence the same ~/Library/WebKit/com.detourbrowser.mac WebsiteDataStore (same 1Password IndexedDB files) and competes for the same 1Password desktop-app connection; 1Password only trusts the signed /Applications build, so the debug instance always fails - check whether its attempts knock the release instance's port over (PortClosed), and whether two instances writing one extension origin's IndexedDB explains the transaction backlog. If so, part of the fix is making non-release builds use an isolated data directory by default.
<!-- SECTION:NOTES:END -->
