---
type: Playbook
title: Debug harness
description: How to drive and observe the running app from a temporary, environment-gated block in AppDelegate — the pattern, the seeding calls, the stub drag info, and how to keep it out of commits.
tags: [playbook, harness, runtime, debugging]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-13T00:33:19Z }
sources:
  - id: app-delegate
    resource: ../../Detour/App/AppDelegate.swift
    title: AppDelegate.swift (the hook point)
  - id: task104-patch
    resource: ../../docs/task-104/task104-harness.patch
    title: TASK-104 harness patch (tab-cycling harness, kept in the repo)
  - id: task104-run
    resource: ../../docs/task-104/run_harness.sh
    title: TASK-104 launch-and-sample script
  - id: task110-stage
    resource: ../../docs/task-110/DemoStage.swift.txt
    title: TASK-110 DemoStage harness (command-file driven)
  - id: task110-hook
    resource: ../../docs/task-110/appdelegate-hook.patch
    title: TASK-110 AppDelegate hook
  - id: dragdrop
    resource: ../../Detour/Browser/Sidebar/SidebarDragDrop.swift
    title: SidebarDragDrop.swift (payload types)
  - id: task-89
    resource: backlog:TASK-89
    title: Permanent in-process UI automation hook (debug builds only)
  - id: task-121
    resource: backlog:TASK-121
    title: Standalone video URL shows the error page
  - id: notes-harness
    resource: "Agent session notes, 2026-09-25 (not in the repository)"
    title: Session notes on the runtime debug harness
  - id: notes-updates
    resource: "Agent session notes, 2026-09-25 (not in the repository)"
    title: Session notes on verifying the extension update UI
  - id: notes-private
    resource: "Agent session notes, 2026-09-20 (not in the repository)"
    title: Session notes on Private profile extensions
  - id: patches
    resource: ../../docs/harness/README.md
    title: Per-task harness patches and WebKit spikes kept in docs/harness
  - id: task-175
    resource: backlog:TASK-175
    title: A GPU process WebKit failed to kill stays alive and freezes every tab connected to it
---

There is no permanent automation hook in Detour. Runtime checks that need
more than "launch and look at the database" are done with a temporary block
of code in `AppDelegate`, switched on by an environment variable, that
seeds state, drives the app on timers and writes what it sees to a log
file. It is reverted before commit. TASK-89 proposes replacing this with a
permanent Debug-only hook; until that exists, this page is the pattern.

# When to use

- The behaviour under test needs the real window, sidebar or web views
  (hosting, focus, animation, drop handling, navigation delegates).
- A unit test would have to fake the thing you are unsure about.
- You need a before/after measurement of a fix.

For pure state rules, write a test instead ([CLAUDE.md](../../CLAUDE.md)).

# Steps

## 1. Hook in after the first window is up

The hook point is the end of `applicationDidFinishLaunching`, after
`observeWindowClose(wc)`: the session is restored, the window has its
active space, and `wc` is the `BrowserWindowController`.

```swift
        observeWindowClose(wc)
        #if DEBUG
        runVerifyHarnessIfRequested(wc)   // TEMP — DO NOT COMMIT
        #endif
```

```swift
// MARK: - TEMP verify harness — DO NOT COMMIT
extension AppDelegate {
    func runVerifyHarnessIfRequested(_ wc: BrowserWindowController) {
        guard let outDir = ProcessInfo.processInfo.environment["DETOUR_VERIFY_DIR"] else { return }
        let logURL = URL(fileURLWithPath: outDir).appendingPathComponent("verify.log")
        func log(_ line: String) {
            let data = Data((line + "\n").utf8)
            if let h = try? FileHandle(forWritingTo: logURL) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else { try? data.write(to: logURL) }
        }
        func after(_ t: TimeInterval, _ block: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: block)
        }
        log("harness armed pid=\(ProcessInfo.processInfo.processIdentifier)")
        after(2) {
            guard let space = wc.activeSpace else { log("no space"); return }
            let tab = TabStore.shared.addTab(in: space, url: URL(string: "data:text/html,<title>A</title>A")!)
            wc.selectTab(id: tab.id)
            after(4) { log("url=\(wc.selectedTab?.webView?.url?.absoluteString ?? "nil")"); log("done") }
        }
    }
}
```

Rules that make it dependable:

- Gate on an environment variable that names the output directory. No
  variable, no effect. The names used so far (`DETOUR_VERIFY_DIR`,
  `DETOUR_VERIFY_MODE`, `DETOUR_KEYLOOP_DIR`, `DETOUR_DEMO_STAGE`,
  `DETOUR_IOSURFACE_HARNESS`, `DETOUR_HARNESS_*`) are harness conventions;
  none of them exists in the shipped code.
- Log to the harness's own file, not stdout: an app started with `open`
  has no captured stderr.[^notes-harness]
- Log the pid first, and end with a `done` line the launching script can
  wait for.
- Always run it with an isolated `DETOUR_DATA_DIR`
  ([runtime verification](./runtime-verification.md)).

## 2. Seed and drive through the real entry points

| Want | Call |
|---|---|
| A tab | `TabStore.shared.addTab(in: space, url:)`, then `wc.selectTab(id:)` |
| A tab with a custom configuration | build the `WKWebView` from `space.makeWebViewConfiguration()`, then `addTab(in:webView:)` (as the TASK-104 harness does for autoplay) |
| An extension page | `addExtensionTab(in:url:configuration:)`, not `addTab`[^notes-private] |
| A second space | `TabStore.shared.addSpace(name:emoji:colorHex:profileID:)`, `wc.setActiveSpace(id:)` |
| A favorite | `addTab`, wait about 5 s for the favicon, then `detachTab` and `addFavorite(from:)`[^notes-harness] |
| The archive page, auto-hide | `wc.tabSidebar.showArchivePage(animated:)`, `wc.toggleSidebarAutoHide()` |
| A button or menu item | `button.performClick(nil)`, `NSApp.sendAction(_:to:from:)` |
| Something private | add a small `debugX` accessor in a `// TEMP` extension of the class, in the same patch |

`data:` URLs make deterministic pages with a known title. For real clicks
and keys see [in-process UI automation](./in-process-ui-automation.md).

## 3. Launch, wait, read, kill — as one command

```bash
open -n -g "$APP" --env DETOUR_DATA_DIR=DetourVerify121 --env DETOUR_VERIFY_DIR="$OUT"
for i in $(seq 1 60); do grep -q '^done' "$OUT/verify.log" 2>/dev/null && break; sleep 1; done
cat "$OUT/verify.log"
kill "$(pgrep -f "$APP/Contents/MacOS/Detour")"
```

[docs/task-104/run_harness.sh](../../docs/task-104/run_harness.sh) is a
complete example that also samples another process while the harness
cycles tabs.

## 4. Prove the harness can fail

Run it against the fixed build, then put the old code back (revert the one
fixed file), rebuild and run again. A harness that reports the same thing
both times proves nothing. One such cycle took about two minutes with a
warm build.[^notes-harness] A good observable is something that is
different in kind, not degree: for navigation failures it was the URL
scheme of the selected web view, `browser-error://…` against `https://…`.[^task-121]

## 5. Remove it

```bash
git diff -- Detour > docs/harness/taskNNN-harness.patch   # keep it if it may be reused; add a row to its README
git checkout -- Detour/App/AppDelegate.swift         # and any file with a debug accessor
git status --short Detour                            # must be clean of harness code
```

The larger alternative is a separate harness file in a throwaway worktree,
which never touches the checkout you commit from.[^notes-updates]

# Driving a drop without a drag

The sidebar's drop handling can be exercised without a drag session: build
an object that conforms to `NSDraggingInfo` and hand it straight to the
table view delegate.[^notes-harness]

```swift
final class DebugDragInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    var location: NSPoint            // window coordinates
    weak var window: NSWindow?
    init(payload: SidebarDragPayload, location: NSPoint, window: NSWindow?) {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("debug-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(payload.pasteboardString!, forType: tabReorderPasteboardType)
        pasteboard.writeObjects([item])
        self.location = location; self.window = window
    }
    var draggingLocation: NSPoint { location }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { .move }
    // … the remaining protocol requirements return empty values
}

// inside a TEMP extension of TabSidebarViewController:
let info = DebugDragInfo(payload: payload, location: point, window: view.window)
_ = tableView(tableView, acceptDrop: info, row: row, dropOperation: .above)
```

Use a private pasteboard name so the system drag pasteboard is untouched.
The payload must carry this sidebar's `sidebarID`, or the drop is rejected
as coming from another window. For an edge-band (split) drop put x at 0.15
or 0.85 of the row width.[^notes-harness] The rules being exercised are on
[sidebar drag and drop](../sidebar/drag-and-drop.md).

# Environment switches that are in the app

These exist in the shipped code and are useful from a harness run:

| Variable or argument | Effect | Where |
|---|---|---|
| `DETOUR_DATA_DIR` | data directory name | `detourDataDirectoryName()` |
| `DETOUR_NATIVE_MESSAGING_HOSTS_DIR` | extra native-host manifest directory, searched first (Debug builds only) | `NativeMessagingHost.searchDirectories` |
| `DETOUR_SLEEP_SHOW_BUDGET`, `DETOUR_SLEEP_SHOW_BUDGET_GRACE_SECONDS` | shrink the show-budget sleep rule | `TabStore` |
| `DETOUR_GPU_RECYCLE_SOFT_LIMIT`, `_HARD_LIMIT`, `_INACTIVE_GRACE_SECONDS`, `_USER_IDLE_SECONDS`, `_MIN_INTERVAL_SECONDS`, `DETOUR_GPU_RECYCLE_CHECK_SECONDS` | make the GPU recycler fire quickly | `GPUProcessRecycler` |
| `DETOUR_GPU_ORPHAN_MIN_AGE_SECONDS`, `DETOUR_GPU_ORPHAN_CHECK_SECONDS` | make the abandoned-GPU-process reaper act within seconds | `GPUProcessOrphanReaper` |
| `-ExtensionConsoleLogPublic YES` (launch argument) | extension console text readable in the log | `ExtensionPolyfillHandler` |

See [sleeping and archiving](../tabs/sleeping-and-archiving.md),
[GPU IOSurface limit](../platform/gpu-iosurface-limit.md) and
[reading runtime logs](./reading-runtime-logs.md).

# Existing harnesses

In the repository:

- [docs/task-104/task104-harness.patch](../../docs/task-104/task104-harness.patch)
  — seeds N tabs and cycles the selection through `selectTab` in phases,
  marking each phase in a log so an outside loop can chart a measurement.
- [docs/task-110/DemoStage.swift.txt](../../docs/task-110/DemoStage.swift.txt)
  with [appdelegate-hook.patch](../../docs/task-110/appdelegate-hook.patch)
  — a long-lived harness that polls a command file every 0.2 s, so a shell
  script can drive the app step by step
  ([release and website](./release-and-website.md)).
- [docs/harness](../../docs/harness/README.md) — twelve per-task patches
  (TASK-124 to TASK-132.8) and three standalone WebKit spikes, with a table
  of what each drives and its environment variables. They cover sidebar
  layer snapshots, the hit-test and resize probes, the stub drag info above,
  the key-view loop probe, the extension harnesses of the Claude extension
  epic, and the side panel harness whose procedure is the
  [side panel runtime check](./side-panel-runtime-check.md).
- [docs/harness/task175-176-harness.patch](../../docs/harness/task175-176-harness.patch)
  — two modes: a page the harness keeps drawing through the GPU process,
  so an outside script can `SIGSTOP` that process and watch the reaper
  ([abandoned GPU process](../platform/abandoned-gpu-process.md)); and a
  page that blocks its main thread, then `reloadPage`
  ([unresponsive web process](../platform/unresponsive-web-process.md)).
  It logs the web and GPU pids once a second.

The patches were written against the `AppDelegate` of their day and may
need a hunk fixed up. The techniques are written up on
[in-process UI automation](./in-process-ui-automation.md) and
[UI probes](./ui-probes.md), so those pages, not the patches, are the
reference. Until 2026-10-04 the patches were untracked files under
`.claude/` in one checkout; the ones for TASK-92, 94, 95 and 133/135 no
longer applied and were not kept.

# Traps

- **Committing it.** Mark every added line `TEMP`, keep harness code in as
  few files as possible, and check `git status` before staging.
- **A stale build runs no harness** and gives no error. Confirm the build
  ([runtime verification](./runtime-verification.md)).
- **Timers hide races.** `after(2)` works on an idle machine and fails on
  a busy one. Poll for the condition (the document exists, the favicon
  arrived) instead of sleeping where the step matters.
- **A `file:` or `data:` page does not load in the selected tab.** The
  window's navigation policy does not load those schemes in a web view it
  has claimed (TASK-159): a tab that is selected right after `addTab` stays
  empty, with no error. Serve the fixture from a local HTTP server
  (`python3 -m http.server --bind 127.0.0.1 --directory <dir>`), started by
  the same command that launches the app.[^task-175]
- **The harness window is hidden to WebKit.** An app launched from a shell
  comes up behind the other windows, so its page counts as hidden, and on a
  busy machine a hidden page's own timers all but stop
  ([hidden web view load stalls](../platform/hidden-webview-load-stalls.md)).
  A page that must keep doing something should be driven from the harness
  with `evaluateJavaScript` on a timer; a pending call also holds the web
  process at foreground priority.[^task-175]
- **Do not seed under an invented space id.** History visits of spaces
  that do not exist are swept shortly after launch; create a real space.
- **Attaching a debugger to an app launched from Xcode.** `lldb -p` fails
  because Xcode owns the debug session; pause in Xcode and use its console.
  There, `print()` inside an expression goes to the paused app's stdout
  and is not shown (return a string instead), `keyWindow` is nil while
  Xcode is frontmost, and the Objective-C expression parser needs casts
  (`(NSString *)[view _subtreeDescription]`).[^notes-harness]
- **`NSSplitView.setPosition`** on panes with stale frames was the root
  cause the first harness found; see
  [AppKit gotchas](../platform/appkit-gotchas.md) and
  [split tabs hosting](../tabs/split-tabs-hosting.md).

# Related

- [Runtime verification](./runtime-verification.md) — build, launch, isolate.
- [In-process UI automation](./in-process-ui-automation.md) — events and captures from inside the harness.
- [UI probes](./ui-probes.md) — ready-made measurements to paste into a harness.
- [App shell](../architecture/app-shell.md) — the launch sequence the hook sits at the end of.

[^notes-harness]: Session notes on the runtime debug harness
[^notes-updates]: Session notes on verifying the extension update UI
[^notes-private]: Session notes on Private profile extensions
[^task-121]: TASK-121
[^task-175]: TASK-175
