---
id: TASK-312
title: >-
  Extensions: on only in the profile they were installed from; a new profile
  starts with none
status: To Do
assignee: []
created_date: '2026-11-08T22:20:00Z'
labels:
  - extensions
  - privacy
dependencies: []
priority: medium
ordinal: 374000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
User decision, Nov 8 2026. Today a missing profileExtension row means ON in every normal profile (OFF only in Private, TASK-74), so a new profile starts with every installed extension on and an extension installed later is on in every normal profile. A Banking profile can't stay extension-free. Change, as Chrome does per profile: a new profile starts with no extensions on; a new install is on only in the profile it was installed from (Chrome Web Store tab: that tab's profile; the app's install command for a .crx/folder: the front window's profile; Settings › Extensions: the front window's profile, and Settings says which); Private unchanged (off unless Allow in Private); an update never changes where an extension is on. A migration writes today's implicit ON as explicit rows for every normal profile × installed extension, so existing setups don't change. A 'Turn On in All Profiles' action in Settings › Extensions covers users who want an extension everywhere (e.g. 1Password across four profiles). Follow-up text: privacy guide step 2 (TASK-292.13, website branch privacy-guide) and any page that says extensions are on in every profile.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A missing profileExtension row means off in every profile (Database.extensionEnabledByDefault), and a migration records ON rows for every existing normal profile × installed extension that had no row, so nothing changes for existing setups (migration test)
- [ ] #2 A new profile starts with no extensions loaded or enabled
- [ ] #3 Installing (Web Store tab, the install command, Settings) turns the extension on in exactly the profile it was installed from and loads it there only; reinstalling or updating an installed extension keeps its per-profile choices
- [ ] #4 Settings › Extensions offers Turn On in All Profiles (normal profiles; not Private), and says which profile a Settings install went to
- [ ] #5 Tests cover the default, the migration, each install path's target profile, updates keeping rows, Private unchanged; the change is checked at runtime with /verify
- [ ] #6 Wiki updated; the privacy guide (TASK-292.13 branch) and any website page that describes the old default are updated on a branch held for the release
<!-- AC:END -->
