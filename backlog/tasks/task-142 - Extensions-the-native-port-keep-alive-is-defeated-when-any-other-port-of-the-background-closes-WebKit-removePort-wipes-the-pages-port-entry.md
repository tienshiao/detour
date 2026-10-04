---
id: TASK-142
title: >-
  Extensions: the native-port keep-alive is defeated when any other port of the
  background closes (WebKit removePort wipes the page's port entry)
status: To Do
assignee: []
created_date: '2026-10-04 02:09'
labels: []
dependencies:
  - TASK-141
references:
  - wiki/platform/service-worker-unload-rules.md
  - wiki/extensions/native-port-keep-alive.md
priority: high
ordinal: 165000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-141 confirmed, in WebKit's source and at runtime, that WebExtensionContext::removePort removes a page's whole entry from m_pagePortMap when any one port's count reaches zero. From then on pageHasOpenPorts is false for the background, the 2-minute open-active-ports rule no longer applies, and the next 30 s unload tick closes the background — while Detour's keep-alive port is open, armed and being answered.

Measured 2026-10-03 on a background page in the test host (ExtensionPolyfillProfileWiringTests, DETOUR_MEASURE_BACKGROUND_PAGE_UNLOAD=1): two native ports, one disconnected at +10 s, keep-alive armed with a host still connected: unloaded at +29.7 s (control without the close: still running at +300 s). The same with an ordinary runtime.connect port that an extension page opened and closed: unloaded at +30.2 s. After the unload WebKit reports no disconnect for the surviving ports, so Detour keeps the host process and an armed keep-alive until the missed-reply recovery drops them 15–30 s later and reloads the background about 60 s after the unload; if the extension repeats the pattern, it cycles.

So the keep-alive (TASK-16/62/68) only holds for a background whose ports never close while it is being held. Any content-script port ending (a tab closing or navigating), a second native port closing, or a relayed socket closing breaks it. Not yet measured: a service worker background (same WebKit code path), a signed build, and how often real extensions (1Password) hit it.

Directions to evaluate, not decided: (a) re-create the page's entry after a loss — WebKit's addPorts re-creates it whenever the background opens a port, so the polyfill could open a fresh keep-alive port after any of the background's ports disconnects, and/or on every ping; (b) have the native side detect the unload sooner than two missed pings; (c) report the bug to WebKit (the fix there is to remove the page entry only when its counted set is empty).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A background that is being kept alive stays loaded after another of its ports closes: a second native port, a runtime.connect port closed by the other end, and a port the background closes itself
- [ ] #2 The TASK-141 legs (d)–(f) are joined by legs showing the page still running well past the 30 s tick with the fix, and the existing keep-alive tests still pass
- [ ] #3 The same is shown for a service worker background, not only a background page
- [ ] #4 No port or host is leaked by the fix, and a background that should unload (no host, no relayed socket) still does
- [ ] #5 A WebKit bug is filed or the task records why not; the wiki pages platform/service-worker-unload-rules.md and extensions/native-port-keep-alive.md are updated
<!-- AC:END -->
