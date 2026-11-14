---
type: Playbook
title: Extension compatibility run
description: "How to run extensions end to end through the automation endpoint (install, drive a popup and a content script, read the console, fetch the compatibility report) and diff the result against a saved baseline, with the script that does it and the traps met doing it."
tags: [extensions, automation, testing, playbook]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-14T09:20:00Z }
sources:
  - id: script
    resource: ../../docs/harness/task2282-compat-run.py
    title: docs/harness/task2282-compat-run.py
  - id: endpoint
    resource: ../features/automation-endpoint.md
    title: Automation endpoint (MCP)
  - id: task-228-2
    resource: backlog:TASK-228.2
    title: "Automation: extension testing tools on the MCP endpoint"
  - id: fixtures
    resource: ../../TestExtensions
    title: TestExtensions (api-explorer, hello-world, vimium)
---

# When to use

You want to know what a real extension does in Detour without a person at
the keyboard: whether it installs and its worker starts, whether its popup
and content scripts work, what it logs, and which APIs, manifest keys and
permissions it uses that Detour lacks; or you changed the extension runtime
and want to see that nothing moved against a baseline. It is the template
for the external test repo's scenarios (TASK-228.2).[^task-228-2] The tools
are described on the [automation endpoint](../features/automation-endpoint.md)
page.

# Steps

1. Build Debug and resolve the app from `-showBuildSettings`
   (`BUILT_PRODUCTS_DIR`), never by globbing DerivedData.
2. Run the script with the sandbox off (it launches an app):

   ```bash
   docs/harness/task2282-compat-run.py "$APP" /tmp/out-1 --vimium
   docs/harness/task2282-compat-run.py "$APP" /tmp/out-2 --vimium --baseline /tmp/out-1
   ```

   It launches the build with its own data directory
   (`DetourCompat2282-<random>`), `DETOUR_MCP=1` and an empty
   `DETOUR_NATIVE_MESSAGING_HOSTS_DIR`, so no extension can reach a real
   native host, serves a fixture page on 127.0.0.1, and cleans up the data
   directory, its WebKit stores (from `browser.db` first), its preferences
   domain and plist and its window keys at the end, also after a failure.[^script]
3. What it drives, all with Detour in the background:
   - `install_extension` for `TestExtensions/api-explorer`, `hello-world`
     and (with `--vimium`) `vimium`, then `wait_for worker_started` each.
   - The fixture in a tab; API Explorer's popup with
     `open_extension_context kind popup`; `call_extension_api
     chrome.tabs.query` in the popup for the tab's WebKit id; then
     `chrome.tabs.sendMessage(id, {type: 'highlight'})` from the popup,
     which API Explorer's content script answers by outlining the page:
     `wait_for` an expression in the tab checks the outline, and the reply
     must be `{highlighted: true}`.
   - A real `click` on the popup's Query All Tabs and `read_page` of its
     result.
   - Per extension: `console_messages extension:<id> stable`,
     `list_extensions stable`, `extension_compat_report`.
4. Read the output. Per extension, `<name>.json` is what a baseline
   compares: the report without `run`, the stable list entry, and the
   console's warning and error lines (sorted, the fixture origin written
   `http://<fixture>`), with the extension's id written `<name>`.
   `<name>.run.json` is the report's `run` (profile id, stub call counts,
   repeat counts) and `<name>.console.txt` every console line; neither is
   compared.
5. With `--baseline`, every difference is printed as a JSON path
   (`api-explorer: $.report.summary.missing_in_worker: 2 items != 3 …`) and
   the exit status is 1.

# The run of 2026-11-14

Debug build of 2b3c1c2, two runs, the second against the first: every check
passed, and `Baseline: no differences`. What the reports said:

| Extension | References | Missing (worker and page) | Stubs referenced | Stubs called | Manifest |
|---|---|---|---|---|---|
| API Explorer | 113 | `bookmarks.getTree`, `tabs.move` | `action.getUserSettings`, `idle.onStateChanged`, `privacy.services`, `storage.managed` | `idle.onStateChanged` (it adds a listener at start) | `commands` unsupported; `bookmarks` unsupported (WebKit drops it); privacy and webRequest stubbed |
| hello-world | 4 | none | none | none | nothing unsupported |
| Vimium | 56 | `bookmarks.getTree`, `runtime.getBrowserInfo` (Firefox's), `tabs.move` | `history.onVisited`, `history.onVisitRemoved` | none | `bookmarks` unsupported |

No runtime errors naming an API were logged in this scenario (the
integration test `AutomationCompatReportTests` covers that part with a
fixture that throws them).

# Traps

- **Keyless extensions get a new id in every new data directory.** A
  reinstall keeps the id within one data directory (AC #10), but a fresh
  one is a first install: the second run's API Explorer had another id, and
  the first diff was all ids. The script writes the id as the folder name;
  a suite can do the same, or give its fixtures a manifest `key`.
- **An extension's own log lines carry run data.** API Explorer logs tab
  ids and the fixture's URL (`tabs.onCreated 108`), Vimium the sender's tab
  id, so whole consoles differ between runs. Compare warnings and errors
  only, or normalise what the scenario controls.
- **The popup does not scroll from script.** WebKit lays an action popup
  out at its content size (API Explorer's is 3617 points tall) inside the
  600-point popover, and `scrollIntoView`, `scrollTo` and `scrollTop` all
  left `scrollY` at 0. The input tools scroll an element into view first,
  so any element below 600 points answers `element_not_visible` (API
  Explorer's Send to Tab field). Drive such a feature with
  `call_extension_api` from the popup, as the script does, or click what is
  in the first 600 points.
- **hello-world's content script never runs** (no `host_permissions`;
  WebKit does not count content-script matches as requested patterns).
  Drive content scripts with API Explorer.
- **Console and stub counts start with automation.** In a test run that is
  at launch, so everything is recorded; with the endpoint turned on in
  Settings mid-session, a worker already running reports neither until it
  restarts.
- **The report starts the worker** (its probe goes through the channel).
  Pass `probe: false` for the static and recorded parts alone.

# Related

- [Automation endpoint](../features/automation-endpoint.md) — the tools, the report's parts and what is stable.
- [Testing extensions](../extensions/testing-extensions.md) — which test level proves what; this is level 5 without a person.
- [Runtime verification](./runtime-verification.md) — launching an isolated build and cleaning up after it.
- [Seeding extensions](./seeding-extensions.md) — the hand-made alternative to `install_extension`.

[^script]: docs/harness/task2282-compat-run.py
[^task-228-2]: Automation: extension testing tools on the MCP endpoint
