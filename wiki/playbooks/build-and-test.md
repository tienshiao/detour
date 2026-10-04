---
type: Playbook
title: Build and test
description: How to generate the project, build, and run the test suite without clobbering another build, another test run or the machine's memory.
tags: [playbook, build, tests, xcodebuild]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T19:45:18Z }
sources:
  - id: task-132-8
    resource: backlog:TASK-132.8
    title: Host an extension's per-tab side panel beside the tab's content
  - id: claude-md
    resource: ../../CLAUDE.md
    title: CLAUDE.md (build commands, TDD policy, commit checklist)
  - id: project-yml
    resource: ../../project.yml
    title: project.yml (targets, schemes, test scheme environment)
  - id: test-setup
    resource: ../../DetourTests/TestEnvironmentSetup.swift
    title: TestEnvironmentSetup.swift
  - id: wiring-tests
    resource: ../../DetourTests/ExtensionPolyfillProfileWiringTests.swift
    title: ExtensionPolyfillProfileWiringTests.swift (gated measurement legs)
  - id: notes-memory
    resource: "Agent session notes, 2026-09-13 (not in the repository)"
    title: Session notes on a runaway test host and test memory limits
  - id: notes-env
    resource: "Agent session notes, 2026-09-13 (not in the repository)"
    title: Session notes on xcodebuild test environment variables
  - id: notes-parallel
    resource: "Agent session notes, 2026-09-12 (not in the repository)"
    title: Session notes on parallel builds and test data directories
  - id: notes-stale
    resource: "Agent session notes, 2026-09-19 (not in the repository)"
    title: Session notes on stale DerivedData builds
  - id: notes-harness
    resource: "Agent session notes, 2026-09-25 (not in the repository)"
    title: Session notes on the runtime debug harness
  - id: notes-crash
    resource: "Agent session notes, 2026-09-13 (not in the repository)"
    title: Session notes on test host crashes
---

The commands are in [CLAUDE.md](../../CLAUDE.md), and so is the policy: what
needs a test first, and what must pass before a commit. This page is the
part CLAUDE.md does not cover: which build directory to use, how to keep two
builds or two test runs from corrupting each other, how to pass environment
variables to the test host, and how to stop a test from eating the machine.

# When to use

Before the first build in a checkout, before any `xcodebuild test`, and
whenever more than one agent or an open Xcode shares the machine.

# Steps

## 1. Generate the project

`*.xcodeproj` is gitignored; the project is generated from
[project.yml](../../project.yml).

```bash
xcodegen generate
```

Run it once per checkout or worktree, and again after adding or removing a
file. A worktree has no project until you do.

## 2. Pick a build directory

| Situation | Use |
|---|---|
| Nobody else is building, Xcode is closed | the default DerivedData (no flag) |
| Xcode has the project open, or another agent builds | `-derivedDataPath <dir>` of your own |
| A worktree | `-derivedDataPath "$PWD/.derived"` (not in `.gitignore` on `main`: never `git add` it) |

When Xcode holds the default DerivedData bundle, a command-line build into
the same directory fails at CodeSign.[^notes-harness] A private directory
costs one cold build.

## 3. Build

```bash
xcodebuild -scheme Detour -configuration Debug build > "$OUT/build.log" 2>&1
tail -5 "$OUT/build.log"
```

Resolve the product from the build settings, with the same
`-derivedDataPath` you built with. Never glob DerivedData for it (see
[runtime verification](./runtime-verification.md)):

```bash
xcodebuild -scheme Detour -configuration Debug -showBuildSettings | grep -m1 " BUILT_PRODUCTS_DIR"
```

## 4. Run tests

```bash
# everything
xcodebuild -scheme DetourTests -configuration Debug test > "$OUT/test.log" 2>&1
# one suite or one test
xcodebuild -scheme DetourTests -configuration Debug test \
  -only-testing:DetourTests/SidebarLayoutTests > "$OUT/test.log" 2>&1
```

Always write the output to a file and read the file. A `grep` pipe throws
away the lines that explain a host crash (see
[test host crashes](./test-host-crashes.md)).[^notes-crash]

What a healthy start looks like, printed by `TestEnvironmentSetup` at
bundle start:

```
✓ Test data directory: ~/Library/Application Support/DetourTests/
```

The test scheme sets `DETOUR_DATA_DIR=DetourTests`, so the host (which is
the app itself: `TEST_HOST` is `Detour.app`) keeps its databases out of the
production directory. If the line reads `⚠️ DETOUR_DATA_DIR not set`, stop:
the run is writing into the real profile. What the data directory does and
does not isolate is on [persistence](../architecture/persistence.md) and
[profile data removal](../architecture/profile-data-removal.md).

## 5. Environment variables for the test host

`xcodebuild test` does not forward ordinary environment variables to the
test host. Prefix them with `TEST_RUNNER_`; the prefix is stripped in the
host.[^notes-env]

```bash
env TEST_RUNNER_DETOUR_MEASURE_BACKGROUND_PAGE_UNLOAD=1 \
  xcodebuild -scheme DetourTests -configuration Debug test \
  -only-testing:DetourTests/ExtensionPolyfillProfileWiringTests > "$OUT/test.log" 2>&1
```

Variables the tests read (name as seen in the host):

| Variable | Effect |
|---|---|
| `DETOUR_DATA_DIR` | data directory name; override per run with `TEST_RUNNER_DETOUR_DATA_DIR=DetourTests-<tag>` |
| `DETOUR_MEASURE_BACKGROUND_PAGE_UNLOAD=1` | six background-page unload legs in `ExtensionPolyfillProfileWiringTests`: the original three, about 37 s, 127 s and 300 s,[^notes-env] and the three port-closing legs of TASK-141, about 47 s, 128 s and 38 s. Pick legs with `-only-testing` |
| `DETOUR_MEASURE_WORKER_UNLOAD=1`, `DETOUR_MEASURE_WORKER_UNLOAD_SECONDS` | the worker unload leg (default 300 s) |
| `DETOUR_MEASURE_PRIVATE_WORKER=1`, `DETOUR_MEASURE_PRIVATE_WORKER_SECONDS` | the long Private-store worker leg in `ExtensionPrivateStoreTests` (90 s instead of 5) |
| `HISTORY_BENCH=1` | `HistoryBenchmarkTests` |

The gated legs skip themselves otherwise. Leave them off in ordinary runs
and reviews. What the unload legs measure is on
[service worker unload rules](../platform/service-worker-unload-rules.md).

## 6. One xcodebuild at a time

Two concurrent builds or test runs on one machine starve each other and,
for tests, share state. Wait for the other one:

```bash
while pgrep -x xcodebuild >/dev/null; do sleep 20; done; xcodebuild …
```

Use `pgrep -x`. `pgrep -f xcodebuild` matches the wait loop's own command
line and never exits.[^notes-stale] In an agent shell that blocks
foreground sleeps, run the whole line as one background command.

If two test runs must overlap anyway, give each its own data directory and
its own DerivedData:

```bash
env TEST_RUNNER_DETOUR_DATA_DIR=DetourTests-<tag> \
  xcodebuild -scheme DetourTests -configuration Debug test -derivedDataPath <dir> …
```

Without that, both hosts use `~/Library/Application Support/DetourTests/`
and `TestEnvironmentSetup` wipes the extension table at bundle start, so
each run corrupts the other. The override is confirmed by the
`✓ Test data directory` line naming the new directory.[^notes-parallel]

## 7. Memory watchdog for agent-run tests

A test host can run away. On 2026-09-13 a helper that looped over
`WKUserContentController.userScripts` while re-adding scripts never ended
(the bridged array tracks the controller), and the host grew from 337 MB to
36.66 GB in 90 seconds.[^notes-memory] Before an unattended test run, start
a watchdog in the supervising session. The rule that was used: kill a test
host above about 4 GB resident, and kill all test hosts if free memory
(`memory_pressure -Q`) drops below about 35%.[^notes-memory] A sketch (not
a script in the repository; macOS ships bash 3.2, so no associative arrays):

```bash
while sleep 10; do
  ps -axo pid=,rss=,command= | grep '/Detour.app/Contents/MacOS/Detour' \
    | grep -v '^ *[0-9]* *[0-9]* */Applications/' | grep -v grep \
    | while read -r pid rss _; do
        [ "$rss" -gt 4000000 ] && kill -9 "$pid"     # rss is in KB
      done
done
```

Match the executable path `…/Detour.app/Contents/MacOS/Detour` and exclude
`/Applications/`: an installed Detour has the same process name.

## 8. A failure that only shows in the full suite

A test that fails in a full run and passes alone was affected by an earlier
suite. Two that have happened:

- **Something an earlier test left alive.**
  `ProductionDefaultsIsolationTests.testLaunchWindowUsesTheScopedAutosaveNames`
  walks every `BrowserWindowController` in `NSApp.windows`, so a test window
  that was closed but never released fails it many suites later
  (2026-10-04, TASK-132.8).[^task-132-8] To find the test: keep a static
  array of weak boxes of each test's windows with the test's name, and print
  the ones still alive at the start of every `tearDown`. To find what holds
  it: from inside the test host, run
  `/usr/bin/leaks <own pid> --traceTree=<address of the object>` with
  `Process` and write the output to a file. The first-level nodes are the
  direct referencers; notification-centre and tracking-area entries are
  unretained noise, a `ScriptMessageHandlerDelegate` or a Swift storage node
  is a real owner. Narrow first with `-only-testing` for the suspect suite
  plus the failing one.
- **A failure that was already there.** Four
  `ExtensionPolyfillProfileWiringTests` cases about a background *page*
  getting `runtime.onInstalled`
  (`testMV3BackgroundPageGetsRuntimeOnInstalledOnce`,
  `…GetsTheUpdateAfterAVersionChange`,
  `testMV3BackgroundScriptsPageGetsRuntimeOnInstalledOnce`,
  `testBackgroundPageDeclaredWithARelativePathGetsRuntimeOnInstalledOnce`)
  time out in a full run and pass when the suite runs first or alone. The
  app's own log lines are the same in both (the install is delivered and
  dispatched to one listener); what fails is the test's question to the
  background page through an extension page. Which earlier suite causes it
  is not known. Before blaming a change, run the full suite on the parent
  commit in a separate worktree with its own `-derivedDataPath`: on
  2026-10-04 the unmodified parent failed the same four.[^task-132-8]

# Traps

- **Sandboxed agent shells.** `xcodegen generate` and `xcodebuild` write to
  the system temporary directory and fail inside a filesystem sandbox; run
  them with the sandbox off. `pgrep`, `ps` and `log show` are blocked the
  same way.[^notes-parallel]
- **Codesign timestamp.** `project.yml` signs with `--timestamp`. When the
  timestamp server is unreachable, pass `OTHER_CODE_SIGN_FLAGS=--timestamp=none`
  on the `xcodebuild` command line for local runs; do not change
  `project.yml`.[^notes-parallel]
- **"TEST FAILED" with zero failures** is a host crash, not a test failure:
  [test host crashes](./test-host-crashes.md).
- **Mutating a WebKit collection while iterating it.** Snapshot plain
  values first. Never create web views or user scripts once per poll
  iteration.[^notes-memory]
- **`-test-iterations` and parallel testing** on the long measurement legs
  multiply their memory and time; do not use them there.[^notes-memory]
- **A runaway already happened.** Read
  `/Library/Logs/DiagnosticReports/Detour_*.cpu_resource.diag` (footprint
  growth and the heaviest stack) and the kernel's `memorystatus` lines in
  `log show`.[^notes-memory]
- **Shell differences.** An agent's tool shell may be zsh while the
  interactive shell is something else. Quote globs (`--include='*.swift'`)
  and put multi-line recipes in a script file run with `bash`.
- **WebKit storage.** The test host shares
  `~/Library/WebKit/com.detourbrowser.mac/` with the installed app (the
  directory is keyed by bundle id); isolation there comes from
  `WebKitStorageScope`, not from the data directory. Never delete in that
  directory by hand. See
  [WebKit test host traps](../platform/webkit-test-host-traps.md).

# Related

- [Runtime verification](./runtime-verification.md) — what to do after the tests pass.
- [Test host crashes](./test-host-crashes.md) — decoding a crashed run.
- [Parallel agent workflow](./parallel-agent-workflow.md) — several agents building on one machine.
- [Testing extensions](../extensions/testing-extensions.md) — which extension suite proves what.
- [WebKit test host traps](../platform/webkit-test-host-traps.md) — WebKit behaviour that crashes or pollutes the host.
- [App shell](../architecture/app-shell.md) — what the app skips when it is the test host.

[^task-132-8]: Host an extension's per-tab side panel beside the tab's content
[^notes-memory]: Session notes on a runaway test host and test memory limits
[^notes-env]: Session notes on xcodebuild test environment variables
[^notes-parallel]: Session notes on parallel builds and test data directories
[^notes-stale]: Session notes on stale DerivedData builds
[^notes-harness]: Session notes on the runtime debug harness
[^notes-crash]: Session notes on test host crashes
