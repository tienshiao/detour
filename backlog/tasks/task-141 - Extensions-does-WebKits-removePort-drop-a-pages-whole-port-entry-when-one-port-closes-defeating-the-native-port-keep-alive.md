---
id: TASK-141
title: >-
  Extensions: does WebKit's removePort drop a page's whole port entry when one
  port closes, defeating the native-port keep-alive?
status: To Do
assignee: []
created_date: '2026-10-04 01:58'
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
- [ ] #1 The removePort / pageHasOpenPorts / unload-timer logic is traced in WebKit's source and the finding states which revision was read and whether the shipped framework matches
- [ ] #2 A runtime experiment in a real extension context (two ports open from a background, one closed, the other kept active) shows whether the background is unloaded, with the timing recorded; long legs sit behind a TEST_RUNNER_ variable
- [ ] #3 The consequence for NativeHostKeepAlive is stated: which extension behaviours defeat the keep-alive, and whether TASK-16/21/68's observations are explained
- [ ] #4 wiki/platform/service-worker-unload-rules.md and wiki/extensions/native-port-keep-alive.md record the result with its evidence; a fix, if one is warranted, is filed as its own task
<!-- AC:END -->
