---
type: Playbook
title: Test host crashes
description: What to do when xcodebuild prints TEST FAILED although no test failed — the test host crashed — and how to get the stack and find the suite that really caused it.
tags: [playbook, tests, crash, webkit, xcodebuild]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:44:19Z }
sources:
  - id: popup-tests
    resource: ../../DetourTests/ExtensionMenuPopupDecisionTests.swift
    title: ExtensionMenuPopupDecisionTests.swift (the retained-profile pattern)
  - id: test-setup
    resource: ../../DetourTests/TestEnvironmentSetup.swift
    title: TestEnvironmentSetup.swift
  - id: task-55
    resource: backlog:TASK-55
    title: Building the Extensions menu loads every extension's popup page
  - id: notes-crash
    resource: "Agent session notes, 2026-09-13 (not in the repository)"
    title: Session notes on test host crashes
  - id: notes-memory
    resource: "Agent session notes, 2026-09-13 (not in the repository)"
    title: Session notes on a runaway test host and test memory limits
---

The DetourTests bundle runs inside the app (`TEST_HOST` is `Detour.app`).
When the app process dies in the middle of a run, XCTest restarts it and
carries on, and the summary looks like a contradiction: `Executed N tests,
with 0 failures` followed by `** TEST FAILED **`. Nothing failed an
assertion. The host crashed, and the tests that were due to run in the dead
process were skipped without being counted.[^notes-crash]

# When to use

- `** TEST FAILED **` with zero failures in the totals.
- A full run reports noticeably fewer tests than usual (a healthy full run
  was 991 tests on 2026-09-13; the number only grows).[^notes-crash]
- A suite fails or vanishes only in a full run and passes alone.

# Steps

## 1. Confirm it was a crash

The full log must be in a file ([build and test](./build-and-test.md)).

```bash
grep -n "Restarting after unexpected exit, crash, or test timeout" "$OUT/test.log"
grep -n "Executed .* tests" "$OUT/test.log" | tail -3
```

The restart line names the test that was running when the process died.
That test is where the crash landed. It is often not where it was caused
(step 4).

## 2. Find the crash report

```bash
ls -t ~/Library/Logs/DiagnosticReports/Detour-*.ips | head -3
```

A memory or CPU kill leaves a different file,
`/Library/Logs/DiagnosticReports/Detour_*.cpu_resource.diag`, which shows
the footprint growth and the heaviest stack.[^notes-memory]

## 3. Decode the .ips

An `.ips` file is two JSON documents: a one-line header, then the body.
The body has `faultingThread`, `threads[i].frames` and `usedImages`.[^notes-crash]
A decoder sketch:

```bash
python3 - "$IPS" <<'EOF'
import json, sys
head, _, body = open(sys.argv[1]).read().partition("\n")
r = json.loads(body)
print(json.loads(head).get("app_name"), r.get("exception", {}))
images = r.get("usedImages", [])
t = r["threads"][r.get("faultingThread", 0)]
for f in t.get("frames", [])[:40]:
    image = images[f["imageIndex"]].get("name", "?") if f.get("imageIndex", -1) < len(images) else "?"
    print(f'{image:28} {f.get("symbol", hex(f.get("imageOffset", 0)))}')
EOF
```

Read the stack from the bottom for who started it and from the top for
what trapped.

## 4. Find the suite that caused it

A crash whose stack is all WebKit and no test code was usually set up by
an earlier test and fired later from the run loop. Look one or two seconds
back in the log for the suites that ran just before the restart line, and
ask which of them released a WebKit object.

The known case:[^notes-crash]

```
IPC::MessageReceiverMap::invalidate
WebKit::WebProcessPool::~WebProcessPool
-[WKProcessPool dealloc]
WebKit::WebProcessProxy::~WebProcessProxy
```

WebKit traps when a `WKWebExtensionController`'s process pool is freed
from inside an IPC dispatch. The trigger was a test that read
`action.popupWebView` (the popup web view lives in the controller's own
configuration) and then removed its profile with `forceRemoveProfile`,
which released the `Profile`. The crash landed one to two seconds later,
in whichever suite ran next.

The fix pattern, in `ExtensionMenuPopupDecisionTests`: call
`action.closePopup()`, and keep any profile whose controller ever hosted a
popup web view alive for the rest of the process in a static array. The
context is still unloaded and the store row removed; only the object
outlives the test.

## 5. Reproduce

Run the suspected suite followed by any other suite in one invocation:

```bash
xcodebuild -scheme DetourTests -configuration Debug test \
  -only-testing:DetourTests/<SuspectTests> -only-testing:DetourTests/<AnyOtherTests> \
  > "$OUT/repro.log" 2>&1
```

Running the suspect alone may pass: the trap fired one to two seconds
after the release, and a short run can be over by then. (That it would
pass alone is an inference from the timing, not something that was
tried.)

# Traps

- **Blaming the named test.** The restart line names the victim.
- **Piping `xcodebuild` through `grep`.** The restart line and the crash
  context are gone; rerun with the output in a file.
- **Trusting the totals.** "0 failures" with a crash means some tests did
  not run. Compare the executed count with a healthy run.
- **A watchdog kill looks the same.** If a memory watchdog is running
  ([build and test](./build-and-test.md)), check whether it killed the
  host before reading crash reports.
- **Reports from other Detour processes.** An installed app or an isolated
  run writes `Detour-*.ips` too. Match the report's timestamp and its
  process path against the test host under your DerivedData.
- **Releasing WebKit objects in `tearDown`.** Profiles, extension
  controllers, process pools and data stores have teardown rules of their
  own; the collected cases are on
  [WebKit test host traps](../platform/webkit-test-host-traps.md).

# Related

- [Build and test](./build-and-test.md) — running the suite, the memory watchdog.
- [WebKit test host traps](../platform/webkit-test-host-traps.md) — the WebKit behaviours behind these crashes.
- [Testing extensions](../extensions/testing-extensions.md) — the suites that create controllers and contexts.
- [Popup and options UI](../extensions/popup-and-options-ui.md) — why reading `popupWebView` has side effects.

[^notes-crash]: Session notes on test host crashes
[^notes-memory]: Session notes on a runaway test host and test memory limits
