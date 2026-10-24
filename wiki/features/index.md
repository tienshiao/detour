# Concepts

* [History recording and search](history-recording-and-search.md) - When a visit is recorded, how its title is stored and corrected, how in-page navigations become visits, and which query serves which consumer under which scope.

# Components

* [Favicons](favicons.md) - How a tab finds its icon (an optimistic /favicon.ico guess, an early link report from a private content world, an end-of-load lookup), and the two shared loaders that hand icons to AppKit and to web views.
* [Internal pages (detour://)](internal-pages.md) - How Detour serves its own privileged pages into ordinary tabs: single-use arming, a scheme handler that serves only internal main documents, and a bridge in a private content world that re-verifies every sender.
* [Settings window](settings.md) - The fixed-size Settings window and its five panes (General, Spaces, Profiles, Extensions, Content Blocking): what each one edits, how changes reach TabStore, and the layout traps of a non-resizable pane.
* [Suggestion pipeline](suggestion-pipeline.md) - How the command palette's rows are produced - open tabs, space-scoped history, inline URL completion by frecency, network search suggestions - and how typed input is classified as a URL or a search.

# Features

* [Command palette](command-palette.md) - The overlay used for URL entry, tab switching, history and web search: its two modes, how it is opened and dismissed, inline completion, keyboard handling, and how focus returns to the page.
* [Content blocking](content-blocking.md) - The built-in blocker: EasyList-family filter lists compiled to WKContentRuleLists, per-profile list toggles, the per-site switch implemented through a WebKit preferences SPI, and the blocked-resource counter.
* [Dev mode](dev-mode.md) - Which URLs count as local development (localhost, *.localhost, 127.0.0.0/8 in any IPv4 spelling, [::1], 0.0.0.0, *.test over http/https), the per-site override and its popover switch, the one function the effective state goes through, and how a dev-mode tab's sidebar row, split half and favourite tile are marked with a hazard border and a host line and follow a change at once.
* [Downloads](downloads.md) - How a navigation becomes a download, what DownloadManager tracks and persists, how a Private window's downloads are kept apart and cancelled when it closes, the sidebar popover and badge, the fly-to-button animation, and the CRX path that reuses the list.
* [Error pages](error-pages.md) - What a failed load looks like: the browser-error:// page, which failures earn one (only those before commit) and which are ignored, how the tab keeps the URL the user asked for, and how retry, restore and background tabs behave.
* [External application links](external-apps.md) - What happens when a page navigates to a non-web scheme such as zoommtg: or mailto: - the confirmation sheet, the pure launch policy, and the per-profile 'Always allow' store keyed by origin and scheme.
* [Find in page](find-in-page.md) - The Cmd+F find bar: a per-window FindBarView driving WKWebView.find on the selected tab, with a match counter computed separately in JavaScript.
* [History page](history-page.md) - The detour://history/ page: a profile-scoped list of visits in an ordinary tab, with search, a time-range filter, selection and delete, and a natively confirmed Clear History.
* [Tab hover card](tab-hover-card.md) - The card shown beside the sidebar when the pointer rests on a tab row or favourite tile: the full title, the URL with its host emphasised and a page thumbnail; when it shows, what it describes, where thumbnails come from (memory, then a per-row JPEG on disk) and what dismisses it.
