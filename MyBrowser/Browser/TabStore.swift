import Foundation
import AppKit
import Combine
import WebKit
import GRDB

protocol TabStoreObserver: AnyObject {
    func tabStoreDidInsertTab(_ tab: BrowserTab, at index: Int, in space: Space)
    func tabStoreDidRemoveTab(_ tab: BrowserTab, at index: Int, in space: Space)
    func tabStoreDidReorderTabs(in space: Space)
    func tabStoreDidUpdateTab(_ tab: BrowserTab, at index: Int, in space: Space)
    func tabStoreDidUpdateSpaces()
}

extension TabStoreObserver {
    func tabStoreDidInsertTab(_ tab: BrowserTab, at index: Int, in space: Space) {}
    func tabStoreDidRemoveTab(_ tab: BrowserTab, at index: Int, in space: Space) {}
    func tabStoreDidReorderTabs(in space: Space) {}
    func tabStoreDidUpdateTab(_ tab: BrowserTab, at index: Int, in space: Space) {}
    func tabStoreDidUpdateSpaces() {}
}

// MARK: - Space

class Space {
    let id: UUID
    var name: String
    var emoji: String
    var colorHex: String
    var tabs: [BrowserTab] = []
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
    private var observers: [WeakObserver] = []
    private var tabSubscriptions: [UUID: Set<AnyCancellable>] = [:]
    private var saveWorkItem: DispatchWorkItem?

    /// Used only for persistence — the space that was last active when saving.
    /// Each window tracks its own active space independently.
    var lastActiveSpaceID: UUID?

    /// In-memory dedup cache for history: "url|spaceID" -> timestamp
    private var recentHistoryWrites: [String: TimeInterval] = [:]

    private var db: DatabaseQueue { AppDatabase.shared.dbQueue }

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

        do {
            try db.write { db in
                // Clear existing session data
                try SpaceRecord.deleteAll(db)
                // Tabs cascade-deleted via foreign key

                // Insert spaces and tabs (skip incognito)
                for (spaceIndex, space) in persistentSpaces.enumerated() {
                    let spaceRecord = SpaceRecord(
                        id: space.id.uuidString,
                        name: space.name,
                        emoji: space.emoji,
                        colorHex: space.colorHex,
                        sortOrder: spaceIndex,
                        selectedTabID: space.selectedTabID?.uuidString
                    )
                    try spaceRecord.insert(db)

                    for (tabIndex, tab) in space.tabs.enumerated() {
                        var stateData: Data?
                        if let state = tab.webView.interactionState {
                            stateData = try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false)
                        }
                        let tabRecord = TabRecord(
                            id: tab.id.uuidString,
                            spaceID: space.id.uuidString,
                            url: tab.url?.absoluteString,
                            title: tab.title,
                            faviconURL: tab.faviconURL?.absoluteString,
                            interactionState: stateData,
                            sortOrder: tabIndex
                        )
                        try tabRecord.insert(db)
                    }
                }

                // Upsert lastActiveSpaceID
                if let activeID = lastActiveSpaceID {
                    try db.execute(
                        sql: "INSERT INTO appState (key, value) VALUES ('lastActiveSpaceID', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                        arguments: [activeID.uuidString]
                    )
                }
            }
        } catch {
            print("Failed to save session: \(error)")
        }
    }

    /// Restores session. Returns (activeSpaceID, selectedTabID) for the window to use.
    func restoreSession() -> (spaceID: UUID, tabID: UUID?)? {
        do {
            return try db.read { db in
                let spaceRecords = try SpaceRecord.order(Column("sortOrder")).fetchAll(db)
                guard !spaceRecords.isEmpty else { return nil }

                for spaceRecord in spaceRecords {
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

                    let tabRecords = try TabRecord
                        .filter(Column("spaceID") == spaceRecord.id)
                        .order(Column("sortOrder"))
                        .fetchAll(db)

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
                    self.spaces.append(space)
                }

                let activeIDString = try String.fetchOne(db, sql: "SELECT value FROM appState WHERE key = 'lastActiveSpaceID'")
                let activeID = activeIDString.flatMap { UUID(uuidString: $0) } ?? self.spaces.first!.id
                self.lastActiveSpaceID = activeID
                self.notifyObservers { $0.tabStoreDidUpdateSpaces() }

                let activeSpace = self.space(withID: activeID)
                return (activeID, activeSpace?.selectedTabID)
            }
        } catch {
            print("Failed to restore session: \(error)")
            return nil
        }
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

        let record = HistoryRecord(
            url: urlString,
            title: tab.title,
            faviconURL: tab.faviconURL?.absoluteString,
            spaceID: spaceID.uuidString,
            visitedAt: now
        )
        do {
            try db.write { db in
                try record.insert(db)
            }
        } catch {
            print("Failed to record history: \(error)")
        }
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

    func closeTab(id: UUID, in space: Space) {
        guard let index = space.tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = space.tabs[index]
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

    // MARK: - Per-Tab Subscriptions

    private func subscribeToTab(_ tab: BrowserTab, spaceID: UUID) {
        var cancellables = Set<AnyCancellable>()

        let notify: (BrowserTab) -> Void = { [weak self] tab in
            guard let self else { return }
            for space in self.spaces {
                if let index = space.tabs.firstIndex(where: { $0.id == tab.id }) {
                    self.notifyObservers { $0.tabStoreDidUpdateTab(tab, at: index, in: space) }
                    break
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

        tabSubscriptions[tab.id] = cancellables
    }
}

private struct WeakObserver {
    weak var value: (any TabStoreObserver)?
}
