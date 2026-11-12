---
id: TASK-321
title: 'About: show the git commit the app was built from'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-11T08:00:00Z'
updated_date: '2026-11-12T02:29:00Z'
labels:
  - about
  - build
dependencies: []
priority: low
type: feature
ordinal: 383000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The user could not tell whether their running Detour (0.4.2 (10), pid 7900) contained the TASK-314 fix: the version and build number alone don't say which commit a locally built or installed app came from. Stamp the commit into the built app's Info.plist at build time (DetourGitCommit: short hash, '-dirty' when tracked files other than Info.plist and backlog/ differ from HEAD) and show it in About Detour next to the build number.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A build writes DetourGitCommit into the built Info.plist on every build, before signing, without modifying the source Info.plist
- [x] #2 About Detour shows Version X (build · hash), and just the build number when the key is missing
- [x] #3 build-release.sh's Info.plist bump alone does not mark a release build dirty
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-11: 'Stamp git commit' postBuildScript in project.yml (no dependency analysis, runs before code signing; the target already has ENABLE_USER_SCRIPT_SANDBOXING = NO) writes DetourGitCommit (10-char short hash, -dirty) into $TARGET_BUILD_DIR/$INFOPLIST_PATH. BuildInfo (Detour/App/BuildInfo.swift) passes '<build> · <commit>' as the About panel's .version option. Checked: BuildInfoTests 5/5; built Debug app carries 3cb6022e4b-dirty (dirty = uncommitted edits), codesign --verify --strict passes, source Info.plist unchanged; in a scratch worktree a CFBundleVersion bump plus a backlog/ change stays clean and a README change goes dirty. Not yet: the About panel seen at runtime (/verify), /code-review, a Release build through build-release.sh.

2026-11-11 review (/code-review --fix): stamp script rewritten — git --no-optional-locks (no index.lock during parallel git work), untracked non-ignored files under Detour/ count as dirty, plist rewritten only when the stamp changes (avoids a re-sign every build), a stale stamp is removed when there is no commit. Skipped: narrowing the Info.plist exclusion to the version keys (more parsing for little gain), skipping testBuiltAppCarriesTheCommit outside git (would weaken it), the nonisolated annotation. Verified: BuildInfoTests 5/5 (.derived); Debug app built from this tree carries 3cb6022e4b-dirty, codesign --verify --strict passes; runtime: About Detour opened via the menu in an isolated (DETOUR_DATA_DIR) instance reads 'Detour, Version 0.4.2 (10 · 3cb6022e4b-dirty)'. Release build through build-release.sh follows as 0.4.3.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
About Detour shows the commit the app was built from: a 'Stamp git commit' post-build phase writes DetourGitCommit (short hash, -dirty) into the built Info.plist, BuildInfo passes 'build · hash' as the About panel's version. Tests: BuildInfoTests 5/5. Runtime: About panel read via Accessibility in an isolated Debug instance. Wiki: release playbook Build table. Not yet seen: a Release build's stamp (0.4.3 is the first).
<!-- SECTION:FINAL_SUMMARY:END -->
