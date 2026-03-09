import Foundation
import Combine

protocol TabStoreObserver: AnyObject {
    func tabStoreDidInsertTab(_ tab: BrowserTab, at index: Int)
    func tabStoreDidRemoveTab(_ tab: BrowserTab, at index: Int)
    func tabStoreDidReorderTabs()
    func tabStoreDidUpdateTab(_ tab: BrowserTab, at index: Int)
}

class TabStore {
    static let shared = TabStore()

    private(set) var tabs: [BrowserTab] = []
    var selectedTabID: UUID?
    private var observers: [WeakObserver] = []
    private var tabSubscriptions: [UUID: Set<AnyCancellable>] = [:]
    private var saveWorkItem: DispatchWorkItem?

    private init() {}

    // MARK: - Session Persistence

    private struct TabSession: Codable {
        let id: UUID
        let url: URL?
        let title: String
        let interactionState: Data?
    }

    private struct BrowserSession: Codable {
        let tabs: [TabSession]
        let selectedTabID: UUID?
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
        let tabSessions = tabs.map { tab -> TabSession in
            var stateData: Data?
            if let state = tab.webView.interactionState {
                stateData = try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false)
            }
            return TabSession(id: tab.id, url: tab.url, title: tab.title, interactionState: stateData)
        }
        let session = BrowserSession(tabs: tabSessions, selectedTabID: selectedTabID)
        if let data = try? JSONEncoder().encode(session) {
            try? data.write(to: Self.sessionURL, options: .atomic)
        }
    }

    func restoreSession() -> UUID? {
        guard let data = try? Data(contentsOf: Self.sessionURL),
              let session = try? JSONDecoder().decode(BrowserSession.self, from: data),
              !session.tabs.isEmpty else { return nil }

        for tabSession in session.tabs {
            let tab = BrowserTab(
                id: tabSession.id,
                title: tabSession.title,
                archivedInteractionState: tabSession.interactionState,
                fallbackURL: tabSession.url
            )
            tabs.append(tab)
            subscribeToTab(tab)
            notifyObservers { $0.tabStoreDidInsertTab(tab, at: self.tabs.count - 1) }
        }

        return session.selectedTabID
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

    // MARK: - Tab Mutations

    @discardableResult
    func addTab(url: URL? = nil, afterTabID: UUID? = nil) -> BrowserTab {
        let tab = BrowserTab()

        let insertionIndex: Int
        if let afterTabID, let afterIndex = tabs.firstIndex(where: { $0.id == afterTabID }) {
            insertionIndex = afterIndex + 1
            tabs.insert(tab, at: insertionIndex)
        } else {
            tabs.append(tab)
            insertionIndex = tabs.count - 1
        }

        subscribeToTab(tab)
        notifyObservers { $0.tabStoreDidInsertTab(tab, at: insertionIndex) }

        if let url {
            tab.load(url)
        }

        scheduleSave()
        return tab
    }

    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        tabSubscriptions.removeValue(forKey: tab.id)
        tabs.remove(at: index)
        notifyObservers { $0.tabStoreDidRemoveTab(tab, at: index) }

        if tabs.isEmpty {
            addTab()
        }
        scheduleSave()
    }

    func moveTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < tabs.count,
              destinationIndex >= 0, destinationIndex < tabs.count else { return }
        let tab = tabs.remove(at: sourceIndex)
        tabs.insert(tab, at: destinationIndex)
        notifyObservers { $0.tabStoreDidReorderTabs() }
        scheduleSave()
    }

    func tab(withID id: UUID) -> BrowserTab? {
        tabs.first { $0.id == id }
    }

    func index(of id: UUID) -> Int? {
        tabs.firstIndex { $0.id == id }
    }

    // MARK: - Per-Tab Subscriptions

    private func subscribeToTab(_ tab: BrowserTab) {
        var cancellables = Set<AnyCancellable>()

        tab.$title
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] _ in
                guard let self, let tab, let index = self.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
                self.notifyObservers { $0.tabStoreDidUpdateTab(tab, at: index) }
            }
            .store(in: &cancellables)

        tab.$url
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] _ in
                guard let self, let tab, let index = self.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
                self.notifyObservers { $0.tabStoreDidUpdateTab(tab, at: index) }
                self.scheduleSave()
            }
            .store(in: &cancellables)

        tabSubscriptions[tab.id] = cancellables
    }
}

private struct WeakObserver {
    weak var value: (any TabStoreObserver)?
}
