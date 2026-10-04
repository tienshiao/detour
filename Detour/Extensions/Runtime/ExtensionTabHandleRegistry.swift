import Foundation
import WebKit

// The bridge from a WebKit tab id to the `BrowserTab` behind it (TASK-132.2).
//
// WebKit owns `chrome.tabs` and mints its tab ids, and exposes no lookup from an
// id back to the `WKWebExtensionTab` object. A polyfilled API that takes a
// `tabId` (tabs.group, chrome.tabGroups, chrome.debugger) therefore cannot ask
// WebKit which tab is meant. It asks the tab instead: `tabs.getZoom(tabId)` is
// answered by `BrowserTab.zoomFactor(for:)` on exactly the tab WebKit resolved
// the id to, needs neither the `tabs` permission nor host access, fails for an
// unknown id, and its return value reaches the caller unclamped. While a
// resolve is *armed* for the calling extension context the tab answers with
// `-handle` instead of its zoom; the handle is what the polyfill then sends to
// the native handlers, which map it back here. See docs/extensions.md.

// MARK: - Handles

/// Process-unique positive integer handles for objects, held weakly: a handle
/// is minted the first time an object is asked for one, stays that object's for
/// as long as it lives, and is never handed to another object afterwards.
struct WeakHandleTable<Object: AnyObject> {

    private struct Entry {
        weak var object: Object?
        let identity: ObjectIdentifier
    }

    private var entries: [Int: Entry] = [:]
    private var handles: [ObjectIdentifier: Int] = [:]
    private var nextHandle = 1
    /// Dead entries are swept when the table has grown to this size; doubled
    /// past the survivors each time, so a sweep is amortised over the mints.
    private var sweepThreshold = 64

    /// The handle of `object`, minted on first use.
    mutating func handle(for object: Object) -> Int {
        let identity = ObjectIdentifier(object)
        if let handle = handles[identity] {
            // An `ObjectIdentifier` is an address, and an address is reused once
            // its object is gone: only an entry still pointing at this very
            // object is this object's handle.
            if entries[handle]?.object === object { return handle }
            entries.removeValue(forKey: handle)
        }
        if entries.count >= sweepThreshold { sweep() }
        let handle = nextHandle
        nextHandle += 1
        entries[handle] = Entry(object: object, identity: identity)
        handles[identity] = handle
        return handle
    }

    /// The live object `handle` was minted for, or nil: never minted, or its
    /// object is gone.
    mutating func object(forHandle handle: Int) -> Object? {
        guard let entry = entries[handle] else { return nil }
        if let object = entry.object { return object }
        forget(handle, identity: entry.identity)
        return nil
    }

    /// How many handles are still on record, dead ones not yet swept included.
    var recordedCount: Int { entries.count }

    private mutating func forget(_ handle: Int, identity: ObjectIdentifier) {
        entries.removeValue(forKey: handle)
        // The address may already belong to a newer object with its own handle.
        if handles[identity] == handle { handles.removeValue(forKey: identity) }
    }

    private mutating func sweep() {
        for (handle, entry) in entries where entry.object == nil {
            forget(handle, identity: entry.identity)
        }
        sweepThreshold = max(64, entries.count * 2)
    }
}

// MARK: - Arms

/// A per-key counter of pending resolves. Each arm expires on its own, so a
/// resolve that never reaches `getZoom` (a worker torn down between the two
/// calls, a bridge error) cannot leave the context answering handles for ever.
///
/// A counter rather than a flag: two JS contexts of one extension (its worker
/// and a page) share a key and may resolve at the same moment. Arms are
/// interchangeable — whichever `getZoom` consumes one is still answered by the
/// tab *it* asked about — so the count is all that has to be right.
struct ExtensionTabResolveArms<Key: Hashable> {

    /// How long an arm stays consumable, in seconds.
    let lifetime: TimeInterval
    /// The most arms one key may hold; more are refused. A resolver holds one
    /// at a time per JS context, so the cap only ever stops a context that
    /// arms in a loop from growing this table.
    let limit: Int

    /// Expiry times per key, oldest first.
    private var deadlines: [Key: [TimeInterval]] = [:]

    init(lifetime: TimeInterval, limit: Int) {
        self.lifetime = lifetime
        self.limit = limit
    }

    /// Nothing is armed for any key (expired arms not yet dropped count as
    /// armed). The fast path of every `getZoom` that is not part of a resolve.
    var isEmpty: Bool { deadlines.isEmpty }

    /// Adds one arm. False when the key already holds `limit` live arms.
    mutating func arm(_ key: Key, now: TimeInterval) -> Bool {
        // Expired arms of *other* keys are only ever dropped here: a context
        // that armed and then went away never asks about its own again, and
        // its leftovers would keep `isEmpty` false for good.
        for (other, expiries) in deadlines where other != key {
            let live = expiries.filter { $0 > now }
            deadlines[other] = live.isEmpty ? nil : live
        }
        var live = liveDeadlines(key, now: now)
        guard live.count < limit else {
            deadlines[key] = live
            return false
        }
        live.append(now + lifetime)
        deadlines[key] = live
        return true
    }

    /// Takes one live arm — the one closest to expiring. False when there is none.
    mutating func consume(_ key: Key, now: TimeInterval) -> Bool {
        var live = liveDeadlines(key, now: now)
        defer { deadlines[key] = live.isEmpty ? nil : live }
        guard !live.isEmpty else { return false }
        live.removeFirst()
        return true
    }

    /// Takes back one live arm — the most recent, which is the caller's own
    /// when it disarms straight after a failed resolve. False when there is none.
    mutating func disarm(_ key: Key, now: TimeInterval) -> Bool {
        var live = liveDeadlines(key, now: now)
        defer { deadlines[key] = live.isEmpty ? nil : live }
        guard !live.isEmpty else { return false }
        live.removeLast()
        return true
    }

    /// Live arms for `key`.
    func count(_ key: Key, now: TimeInterval) -> Int {
        liveDeadlines(key, now: now).count
    }

    private func liveDeadlines(_ key: Key, now: TimeInterval) -> [TimeInterval] {
        (deadlines[key] ?? []).filter { $0 > now }
    }
}

// MARK: - Placement

/// Where a tab sits among the containers a window's tab enumeration reads
/// (`extensionWindowTabs`, the placement rule in `ExtensionTabLifecycle`).
struct ExtensionTabPlacement: Equatable {
    enum Kind: String {
        /// In a space's tab list.
        case normal
        /// The live backing tab of a space's pinned entry.
        case pinned
        /// The live backing tab of a profile's favourite.
        case favorite
        /// The live Peek of a tab in one of the three sections above.
        case peek
    }

    let kind: Kind
    /// The profile whose windows list the tab: its space's, the favourite's
    /// owner, or — for a Peek — its host's.
    let profileID: UUID
    /// The space holding the tab (for a Peek, its host). Nil for a favourite's
    /// backing tab, which belongs to a profile rather than to any one space.
    let spaceID: UUID?
}

/// The placement of `tab` in `store`, or nil when no window could list it: it
/// was closed, detached and never re-homed, or is a Peek that was parked (a
/// parked Peek has no web view and is left out of the enumeration too).
func extensionTabPlacement(of tab: BrowserTab, in store: TabStore) -> ExtensionTabPlacement? {
    func section(of candidate: BrowserTab) -> ExtensionTabPlacement? {
        for space in store.spaces {
            if space.pinnedEntries.contains(where: { $0.tab === candidate }) {
                return ExtensionTabPlacement(kind: .pinned, profileID: space.profileID, spaceID: space.id)
            }
            if space.tabs.contains(where: { $0 === candidate }) {
                return ExtensionTabPlacement(kind: .normal, profileID: space.profileID, spaceID: space.id)
            }
        }
        for profile in store.profiles where profile.favorites.contains(where: { $0.tab === candidate }) {
            return ExtensionTabPlacement(kind: .favorite, profileID: profile.id, spaceID: nil)
        }
        return nil
    }

    if let placement = section(of: tab) { return placement }
    guard tab.webView != nil,
          let host = store.tab(hostingPeek: tab),
          let hostPlacement = section(of: host) else { return nil }
    return ExtensionTabPlacement(kind: .peek, profileID: hostPlacement.profileID, spaceID: hostPlacement.spaceID)
}

// MARK: - Registry

/// Why a handle was refused. The distinction is for Detour's own callers and
/// the log; an extension is told the same thing in every case (see
/// `ExtensionPolyfillHandler`), so probing handles says nothing about tabs in
/// another profile.
enum ExtensionTabHandleError: Error, Equatable {
    /// Not a positive integer.
    case invalidHandle
    /// Never minted, or the tab it was minted for no longer exists.
    case unknownHandle
    /// The tab exists but no window could list it any more.
    case notPlaced
    /// The tab is listed by another profile's windows.
    case otherProfile
}

/// The process-wide table behind the tab-id bridge: tab handles, and the
/// per-context resolve arms `BrowserTab.zoomFactor(for:)` consumes.
///
/// Main thread only, like everything it serves: WebKit calls the tab delegate
/// on the main thread and the polyfill handler dispatches there.
final class ExtensionTabHandleRegistry {

    static let shared = ExtensionTabHandleRegistry()

    /// How the polyfill handler names an extension context: the profile it
    /// serves and the verified id of the sending extension.
    struct ContextKey: Hashable {
        let profileID: UUID
        let extensionID: String
    }

    /// A handle that passed every check.
    struct ResolvedTab {
        let tab: BrowserTab
        let placement: ExtensionTabPlacement
    }

    /// A resolve is one `tabs.armResolve` reply followed at once by one
    /// `tabs.getZoom`, so an arm is normally consumed within milliseconds.
    /// Long enough for a busy machine, short enough that a stray arm is gone
    /// before anyone notices.
    static let defaultArmLifetime: TimeInterval = 5
    static let defaultArmLimit = 32

    private var handles = WeakHandleTable<BrowserTab>()
    private var arms: ExtensionTabResolveArms<ContextKey>
    private let clock: () -> TimeInterval

    /// `clock` is monotonic seconds; tests inject their own to expire arms.
    init(armLifetime: TimeInterval = ExtensionTabHandleRegistry.defaultArmLifetime,
         armLimit: Int = ExtensionTabHandleRegistry.defaultArmLimit,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.arms = ExtensionTabResolveArms(lifetime: armLifetime, limit: armLimit)
        self.clock = clock
    }

    // MARK: Handles

    /// `tab`'s handle, minted on first use and stable for the tab's lifetime.
    func handle(for tab: BrowserTab) -> Int {
        handles.handle(for: tab)
    }

    /// The tab behind `handle`, for a request from `profile`. Refuses a handle
    /// whose tab is gone, is no longer anywhere a window could list it, or is
    /// listed by another profile — a handle is only an integer, and an
    /// extension may send any integer.
    func tab(forHandle handle: Int, in profile: Profile,
             store: TabStore = .shared) -> Result<ResolvedTab, ExtensionTabHandleError> {
        guard handle > 0 else { return .failure(.invalidHandle) }
        guard let tab = handles.object(forHandle: handle) else { return .failure(.unknownHandle) }
        guard let placement = extensionTabPlacement(of: tab, in: store) else { return .failure(.notPlaced) }
        guard placement.profileID == profile.id else { return .failure(.otherProfile) }
        return .success(ResolvedTab(tab: tab, placement: placement))
    }

    // MARK: Arms

    /// One more pending resolve for `key`. False when the key is at its cap.
    @discardableResult
    func arm(_ key: ContextKey) -> Bool {
        arms.arm(key, now: clock())
    }

    /// Takes back one pending resolve, if one is still there.
    @discardableResult
    func disarm(_ key: ContextKey) -> Bool {
        arms.disarm(key, now: clock())
    }

    /// Pending resolves for `key`.
    func armCount(_ key: ContextKey) -> Int {
        arms.count(key, now: clock())
    }

    /// If a resolve is pending for `key`, consumes it and returns `tab`'s
    /// handle; nil otherwise.
    func consumeArm(_ key: ContextKey, answeringFor tab: BrowserTab) -> Int? {
        guard arms.consume(key, now: clock()) else { return nil }
        return handle(for: tab)
    }

    /// `consumeArm` for the context WebKit is asking on behalf of — the entry
    /// point of `BrowserTab.zoomFactor(for:)`. Costs one dictionary check when
    /// nothing is armed anywhere, which is every ordinary `tabs.getZoom`.
    func consumeArm(for context: WKWebExtensionContext, answeringFor tab: BrowserTab) -> Int? {
        guard !arms.isEmpty, let key = Self.contextKey(for: context) else { return nil }
        return consumeArm(key, answeringFor: tab)
    }

    /// The key the polyfill handler arms under for messages from `context`:
    /// the profile owning its controller, and the id it is loaded under there.
    /// Nil for a context no live profile lists (unloaded, or mid-reload).
    static func contextKey(for context: WKWebExtensionContext) -> ContextKey? {
        guard let controller = context.webExtensionController,
              let profile = Profile.profile(owning: controller),
              let extensionID = profile.extensionID(for: context) else { return nil }
        return ContextKey(profileID: profile.id, extensionID: extensionID)
    }
}
