# Overviews

* [Sidebar overview](overview.md) - A map of the sidebar — TabSidebarViewController, its pages, cells and pure helper files — and how actions flow through TabSidebarDelegate to the window controller and TabStore.

# Concepts

* [Keyboard focus in the window and sidebar](keyboard-focus.md) - Which view holds first responder in a browser window, when focus is handed back to the web page, and why only the sidebar page on screen may take the keyboard.
* [Sidebar drag and drop](drag-and-drop.md) - The sidebar's drag pipeline: ID-based payloads, the pure validate / destination / resolve functions, the drop transaction, drop landing and the favorite drop hint.
* [Sidebar row layout](row-layout.md) - How a sidebar table row maps to a pinned item or a tab-list item, why an item index is not a tab index, and the pure functions every conversion must go through.

# Components

* [Sidebar space paging](space-paging.md) - The sidebar's horizontal page strip — one page per space plus the Archived Tabs page before the first — and how swipes, space buttons and the active space move it.
* [Tab cell and folder cell](tab-cell.md) - The sidebar's row views — TabCellView, FolderCellView and friends: what each element shows, the progress bar and its stalled-load fade, split rows, hover, and the cell-reuse rules.

# Features

* [Sidebar visibility and auto-hide](visibility-and-auto-hide.md) - The sidebar's two modes (pinned and auto-hidden), the pure SidebarVisibilityState reducer that attributes every collapse to its source, edge-hover reveal, the level-triggered hover hide, and how open popovers hold a revealed sidebar.
