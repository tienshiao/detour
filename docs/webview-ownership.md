# WebView Ownership & Multi-Window

The most critical architectural invariant in Detour: **only one window at a time "owns" a tab's WKWebView**. Non-owning windows display a static snapshot image.

## Why

WebKit's `WKWebView` can only have one superview. When multiple windows need to display the same tab (because spaces are global but windows are independent), the non-owning windows need an alternative. Detour uses `NSImageView` snapshots as that alternative.

## Ownership State

Each `BrowserWindowController` tracks:

```swift
private var ownsWebView: Bool {              // Does this window host the selected tab's WebView?
    guard let container = selectedTab?.webViewContainer else { return false }
    return container.isDescendant(of: contentContainerView)
}
private var snapshotImageView: NSImageView?  // Fallback display when not owning
private var localSnapshot: NSImage?          // Snapshot handed over by the window that took the WebView
```

Ownership is not stored. `ownsWebView` is computed from the view hierarchy: a container can only be parented in one window at a time, so the flag cannot drift out of sync with what is on screen.

A `BrowserTab` has:

```swift
private(set) var webView: WKWebView?                        // nil when sleeping
private(set) var webViewContainer: WebViewContainerView?    // wraps webView; retains docked inspector views across detach/reattach
```

The `webViewContainer` is the actual view added to a window's `contentContainerView` (for a split, both panes' containers sit inside an `NSSplitView` hosted there). The raw `webView` is a subview of the container. WebKit places docked UI (e.g., Web Inspector) as siblings of the webView — i.e., inside the container — so moving the container preserves that UI.

## Transfer Mechanism

When a window becomes the key window (gains focus):

1. `windowDidBecomeKey` calls `claimWebView(for:)` for the window's selected tab
2. If the tab's `webViewContainer` is already in this window, the claim only refreshes its frame and stops -- nothing is posted
3. Otherwise the claiming window captures a synchronous bitmap of what the previous owner is displaying (webView + docked inspector pixels, or the whole split view), removes the container from its old superview, and attaches it to its own `contentContainerView`
4. It then posts `Notification.Name.webViewOwnershipChanged`, with the claimed tab IDs and the snapshot in `userInfo`
5. Other windows whose selected tab was claimed, and which were displaying it live, keep the snapshot as `localSnapshot` and switch to displaying `snapshotImageView`

So the notification is posted by the new owner, after the container has moved; it is not what triggers the transfer. By the time it arrives, `ownsWebView` is already false in the window that lost the tab.

`selectTab()` goes through the same claim when its window is key, or when no window is hosting the tab. In a background window whose tab is hosted elsewhere it shows a snapshot instead. Actions that need the live page (navigate, reload, back, forward) call `ensureOwnsWebView()` first.

## Snapshot System

```
container.bitmapImageRepForCachingDisplay(in: container.bounds)
  -> container.cacheDisplay(in:to:)
     -> NSImage
```

Snapshots are taken:
- When a window claims a container that another window is hosting (by the claiming window, before the container is moved; handed to the previous owner in the notification)
- When a background window selects a tab that another window is hosting and has no handed-over snapshot (the web view is rendered where it is currently parented)
- For the split formation and separation animations

Switching tabs within a window takes no snapshot of this kind. The Control+Tab switcher's card picture is separate: it uses `WKWebView.takeSnapshot` (asynchronous) on a pane that is on screen, as the tab is left.

The snapshot is shown in an `NSImageView` at half opacity. If there is nothing to render, the image is nil and the pane is empty.

## Sleeping Tabs

Sleeping is separate from ownership. A sleeping tab has `webView == nil`:

```
sleep()
  1. Serialize webView.interactionState -> cachedInteractionState (Data)
  2. Remove KVO observers, cancel Combine subscriptions
  3. Remove webView and webViewContainer from their superviews
  4. self.webView = nil, self.webViewContainer = nil
  5. isSleeping = true

wake()
  1. Create fresh WKWebView via space.makeWebViewConfiguration()
  2. Restore interactionState OR reload URL
  3. Re-setup KVO observers and Combine subscriptions
  4. isSleeping = false
```

When a window selects a sleeping tab, `wake()` is called before the WebView is attached. This means the window that selects the tab becomes its owner automatically, even when it is not key (no other window can be hosting a WebView that was just created).

## Interaction State

WebKit's `interactionState` property captures the full browsing state (scroll position, back/forward history, form data). Detour serializes it via `NSKeyedArchiver` for:

- **Session persistence** -- saved to `tab.interactionState` BLOB in the database
- **Sleep/wake** -- cached in memory as `cachedInteractionState: Data?`
- **Closed tab restoration** -- stored in `closedTab.interactionState`

The `currentInteractionStateData()` method returns the live state from the WebView if available, or falls back to the cached data if the tab is sleeping.

## Rules of Thumb

1. **Never assume `tab.webView` is non-nil, or that it is in this window** -- it's nil for sleeping tabs; in a non-owning window it is a live view parented in another window, so check `ownsWebView` (or `webView.window === window`)
2. **Never add a tab's WebView to multiple superviews** -- always check/transfer ownership first
3. **A key window that calls `selectTab()` gets ownership** -- this is the standard flow; a background window gets it only when no window is hosting the tab
4. **Snapshot before moving** -- the claiming window captures the snapshot before it takes the container out of the previous owner's window
5. **Wake before display** -- selecting a sleeping tab triggers `wake()`, which creates a fresh WebView
