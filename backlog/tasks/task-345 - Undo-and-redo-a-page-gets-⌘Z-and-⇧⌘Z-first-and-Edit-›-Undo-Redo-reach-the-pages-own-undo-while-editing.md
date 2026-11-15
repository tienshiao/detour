---
id: TASK-345
title: >-
  Undo and redo: a page gets ⌘Z and ⇧⌘Z first, and Edit › Undo/Redo reach the
  page's own undo while editing
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-15T07:37:00Z'
updated_date: '2026-11-15T20:50:00Z'
labels:
  - keyboard
  - undo
dependencies: []
references:
  - TASK-333
  - Detour/Browser/Window/BrowserWebView.swift
  - wiki/tabs/tab-lifecycle.md
priority: medium
type: feature
ordinal: 423000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Decided 2026-11-14 by the user after TASK-333. Today BrowserWebView takes ⌘Z and ⇧⌘Z before the page whenever Detour's own undo list (closed tabs, moved tabs) has something to undo or redo and no editable element is focused, so canvas web apps (Figma, Google Sheets) lose their own undo and redo. And in a focused page field, ⌘Z goes to the page and then to Edit > Undo, whose browserUndo:/browserRedo: act on Detour's list: with a closed tab on the list, ⌘Z in a text box reopens the tab instead of undoing the typing; with nothing on the list it does nothing, although WebKit holds the field's edit (execCommand('undo') undoes it). TASK-333 measured both (wiki/tabs/tab-lifecycle.md). The user chose: the page first, Detour's undo only when the page does not handle the key; and Edit > Undo/Redo reach the page's own undo while editing.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 With no editable element focused, ⌘Z / ⇧⌘Z reach the page first; Detour's undo or redo runs only when the page does not handle the key (no preventDefault), and runs once
- [ ] #2 With an editable element focused (input, textarea, contenteditable), Edit > Undo / Redo and ⌘Z / ⇧⌘Z undo and redo the page's edit, never Detour's list, and the menu titles say so (or stay generic)
- [x] #3 With focus outside the page (sidebar, palette), Detour's undo and redo work as today
- [x] #4 TASK-327's shortcut reservations match the new routing
- [x] #5 Tests cover the routing decision; checked at runtime with a canvas-style fixture that handles ⌘Z itself, a plain input and contenteditable
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. WebKit (main sources, WebViewImpl.mm/WebPageProxy.cpp): a key equivalent goes to the page when the web view is first responder; an unhandled one comes back through doneWithKeyEvent -> [NSApp sendEvent:], and performKeyEquivalent falls to super on the resend, so the main menu gets it. No Cocoa didNotHandleKeyEvent delegate exists (C API only). So: remove BrowserWebView's ⌘Z/⇧⌘Z interception (and its matcher); Edit > Undo/Redo after the page is the 'page did not handle it' path, and runs once.
2. Page undo: WebKit registers edits into [m_view undoManager]. Probe which manager that is today (expect the window's own), then give BrowserWebView its own undo manager (override undoManager) so each page's edits are its own (not another tab's, not the palette's field editor).
3. Routing: one pure decision (page or browser) from 'the window's first responder is a BrowserWebView with an editable element focused'; browserUndo:/browserRedo:, the registry rule and title use it. Editing: the page's undo manager (title from it, disabled when it has nothing), never TabStore's. Focus outside the page: TabStore's, as today.
4. TASK-327 reservations: drop pageShortcuts (nothing takes ⌘Z/⇧⌘Z outside menus now; Edit > Undo/Redo hold them via the menu rule); update the fixed-shortcut reason, ShortcutConflictTests, wiki.
5. Tests: routing decision, registry rule/title, controller routing with a real window (page undo vs store undo, focus outside the page), WebKit edits landing on the web view's own manager; BrowserUndoKeyTests replaced.
6. /verify with real key events on a fixture (canvas preventDefault counter, input, contenteditable), closed tabs on the list; ⌘Z, ⇧⌘Z, Edit menu items, sidebar focus after a field.
7. Wiki (tab-lifecycle, keyboard-shortcuts, log), Backlog notes, review, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
WebKit (source on main, read 2026-11-15; wiki/platform/page-key-equivalents-and-undo.md): with the web view first responder, WebViewImpl::performKeyEquivalent sends a Cmd key to the page and returns YES; an unhandled one comes back through doneWithKeyEvent -> [NSApp sendEvent:], where performKeyEquivalent falls straight to NSView's, so the main menu gets it. No Cocoa delegate reports an unhandled key (didNotHandleKeyEvent is C-API only), so no private delegate method and no WebKitDelegateReachabilityTests row. WebKit registers a page's edits with [view undoManager]; measured before the change (probe test): the window's own NSUndoManager (same object as window.undoManager, 'Typing'), not TabStore's. WebKit also clears a page's edits when its view moves into or out of a window (viewWillMoveToWindow -> clearAllEditCommands), so a tab switch empties the page's stack.

Change: BrowserWebView no longer intercepts Cmd+Z / Shift+Cmd+Z (performKeyEquivalent override, browserUndoKey, takenBrowserUndoKey removed): a page gets them first; one it leaves reaches Edit > Undo/Redo once. BrowserWebView has its own undoManager (per page; not the window's, shared by split panes and the window's text fields). browserUndo:/browserRedo: run BrowserWindowController.undoTarget's choice: the focused page's own undo when the window's first responder is a BrowserWebView with isEditingWebContent and this window has the keys (or none does), else TabStore.undoManager. Registry: Undo/Redo rule and title read the page's stack while editing (canUndoPageEdit, pageUndoTitle: 'Undo Typing'), never the browser's. editableFieldFocus script also reports on page load / bfcache restore (top frame) and on Cmd+Z itself from a capturing keydown (its message precedes WebKit's 'not handled'), so a stale flag (focused element removed, tab switch) does not route the key; releaseScriptHandlers no longer clears the flag. A Peek's page gets the editableFieldFocus handler (claimPeekWebView), which it never had. TASK-327: pageShortcuts (Cmd+Z/Shift+Cmd+Z 'undoing/redoing in a page') removed: nothing outside the menu holds them; Edit > Undo/Redo hold them (rule 3, now asserted against the real menu bar); the fixed-shortcut reason rewritten (Undo/Redo stay fixed: moving them would take text undo from pages).

Tests: PageUndoRoutingTests (9, new; replaces BrowserUndoKeyTests): routing decision incl. another key window; in a window: outside a field Edit > Undo runs the browser's once, while editing the page's (disabled with an empty page stack although the browser could undo; 'Undo Typing'/'Redo Typing'), focus outside the page with the flag stale runs the browser's, an unfocused web view leaves Cmd+Z/Shift+Cmd+Z to the menu (old code took them), the focus script reports on Cmd+Z/Shift+Cmd+Z (not on other keys) and on load, a Peek's field is the Peek's undo (failed with the handler line removed: timed out), WebKit's edits land on the web view's own manager (not the window's, not TabStore's) and undo there. BrowserCommandRegistryTests (rule/title while editing), ShortcutConflictTests (Cmd+Z/Shift+Cmd+Z free outside menus, Edit > Undo/Redo in the real menu bar). Final run: PageUndoRoutingTests 9, BrowserCommandRegistryTests 23, ShortcutConflictTests 18, ShortcutBindingStoreTests 21, ShortcutMenuTests 10, ShortcutsSettingsPaneTests 21, MainMenuCharacterizationTests 10, QuickDetourWindowTests 16, ClosedPeekTests 11, MenuKeyEquivalentMatcherTests 16, WebKitDelegateReachabilityTests 3, WindowCloseReleaseTests 20, PeekWindowCommandsTests 4, WebViewHandoffFocusTests 7, RecentTabSwitcherPeekTests 7, InPageLinkRoutingTests 24: 220 tests, 0 failures.

Runtime (/verify, Debug build 12:21 with every change but the Peek handler; DetourVerify-345c; docs/harness/task345/drive.py + undo.html; real Cmd+Z/Shift+Cmd+Z posted to the pid with Detour made frontmost before each key; closed tabs put on the list with real Cmd+W): canvas (preventDefault) counted Cmd+Z and Shift+Cmd+Z once each, Detour's list untouched; body focused: page logged the key, exactly one of two closed tabs came back, Shift+Cmd+Z re-closed exactly one; <input> and contenteditable: Cmd+Z/Shift+Cmd+Z and Edit > Undo/Redo (run_menu_item, titled 'Undo Typing'/'Redo Typing') undid/redid the typing, no tab change; page stack empty: Cmd+Z changed nothing and Detour's closes stayed; palette (Cmd+L) and find bar (Cmd+F) focused with the page's input still DOM-focused: Cmd+Z reopened one tab, page text untouched, page saw no key; tab switched away and back with the contenteditable focused: Cmd+Z reached the page, nothing undone (WebKit cleared the edits on the switch), Edit > Undo 'Undo', disabled, Detour's list untouched; focused input removed by the page: Cmd+Z reached the page, then reopened exactly one tab. Earlier run (DetourVerify-345b, before the review fixes): same matrix 25/25. Clicking the sidebar tab list does not take the keys (TASK-174), so Cmd+Z then stays the page's. Traps: a first run lost activation mid-run (the person at the Mac in another app) and the re-sent keys did nothing; tabs closed via run_menu_item landed in one undo group.

Not verified: the Peek handler at runtime (unit-tested only); split panes at runtime (owned web views, same path as tabs); Release/signed build. Out of scope, not changed: a Quick Detour window's Edit > Undo/Redo answer only in browser windows, so Cmd+Z in a Quick Detour field still undoes nothing; the docked Web Inspector (a plain WKWebView) leaves Cmd+Z to the browser's undo; Settings' and extension popups' text fields still reach the main browser window's browserUndo: (now always the browser's undo there, never a page's).

Correction and follow-up (2026-11-15, after an advisor pass and a second review):
- The runtime section above overstated one point: the palette and find-bar checks on the 12:21 build did not run (the find mode crashed on an input an earlier step had removed; the outside mode was not rerun). All checks were rerun on the final build (Debug 12:45 = this commit; DetourVerify-345e; Detour activated before every key, active and key after all of them): matrix 25/25 (canvas, body, input, contenteditable, Edit menu, empty page stack), palette (Cmd+L) 2/2, find bar (Cmd+F) 2/2 (a fresh real Cmd+W close on the list first), tab switch and removed input 5/5, and two new ones below. HEAD-before-review build (12:38, DetourVerify-345d) gave the same.
- Order of the Cmd+Z report: a fixture variant (undo.html?swallow=1) stops every focusout at window capture, so Detour's flag stays stale after clicking out of a typed input; Cmd+Z then reopened one tab and left the text, 3 of 3 (without the key's report the stale flag would have undone the typing). So the keydown message arrives before WebKit's 'not handled' at runtime too.
- Quick Detour (measured, not changed): a page opened with Open Link in Quick Detour, its input focused and typed into, Detour key: Cmd+Z reached the page, the typing stayed, the browser window's closed tab stayed closed; Edit > Undo is disabled there ('Nothing in the window handles Undo'). AC #2 unchecked for this: whether Quick Detour pages should get their own text undo (let Undo/Redo answer in a Quick Detour window for its page only) is the user's call.
- Second review (medium --fix, on the commit's later pieces), applied: isEditable follows open shadow roots; the top document also reports on window focus; the key listener captures on window (ahead of the page's document listeners) and matches code KeyZ too; one shared report(); focusout guarded. Not applied: releasing the Peek's handler on hide (weak, sets only that view's flag). Test added: a shadow-root field counts on focus and on Cmd+Z (PageUndoRoutingTests 9). Final runs: PageUndoRoutingTests 9, WindowCloseReleaseTests 20, PeekWindowCommandsTests 4, WebViewHandoffFocusTests 7, InPageLinkRoutingTests 24 (64, 0 failures) after the review fixes; the other suites listed above ran on the commit before them (no change in their code paths since).
- Not measured: a page's window-capture keydown listener that stops propagation would hide the key's report; the dead-web-process case (source only); the docked Web Inspector (source only, unchanged); split panes at runtime.

Final test run on the amended commit: the 16 suites above, 220 tests, 0 failures (PageUndoRoutingTests 9 incl. the shadow-root case).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A page now gets Cmd+Z and Shift+Cmd+Z first. BrowserWebView no longer takes them before the page: WebKit sends a Cmd key to the focused page and re-sends one the page leaves through NSApp.sendEvent, so Edit > Undo/Redo get it once (no delegate callback exists; read in WebKit's source and measured). In a browser window, Edit > Undo/Redo run the focused page's own undo while an editable element in it has focus (the web view is first responder, the window has the keys), titled from the page ('Undo Typing') and disabled when the page has nothing, never Detour's list; otherwise TabStore's undo, focus in the palette or find bar included. Each BrowserWebView has its own undo manager (WebKit's edits were on the window's). The focus script also reports on load, window focus and Cmd+Z itself (its message arrives before WebKit's 'not handled': measured), follows shadow roots, and a Peek's page now reports too. TASK-327: Cmd+Z/Shift+Cmd+Z are no longer reserved outside menus; Edit > Undo/Redo hold them and stay fixed.

Tests: PageUndoRoutingTests (9, new, replacing BrowserUndoKeyTests) and the registry, shortcut, menu, Peek, Quick Detour and window suites: 220 tests, 0 failures. Runtime on the final build with real key events, a fixture (preventDefault canvas, input, contenteditable) and closed tabs on the list: every focus case for Cmd+Z, Shift+Cmd+Z and the Edit menu items behaved as specified, Detour's undo running exactly once when the page left the key.

Open (AC #2 unchecked, task In Progress): in a Quick Detour window Cmd+Z in a field reaches the page and nothing more (measured; Edit > Undo/Redo answer only in browser windows); whether Quick Detour pages should get their own text undo is the user's decision. Also: WebKit empties a page's undo when its view leaves the window, so after a tab switch the page has nothing to undo (Edit > Undo disabled, Detour's list untouched).
<!-- SECTION:FINAL_SUMMARY:END -->
