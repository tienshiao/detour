---
id: TASK-132.28
title: >-
  Extensions: differential test of Runtime.evaluate's completion-value rewrite
  against WebKit's own script evaluation
status: To Do
assignee: []
created_date: '2026-11-08T05:30:00Z'
labels:
  - extensions
  - debugger
  - testing
dependencies: []
parent_task_id: TASK-132
priority: medium
ordinal: 340000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Runtime.evaluate (TASK-132.15) returns the code's completion value using an in-house tokenizer, Detour/Extensions/Runtime/ExtensionDebuggerReplSource.swift (about 460 lines, not a parser). It finds where the last statement could start and rewrites it to `$c = (expr\n)`; ExtensionDebuggerEvaluation.prepare tries each candidate, compile-checked in the DetourDebugger world, and runs the code unchanged (value undefined) when none compiles. Coverage today is about 30 unit assertions and 26 snippets (plain and block-wrapped) compared against WebKit's evaluateJavaScript in ExtensionDebuggerRuntimeTests.testCompletionValuesMatchWebKitsOwnScriptEvaluation. The 132.15 review found two tokenizer bugs (a regex after a template's `${`, a string continued over CR LF), so more edge cases likely remain.

The risk to measure: a wrong boundary that still compiles gives a wrong value or, in theory, changes what the code does. Suspect areas:
- regex vs division after `)` or `}` (`if (x) /a/.test(y)`);
- a block vs an object literal at statement start;
- automatic semicolon insertion around `++`/`--`, templates, `[` and `(` after a line break;
- Unicode escapes in identifiers;
- HTML-style comments.

Build a differential test over a few hundred varied snippets, run plain and wrapped in the Claude extension's block. The oracle is WebKit's own script evaluation (evaluateJavaScript in .page) of the same snippet in a fresh page. Any wrong value is a failure; undefined is allowed only where completion values are documented as unreachable (code ending in if/loop/switch/try/label).

Sources for the snippets: hand-written edge cases for the suspect areas above; JavaScript a model writes for browser automation (DOM queries, fetch, JSON, array pipelines, top-level await); and generated combinations. Side-effecting snippets need a fresh page per case, or must be idempotent.

Outcome: fix what the test finds in the tokenizer, or record that replacing it with a real parser (acorn, a decision for the user) is warranted. Keep the test either way, as the oracle for any replacement.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A differential test of at least 300 snippets runs in DetourTests, each plain and block-wrapped, comparing Runtime.evaluate's by-value result with WebKit's own evaluation of the same snippet
- [ ] #2 The snippets cover regex/division ambiguity, block vs object literal, automatic semicolon insertion cases, template literals, comments, Unicode identifiers, top-level await and typical model-written DOM/fetch code
- [ ] #3 No snippet returns a value different from the oracle; undefined is accepted only for the documented unreachable forms, which are listed in the test
- [ ] #4 Every tokenizer bug found is fixed with a unit test, or recorded with the reason it is left
- [ ] #5 The wiki's Runtime.evaluate section states the tested coverage and, if warranted, a recommendation on replacing the tokenizer with a real parser
<!-- AC:END -->
