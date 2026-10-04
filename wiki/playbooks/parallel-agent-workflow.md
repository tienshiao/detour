---
type: Playbook
title: Parallel agent workflow
description: How several agents work on this repository at once without breaking each other — one worktree, build directory and test data directory each, one build at a time, explicit review targets, and integration through a branch a person merges.
tags: [playbook, agents, worktrees, git, review, tests]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:44:19Z }
sources:
  - id: claude-md
    resource: ../../CLAUDE.md
    title: CLAUDE.md (commit checklist, Backlog workflow)
  - id: project-yml
    resource: ../../project.yml
    title: project.yml (test scheme data directory)
  - id: test-setup
    resource: ../../DetourTests/TestEnvironmentSetup.swift
    title: TestEnvironmentSetup.swift (wipes test state at bundle start)
  - id: database
    resource: ../../Detour/Storage/Database.swift
    title: Database.swift (migration names)
  - id: notes-workflow
    resource: "Agent session notes, 2026-09-25 (not in the repository)"
    title: Session notes on the parallel worktree and review workflow
  - id: notes-parallel
    resource: "Agent session notes, 2026-09-12 (not in the repository)"
    title: Session notes on parallel builds and test data directories
  - id: notes-crash
    resource: "Agent session notes, 2026-09-13 (not in the repository)"
    title: Session notes on test host crashes and review targeting
  - id: notes-stale
    resource: "Agent session notes, 2026-09-19 (not in the repository)"
    title: Session notes on stale DerivedData builds
  - id: notes-backlog
    resource: "Agent session notes, 2026-10-03 (not in the repository)"
    title: Session notes on Backlog task numbering across branches
---

A batch of independent tasks can be handed to several agents at once, each
in its own git worktree, with one supervising session that plans,
integrates and reviews. Everything that is shared between them is a way
for one agent to break another: the checkout's index, the stash, the
default DerivedData, the test data directory, the machine's memory, and
the next migration name. This page is the set of rules that kept a batch
of seven tasks from tripping over those.[^notes-workflow]

# When to use

Two or more code tasks that touch different files and can each be tested
alone. Not for tasks that will edit the same functions, and not when a
single build is already slow enough to be the bottleneck: builds do not
run in parallel here (rule 4).

# Steps

## 1. Plan in Backlog first, on the main branch

Create and commit the task files before any branch or worktree is cut.
Backlog numbers a new task from the tasks it can see, so tasks that exist
only on a branch let another branch hand out the same number.[^notes-backlog]

## 2. One worktree per agent, and check where it starts

```bash
git worktree add .claude/worktrees/<task> -b <task> main
```

An automatically created worktree may start from an older commit than the
branch you meant (one batch started about 19 commits behind). Each agent
confirms `git log -1` first and resets to the intended base before doing
anything.[^notes-parallel]

## 3. Per-worktree setup

```bash
xcodegen generate                       # *.xcodeproj is gitignored: no project until this runs
xcodebuild -scheme Detour -configuration Debug build -derivedDataPath "$PWD/.derived"
env TEST_RUNNER_DETOUR_DATA_DIR=DetourTests-<task> \
  xcodebuild -scheme DetourTests -configuration Debug test -derivedDataPath "$PWD/.derived" \
  -only-testing:DetourTests/<Suite> > "$OUT/test.log" 2>&1
```

- A private `-derivedDataPath` per worktree. Never commit it (`.derived`
  is not in `.gitignore` on `main`).
- A private test data directory per run. Without it every run uses
  `~/Library/Application Support/DetourTests/`, and `TestEnvironmentSetup`
  resets shared state at bundle start, so concurrent runs corrupt each
  other.[^notes-parallel]
- Details and the reasons: [build and test](./build-and-test.md).

## 4. One xcodebuild at a time, machine-wide

```bash
while pgrep -x xcodebuild >/dev/null; do sleep 20; done; xcodebuild …
```

Every agent wraps every build and test run in that wait. `pgrep -x`, not
`-f`.[^notes-stale] The supervising session runs a memory watchdog for the
whole batch ([build and test](./build-and-test.md)).

## 5. Agents commit on their own branch, only their own paths

Tell each agent explicitly: the worktree path, the base commit, "commit
only the files of this task", and not to touch other worktrees.

## 6. Integrate

Two ways that worked:

- **Cherry-pick** each agent's commits onto the integration branch
  (`git cherry-pick <sha>`). A dirty working tree is fine when the files
  do not overlap.[^notes-workflow]
- **An integration worktree**, when an agent's branch should be the base:

  ```bash
  git worktree add .claude/worktrees/<task>-int -b <task>-int <agent-branch>
  git diff -- Detour > "$OUT/own.patch"                 # the supervisor's own uncommitted work
  git -C .claude/worktrees/<task>-int apply --3way "$OUT/own.patch"
  ```

  Commit there, point the next agent at that worktree by explicit path,
  and run the tests there too. Backlog edits for the task go in the same
  worktree so they travel with the branch.[^notes-workflow]

**Merging agent-written branches into the main branch is the person's
decision.** If the agent's permission mode refuses the merge, do not reach
the same result another way (a cherry-pick or an applied patch is the same
merge). Prepare the integration branch, state what is on it and what was
tested, and leave the final merge or fast-forward to the person.[^notes-workflow]

## 7. Review with an explicit target

A review run as a forked agent inherits the session's context and can
review the wrong checkout; one reviewed a finished agent worktree instead
of the staged diff.[^notes-crash] Give it:

- the checkout path;
- the git range, or `git diff --cached`;
- the file list;
- "do not edit other worktrees";
- its own `-derivedDataPath` and `TEST_RUNNER_DETOUR_DATA_DIR`.

Fold review fixes into the commit they belong to:

```bash
git commit --fixup <sha>
GIT_SEQUENCE_EDITOR=true git rebase -i --autosquash <base>
```

## 8. Runtime-verify without blocking the editors

To run a long harness while other agents keep editing, build from a
separate worktree at a fixed commit with its own DerivedData, and kill
only the process whose path is that build's
([runtime verification](./runtime-verification.md)).[^notes-parallel]

# Traps

- **Rebasing while anything else runs git in the same checkout.** A
  review fork or another agent holds `index.lock`; the rebase fails with
  "could not detach HEAD" or "could not write index" and can stop half
  way. Wait for the other process to finish. If it already happened,
  repeat `git rebase --continue` until `.git/rebase-merge` is gone before
  touching anything else.[^notes-workflow]
- **Uncommitted Backlog files block a rebase.** Commit them, or set them
  aside first.[^notes-workflow]
- **The stash is shared by every worktree.** Never `git stash pop`: after
  a failed `stash push` (a gitignored path such as `Detour.xcodeproj`
  makes it error out) the next pop takes someone else's entry. Push with a
  unique message, find your entry in `git stash list`, and
  `git stash apply <sha>`. A temporary commit is safer than any stash.[^notes-workflow]
- **Two tasks add the next migration.** Parallel branches each pick the
  same next name (two `"v8"` collided). Rename at integration and update
  the tests that migrate up to a named version.[^notes-parallel]
- **A review fork that returns early.** Its result reads like a progress
  note ("waiting on the finder agents"), and the finders later report raw
  findings to the supervisor with no verify or fix stage. Rerun the review
  or have an agent apply the findings; do not count it as a completed
  review.[^notes-workflow]
- **Different temporary directories.** A sandboxed command and an
  unsandboxed one can see different `$TMPDIR` values. Create worktrees and
  logs under absolute paths.[^notes-crash]
- **Sandboxed shells.** `xcodegen generate`, `xcodebuild`, `pgrep` and
  `log show` need the sandbox off. The `backlog` CLI works inside it, but
  prints a long stack trace when its remote fetch is refused; append
  `2>/dev/null` and read the output.
- **Killing by name.** `pkill Detour` hits every agent's app and any
  installed one. Kill by the pid of your own build path.
- **Codesign timestamp failures** in the middle of a batch: pass
  `OTHER_CODE_SIGN_FLAGS=--timestamp=none` on local `xcodebuild`
  invocations.[^notes-parallel]

# Related

- [Build and test](./build-and-test.md) — build directories, test environment variables, the watchdog.
- [Runtime verification](./runtime-verification.md) — isolated runs and process hygiene.
- [Test host crashes](./test-host-crashes.md) — when an agent's run "fails with zero failures".
- [Session database](../architecture/session-database.md) — the migration list parallel tasks collide on.

[^notes-workflow]: Session notes on the parallel worktree and review workflow
[^notes-parallel]: Session notes on parallel builds and test data directories
[^notes-crash]: Session notes on test host crashes and review targeting
[^notes-stale]: Session notes on stale DerivedData builds
[^notes-backlog]: Session notes on Backlog task numbering across branches
