---
type: Feature
title: "Automation endpoint: the compatibility report"
description: The automation endpoint's extension_compat_report (TASK-228.2 part 2), which covers the static scan of chrome.* and browser.* references checked in the live worker and a probe page, the polyfill's stub registry and its call counts, API-naming runtime errors, unsupported manifest keys and permissions, worker failures, and the stable output used to diff a run against a baseline.
tags: [automation, mcp, extensions, testing]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:12Z }
sources:
  - id: compat-report
    resource: ../../Detour/Automation/AutomationTools+CompatReport.swift
    title: AutomationTools+CompatReport.swift and AutomationCompatReport.swift (the report, the probe page, the scan)
  - id: stubs
    resource: ../../Detour/Extensions/Runtime/ExtensionPolyfillStubs.swift
    title: ExtensionPolyfillStubs.swift (the stub registry and the counting module)
  - id: webkit-manifest
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/WebExtension.cpp
    title: "WebKit, WebExtension.cpp (the manifest keys it reads, supportedPermissions)"
  - id: task-228-2
    resource: backlog:TASK-228.2
    title: "Automation: extension testing tools on the MCP endpoint"
  - id: compat-tests
    resource: ../../DetourTests/AutomationCompatReportTests.swift
    title: AutomationCompatReportTests
---

`extension_compat_report {extension, profile_id?, probe?, timeout_ms?}`
answers what an extension tried to use that Detour does not have, for a
suite that runs many third-party extensions and diffs each run against a
baseline (TASK-228.2 part 2).[^task-228-2][^compat-report] It is a tool of
the [automation endpoint](./automation-endpoint.md), available whenever the
endpoint is on (not gated to test runs: it installs nothing); `probe: false`
skips the runtime checks. It never wraps or replaces `chrome` or `browser`
([never replace the globals](../decisions/never-replace-chrome-globals.md)),
so nothing an extension sees changes shape; the five parts are built from
what can be read without that. It uses the worker channel and console of
[extension contexts](./automation-endpoint-extensions.md).

# 1. References, checked at runtime

A static scan (`AutomationCompatReport.scan`, off the main thread) reads
the installed copy's `.js` and `.mjs` files (Detour's own `_detour_*` files
and `_metadata/` left out; at most 3000 scripts, 16 MB a file, 160 MB in
all, in path order, `scan.truncated`/`skipped` say what a bound cut) and
counts each `chrome.X.Y` and `browser.X.Y`, also with `?.`, a bracket with
a string (`chrome['scripting']`) or `globalThis.`/`window.`/`self.` before
it. Only the first two segments are kept: `chrome.storage.local.get` is
the api `storage.local`, `chrome.sidePanel` alone the api `sidePanel`. Only
namespaces in Chrome's published list (plus Firefox's and Safari's) count,
which keeps out `chrome.google.com` in a URL and a library's own
`browser.version`. Not followed: aliases (`const api = chrome.storage`),
computed names, and minified code that renamed the global.

Each file gets roles from the installed manifest and the pages: the
worker, `background.scripts` and a background page's scripts are
`background`, manifest content scripts `content_script`, any HTML page's
`<script src>` `page`, followed through `importScripts`, static and dynamic
`import` and `export … from` (relative specifiers only); a file reached from
none of them is `other`. A member missing in the worker matters less when
only a content script names it.

Every referenced api is then checked in two live contexts with the
runner's `probe` command (present, `typeof`, and whether the function, or
an event's `addListener`, is WebKit's own by the `[native code]` test;
for a stub that is an object, such as `storage.managed`, the test reads its
first counted function). Each reference is probed under every global the
extension uses for it, since `chrome` and `browser` can be different objects
and the polyfill fills in `chrome` only:

- **worker**: through the channel, which starts the worker if needed.
  `worker.started` false with `start_error` (`worker_not_running`,
  `timeout`) when it did not answer; its column is then `not_checked`.
- **page**: a probe page of the report's own, `_detour_probe.html`, an
  empty document written into the installed copy (WebKit reads an
  extension's resources from disk when they are requested, so a file
  written after load is served) and loaded in a hidden web view from the
  context's configuration, so the polyfill runs in it and none of the
  extension's scripts do; closed once it answered. Its console and stub
  calls are not the extension's (`probe` context kind, never recorded).
  Content scripts' surface is not checked: nothing reaches their world.

Status per context: `available`, `missing` (the namespace or the member is
not there; a member present with the value undefined, like
`runtime.lastError`, counts as there), `stubbed` (in the stub registry and
not WebKit's own function), `not_checked`.

# 2. Stubs and their calls

`ExtensionPolyfillStubs` is the one registry of the polyfill's stand-ins
(read from `ExtensionAPIPolyfill`, November 2026):[^stubs] `privacy.services`
(settings read false, set does nothing), `privacy.network`/`websites`
(empty), every `webRequest` event and `handlerBehaviorChanged`,
`action.getUserSettings` (always on the toolbar), `storage.managed` (no
policy source), `sessions.getRecentlyClosed`/`getDevices` (always `[]`) and
`sessions.onChanged`, `idle.onStateChanged`, `notifications.onButtonClicked`,
`history.onVisited`/`onVisitRemoved` (TASK-146), `history.getVisits` and its
no-op writers, and the four `management` events. `notifications.onClicked`
and `onClosed` are not stubs (delivered since TASK-247). A module that
starts delivering an event leaves the list in the same change.

The polyfill's counting module (`countingModuleJS`, after every module that
defines a stub, before the automation channel) wraps each registry function
that is the polyfill's own, on the polyfill's objects or a native wrapper
the polyfill already patched and rooted (`chrome.action`), keeping `this`,
the arguments, the result and the `_detourPolyfill` marker. Calls of one
task go in one batch, `automation.stubCalls`, from any extension context
(not content scripts, which run no bundle). The handler keeps registry
paths only, per extension, profile, path and context kind
(`AutomationExtensionStubCalls`), and answers `stop` while automation is
off or in the Private profile while Private access is not allowed: the
context then stops sending for its lifetime, so with the endpoint off the
cost is one request per context that calls a stub. The request is an
`automation.` one and is not the worker's activity. Counts start in the
same turn as the channel opens, so a worker's start-up calls count; the
report waits 300 ms after its probes for the batch the probe's own worker
start sent. More on the module: [polyfill layer](../extensions/polyfill-layer.md).

# 3. Runtime errors

The extension's recorded console (every context, uncaught errors and
rejections included) is searched for JavaScriptCore's wording of a missing
API: "undefined is not an object (evaluating 'chrome.sidePanel.open')",
"chrome.x.y is not a function. (In 'chrome.x.y()', 'chrome.x.y' is
undefined)", "Can't find variable: chrome". Each is reported once per api,
expression and error name, with the contexts it came from and one message
line (from the error's name on, origins normalised); repeats are counted in
`run`. A chain that is a prefix of a longer one in the same text is folded
in; Detour's own `[Detour polyfill]` warnings and unchecked lastError lines
are skipped; a minified alias (`e.sidePanel.open`) names no global and is
not attributed. Content scripts' errors never reach the console bridge.

# 4. The manifest

Top-level keys (`manifest.keys`, only those not plainly supported, and
`supported_keys`), from what WebKit's parser reads (`WebExtension.cpp` on
main, read 2026-11-14)[^webkit-manifest] and what Detour reads itself (`key`,
`update_url`): `unsupported` (WebKit parses `commands`, but Detour never calls
`performCommand(for:)`, so shortcuts do not run; `chrome_url_overrides`;
`side_panel` on this build; `incognito`, which Detour's per-profile switch
replaces; `omnibox` and the other Chrome-only keys), `ignored`
(informational: `minimum_chrome_version`, `author`, …), `unverified`
(`devtools_page`, `icon_variants`) and `unknown`. API permissions are
`supported` when WebKit kept them (its live `requestedPermissions` and
`optionalPermissions`, which drop names it does not support, so this
follows the installed WebKit), `polyfill` (history, management,
notifications, idle, fontSettings, sessions, search, offscreen, favicon),
`stubbed` (privacy; webRequest, whose listeners never fire although WebKit
keeps the name), `ignored` (`background`) or `unsupported`. Host patterns
WebKit refuses are listed, and `WKWebExtension.errors` as `warnings`.

# 5. The worker

`background` (service_worker, service_worker_module, scripts, page, none),
whether it answered the probe, whether a `backgroundContentFailedToLoad` was
recorded this session (`failed_to_load`), whether
`Profile.recoverFromBackgroundLoadFailure` reloaded it
(`recovery_attempted`; `ExtensionErrorLog.recordRecovery` counts them), and
its load errors (normalised, once each; counts in `run`).

# Diffing against a baseline

Everything outside the report's `run` object is stable over the same files:
arrays sorted, no timestamps, no profile ids, extension origins written
`webkit-extension://<extension id>` (a context's base URL is new at every
load), paths relative to the extension's root and the installed folder
removed from messages. `run` holds `profile_id`, the stub call counts, error
and load-error repeat counts, recovery attempts, and how many console
records were read. `summary` gathers the short lists worth diffing
first (`missing_in_worker`, `missing_in_page`, `stubbed_referenced`,
`stubs_called`, `runtime_error_apis`, `unsupported_manifest_keys`,
`unsupported_permissions`, `worker_started`). Whether a stub was called and
which errors appear depend on the scenario, not on timing, as long as the
scenario drives the same code.

The other tools have a `stable: true` form for the same purpose:
`list_extensions` drops profile ids (profiles sorted by name),
`worker_parked`, `open_contexts` and repeat counts, lists load errors once
each, sorted, and normalises origins in messages; `console_messages` drops
each entry's `seq` and `timestamp` and normalises origins (an extension
context's records with its own id; a tab's with the id of the loaded
context that has that origin, else `unknown`). Console entries keep their
order of arrival, which between two contexts can change from run to run,
so a baseline is better kept as a sorted set of lines (the playbook's
script does that). `next_seq`, `dropped` and `capturing` are cursor state,
never compared.

[Extension compatibility run](../playbooks/extension-compat-run.md) is the
end-to-end playbook, with `docs/harness/task2282-compat-run.py`.

# Tests

`AutomationCompatReportTests` (the scan's reference forms, imports, roles,
Detour files, bounds and order; manifest keys and permissions;
JavaScriptCore error messages; origin normalising; the registry; a report
for a real extension with references checked in the worker and the probe
page, a stub called from the worker and from the popup, TypeErrors from a
caught and an uncaught error, unsupported keys and permissions, two reports
equal outside `run`, `probe: false`; an unknown and a turned-off extension,
a closed channel; the counts' handler taking registry paths only and
answering stop; `stable` list and console).[^compat-tests]

# Related

- [Automation endpoint (MCP)](./automation-endpoint.md): the hub.
- [Extension contexts](./automation-endpoint-extensions.md): the worker
  channel and the console the report reads.
- [Extension compatibility run](../playbooks/extension-compat-run.md): the
  report end to end.
- [Polyfill layer](../extensions/polyfill-layer.md): the stubs and the
  counting module.

[^task-228-2]: Automation: extension testing tools on the MCP endpoint
[^compat-report]: AutomationTools+CompatReport.swift and AutomationCompatReport.swift (the report, the probe page, the scan)
[^stubs]: ExtensionPolyfillStubs.swift (the stub registry and the counting module)
[^webkit-manifest]: WebKit, WebExtension.cpp (the manifest keys it reads, supportedPermissions)
[^compat-tests]: AutomationCompatReportTests
