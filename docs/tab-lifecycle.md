# Tab & Space Lifecycle

## Space Lifecycle

### Creation

```swift
let space = TabStore.shared.addSpace(name: "Work", emoji: "...", colorHex: "FF9500", profileID: profileID)
```

1. Creates a `Space` object with a new UUID
2. Links it to the specified profile (sets `space.profile`)
3. Appends to `TabStore.spaces`
4. Notifies observers via `tabStoreDidUpdateSpaces()`
5. Schedules debounced save

**Default space**: If no spaces exist after session restore, `ensureDefaultSpace()` creates a "Home" space with the default profile.

**Incognito space**: Created via `addIncognitoSpace()`, linked to the built-in incognito profile. Uses a non-persistent `WKWebsiteDataStore`. Never persisted to the session database.

### Deletion

```swift
TabStore.shared.deleteSpace(id: spaceID)
```

1. Guards: must have > 1 space remaining
2. Removes from `TabStore.spaces`
3. Cleans up all tab Combine subscriptions
4. Deletes closed tab records for this space from DB
5. Notifies observers, schedules save

The profile is **not** deleted with the space (profiles are shared resources).

### Incognito Cleanup

When an incognito window closes, `removeIncognitoSpace(id:)` removes the space and its tab subscriptions. The built-in incognito profile persists across sessions.

---

## Tab Lifecycle

### Creation

Three ways to create a tab:

**1. Fresh tab** (Cmd+T or programmatic):
```swift
let tab = TabStore.shared.addTab(in: space, url: nil, parentID: nil)
```
- Creates `BrowserTab(configuration: space.makeWebViewConfiguration())`
- Live `WKWebView` is created immediately
- Inserted at a computed index (see [Tab Insertion](#tab-insertion))

**2. Adopt existing WebView** (e.g., window.open from JavaScript):
```swift
let tab = TabStore.shared.addTab(in: space, webView: existingWebView, parentID: parentTabID)
```
- Wraps an already-loaded `WKWebView`
- Seeds published properties from the WebView's current state

**3. Session restore** (sleeping):
```swift
BrowserTab(id: tabID, title: title, url: url, faviconURL: faviconURL,
           cachedInteractionState: stateData, spaceID: spaceID)
```
- No WebView created (`webView = nil`, `isSleeping = true`)
- Stores serialized interaction state for later `wake()`
- Used for all non-selected tabs during session restore

### Tab Insertion

New tabs are inserted at a computed position via `tabInsertionIndex()` in `TabInsertion.swift`:

- If the tab has a `parentID`, it's inserted after the parent and any existing children of that parent
- Otherwise, it's appended to the end of the tab list

This creates a natural grouping where child tabs (opened from links) cluster next to their parent.

### Navigation

```swift
tab.load(url)
```

1. If sleeping, calls `wake()` first
2. Sets `navigationPending = true`
3. Resets `blockedCount` to 0
4. Optimistically fetches favicon from `{scheme}://{host}/favicon.ico`
5. Calls `webView.load(URLRequest(url:))`

On navigation commit (`didCommitNavigation`), `navigationPending` clears and the title updates. On load completion, `TabStore` records a history visit.

On provisional navigation failure, an error page is loaded via the `browser-error://` custom scheme.

### Sleeping

Tabs are put to sleep to conserve memory. This preserves their state without keeping a `WKWebView` alive.

**Triggers**: `TabStore.sleepStaleTabs`, run by the archive timer every 5 minutes, sleeps a tab under either of two rules:
- **Idle rule**: a normal (unpinned) tab whose `lastDeselectedAt` is older than the profile's `sleepThreshold`.
- **Show-budget rule (TASK-104)**: any hidden tab, including pinned entries' and favourites' backing tabs, that has been shown at least `sleepShowBudget` times since it last woke (50 by default) and has been out of sight for `sleepShowBudgetGrace` (15 minutes by default). `BrowserTab.showsSinceWake` counts every time a window actually attaches the tab's web view and every time a hosting window comes back from being fully covered; waking resets it. The rule exists because WebKit's GPU process keeps IOSurfaces from every hidden-to-visible transition until the tab's WebContent process goes away. After a long session it hits the per-process limit of 16,384 surfaces, and WebGL and canvas stop working in every tab. The idle rule never reaches the tabs shown most often, so they need this second route.

**Never slept**:
- a tab playing audio
- a tab that is selected somewhere (`lastDeselectedAt == nil`) or whose container is still in a window. Two windows on one space share a single timestamp.
- one member of a split while its partner doesn't qualify too
- any tab in a profile whose `sleepThreshold` is `.never`, under either rule

A sleeping pinned entry or favourite keeps its tab, which is live but asleep, so selecting it wakes the tab from its saved state instead of reloading the page from scratch. For testing, `DETOUR_SLEEP_SHOW_BUDGET` and `DETOUR_SLEEP_SHOW_BUDGET_GRACE_SECONDS` override the two constants when the app launches.

**Process**:
1. Serialize `webView.interactionState` via `NSKeyedArchiver`
2. Remove all KVO observers and Combine subscriptions
3. Remove WebView from superview, set `self.webView = nil`
4. Set `isSleeping = true`

**Waking**:
1. Create fresh WebView from `space.makeWebViewConfiguration()`
2. Restore `interactionState` (restores scroll position, back/forward stack) or fall back to reloading the URL
3. Re-setup observers
4. Set `isSleeping = false`

### Keyboard Switching

- **Cmd+Option+Up/Down** steps through the space's sidebar rows (`Sidebar/TabNavigation.swift`): pinned rows, then normal items, a split being one stop, wrapping at both ends. It selects through the same paths as a row click, so a dormant pinned entry is activated. Dormant tiles that cannot open are skipped.
- **Control+Tab** switches between recently used tabs (`Window/RecentTabSwitcher.swift`). It lists the current tab and every tab left since launch in the active space, newest first. That order comes from `BrowserTab.switcherPreviewAt`, an in-memory clock set in `stampDeselected`. The persisted `lastDeselectedAt` stays the sleep clock only. The card picture (`switcherPreview`) is taken with `WKWebView.takeSnapshot` as the tab is left, never by hosting a hidden tab, and it survives sleep.

### Archiving (Auto-Close)

Tabs that have been inactive longer than the profile's `archiveThreshold` are automatically closed and moved to the closed tab stack.

**Triggers**:
- Same 5-minute archive timer as sleep
- Only applies to non-incognito spaces
- Never archives the last remaining tab in a space

**Process**: Calls `closeTab(id:in:archivedAt:)` with the current timestamp. The `archivedAt` field distinguishes auto-archived tabs from manually closed ones.

### Closing

```swift
TabStore.shared.closeTab(id: tabID, in: space)
```

1. Find and remove the tab from `space.tabs`
2. If not incognito, archive to the closed tab stack:
   - Serialize current interaction state
   - Create `ClosedTabRecord` with all metadata
   - Push to DB (capped at 100 records, FIFO eviction; the table is the only store — TASK-117)
3. Remove Combine subscriptions for this tab
4. Notify observers via `tabStoreDidRemoveTab`
5. Schedule save

### Reopening

```swift
TabStore.shared.reopenClosedTab(in: space)
```

1. Find the most recent closed tab record for this space
2. Remove from stack (both in-memory and DB)
3. Create a new `BrowserTab` with a **fresh UUID** but the archived state
4. Insert at the original `sortOrder` position (clamped to current tab count)
5. Subscribe to the new tab's properties
6. Notify observers, schedule save

The tab gets a new UUID because the old tab object is gone. The user experience is seamless because the interaction state restores the full page.

---

## Pinned Tab Lifecycle

### Pinning

```swift
TabStore.shared.pinTab(id: tabID, in: space, at: destinationIndex)
```

1. Remove tab from `space.tabs`
2. Set `isPinned = true`, capture `pinnedURL` and `pinnedTitle` from current state
3. Compute sort order (max of existing pinned tabs and folders + 1)
4. Insert into `space.pinnedTabs`
5. Notify via `tabStoreDidPinTab` (atomic: includes both source and destination indices)

### Closing a Pinned Tab

```swift
TabStore.shared.closePinnedTab(id: tabID, in: space)
```

**Two behaviors**:
- If the tab is at its pinned home URL: fully remove it (like closing a regular tab)
- If the tab has navigated away: reset it to `pinnedURL` via `resetToPinnedHome()`

### Unpinning

```swift
TabStore.shared.unpinTab(id: tabID, in: space)
```

Reverse of pinning: moves from `pinnedTabs` back to `tabs`, clears all pinned properties.

---

## Persistence Timing

| Event | Action |
|-------|--------|
| Tab/space mutation | `scheduleSave()` (1s debounce) |
| App termination | `saveNow()` (immediate) |
| Profile update | `saveProfile()` + `scheduleSave()` |
| 5-minute timer tick | Sleep stale tabs, archive stale tabs (both trigger saves) |

The debounced save prevents excessive disk writes during rapid operations like drag-reordering multiple tabs or bulk closing.
