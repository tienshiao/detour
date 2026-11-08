---
type: Decision
title: Extensions are on only where installed or turned on
description: Why a missing profileExtension row now means off in every profile, so a new profile starts with no extensions and an install is on only in the profile it came from; the migration that kept existing setups unchanged, how the install's profile is chosen, and what was rejected.
tags: [extensions, profiles, privacy, decision]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-08T23:30:00Z }
sources:
  - id: database
    resource: ../../Detour/Storage/Database.swift
    title: Database.swift (extensionEnabledByDefault, migration v24)
  - id: install-target
    resource: ../../Detour/Extensions/Runtime/ExtensionInstallTarget.swift
    title: ExtensionInstallTarget.swift
  - id: manager
    resource: ../../Detour/Extensions/Runtime/ExtensionManager.swift
    title: ExtensionManager.swift (install turningOnIn, turnOnInAllProfiles)
  - id: settings
    resource: ../../Detour/Browser/Settings/ExtensionsSettingsViewController.swift
    title: ExtensionsSettingsViewController.swift (Turn On in All Profiles)
  - id: scope-tests
    resource: ../../DetourTests/ExtensionProfileScopeTests.swift
    title: ExtensionProfileScopeTests.swift
  - id: task-312
    resource: backlog:TASK-312
    title: "Extensions: on only in the profile they were installed from; a new profile starts with none"
  - id: task-74
    resource: backlog:TASK-74
    title: Do not load extensions in the Private profile unless the user allows each one
---

# Context

Until 2026-11-08 a missing `profileExtension` row meant **on** in every
normal profile and off only in the built-in Private profile
([private extensions opt-in](./private-extensions-opt-in.md)). So a profile
created in Settings started with every installed extension on, and an
extension installed later was on in every normal profile. A profile kept
apart for banking could not stay extension-free without the user turning
each extension off there, and again after every new install.[^task-312]

# Decision

As Chrome does per profile (user decision, 2026-11-08):

- `AppDatabase.extensionEnabledByDefault(inProfile:)` answers **off** for
  every profile. An extension is on in a profile only where a row says so.
- **A new profile starts with no extensions.** `TabStore.addProfile` writes
  no row, and `ExtensionManager.profileWasAdded` therefore loads nothing.
- **An install is on in exactly the profile it was installed from.**
  `ExtensionManager.install(from:publicKey:options:turningOnIn:)` writes that
  profile's ON row after the installer's `extension` row and before the
  asynchronous load, so the reconcile loads the context there and nowhere
  else.
- **An update never changes where an extension is on.** The update, reload
  and staged-update paths pass no target (or bypass the manager, at launch);
  a reinstall keeps every row and turns the extension on in the profile it
  was reinstalled from.
- **Private is unchanged**: off unless "Allow in Private". The Private
  profile is never an install's target.
- Settings › Extensions has **Turn On in All Profiles** for the selected
  extension (every normal profile, never Private), through the same
  `setEnabled(id:profileIDs:enabled:)` path the Profiles pane's switches use,
  so each context loads at once. Below it a line says which profiles have it
  on ("On in “Work”.", "On in all profiles.", "Off in every profile.").

## Which profile an install is from

`ExtensionInstallTarget.resolveProfile(candidates:normalProfiles:)` takes the
first candidate that is a normal profile (not Private, still in `TabStore`),
else the first normal profile in `TabStore` order:

| Install | Candidates |
|---|---|
| Chrome Web Store, or any CRX link, in a browser tab | the profile of the tab the package was opened in (read when the response arrives, resolved again after the download) |
| CRX link in a Quick Detour | that window's profile |
| Extensions › Install Extension… (unpacked folder) | every browser window front to back (`browserWindowControllersFrontToBack`), each window's active space's profile |
| Settings › Extensions › Load Unpacked Extension… | the same; Settings is skipped, so it is the window behind Settings |

So a Private window in front gives the next normal window's profile, a CRX
from a Private tab or Private Quick Detour goes to the first normal profile,
and with no window at all it is the first normal profile. The confirmation
alert names the profile ("It will be turned on in the “Work” profile.") and
so does "Extension Installed", which also points at Turn On in All Profiles
and Settings › Profiles.

## The migration

Migration v24 writes the old implicit ON as explicit rows: an ON row for
every normal profile × installed extension that has none (`INSERT OR
IGNORE`, the Private id spelled out as in v10 and v19). Rows that exist — an
explicit off, a pin, a Private allow or refusal — are untouched, Private gets
nothing, and a globally disabled extension gets its rows too, so turning it
back on restores it where it was. Existing setups behave exactly as before;
only profiles created afterwards start empty.[^task-312]

# Alternatives rejected

| Alternative | Why not |
|---|---|
| Keep the default and only make new profiles start empty (write OFF rows at `addProfile`) | Every later install would still be on in every profile, the Banking case again; and OFF rows for every profile × extension grow with both |
| Ask at install which profiles to turn it on in | An extra choice on every install; Chrome does not ask. Turn On in All Profiles covers the "everywhere" case (1Password across four profiles) in one click |
| Flip the default without a migration, as TASK-74 did for Private | TASK-74 could, because no Private rows existed; here every existing normal profile relied on the missing row, so flipping alone would have turned every extension off everywhere |
| Install into the first profile when the front window is Private | The frontmost normal window behind it is closer to what the user was doing; the first profile is only the last resort |

# Consequences

- A hand-seeded extension (the [seeding playbook](../playbooks/seeding-extensions.md))
  needs an ON `profileExtension` row per profile it should run in.
- Tests that load through the real rule write the row a real profile would
  have (`turnOnTestExtension` in `ExtensionTestSupport`).
- Uninstalling deletes all rows; a reinstall starts with only its target on.
- A profile deleted while a download was in flight is no target: the target
  is resolved again after the download, falling back to the first normal
  profile.

# Related

- [Private extensions opt-in](./private-extensions-opt-in.md) — the earlier, Private-only default this generalises
- [Extension manager](../extensions/extension-manager.md) — the enabled rule and the install path
- [Installer and CRX](../extensions/installer-and-crx.md) — the ways in
- [Settings](../features/settings.md) — the Extensions and Profiles panes

[^task-312]: TASK-312
