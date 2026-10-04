---
id: TASK-141
title: >-
  Extensions: does WebKit's removePort drop a page's whole port entry when one
  port closes, defeating the native-port keep-alive?
status: Done
assignee: []
created_date: '2026-10-04 01:58'
updated_date: '2026-10-04 02:15'
labels: []
dependencies: []
references:
  - wiki/platform/service-worker-unload-rules.md
  - wiki/extensions/native-port-keep-alive.md
priority: medium
ordinal: 164000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Hypothesis from reading WebKit's source (WebExtensionContext::removePort, same code at the 2026-05-02 revision and on main): when any one port's count for a page reaches zero, the page's whole entry is removed from m_pagePortMap. If so, closing one port of a background context makes pageHasOpenPorts false for all its ports, the 30-second unload timer runs although the keep-alive port is open and recently posted on, and the later page close reports no disconnect for the remaining ports.

It would explain three recorded observations — the background unloaded exactly 30.0 s after its last real native port closed while the keep-alive port was open (TASK-16 twice, TASK-21 once) — and is a candidate cause for the post-lock worker cycling that TASK-68 attributed to worker timers by elimination. It has never been tested on its own. Recorded as source-derived in wiki/platform/service-worker-unload-rules.md with an open question in wiki/extensions/native-port-keep-alive.md.

Goal: confirm or refute it — first against the source of the WebKit that ships with the current macOS, then with a runtime experiment in a real extension context — and, if it holds, say what it means for NativeHostKeepAlive (an extension that closes a second native port or a relayed socket while its host stays connected).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The removePort / pageHasOpenPorts / unload-timer logic is traced in WebKit's source and the finding states which revision was read and whether the shipped framework matches
- [x] #2 A runtime experiment in a real extension context (two ports open from a background, one closed, the other kept active) shows whether the background is unloaded, with the timing recorded; long legs sit behind a TEST_RUNNER_ variable
- [x] #3 The consequence for NativeHostKeepAlive is stated: which extension behaviours defeat the keep-alive, and whether TASK-16/21/68's observations are explained
- [x] #4 wiki/platform/service-worker-unload-rules.md and wiki/extensions/native-port-keep-alive.md record the result with its evidence; a fix, if one is warranted, is filed as its own task
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Read removePort, pageHasOpenPorts, disconnectPortsForPage and unloadBackgroundContentIfPossible in WebKit main and in the safari-7624 / safari-7623 branches.
2. Add two env-gated legs to ExtensionPolyfillProfileWiringTests (DETOUR_MEASURE_BACKGROUND_PAGE_UNLOAD=1): (d) two silent native ports, one closed at +10 s, keep-alive out of the way; (e) the same with the production keep-alive armed and pinging every 15 s. Controls are the existing legs (b) 120 s and (c) alive at 300 s.
3. Record what Detour is left holding after the unload (hosts, keep-alive state) and whether it recovers.
4. Write the result into the two wiki pages; file a fix as its own task if warranted.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Source: WebExtensionContext::removePort (Source/WebKit/UIProcess/Extensions/Cocoa/API/WebExtensionContextAPIPortCocoa.mm) ends with 'if (pagePorts.remove({source, target, channel})) m_pagePortMap.remove(page)'. HashCountedSet::remove returns true when that value's count reaches zero, not when the set is empty, so the first port of a page to go removes the page's whole entry. Identical on WebKit main and on the safari-7624 and safari-7623 branches (read 2026-10-04 UTC); the installed framework is 21624.5.1.11.3 on macOS 26.7. unloadBackgroundContentIfPossible defers only while pageHasOpenPorts(backgroundPage) and the last background post is under 2 minutes old, so once the entry is gone the next 30 s tick unloads. disconnectPortsForPage then finds no entry and reports no disconnect for the surviving ports.

Runtime (three new env-gated legs in ExtensionPolyfillProfileWiringTests, DETOUR_MEASURE_BACKGROUND_PAGE_UNLOAD=1, background page, Debug test host, private DerivedData; each run twice with the same timings):
(d) two silent native ports, keep-alive out of the way, the background disconnects one at +10.0 s: unloaded at +29.7 s (control, leg b: +120 s). The surviving port got no onDisconnect; Detour still held its host 10 s later.
(e) the same with the production keep-alive armed, pinging every 15 s, a host still connected: unloaded at +29.7 s (control, leg c: running at +300 s). Detour kept connectedHosts 1 / armed for 15–30 s, the missed-reply recovery then dropped the host and reloaded the page about 60 s after the unload, and the reloaded page (same script) was unloaded at +29.7 s again.
(f) keep-alive armed, one native port, plus a runtime.connect port opened by an extension page and disconnected by it at +10.6 s: unloaded at +30.2 s.

Consequence: the keep-alive holds only while none of the background's ports ends. A second native port, a relayed socket, or any runtime port closing (a content script's port when its tab closes or navigates) defeats it within one 30 s tick, and the surviving host leaks until the missed-reply recovery. This explains the three '30.0 s after the last real native port closed' observations of TASK-16/TASK-21 (there the disconnect event woke the background and re-armed the timer, hence 30.0 s after the close). It is a plausible cause of TASK-68's post-lock worker cycling, not shown: that needs a 1Password run.

Not measured: a service worker background (same per-page bookkeeping), a signed build, real extensions.

Checks: /code-review low on the test diff found nothing to fix. Tests: the three legs 3/3 passed (210 s); the whole ExtensionPolyfillProfileWiringTests class without the gate: 50 executed, 7 skipped, 0 failures. No app code changed, so no /verify.

Fix filed as TASK-142 with three directions to evaluate (re-create the page entry by opening a fresh keep-alive port after a port loss or on every ping; faster native-side detection; a WebKit bug report).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Confirmed. WebKit removes a page's whole port entry when any one of its ports closes (source on main and safari-7624/7623; runtime on framework 21624.5.1.11.3), so the next 30 s tick unloads a background that Detour's keep-alive is holding, and the surviving ports get no disconnect. Pinned by three env-gated measurement legs (d, e, f) and written into wiki/platform/service-worker-unload-rules.md and wiki/extensions/native-port-keep-alive.md. The fix is TASK-142.
<!-- SECTION:FINAL_SUMMARY:END -->
