---
type: Playbook
title: Seeding extensions
description: How to put an extension into an isolated Detour profile by hand for a runtime check — the files, the database rows (including the permission rows a real install writes), a fake native host, and readable worker console output.
tags: [playbook, extensions, runtime, verify, seeding]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:44:19Z }
sources:
  - id: database
    resource: ../../Detour/Storage/Database.swift
    title: Database.swift (extension, extensionPermission, profileExtension tables)
  - id: extension-manager
    resource: ../../Detour/Extensions/Runtime/ExtensionManager.swift
    title: ExtensionManager.swift (load path, declared-permission recording, polyfill injection)
  - id: installer
    resource: ../../Detour/Extensions/Installer/ExtensionInstaller.swift
    title: ExtensionInstaller.swift (what a real install writes)
  - id: permission-record
    resource: ../../Detour/Extensions/Storage/Models/ExtensionPermissionRecord.swift
    title: ExtensionPermissionRecord.swift (type and status raw values)
  - id: nm-host
    resource: ../../Detour/Extensions/Runtime/NativeMessagingHost.swift
    title: NativeMessagingHost.swift (manifest search directories)
  - id: test-support
    resource: ../../DetourTests/ExtensionTestSupport.swift
    title: ExtensionTestSupport.swift (FakeNativeMessagingHost)
  - id: test-extensions
    resource: ../../TestExtensions
    title: TestExtensions (api-explorer, hello-world, hello-world-module)
  - id: task-63
    resource: backlog:TASK-63
    title: Reinstalling or updating an extension overwrites a saved nativeMessaging denial (declared permissions are recorded only where no decision is saved)
  - id: task-99
    resource: backlog:TASK-99
    title: Give each context a stable base URL so extension storage survives a relaunch
  - id: task-74
    resource: backlog:TASK-74
    title: Extensions are off in Private unless allowed
  - id: notes-seeding
    resource: "Agent session notes, 2026-10-03 (not in the repository)"
    title: Session notes on seeding extensions for runtime checks
  - id: notes-logs
    resource: "Agent session notes, 2026-09-12 (not in the repository)"
    title: Session notes on reading the unified log during harness runs
---

A runtime check of extension behaviour needs an extension installed in the
isolated profile. The normal ways in (Develop > Load Unpacked Extension…,
or a CRX install) go through an open panel or the network. For an
unattended run it is quicker to place the files and the database rows
yourself. The catch is that a real install writes more than the
`extension` row.

# When to use

- A `/verify`-style run ([runtime verification](./runtime-verification.md))
  that needs a working extension from launch, with no UI driving.
- A harness that measures worker lifetime, native messaging or storage in
  the real app rather than in the test host.

If the check can be an XCTest, prefer that:
[testing extensions](../extensions/testing-extensions.md) lists the
fixtures that load an extension into a real context without touching a
profile on disk.

# Steps

## 1. Create the data directory

Launch the isolated build once so `browser.db` exists with the current
schema, then quit it.

```bash
DATA="$HOME/Library/Application Support/DetourVerifyExt"
```

## 2. Copy the extension

```bash
ID=hello-world-seed          # any id; see the note on ids below
mkdir -p "$DATA/Extensions"
cp -R TestExtensions/hello-world "$DATA/Extensions/$ID"
```

`basePath` must be this copy, never the folder in the repository: at every
load `ExtensionManager` writes its polyfill files into `basePath` and
patches the service worker source and `manifest.json` there.

Ids: a real unpacked install gets a UUID, or, when the manifest has a
`key`, the derived 32-letter id. Use the real id when something checks it,
such as a native host's `allowed_origins` (`chrome-extension://<id>/`).

## 3. Insert the rows

```bash
sqlite3 "$DATA/browser.db" <<SQL
INSERT INTO extension (id, name, version, manifestJSON, basePath, isEnabled, installedAt, source)
VALUES ('$ID', 'Hello World', '1.0.0',
        readfile('$DATA/Extensions/$ID/manifest.json'),
        '$DATA/Extensions/$ID', 1, strftime('%s','now'), 'unpacked');

-- one row per manifest "permissions" entry: permissionType 0, status 0 (granted)
INSERT INTO extensionPermission (extensionID, permissionKey, permissionType, status, grantedAt)
VALUES ('$ID', 'storage', 0, 0, strftime('%s','now'));

-- one row per "host_permissions" pattern: permissionType 1
-- INSERT INTO extensionPermission VALUES ('$ID', '<all_urls>', 1, 0, strftime('%s','now'));
SQL
```

| Column | Value |
|---|---|
| `extension.manifestJSON` | a blob; the on-disk `manifest.json` is read first at load and this is only the fallback, so the file's bytes are fine |
| `extension.source` | `unpacked` (no update polling) |
| `extensionPermission.permissionType` | 0 API permission, 1 match pattern (`ExtensionPermissionType`) |
| `extensionPermission.status` | 0 granted, 1 denied (`ExtensionPermissionStatus`) |

**The permission rows are not optional.** A real install records every
declared permission and host pattern as granted
(`AppDatabase.recordDeclaredPermissions`, called from the install path);
the load path only restores saved decisions. With no rows, nothing is
granted.[^notes-seeding]

To run the extension in the Private profile as well, add a
`profileExtension` row for the built-in Private profile id
(`TabStore.incognitoProfileID`) with `isEnabled` 1; a missing row means
off there and on everywhere else
([private profile extensions](../extensions/private-profile-extensions.md)).

## 4. Launch with readable console output

```bash
DETOUR_DATA_DIR=DetourVerifyExt "$APP/Contents/MacOS/Detour" -ExtensionConsoleLogPublic YES &
```

`-ExtensionConsoleLogPublic YES` puts the flag in the argument domain for
this process only, so nothing is persisted. Then:

```bash
/usr/bin/log show --last 5m --info --debug --predicate \
  "processIdentifier == <pid> AND subsystem BEGINSWITH 'com.detour'"
```

A working seed shows, in `EXT-LOAD`, `Context loaded for <id>, baseURL:
webkit-extension://…`, and the worker's console output as `[SW <id>] …`
in `extension-polyfill`.

## 5. A fake native host, if the extension uses native messaging

Debug builds search `DETOUR_NATIVE_MESSAGING_HOSTS_DIR` first. A host that
connects and then says nothing is enough to hold a port open:

```bash
HOSTS="$OUT/nm-hosts"; mkdir -p "$HOSTS"
printf '#!/bin/sh\nexec sleep 100000\n' > "$HOSTS/fake-host.sh"; chmod 755 "$HOSTS/fake-host.sh"
cat > "$HOSTS/com.detour.fake_host.json" <<JSON
{ "name": "com.detour.fake_host", "description": "fake", "path": "$HOSTS/fake-host.sh",
  "type": "stdio", "allowed_origins": ["chrome-extension://$ID/"] }
JSON
DETOUR_NATIVE_MESSAGING_HOSTS_DIR="$HOSTS" DETOUR_DATA_DIR=DetourVerifyExt "$APP/Contents/MacOS/Detour" &
```

This is the same fixture `FakeNativeMessagingHost` builds for the tests.
To find the host processes, `pgrep -f 'sleep 100000'`: because of the
`exec`, the script's own path never appears in the process list.[^notes-logs]
Use a distinctive sleep argument per run so you count only your own.

# Traps

- **"The background content failed to load due to an error", three times,
  then silence.** The seed has no `extensionPermission` rows. APIs behind
  a permission (`chrome.storage`, …) are undefined, a worker that touches
  one at top level throws, and Detour's recovery reloads it up to its
  limit and gives up. That is the seeding, not a product bug. It bit API
  Explorer and spared hello-world, which touches nothing at load.[^notes-seeding]
- **Seeding while the app runs.** The app owns `browser.db`; quit first.
- **Pointing `basePath` at the repository.** The load rewrites files
  there.
- **Expecting the Private profile to load it.** Off unless allowed.[^task-74]
- **Expecting origin storage to survive a relaunch.** On `main` a context
  gets a new base URL on each load, so IndexedDB and `localStorage` from
  the last launch are not found.[^task-99] See
  [storage](../extensions/storage.md).
- **Reading someone else's lines.** Filter the log by your pid; other
  Detour processes use the same subsystem.
- **API Explorer's start-up noise.** Its worker probes
  `wss://example.invalid` on every start; the relay failure lines are
  deliberate.

# Related

- [Runtime verification](./runtime-verification.md) — isolated data directories and launching.
- [Reading runtime logs](./reading-runtime-logs.md) — the categories you will read.
- [Testing extensions](../extensions/testing-extensions.md) — the test extensions and the XCTest fixtures.
- [Permissions](../extensions/permissions.md) — what the permission rows mean.
- [Extension manager](../extensions/extension-manager.md) — the load path the seed goes through.
- [Native messaging](../extensions/native-messaging.md) — manifest lookup and origin checks.

[^notes-seeding]: Session notes on seeding extensions for runtime checks
[^notes-logs]: Session notes on reading the unified log during harness runs
[^task-74]: TASK-74
[^task-99]: TASK-99
