---
type: Playbook
title: Signed-build verification
description: How to check extension behaviour that only works in the signed build installed in /Applications (real 1Password, native messaging trust) — deploy, capture the log, drive the session with a person, and read the result.
tags: [playbook, extensions, 1password, verification, release-build]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:44:19Z }
sources:
  - id: deploy-script
    resource: ../../scripts/deploy-1password-test.sh
    title: deploy-1password-test.sh
  - id: plan-doc
    resource: ../../docs/1password-integration-plan.md
    title: 1Password integration plan (production results, log filters)
  - id: task-21
    resource: backlog:TASK-21
    title: Verify the native keep-alive and the WebSocket relay in the signed build
  - id: task-71
    resource: backlog:TASK-71
    title: Which chrome.offscreen implementation runs in the signed build
  - id: task-90
    resource: backlog:TASK-90
    title: 1Password worker stuck in a reconnect loop
  - id: api-explorer
    resource: ../../TestExtensions/api-explorer
    title: API Explorer test extension
  - id: notes-signed
    resource: "Agent session notes, 2026-09-21 (not in the repository)"
    title: Session notes on a signed-build verification session
  - id: notes-1password
    resource: "Agent session notes, 2026-09-13 (not in the repository)"
    title: Session notes on the 1Password integration
---

Some behaviour cannot be verified in a Debug build or an isolated profile.
The 1Password desktop app only talks to a browser it trusts, and its trust
is a code-signing requirement (the signing team) plus the `/Applications`
path, not a build hash.[^notes-1password] A DerivedData Debug build fails
that check. So the last step for native messaging, keep-alive, relay and
tracking-prevention fixes is a session in the signed Release build
installed in `/Applications`, with a person driving the parts an agent
cannot (unlocking, popups, biometric prompts).

# When to use

- A change to native messaging, the keep-alive, the WebSocket relay,
  extension data stores or tracking prevention has passed its tests and an
  isolated harness run, and its acceptance criteria name "production" or
  "the signed build".
- A bug reproduces only with the real 1Password extension and desktop app.

Do the harness run first ([seeding extensions](./seeding-extensions.md)
with a fake native host). A signed-build session costs a person's time and
replaces their installed browser.

# Steps

## 1. Agree the session with the person

[scripts/deploy-1password-test.sh](../../scripts/deploy-1password-test.sh)
does this, in order: `xcodegen generate`, a Release build, a Developer ID
`codesign` with the hardened runtime, **`killall Detour`**, **delete and
replace `/Applications/Detour.app`**, launch it. It quits every running
Detour and overwrites the installed app. It needs the signing identity in
the keychain. An agent does not run it on its own initiative: the person
runs it, or says to.

Because the trust record is not a build hash, a rebuilt and redeployed app
needs no new approval in 1Password.[^notes-1password]

## 2. Preconditions

- The 1Password desktop app is **running and unlocked before** Detour
  starts. Otherwise each worker connects to the browser-support host, gets
  no app, and drops the host after 10 seconds, and the keep-alive
  correctly disarms; the run tells you nothing.[^task-21]
- Extension console text is public for the session
  (`defaults write com.detourbrowser.mac ExtensionConsoleLogPublic -bool YES`
  before launch; delete the key afterwards), or 1Password's own lines read
  `<private>`. See [reading runtime logs](./reading-runtime-logs.md).
- If the question involves the Private profile: the extension is allowed
  in Private in Settings
  ([private profile extensions](../extensions/private-profile-extensions.md)).
- Note the commit the build was made from, the app's pid and launch time,
  the extension version and the macOS version. Results without them cannot
  be compared later.

## 3. Start the capture before the first interaction

The script's own `--log` option is too narrow (it leaves out
`extension-manager` and `websocket-relay` and does not request info
level).[^task-21] Capture with:

```bash
/usr/bin/log stream --level info --process Detour --predicate \
  'category == "extension-manager" OR category == "native-messaging" OR category == "websocket-relay" OR category == "extension-idle" OR category == "EXT-LOAD" OR category == "EXT-ITP" OR category == "extension-polyfill" OR category == "Extensions"' \
  > "$OUT/session.log" &
```

(sandbox off, in the background). WebKit's unload and worker lines are not
in that predicate. Fetch them afterwards for the interesting window:

```bash
/usr/bin/log show --info --start '2026-09-21 01:26:00' --end '2026-09-21 01:27:00' --predicate \
  '(process == "Detour" OR process == "com.apple.WebKit.Networking") AND (eventMessage CONTAINS "WebPageProxy::close" OR eventMessage CONTAINS "SWServerRegistration::clear" OR eventMessage CONTAINS "terminateWorker" OR eventMessage CONTAINS "loadServiceWorker" OR eventMessage CONTAINS "runRegisterJob")'
```

Whole seconds only in `--start` / `--end`.

## 4. Fixture pages, if forms are involved

There is no fixture in the repository. The one that was used: a page with
four login forms (top level, a cross-origin `http` iframe, a `srcdoc`
iframe, and a script-filled `about:blank` iframe) served by two
`python3 -m http.server` instances on different loopback origins
(`127.0.0.1:<port>` and `localhost:<port>`), so the iframe is genuinely
cross-origin.[^notes-signed] Binding a port needs the sandbox off. What
those cases exercise is on
[frames and content scripts](../extensions/frames-and-content-scripts.md).

## 5. Run the checks

| Check | Do | Passing evidence |
|---|---|---|
| Keep-alive holds | leave 1Password unlocked for at least 15 minutes | one `Keep-alive port opened` per profile, `Keep-alive armed … 1 native host(s) connected`, a reply to every 30 s ping, and zero `disarmed`, `port closed`, `superseded`, recovery, `SWServerRegistration::clear`, `runRegisterJob`, `terminateWorker` lines[^task-21] |
| Idle unload after hosts go | bring hosts to zero (below) | `Keep-alive disarmed … no native host connected`, WebKit `WebPageProxy::close` 30 s later, then on the next event `loadServiceWorker` and a clean start with no code-6 load failure and no recovery[^task-21] |
| Relay | unlock, wait | `Relaying a WebSocket for <id>` then `Relayed WebSocket open`, none closed[^task-21] |
| Live push | change a vault item on another device | every worker logs `[Syncer] Sync started … reason code: 7` within about 200 ms, with no local trigger before it[^task-21] |
| Relay echo | API Explorer's WebSocket (Relay) panel against a public echo server | text and binary echoed, close code 1000, `wasClean` true[^task-21] |
| No host leak | after reconnects, `ps` the browser-support children of Detour | exactly one per connected profile[^task-21] |
| Tracking prevention | watch the first minutes after launch | `ITP: logged user interaction for <id> origin <uuid>` before the Networking pass, no `SWServerRegistration::clear` after `deleteAndRestrictWebsiteDataForRegistrableDomains`[^task-90] |
| Which `chrome.offscreen` | read the worker start lines | `[Detour polyfill] chrome.offscreen implementation: polyfill`[^task-71] |

**Getting native hosts to zero.** Locking 1Password does not do it (the
browser-support process stays connected) and quitting the desktop app does
not either (the extension relaunches it and restarts its workers). What
works: in one profile, turn off "Integrate with 1Password app" in the
extension's own Settings > General. The other profiles are the control.
Expect `Disconnected from Desktop app due to ExtensionSupportDisabled`,
`NM EOF`, the disarm, and the unload 30 seconds later.[^task-21]

## 6. Record and clean up

- Put timings and the exact lines in the Backlog task; update
  [docs/1password-integration-plan.md](../../docs/1password-integration-plan.md)
  where it keeps production results.
- State what was not exercised.
- `defaults delete com.detourbrowser.mac ExtensionConsoleLogPublic`.
- Stop the stream and the fixture servers.

# Traps

- **Lines with no profile.** Keep-alive lines do not name the profile;
  tell workers apart by base URL or by `connectNative … in profile X`.[^notes-signed]
- **`armed: 1 native host(s)` with integration off.** A relayed WebSocket
  counts as a host; the notifier socket reopening after an unlock re-arms
  the keep-alive.[^task-21]
- **`superseded by a newer one` right after an unload** is expected.
- **API Explorer noise.** Its `example.invalid` relay probe at every worker
  start logs a hostname failure and a 1006 close.[^task-21]
- **Counting hits with grep.** A count of 1 for a string that is in the
  predicate is the stream's header line.[^notes-signed]
- **A first run that proves nothing.** If the desktop app was not running,
  discard the run instead of interpreting it.[^task-21]
- **Missing info-level lines in a later `log show`** are not evidence of
  absence.[^task-71]
- **1Password's options page.** The extension declares none, so Detour
  shows no Options entry for it; its settings open from its own popup.
  See [popup and options UI](../extensions/popup-and-options-ui.md).
- **Trust failures look like connection failures.** The browser-support
  process's own log says `parent browser was not valid` or
  `UnsupportedBrowser` when the caller is not the trusted signed app.[^notes-1password]

# Related

- [Reading runtime logs](./reading-runtime-logs.md) — categories, levels, predicates.
- [Diagnosing extension problems](./diagnosing-extension-problems.md) — what a failing line means.
- [1Password integration](../extensions/1password-integration.md) — what is being verified and why.
- [Native port keep-alive](../extensions/native-port-keep-alive.md), [WebSocket relay](../extensions/websocket-relay.md), [data store and ITP](../extensions/data-store-and-itp.md) — the mechanisms.
- [Release and website](./release-and-website.md) — the other script that builds a signed app.

[^task-21]: TASK-21
[^task-71]: TASK-71
[^task-90]: TASK-90
[^notes-signed]: Session notes on a signed-build verification session
[^notes-1password]: Session notes on the 1Password integration
