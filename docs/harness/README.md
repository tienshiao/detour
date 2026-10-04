# Runtime-check harnesses

Temporary, environment-gated code that was pasted into the app to drive and
observe it for one task's runtime check, saved as a patch after the check.
None of it is part of the app. The pattern, and how to write a new one, is in
`wiki/playbooks/debug-harness.md`; TASK-89 proposes a permanent Debug-only
hook that would replace these.

## Using one

```bash
git apply docs/harness/taskNNN-harness.patch    # one at a time: most patch AppDelegate.swift
# build, launch with DETOUR_DATA_DIR pointing at an isolated profile plus the patch's own variables
git checkout -- Detour                           # remove it before committing
```

The table lists each patch's variables; the patch itself says what values they
take. All 12 applied cleanly to `epic-claude-extension` at 081789e (2026-10-04). They are
written against the `AppDelegate` of their day, so expect to fix up a hunk
later; a patch that no longer applies is still a record of how the check was
driven.

## Patches

| Patch | Tasks | What it drives | Gate |
|---|---|---|---|
| `task124-harness.patch` | TASK-124 | A background tab whose load stalls, for the sidebar progress bar fade | `DETOUR_VERIFY_DIR`, `DETOUR_VERIFY_URL` |
| `task126-128-harness.patch` | TASK-126, 127, 128 | Hit-test map of the Downloads button, the hover-revealed sidebar with the downloads popover, first responder at launch | `DETOUR_VERIFY_DIR`, `DETOUR_VERIFY_MODE`, `DETOUR_VERIFY_PRIVATE` |
| `task129-harness.patch` | TASK-129 | Sidebar drags with a stub drag info: the favourite drop hint and drops landing from the release point | `DETOUR_VERIFY_DIR` |
| `task130-harness.patch` | TASK-130 | Key-view loop probe: where keyboard focus is after a space page slides away | `DETOUR_KEYLOOP_DIR`, `DETOUR_KEYLOOP_MODE`, `DETOUR_KEYLOOP_FKA` |
| `task131-harness.patch` | TASK-131 | The same probe, extended to a space list that changes under a focused tab list | `DETOUR_KEYLOOP_DIR`, `DETOUR_KEYLOOP_MODE`, `DETOUR_KEYLOOP_FKA` |
| `bugfix-batch-harness.patch` | TASK-135, 137, 143, 148, 151 | A second window on the same tab, a Private window beside a normal one, the install prompt and its refusals, a download ending at quit | `DETOUR_VERIFY_DIR`, `DETOUR_VERIFY_CRX_DIR`, `DETOUR_VERIFY_STORE_URL` |
| `followups-batch-harness.patch` | TASK-152, 153, 154, 156, 157, 159 | The follow-up batch; adds a separate `BatchVerifyHarness.swift` | `DETOUR_VERIFY_DIR` and five `DETOUR_VERIFY_*` inputs |
| `task132.3-harness.patch` | TASK-132.3 | Unselected tabs kept renderable while an extension drives them, with synthesized input | `DETOUR_PARKING_HARNESS_DIR`, `_URL`, `_KEY` |
| `task132.4-harness.patch` | TASK-132.4 | The API Explorer popup and the declarativeNetRequest session header rule against a header-echoing fixture | `DETOUR_DNR_HARNESS_DIR`, `_URL`, `_EXT` and mode switches |
| `task132.4-install-harness.patch` | TASK-132.4 | Installing the Claude extension from its Chrome Web Store page, answering Detour's prompt | `DETOUR_INSTALL_HARNESS_DIR` |
| `task132.6-harness.patch` | TASK-132.6 | `externally_connectable` pages: runs `step-N.js` files from the output directory in a tab | `DETOUR_EC_HARNESS_DIR`, `_EXT`, `_URL`, `_MODE` |
| `task132.8-harness.patch` | TASK-132.8, 132.9 | An extension's side panel; procedure in `wiki/playbooks/side-panel-runtime-check.md` | `DETOUR_SP_HARNESS_DIR`, `_MODE` (explorer, width, claude), `_EXT`, `_URL` |

## Spikes

Standalone Objective-C programs that measure shipped WebKit outside the app.
The comment at the top of each file says what it measures and what arguments
it takes. Build with `clang -fobjc-arc -framework AppKit -framework WebKit
<file>.m -o spike`.

| File | Question it answers |
|---|---|
| `task132.1-sidepanel-spike.m` | Does shipped WebKit vend `chrome.sidePanel`, and does it hand the app a sidebar? |
| `task132.3-covered-webview-spike.m` | Can a web view that is in a window but covered by a sibling be snapshotted and driven with synthesized events? |
| `task132.3-declined-key-spike.m` | Where does a key land when a hidden in-window web view's page declines it and WebKit re-sends it through `NSApp.sendEvent`? |

## Old paths

Before 2026-10-04 these files were untracked under `.claude/` in one working
checkout, and Backlog task notes still cite them there:
`.claude/<name>-harness.patch` is `docs/harness/<name>-harness.patch`, and
`.claude/scratch/task132.3/declined-key-spike.m` is
`task132.3-declined-key-spike.m` here. The patches for TASK-92, 94, 95 and
133/135 (key events) no longer applied and were not kept; their techniques are
in `wiki/playbooks/in-process-ui-automation.md` and
`wiki/playbooks/ui-probes.md`. `.claude/scratch/` holds a checkout's own
build and test logs and is ignored by git, so a log a task cites there exists
only in the checkout that wrote it; the results are summarised in the task.
