---
type: Decision
title: Extensions are off in Private unless allowed
description: Why extensions do not load in the Private profile until the user allows each one, why that was implemented as a changed default rather than a migration, and what was rejected.
tags: [extensions, privacy, incognito, decision]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:48:49Z }
sources:
  - id: database
    resource: ../../Detour/Storage/Database.swift
    title: Database.swift (extensionEnabledByDefault)
  - id: profile
    resource: ../../Detour/Browser/Profile.swift
    title: Profile.swift (hasAccessToPrivateData in loadExtensionContext)
  - id: default-tests
    resource: ../../DetourTests/ExtensionPrivateDefaultTests.swift
    title: ExtensionPrivateDefaultTests.swift
  - id: plan
    resource: ../../docs/1password-integration-plan.md
    title: 1Password integration plan (Extensions are off in Private unless allowed)
  - id: task-70
    resource: backlog:TASK-70
    title: Tracking prevention deletes an extension origin's script-written storage
  - id: task-73
    resource: backlog:TASK-73
    title: The Private profile's extension worker stalls in an ephemeral data store
  - id: task-74
    resource: backlog:TASK-74
    title: Do not load extensions in the Private profile unless the user allows each one
---

# Context

On 2026-09-13 it turned out that extension pages did not run in their
profile's data store at all (see
[data store and ITP](../extensions/data-store-and-itp.md)). The fix moved
them to each profile's own store, but in the Private profile that made
1Password's worker stop responding, so Private was left on WebKit's shared
default store. That store is persistent and on disk: anything an extension
wrote during a Private session, 1Password's item cache above all, outlived
the session and the app.[^task-74]

Until then extensions ran in Private for a reason nobody had chosen: there
was no per-profile row for them, and a missing row meant "enabled".

# Decision

Adopt Chrome's incognito default. **An extension is off in the built-in
Private profile unless the user turns on "Allow in Private" for it.**

- The rule is one function, `AppDatabase.extensionEnabledByDefault(inProfile:)`:
  a missing `profileExtension` row means off for `TabStore.incognitoProfileID`
  and on for every other profile. All enabled-state readers go through it.
- The switch lives in Extension settings, next to the global Enabled switch,
  and writes only the Private profile's row. It takes effect at once.
- A context loaded into the Private profile gets `hasAccessToPrivateData`,
  which is exactly what the user's opt-in means to WebKit.
- Installing, updating, globally re-enabling and pinning an extension never
  change its Private state. Install and update write no per-profile row; a
  pin inserts a row carrying the profile's default.

The default was kept after the storage leak that prompted it was closed
(Private extension pages now run in the profile's ephemeral store). Opting in
per extension is the state a user can be presumed to want in a private
window, whatever the storage does.

# Alternatives rejected

| Alternative | Why not |
|---|---|
| Leave extensions on in Private | It was the leak, and it was never a choice anyone made |
| A one-time migration that writes "off" rows for every installed extension (the original plan) | Unnecessary. The database had no Private rows, so changing what a missing row means *is* the behaviour change, and an explicit allow made later is a row that keeps reading on[^task-74] |
| Wait for the ephemeral-store fix and keep the old default | The default closes the leak at once and stands on its own; when it was decided, the cause of the worker stall in the ephemeral store was not yet known[^task-73] |

# Consequences

- An allowed extension's context loads in Private at every launch, before a
  Private window exists, and stays until quit.
- The rule is keyed on the built-in Private profile's id, not on
  `isIncognito`. Only one incognito profile exists in production.
- Uninstalling removes the allow with the extension's rows. Chrome remembers
  it across a reinstall; Detour does not.
- A database that somehow held Private rows with `isEnabled = 1` from before
  the change would read them as an allow. None existed when it shipped.
- The switch is shown disabled while the extension is globally off, and
  keeps its saved value.
- Without `hasAccessToPrivateData` an allowed extension would load and do
  nothing: WebKit hides Private windows and tabs from the context and injects
  no content scripts there. Verified at runtime: content scripts inject in
  Private tabs only with the allow on.[^task-74]
- The same flag turned out to be the cause of the worker "stall" that had
  kept Private on the default store, which is what let the ephemeral store
  be adopted the same day.[^task-73]

# Related

- [Private profile extensions](../extensions/private-profile-extensions.md) — the full rules and the WebKit gate
- [Incognito](../architecture/incognito.md) — the Private profile
- [Extension manager](../extensions/extension-manager.md) — per-profile enablement
- [Never replace chrome globals](./never-replace-chrome-globals.md) — another decision forced by a WebKit behaviour found through 1Password

[^task-73]: The Private profile's extension worker stalls in an ephemeral data store
[^task-74]: Do not load extensions in the Private profile unless the user allows each one
