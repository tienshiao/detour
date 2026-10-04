---
type: Guide
title: Wiki conventions
description: The schema of this wiki — what belongs here, page types, frontmatter, link and source rules, and the ingest / query / lint workflows.
tags: [meta, schema]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:22:25Z }
sources:
  - id: okf-spec
    resource: https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md
    title: Open Knowledge Format (OKF) v0.2 specification
  - id: llm-wiki
    resource: https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f
    title: Andrej Karpathy, "LLM Wiki" idea file
---

# Purpose

This wiki is the project's accumulated knowledge: how the subsystems work,
which invariants hold, why decisions went the way they did, what WebKit and
AppKit do that the documentation does not say, and how to verify things at
runtime. It follows the LLM-wiki pattern[^llm-wiki]: agents write and
maintain it, people read it and direct it, and every session leaves it a
little better instead of re-deriving the same facts.

The format is the Open Knowledge Format v0.2[^okf-spec]: a directory of
markdown files with YAML frontmatter. `wiki/` is the bundle root.

# What belongs here, and what does not

| Kind of information | Home |
|---|---|
| Rules an agent must follow (build commands, TDD policy, commit checklist) | `CLAUDE.md` |
| Committed work, its status, plans and notes | Backlog (`backlog` CLI) |
| Long-form design documents written for one feature | `docs/` |
| Knowledge that outlives a task: behaviour, invariants, rationale, quirks, investigations, playbooks | **this wiki** |

Three layers, as in the LLM-wiki pattern:

1. **Sources** — the code, `docs/`, Backlog tasks, git history, WebKit's
   source, and session notes. The wiki never edits them.
2. **The wiki** — concept pages that summarise, connect and explain the
   sources. Agents own this layer.
3. **The schema** — this page, plus the pointer in `CLAUDE.md`.

Do not record: task status ("TASK-90 is Done" goes stale; cite the task as a
source instead), secrets, personal or machine-specific details, or text
copied wholesale from a source that could be linked.

# Layout

```
wiki/
  index.md            root listing; carries okf_version
  log.md              history of wiki changes, newest first
  meta/               this schema
  architecture/       app structure, state, ownership, persistence
  tabs/               tab model and rules: lifecycle, pinning, splits, archive
  sidebar/            sidebar rows, drag and drop, paging, focus
  features/           user-facing features outside the tab model
  extensions/         Web Extension support
  platform/           WebKit and AppKit behaviour found the hard way
  playbooks/          how to build, verify, debug and diagnose
  decisions/          design decisions and the alternatives they rejected
```

Every concept sits exactly one directory below the bundle root. That keeps
paths uniform: a sibling is `./page.md`, another area is `../area/page.md`,
and a repository file is `../../path/from/repo/root`.

Each directory has an `index.md` listing its pages. `index.md` and `log.md`
are reserved names and are never concept pages.

A concept's ID is its path without `.md` (`tabs/split-tabs`). Filenames are
lowercase kebab-case and name the thing, not the task that produced it.
Renaming a page means fixing every inbound link in the same change.

# Page types

`type` is the only field OKF requires. This wiki uses a small fixed set;
add a type here before using a new one.

| Type | Use for | Conventional sections |
|---|---|---|
| `Overview` | A map of an area: what exists and how the parts relate | `# Summary`, `# Parts`, `# How they connect` |
| `Component` | A unit of code (a class, a file group) | `# Role`, `# How it works`, `# Invariants`, `# Gotchas`, `# Tests` |
| `Concept` | A domain idea or rule that spans components | `# Summary`, `# Rules`, `# Where it lives` |
| `Feature` | A user-facing capability | `# What it does`, `# How it works`, `# Edge cases`, `# Tests` |
| `Decision` | A choice that was made, with what was rejected | `# Context`, `# Decision`, `# Alternatives rejected`, `# Consequences` |
| `Investigation` | A root-cause finding | `# Symptom`, `# Root cause`, `# Evidence`, `# Fix`, `# Open questions` |
| `Platform Quirk` | WebKit / AppKit / macOS behaviour that is not ours to change | `# Behavior`, `# Why it matters here`, `# Workaround` |
| `Playbook` | A procedure to follow | `# When to use`, `# Steps`, `# Traps` |
| `Reference` | A lookup table or a pointer to external material | free-form |
| `Guide` | Pages about the wiki itself | free-form |

Sections are conventions, not requirements: drop one that would be empty,
add one the page needs. Most pages end with `# Related`, a short list of
links with a phrase saying how each page relates.

# Frontmatter

```yaml
---
type: Component                       # required
title: TabStore                       # display name
description: One sentence, shown in the index.   # no line breaks
resource: ../../Detour/Browser/TabStore.swift    # optional: the one asset the page is about
tags: [tabs, state]                   # lowercase, short, cross-cutting
status: stable                        # draft | stable | deprecated
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:22:25Z }
verified:                             # optional; see Trust
  - { by: human:tma, at: 2026-10-05T17:00:00Z }
stale_after: 2026-12-01T00:00:00Z     # optional; see Freshness
sources:
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift
  - id: task-117
    resource: backlog:TASK-117
    title: Closed-tab stack reads from the database only
---
```

- `title` and `description` are expected on every page. `description` is
  one sentence that would let a reader decide whether to open the page.
- `resource` is for pages about one concrete asset (usually a `Component`).
  Leave it out when the page is about an idea.
- `generated.at` is the time of the last meaningful content change, as an
  ISO 8601 datetime with a UTC offset (`date -u +%Y-%m-%dT%H:%M:%SZ`).
  Update it, and `generated.by`, whenever the body changes in substance.
- Actors: `claude-code/<model id>` for an agent, `human:<id>` for a person,
  `process:<id>` for automation.
- YAML that contains `: ` or starts with a quote, bracket or backtick must
  be quoted.

## Sources

`sources` lists what the page was derived from. `resource` takes one of:

| Form | Example | Meaning |
|---|---|---|
| Repository path, relative to the page | `../../Detour/Browser/TabStore.swift` | A file or directory in this repo |
| Bundle page, relative to the page | `../tabs/split-tabs.md` | Another wiki page |
| `backlog:TASK-N` | `backlog:TASK-90` | A Backlog task; read it with `backlog task view TASK-90 --plain` |
| `commit:<sha>` | `commit:ccde7e1` | A commit |
| Absolute URL | `https://github.com/WebKit/WebKit/blob/main/…` | External material |
| Free text | `Agent session notes, 2026-09-20 (not in the repository)` | A source that cannot be followed |

Tasks are cited by ID, not by file path, because task files are renamed and
moved as their status changes.

Give a source an `id` when the body cites it. Attribute a claim with a
markdown footnote whose label is that `id`:

```markdown
A low-memory flush frees only about 15% of the surfaces.[^task-104]

[^task-104]: TASK-104
```

Footnote the claims a reader could not check by opening the page's main
source: measurements, behaviour observed at runtime, anything learned from
an experiment. Plain descriptions of code do not need one.

## Trust

Trust comes from `verified`, as OKF defines it:

- no `verified` — **unverified**: written by an agent, not re-checked.
- `verified` by an agent or process only — **machine-confirmed**: a later
  pass compared the page with its sources.
- `verified` by `human:<id>` — **human-reviewed**.

A page's author does not verify its own page in the same pass. Add a
`verified` entry when you re-read a page against the current code and it
holds; remove the entries when you change the page's substance.

## Freshness

- `status: draft` — incomplete, or about something planned or in flight.
- `status: stable` — describes the project as it is. The default.
- `status: deprecated` — the thing is gone. Keep the page for inbound
  links, say what replaced it in the first line.
- `stale_after` — set it on pages about work in progress or about measured
  platform behaviour that a macOS update could change. When the instant has
  passed, re-check the page before relying on it.

# Body

- No `# Title` heading; the title is in the frontmatter. Top-level `#`
  headings are the sections.
- Open with one short paragraph that states the point of the page.
- Prefer tables, lists and short code blocks to long prose.
- Name symbols in backticks (`TabStore.moveTab`). Link files with a path
  relative to the page: `[TabStore.swift](../../Detour/Browser/TabStore.swift)`.
  No line numbers; they rot.
- Dates are absolute (`2026-09-28`), never "last week".
- State what is known and how. Mark what is not: "not verified in a signed
  build", "measured once on macOS 15.6".
- One concept per page. When a section grows into its own subject, split it
  out and link to it.
- When two sources disagree (a design document and the code, say), the code
  wins; note the disagreement on the page.

## Links

Links between pages are ordinary relative markdown links:
`[split tabs](../tabs/split-tabs.md)`. OKF also allows bundle-absolute links
(`/tabs/split-tabs.md`); this wiki does not use them, because the bundle is
a subdirectory of the repository and they would not resolve on GitHub or in
an editor.

Link the first mention of another page's subject. A link to a page that
does not exist yet is allowed and marks a page worth writing; the lint
lists them.

# Workflows

## Query — before working in an area

1. Read `wiki/index.md`, then the index of the relevant directory.
2. Read the pages that match. Follow their links and their sources.
3. Treat an unverified or stale page as a strong hint, not as fact: check
   the code before acting on a claim that matters.
4. If answering took real synthesis that no page holds, file the answer as
   a page.

## Ingest — after learning something

Triggers: a task is finished; an investigation found a cause; a runtime
check showed behaviour nobody had written down; a design choice was made;
a page turned out to be wrong.

1. Find the pages the new knowledge touches (`grep -ril <term> wiki/`).
   Update those first; create a page only for a subject that has none.
2. Update every page the change affects, not only the obvious one: the
   overview that lists it, the pages that link to it, the decision it
   overturns.
3. Add the sources, footnote the non-obvious claims, set `generated`.
4. Run `python3 scripts/wiki-lint.py --fix` to refresh the directory
   indexes, then fix what it reports.
5. If a directory was added, add it to the root `index.md`.
6. Add a line to `log.md`.

Wiki-only changes are documentation: they need no code review or runtime
check before committing.

## Lint — keeping it healthy

`python3 scripts/wiki-lint.py` checks OKF conformance, frontmatter fields,
links, sources, footnote labels, orphan pages, index drift, and pages past
`stale_after`. `--fix` rewrites the per-directory `index.md` files from
frontmatter.

The script cannot judge content. Periodically, or when asked, also look
for: pages that contradict each other or the code, claims a newer task
has overturned, subjects mentioned on several pages with no page of their
own, and pages that have grown past one subject.

# index.md and log.md

`index.md` files have no frontmatter (the root one carries only
`okf_version`). Entries are `* [Title](path) - description`, grouped under
`#` headings. The root index is written by hand and lists the directories
and a few starting points; directory indexes are generated.

`log.md` is newest first, grouped under ISO date headings, one bullet per
change with a bold leading word (`**Creation**`, `**Update**`,
`**Ingest**`, `**Lint**`, `**Deprecation**`) and links to the pages
touched:

```markdown
## 2026-10-04
* **Ingest**: TASK-104 follow-up — added the vmmap recipe to [GPU IOSurface limit](platform/gpu-iosurface-limit.md).
```

[^okf-spec]: Open Knowledge Format (OKF) v0.2 specification
[^llm-wiki]: Andrej Karpathy, "LLM Wiki" idea file
