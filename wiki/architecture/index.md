# Overviews

* [Architecture overview](overview.md) - The whole app on one page — profiles, spaces, tabs and windows, the singletons that hold them, how the parts talk to each other, and the launch sequence.

# Concepts

* [Incognito (Private windows)](incognito.md) - How Private browsing is built — one built-in Private profile with a non-persistent store, one throwaway space per Private window, and the list of things that are and are not kept.
* [Persistence](persistence.md) - What Detour saves, where and when — the two databases, the debounced one-transaction session save, its write order and what it does when it cannot be written, session restore, interaction state, and the DETOUR_DATA_DIR switch.
* [Profile data removal and storage scoping](profile-data-removal.md) - What deleting a profile removes and in what order, why the on-disk WebKit data needs a pending row and retries, and how WebKitStorageScope and UserDefaultsScope keep test and verification runs out of the production app's data.
* [Profiles and spaces](profiles-and-spaces.md) - A profile owns website data, extensions and settings; a space is a tab group that points at one profile; the active space is per window.
* [Web view ownership](webview-ownership.md) - A tab's web view is hosted by at most one window; the others draw a dimmed snapshot, and hosting moves to whichever window becomes key.

# Components

* [App shell](app-shell.md) - AppDelegate and main.swift — launch and termination, window creation, the menu bar built in code, the key-equivalent fast path, Sparkle, and every launch-time environment switch.
* [BrowserTab](browser-tab.md) - The tab model — an optional WKWebView with published state, sleep and wake, its own navigation delegate while no window owns it, and the flags that keep a restored session intact.
* [BrowserWindowController](browser-window-controller.md) - The per-window controller — what each of its extension files handles, how it selects a tab and hosts content, and the per-window state it keeps apart from TabStore.
* [History database](history-database.md) - history.db — one shared row per URL, one row per visit scoped to a space, two FTS5 indexes, the per-space title index and its triggers, and the rules that keep one profile's titles out of another's results.
* [Site settings](site-settings.md) - Per-site preferences per profile: the siteSetting table, SiteSettingsStore's cache and change notification, each setting's key and matching rule (host and parents, or dev mode's exact host:port), Private values kept in memory only (migration v19), and how content blocking's site list moved into it.
* [TabStore](tabstore.md) - The state singleton that owns profiles, spaces and tabs — its observer protocol, mutation families, what triggers a save, and the invariants every mutation keeps.

# References

* [Session database](session-database.md) - The tables of browser.db, what each is for, the foreign keys that shape the save order, the migration history through v20, and the GRDB record types.
