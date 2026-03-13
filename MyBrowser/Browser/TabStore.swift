import Foundation
import AppKit
import Combine
import WebKit

protocol TabStoreObserver: AnyObject {
    func tabStoreDidInsertTab(_ tab: BrowserTab, at index: Int, in space: Space)
    func tabStoreDidRemoveTab(_ tab: BrowserTab, at index: Int, in space: Space)
    func tabStoreDidReorderTabs(in space: Space)
    func tabStoreDidUpdateTab(_ tab: BrowserTab, at index: Int, in space: Space)
    func tabStoreDidUpdateSpaces()

    // Pinned tab observer methods
    func tabStoreDidInsertPinnedTab(_ tab: BrowserTab, at index: Int, in space: Space)
    func tabStoreDidRemovePinnedTab(_ tab: BrowserTab, at index: Int, in space: Space)
    func tabStoreDidReorderPinnedTabs(in space: Space)
    func tabStoreDidUpdatePinnedTab(_ tab: BrowserTab, at index: Int, in space: Space)
    func tabStoreDidResetPinnedTab(_ tab: BrowserTab, at index: Int, in space: Space)
}

extension TabStoreObserver {
    func tabStoreDidInsertTab(_ tab: BrowserTab, at index: Int, in space: Space) {}
    func tabStoreDidRemoveTab(_ tab: BrowserTab, at index: Int, in space: Space) {}
    func tabStoreDidReorderTabs(in space: Space) {}
    func tabStoreDidUpdateTab(_ tab: BrowserTab, at index: Int, in space: Space) {}
    func tabStoreDidUpdateSpaces() {}
    func tabStoreDidInsertPinnedTab(_ tab: BrowserTab, at index: Int, in space: Space) {}
    func tabStoreDidRemovePinnedTab(_ tab: BrowserTab, at index: Int, in space: Space) {}
    func tabStoreDidReorderPinnedTabs(in space: Space) {}
    func tabStoreDidUpdatePinnedTab(_ tab: BrowserTab, at index: Int, in space: Space) {}
    func tabStoreDidResetPinnedTab(_ tab: BrowserTab, at index: Int, in space: Space) {}
}

// MARK: - Space

class Space {
    let id: UUID
    var name: String
    var emoji: String
    var colorHex: String
    var tabs: [BrowserTab] = []
    var pinnedTabs: [BrowserTab] = []
    var selectedTabID: UUID?
    let isIncognito: Bool

    var color: NSColor {
        NSColor(hex: colorHex) ?? .controlAccentColor
    }

    /// Dedicated data store for this space — isolates cookies, localStorage, cache.
    /// Incognito spaces use a non-persistent store (in-memory only).
    lazy var dataStore: WKWebsiteDataStore = {
        if isIncognito {
            return .nonPersistent()
        }
        return WKWebsiteDataStore(forIdentifier: id)
    }()

    init(id: UUID = UUID(), name: String, emoji: String, colorHex: String, isIncognito: Bool = false) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.colorHex = colorHex
        self.isIncognito = isIncognito
    }

    /// Returns a fresh WKWebViewConfiguration wired to this space's isolated storage.
    func makeWebViewConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        return config
    }

    static let presetColors: [String] = [
        "007AFF", // Blue
        "FF3B30", // Red
        "34C759", // Green
        "FF9500", // Orange
        "AF52DE", // Purple
        "FF2D55", // Pink
    ]
}

// MARK: - TabStore

class TabStore {
    static let shared = TabStore()

    private(set) var spaces: [Space] = []
    private(set) var closedTabStack: [ClosedTabRecord] = []
    private var observers: [WeakObserver] = []
    private var tabSubscriptions: [UUID: Set<AnyCancellable>] = [:]
    private var saveWorkItem: DispatchWorkItem?

    /// Used only for persistence — the space that was last active when saving.
    /// Each window tracks its own active space independently.
    var lastActiveSpaceID: UUID?

    /// In-memory dedup cache for history: "url|spaceID" -> timestamp
    private var recentHistoryWrites: [String: TimeInterval] = [:]

    private init() {}

    func space(withID id: UUID) -> Space? {
        spaces.first { $0.id == id }
    }

    // MARK: - Session Persistence

    func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.saveNow()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    func saveNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil

        let persistentSpaces = spaces.filter { !$0.isIncognito }

        var sessionData: [(SpaceRecord, [TabRecord])] = []
        for (spaceIndex, space) in persistentSpaces.enumerated() {
            let spaceRecord = SpaceRecord(
                id: space.id.uuidString,
                name: space.name,
                emoji: space.emoji,
                colorHex: space.colorHex,
                sortOrder: spaceIndex,
                selectedTabID: space.selectedTabID?.uuidString
            )

            var tabRecords: [TabRecord] = []
            for (tabIndex, tab) in space.tabs.enumerated() {
                var stateData: Data?
                if let state = tab.webView.interactionState {
                    stateData = try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false)
                }
                tabRecords.append(TabRecord(
                    id: tab.id.uuidString,
                    spaceID: space.id.uuidString,
                    url: tab.url?.absoluteString,
                    title: tab.title,
                    faviconURL: tab.faviconURL?.absoluteString,
                    interactionState: stateData,
                    sortOrder: tabIndex
                ))
            }
            sessionData.append((spaceRecord, tabRecords))
        }

        AppDatabase.shared.saveSession(
            spaces: sessionData,
            lastActiveSpaceID: lastActiveSpaceID?.uuidString
        )

        // Save pinned tabs separately
        for space in persistentSpaces {
            var pinnedRecords: [PinnedTabRecord] = []
            for (i, tab) in space.pinnedTabs.enumerated() {
                var stateData: Data?
                if let state = tab.webView.interactionState {
                    stateData = try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false)
                }
                pinnedRecords.append(PinnedTabRecord(
                    id: tab.id.uuidString,
                    spaceID: space.id.uuidString,
                    pinnedURL: tab.pinnedURL?.absoluteString ?? "",
                    pinnedTitle: tab.pinnedTitle ?? tab.title,
                    url: tab.url?.absoluteString,
                    title: tab.title,
                    faviconURL: tab.faviconURL?.absoluteString,
                    interactionState: stateData,
                    sortOrder: i
                ))
            }
            AppDatabase.shared.savePinnedTabs(pinnedRecords, spaceID: space.id.uuidString)
        }
    }

    /// Restores session. Returns (activeSpaceID, selectedTabID) for the window to use.
    func restoreSession() -> (spaceID: UUID, tabID: UUID?)? {
        guard let session = AppDatabase.shared.loadSession() else { return nil }

        for (spaceRecord, tabRecords) in session.spaces {
            guard let spaceID = UUID(uuidString: spaceRecord.id) else { continue }
            let space = Space(
                id: spaceID,
                name: spaceRecord.name,
                emoji: spaceRecord.emoji,
                colorHex: spaceRecord.colorHex
            )
            if let selID = spaceRecord.selectedTabID {
                space.selectedTabID = UUID(uuidString: selID)
            }

            for tabRecord in tabRecords {
                guard let tabID = UUID(uuidString: tabRecord.id) else { continue }
                let tab = BrowserTab(
                    id: tabID,
                    title: tabRecord.title,
                    archivedInteractionState: tabRecord.interactionState,
                    fallbackURL: tabRecord.url.flatMap { URL(string: $0) },
                    faviconURL: tabRecord.faviconURL.flatMap { URL(string: $0) },
                    configuration: space.makeWebViewConfiguration()
                )
                space.tabs.append(tab)
                self.subscribeToTab(tab, spaceID: spaceID)
            }

            // Load pinned tabs
            let pinnedRecords = AppDatabase.shared.loadPinnedTabs(spaceID: spaceRecord.id)
            for pinnedRecord in pinnedRecords {
                guard let tabID = UUID(uuidString: pinnedRecord.id) else { continue }
                let tab = BrowserTab(
                    id: tabID,
                    title: pinnedRecord.title ?? pinnedRecord.pinnedTitle,
                    archivedInteractionState: pinnedRecord.interactionState,
                    fallbackURL: pinnedRecord.url.flatMap { URL(string: $0) } ?? URL(string: pinnedRecord.pinnedURL),
                    faviconURL: pinnedRecord.faviconURL.flatMap { URL(string: $0) },
                    configuration: space.makeWebViewConfiguration()
                )
                tab.isPinned = true
                tab.pinnedURL = URL(string: pinnedRecord.pinnedURL)
                tab.pinnedTitle = pinnedRecord.pinnedTitle
                space.pinnedTabs.append(tab)
                self.subscribeToTab(tab, spaceID: spaceID)
            }

            self.spaces.append(space)
        }

        // Load closed tab stack from DB
        self.closedTabStack = AppDatabase.shared.loadClosedTabs()

        let activeID = session.lastActiveSpaceID.flatMap { UUID(uuidString: $0) } ?? self.spaces.first!.id
        self.lastActiveSpaceID = activeID
        self.notifyObservers { $0.tabStoreDidUpdateSpaces() }

        let activeSpace = self.space(withID: activeID)
        return (activeID, activeSpace?.selectedTabID)
    }

    // MARK: - History Recording

    private func recordHistoryVisit(tab: BrowserTab, spaceID: UUID) {
        // Never record history for incognito spaces
        if let space = space(withID: spaceID), space.isIncognito { return }

        guard let url = tab.url else { return }
        let urlString = url.absoluteString

        // Skip internal URLs
        guard url.scheme == "http" || url.scheme == "https" else { return }

        // Deduplicate: skip if same (url, spaceID) recorded within 30 seconds
        let dedupKey = "\(urlString)|\(spaceID.uuidString)"
        let now = Date().timeIntervalSince1970
        if let lastWrite = recentHistoryWrites[dedupKey], now - lastWrite < 30 {
            return
        }
        recentHistoryWrites[dedupKey] = now

        HistoryDatabase.shared.recordVisit(
            url: urlString,
            title: tab.title,
            faviconURL: tab.faviconURL?.absoluteString,
            spaceID: spaceID.uuidString
        )
    }

    // MARK: - Observer Management

    func addObserver(_ observer: TabStoreObserver) {
        observers.removeAll { $0.value == nil }
        observers.append(WeakObserver(value: observer))
    }

    func removeObserver(_ observer: TabStoreObserver) {
        observers.removeAll { $0.value === observer || $0.value == nil }
    }

    private func notifyObservers(_ action: (TabStoreObserver) -> Void) {
        observers.removeAll { $0.value == nil }
        for wrapper in observers {
            if let observer = wrapper.value {
                action(observer)
            }
        }
    }

    // MARK: - Space Management

    @discardableResult
    func addSpace(name: String, emoji: String, colorHex: String) -> Space {
        let space = Space(name: name, emoji: emoji, colorHex: colorHex)
        spaces.append(space)
        notifyObservers { $0.tabStoreDidUpdateSpaces() }
        scheduleSave()
        return space
    }

    func deleteSpace(id: UUID) {
        guard spaces.count > 1,
              let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let space = spaces.remove(at: index)
        for tab in space.tabs {
            tabSubscriptions.removeValue(forKey: tab.id)
        }
        for tab in space.pinnedTabs {
            tabSubscriptions.removeValue(forKey: tab.id)
        }
        // Clean up closed tab records for this space
        let spaceIDString = id.uuidString
        AppDatabase.shared.deleteClosedTabs(spaceID: spaceIDString)
        closedTabStack.removeAll { $0.spaceID == spaceIDString }

        WKWebsiteDataStore.remove(forIdentifier: space.id) { _ in }
        notifyObservers { $0.tabStoreDidUpdateSpaces() }
        scheduleSave()
    }

    func updateSpace(id: UUID, name: String, emoji: String, colorHex: String) {
        guard let space = space(withID: id) else { return }
        space.name = name
        space.emoji = emoji
        space.colorHex = colorHex
        notifyObservers { $0.tabStoreDidUpdateSpaces() }
        scheduleSave()
    }

    func ensureDefaultSpace() {
        guard spaces.isEmpty else { return }
        let space = Space(name: "Home", emoji: "🏠", colorHex: "007AFF")
        spaces.append(space)
        lastActiveSpaceID = space.id
        notifyObservers { $0.tabStoreDidUpdateSpaces() }
    }

    @discardableResult
    func addIncognitoSpace() -> Space {
        let space = Space(name: "Private", emoji: "🔒", colorHex: "2C2C2E", isIncognito: true)
        spaces.append(space)
        notifyObservers { $0.tabStoreDidUpdateSpaces() }
        return space
    }

    func removeIncognitoSpace(id: UUID) {
        guard let index = spaces.firstIndex(where: { $0.id == id && $0.isIncognito }) else { return }
        let space = spaces.remove(at: index)
        for tab in space.tabs {
            tabSubscriptions.removeValue(forKey: tab.id)
        }
        notifyObservers { $0.tabStoreDidUpdateSpaces() }
    }

    // MARK: - Tab Mutations

    @discardableResult
    func addTab(in space: Space, url: URL? = nil, afterTabID: UUID? = nil) -> BrowserTab {
        let tab = BrowserTab(configuration: space.makeWebViewConfiguration())

        let insertionIndex: Int
        if let afterTabID, let afterIndex = space.tabs.firstIndex(where: { $0.id == afterTabID }) {
            insertionIndex = afterIndex + 1
            space.tabs.insert(tab, at: insertionIndex)
        } else {
            space.tabs.append(tab)
            insertionIndex = space.tabs.count - 1
        }

        subscribeToTab(tab, spaceID: space.id)
        notifyObservers { $0.tabStoreDidInsertTab(tab, at: insertionIndex, in: space) }

        if let url {
            tab.load(url)
        }

        scheduleSave()
        return tab
    }

    @discardableResult
    func addTab(in space: Space, webView: WKWebView, afterTabID: UUID? = nil) -> BrowserTab {
        let tab = BrowserTab(webView: webView)

        let insertionIndex: Int
        if let afterTabID, let afterIndex = space.tabs.firstIndex(where: { $0.id == afterTabID }) {
            insertionIndex = afterIndex + 1
            space.tabs.insert(tab, at: insertionIndex)
        } else {
            space.tabs.append(tab)
            insertionIndex = space.tabs.count - 1
        }

        subscribeToTab(tab, spaceID: space.id)
        notifyObservers { $0.tabStoreDidInsertTab(tab, at: insertionIndex, in: space) }
        scheduleSave()
        return tab
    }

    func closeTab(id: UUID, in space: Space) {
        guard let index = space.tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = space.tabs[index]

        // Archive to closed tab stack (skip incognito)
        if !space.isIncognito {
            var stateData: Data?
            if let state = tab.webView.interactionState {
                stateData = try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false)
            }
            let record = ClosedTabRecord(
                id: nil,
                tabID: tab.id.uuidString,
                spaceID: space.id.uuidString,
                url: tab.url?.absoluteString,
                title: tab.title,
                faviconURL: tab.faviconURL?.absoluteString,
                interactionState: stateData,
                sortOrder: index
            )
            AppDatabase.shared.pushClosedTab(record)
            closedTabStack.insert(record, at: 0)
            // Trim in-memory stack to match cap
            if closedTabStack.count > 100 {
                closedTabStack = Array(closedTabStack.prefix(100))
            }
        }

        tabSubscriptions.removeValue(forKey: tab.id)
        space.tabs.remove(at: index)
        notifyObservers { $0.tabStoreDidRemoveTab(tab, at: index, in: space) }
        scheduleSave()
    }

    func moveTab(from sourceIndex: Int, to destinationIndex: Int, in space: Space) {
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < space.tabs.count,
              destinationIndex >= 0, destinationIndex < space.tabs.count else { return }
        let tab = space.tabs.remove(at: sourceIndex)
        space.tabs.insert(tab, at: destinationIndex)
        notifyObservers { $0.tabStoreDidReorderTabs(in: space) }
        scheduleSave()
    }

    // MARK: - Pinned Tab Mutations

    func pinTab(id: UUID, in space: Space, at destinationIndex: Int? = nil) {
        guard let index = space.tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = space.tabs.remove(at: index)
        tab.isPinned = true
        tab.pinnedURL = tab.url
        tab.pinnedTitle = tab.title
        let insertAt = min(destinationIndex ?? space.pinnedTabs.count, space.pinnedTabs.count)
        space.pinnedTabs.insert(tab, at: insertAt)
        notifyObservers { $0.tabStoreDidRemoveTab(tab, at: index, in: space) }
        notifyObservers { $0.tabStoreDidInsertPinnedTab(tab, at: insertAt, in: space) }
        scheduleSave()
    }

    func unpinTab(id: UUID, in space: Space, at destinationIndex: Int? = nil) {
        guard let index = space.pinnedTabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = space.pinnedTabs.remove(at: index)
        tab.isPinned = false
        tab.pinnedURL = nil
        tab.pinnedTitle = nil
        let insertAt = min(destinationIndex ?? 0, space.tabs.count)
        space.tabs.insert(tab, at: insertAt)
        notifyObservers { $0.tabStoreDidRemovePinnedTab(tab, at: index, in: space) }
        notifyObservers { $0.tabStoreDidInsertTab(tab, at: insertAt, in: space) }
        scheduleSave()
    }

    func closePinnedTab(id: UUID, in space: Space) {
        guard let index = space.pinnedTabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = space.pinnedTabs[index]
        if tab.isAtPinnedHome {
            // Fully remove
            tabSubscriptions.removeValue(forKey: tab.id)
            space.pinnedTabs.remove(at: index)
            notifyObservers { $0.tabStoreDidRemovePinnedTab(tab, at: index, in: space) }
        } else {
            // Reset to pinned home
            tab.resetToPinnedHome()
            notifyObservers { $0.tabStoreDidResetPinnedTab(tab, at: index, in: space) }
        }
        scheduleSave()
    }

    func movePinnedTab(from sourceIndex: Int, to destinationIndex: Int, in space: Space) {
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < space.pinnedTabs.count,
              destinationIndex >= 0, destinationIndex < space.pinnedTabs.count else { return }
        let tab = space.pinnedTabs.remove(at: sourceIndex)
        space.pinnedTabs.insert(tab, at: destinationIndex)
        notifyObservers { $0.tabStoreDidReorderPinnedTabs(in: space) }
        scheduleSave()
    }

    // MARK: - Reopen Closed Tab

    func canReopenClosedTab(in space: Space) -> Bool {
        let spaceIDString = space.id.uuidString
        return closedTabStack.contains { $0.spaceID == spaceIDString }
    }

    @discardableResult
    func reopenClosedTab(in space: Space) -> BrowserTab? {
        let spaceIDString = space.id.uuidString
        guard let stackIndex = closedTabStack.firstIndex(where: { $0.spaceID == spaceIDString }) else {
            return nil
        }
        let record = closedTabStack.remove(at: stackIndex)
        _ = AppDatabase.shared.popClosedTab(spaceID: spaceIDString)

        let tab = BrowserTab(
            id: UUID(),
            title: record.title,
            archivedInteractionState: record.interactionState,
            fallbackURL: record.url.flatMap { URL(string: $0) },
            faviconURL: record.faviconURL.flatMap { URL(string: $0) },
            configuration: space.makeWebViewConfiguration()
        )

        let insertionIndex = min(record.sortOrder, space.tabs.count)
        space.tabs.insert(tab, at: insertionIndex)
        subscribeToTab(tab, spaceID: space.id)
        notifyObservers { $0.tabStoreDidInsertTab(tab, at: insertionIndex, in: space) }
        scheduleSave()
        return tab
    }

    // MARK: - Per-Tab Subscriptions

    private func subscribeToTab(_ tab: BrowserTab, spaceID: UUID) {
        var cancellables = Set<AnyCancellable>()

        let notify: (BrowserTab) -> Void = { [weak self] tab in
            guard let self else { return }
            for space in self.spaces {
                if let index = space.pinnedTabs.firstIndex(where: { $0.id == tab.id }) {
                    self.notifyObservers { $0.tabStoreDidUpdatePinnedTab(tab, at: index, in: space) }
                    return
                }
                if let index = space.tabs.firstIndex(where: { $0.id == tab.id }) {
                    self.notifyObservers { $0.tabStoreDidUpdateTab(tab, at: index, in: space) }
                    return
                }
            }
        }

        tab.$title
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak tab] _ in
                guard let tab else { return }
                notify(tab)
            }
            .store(in: &cancellables)

        tab.$url
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] _ in
                guard let self, let tab else { return }
                notify(tab)
                self.scheduleSave()
            }
            .store(in: &cancellables)

        tab.$favicon
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] _ in
                guard let self, let tab else { return }
                notify(tab)
                self.scheduleSave()
            }
            .store(in: &cancellables)

        tab.$isLoading
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] isLoading in
                guard let self, let tab else { return }
                notify(tab)
                // Record history when page finishes loading
                if !isLoading {
                    self.recordHistoryVisit(tab: tab, spaceID: spaceID)
                }
            }
            .store(in: &cancellables)

        tab.$estimatedProgress
            .dropFirst()
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak tab] _ in
                guard let tab else { return }
                notify(tab)
            }
            .store(in: &cancellables)

        tab.$isPlayingAudio
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak tab] _ in
                guard let tab else { return }
                notify(tab)
            }
            .store(in: &cancellables)

        tab.$isMuted
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak tab] _ in
                guard let tab else { return }
                notify(tab)
            }
            .store(in: &cancellables)

        tabSubscriptions[tab.id] = cancellables
    }
}

private struct WeakObserver {
    weak var value: (any TabStoreObserver)?
}
