---
type: Concept
title: Frames and content scripts
description: What WebKit does with frames in an extension context — native getAllFrames with its own frame ids, empty URLs and no content scripts for srcdoc and about:blank frames, the limits seen in cross-origin iframes — and what Detour adds for content scripts.
tags: [extensions, frames, content-scripts, webnavigation, webkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:49:13Z }
stale_after: 2027-04-01T00:00:00Z
sources:
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift (webNavigationJS, contentPolyfillJS, contentPolyfillBridgeJS)
  - id: plan-doc
    resource: ../../docs/1password-integration-plan.md
    title: docs/1password-integration-plan.md, "Phase 3 — Real frame enumeration"
  - id: integration-tests
    resource: ../../DetourTests/ExtensionPolyfillIntegrationTests.swift
    title: ExtensionPolyfillIntegrationTests (testFrameKindsAsReportedByNativeGetAllFrames, testContentScriptFrameHellosReachTheWorker)
  - id: manifest
    resource: ../../Detour/Extensions/Model/ExtensionManifest.swift
    title: ExtensionManifest.swift (ContentScript)
  - id: task-4
    resource: backlog:TASK-4
    title: "1Password: iframe autofill — test the empty-URL hypothesis"
  - id: task-100
    resource: backlog:TASK-100
    title: Inject content scripts into srcdoc and about:blank frames (match_about_blank)
  - id: task-101
    resource: backlog:TASK-101
    title: 1Password's inline menu does not open from a form inside a cross-origin iframe
  - id: task-102
    resource: backlog:TASK-102
    title: 1Password's worker in the Private profile throws on page loads
  - id: task-20
    resource: backlog:TASK-20
    title: Un-skip the WKExtensionIntegrationTests runtime messaging tests
---

Content script injection and frame enumeration are WebKit's. Detour adds one
small script to each content script entry and patches some `webNavigation`
events. What matters on this page is mostly measurement: which frames WebKit
enumerates, what it reports for them, and where an extension that works in
Chrome gets nothing. Two of the gaps are open.

# Summary

- WebKit injects manifest content scripts into every web view whose
  configuration carries the profile's extension controller.
- `webNavigation.getAllFrames` and `getFrame` are **native**, in workers and
  pages, and return WebKit's own frame ids. Detour does not polyfill them.
- `srcdoc` and `about:blank` frames are enumerated but report an empty URL
  and get no content script.
- In a cross-origin http iframe the content script runs, but 1Password's
  inline menu does not open. Not diagnosed.

# Rules

## Frame enumeration is WebKit's, on purpose

Measured on macOS 26 (2026-09-12): `getAllFrames({tabId})` returns every
frame with WebKit's own ids (top frame 0, subframes such as 30064771073),
`parentFrameId` -1 for the top and 0 for its children, and URLs. Those ids are
what `getFrame`, `sender.frameId` and `tabs.sendMessage(tabId, msg, {frameId})`
use.[^task-4]

An earlier plan was a registry in the worker polyfill, fed by hellos from
content scripts. It was dropped, and the polyfill's `getAllFrames` / `getFrame`
fallbacks were deleted:

- frame ids must be WebKit's or messages go to frames that do not exist;
- a fallback has no cross-origin frame tree to read, so it could only
  fabricate records;
- a WebKit regression should therefore fail loudly — `getAllFrames is not a
  function` at the call site — rather than hand an extension phantom frames.

`webNavigationJS` records, once and before patching anything, whether WebKit
vends the two functions: `__detourWebNavFrames`, surfaced as
`_polyfillDiag.apis.webNavigationFrames`. That reading is the only warning a
regression would give.

## What WebKit reports per frame kind

Measured by `testFrameKindsAsReportedByNativeGetAllFrames` on macOS 26.6.2,
WebKit 21624 (2026-09-13). The fixture is a login page with three login-form
iframes and an `<all_urls>`, `all_frames: true` content script that says hello
to the worker from every frame it lands in.[^task-4]

| Frame | URL from `getAllFrames` | Chrome's URL | Content script injected | `tabs.sendMessage` with its `frameId` |
|---|---|---|---|---|
| Top document (http) | The page URL | Same | Yes, `frameId` 0 | Reaches it |
| Cross-origin http iframe | Its URL | Same | Yes | Reaches it |
| `srcdoc` iframe | `""` | `about:srcdoc` | **No** | Fails silently |
| `about:blank` iframe filled by its parent | `""` | `about:blank` | **No** | Fails silently |

All four are enumerated, each with a distinct id and a `documentId`, and
`getFrame` resolves all four.

"Fails silently" is exact: the `tabs.sendMessage` callback fires with
`undefined` and **no** `chrome.runtime.lastError`. A caller cannot tell "no
receiver" from "the receiver answered nothing".

Chrome injects into `about:blank` / `about:srcdoc` frames only when the
content script declares `match_about_blank` (or `match_origin_as_fallback`),
matching against the parent's URL. `ExtensionManifest.ContentScript` decodes
`match_about_blank`; nothing in Detour acts on it.

## What that costs a real extension

Signed build, 2026-09-21, 1Password 8.12.26.40, a fixture with a top-level
form and the three iframe kinds:[^task-4]

| Frame | 1Password control in the input | Menu on click |
|---|---|---|
| Top-level form | Yes | Yes |
| Cross-origin http iframe | Yes | **No — nothing happens** |
| `srcdoc` iframe | No | — |
| Script-filled `about:blank` iframe | No | — |

Two open defects follow:

- **No content script in `srcdoc` / `about:blank` frames.**[^task-100] The
  candidate fix is to inject the declared scripts when the manifest asks for
  it and the parent's URL matches, in the extension's content world, and to
  decide whether to report `about:srcdoc` / `about:blank` instead of `""`.
  The security rule for any fix: inject only where Chrome would — the key is
  declared, the match is against the parent's URL with the extension's granted
  host access — and never into a frame whose parent the extension cannot
  access.
- **The inline menu does not open in a cross-origin iframe.**[^task-101] The
  same control on the top-level form works, so the worker, native messaging
  and the port rewrite are fine. Suspects, in order: the menu is an
  extension-page iframe (`web_accessible_resources`) that WebKit may refuse to
  load in a cross-origin subframe, or whose runtime port never connects;
  frame-targeted messaging between the subframe and the top frame;
  `permissions.contains` answering false for the frame's own origin.

A third thing was ruled out. 1Password logs "[Tabs] Could not collect all
frames that were initially found", and the empty-URL frames looked like the
cause. Loading the fixture never produced the line; it appeared once, from
the Private profile's worker on reddit.com. The hypothesis is rejected for
this fixture and the line is unexplained.[^task-102]

## What Detour adds to content scripts

`_detour_content_polyfill.js` is inserted first in every manifest
`content_scripts[].js` list ([Polyfill layer](./polyfill-layer.md)). A content
script has no channel to Swift, so both of its features round-trip through
`runtime.sendMessage` to the background context, where
`contentPolyfillBridgeJS` answers:

| Feature | Path |
|---|---|
| `chrome.i18n.detectLanguage(text)` | Message `{_detourDetectLanguage}` → background → native `i18n.detectLanguage` (`NLLanguageRecognizer`). Falls back to `und`. |
| `webNavigation.onHistoryStateUpdated`, `onReferenceFragmentUpdated` | The script wraps `history.pushState` / `replaceState` and listens for `hashchange`, sends `{_detourWebNav}`; the background dispatches to listeners registered through the polyfill (`__extensionDispatchWebNavEvent`) |

The bridge is installed in whichever context is the background one, worker or
background page (`__detourContextKind`), and nowhere else: two responders
would both answer the same message.

`webNavigationJS` patches the native namespace rather than replacing it. A
native event is wrapped so a listener is registered both natively and in the
polyfill's own list; a missing event gets a pure polyfill emitter. The patched
wrapper is pinned as an own property on `chrome`
([Chrome runtime patching](./chrome-runtime-patching.md)).

# Gotchas

- `chrome` exists only in the extension's content-script world. In a test,
  evaluating `chrome.runtime.sendMessage` in the page world throws; the test
  extensions relay through `window.postMessage`.[^task-20]
- Content-script messaging needs the web view to be a registered tab
  ([Tab and window bridge](./tab-and-window-bridge.md)).
- A message sent while the worker sleeps can be lost with no error.[^task-4]
- The history-state detection has no test. The wrap of `history.pushState` is
  made in the content script's world, so whether it sees the *page's* own
  calls has not been verified. The relayed event carries `frameId` 0 for the
  top frame and -1 for any other.
- The content polyfill is inert in a `MAIN`-world entry: it returns at once
  when `chrome` is undefined.
- Sites on a non-default port needed a separate fix before any frame result
  could be read at all ([Permissions](./permissions.md), "Origin patterns with
  a port").
- The test worker is shared by the whole class, so state it accumulates
  (its list of frame hellos) leaks between repetitions under
  `-test-iterations`; the frame tests clear it and scope hellos to their own
  loopback origin.

# Where it lives

- [ExtensionAPIPolyfill.swift](../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift) — `webNavigationJS`, `webNavigationPageDetectionJS`, `contentPolyfillJS`, `contentPolyfillBridgeJS`.
- [ExtensionPolyfillIntegrationTests](../../DetourTests/ExtensionPolyfillIntegrationTests.swift) — the frame measurements, with loopback HTTP servers (a different port is a different origin).
- [docs/1password-integration-plan.md](../../docs/1password-integration-plan.md), Phase 3 — the full tables and the fixture recipe.

# Related

- [1Password integration](./1password-integration.md) — why iframe autofill matters.
- [Testing extensions](./testing-extensions.md) — the fixture servers and probe tabs.
- [Signed build verification](../playbooks/signed-build-verification.md) — how the 2026-09-21 trial was run.
- [Private profile extensions](./private-profile-extensions.md) — where the unexplained log line came from.

[^task-4]: 1Password: iframe autofill — test the empty-URL hypothesis
[^task-100]: Inject content scripts into srcdoc and about:blank frames (match_about_blank)
[^task-101]: 1Password's inline menu does not open from a form inside a cross-origin iframe
[^task-102]: 1Password's worker in the Private profile throws on page loads
[^task-20]: Un-skip the WKExtensionIntegrationTests runtime messaging tests
