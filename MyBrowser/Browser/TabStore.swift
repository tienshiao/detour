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

    var color: NSColor {
        NSColor(hex: colorHex) ?? .controlAccentColor
    }

    /// Dedicated data store for this space — isolates cookies, localStorage, cache.
    lazy var dataStore: WKWebsiteDataStore = WKWebsiteDataStore(forIdentifier: id)

    init(id: UUID = UUID(), name: String, emoji: String, colorHex: String) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.colorHex = colorHex
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

private extension NSColor {
    convenience init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard hex.count == 6 else { return nil }
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = CGFloat((int >> 16) & 0xFF) / 255.0
        let g = CGFloat((int >> 8) & 0xFF) / 255.0
        let b = CGFloat(int & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
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

    private init() {}

    func space(withID id: UUID) -> Space? {
        spaces.first { $0.id == id }
    }

    // MARK: - Session Persistence

    private struct TabSession: Codable {
        let id: UUID
        let url: URL?
        let title: String
        let interactionState: Data?
        let faviconURL: URL?
    }

    private struct SpaceSession: Codable {
        let id: UUID
        let name: String
        let emoji: String
        let colorHex: String
        let tabs: [TabSession]
        let selectedTabID: UUID?
    }

    private struct BrowserSession: Codable {
        let spaces: [SpaceSession]
        let activeSpaceID: UUID?
    }

    private static var sessionURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MyBrowser", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.json")
    }

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
        let spaceSessions = spaces.map { space -> SpaceSession in
            let tabSessions = space.tabs.map { tab -> TabSession in
                var stateData: Data?
                if let state = tab.webView.interactionState {
                    stateData = try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false)
                }
                return TabSession(id: tab.id, url: tab.url, title: tab.title, interactionState: stateData, faviconURL: tab.faviconURL)
            }
            return SpaceSession(id: space.id, name: space.name, emoji: space.emoji, colorHex: space.colorHex, tabs: tabSessions, selectedTabID: space.selectedTabID)
        }
        let session = BrowserSession(spaces: spaceSessions, activeSpaceID: lastActiveSpaceID)
        if let data = try? JSONEncoder().encode(session) {
            try? data.write(to: Self.sessionURL, options: .atomic)
        }
    }

    /// Restores session. Returns (activeSpaceID, selectedTabID) for the window to use.
    func restoreSession() -> (spaceID: UUID, tabID: UUID?)? {
        guard let data = try? Data(contentsOf: Self.sessionURL),
              let session = try? JSONDecoder().decode(BrowserSession.self, from: data),
              !session.spaces.isEmpty else { return nil }

        for spaceSession in session.spaces {
            let space = Space(id: spaceSession.id, name: spaceSession.name, emoji: spaceSession.emoji, colorHex: spaceSession.colorHex)
            space.selectedTabID = spaceSession.selectedTabID
            for tabSession in spaceSession.tabs {
                let tab = BrowserTab(
                    id: tabSession.id,
                    title: tabSession.title,
                    archivedInteractionState: tabSession.interactionState,
                    fallbackURL: tabSession.url,
                    faviconURL: tabSession.faviconURL,
                    configuration: space.makeWebViewConfiguration()
                )
                space.tabs.append(tab)
                subscribeToTab(tab)
            }
            spaces.append(space)
        }

        let activeID = session.activeSpaceID ?? spaces.first!.id
        lastActiveSpaceID = activeID
        notifyObservers { $0.tabStoreDidUpdateSpaces() }

        let activeSpace = space(withID: activeID)
        return (activeID, activeSpace?.selectedTabID)
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

        subscribeToTab(tab)
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

    private func subscribeToTab(_ tab: BrowserTab) {
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
