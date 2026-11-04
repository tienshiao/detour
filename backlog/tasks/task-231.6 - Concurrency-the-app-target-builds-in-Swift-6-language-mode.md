---
id: TASK-231.6
title: 'Concurrency: the app target builds in Swift 6 language mode'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T00:08:00Z'
updated_date: '2026-11-03T03:51:00Z'
labels:
  - concurrency
dependencies:
  - TASK-231.5
references:
  - project.yml
  - CLAUDE.md
parent_task_id: TASK-231
priority: medium
type: chore
ordinal: 273000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Once the subsystem subtasks are done, the rest of the app target's warnings (Profile, sidebar, window controllers and others, mostly main-actor isolation that is already true at runtime) go to zero and the target switches to Swift 6 mode, where the checks are errors and new code cannot add races.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The Detour target has no concurrency warnings and sets `SWIFT_VERSION: "6"`
- [x] #2 `@unchecked Sendable`, `nonisolated(unsafe)` and `MainActor.assumeIsolated` remain only where the compiler cannot check the code, each with a comment saying what makes it safe
- [x] #3 The full DetourTests suite passes
- [x] #4 At runtime (/verify): multiple windows with tab ownership hand-off, split tabs, the command palette, an extension popup and the History page work
- [x] #5 CLAUDE.md (which says Swift 5.10) and a wiki page describe the isolation model new code follows
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Clear the remaining ~157 concurrency warnings, mostly AppKit callbacks the SDK types as nonisolated @Sendable but runs on main: NSAnimationContext completions, main-run-loop timers, main-queue notification blocks (new helpers in Browser/Shared/MainActorCallbacks.swift: runAnimationGroup(_:onMain:), Timer.scheduledMainTimer, NotificationCenter.addMainObserver), KVO handlers and RunLoop.main blocks (inline commented assumeIsolated); isolated deinits for main-actor teardown; nonisolated observeValue; @MainActor function-typed seams; a local function in an undo handler marked @MainActor.
2. Audit every Objective-C entry point a framework could call off the main thread before Swift 6 adds traps: selector notification observers (all posts from main-actor code), framework delegates without a thread promise (UserNotifications → nonisolated + hop), Carbon hot-key handler (main run loop).
3. SWIFT_VERSION 6 for the Detour target; fix what Swift 6 adds.
4. The test target follows (a Swift 6 app module makes its calls strict): same default isolation, still 5.10.
5. Full suite, runtime smoke (split, two-window ownership hand-off, palette, extension popup, History page), CLAUDE.md and wiki.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Done 2026-11-02.

Warnings: 164 → 0 concurrency warnings in the Detour target (7 left, none concurrency: two deprecations, three #ImplicitStrongCapture, an unmutated weak var, an unused ??). Then SWIFT_VERSION "6": one error (CRXInstallGate.Refusal synthesized Equatable used Installed main-actor conformance; Installed made nonisolated + Sendable). App builds in Swift 6 mode.

Test target: with the app module in Swift 6 mode, 4,439 errors in DetourTests (nonisolated test methods calling main-actor API, which a Swift 5 app module had allowed). DetourTests given SWIFT_DEFAULT_ACTOR_ISOLATION MainActor + approachable concurrency (still 5.10): 5 errors left, fixed in ContentRuleStoreThreadingTests (@MainActor local func), NewProfileExtensionLoadTests and ProfileDataRemovalTests (values hoisted out of @Sendable GRDB closures), QuarantineTests (main-actor default argument moved into the body). 67 test-target warnings remain for TASK-231.7.

Runtime-trap audit before the switch: selector notification observers safe (every post from main-actor code); UNUserNotificationCenterDelegate nonisolated + hop to main (header has no actor annotation; reachability test rows kept); Carbon hot-key handler assumeIsolated (application event target, main run loop); KVO observeValue nonisolated. Review correction: AVAudioPlayerDelegate is NS_SWIFT_UI_ACTOR in the SDK, so its callback stays main-actor and runs in place (my hop had opened a race: a queued finish could release the next player); it now also checks player === audioPlayer. Review also moved the remaining hand-written main-queue observers (AppDelegate window close, RecentTabSwitcher, ShortcutRecorderView, LinksSettings, QuickDetourSettings) onto addMainObserver and corrected the AVFoundation example in CLAUDE.md and the wiki.

Tests: full DetourTests on the Swift 6 app before the review: 3371 tests, 17 skipped, 0 failures, no test-host restart (no isolation trap). Rerun after the review fixes: see below.

Runtime (harness docs/harness/task231-6-harness.patch incl. a TEMP palette accessor; profile DetourVerify2316; Swift 6 build): a split of two tabs hosted both panes in window A; a second window showing the space took tab A web view when key, and window A took it back; the command palette showed 3 suggestions for a history query (background pass); hello-world installed and its action popup (popup.html) loaded through tabSidebarDidRequestShowExtensionPopup; the History page listed 3 rows. App alive afterwards, no crash report. (Two Detour .ips files from 19:22/19:23 are launches of a half-built app after harness compile errors: dyld could not load GRDB because of a stale code signature; not a product issue.)

After the review fixes: full DetourTests 3371 tests, 17 skipped, 0 failures, no test-host restart; runtime harness rerun on the final code (profile DetourVerify2316c): 6/6 PASS, app alive afterwards, no crash report. An ExcUserFault report at 19:37 during the suite is a non-fatal WebKit NetworkProcessProxy logInvalidMessage diagnostic in the test host (similar ones predate this task).

Process slip, corrected: removing the first harness with `git checkout -- Detour/App/AppDelegate.swift` also reverted this task own AppDelegate edit (the window-close observer on addMainObserver), which is why the review found it missing; a second checkout reverted the review fix again. Restored; harnesses are now removed by reverse edits, and docs/harness/task231-6-harness.patch was regenerated to contain only harness lines (it had picked up the task hunk and stopped applying).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The Detour target builds in the Swift 6 language mode with no concurrency warnings. The last ~157 were mostly AppKit callbacks that run on the main thread but are typed nonisolated; they now go through MainActorCallbacks.swift helpers (animation completions, main-run-loop timers, main-queue observers) or a commented assumeIsolated, with isolated deinits for main-actor teardown. Before the switch, every Objective-C entry point a framework could call off the main thread was audited (notification posts, UserNotifications delegate made nonisolated, AVAudioPlayerDelegate confirmed main-actor in the SDK, Carbon handler). The test target needed the app default isolation once the app module became Swift 6 (4,439 errors → 5, fixed). Full suite 3371/0 with no isolation trap; split, two-window ownership hand-off, palette, extension popup and History page work at runtime. CLAUDE.md states the isolation rules new code follows; the wiki records what Swift 6 adds at runtime and the audit.
<!-- SECTION:FINAL_SUMMARY:END -->
