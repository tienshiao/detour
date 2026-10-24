---
type: Component
title: Site settings
description: "Per-site preferences per profile: the siteSetting table, SiteSettingsStore's cache, each setting's matching rule, and how content blocking's site list moved into it."
tags: [storage, profiles, content-blocker, site-settings]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-24T11:00:00Z }
sources:
  - id: store
    resource: ../../Detour/Browser/SiteSettings/SiteSettingsStore.swift
    title: SiteSettingsStore.swift (SiteSetting, SiteSettingsStore)
  - id: record
    resource: ../../Detour/Storage/Models/SiteSettingRecord.swift
    title: SiteSettingRecord.swift
  - id: database
    resource: ../../Detour/Storage/Database.swift
    title: Database.swift (migration v18, saveSiteSetting, deleteSiteSettings, loadSiteSettings)
  - id: whitelist
    resource: ../../Detour/Browser/ContentBlocker/ContentBlockerWhitelist.swift
    title: ContentBlockerWhitelist.swift
  - id: tests
    resource: ../../DetourTests/SiteSettingsStoreTests.swift
    title: SiteSettingsStoreTests.swift
  - id: task-187
    resource: backlog:TASK-187
    title: Storage - a per-site settings table, with content blocking's site list migrated into it
  - id: task-188
    resource: backlog:TASK-188
    title: Picture in picture - a per-site switch for opening PiP automatically when you leave a playing tab
  - id: pip-tests
    resource: ../../DetourTests/AutomaticPictureInPictureTests.swift
    title: AutomaticPictureInPictureTests.swift
---

# Site settings

Per-site preferences live in one table of the
[session database](./session-database.md), `siteSetting`, so each new
per-site switch adds a `SiteSetting` case rather than a table.[^task-187]
Content blocking was the first, automatic picture in picture the
second;[^task-188] dev mode (TASK-186.5) is planned to follow.

## Table

`siteSetting(profileID, site, setting, value)`, primary key
`(profileID, site, setting)`, `profileID` cascading from `profile`.

- `site` is a host, stored lowercased.
- `setting` is `SiteSetting.rawValue`.
- `value` is a boolean **override**. A missing row means the setting's
  default, and the default belongs to the setting's consumer, not the store.

Profile deletion removes the rows explicitly in `deleteProfileRows`, like the
other per-profile tables ([profile data removal](./profile-data-removal.md)).
Whether the Private profile's values reach the table depends on the setting
(`SiteSetting.persistsInPrivate`). Content blocking's are written like any
other profile's (its profile row is saved under its fixed id, as before the
move); TASK-195 is to stop that. Picture in picture's are kept in the cache
only, so a site visited in Private is not left on disk, and
`discardPrivateSession()` drops them when the last Private space is removed
(`TabStore.removeIncognitoSpace`, through the shared store's `siteSettings`).
The user chose this on 2026-10-24, matching the external-app permissions,
which keep Private decisions in memory too.[^task-188][^pip-tests]

## SiteSettingsStore

`SiteSettingsStore.shared` (over `AppDatabase.shared`) reads the whole table
once when it is created and keeps a per-profile cache; `set` and `clear` write
through. A row whose `setting` this build does not know (written by a newer
build) is skipped on load and left in the table.

- `override(_:forHost:profileID:)` is the value that applies to a page:
  among the stored sites that cover the host by the setting's rule, the most
  specific (longest) wins. Nil means "use the default".
- `overrides(_:profileID:)` lists the stored sites for one setting.
- `resetToDefault(_:forHost:profileID:)` clears every stored site that
  covers the host, since a parent site's row left behind would still apply;
  a switch turned back on uses it.

Each setting owns its matching rule (`SiteSetting.site(_:covers:)`):

| Setting | `false` means | Matches |
|---|---|---|
| `contentBlocking` | blocking off for the site | the host or any parent host (`example.com` covers `www.example.com`) |
| `pictureInPicture` | no automatic PiP when leaving the site's playing tab | the same |

## Content blocking's site list

`ContentBlockerWhitelist` kept its API (`isWhitelisted`, `toggleHost`,
`hostsForProfile`, the pure `covers` / `entriesCovering`) and now reads and
writes the store: a whitelisted host is a `contentBlocking = false` row. How
the switch is enforced is unchanged ([content blocking](../features/content-blocking.md)).

Migration v18 copied every `contentBlockerWhitelist` row into `siteSetting`
as `contentBlocking = false` and dropped the old table. The host is
lowercased, as the old loader did, so two spellings of one host became one
row. Rows whose profile no longer exists (left while foreign keys were off)
are dropped, so they cannot fail the migration's foreign key check. The
migration is tested against a database migrated to v17.

[^task-187]: Storage - a per-site settings table, with content blocking's site list migrated into it
[^task-188]: Picture in picture - a per-site switch for opening PiP automatically when you leave a playing tab
[^pip-tests]: AutomaticPictureInPictureTests.swift
