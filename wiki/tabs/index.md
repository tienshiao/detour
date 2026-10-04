# Concepts

* [Pinned tabs and folders](pinned-tabs-and-folders.md) - The pinned section's model (PinnedEntry with an optional backing tab, PinnedFolder, per-level sort order), what live, asleep and dormant mean, how closing and home work, and why a dormant tile can refuse to open.
* [Sleeping and archiving](sleeping-and-archiving.md) - The two rules that put a tab to sleep, the rule that archives one, everything that keeps a tab awake, and how a wake that fails keeps the restored session instead of showing an error page.
* [Split tabs](split-tabs.md) - The data model of a split (two adjacent tabs sharing a splitGroupID), the contiguity invariants TabStore keeps in every mutation, and where a pinned split's group lives.
* [Tab insertion and close selection](tab-insertion-and-close-selection.md) - The two pure rules that decide where a new tab lands in a space's list and which tab is selected after one closes, plus what the window layers on top of them.
* [Tab lifecycle](tab-lifecycle.md) - How a tab comes into being, navigates, closes and comes back, which object is its navigation delegate at each point, and when each step reaches the database.

# Components

* [Split tab hosting in the window](split-tabs-hosting.md) - How BrowserWindowController shows a split (a frame-based NSSplitView of two pane containers), what the focused pane is, how hosting converges after store changes, and the gestures and animations that form and break a split.

# Features

* [Closed tabs and the Archived Tabs page](closed-tabs-and-archive.md) - What a closed-tab record holds, how Reopen Closed Tab, the close undos and the Archived Tabs page each consume it, and how archived records differ from plain closes.
* [Favourites](favorites.md) - Per-profile tiles above the tab list, each with an optional backing tab that lives on the profile rather than in any space; how they are selected, moved, parked, peeked and kept visible to extensions.
* [Peek](peek.md) - The overlay that shows a linked page over the current tab; which links open in one, how it is anchored to its host tab, parked, restored and expanded, and how extensions see it.
* [Tab switching by keyboard](tab-switching.md) - Cmd+Option+Up/Down steps through a space's sidebar rows in order; Control+Tab switches between recently used tabs with a preview overlay. Both treat a split as one item.
