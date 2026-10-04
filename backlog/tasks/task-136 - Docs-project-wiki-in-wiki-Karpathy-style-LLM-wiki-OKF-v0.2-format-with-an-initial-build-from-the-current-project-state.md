---
id: TASK-136
title: >-
  Docs: project wiki in /wiki (Karpathy-style LLM wiki, OKF v0.2 format) with an
  initial build from the current project state
status: Done
assignee: []
created_date: '2026-10-04 01:57'
updated_date: '2026-10-04 01:58'
labels: []
dependencies: []
references:
  - >-
    https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md
  - 'https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f'
ordinal: 159000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add an LLM-maintained wiki to the repo so knowledge accumulates across sessions instead of being re-derived: architecture, subsystem behaviour, invariants, design decisions with their rejected alternatives, WebKit/AppKit quirks, investigations and runtime-verification playbooks. The wiki lives in /wiki as an Open Knowledge Format (OKF v0.2, https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md) bundle: one markdown concept per file with YAML frontmatter, index.md for progressive disclosure, log.md for history. Sources are the repo itself (code, docs/, Backlog tasks) plus session notes; the wiki summarises and cross-links them and does not replace CLAUDE.md (rules) or Backlog (task status). Built on branch wiki (worktree off main), so the initial pages describe main; work that exists only on epic-claude-extension is covered as in-flight and gets ingested when the epic merges.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 wiki/ is a conformant OKF v0.2 bundle: every non-reserved .md has parseable frontmatter with a non-empty type; index.md and log.md follow the spec's structure; the root index declares okf_version
- [x] #2 A conventions page records the schema: page types, frontmatter fields, source and link conventions, and the ingest / query / lint workflows
- [x] #3 Initial pages cover architecture, tabs, sidebar, features, extensions, platform quirks, playbooks and decisions, each citing its sources (code paths, docs, Backlog tasks)
- [x] #4 A lint script reports frontmatter problems, broken links and sources, orphan pages and index drift, and regenerates the per-directory indexes
- [x] #5 CLAUDE.md tells future sessions when to read and when to update the wiki
<!-- AC:END -->



## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Read the OKF v0.2 spec and the LLM-wiki pattern; fix the wiki's schema (types, frontmatter, link and source conventions, workflows) in wiki/meta/conventions.md.
2. Fix the page manifest (one directory per area, depth 1) so pages written in parallel can cross-link.
3. Write the pages per area with parallel agents, each from code + docs/ + Backlog tasks + session notes, citing sources.
4. scripts/wiki-lint.py: conformance, links, sources, orphans, index drift; regenerates per-directory indexes.
5. Root index.md and log.md by hand; lint until clean; point CLAUDE.md at the wiki.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Built on branch wiki (worktree .claude/worktrees/wiki, cut from main at 4b31645).

What exists: wiki/ with 98 concept pages (24 Component, 18 Concept, 14 Playbook, 13 Feature, 12 Decision, 6 Platform Quirk, 5 Overview, 3 Investigation, 2 Reference, 1 Guide) in architecture/, tabs/, sidebar/, features/, extensions/, platform/, playbooks/, decisions/, meta/; a hand-written root index.md (okf_version 0.2) and log.md; generated per-directory index.md files; scripts/wiki-lint.py; a Wiki section in CLAUDE.md.

Decisions: (1) concepts sit exactly one directory below wiki/ so every relative path has the same shape; (2) links between pages are relative, not OKF's bundle-absolute form, because the bundle is a repo subdirectory and absolute links would not resolve on GitHub or in an editor; (3) Backlog tasks are cited as backlog:TASK-N, not by file path, because task files are renamed and moved; (4) the wiki describes main — work that exists only on epic-claude-extension has one draft page (extensions/claude-extension-epic.md, stale_after 2026-11-03) built from the TASK-132 tasks, including the branch's copies of TASK-132.1/.2/.3/.8, and cites three branch commits that would dangle if the branch is rebased; (5) all pages start unverified (no verified key): they were written by agents from code, docs/, tasks and session notes and have not had an independent check.

Validation: python3 scripts/wiki-lint.py reports 0 errors, 0 warnings (frontmatter, links, source paths, task IDs, footnote labels, orphans, index drift). A grep for home paths, names, addresses and signing identities found nothing personal. No build or tests were run, and no /code-review or /verify: the change is documentation plus one standalone Python script (needs PyYAML) that touches no app code. Not verified: page content against the running app; three pages were read end to end by the integrator, the rest only linted.

Follow-ups filed from what the writers found: the Private-tab palette leak, the unscoped chrome.history.search, the CRX length trap, the stale docs/ files, and the removePort hypothesis.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added wiki/ (OKF v0.2 bundle, 98 unverified pages across eight areas plus the schema in wiki/meta/conventions.md), scripts/wiki-lint.py (conformance, links, sources, orphans, index regeneration) and a Wiki section in CLAUDE.md. Lint: 0 errors, 0 warnings. No app code changed; no tests or runtime check were needed or run.
<!-- SECTION:FINAL_SUMMARY:END -->
