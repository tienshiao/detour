# Concepts

* [Pinned tabs and folders](pinned-tabs-and-folders.md) - The pinned section's model (PinnedEntry with an optional backing tab, PinnedFolder, per-level sort order), what live, asleep and dormant mean, how closing and home work, and why a dormant tile can refuse to open.
* [Sleeping and archiving](sleeping-and-archiving.md) - The rules that put a tab to sleep (idle, show budget, memory pressure), the rule that archives one, everything that keeps a tab awake, and how a wake that fails keeps the restored session instead of showing an error page.
* [Split tabs](split-tabs.md) - The data model of a split (two adjacent tabs sharing a splitGroupID), the contiguity invariants TabStore keeps in every mutation, and where a pinned split's group lives.
* [Tab insertion and close selection](tab-insertion-and-close-selection.md) - The two pure rules that decide where a new tab lands in a space's list and which tab is selected after one closes, plus what the window layers on top of them.
* [Tab lifecycle](tab-lifecycle.md) - How a tab comes into being, navigates, closes and comes back, which object is its navigation delegate at each point, and when each step reaches the database.
* [Tab opener](tab-opener.md) - The link from a tab to the tab it was opened from (BrowserTab.parentID): which paths set it, the one opener rule (Space.openerTab: a normal, live pinned or live favourite tab) every reader resolves it by (close selection, Back and the back swipe, window.close, reopen and the close undos, Move to Space), the deliberate exceptions, and when the link is cut, re-checked or left dangling.

# Components

* [Split tab hosting in the window](split-tabs-hosting.md) - How BrowserWindowController shows a split (a frame-based NSSplitView of two pane containers), what the focused pane is, how hosting converges after store changes, and the gestures and animations that form and break a split.

# Features

* [Back swipe to the opener](back-swipe-to-opener.md) - On a tab opened from another tab, with no back history, the two-finger back swipe does what the Back button does — closes the tab and selects its opener — through Detour's own swipe (WebKit's needs a back item): when a pane's web view is in that mode, how a swipe starts from the scrolls the page did not use, the veneer that shows during it (the opener's picture going back, a picture of the page left going back on the forward swipe), the decisions per case (splits, Peek, pinned tabs, Quick Detour), and what is verified only by hand. *(draft)*
* [Closed tabs and the Archived Tabs page](closed-tabs-and-archive.md) - What a closed-tab record holds, how Reopen Closed Tab, the close undos and the Archived Tabs page each consume it, how archived records differ from plain closes, and closed Quick Detours filed under their profile's scope (TASK-193.5).
* [Favourites](favorites.md) - Per-profile tiles above the tab list, each with an optional backing tab that lives on the profile rather than in any space; how they are selected, moved, parked, peeked and kept visible to extensions.
* [Peek](peek.md) - The overlay that shows a linked page over the current tab; which links open in one, how it is anchored to its host tab, parked, restored and expanded, and how extensions see it.
* [Tab switching by keyboard](tab-switching.md) - Cmd+Option+Up/Down steps through a space's sidebar rows in order; Control+Tab switches between recently used tabs with a preview overlay. Both treat a split as one item.
