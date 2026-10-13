---
id: TASK-169
title: >-
  Sidebar: a hover-revealed sidebar sometimes stays open instead of hiding again
  (seen after switching tabs and returning to CodeToaster)
status: Done
assignee: []
created_date: '2026-10-10 07:08'
updated_date: '2026-10-13 01:22'
labels:
  - bug
dependencies: []
references:
  - Detour/Browser/Window/SidebarVisibilityState.swift
  - Detour/Browser/Window/BrowserWindowController.swift
  - wiki/sidebar/visibility-and-auto-hide.md
priority: medium
ordinal: 192000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported by the user 2026-10-10. On a smaller laptop the sidebar is kept hidden (auto-hide mode). After revealing it by hovering the left edge, using it to switch tabs, and eventually switching back to the CodeToaster tab, the sidebar sometimes does not hide again and stays stuck open. The user's guess is that CodeToaster (a web app with an xterm.js terminal) captures a mouse event the sidebar needs; that is not established, and it may only be where the user spends the most time.

Not reproduced yet. Candidates read from the code, to confirm or rule out:

1. The hide is driven only by a mouseExited from the sidebar's tracking area. An exit that arrives during the 0.5 s grace period after a reveal is dropped (sidebarHoverGraceActive) and nothing re-checks where the pointer is when the grace period ends, so a quick in-and-out leaves the sidebar open until the pointer enters and leaves it again.

2. AppKit does not always deliver mouseExited: while a mouse button is down (a click or drag that starts in the sidebar and ends over the page), when the view under the pointer changes without the pointer moving (selecting a tab swaps the web view; the sidebar itself animates in and out), when the tracking area is rebuilt (.inVisibleRect), or when the app or window stops being active (.activeInActiveApp) while the pointer is inside. Any of these leaves openedByHover true with no hide scheduled.

3. The popover hold never ends. heldOpen is released only by NSPopover.didCloseNotification; the wiki already records a popover that stayed up with no didClose, and a popover whose window goes away another way would leave the hold on, after which every hoverHide is ignored. An extension popup or the site settings popover opened from the revealed sidebar would be the trigger.

4. The mode was changed to pinned by something that is not the user: an expand the reducer attributes as external (collapsedChanged(false) while it expects collapsed) pins the sidebar. A hover reveal racing the collapse animation of a hover hide is one way to get there.

5. A web view that captures the pointer (xterm.js mouse reporting, pointer lock, or a drag selection in the terminal) changing which events AppKit delivers to the window.

The fix should not depend on one exit event: whatever the cause, a revealed sidebar whose pointer is elsewhere should end up hidden.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The stuck state is reproduced, or caught in the running app with enough logging to name it: the reducer's state (autoHides, openedByHover, heldOpen, expectedCollapsed), whether a hide was scheduled, and the event that was missed
- [x] #2 The cause is recorded in the task, including which of the listed candidates were ruled out and how
- [x] #3 A hover-revealed sidebar hides after the pointer has left it in each case found, including an exit during the reveal grace period and a tab switch made from the revealed sidebar
- [x] #4 A hover-revealed sidebar still stays open while the pointer is in it and while a popover opened from it is showing (TASK-127), and Toggle Sidebar still pins it
- [x] #5 The rule is in the pure reducer with tests in SidebarVisibilityStateTests that fail before the fix; anything that cannot be a reducer test has a stated reason
- [x] #6 Checked in the running app with real pointer movement, on a page that takes mouse input (an xterm.js terminal with mouse reporting on); the wiki's auto-hide page is updated
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Investigate: read the reducer and the window glue against each listed candidate; run small AppKit probes (standalone, and against the real BrowserWindowController in the test host) for what reading cannot settle: enter/exit delivery, NSMenu tracking vs timers, popover isShown after its anchor goes away, a hover reveal racing a hover hide.
2. Reproduce on the unfixed build with a temporary harness (isolated DETOUR_DATA_DIR) and log the reducer state for the stuck case.
3. Tests first (SidebarVisibilityStateTests): the hide becomes level-triggered. New reducer input 'where the pointer is' (enter, exit, end of the reveal grace period, a periodic sample), the grace period and 'a hide is pending' move into the reducer, the hide delay re-checks the pointer when it fires.
4. Window glue: a cheap pointer sample that runs only while the sidebar is hover-revealed (default run loop mode, so it is silent during menu tracking and drags; skipped while a mouse button is down); popover hold tracked by weak reference and re-validated (isShown) on each sample.
5. Run SidebarVisibilityStateTests and BrowserWindowSidebarModeTests; run the harness again on the fixed build.
6. Update wiki/sidebar/visibility-and-auto-hide.md and wiki/log.md; record findings per candidate, tests and runtime results here; one commit on the worktree branch.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Findings (2026-10-10)

The user's own occurrence was not observed. Two mechanisms that produce exactly the reported state were established from the code and reproduced in the running app on the unfixed rule, with the events injected (enter/exit events cannot be synthesized; see Runtime). Which of them the user hit is not determined.

Per candidate:
1. Exit during the 0.5 s grace period — CONFIRMED. mouseExited dropped the exit while sidebarHoverGraceActive and nothing looked at the pointer when the grace ended. Unfixed build, harness S1: edge enter, exit at +0.2 s, then at +3.0 s collapsed=false autoHides=true openedByHover=true heldOpen=false expectedCollapsed=false, no hide scheduled; a second exit hid it. A pointer that brushes the window's left edge and goes back to the page is enough.
2. mouseExited never delivered — CONFIRMED as a stuck state, delivery itself reasoned not measured. Unfixed build, harness S2/S3: reveal with no exit, same state at +3.0 s. That AppKit drops exits is already recorded in this codebase (TabSidebarViewController: none while a drag session is active; TabCellView.recheckHover: not reliable when the view under the pointer changes), and the areas are .activeInActiveApp. A tab dragged out of the revealed sidebar onto the page is one concrete path. Not reproduced with a real pointer.
3. Popover hold that never ends — NOT FOUND. Standalone AppKit probes (macOS 26): removing the anchor's view closes the popover with didClose; a shown popover with no remaining reference stays alive and shown; ordering the parent window out or minimizing it leaves a semitransient popover isShown with no didClose and it comes back with the window (a transient one closes on minimize). No case where the popover is gone and didClose never arrives. The ObjectIdentifier reuse cannot happen for a shown popover (AppKit keeps it alive). Hardened anyway.
4. Mode silently changed to pinned — NOT FOUND. Standalone probe of toggleSidebar: isCollapsed KVO is synchronous inside every call; a hide and a reveal 50 ms apart in either order, and expand-then-collapse in one run loop turn, produce no unrequested change. Collapse-then-expand in ONE run loop turn ends collapsed with a third KVO (true) after both calls returned; the reducer adopts it as an external collapse (hidden, still auto-hide) — a lost reveal, not a stuck one. No sequence produced an unrequested expand. Narrowing a window to 260 pt and widening it does not collapse or expand the sidebar. Fullscreen not checked. No non-user caller of toggleSidebarAutoHide (sidebar button, menu, Show Archived Tabs).
5. Web view capturing the pointer — NOT DETERMINED, and covered. xterm.js mouse reporting is DOM-level and cannot change what AppKit sends for the sidebar's own tracking area; a press that starts in the sidebar and ends on the page is case 2. Not tested with CodeToaster.
Also noted, not a defect: Toggle Sidebar is Cmd+S and reaches the menu after the page had the key; pressed in a web app it pins a hidden or hover-revealed sidebar, which looks the same as a sidebar that failed to hide.

## Design
Level-triggered hide in the reducer. New state inRevealGrace and hidePending (both were window state or implicit before); new events hoverGraceEnded(pointerInSidebar:) and pointerObserved(inSidebar:); hoverHide carries pointerInSidebar. One rule (settleHide) for every report of where the pointer is: in the sidebar, no hide pending; elsewhere and hover-revealed, not held, past the grace, a hide delay is running (started once). The delay re-checks the pointer when it elapses, so the sidebar also stays when an enter event was missed. watchesPointer tells the window when to sample.
Window glue: mouseEntered/mouseExited only decode the zone and call sidebarHoverZoneEntered/Exited (internal, so tests and a harness can call them); three default-mode Timers (grace, hide delay, a 0.25 s pointer sample that runs only while hover-revealed, stopped in windowWillClose); the popover hold keeps popovers weakly and is re-derived from isShown on didShow, didClose, every sample and every elapsed hide delay; isPointerInSidebar tests the sidebar's visibleRect instead of bounds (during the slide-in the bounds reach past the window edge: a real pointer 120 pt left of the window tested inside; visibleRect equals the bounds once settled).
Context menus: the timers run in the default run loop mode only, and a default-mode Timer does not fire while AppKit tracks a menu (probe: 0 ticks during a context menu, while a DispatchQueue.main.asyncAfter block did fire, in NSEventTrackingRunLoopMode). So nothing hides the sidebar under an open context menu or during a drag session; an overdue hide runs when the menu closes and decides from the pointer then. This also closes the old gap where the asyncAfter hide collapsed the sidebar under a menu (unfixed build S6: collapsed 1.2 s into the menu; fixed build: still shown, hidden after the menu closed). The sample also skips while a mouse button is down, so a press or drag that began in the sidebar keeps it as before.
Not done, deliberately: hooks on tab selection and window/app activation (the sample covers them within 0.25 s and they would be more glue to keep right); starting the hold at willShow (TASK-127 gap, separate); treating a pointer on a window that covers the sidebar as outside (NSWindow.windowNumber(at:) could do it; not verifiable here with a real pointer, and getting it wrong would hide the sidebar under the pointer).
Behaviour changes to know: a pointer over the sidebar's area but on a covering window (Settings, another app) keeps the sidebar; before, the exit event hid it. A hide due during a menu or drag now waits for it to end.

## Tests
TDD: tests written first against the unchanged rule (new events accepted and ignored): xcodebuild test -only-testing SidebarVisibilityStateTests + BrowserWindowSidebarModeTests = 42 run, 14 failed (11 new TASK-169 cases, 3 existing hold cases whose harness now reports exits to the reducer). After the fix, final code, harness removed: xcodebuild -scheme DetourTests -configuration Debug test -derivedDataPath .derived -only-testing:DetourTests/SidebarVisibilityStateTests -only-testing:DetourTests/BrowserWindowSidebarModeTests -only-testing:DetourTests/SidebarPageFocusTests = 63 run, 0 failed, 0 skipped (39 reducer, 8 window, 16 focus as a window-lifecycle smoke check). Full suite not run (one xcodebuild at a time on this machine).
New window-level tests (real BrowserWindowController, pointer replaced through sidebarPointerProbeForTesting): hides with no exit event; hides after an exit in the grace period; stays while the pointer is in it and through a stray exit; stays under a real NSPopover and hides when it closes; Toggle Sidebar pins. A first version of these passed for the wrong reason (the reveal issued in the same run loop turn as the collapse did not hold, so the sidebar 'hid' in 0.1 s); they now let the collapse settle and fail a hide that comes earlier than grace + delay.
Not a reducer test, with reason: the run loop mode of the timers, the mouse-button check and popover.isShown are AppKit state; the first two are in the harness run (S6) and by reading, the third in the window-level popover test.

## Runtime (isolated profiles DetourVerify169a/b/c, harness kept as docs/harness/task169-harness.patch)
Unfixed and fixed builds, same script, screen unlocked, app not active. Events injected by calling what the tracking areas call; in S1/S2 the pointer position was the real one (the window was placed away from the pointer, the pointer was never moved), in S3-S6 a stand-in.
- S1 exit in the grace period: unfixed stuck at +3 s; fixed hidden by +1.7 s.
- S2 no exit: unfixed stuck; fixed hidden by +2.0 s.
- S3 pointer inside 3 s then outside with no exit: both stay while inside; unfixed then stuck, fixed hidden within about 1 s.
- S4 popover: both stay 2.5 s with the pointer outside, both hide within 1 s of close.
- S5 Toggle Sidebar on a revealed sidebar: both pinned, stays.
- S6 context menu with the pointer outside: unfixed collapsed under the menu; fixed stays, hides after the menu closes.
- S7 window moved under the real pointer: inconclusive, the pointer was moved away within a second (the sidebar then hid, correctly).
NOT verified: real tracking-area enter/exit events (posted mouseMoved events produce none, even for an .activeAlways area); real pointer movement; 'stays while the real pointer is over it' with visibleRect (only the stand-in, plus the logged steady-state visibleRect equal to the sidebar's bounds); CodeToaster or any xterm.js page; fullscreen; an active (frontmost) app; a signed build. AC #6 needs a person at the machine.
Standalone probes (swiftc, scratchpad, not in the repo) were run while xcodebuild was unavailable; nothing of the app was built that way.

AC #1 and #2 left unchecked on purpose: the stuck state is reproduced and named only with injected events, and which mechanism the user hit is not established.

## After /code-review --fix (medium), 2026-10-10
Seven findings. Applied (the first by the review, then reshaped by me so the rule sits in one place):
- A mouse button down puts the hide off in all three places the window looks at the pointer, not only in the sample: sidebarPointerReading is nil while a button is down; the sample skips, the grace end and the elapsed hide delay report 'in the sidebar' and the sample starts the delay again after the button is up. This changes one old behaviour: a hide already due used to fire during a press.
- A window that is not visible (hidden app, minimized, closed) counts as 'pointer not in the sidebar', so its hover session ends; before this the sample skipped such a window and would have ticked 4 times a second for as long as it stayed hidden.
- The window tests no longer wait on 0.5 s timers: sidebarHoverDelay and sidebarPointerSampleInterval are instance variables that the tests shorten (0.15 s / 0.05 s). They still wait on real timers; each wait can only err one way (a timer never fires early).
Not applied, for review:
- A pointer on a window that covers the sidebar keeps it (geometric test). The reviewer suggests NSWindow.windowNumber(at:belowWindowWithWindowNumber:) limited to this window and its children; not done because it cannot be checked here with a real pointer and a wrong answer hides the sidebar under the pointer.
- No reducer action cancels the grace timer; a stale hoverGraceEnded reaches a session that ended and is ignored (covered by testToggleDuringRevealGracePinsAndTheGraceEndIsIgnored).
- sidebarPointerProbeForTesting replaces the button and visibility rules too, so neither is under test.
The review ran its own 'xcodebuild build' in this worktree's .derived without waiting for other builds.

Final code, harness removed: xcodebuild -scheme DetourTests -configuration Debug test -derivedDataPath .derived -only-testing:DetourTests/SidebarVisibilityStateTests -only-testing:DetourTests/BrowserWindowSidebarModeTests -only-testing:DetourTests/SidebarPageFocusTests = 63 run, 0 failed, 0 skipped (window tests 8.3 s). Harness rerun on that code (isolated profile DetourVerify169d): S1-S6 as before (S1 hidden by +1.7 s, S2 by +2.0 s, S3 stays then hides, S4 held then hides, S5 pinned, S6 stays under the menu then hides). S7 is now behind DETOUR_VERIFY_UNDER_POINTER and was not rerun. The mouse-button rule and the hidden-window rule were not exercised at runtime or in a test.

## Integration and review by the main session, 2026-10-10

The agent's commit is cherry-picked onto main's tip (db9024b, which has TASK-167/168) as branch task-169-sidebar-autohide; one conflict in wiki/log.md, both entries kept. Reducer and window glue read through: the hide rule is one function (settleHide), the window only reports where the pointer is, and the three timers run in the default run loop mode.

AC #1 and #2 checked by the main session: the stuck state was reproduced in the running app on the unfixed build and named (collapsed=false autoHides=true openedByHover=true heldOpen=false, no hide scheduled, the missed event an exit in the grace period or no exit at all), and each candidate has a verdict with its evidence above. The caveat stands: the events were injected, and which mechanism the user's own occurrence was is not known. AC #6 stays open: it needs real pointer movement on a page that takes mouse input.

Full DetourTests run on the branch: 2,116 tests, 11 skipped, 1 failure: ExtensionOriginTrackingPreventionTests.testTrackingPreventionPassSparesOriginsWithALoggedInteraction ('timed out after 30.0 s waiting for the uninteracted origin's localStorage to be deleted'). Not from this change: run alone a few minutes later it fails the same way on this branch and on main at db9024b, where it had passed in a full run about half an hour earlier (2,095 tests, 0 failures). Cause not established (the test drives WebKit's tracking-prevention pass, which has time-dependent rules).

One thing for the user to rule out, since it looks the same as a sidebar that failed to hide: Toggle Sidebar is Cmd+S and reaches the menu when the page does not take the key, so Cmd+S pressed in a web app pins a hidden or hover-revealed sidebar.

2026-10-12, task sweep: the user confirmed criterion 6 from daily use of the build they have run since 2026-10-11, including on a page that takes mouse input (a CodeToaster terminal): a hover-revealed sidebar hides again after the pointer leaves. The wiki page (sidebar/visibility-and-auto-hide) was rewritten with the fix on 2026-10-10. Which of the reproduced mechanisms the user's original occurrences were is still not known.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A hover-revealed sidebar now hides without waiting for an exit event: the reducer takes every report of where the pointer is through one rule (settleHide), re-checks the pointer when the hide delay elapses, and re-derives the popover hold. The stuck state was reproduced on the unfixed build and named; tests are in SidebarVisibilityStateTests. Confirmed by the user in daily use on a page that takes mouse input (2026-10-12).
<!-- SECTION:FINAL_SUMMARY:END -->
