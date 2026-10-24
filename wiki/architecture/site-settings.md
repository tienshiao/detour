---
type: Component
title: Site settings
description: "Per-site preferences per profile: the siteSetting table, SiteSettingsStore's cache and change notification, each setting's key and matching rule (host and parents, or dev mode's exact host:port), Private handling, and how content blocking's site list moved into it."
tags: [storage, profiles, content-blocker, site-settings, dev-mode]
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
  - id: task-186-5
    resource: backlog:TASK-186.5
    title: "Dev mode: turn dev mode on or off per site from the address bar popover"
  - id: dev-mode-tests
    resource: ../../DetourTests/DevModeSiteOverrideTests.swift
    title: DevModeSiteOverrideTests.swift
---

# Site settings

Per-site preferences live in one table of the
[session database](./session-database.md), `siteSetting`, so each new
per-site switch adds a `SiteSetting` case rather than a table.[^task-187]
Content blocking was the first, automatic picture in picture the
second,[^task-188] dev mode the third.[^task-186-5] Adding the dev-mode case
needed no migration: the table stores `setting` as text.

## Table

`siteSetting(profileID, site, setting, value)`, primary key
`(profileID, site, setting)`, `profileID` cascading from `profile`.

- `site` is the setting's key, stored lowercased: a host, or for dev mode a
  host plus a non-default port (`localhost:3000`).
- `setting` is `SiteSetting.rawValue`.
- `value` is a boolean **override**. A missing row means the setting's
  default, and the default belongs to the setting's consumer, not the store.

Profile deletion removes the rows explicitly in `deleteProfileRows`, like the
other per-profile tables ([profile data removal](./profile-data-removal.md)).
Whether the Private profile's values reach the table depends on the setting
(`SiteSetting.persistsInPrivate`). Content blocking's are written like any
other profile's (its profile row is saved under its fixed id, as before the
move); TASK-195 is to stop that. Picture in picture's and dev mode's are kept
in the cache only, so a site visited in Private is not left on disk, and
`discardPrivateSession()` drops them when the last Private space is removed
(`TabStore.removeIncognitoSpace`, through the shared store's `siteSettings`).
The user chose this on 2026-10-24, matching the external-app permissions,
which keep Private decisions in memory too.[^task-188][^pip-tests]

## SiteSettingsStore

`SiteSettingsStore.shared` (over `AppDatabase.shared`) reads the whole table
once when it is created and keeps a per-profile cache; `set` and `clear` write
through. A row whose `setting` this build does not know (written by a newer
build) is skipped on load and left in the table.

- `override(_:forSite:profileID:)` is the value that applies to a page whose
  site (in the setting's key form) is given: among the stored sites that
  cover it by the setting's rule, the most specific (longest) wins. Nil means
  "use the default". (The label was `forHost:` until dev mode's key, which is
  not a host, arrived.)
- `overrides(_:profileID:)` lists the stored sites for one setting.
- `resetToDefault(_:forSite:profileID:)` clears every stored site that
  covers the key, since a parent site's row left behind would still apply;
  a switch turned back on uses it.
- Every `set`, and a `clear` that removed a row, posts
  `SiteSettingsStore.didChangeNotification` (object: the store) with the
  `SiteSetting` and the profile id in `userInfo`. The sidebar uses it to
  re-mark dev-mode rows at once ([dev mode](../features/dev-mode.md)).
  `discardPrivateSession()` posts nothing: no window of the Private profile
  is left to show the values.

Each setting owns its matching rule (`SiteSetting.site(_:covers:)`):

| Setting | `false` means | Matches |
|---|---|---|
| `contentBlocking` | blocking off for the site | the host or any parent host (`example.com` covers `www.example.com`) |
| `pictureInPicture` | no automatic PiP when leaving the site's playing tab | the same |
| `devMode` | dev mode off for the site (`true`: on) | the site key exactly: host plus a non-default port (`devModeSiteKey`); `example.com` does not cover `www.example.com`, `localhost:3000` not `localhost:3001` |

`devMode` is the only setting overridden in both directions: its default
(local development URL or not) varies by site, so `true` and `false` rows
both occur. Its key is the dev-mode host line's string, so two local apps
on different ports are two sites; only `http`/`https` pages have one.[^task-186-5][^dev-mode-tests]

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
[^task-186-5]: Dev mode: turn dev mode on or off per site from the address bar popover
[^dev-mode-tests]: DevModeSiteOverrideTests.swift
