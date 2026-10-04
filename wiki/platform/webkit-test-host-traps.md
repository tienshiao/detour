---
type: Platform Quirk
title: WebKit test host traps
description: WebKit and macOS behaviours that crash the DetourTests host, make it eat memory, or let a test run write into the installed app's data — and the guard the project has for each.
tags: [webkit, tests, storage, crashes, isolation]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:30:18Z }
stale_after: 2027-04-01T00:00:00Z
sources:
  - id: task-36
    resource: backlog:TASK-36
    title: Stop the test host writing WebKit data into the production app's WebKit directory
  - id: task-41
    resource: backlog:TASK-41
    title: Stop the test host writing the production app's UserDefaults and starting Sparkle
  - id: task-122
    resource: backlog:TASK-122
    title: A background tab whose load fails never shows the error page
  - id: notes-crash
    resource: "Agent session notes, 2026-09-13 (not in the repository)"
    title: Test host crash on process pool release; runaway test host memory
  - id: storage-scope
    resource: ../../Detour/Browser/WebKitStorageScope.swift
    title: WebKitStorageScope.swift
  - id: defaults-scope
    resource: ../../Detour/Browser/UserDefaultsScope.swift
    title: UserDefaultsScope.swift
  - id: test-setup
    resource: ../../DetourTests/TestEnvironmentSetup.swift
    title: TestEnvironmentSetup.swift
  - id: popup-tests
    resource: ../../DetourTests/ExtensionMenuPopupDecisionTests.swift
    title: ExtensionMenuPopupDecisionTests.swift
  - id: wiring-tests
    resource: ../../DetourTests/ExtensionPolyfillProfileWiringTests.swift
    title: ExtensionPolyfillProfileWiringTests.swift
  - id: unclaimed-tests
    resource: ../../DetourTests/BrowserTabUnclaimedNavigationTests.swift
    title: BrowserTabUnclaimedNavigationTests.swift
---

The `DetourTests` bundle runs inside the app itself: the test host is
`Detour.app`, with the app's bundle identifier, a real `TabStore.shared`, and
real WebKit processes. That is what makes integration tests against real
extension contexts possible. It also means WebKit's process-lifetime rules
and macOS's per-bundle-id storage apply to the test run. Each trap below cost
real time once.

# Behavior

## Crashes

**Releasing a process pool inside an IPC dispatch traps.** WebKit traps in
`IPC::MessageReceiverMap::invalidate`, reached from `~WebProcessPool` ←
`-[WKProcessPool dealloc]` ← `~WebProcessProxy`, when a
`WKWebExtensionController`'s process pool is freed from inside an IPC
dispatch.[^notes-crash]

- Trigger: a test makes an extension controller host a web view of its own
  (reading `action.popupWebView` creates the popup in the controller's own
  configuration), then the test's tear-down releases the `Profile`. The pool
  dies with the popup's web process.
- The crash lands one or two seconds later, **in whichever suite runs
  next**, so the failing test name points at the wrong code.[^notes-crash]
- `xcodebuild` reports it as `** TEST FAILED **` after a summary line with
  zero failures — see [test host crashes](../playbooks/test-host-crashes.md)
  for how to recognise and decode that.

**Adding the same `WKUserScript` object twice traps.** `EXC_BREAKPOINT`
inside `WebUserContentControllerProxy::addUserScript`. A test that removes
and re-adds scripts to reorder them must build fresh `WKUserScript`s from the
old ones' source, injection time and main-frame flag. `WKUserScript` does not
expose its content world, so only page-world scripts can be rebuilt this way.

## Runaway memory

**`WKUserContentController.userScripts` is a live view.** The bridged array
tracks the controller. A loop that iterates it while adding scripts grows the
array it is iterating and never ends; one such loop took a test host from
337 MB to 36 GB in 90 seconds.[^notes-crash] Snapshot the scripts into plain
Swift values before mutating anything.

More generally: never create web views or user scripts once per poll
iteration in a waiting loop.

## Loads that do not behave like failures

**A restricted port never fails.** `http://127.0.0.1:1/` looks like a
guaranteed connection-refused, but port 1 is on WebKit's restricted-port
list (1, 7, 9, …). WebKit refuses it itself: it commits `about:blank` and
calls `didFinish`, with no failure callback at all.[^task-122] A test that
needs a real failure binds a loopback port, closes it, and loads that port
(refused at once, nothing leaves the machine); a test that needs a load to
stay provisional holds a listening socket that never answers.

**A load that must never finish** is done with a custom scheme handler that
holds one subresource open (`StallingSchemeHandler` in
[FaviconLinkBridgeTests.swift](../../DetourTests/FaviconLinkBridgeTests.swift)),
not with a slow server.

## Storage shared with the installed app

WebKit and AppKit key persistent storage by bundle identifier, not by
Detour's data directory. `DETOUR_DATA_DIR` (set to `DetourTests` for the test
scheme in `project.yml`) moves only Detour's own databases.

| Storage | Keyed by | What went wrong |
|---|---|---|
| `WKWebsiteDataStore(forIdentifier:)` directories and persistent `WKWebExtensionController` directories, under `~/Library/WebKit/<bundle id>/` | bundle id + identifier | Every test profile created a pair of directories in the installed app's WebKit directory and nothing removed them: 4,976 data store and 3,408 extension directories, about 3.2 GB, had accumulated[^task-36] |
| `WKContentRuleListStore.default()` | bundle id | Tests compiled into, and refreshed, the installed app's rule lists[^task-36] |
| Standard `UserDefaults` domain | bundle id | Window frame and split view autosave keys, and Sparkle's `SU*` keys, were written by test runs; the app restores its window from those keys at launch[^task-41] |
| Sparkle updater | process | `SPUStandardUpdaterController` started in the test host and could schedule or perform update checks[^task-41] |
| WebKit's default persistent store, `URLSession.shared` cookies and cache | bundle id | Shared, but fixed-size and never browsed in by the app; left as is[^task-36] |

Two further WebKit facts found while fixing this:

- **WebKit refuses to remove a data store that is still in use**, and an
  extension controller retains its store. A store released by every owner
  became removable after 0.27 s in a probe. Longer retries (about 32 s) and
  removing all website data between attempts changed nothing — a store that
  stays "in use" is a real leak in the test or the app.[^task-36]
- **The error text is not diagnostic.** WebKit said "in use (by network
  process)" even while UI-process objects still held the store.[^task-36]

The leaks behind those refusals were ordinary retain cycles: undo actions
capturing spaces (and so profiles), and a restored favourite's favicon
callback capturing its profile strongly. The second was a real app bug, since
it kept a deleted profile's store in use.[^task-36]

# Why it matters here

- A crash blamed on the wrong suite, or a "failed with 0 failures" run, sends
  people looking for a bug in code that is fine.
- Tests run on machines where the app is also installed and may be running.
  Writing its window geometry, update schedule, rule lists or gigabytes of
  WebKit directories is damage outside the repository.
- Profile deletion removes WebKit storage from disk
  ([profile data removal](../architecture/profile-data-removal.md)). A run
  in a non-default data directory must be provably unable to remove the
  installed app's storage.

# Workaround

## Process pool trap

In any suite whose profiles' extension controllers hosted a web view: close
the popup (`action.closePopup()`), unload the extensions and remove the
profile from the store as usual, then **keep the `Profile` object alive for
the rest of the process** in a static array. Only the object outlives the
test; the context is unloaded and the store row removed. The pattern is
`retainedProfiles` in
[ExtensionMenuPopupDecisionTests](../../DetourTests/ExtensionMenuPopupDecisionTests.swift),
`ExtensionOriginTrackingPreventionTests` and `ExtensionPrivateStoreTests`.

## Storage isolation

| Guard | What it does |
|---|---|
| `WebKitStorageScope` | In the default data directory the WebKit identifier is the profile id, so the installed app is untouched. In any other data directory it is a version 5 UUID over a fixed namespace, the data directory name and the profile id — stable per directory, and never equal to a production (version 4) id. A non-default directory records each identifier in its own database before WebKit creates the storage |
| `WebKitStorageScope.removeRecordedStorage` | Removes only identifiers that are recorded in this directory, re-derivable from the recorded profile id and this directory's name, and absent from the production database's profile ids. An unreadable production database means nothing is removed. The production database is read from a byte copy, never opened in place, so a lock cannot fail one of the running app's writes |
| `TestEnvironmentSetup` (the bundle's principal class) | At bundle start: resets the shared store and removes storage earlier runs left recorded. At bundle end: unloads extensions, clears undo actions, swaps the kept profiles' store and controller for non-persistent ones, then removes everything recorded |
| `ContentBlockerStorage` | A non-default data directory gets its own `WKContentRuleListStore(url:)`, filter list cache and defaults suite |
| `UserDefaultsScope.autosaveName` | Suffixes the window frame and split view autosave names with the data directory name outside the default one |
| `AppDelegate.startsUpdater` | Sparkle starts only outside the XCTest host and in the default data directory; otherwise the "Check for Updates…" item is left out of the menu |
| `AppDelegate.isRunningUnitTests` | Also skips the launch retry of pending profile data removals, the deleted-space history sweep and periodic extension update checks |
| Defaults safety net in `TestEnvironmentSetup` | Snapshots the production autosave and `SU*` keys and, at bundle end, restores only keys **this process** changed. It tells its own writes from another process's through `UserDefaults.didChangeNotification`, which a process receives only for its own writes — so it never reverts a concurrently running app |

The bundle identifier was deliberately not changed for Debug or test builds:
Sparkle, keychain items, native messaging host manifests and the 1Password
browser trust are all keyed by it. Using non-persistent stores under XCTest
was rejected because persistence tests need real stores and isolated app runs
would not have been covered.[^task-36]

Verified: two consecutive full runs left the directory counts under the
installed app's WebKit directory unchanged, and the end-of-bundle cleanup
removed 157 of 157 recorded identifiers in about 1.4 s.[^task-36] A
`defaults read` of the app's domain before and after a full run differed only
in the scoped test key.[^task-41]

## Rules of thumb for new tests

- Create profiles through the app's types so their WebKit identifiers are
  scoped and recorded. Do not build
  `WKWebExtensionController.Configuration(identifier: UUID())` directly.
- Remove what you compile into a rule list store.
- If a store will not delete at bundle end, look for a retained `Profile`
  (weak-reference probe), not for a longer timeout.
- Profiles added to `TabStore.shared` in tests do not load installed
  extensions: `TestEnvironmentSetup` sets
  `ExtensionManager.shared.loadsExtensionsIntoAddedProfiles = false`, and
  tests wire contexts by hand.
- Environment variables reach the test host only with the `TEST_RUNNER_`
  prefix — see [build and test](../playbooks/build-and-test.md).

# Related

- [Test host crashes](../playbooks/test-host-crashes.md) — recognising a crashed host and decoding the crash report.
- [Build and test](../playbooks/build-and-test.md) — commands, memory watchdog, one build at a time.
- [Profile data removal](../architecture/profile-data-removal.md) — `WebKitStorageScope` and `UserDefaultsScope` in full.
- [Persistence](../architecture/persistence.md) — `DETOUR_DATA_DIR` and what it moves.
- [App shell](../architecture/app-shell.md) — the launch-time switches in `AppDelegate`.
- [Testing extensions](../extensions/testing-extensions.md) — the integration-test styles that need real controllers.
- [Popup and options UI](../extensions/popup-and-options-ui.md) — why reading `popupWebView` loads the popup.
- [WKWebView delegate order](./wkwebview-delegate-order.md) — the failure callbacks, including the restricted-port case.
- [Content blocking](../features/content-blocking.md) — the rule list store.

[^task-36]: Stop the test host writing WebKit data into the production app's WebKit directory
[^task-41]: Stop the test host writing the production app's UserDefaults and starting Sparkle
[^task-122]: A background tab whose load fails never shows the error page
[^notes-crash]: Test host crash on process pool release; runaway test host memory
