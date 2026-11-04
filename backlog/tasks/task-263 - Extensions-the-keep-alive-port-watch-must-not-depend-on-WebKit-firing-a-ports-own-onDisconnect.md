---
id: TASK-263
title: >-
  Extensions: the keep-alive port watch must not depend on WebKit firing a
  port's own onDisconnect
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T22:55:00Z'
updated_date: '2026-11-03T23:14:00Z'
labels:
  - extensions
  - native-messaging
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
priority: medium
type: bug
ordinal: 307000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-256. The keep-alive port watch (watchPort / installPortWatch in ExtensionAPIPolyfill.swift) relies on WebKit firing a port's onDisconnect in the context that called port.disconnect() — a WebKit bug (WebExtensionAPIPort::disconnect calls fireDisconnectEventIfNeeded), fixed upstream 2026-10-30 (325256@main, bug 329433). Detour uses the system WebKit, so once a macOS update ships the fix, an already installed Detour stops re-anchoring when the background closes a runtime.connect / tabs.connect port itself; the closed port goes unseen until the next ping, bringing back the TASK-142 unload risk (1Password keep-alive). The watch should re-anchor after the caller's own disconnect whether or not WebKit fires the event, without double-anchoring today.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A port the background closes itself triggers a re-anchor both when WebKit fires the caller's onDisconnect (today) and when it does not (simulated: e.g. the watch wraps port.disconnect and the test suppresses the self-fired event), and re-anchoring stays idempotent (one anchor held)
- [x] #2 The TASK-256 tests that pin the current WebKit behaviour stay, documented as expected to flip when the fix ships
- [ ] #3 NativeHostKeepAliveTests and the keep-alive legs of ExtensionPolyfillProfileWiringTests pass; the task records a signed-build 1Password check if behaviour changed
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation: watchPort (ExtensionAPIPolyfill.swift) now wraps disconnect on every watched port (runtime.connect, tabs.connect, ports handed to the extension's onConnect/onConnectExternal listeners). The wrapper is non-enumerable (Object.defineProperty), calls the port's own disconnect on the port (a detached call works), returns its result, and only then counts the end; a throwing disconnect does not count. A per-port ended flag counts the end once whether the wrapper or the self-fired onDisconnect sees it first, and reanchorSoon coalesces, so today's double sighting opens one anchor. Diagnostics: portDisconnectsWrapped, selfFiredEndsIgnored. Test-only hook __detourKeepAliveNoSelfFiredDisconnect makes the listener ignore an event fired inside the wrapped call, to play a WebKit with 325256@main.

Tests added: ExtensionPolyfillTests.testKeepAliveReanchorsWhenTheBackgroundDisconnectsAPortItself (fixed WebKit: runtime/tabs/received ports each re-anchor once, one anchor held, detached call, result passed through), testKeepAliveCountsASelfClosedPortOnceWhenWebKitFiresItsOwnOnDisconnect (shipped WebKit: one end, one re-anchor, later ends ignored; hook leg), testKeepAliveDoesNotReanchorWhileDisarmed extended with a self-close. ExtensionPolyfillProfileWiringTests.testAWorkerClosingItsOwnRuntimePortReanchorsWhetherOrNotWebKitFiresItsOnDisconnect (real worker, both legs: +1 end, +1 anchor, ignored 0/1, Detour holds one anchor; ping interval pinned to 3600 s). TASK-256 pins kept, doc comments now say they are expected to flip with the ignored count.

Results: ExtensionPolyfillTests 196, ExtensionPolyfillProfileWiringTests 65 (13 skipped, TEST_RUNNER-gated legs), NativeMessagingEnforcementTests 19, NativeHostKeepAliveTests 17: 297 tests, 0 failures (run before and after the review fixes). Under Thread Sanitizer, 10 iterations each of testAnArmedWorkerHoldsOneAnchorAndADisarmStopsReanchoring, the new wiring test and testARuntimePortEndingMakesTheArmedWorkerReanchor: 30/30 passed, no TSan reports (before and after the review fixes).

Review (/code-review --fix): fixed a throwing disconnect latching the end (would have silenced the port's real end) and the wrapper being an enumerable own property; also pinned the ping interval in the new wiring test and pointed the TASK-256 pin comments at the new ignored count. Skipped: the once-per-port latch (what AC #1 asks; pings cover a hypothetical second removal), test-only state in production (follows the existing hooks).

/verify (Debug build, DETOUR_DATA_DIR=DetourVerify263, fake silent host, seeded MV3 extension whose worker holds the host, opens an extension page, runtime.connects to it and self-closes): as shipped anchorsOpened 1->2, portEndsSeen 0->1, extension's own onDisconnect fired once; with the hook set (fixed WebKit simulated) anchorsOpened 2->3, portEndsSeen 1->2, selfFiredEndsIgnored 1; portDisconnectsWrapped counted on the real WebKit port. Pings #2 and #3 answered 27 s and 56 s after the closes, no port-closed/unload line. Data dir and defaults keys removed.

Owed by the user (AC #3): a signed-build check with 1Password, since the keep-alive port watch's behaviour changed (it now wraps port.disconnect). Everything else is complete.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The keep-alive port watch re-anchors after the background's own port.disconnect() through a non-enumerable disconnect wrapper, so it no longer depends on WebKit firing the caller's own onDisconnect (removed upstream in 325256@main). A per-port flag plus reanchorSoon's coalescing keep today's double sighting at one re-anchor. JS-level and real-worker tests cover shipped and simulated-fixed WebKit; 297 tests pass, the TSan 10x anchor checks pass, and /verify showed one anchor per self-close in both modes. Signed-build 1Password check is owed by the user (AC #3 unchecked).
<!-- SECTION:FINAL_SUMMARY:END -->
