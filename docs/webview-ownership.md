# WebView Ownership & Multi-Window

The most critical architectural invariant in Detour: **only one window at a time "owns" a tab's WKWebView**. Non-owning windows display a static snapshot image.

## Why

WebKit's `WKWebView` can only have one superview. When multiple windows need to display the same tab (because spaces are global but windows are independent), the non-owning windows need an alternative. Detour uses `NSImageView` snapshots as that alternative.

## Ownership State

Each `BrowserWindowController` tracks:

```swift
private var ownsWebView = false          // Does this window own the displayed tab's WebView?
private var snapshotImageView: NSImageView?  // Fallback display when not owning
private var localSnapshot: NSImage?      // Cached snapshot image
```

A `BrowserTab` has:

```swift
private(set) var webView: WKWebView?         // nil when sleeping
private(set) var webViewContainer: NSView?   // wraps webView; retains docked inspector views across detach/reattach
```

The `webViewContainer` is the actual view added to a window's `contentContainerView`. The raw `webView` is a subview of the container. WebKit places docked UI (e.g., Web Inspector) as siblings of the webView — i.e., inside the container — so moving the container preserves that UI.

## Transfer Mechanism

When a window becomes the key window (gains focus):

1. `NSWindow.didBecomeKeyNotification` fires
2. The window posts `Notification.Name.webViewOwnershipChanged`
3. **All windows** receive this notification and re-evaluate ownership
4. The newly focused window takes ownership: attaches the tab's `webViewContainer` to its `contentContainerView`
5. Other windows showing the same tab switch to displaying `snapshotImageView`

Before releasing the container, the departing owner captures a synchronous bitmap of the container (webView + docked inspector pixels) and caches it locally for display.

## Snapshot System

```
container.bitmapImageRepForCachingDisplay(in: container.bounds)
  -> container.cacheDisplay(in:to:)
     -> NSImage
```

Snapshots are taken:
- When a window loses ownership (before the container is moved)
- When switching tabs within a window (snapshot of the departing tab's container)
- On demand for peek overlays

If a tab's WebView is nil (sleeping) or unavailable, the snapshot is nil and the window shows an empty state.

## Sleeping Tabs

Sleeping is separate from ownership. A sleeping tab has `webView == nil`:

```
sleep()
  1. Serialize webView.interactionState -> cachedInteractionState (Data)
  2. Remove KVO observers, cancel Combine subscriptions
  3. webView.removeFromSuperview()
  4. self.webView = nil
  5. isSleeping = true

wake()
  1. Create fresh WKWebView via space.makeWebViewConfiguration()
  2. Restore interactionState OR reload URL
  3. Re-setup KVO observers and Combine subscriptions
  4. isSleeping = false
```

When a window selects a sleeping tab, `wake()` is called before the WebView is attached. This means the window that selects the tab becomes its owner automatically (it's the one that created the new WebView).

## Automation-Attached Tabs (Parked)

An extension that is driving a tab — a `chrome.debugger` attachment, a command in flight — needs the tab's web view even when the tab is not selected: for snapshots, and for synthesized input that produces trusted events. That is the **attached** state (TASK-132.3, `Window/AutomationParking.swift`).

```swift
tab.attachAutomation(TabAutomationOwner(extensionID: id, reason: "debugger"))   // first owner: wake + park
tab.detachAutomation(owner)                                                     // last owner gone: unpark
tab.automationHosting          // .notAttached / .displayed / .parked / .unhosted
tab.automationDrivableWebView()   // awake, in a window, at content-area size — or nil
```

A tab is attached while its owner set (`BrowserTab.automationOwners`) is non-empty. While attached:

- **It is awake.** Attaching wakes a sleeping tab; `sleep()` refuses and `TabStore.sleepStaleTabs` / `archiveStaleTabs` skip it (and, by the split rules, its partner). A *forced* sleep (profile swap, move across profiles) still releases the web view; the tab is woken and parked again on the next main-queue turn.
- **Its web view is always in a window.** If a window displays the tab (selected tab, split pane, presented peek), nothing changes. Otherwise its `webViewContainer` is **parked**: a subview of a window's `automationParkingView`, which fills `contentContainerView` at the bottom of its z-order. The container is `isHidden`, laid out to the content area's bounds, and resizes with it.
- **Nothing is elevated.** A hidden view in a window is hidden to WebKit: the page reports `visibilityState: hidden`, timers are throttled and `requestAnimationFrame` is stalled exactly as for a hidden tab in no window, and the WebContent process holds no foreground assertion (measured: RunningBoard assertion type 1, background, where the selected tab holds type 3; an unparked hidden tab drops to type 0 about 3 s after loading). Evaluating JavaScript or sending input raises it for the few milliseconds the call is in flight, as it does for any web view. Only tabs with a live attachment are kept in a window at all; every other hidden tab, including other tabs of the same extension's tab group, is untouched.

One thing does differ from a hidden tab in no window (measured in the running app): while the window holding it is key, a parked page reports `document.hasFocus() == true`, although its `visibilityState` stays `hidden` and its web view is never first responder. With the window not key it reports false.

Why a window at all: measured on the shipped WebKit (`.claude/scratch/task132.3-covered-webview-spike.m`), `takeSnapshot` returns a freshly painted image for a web view anywhere, but a web view in *no* window gets `mousedown` without `mouseup`/`click`. A web view that is in a window but hidden takes mouse, key and `insertText` input sent straight to the view, and the page sees trusted events.

### Sending input

Build events with `webView.window`'s window number and send them to the view, never through `NSApp.sendEvent` or the window (which route by hit testing and first responder):

- **Mouse and text:** `webView.mouseDown(with:)` / `mouseUp(with:)` / …, and `NSTextInputClient.insertText(_:replacementRange:)`.
- **Keys:** `AutomationInput.sendKey(_:to:)`, not `webView.keyDown(with:)`. A key down the page declines is handed back by WebKit through `NSApp.sendEvent` (`WebViewImpl::doneWithKeyEvent`), and AppKit routes it to the app's key window and its first responder: a letter sent to a parked page with nothing focused is typed into the field the user is in, and a declined Cmd-key fires the main-menu item (measured: `.claude/scratch/task132.3/declined-key-spike.m`). `AutomationInput` remembers the key downs it sends and a local event monitor drops them when WebKit re-sends them. This applies to a displayed attached tab too.
- WebKit queues mouse events and key events separately: a key sent right after a click can reach the page before the click has moved focus. Wait for the click to land.
- Not covered: a synthesized right-click makes WebKit pop up a real context menu.

### Transitions

`AutomationParking.reconcile(preferring:)` is the one place that decides, and it is idempotent: every attached tab that is asleep is woken, and every attached tab no window displays is parked. It runs on attach and after anything that can take a container out of a content area — `selectTab`, `deselectAllTabs`, a claim, an ownership hand-off, the end of a PiP capture hold, a window closing, a new window appearing.

| Event | Result |
|-------|--------|
| Attach, tab displayed | Stays displayed |
| Attach, tab hidden or asleep | Woken if needed, parked |
| Window selects the tab | Container moves from the parking host to the pane through the normal claim path, un-hidden; counts as a show (`noteShown`) |
| Window deselects the tab (tab switch, space switch, deselect all) | Parked in that window instead of leaving it |
| Another window claims it | Leaves the first window (its pane or its parking host); parks in the new window when *that* one stops showing it |
| Window showing only a snapshot of it becomes key | Claims it out of parking (`ownsWebView` is false for a parked container) |
| Hosting window closes | Parked in another window; with no browser window left the tab is `.unhosted` — attachment recorded, parked when a window appears |
| Tab closes (`teardown()`) | Owners dropped, container gone |
| Last owner detaches | Unparked: container out of the window, an ordinary hidden tab |

**Which window parks a tab** (`automationParkingWindowIndex`): the window that just stopped displaying it; a tab already parked stays where it is. For a tab hosted nowhere (attach, or its window closed): the first window, in `NSApp.windows` order, showing the tab's space; else the first on the tab's profile; else the first browser window. The choice has no visible effect — the container is hidden and any window that selects the tab claims it — so the rule only needs to be stable.

### Isolation from the window

A parked page must not disturb the page the user is in:

- **First responder.** WebKit calls `window.makeFirstResponder(webView)` on every mouse press a web view receives, hidden or not. `BrowserWindow.makeFirstResponder` refuses any view inside a parking host, so the selected tab keeps keyboard focus. The parked page takes input regardless.
- **Declined keys.** See `AutomationInput` above.
- **Responder chain.** `AutomationParkingView` swallows every event and command passed up from a parked page (a key the page declined would otherwise reach `BrowserWindowController.keyDown`), blocks key equivalents from reaching parked web views, answers no hit test, and supplies its own undo manager so text typed into a parked page does not land on `TabStore`'s undo stack.
- **Delegates.** Parking wires nothing. A tab that was never displayed keeps itself as navigation delegate and has no UI delegate, like any background tab.

### The reserve switch

`AutomationParking.revealsParkedWebViews` (default `false`, not exposed in the UI) leaves parked containers un-hidden. WebKit then counts those pages — and only those — as visible: full-rate timers and rendering, and a foreground assertion while the window is on screen. The parking host stays fully transparent and click-through, so nothing shows. It exists in case hidden attached tabs turn out to load too slowly on a busy machine; nothing turns it on.

## Interaction State

WebKit's `interactionState` property captures the full browsing state (scroll position, back/forward history, form data). Detour serializes it via `NSKeyedArchiver` for:

- **Session persistence** -- saved to `tab.interactionState` BLOB in the database
- **Sleep/wake** -- cached in memory as `cachedInteractionState: Data?`
- **Closed tab restoration** -- stored in `closedTab.interactionState`

The `currentInteractionStateData()` method returns the live state from the WebView if available, or falls back to the cached data if the tab is sleeping.

## Rules of Thumb

1. **Never assume `tab.webView` is non-nil** -- it's nil for sleeping tabs and for tabs in non-owning windows
2. **Never add a tab's WebView to multiple superviews** -- always check/transfer ownership first
3. **The window that calls `selectTab()` after becoming key gets ownership** -- this is the standard flow
4. **Snapshot before releasing** -- always capture a snapshot before moving or removing a WebView from a window
5. **Wake before display** -- selecting a sleeping tab triggers `wake()`, which creates a fresh WebView
6. **"In a window" is not "displayed"** -- an automation-attached tab's container can be parked hidden in a window. Ask `tab.isHostedForDisplay` (or the window's `ownsWebView`), not `webViewContainer?.superview != nil`
7. **Never raise a hidden tab's priority** -- parked tabs stay hidden; anything that would make a hidden page count as visible must be scoped to one attached tab and go through `AutomationParking.revealsParkedWebViews`
