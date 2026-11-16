---
type: Feature
title: "Automation endpoint: extension contexts"
description: The automation endpoint's extension tools (TASK-228.2 part 1), covering how an extension and its popup, options, worker and extension-wide contexts are addressed, how the endpoint opens a popup, the parked-request channel into a service worker and why it was chosen over a port or a listener, the extension console, the load-error log, and the traps (inert content scripts, real native hosts, a popup that does not scroll, a popup's profile in the test host).
tags: [automation, mcp, extensions]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:12Z }
sources:
  - id: task-228-2
    resource: backlog:TASK-228.2
    title: "Automation: extension testing tools on the MCP endpoint"
  - id: extension-tools
    resource: ../../Detour/Automation/AutomationTools+Extensions.swift
    title: AutomationTools+Extensions.swift (addressing, the extension tools)
  - id: channel
    resource: ../../Detour/Automation/AutomationExtensionChannel.swift
    title: AutomationExtensionChannel.swift (the channel into an extension's background, the command runner)
  - id: extension-tests
    resource: ../../DetourTests/AutomationExtensionTests.swift
    title: AutomationExtensionTests and AutomationExtensionChannelTests
---

What TASK-228.2 (part 1) adds to the [automation
endpoint](./automation-endpoint.md), for a suite that installs third-party
extensions and drives them: installing and managing them in a test run, and
their popup, options page and service worker as contexts the same tools
reach.[^task-228-2][^extension-tools] The tools' arguments are in [the
tools table](./automation-endpoint-tools.md); the per-extension
[compatibility report](./automation-endpoint-compat-report.md) builds on
this page.

# Addressing

An extension is named by its id, or by its exact manifest name (localised
or as written, ignoring case): two with that name are
`ambiguous_extension`, none `unknown_extension`. Ids survive relaunch, and
a reinstall of the same folder keeps a keyless extension's random id (the
install passes Reload's `forcedID` when an installed unpacked extension came
from that folder), so a scenario's saved id still resolves.

A context is `<kind>:<extension>`, with `@<profile uuid>` appended when the
extension is on in more than one normal profile (else
`ambiguous_profile`); only a UUID after the last `@` counts, so a name with
an `@` still reads as a name. Off in every profile is
`extension_disabled`. The Private profile is never an install, turn-on or
permission target (`private_unreachable`); its contexts are listed and
reached only while Private access is allowed, and only when named with
`@<its id>` (see [Private windows](./automation-endpoint-private-windows.md)).
Extension contexts go in the same `context` argument as tabs
(`resolvePageTarget`).

| Context | What it is | Tools |
|---|---|---|
| `popup:<ext>` | The action popup the endpoint opened (or one the extension opened with `action.openPopup()`), while it is up; else `context_not_open` | `evaluate_js`, `read_page`, `wait_for`, `click`, `type_text`, `press_key`, `screenshot`, `call_extension_api`, `read_extension_global`, `console_messages` (also after it closed) |
| `options:<ext>` | The tab of one of the profile's spaces showing the options page (`existingOptionsPageTab`); `unsupported_context` without an options page | The same; input needs it shown in a window (`open_extension_context` with `window_id`) |
| `worker:<ext>` | The background service worker, or background page | `call_extension_api`, `read_extension_global`, `console_messages`, `wait_for` with `worker_started`; every page tool is `unsupported_context` |
| `extension:<ext>` | Every context of the extension | `console_messages` only |
| `sidepanel:<ext>` | No side panel on `main` (only the epic branch has them) | `unsupported_context` everywhere |

# The popup

`AutomationExtensionPopups` opens it with an `ExtensionPopoverController`
built for the profile and the window's active tab, anchored where a click
on the extension's button would anchor it (its pinned button in the
address bar, else the address bar, else the content's top right when the
sidebar is hidden), and `show` records the user gesture a click records, so
`activeTab` works. An extension whose action has no popup for the tab is
`unsupported_context`: `show` would fire `action.onClicked` instead.
`show` reloads the popup and presents the popover once the page has loaded
(or after 0.5 s); `wait_for load` covers that. The popover is in its own
window, a child of the browser window, so input goes there and results name
the browser window. All of it works with Detour in the background (checked
at runtime: popups opened, clicked, typed into and captured while another
app was active). A popup a person opened from the toolbar is not tracked
and not reachable. Input by `context` into a popup over a Quick Detour or
quarantine window is a known gap (see [window
kinds](./automation-endpoint-windows.md#menus-and-child-windows)).

# The worker channel

Nothing public evaluates script in an extension's service worker, and an
MV3 worker's CSP forbids `eval` and `new Function`, so `worker:` takes
commands, not code: call the function at a path with JSON arguments, read
the value at a path, or ping.[^channel] The polyfill bundle's last module
(background contexts only) parks a request, `automation.awaitCommand`, as
`notifications.awaitEvent` does ([notification events](../extensions/polyfill-notification-events.md)).
The endpoint answers it with a command; the worker acknowledges it at once
(`automation.ack`), parks again, runs it, and sends the result
(`automation.result`). So a call that never settles holds up nothing else,
and several run side by side.

Why this channel and not another:

- A `runtime.onMessage` listener would be seen by the extension's own
  listeners. A Proxy on, or a replacement of, `chrome`/`browser` is never
  done ([never replace the globals](../decisions/never-replace-chrome-globals.md)).
- A native port would push without parking, but opening and closing ports
  changes how long WebKit keeps the background alive and can make it forget
  another port (TASK-141), which would skew a compatibility run. A pending
  native-message reply is not activity and touches no port bookkeeping
  ([service worker unload rules](../platform/service-worker-unload-rules.md)).
- A hidden extension page relaying through `chrome.*` runs in a page, not
  in the worker, and cannot read the worker's globals.

What follows from parking:

- **A park keeps nothing alive, and a dead one is silent.** WebKit unloads
  an idle background after about 30 s and says nothing; a reply to the dead
  worker's park goes nowhere. A delivered command must be acknowledged
  within 1.5 s; if it is not, the background is started
  (`loadBackgroundContent`) and the command goes to the new worker's park,
  up to three times. A call to an unloaded worker therefore takes about
  1.7 s (measured at runtime: the worker's polyfill lines appeared again in
  its console).[^task-228-2] With no park at all the background is started
  at once.
- **A worker that restarted mid-command** loses the command, which is not
  run twice: the call answers `worker_not_running`. A late acknowledgement
  of a command already sent again is honoured, and the worker skips an id it
  has seen.
- **The channel is open while the endpoint is on.** `AutomationController`
  opens it in the same main-actor turn as the launch's start, before any
  worker's first message is handled, so every background parks in a test
  run. A worker that started while automation was off was answered `stop`
  and parks again only at its next start: turning the endpoint on in
  Settings leaves running workers unreachable until they cycle
  (`worker_not_running`, whose message says so). Stopping the endpoint
  stops every park and fails what waits.
- **Who may park.** Only the verified extension's background context
  (`senderIsBackgroundContext`), in the Private profile only while Private
  access is allowed; a page that tries is refused (tested from an options
  page). The extension's own code in its worker could still call the
  request itself and answer its own commands; a test of that extension
  accepts that. The channel's requests do not count as the extension's
  background activity (which delays updates, TASK-123).
- **Cost when automation is off:** one `automation.awaitCommand` round trip
  per worker start, answered `stop`.
- **What a call can do:** `call` invokes the function on the object holding
  it (`this` is `chrome.storage.local` for `chrome.storage.local.get`),
  promise form only (a callback-only API gets no callback); `get` does not
  await. Results go through the same serialiser as `evaluate_js`.
  `worker_not_running` when no live background took the command in time,
  `timeout` when it took it and did not finish.

# The console of extension contexts

`console_messages` on an extension context reads what the polyfill's
[console bridge](../extensions/console-bridge.md) forwards, kept by
`AutomationExtensionConsole` per extension and profile while the endpoint is
on (ring of 1000, one `seq` for all the extension's contexts, the same entry
shape as a tab's plus `context_kind` and `context`). The bridge sends the
console method (`consoleLevel`: `log` still reaches os_log as info), an
`origin` (`uncaught`, `unhandledrejection`) and an error's stack and
location. The kind comes from the sender: the native-message bridge or the
background page's frame is `worker`, a tracked popup web view `popup`, a web
view showing the options page `options`, anything else `page`. It is
recorded before the os_log path's native cap, but the bridge's in-page
limiter still applies: past a burst of 50 messages, about 20 a second, with
repeats folded into "(repeated N times)"; `console.debug` is not bridged,
and content scripts have no bridge. The options page's tab is not captured
by [page capture](./automation-endpoint-page-tools.md) (it is built from
the extension's configuration), so read it as `options:<ext>`, not
`tab:<id>`. Recording starts in the same main-actor turn as the channel
opens, before the listener is ready (since TASK-228.2 part 2; before, it
started once listening), so a worker that starts at launch keeps its
start-up errors too.

# Load errors

`ExtensionErrorLog` keeps, per extension and this session, every error
WebKit reported when reading the installed files (at launch or after an
install), when the controller refused a context, and every context error it
posted (`errorsDidUpdateNotification`, a background that failed to load
among them), deduplicated with a count and cut at 50; forgotten on
uninstall. Before, all of these were only logged. A recovery reload clears
`context.errors`, so the copy is what tells a run that a worker failed at
all. `WKWebExtension.errors` (manifest warnings) is read live.
`list_extensions` reports both.

# Traps

- **A content script needs site access the manifest does not grant.**
  hello-world declares `content_scripts` matching `<all_urls>` and no
  `host_permissions`; WebKit does not count content-script matches as
  requested patterns, so its content script ran on no page, and
  `set_extension_permission` for `<all_urls>` was saved but inert (its
  warning said so). An extension with matching `host_permissions` (API
  Explorer) is fine.[^task-228-2]
- **A CRX that uses native messaging reaches the real host.** Installing the
  store's 1Password CRX started its worker at once, and it connected to the
  installed 1Password app's browser helper (which refused the unsigned
  Debug build and exited). Point `DETOUR_NATIVE_MESSAGING_HOSTS_DIR` (Debug
  builds) at an empty folder for such runs; with it the same install
  connected to nothing.
- **A popup taller than its popover does not scroll from script.** WebKit
  lays the popup out at its content size inside the 600-point popover;
  `scrollIntoView`, `scrollTo` and `scrollTop` left `scrollY` at 0 (API
  Explorer, 3617 points tall), so the input tools answer
  `element_not_visible` for anything below 600 points. Whether a person's
  scroll wheel scrolls it was not checked. Use `call_extension_api` or
  `evaluate_js` for such elements.
- **A popup's profile must outlive the test.** Releasing a profile whose
  controller hosted a popup traps in `WKProcessPool` dealloc, in whichever
  suite runs next; `AutomationExtensionTests` keeps its profiles alive
  ([WebKit test host traps](../platform/webkit-test-host-traps.md)).
- **A command that never settles** (a promise left pending) used to hold the
  worker's only park, so every later call answered `worker_not_running`;
  the result now travels in its own request and the worker parks again at
  once.

# Tests

`AutomationExtensionTests` (the management tools refused outside a test
run; install from a folder, list and address by id or name, ambiguity, a
reinstall keeping the id; no manifest, a bad manifest, a bad CRX, a
relative path, the Private and an unknown profile refused; the worker
answering calls, reads and its console, a never-settling call timing out
and not blocking the next, a closed channel; the popup driven with
`evaluate_js`, `read_page`, `call_extension_api`, `click`, console and
`screenshot`, then closed; the options page in the background and in a
window, and a page refused the channel; turning on and off per profile and
globally, permission decisions with their warnings, uninstall; side panels,
unknown extensions and two profiles) and `AutomationExtensionChannelTests`
(the channel by hand: delivery and results, side-by-side commands, a wake
with no park, a dead park's command sent to the next start, supersession, a
restart mid-command, another extension unable to answer, unload and
stop).[^extension-tests]

# Related

- [Automation endpoint (MCP)](./automation-endpoint.md): the hub.
- [Compatibility report](./automation-endpoint-compat-report.md): what an
  extension uses that Detour lacks.
- [Extension compatibility run](../playbooks/extension-compat-run.md): the
  extension tools end to end, with a baseline diff.
- [Seeding extensions](../playbooks/seeding-extensions.md) and [testing
  extensions](../extensions/testing-extensions.md): other ways to get an
  extension into a run.

[^task-228-2]: Automation: extension testing tools on the MCP endpoint
[^extension-tools]: AutomationTools+Extensions.swift (addressing, the extension tools)
[^channel]: AutomationExtensionChannel.swift (the channel into an extension's background, the command runner)
[^extension-tests]: AutomationExtensionTests and AutomationExtensionChannelTests
