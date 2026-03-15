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

    // Pin/unpin atomic notifications
    func tabStoreDidPinTab(_ tab: BrowserTab, fromIndex: Int, toIndex: Int, in space: Space)
    func tabStoreDidUnpinTab(_ tab: BrowserTab, fromIndex: Int, toIndex: Int, in space: Space)
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
    func tabStoreDidPinTab(_ tab: BrowserTab, fromIndex: Int, toIndex: Int, in space: Space) {}
    func tabStoreDidUnpinTab(_ tab: BrowserTab, fromIndex: Int, toIndex: Int, in space: Space) {}
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
    var profileID: UUID
    var profile: Profile?

    var isIncognito: Bool { profile?.isIncognito ?? false }

    var color: NSColor {
        NSColor(hex: colorHex) ?? .controlAccentColor
    }

    /// Data store is delegated to the profile.
    var dataStore: WKWebsiteDataStore {
        profile!.dataStore
    }

    init(id: UUID = UUID(), name: String, emoji: String, colorHex: String, profileID: UUID) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.colorHex = colorHex
        self.profileID = profileID
    }

    /// Returns a fresh WKWebViewConfiguration wired to this space's profile data store.
    func makeWebViewConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore

        let script = WKUserScript(source: Space.linkHoverScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        config.userContentController.addUserScript(script)

        // Set Detour app name as default; Safari/Custom modes override via
        // webView.customUserAgent in BrowserTab.applyUserAgent()
        config.applicationNameForUserAgent = UserAgentMode.detourAppName

        return config
    }

    private static let linkHoverScript = """
    (function() {
        var currentLink = null;
        document.addEventListener('mouseover', function(e) {
            var el = e.target.closest('a[href]');
            if (el !== currentLink) {
                currentLink = el;
                window.webkit.messageHandlers.linkHover.postMessage(el ? el.href : '');
            }
        });
        document.addEventListener('mouseout', function(e) {
            if (!currentLink) return;
            var related = e.relatedTarget;
            if (!related || !currentLink.contains(related)) {
                currentLink = null;
                window.webkit.messageHandlers.linkHover.postMessage('');
            }
        });
    })();
    """

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

    private let appDB: AppDatabase
    private let historyDB: HistoryDatabase

    private(set) var profiles: [Profile] = []
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

    init(appDB: AppDatabase = .shared, historyDB: HistoryDatabase = .shared) {
        self.appDB = appDB
        self.historyDB = historyDB
    }

    func space(withID id: UUID) -> Space? {
        spaces.first { $0.id == id }
    }

    func profile(withID id: UUID) -> Profile? {
        profiles.first { $0.id == id }
    }

    @discardableResult
    func addProfile(name: String) -> Profile {
        let profile = Profile(name: name)
        profiles.append(profile)
        appDB.saveProfile(profile.toRecord())
        scheduleSave()
        return profile
    }

    func updateProfile(_ profile: Profile) {
        appDB.saveProfile(profile.toRecord())
        scheduleSave()
        NotificationCenter.default.post(name: .init("UserAgentDidChange"), object: nil, userInfo: ["profileID": profile.id])
    }

    func deleteProfile(id: UUID) {
        guard profiles.filter({ !$0.isIncognito }).count > 1 else { return }
        let hasSpaces = spaces.contains { $0.profileID == id && !$0.isIncognito }
        guard !hasSpaces else { return }
        profiles.removeAll { $0.id == id }
        appDB.deleteProfile(id: id.uuidString)
        scheduleSave()
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

        // Save profiles
        let profileRecords = profiles.filter { !$0.isIncognito }.map { $0.toRecord() }
        appDB.saveProfiles(profileRecords)

        let persistentSpaces = spaces.filter { !$0.isIncognito }

        var sessionData: [(SpaceRecord, [TabRecord])] = []
        for (spaceIndex, space) in persistentSpaces.enumerated() {
            let spaceRecord = SpaceRecord(
                id: space.id.uuidString,
                name: space.name,
                emoji: space.emoji,
                colorHex: space.colorHex,
                sortOrder: spaceIndex,
                selectedTabID: space.selectedTabID?.uuidString,
                profileID: space.profileID.uuidString
            )

            var tabRecords: [TabRecord] = []
            for (tabIndex, tab) in space.tabs.enumerated() {
                let stateData = tab.currentInteractionStateData()
                tabRecords.append(TabRecord(
                    id: tab.id.uuidString,
                    spaceID: space.id.uuidString,
                    url: tab.url?.absoluteString,
                    title: tab.title,
                    faviconURL: tab.faviconURL?.absoluteString,
                    interactionState: stateData,
                    sortOrder: tabIndex,
                    lastDeselectedAt: tab.lastDeselectedAt?.timeIntervalSince1970,
                    parentID: tab.parentID?.uuidString
                ))
            }
            sessionData.append((spaceRecord, tabRecords))
        }

        appDB.saveSession(
            spaces: sessionData,
            lastActiveSpaceID: lastActiveSpaceID?.uuidString
        )

        // Save pinned tabs separately
        for space in persistentSpaces {
            var pinnedRecords: [PinnedTabRecord] = []
            for (i, tab) in space.pinnedTabs.enumerated() {
                let stateData = tab.currentInteractionStateData()
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
            appDB.savePinnedTabs(pinnedRecords, spaceID: space.id.uuidString)
        }
    }

    /// Restores session. Returns (activeSpaceID, selectedTabID) for the window to use.
    func restoreSession() -> (spaceID: UUID, tabID: UUID?)? {
        guard let session = appDB.loadSession() else { return nil }

        // Load profiles first
        let profileRecords = appDB.loadProfiles()
        for record in profileRecords {
            if let profile = Profile.from(record: record) {
                profiles.append(profile)
            }
        }

        for (spaceRecord, tabRecords) in session.spaces {
            guard let spaceID = UUID(uuidString: spaceRecord.id) else { continue }
            let profileID = UUID(uuidString: spaceRecord.profileID) ?? profiles.first!.id
            let space = Space(
                id: spaceID,
                name: spaceRecord.name,
                emoji: spaceRecord.emoji,
                colorHex: spaceRecord.colorHex,
                profileID: profileID
            )
            space.profile = profile(withID: profileID)
            if let selID = spaceRecord.selectedTabID {
                space.selectedTabID = UUID(uuidString: selID)
            }

            for tabRecord in tabRecords {
                guard let tabID = UUID(uuidString: tabRecord.id) else { continue }
                let isSelected = space.selectedTabID == tabID
                let tab: BrowserTab
                if isSelected {
                    tab = BrowserTab(
                        id: tabID,
                        title: tabRecord.title,
                        archivedInteractionState: tabRecord.interactionState,
                        fallbackURL: tabRecord.url.flatMap { URL(string: $0) },
                        faviconURL: tabRecord.faviconURL.flatMap { URL(string: $0) },
                        configuration: space.makeWebViewConfiguration()
                    )
                    tab.lastDeselectedAt = nil
                } else {
                    tab = BrowserTab(
                        id: tabID,
                        title: tabRecord.title,
                        url: tabRecord.url.flatMap { URL(string: $0) },
                        faviconURL: tabRecord.faviconURL.flatMap { URL(string: $0) },
                        cachedInteractionState: tabRecord.interactionState,
                        spaceID: spaceID
                    )
                    tab.lastDeselectedAt = tabRecord.lastDeselectedAt.map { Date(timeIntervalSince1970: $0) } ?? Date()
                }
                tab.spaceID = spaceID
                tab.parentID = tabRecord.parentID.flatMap { UUID(uuidString: $0) }
                space.tabs.append(tab)
                self.subscribeToTab(tab, spaceID: spaceID)
            }

            // Load pinned tabs
            let pinnedRecords = appDB.loadPinnedTabs(spaceID: spaceRecord.id)
            for pinnedRecord in pinnedRecords {
                guard let tabID = UUID(uuidString: pinnedRecord.id) else { continue }
                let isSelected = space.selectedTabID == tabID
                let tab: BrowserTab
                if isSelected {
                    tab = BrowserTab(
                        id: tabID,
                        title: pinnedRecord.title ?? pinnedRecord.pinnedTitle,
                        archivedInteractionState: pinnedRecord.interactionState,
                        fallbackURL: pinnedRecord.url.flatMap { URL(string: $0) } ?? URL(string: pinnedRecord.pinnedURL),
                        faviconURL: pinnedRecord.faviconURL.flatMap { URL(string: $0) },
                        configuration: space.makeWebViewConfiguration()
                    )
                } else {
                    tab = BrowserTab(
                        id: tabID,
                        title: pinnedRecord.title ?? pinnedRecord.pinnedTitle,
                        url: pinnedRecord.url.flatMap { URL(string: $0) } ?? URL(string: pinnedRecord.pinnedURL),
                        faviconURL: pinnedRecord.faviconURL.flatMap { URL(string: $0) },
                        cachedInteractionState: pinnedRecord.interactionState,
                        spaceID: spaceID
                    )
                }
                tab.isPinned = true
                tab.pinnedURL = URL(string: pinnedRecord.pinnedURL)
                tab.pinnedTitle = pinnedRecord.pinnedTitle
                tab.spaceID = spaceID
                space.pinnedTabs.append(tab)
                self.subscribeToTab(tab, spaceID: spaceID)
            }

            self.spaces.append(space)
        }

        // Load closed tab stack from DB
        self.closedTabStack = appDB.loadClosedTabs()

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

        historyDB.recordVisit(
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
    func addSpace(name: String, emoji: String, colorHex: String, profileID: UUID) -> Space {
        let space = Space(name: name, emoji: emoji, colorHex: colorHex, profileID: profileID)
        space.profile = profile(withID: profileID)
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
        appDB.deleteClosedTabs(spaceID: spaceIDString)
        closedTabStack.removeAll { $0.spaceID == spaceIDString }

        // Data store belongs to profile now — don't remove it here
        notifyObservers { $0.tabStoreDidUpdateSpaces() }
        scheduleSave()
    }

    func updateSpace(id: UUID, name: String, emoji: String, colorHex: String, profileID: UUID) {
        guard let space = space(withID: id) else { return }
        space.name = name
        space.emoji = emoji
        space.colorHex = colorHex
        if space.profileID != profileID {
            space.profileID = profileID
            space.profile = profile(withID: profileID)
        }
        notifyObservers { $0.tabStoreDidUpdateSpaces() }
        scheduleSave()
    }

    func ensureDefaultSpace() {
        guard spaces.isEmpty else { return }
        let profile = ensureDefaultProfile()
        let space = Space(name: "Home", emoji: "🏠", colorHex: "007AFF", profileID: profile.id)
        space.profile = profile
        spaces.append(space)
        lastActiveSpaceID = space.id
        notifyObservers { $0.tabStoreDidUpdateSpaces() }
    }

    @discardableResult
    private func ensureDefaultProfile() -> Profile {
        if let existing = profiles.first { return existing }
        let profile = Profile(name: "Default")
        profiles.append(profile)
        appDB.saveProfile(profile.toRecord())
        return profile
    }

    @discardableResult
    func addIncognitoSpace() -> Space {
        let profile = Profile(name: "Private", isIncognito: true)
        profiles.append(profile)
        let space = Space(name: "Private", emoji: "🔒", colorHex: "2C2C2E", profileID: profile.id)
        space.profile = profile
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
        // Remove the transient incognito profile
        if let profileIndex = profiles.firstIndex(where: { $0.id == space.profileID }) {
            profiles.remove(at: profileIndex)
        }
        notifyObservers { $0.tabStoreDidUpdateSpaces() }
    }

    // MARK: - Tab Mutations

    private func insertTab(_ tab: BrowserTab, in space: Space, parentID: UUID?) -> Int {
        tab.spaceID = space.id
        tab.parentID = parentID

        let existingTabs = space.tabs.map { (id: $0.id, parentID: $0.parentID) }
        let pinnedTabIDs = Set(space.pinnedTabs.map(\.id))
        let insertionIndex = tabInsertionIndex(
            parentID: parentID,
            existingTabs: existingTabs,
            pinnedTabIDs: pinnedTabIDs
        )

        space.tabs.insert(tab, at: insertionIndex)
        subscribeToTab(tab, spaceID: space.id)
        notifyObservers { $0.tabStoreDidInsertTab(tab, at: insertionIndex, in: space) }
        scheduleSave()
        return insertionIndex
    }

    @discardableResult
    func addTab(in space: Space, url: URL? = nil, parentID: UUID? = nil) -> BrowserTab {
        let tab = BrowserTab(configuration: space.makeWebViewConfiguration())
        insertTab(tab, in: space, parentID: parentID)
        if let url { tab.load(url) }
        return tab
    }

    @discardableResult
    func addTab(in space: Space, webView: WKWebView, parentID: UUID? = nil) -> BrowserTab {
        let tab = BrowserTab(webView: webView)
        insertTab(tab, in: space, parentID: parentID)
        return tab
    }

    func closeTab(id: UUID, in space: Space, archivedAt: Date? = nil) {
        guard let index = space.tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = space.tabs[index]

        // Archive to closed tab stack (skip incognito)
        if !space.isIncognito {
            let stateData = tab.currentInteractionStateData()
            let record = ClosedTabRecord(
                id: nil,
                tabID: tab.id.uuidString,
                spaceID: space.id.uuidString,
                url: tab.url?.absoluteString,
                title: tab.title,
                faviconURL: tab.faviconURL?.absoluteString,
                interactionState: stateData,
                sortOrder: index,
                archivedAt: archivedAt?.timeIntervalSince1970
            )
            appDB.pushClosedTab(record)
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
        notifyObservers { $0.tabStoreDidPinTab(tab, fromIndex: index, toIndex: insertAt, in: space) }
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
        notifyObservers { $0.tabStoreDidUnpinTab(tab, fromIndex: index, toIndex: insertAt, in: space) }
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
        _ = appDB.popClosedTab(spaceID: spaceIDString)

        let tab = BrowserTab(
            id: UUID(),
            title: record.title,
            archivedInteractionState: record.interactionState,
            fallbackURL: record.url.flatMap { URL(string: $0) },
            faviconURL: record.faviconURL.flatMap { URL(string: $0) },
            configuration: space.makeWebViewConfiguration()
        )
        tab.spaceID = space.id

        let insertionIndex = min(record.sortOrder, space.tabs.count)
        space.tabs.insert(tab, at: insertionIndex)
        subscribeToTab(tab, spaceID: space.id)
        notifyObservers { $0.tabStoreDidInsertTab(tab, at: insertionIndex, in: space) }
        scheduleSave()
        return tab
    }

    // MARK: - Tab Archiving

    private var archiveTimer: Timer?

    func startArchiveTimer() {
        archiveTimer?.invalidate()
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.sleepStaleTabs()
            self?.archiveStaleTabs()
        }
    }

    private func sleepStaleTabs() {
        let cutoff = Date().addingTimeInterval(-3600) // 1 hour
        for space in spaces {
            for tab in space.tabs + space.pinnedTabs {
                guard !tab.isSleeping, !tab.isPinned, !tab.isPlayingAudio,
                      let lastDeselected = tab.lastDeselectedAt,
                      lastDeselected < cutoff else { continue }
                tab.sleep()
            }
        }
        scheduleSave()
    }

    private func archiveStaleTabs() {
        let now = Date()

        for space in spaces where !space.isIncognito {
            let threshold = space.profile?.archiveThreshold ?? .twelveHours
            guard threshold != .never else { continue }
            let cutoff = Date().addingTimeInterval(-threshold.rawValue)

            let staleTabIDs = space.tabs.compactMap { tab -> UUID? in
                guard let lastDeselected = tab.lastDeselectedAt, lastDeselected < cutoff else { return nil }
                return tab.id
            }

            // Never archive the last remaining tab
            let remaining = space.tabs.count - staleTabIDs.count
            let idsToArchive = remaining >= 1 ? staleTabIDs : Array(staleTabIDs.dropLast())

            for tabID in idsToArchive {
                closeTab(id: tabID, in: space, archivedAt: now)
            }
        }
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

        /// Subscribe to a tab property, calling notify on change. If `save` is true, also schedules a save.
        func observe<T>(_ keyPath: KeyPath<BrowserTab, Published<T>.Publisher>, save: Bool = false) {
            tab[keyPath: keyPath]
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self, weak tab] _ in
                    guard let tab else { return }
                    notify(tab)
                    if save { self?.scheduleSave() }
                }
                .store(in: &cancellables)
        }

        observe(\.$title)
        observe(\.$url, save: true)
        observe(\.$favicon, save: true)
        observe(\.$isPlayingAudio)
        observe(\.$isMuted)

        tab.$isLoading
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] isLoading in
                guard let self, let tab else { return }
                notify(tab)
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

        tabSubscriptions[tab.id] = cancellables
    }
}

private struct WeakObserver {
    weak var value: (any TabStoreObserver)?
}
