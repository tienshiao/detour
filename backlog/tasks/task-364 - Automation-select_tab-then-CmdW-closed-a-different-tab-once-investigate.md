---
id: TASK-364
title: 'Automation: select_tab then Cmd+W closed a different tab once (investigate)'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
updated_date: '2026-11-16T19:11:00Z'
labels:
  - automation
  - tabs
dependencies: []
references:
  - wiki/features/automation-endpoint-tools.md
priority: low
type: bug
ordinal: 445000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-228.12's runtime check: `select_tab` on "beta" followed by Cmd+W closed "gamma". The select_tab output was discarded, so whether it selected "beta" is unknown. Could be a wrong-tab close after an endpoint selection, or select_tab not selecting.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Reproduced or ruled out with a recorded script
- [x] #2 If real: Cmd+W after select_tab closes the selected tab, with a test
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Find the original TASK-228.12 call in that agent's transcript (which select_tab arguments, which closer).
2. Check select_tab's argument handling against that call.
3. Replay the original call at runtime through scripts/detour-mcp (DETOUR_MCP=1, data dir DetourVerify-364) with output and exit status kept, plus a control with the right argument.
4. Matrix with the right argument: closer run_menu_item cmd+w and press_key cmd+w; no pause and one batch session; one window and two windows (select and close in the non-key window); Detour in the background and active.
5. If not reproduced: record the script and results in the notes, add the trap to the tools wiki page, close as not reproduced. If reproduced: fix with a test.

6. (Runtime result) The original observation is ruled out: select_tab was called with tab_id= and refused (Unknown argument), so gamma stayed selected. But press_key cmd+w window_id=2 with window 1 key closed window 1's tab: WebKit resends a key the page did not handle through NSApp.sendEvent, which AppKit hands to the key window (and its menu). Fix: the endpoint marks the key-downs it hands a view; a local keyDown monitor catches the resend of a marked event whose window is not key, swallows it and runs the main menu's key equivalent for the event's window (as run_menu_item key= does). Test in the host (no key window) plus a pure decision test.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Origin (TASK-228.12's transcript, its runtime session): the call was `select_tab window_id=1 tab_id=<beta> >/dev/null` then `run_menu_item window_id=1 key=cmd+w`. select_tab takes `id`; ToolArguments refuses unknown names, so it failed and gamma (selected) closed correctly.

Recorded runtime script (scripts and logs kept in the session scratchpad, TASK-364/phase1..7.zsh/.log; data dir DetourVerify-364, Debug build of lane-a at 30e8ddff + this change, DETOUR_MCP=1, scripts/detour-mcp, fixture pages on 127.0.0.1:8364):
- Phase 1 (before the fix, background, one window: gamma*, beta, alpha): `select_tab window_id=1 tab_id=<beta>` -> exit 1, invalid_arguments 'Unknown argument(s): tab_id', gamma still selected; `run_menu_item key=cmd+w` closed gamma. Control: `select_tab id=<beta>` -> beta selected; cmd+w closed beta. The original observation is reproduced exactly and explained.
- Phase 2-4 (before the fix, id= used): run_menu_item cmd+w after select_tab closed the selected tab in every case: background one window with no pause (B1), both calls in one batch session (B2), two windows in the background (C1 window 2, C2 window 1), Detour active with window 1 key selecting and closing in window 2 (D1) and in window 1 (D2), batch in the non-key window (D5). select_tab always selected in the window it named.
- press_key before the fix: background, `press_key window_id=1 cmd+w` and `press_key context=tab:<id> cmd+w` answered handled:true and closed nothing (B3, B4, C3). Active, window 1 key: `press_key window_id=2 cmd+w` (epsilon selected in window 2) closed window 1's selected tab alpha (D3) -- a real wrong-window close; `press_key window_id=1 cmd+w` closed window 1's own (D4). A plain key `press_key window_id=2 key=x` on a page with no field reached the logger page in window 1 (key) as a trusted keydown, more than 1 s later (E1/E2).
- Cause: WebKit sends a key the page does not take back through [NSApp sendEvent:] (WebViewImpl::doneWithKeyEvent, same NSEvent object); AppKit hands that to the key window and its menu.
- Fix: AutomationKeyResend (AutomationInput.swift) marks every key-down the endpoint hands a view (press, type, press_key's Cmd branch); a local keyDown monitor catches a marked event coming back: in its own key window it goes on to AppKit; otherwise it is swallowed and the window's main-menu key equivalent runs, resolved in that window as run_menu_item key= does (AutomationTools.runMenuKeyEquivalent). AutomationEnvironment.keyWindow is injectable (the test host has no key window).
- Phase 7 (after the fix, fresh data dir, two windows): background `press_key window_id=2 cmd+w` closed window 2's eta (F1); active with window 1 key on logger, `press_key window_id=2 cmd+w` closed window 2's gamma, window 1 kept logger (F2); in the key window it closed its own beta (F3); `press_key window_id=2 key=x` and `key=y` did not reach window 1's logger (checked at 3 s and again later, log only showed F6's own key) (F4); run_menu_item unchanged (F5); `press_key window_id=1 cmd+g` still reached window 1's own page (F6).

Chosen by Claude (not yet confirmed by the user): a Cmd key a native first responder declines at once (performKeyEquivalent false) now goes to the window's main menu, as AppKit tries next for a person's key (before: nothing, handled false); alternative: leave it unhandled. Chosen by Claude (not yet confirmed by the user): a key given back outside its own key window that no menu item has is dropped, and the window's own view key equivalents are not tried again (the web view already declined; trying them later would make WebKit send the key to the page again); alternative: also hand it to the window's first responder's keyDown (a person's unhandled key ends in a beep there).

Code review (/code-review medium --fix, forked): 8 findings, 3 fixed by the review: (1) a Cmd key a native view declines now awaits its menu command inside press_key (was a fire-and-forget Task, so a following select_tab could overtake it), completed covers it; (3) the menu lookup passes the event's modifier flags whole (the matcher keeps Fn where it counts, TASK-375); (6) Route.dropping and the default resend parameters removed (resend is required on press/type). Not fixed: (2) a key the page gives back arrives after press_key answered, so its command acts on what the window holds then (a select_tab in between changes which tab Cmd+W closes) -- AppKit's own resend for a person behaves the same; noted in the wiki, follow-up candidate; (4) each given-back key in a non-key window runs a main-menu search (small cost); (5) NSMapTable weak keys compact lazily (small); (7)(8) style.
Tests: AutomationInputTests + AutomationToolsTests + AutomationWindowKindsTests + AutomationAgentPointerTests + AutomationEndpointTests + AutomationPageTests 88/0 before the review and 88/0 after (no skips). The four new tests failed with the catcher disabled (both integration tests timed out waiting for the close) and pass with it. One review-time run of AutomationInputTests had testANativeButtonTakesTheClickAndANativeMenuCanBeChosenFrom fail ('the earlier menu closed before this one opened'); it uses no key tools, and the four suite runs after it passed; looks load-sensitive, not related.
Runtime after the review fixes: phase 7 re-run on a fresh build, same results (F1-F6).
Not verified: the native-first-responder Cmd fallback at runtime (test only); type_text's given-back keys at runtime; a person's real keys (unchanged code path).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The reported wrong close was not a Detour bug: TASK-228.12's script called select_tab with tab_id= (the argument is id), the endpoint refused it as an unknown argument, the script discarded the answer, and Cmd+W closed the tab still selected. Replayed at runtime exactly. A matrix through scripts/detour-mcp (one and two windows, Detour in the background and active, no pause and one batch session) showed select_tab + run_menu_item cmd+w always closing the selected tab of the named window. It did find a real wrong-window close in press_key: with Detour active and window 1 key, press_key window_id=2 cmd+w closed window 1's tab, and an unhandled plain key in window 2's page reached window 1's page; in the background press_key cmd+w closed nothing. Cause: WebKit sends a key the page does not take back through NSApp.sendEvent, which AppKit hands to the key window. Fix: AutomationKeyResend marks every key-down the endpoint hands a view; a local key-down monitor catches the marked event coming back and, unless its own window is key, routes it to that window's main-menu key equivalent (as run_menu_item key= resolves it) instead. A Cmd key a native view declines also goes to the window's menu, awaited (Claude's choice, to confirm). Tests: four new AutomationInputTests (pure routing, Cmd-W with another window key, Cmd-W in the background unless the page takes it, native fallback), shown to fail without the catcher; automation suites 88/0. Checked at runtime before and after. Follow-up candidate: a given-back key acts on what the window holds when it arrives (as AppKit's own resend does).
<!-- SECTION:FINAL_SUMMARY:END -->
