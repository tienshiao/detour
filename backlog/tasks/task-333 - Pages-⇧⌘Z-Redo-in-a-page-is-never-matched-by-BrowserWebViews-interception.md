---
id: TASK-333
title: 'Pages: ⇧⌘Z (Redo) in a page is never matched by BrowserWebView''s interception'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-14T23:45:00Z'
updated_date: '2026-11-15T00:19:00Z'
labels:
  - keyboard
  - undo
dependencies: []
references:
  - TASK-327
  - Detour/Browser/Window/BrowserWebView.swift
priority: low
type: bug
ordinal: 407000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-327. BrowserWebView intercepts ⌘Z and ⇧⌘Z so undo and redo reach the page (or Detour's own undo) correctly. The ⇧⌘Z branch compares charactersIgnoringModifiers with "z", but with Shift held the event reports "Z", so the branch never runs and ⇧⌘Z takes the menu path instead. TASK-327 removed ⇧⌘Z from the shortcut reservations for that reason. Find out what the branch was meant to do (git history, the task that added it) before changing it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The intended behaviour of the ⇧⌘Z branch is found and recorded, and ⇧⌘Z in a page does that (in text fields, contenteditable and outside them)
- [x] #2 TASK-327's shortcut reservations match the fixed behaviour (⇧⌘Z reserved again if it is taken before the menus)
- [x] #3 A test covers the key matching with and without Shift; checked at runtime with /verify
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Find the branch's intent (git log -S): b1339ba 'Add support for undo/redo'.
2. Pure matcher BrowserWebView.browserUndoKey (case-insensitive character, Caps Lock ignored); performKeyEquivalent uses it for both keys, behaviour otherwise unchanged.
3. Reserve Shift+Cmd+Z again ('redoing in a page') in HotKeyShortcutValidation.pageShortcuts; ShortcutBindings' fixed-shortcut reason; ShortcutConflictTests.
4. Tests: BrowserUndoKeyTests (matching with and without Shift, Caps Lock, other modifiers; in a window: redo taken outside a field, left to the page while editing).
5. /verify with real key events: the page's key log tells fixed from unfixed.
6. Wiki: keyboard-shortcuts, tab-lifecycle, log.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Intent (AC #1): the branch came with b1339ba 'Add support for undo/redo' (2026-03-25), with the ⌘Z one and the comment 'When editing web content, let WKWebView handle Cmd+Z (text undo). Otherwise, do browser undo (close tab, move tab, etc.)'. So ⇧⌘Z outside an editable element, with something to redo, is the browser's redo, taken before the page sees the key; while editing (or with nothing to redo) it stands aside. Because charactersIgnoringModifiers is 'Z' with Shift held, it never matched: ⇧⌘Z reached the page and then Edit > Redo (browserRedo:), which also redoes the browser's action, so the visible result outside a field was the same, except that the page saw (and could preventDefault) the key first.

Fix: BrowserWebView.browserUndoKey(modifiers:charactersIgnoringModifiers:) matches ⌘Z as undo and ⇧⌘Z as redo, comparing the character without case and ignoring Caps Lock (as menus do; before, ⌘Z with Caps Lock on also missed the branch and went through the menu). performKeyEquivalent uses it; its decisions are unchanged otherwise (Quick Detour and editing pass to super). ⇧⌘Z is reserved again as 'redoing in a page' (HotKeyShortcutValidation.pageShortcuts); the Undo/Redo fixed-shortcut reason in ShortcutBindings now names both keys.

Tests: BrowserUndoKeyTests (5, new): ⌘Z / ⇧⌘Z as AppKit reports them ('Z' with Shift), Caps Lock, other modifiers and keys; in a browser window with a redo on TabStore.shared's stack, a synthetic ⇧⌘Z event ('Z') is taken and redoes it, and while editing it is left alone. ShortcutConflictTests: ⇧⌘Z refused as 'redoing in a page'. Run: BrowserUndoKeyTests 5, ShortcutConflictTests 10, ShortcutBindingStoreTests 21, ShortcutMenuTests 10, ShortcutsSettingsPaneTests 16, MainMenuCharacterizationTests 9, QuickDetourWindowTests 16: 87 tests, 0 failures. (The window test was not run against the old code; the old branch cannot match 'Z'.)

Runtime (/verify), real key events posted to the process (CGEventPostToPid, docs/harness/task327/axdrive.swift), window key, fixture page reporting every Cmd keydown to the loopback server's log:
- Before (Debug build of the TASK-331 commit, 70dd3a5 before it was amended into 6eb7fed with record-only changes; DetourVerify-333): a redo pending (child closed with ⌘W, reopened with ⌘Z), page body focused: ⇧⌘Z reached the page (logged cmd+shift+z), then the tab closed again through Edit > Redo.
- After (Debug build 16:09, DetourVerify-333b): same setup: the page saw nothing and the tab closed (the browser's redo, before the page).
- Declines, after: with the page's <input> focused, or a contenteditable, and a redo pending, the page saw ⇧⌘Z; then the Edit menu's Redo re-closed the tab (see the finding below). Body focused with nothing to redo: the page saw it, nothing else happened.

Finding (outside this task, not changed): while a page field is focused, ⌘Z and ⇧⌘Z go to the page and then the Edit menu, whose Undo/Redo send browserUndo:/browserRedo: and so run TabStore.undoManager, not the page's text undo. Observed: with a closed tab on the stack, ⌘Z in an <input> after typing 'ab' reopened the tab and the text was not undone (the field then read 'Ab', not explained); with nothing on the browser's stack, ⌘Z in an <input> and in a contenteditable did nothing, although WebKit held the contenteditable's edit (document.execCommand('undo') there undid it; not tried on the <input>). Which undo manager holds WebKit's edits was not determined. So 'text redo in fields' (the branch's intent for editing) does not happen today, for ⌘Z either; recorded in wiki/tabs/tab-lifecycle.md.

Review (code-review medium --fix, forked): no bug in the matching. Acted on: the take decision is now the pure BrowserWebView.takenBrowserUndoKey (editing, nothing to undo/redo, other keys), tested directly, replacing a window test that called WKWebView's real performKeyEquivalent with a synthetic event (WebKit could replay it to the menu after the test); the comment on performKeyEquivalent says the Edit menu then runs the browser's undo; HotKeyShortcut's comment and the wiki say that in the live menu Edit > Redo is named first (the 'redoing in a page' holder answers where no menu is checked). Not acted on (product decision, for the lead): outside a field ⇧⌘Z is now taken for the browser's redo before the page when the browser has something to redo, as ⌘Z already was, so canvas-style web apps (no editable element focused) lose their own ⇧⌘Z while a browser redo is pending.
Final test run: BrowserUndoKeyTests 8, ShortcutConflictTests 10, ShortcutBindingStoreTests 21, ShortcutMenuTests 10, ShortcutsSettingsPaneTests 16, MainMenuCharacterizationTests 9, QuickDetourWindowTests 16, ClosedPeekTests 11: 101 tests, 0 failures. Runtime re-run on that build (16:15, DetourVerify-333c): body + redo pending: the page saw nothing and the tab re-closed; <input> + redo pending: the page saw ⇧⌘Z (then the menu's Redo); body + undo pending: ⌘Z reopened the tab without the page seeing it.

AC #1 left unchecked: outside fields ⇧⌘Z does what the branch meant; in a text field or contenteditable the branch stands aside as meant, but what follows is the Edit menu's browser redo, not the page's text redo (pre-existing, also for ⌘Z), which this task did not change.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Shift+Cmd+Z in a page now matches BrowserWebView's redo branch. Its intent (b1339ba, with the Cmd+Z one): outside an editable element, with something to redo, redo the browser's action before the page sees the key; while editing, stand aside. The branch compared charactersIgnoringModifiers with "z", but AppKit reports "Z" with Shift held. A pure matcher (browserUndoKey: case and Caps Lock ignored) and a pure take decision (takenBrowserUndoKey) now drive performKeyEquivalent. Shift+Cmd+Z is reserved again as "redoing in a page" (HotKeyShortcutValidation; in the live menu Edit > Redo is still named first).

Tests: BrowserUndoKeyTests (8, new), ShortcutConflictTests and the Shortcut, menu, Quick Detour and Peek suites, 101 tests, 0 failures. Runtime with real key events: before the fix the page saw Shift+Cmd+Z and the menu then redid; after, it is taken before the page outside fields and left to the page in an input or contenteditable.

Still open (AC #1, task left In Progress): in a focused page field the keys fall to the Edit menu, whose Undo/Redo run the browser's undo stack rather than the page's text undo (observed for Cmd+Z and Shift+Cmd+Z; pre-existing; recorded in wiki/tabs/tab-lifecycle.md). Also for the lead: taking Shift+Cmd+Z before the page means canvas-style web apps lose their own redo while a browser redo is pending, as with Cmd+Z.
<!-- SECTION:FINAL_SUMMARY:END -->
