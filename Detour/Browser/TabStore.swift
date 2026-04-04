import Foundation
import AppKit
import Combine
import WebKit

extension Notification.Name {
    static let tabRestoredByUndo = Notification.Name("tabRestoredByUndo")
}

protocol TabStoreObserver: AnyObject {
    func tabStoreDidInsertTab(_ tab: BrowserTab, at index: Int, in space: Space)
    func tabStoreDidRemoveTab(_ tab: BrowserTab, at index: Int, in space: Space)
    func tabStoreDidReorderTabs(in space: Space)
    func tabStoreDidUpdateTab(_ tab: BrowserTab, at index: Int, in space: Space)
    func tabStoreDidUpdateSpaces()

    // Pinned entry observer methods
    func tabStoreDidInsertPinnedEntry(_ entry: PinnedEntry, at index: Int, in space: Space)
    func tabStoreDidRemovePinnedEntry(_ entry: PinnedEntry, at index: Int, in space: Space)
    func tabStoreDidReorderPinnedEntries(in space: Space)
    func tabStoreDidUpdatePinnedEntry(_ entry: PinnedEntry, at index: Int, in space: Space)

    // Pin/unpin atomic notifications
    func tabStoreDidPinTab(_ entry: PinnedEntry, fromIndex: Int, toIndex: Int, in space: Space)
    func tabStoreDidUnpinTab(_ entry: PinnedEntry, fromIndex: Int, toIndex: Int, in space: Space)

    // Pinned folder notifications
    func tabStoreDidUpdatePinnedFolders(in space: Space)

    // Favorites notifications
    func tabStoreDidUpdateFavorites(for profile: Profile)
}

extension TabStoreObserver {
    func tabStoreDidInsertTab(_ tab: BrowserTab, at index: Int, in space: Space) {}
    func tabStoreDidRemoveTab(_ tab: BrowserTab, at index: Int, in space: Space) {}
    func tabStoreDidReorderTabs(in space: Space) {}
    func tabStoreDidUpdateTab(_ tab: BrowserTab, at index: Int, in space: Space) {}
    func tabStoreDidUpdateSpaces() {}
    func tabStoreDidInsertPinnedEntry(_ entry: PinnedEntry, at index: Int, in space: Space) {}
    func tabStoreDidRemovePinnedEntry(_ entry: PinnedEntry, at index: Int, in space: Space) {}
    func tabStoreDidReorderPinnedEntries(in space: Space) {}
    func tabStoreDidUpdatePinnedEntry(_ entry: PinnedEntry, at index: Int, in space: Space) {}
    func tabStoreDidPinTab(_ entry: PinnedEntry, fromIndex: Int, toIndex: Int, in space: Space) {}
    func tabStoreDidUnpinTab(_ entry: PinnedEntry, fromIndex: Int, toIndex: Int, in space: Space) {}
    func tabStoreDidUpdateFavorites(for profile: Profile) {}
    func tabStoreDidUpdatePinnedFolders(in space: Space) {}
}

// MARK: - Space

class Space {
    let id: UUID
    var name: String
    var emoji: String
    var colorHex: String
    var tabs: [BrowserTab] = []
    var pinnedEntries: [PinnedEntry] = []
    var pinnedFolders: [PinnedFolder] = []
    var selectedTabID: UUID?
    var profileID: UUID
    var profile: Profile?

    var isIncognito: Bool { profile?.isIncognito ?? false }

    var pinnedTabs: [BrowserTab] { pinnedEntries.compactMap(\.tab) }

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
    /// When per-tab isolation is enabled, each call gets its own non-persistent store.
    func makeWebViewConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        if profile?.isPerTabIsolation == true {
            config.websiteDataStore = .nonPersistent()
        } else {
            config.websiteDataStore = dataStore
        }

        // Wire this profile's extension controller so content scripts inject automatically
        config.webExtensionController = profile?.extensionController

        // Register favicon scheme handler so extension iframes (e.g., Vomnibar) can
        // load favicon images via detour-favicon:// URLs rewritten by the polyfill.
        config.setURLSchemeHandler(FaviconSchemeHandler(), forURLScheme: FaviconSchemeHandler.scheme)

        let script = WKUserScript(source: Space.linkHoverScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        config.userContentController.addUserScript(script)

        let editableFocusScript = WKUserScript(source: Space.editableFieldFocusScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        config.userContentController.addUserScript(editableFocusScript)

        // Apply content blocking rules
        if let profile {
            ContentBlockerManager.shared.applyRuleLists(to: config.userContentController, profile: profile)
        }

        // Inject Chrome Web Store install interceptor (at document start for API polyfill)
        let cwsEarlyScript = WKUserScript(
            source: Space.chromeWebStoreEarlyScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(cwsEarlyScript)
        // DOM-based fallback at document end
        let cwsScript = WKUserScript(
            source: Space.chromeWebStoreScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(cwsScript)

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

    /// Tracks focus/blur on editable elements (input, textarea, contentEditable)
    /// and posts to `editableFieldFocus` so native undo routing can adapt.
    private static let editableFieldFocusScript = """
    (function() {
        function isEditable(el) {
            if (!el || el === document.body) return false;
            var tag = el.tagName;
            if (tag === 'TEXTAREA') return true;
            if (tag === 'INPUT') {
                var t = (el.type || 'text').toLowerCase();
                return t === 'text' || t === 'search' || t === 'url' || t === 'email'
                    || t === 'password' || t === 'tel' || t === 'number';
            }
            if (el.isContentEditable) return true;
            return false;
        }
        document.addEventListener('focusin', function() {
            window.webkit.messageHandlers.editableFieldFocus.postMessage(isEditable(document.activeElement));
        });
        document.addEventListener('focusout', function() {
            window.webkit.messageHandlers.editableFieldFocus.postMessage(false);
        });
    })();
    """

    /// Polyfills `chrome.webstore.install()` before the page's JS runs.
    static let chromeWebStoreEarlyScript = """
    (function() {
        if (location.hostname !== 'chromewebstore.google.com') return;

        function extractID(url) {
            try {
                var path = url ? new URL(url, location.href).pathname : location.pathname;
                var parts = path.split('/').filter(Boolean);
                if (parts[0] === 'detail') {
                    var last = parts[parts.length - 1];
                    if (/^[a-z]{32}$/.test(last)) return last;
                }
            } catch(e) {}
            return null;
        }

        function crxURL(extID) {
            return 'https://clients2.google.com/service/update2/crx'
                + '?response=redirect&prodversion=131.0&acceptformat=crx3'
                + '&x=id%3D' + extID + '%26installsource%3Dondemand%26uc';
        }

        // Polyfill chrome.webstore.install(url, onSuccess, onFailure)
        if (!window.chrome) window.chrome = {};
        if (!window.chrome.webstore) window.chrome.webstore = {};
        window.chrome.webstore.install = function(url, onSuccess, onFailure) {
            var extID = extractID(url) || extractID(null);
            if (!extID) {
                if (onFailure) onFailure('Could not determine extension ID');
                return;
            }
            location.href = crxURL(extID);
            if (onSuccess) setTimeout(onSuccess, 100);
        };

        // Feature-detection: pretend we're Chrome so the store enables the button
        if (!window.chrome.app) {
            window.chrome.app = { isInstalled: false, installState: 'not_installed', getIsInstalled: function() { return false; } };
        }
    })();
    """

    /// DOM fallback: hijacks "Add to Chrome" buttons on the Chrome Web Store
    /// for the modern store UI that doesn't use chrome.webstore.install().
    static let chromeWebStoreScript = """
    (function() {
        if (location.hostname !== 'chromewebstore.google.com') return;

        function extractID() {
            var parts = location.pathname.split('/').filter(Boolean);
            if (parts[0] === 'detail') {
                var last = parts[parts.length - 1];
                if (/^[a-z]{32}$/.test(last)) return last;
            }
            return null;
        }

        function crxURL(extID) {
            return 'https://clients2.google.com/service/update2/crx'
                + '?response=redirect&prodversion=131.0&acceptformat=crx3'
                + '&x=id%3D' + extID + '%26installsource%3Dondemand%26uc';
        }

        function hijackButtons() {
            var extID = extractID();
            if (!extID) return;

            var buttons = document.querySelectorAll('button');
            for (var i = 0; i < buttons.length; i++) {
                var btn = buttons[i];
                var text = btn.textContent.trim();
                if ((text.indexOf('Add to') === 0 || text === 'Install') && !btn.dataset.detourHijacked) {
                    btn.dataset.detourHijacked = '1';
                    btn.disabled = false;
                    btn.style.pointerEvents = 'auto';
                    btn.style.opacity = '1';
                    btn.addEventListener('click', function(e) {
                        e.preventDefault();
                        e.stopPropagation();
                        e.stopImmediatePropagation();
                        location.href = crxURL(extID);
                    }, true);
                }
            }
        }

        hijackButtons();
        new MutationObserver(hijackButtons).observe(document.body || document.documentElement, { childList: true, subtree: true });
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
    static let incognitoProfileID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private let appDB: AppDatabase
    private let historyDB: HistoryDatabase

    private(set) var profiles: [Profile] = []
    private(set) var spaces: [Space] = []
    private(set) var closedTabStack: [ClosedTabRecord] = []
    private var observers: [WeakObserver] = []
    private var tabSubscriptions: [UUID: Set<AnyCancellable>] = [:]
    private var saveWorkItem: DispatchWorkItem?

    /// Undo manager for structural browser operations (tabs, pinned entries, folders, spaces).
    let undoManager = UndoManager()

    /// Used only for persistence — the space that was last active when saving.
    /// Each window tracks its own active space independently.
    var lastActiveSpaceID: UUID?

    /// In-memory dedup cache for history: "url|spaceID" -> timestamp
    private var recentHistoryWrites: [String: TimeInterval] = [:]

    init(appDB: AppDatabase = .shared, historyDB: HistoryDatabase = .shared) {
        self.appDB = appDB
        self.historyDB = historyDB
    }

    // MARK: - Undo Helpers

    private func registerUndo(actionName: String, handler: @escaping () -> Void) {
        undoManager.registerUndo(withTarget: self) { _ in handler() }
        undoManager.setActionName(actionName)
    }

    /// Removes a space by ID without the "keep at least one" guard.
    /// Use only in test tearDown to ensure clean state between tests.
    func forceRemoveSpace(id: UUID) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let space = spaces.remove(at: index)
        for tab in space.tabs {
            tabSubscriptions.removeValue(forKey: tab.id)
        }
        for entry in space.pinnedEntries {
            if let tab = entry.tab {
                tabSubscriptions.removeValue(forKey: tab.id)
            }
        }
        let spaceIDString = id.uuidString
        appDB.deleteClosedTabs(spaceID: spaceIDString)
        closedTabStack.removeAll { $0.spaceID == spaceIDString }
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
        guard id != Self.incognitoProfileID else { return }
        guard profiles.filter({ !$0.isIncognito }).count > 1 else { return }
        let hasSpaces = spaces.contains { $0.profileID == id && !$0.isIncognito }
        guard !hasSpaces else { return }
        profiles.removeAll { $0.id == id }
        appDB.deleteProfile(id: id.uuidString)
        scheduleSave()
    }

    /// Removes a profile by ID without guards.
    /// Use only in test tearDown to ensure clean state between tests.
    func forceRemoveProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
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
                    parentID: tab.parentID?.uuidString,
                    peekURL: tab.peekURL?.absoluteString,
                    peekInteractionState: tab.peekInteractionState,
                    peekFaviconURL: tab.peekFaviconURL?.absoluteString
                ))
            }

            // Also save backing tabs for live pinned entries (FK from pinnedTab.tabID → tab.id)
            for entry in space.pinnedEntries {
                guard let tab = entry.tab else { continue }
                let stateData = tab.currentInteractionStateData()
                tabRecords.append(TabRecord(
                    id: tab.id.uuidString,
                    spaceID: space.id.uuidString,
                    url: tab.url?.absoluteString,
                    title: tab.title,
                    faviconURL: tab.faviconURL?.absoluteString,
                    interactionState: stateData,
                    sortOrder: -1,  // Convention for backing tabs
                    lastDeselectedAt: tab.lastDeselectedAt?.timeIntervalSince1970,
                    parentID: tab.parentID?.uuidString,
                    peekURL: tab.peekURL?.absoluteString,
                    peekInteractionState: tab.peekInteractionState,
                    peekFaviconURL: tab.peekFaviconURL?.absoluteString
                ))
            }

            sessionData.append((spaceRecord, tabRecords))
        }

        // Append favorite backing tabs to session data BEFORE saving.
        // Each live favorite's tab is hosted in the first persistent space with its profile.
        var savedProfileIDs = Set<UUID>()
        for profile in profiles where !profile.isIncognito && !savedProfileIDs.contains(profile.id) {
            savedProfileIDs.insert(profile.id)
            guard let hostSpaceID = persistentSpaces.first(where: { $0.profileID == profile.id })?.id else { continue }
            for fav in profile.favorites {
                guard let tab = fav.tab else { continue }
                let stateData = tab.currentInteractionStateData()
                let tabRecord = TabRecord(
                    id: tab.id.uuidString,
                    spaceID: hostSpaceID.uuidString,
                    url: tab.url?.absoluteString,
                    title: tab.title,
                    faviconURL: tab.faviconURL?.absoluteString,
                    interactionState: stateData,
                    sortOrder: -2,
                    lastDeselectedAt: nil,
                    parentID: nil,
                    peekURL: nil,
                    peekInteractionState: nil,
                    peekFaviconURL: nil
                )
                if let idx = sessionData.firstIndex(where: { $0.0.id == hostSpaceID.uuidString }) {
                    sessionData[idx].1.append(tabRecord)
                }
            }
        }

        appDB.saveSession(
            spaces: sessionData,
            lastActiveSpaceID: lastActiveSpaceID?.uuidString
        )

        // Save profiles AFTER session so that stale profiles (no longer referenced
        // by any space) can be deleted without hitting FK constraint violations.
        let profileRecords = profiles.filter { !$0.isIncognito || $0.id == Self.incognitoProfileID }.map { $0.toRecord() }
        appDB.saveProfiles(profileRecords)

        // Save pinned folders and entries together in one transaction (entries FK → folders)
        for space in persistentSpaces {
            var folderRecords: [PinnedFolderRecord] = []
            for folder in space.pinnedFolders {
                folderRecords.append(PinnedFolderRecord(
                    id: folder.id.uuidString,
                    spaceID: space.id.uuidString,
                    parentFolderID: folder.parentFolderID?.uuidString,
                    name: folder.name,
                    isCollapsed: folder.isCollapsed,
                    sortOrder: folder.sortOrder
                ))
            }

            var pinnedRecords: [PinnedTabRecord] = []
            for entry in space.pinnedEntries {
                pinnedRecords.append(PinnedTabRecord(
                    id: entry.id.uuidString,
                    spaceID: space.id.uuidString,
                    pinnedURL: entry.pinnedURL.absoluteString,
                    pinnedTitle: entry.pinnedTitle,
                    faviconURL: entry.faviconURL?.absoluteString,
                    sortOrder: entry.sortOrder,
                    folderID: entry.folderID?.uuidString,
                    tabID: entry.tab?.id.uuidString
                ))
            }

            appDB.savePinnedFoldersAndTabs(folders: folderRecords, tabs: pinnedRecords, spaceID: space.id.uuidString)
        }

        // Save favorites per profile (AFTER session so tab FKs exist)
        savedProfileIDs.removeAll()
        for profile in profiles where !profile.isIncognito && !savedProfileIDs.contains(profile.id) {
            savedProfileIDs.insert(profile.id)
            let records = profile.favorites.enumerated().map { (i, fav) in
                FavoriteRecord(
                    id: fav.id.uuidString,
                    profileID: profile.id.uuidString,
                    url: fav.url.absoluteString,
                    title: fav.title,
                    faviconURL: fav.faviconURL?.absoluteString,
                    sortOrder: i,
                    tabID: fav.tab?.id.uuidString
                )
            }
            appDB.saveFavorites(records, profileID: profile.id.uuidString)
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

        // Load favorites for each profile (after spaces so backing tabs can be found)
        // Build a global lookup of all tab records by ID for matching backing tabs
        var allTabRecordsByID: [String: (TabRecord, UUID)] = [:]  // tabID → (record, spaceID)
        for (spaceRecord, tabRecords) in session.spaces {
            guard let spaceID = UUID(uuidString: spaceRecord.id) else { continue }
            for tabRecord in tabRecords where tabRecord.sortOrder == -2 {
                allTabRecordsByID[tabRecord.id] = (tabRecord, spaceID)
            }
        }
        for profile in profiles {
            let favRecords = appDB.loadFavorites(profileID: profile.id.uuidString)
            // Find a space with this profile for creating tabs
            let hostSpace = self.spaces.first(where: { $0.profileID == profile.id && !$0.isIncognito })
            for record in favRecords {
                guard let favID = UUID(uuidString: record.id) else { continue }

                var backingTab: BrowserTab? = nil
                if let tabIDStr = record.tabID,
                   let tabID = UUID(uuidString: tabIDStr),
                   let (tabRecord, _) = allTabRecordsByID[tabIDStr],
                   let hostSpace {
                    backingTab = BrowserTab(
                        id: tabID,
                        title: tabRecord.title,
                        url: tabRecord.url.flatMap { URL(string: $0) },
                        faviconURL: tabRecord.faviconURL.flatMap { URL(string: $0) },
                        cachedInteractionState: tabRecord.interactionState,
                        spaceID: hostSpace.id
                    )
                    backingTab?.spaceID = hostSpace.id
                    if let tab = backingTab {
                        self.subscribeToTab(tab, spaceID: hostSpace.id)
                    }
                }

                let favorite = Favorite(
                    id: favID,
                    url: URL(string: record.url) ?? URL(string: "about:blank")!,
                    title: record.title,
                    faviconURL: record.faviconURL.flatMap { URL(string: $0) },
                    sortOrder: record.sortOrder,
                    tab: backingTab
                )
                if backingTab == nil {
                    favorite.onFaviconDownloaded = { [weak self, weak favorite] in
                        guard let self, let favorite else { return }
                        self.notifyObservers { $0.tabStoreDidUpdateFavorites(for: profile) }
                    }
                }
                profile.favorites.append(favorite)
            }
        }

        // Ensure the built-in incognito profile exists
        ensureIncognitoProfile()

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

            // Identify backing tab IDs (referenced by pinned entries)
            let pinnedRecords = appDB.loadPinnedTabs(spaceID: spaceRecord.id)
            let backingTabIDs = Set(pinnedRecords.compactMap(\.tabID))

            // Load normal tabs (exclude pinned backing tabs and favorite backing tabs)
            for tabRecord in tabRecords {
                guard let tabID = UUID(uuidString: tabRecord.id) else { continue }
                guard !backingTabIDs.contains(tabRecord.id) else { continue }
                guard tabRecord.sortOrder >= 0 else { continue }
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
                tab.peekURL = tabRecord.peekURL.flatMap { URL(string: $0) }
                tab.peekInteractionState = tabRecord.peekInteractionState
                tab.peekFaviconURL = tabRecord.peekFaviconURL.flatMap { URL(string: $0) }
                tab.downloadPeekFavicon()
                space.tabs.append(tab)
                self.subscribeToTab(tab, spaceID: spaceID)
            }

            // Load pinned folders first
            let folderRecords = appDB.loadPinnedFolders(spaceID: spaceRecord.id)
            for folderRecord in folderRecords {
                let folder = PinnedFolder(
                    id: UUID(uuidString: folderRecord.id) ?? UUID(),
                    name: folderRecord.name,
                    parentFolderID: folderRecord.parentFolderID.flatMap { UUID(uuidString: $0) },
                    isCollapsed: folderRecord.isCollapsed,
                    sortOrder: folderRecord.sortOrder
                )
                space.pinnedFolders.append(folder)
            }

            // Build a lookup for tab records by ID (for matching backing tabs to pinned entries)
            let tabRecordsByID = Dictionary(tabRecords.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for pinnedRecord in pinnedRecords {
                guard let entryID = UUID(uuidString: pinnedRecord.id) else { continue }
                let pinnedURL = URL(string: pinnedRecord.pinnedURL) ?? URL(string: "about:blank")!

                var backingTab: BrowserTab? = nil
                if let backingTabIDStr = pinnedRecord.tabID,
                   let backingTabID = UUID(uuidString: backingTabIDStr),
                   let tabRecord = tabRecordsByID[backingTabIDStr] {
                    let isSelected = space.selectedTabID == backingTabID
                    if isSelected {
                        backingTab = BrowserTab(
                            id: backingTabID,
                            title: tabRecord.title,
                            archivedInteractionState: tabRecord.interactionState,
                            fallbackURL: tabRecord.url.flatMap { URL(string: $0) } ?? pinnedURL,
                            faviconURL: tabRecord.faviconURL.flatMap { URL(string: $0) },
                            configuration: space.makeWebViewConfiguration()
                        )
                    } else {
                        backingTab = BrowserTab(
                            id: backingTabID,
                            title: tabRecord.title,
                            url: tabRecord.url.flatMap { URL(string: $0) } ?? pinnedURL,
                            faviconURL: tabRecord.faviconURL.flatMap { URL(string: $0) },
                            cachedInteractionState: tabRecord.interactionState,
                            spaceID: spaceID
                        )
                    }
                    backingTab?.spaceID = spaceID
                    backingTab?.peekURL = tabRecord.peekURL.flatMap { URL(string: $0) }
                    backingTab?.peekInteractionState = tabRecord.peekInteractionState
                    backingTab?.peekFaviconURL = tabRecord.peekFaviconURL.flatMap { URL(string: $0) }
                    backingTab?.downloadPeekFavicon()
                    if let tab = backingTab {
                        self.subscribeToTab(tab, spaceID: spaceID)
                    }
                }

                let entry = PinnedEntry(
                    id: entryID,
                    pinnedURL: pinnedURL,
                    pinnedTitle: pinnedRecord.pinnedTitle,
                    faviconURL: pinnedRecord.faviconURL.flatMap { URL(string: $0) },
                    folderID: pinnedRecord.folderID.flatMap { UUID(uuidString: $0) },
                    sortOrder: pinnedRecord.sortOrder,
                    tab: backingTab
                )
                if backingTab == nil {
                    entry.onFaviconDownloaded = { [weak self, weak entry] in
                        guard let self, let entry else { return }
                        for space in self.spaces {
                            if let index = space.pinnedEntries.firstIndex(where: { $0.id == entry.id }) {
                                self.notifyObservers { $0.tabStoreDidUpdatePinnedEntry(entry, at: index, in: space) }
                                return
                            }
                        }
                    }
                }
                space.pinnedEntries.append(entry)
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

    // MARK: - Favorites

    private func reindexFavorites(_ profile: Profile) {
        for (i, fav) in profile.favorites.enumerated() { fav.sortOrder = i }
    }

    func addFavorite(from tab: BrowserTab, profileID: UUID, at index: Int? = nil) {
        guard let url = tab.url, let profile = profiles.first(where: { $0.id == profileID }) else { return }

        let favorite = Favorite(url: url, title: tab.title, faviconURL: tab.faviconURL, sortOrder: 0, tab: tab)
        let insertAt = min(index ?? profile.favorites.count, profile.favorites.count)
        profile.favorites.insert(favorite, at: insertAt)
        reindexFavorites(profile)
        notifyObservers { $0.tabStoreDidUpdateFavorites(for: profile) }
        scheduleSave()
    }

    func addFavoriteFromEntry(url: URL, title: String, faviconURL: URL?, favicon: NSImage?,
                              profileID: UUID, at index: Int) {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }

        let favorite = Favorite(url: url, title: title, faviconURL: faviconURL, sortOrder: 0)
        favorite.favicon = favicon
        let insertAt = min(index, profile.favorites.count)
        profile.favorites.insert(favorite, at: insertAt)
        reindexFavorites(profile)
        notifyObservers { $0.tabStoreDidUpdateFavorites(for: profile) }
        scheduleSave()
    }

    func activateFavorite(id: UUID, profileID: UUID, in space: Space) {
        guard let profile = profiles.first(where: { $0.id == profileID }),
              let fav = profile.favorites.first(where: { $0.id == id }),
              fav.tab == nil else { return }

        let tab = BrowserTab(
            id: UUID(),
            title: fav.title,
            archivedInteractionState: nil,
            fallbackURL: fav.url,
            faviconURL: fav.faviconURL,
            configuration: space.makeWebViewConfiguration()
        )
        tab.spaceID = space.id
        fav.tab = tab
        subscribeToTab(tab, spaceID: space.id)
        notifyObservers { $0.tabStoreDidUpdateFavorites(for: profile) }
        scheduleSave()
    }

    func removeFavorite(id: UUID, profileID: UUID) {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        profile.favorites.removeAll { $0.id == id }
        reindexFavorites(profile)
        notifyObservers { $0.tabStoreDidUpdateFavorites(for: profile) }
        scheduleSave()
    }

    /// Moves a favorite back into the tab list, removing it from favorites.
    func restoreFavoriteAsTab(id: UUID, profileID: UUID, in space: Space, at tabIndex: Int) {
        guard let profile = profiles.first(where: { $0.id == profileID }),
              let favIdx = profile.favorites.firstIndex(where: { $0.id == id }) else { return }
        let fav = profile.favorites.remove(at: favIdx)
        reindexFavorites(profile)

        let tab: BrowserTab
        if let liveTab = fav.tab {
            tab = liveTab
        } else {
            tab = BrowserTab(
                id: UUID(),
                title: fav.title,
                archivedInteractionState: nil,
                fallbackURL: fav.url,
                faviconURL: fav.faviconURL,
                configuration: space.makeWebViewConfiguration()
            )
            tab.spaceID = space.id
            subscribeToTab(tab, spaceID: space.id)
        }

        let insertAt = min(tabIndex, space.tabs.count)
        space.tabs.insert(tab, at: insertAt)
        notifyObservers { $0.tabStoreDidInsertTab(tab, at: insertAt, in: space) }
        notifyObservers { $0.tabStoreDidUpdateFavorites(for: profile) }
        scheduleSave()
    }

    /// Moves a favorite back into the pinned section, removing it from favorites.
    func restoreFavoriteAsPinned(id: UUID, profileID: UUID, in space: Space, at pinnedIndex: Int) {
        guard let profile = profiles.first(where: { $0.id == profileID }),
              let favIdx = profile.favorites.firstIndex(where: { $0.id == id }) else { return }
        let fav = profile.favorites.remove(at: favIdx)
        reindexFavorites(profile)

        let maxEntryOrder = space.pinnedEntries.map(\.sortOrder).max() ?? -1
        let maxFolderOrder = space.pinnedFolders.map(\.sortOrder).max() ?? -1
        let entry = PinnedEntry(
            id: UUID(),
            pinnedURL: fav.url,
            pinnedTitle: fav.title,
            faviconURL: fav.faviconURL,
            sortOrder: max(maxEntryOrder, maxFolderOrder) + 1,
            tab: fav.tab
        )
        if fav.tab == nil {
            entry.onFaviconDownloaded = { [weak self, weak entry] in
                guard let self, let entry else { return }
                for space in self.spaces {
                    if let index = space.pinnedEntries.firstIndex(where: { $0.id == entry.id }) {
                        self.notifyObservers { $0.tabStoreDidUpdatePinnedEntry(entry, at: index, in: space) }
                        return
                    }
                }
            }
        }

        let insertAt = min(pinnedIndex, space.pinnedEntries.count)
        space.pinnedEntries.insert(entry, at: insertAt)
        notifyObservers { $0.tabStoreDidInsertPinnedEntry(entry, at: insertAt, in: space) }
        notifyObservers { $0.tabStoreDidUpdateFavorites(for: profile) }
        scheduleSave()
    }

    func reorderFavorite(from sourceIndex: Int, to destinationIndex: Int, profileID: UUID) {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        guard sourceIndex >= 0, sourceIndex < profile.favorites.count else { return }
        let fav = profile.favorites.remove(at: sourceIndex)
        let insertAt = min(destinationIndex, profile.favorites.count)
        profile.favorites.insert(fav, at: insertAt)
        reindexFavorites(profile)
        notifyObservers { $0.tabStoreDidUpdateFavorites(for: profile) }
        scheduleSave()
    }

    // MARK: - History Recording

    func recordHistoryVisit(tab: BrowserTab, spaceID: UUID) {
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
        registerUndo(actionName: "Add Space") { [weak self] in
            self?.deleteSpace(id: space.id)
        }
        notifyObservers { $0.tabStoreDidUpdateSpaces() }
        scheduleSave()
        return space
    }

    func deleteSpace(id: UUID) {
        guard spaces.count > 1,
              let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let space = spaces[index]

        // Capture state for undo before removing
        let savedName = space.name
        let savedEmoji = space.emoji
        let savedColorHex = space.colorHex
        let savedProfileID = space.profileID
        let savedIndex = index

        spaces.remove(at: index)
        for tab in space.tabs {
            tabSubscriptions.removeValue(forKey: tab.id)
            tab.teardown()
        }
        for entry in space.pinnedEntries {
            if let tab = entry.tab {
                tabSubscriptions.removeValue(forKey: tab.id)
                tab.teardown()
            }
        }
        // Clean up closed tab records for this space
        let spaceIDString = id.uuidString
        appDB.deleteClosedTabs(spaceID: spaceIDString)
        closedTabStack.removeAll { $0.spaceID == spaceIDString }

        registerUndo(actionName: "Delete Space") { [weak self] in
            guard let self else { return }
            let restored = Space(id: id, name: savedName, emoji: savedEmoji, colorHex: savedColorHex, profileID: savedProfileID)
            restored.profile = self.profile(withID: savedProfileID)
            let insertAt = min(savedIndex, self.spaces.count)
            self.spaces.insert(restored, at: insertAt)
            self.registerUndo(actionName: "Add Space") { [weak self] in
                self?.deleteSpace(id: id)
            }
            self.notifyObservers { $0.tabStoreDidUpdateSpaces() }
            self.scheduleSave()
        }

        // Data store belongs to profile now — don't remove it here
        notifyObservers { $0.tabStoreDidUpdateSpaces() }
        scheduleSave()
    }

    func updateSpace(id: UUID, name: String, emoji: String, colorHex: String, profileID: UUID) {
        guard let space = space(withID: id) else { return }
        let oldName = space.name
        let oldEmoji = space.emoji
        let oldColorHex = space.colorHex
        let oldProfileID = space.profileID
        space.name = name
        space.emoji = emoji
        space.colorHex = colorHex
        if space.profileID != profileID {
            space.profileID = profileID
            space.profile = profile(withID: profileID)
        }
        registerUndo(actionName: "Edit Space") { [weak self] in
            self?.updateSpace(id: id, name: oldName, emoji: oldEmoji, colorHex: oldColorHex, profileID: oldProfileID)
        }
        notifyObservers { $0.tabStoreDidUpdateSpaces() }
        scheduleSave()
    }

    func moveSpace(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < spaces.count,
              destinationIndex >= 0, destinationIndex < spaces.count else { return }
        let space = spaces.remove(at: sourceIndex)
        spaces.insert(space, at: destinationIndex)
        registerUndo(actionName: "Move Space") { [weak self] in
            self?.moveSpace(from: destinationIndex, to: sourceIndex)
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
    func ensureIncognitoProfile() -> Profile {
        if let existing = profiles.first(where: { $0.id == Self.incognitoProfileID }) {
            existing.isIncognito = true
            existing.name = "Private"
            return existing
        }
        let profile = Profile(id: Self.incognitoProfileID, name: "Private", isIncognito: true)
        profiles.append(profile)
        appDB.saveProfile(profile.toRecord())
        return profile
    }

    @discardableResult
    func addIncognitoSpace() -> Space {
        let profile = ensureIncognitoProfile()
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
        for entry in space.pinnedEntries {
            if let tab = entry.tab {
                tabSubscriptions.removeValue(forKey: tab.id)
            }
        }
        // Keep the built-in incognito profile — it persists across sessions
        notifyObservers { $0.tabStoreDidUpdateSpaces() }
    }

    // MARK: - Tab Mutations

    @discardableResult
    private func insertTab(_ tab: BrowserTab, in space: Space, parentID: UUID?) -> Int {
        tab.spaceID = space.id
        tab.parentID = parentID

        let existingTabs = space.tabs.map { (id: $0.id, parentID: $0.parentID) }
        let pinnedTabIDs = Set(space.pinnedEntries.compactMap { $0.tab?.id })
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

    /// Create a tab for an extension page (webkit-extension://) using the extension
    /// context's webViewConfiguration, which is required to resolve the URL scheme.
    @discardableResult
    func addExtensionTab(in space: Space, url: URL, configuration: WKWebViewConfiguration) -> BrowserTab {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: url))
        return addTab(in: space, webView: webView)
    }

    @discardableResult
    func addTab(in space: Space, webView: WKWebView, parentID: UUID? = nil) -> BrowserTab {
        let tab = BrowserTab(webView: webView)
        insertTab(tab, in: space, parentID: parentID)
        return tab
    }

    /// Detaches a tab from a space without closing or archiving it.
    /// Used when moving a tab to become a favorite's backing tab.
    func detachTab(id: UUID, from space: Space) {
        guard let index = space.tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = space.tabs.remove(at: index)
        notifyObservers { $0.tabStoreDidRemoveTab(tab, at: index, in: space) }
        scheduleSave()
    }

    /// Detaches a pinned entry from a space without closing or archiving it.
    /// Returns the backing tab if it was live.
    func detachPinnedEntry(id: UUID, from space: Space) -> BrowserTab? {
        guard let index = space.pinnedEntries.firstIndex(where: { $0.id == id }) else { return nil }
        let entry = space.pinnedEntries.remove(at: index)
        notifyObservers { $0.tabStoreDidRemovePinnedEntry(entry, at: index, in: space) }
        scheduleSave()
        return entry.tab
    }

    func closeTab(id: UUID, in space: Space, archivedAt: Date? = nil) {
        guard let index = space.tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = space.tabs[index]

        // Capture state for undo before teardown
        let stateData = tab.currentInteractionStateData()
        let tabURL = tab.url?.absoluteString
        let tabTitle = tab.title
        let tabFaviconURL = tab.faviconURL?.absoluteString
        let tabParentID = tab.parentID

        // Archive to closed tab stack (skip incognito)
        if !space.isIncognito {
            let record = ClosedTabRecord(
                id: nil,
                tabID: tab.id.uuidString,
                spaceID: space.id.uuidString,
                url: tabURL,
                title: tabTitle,
                faviconURL: tabFaviconURL,
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
        tab.teardown()

        // Register undo (skip for automated archival)
        if archivedAt == nil {
            registerUndo(actionName: "Close Tab") { [weak self] in
                guard let self else { return }
                let restored = BrowserTab(
                    id: UUID(),
                    title: tabTitle,
                    archivedInteractionState: stateData,
                    fallbackURL: tabURL.flatMap { URL(string: $0) },
                    faviconURL: tabFaviconURL.flatMap { URL(string: $0) },
                    configuration: space.makeWebViewConfiguration()
                )
                restored.spaceID = space.id
                restored.parentID = tabParentID
                let insertAt = min(index, space.tabs.count)
                space.tabs.insert(restored, at: insertAt)
                self.subscribeToTab(restored, spaceID: space.id)
                // Remove the corresponding closed-tab-stack entry
                if let stackIdx = self.closedTabStack.firstIndex(where: { $0.tabID == id.uuidString }) {
                    self.closedTabStack.remove(at: stackIdx)
                }
                self.registerUndo(actionName: "Close Tab") { [weak self] in
                    self?.closeTab(id: restored.id, in: space)
                }
                self.notifyObservers { $0.tabStoreDidInsertTab(restored, at: insertAt, in: space) }
                self.scheduleSave()
                NotificationCenter.default.post(name: .tabRestoredByUndo, object: nil, userInfo: ["tabID": restored.id, "spaceID": space.id])
            }
        }

        notifyObservers { $0.tabStoreDidRemoveTab(tab, at: index, in: space) }
        scheduleSave()
    }

    func moveTab(from sourceIndex: Int, to destinationIndex: Int, in space: Space) {
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < space.tabs.count,
              destinationIndex >= 0, destinationIndex < space.tabs.count else { return }
        let tab = space.tabs.remove(at: sourceIndex)
        space.tabs.insert(tab, at: destinationIndex)
        registerUndo(actionName: "Move Tab") { [weak self] in
            self?.moveTab(from: destinationIndex, to: sourceIndex, in: space)
        }
        notifyObservers { $0.tabStoreDidReorderTabs(in: space) }
        scheduleSave()
    }

    // MARK: - Pinned Tab Mutations

    func pinTab(id: UUID, in space: Space, at destinationIndex: Int? = nil) {
        guard let index = space.tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = space.tabs.remove(at: index)
        let maxEntryOrder = space.pinnedEntries.map(\.sortOrder).max() ?? -1
        let maxFolderOrder = space.pinnedFolders.map(\.sortOrder).max() ?? -1
        let entry = PinnedEntry(
            id: tab.id,
            pinnedURL: tab.url ?? URL(string: "about:blank")!,
            pinnedTitle: tab.title,
            faviconURL: tab.faviconURL,
            sortOrder: max(maxEntryOrder, maxFolderOrder) + 1,
            tab: tab
        )
        let insertAt = min(destinationIndex ?? space.pinnedEntries.count, space.pinnedEntries.count)
        space.pinnedEntries.insert(entry, at: insertAt)
        let savedTabIndex = index
        registerUndo(actionName: "Pin Tab") { [weak self] in
            self?.unpinTab(id: entry.id, in: space, at: savedTabIndex)
        }
        notifyObservers { $0.tabStoreDidPinTab(entry, fromIndex: index, toIndex: insertAt, in: space) }
        scheduleSave()
    }

    /// Creates a dormant pinned entry from a URL (e.g. when restoring a favorite to pinned).
    func pinURL(_ url: URL, title: String, faviconURL: URL?, in space: Space, at destinationIndex: Int? = nil) {
        let maxEntryOrder = space.pinnedEntries.map(\.sortOrder).max() ?? -1
        let maxFolderOrder = space.pinnedFolders.map(\.sortOrder).max() ?? -1
        let entry = PinnedEntry(
            id: UUID(),
            pinnedURL: url,
            pinnedTitle: title,
            faviconURL: faviconURL,
            sortOrder: max(maxEntryOrder, maxFolderOrder) + 1,
            tab: nil
        )
        entry.onFaviconDownloaded = { [weak self, weak entry] in
            guard let self, let entry else { return }
            for space in self.spaces {
                if let index = space.pinnedEntries.firstIndex(where: { $0.id == entry.id }) {
                    self.notifyObservers { $0.tabStoreDidUpdatePinnedEntry(entry, at: index, in: space) }
                    return
                }
            }
        }
        let insertAt = min(destinationIndex ?? space.pinnedEntries.count, space.pinnedEntries.count)
        space.pinnedEntries.insert(entry, at: insertAt)
        notifyObservers { $0.tabStoreDidInsertPinnedEntry(entry, at: insertAt, in: space) }
        scheduleSave()
    }

    func unpinTab(id: UUID, in space: Space, at destinationIndex: Int? = nil) {
        guard let index = space.pinnedEntries.firstIndex(where: { $0.id == id }) else { return }
        let entry = space.pinnedEntries.remove(at: index)
        let savedFolderID = entry.folderID
        let savedSortOrder = entry.sortOrder
        let savedPinnedIndex = index
        let tab: BrowserTab
        if let liveTab = entry.tab {
            tab = liveTab
        } else {
            // Dormant — create a new tab loading the pinned URL
            tab = BrowserTab(
                id: UUID(),
                title: entry.pinnedTitle,
                archivedInteractionState: nil,
                fallbackURL: entry.pinnedURL,
                faviconURL: entry.faviconURL,
                configuration: space.makeWebViewConfiguration()
            )
            tab.spaceID = space.id
            subscribeToTab(tab, spaceID: space.id)
        }
        let insertAt = min(destinationIndex ?? 0, space.tabs.count)
        space.tabs.insert(tab, at: insertAt)
        registerUndo(actionName: "Unpin Tab") { [weak self] in
            guard let self else { return }
            // Re-pin: remove from tabs, create entry, insert at original pinned position
            guard let tabIndex = space.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
            let tab = space.tabs.remove(at: tabIndex)
            let reEntry = PinnedEntry(
                id: tab.id,
                pinnedURL: tab.url ?? URL(string: "about:blank")!,
                pinnedTitle: tab.title,
                faviconURL: tab.faviconURL,
                folderID: savedFolderID,
                sortOrder: savedSortOrder,
                tab: tab
            )
            let reInsertAt = min(savedPinnedIndex, space.pinnedEntries.count)
            space.pinnedEntries.insert(reEntry, at: reInsertAt)
            self.registerUndo(actionName: "Unpin Tab") { [weak self] in
                self?.unpinTab(id: reEntry.id, in: space, at: tabIndex)
            }
            self.notifyObservers { $0.tabStoreDidPinTab(reEntry, fromIndex: tabIndex, toIndex: reInsertAt, in: space) }
            self.scheduleSave()
        }
        notifyObservers { $0.tabStoreDidUnpinTab(entry, fromIndex: index, toIndex: insertAt, in: space) }
        scheduleSave()
    }

    func closePinnedTab(id: UUID, in space: Space) {
        guard let index = space.pinnedEntries.firstIndex(where: { $0.id == id }) else { return }
        let entry = space.pinnedEntries[index]
        // Capture tab state for undo before discarding
        let tab = entry.tab
        let stateData = tab?.currentInteractionStateData()
        let tabURL = tab?.url
        let tabTitle = tab?.title
        let tabFaviconURL = tab?.faviconURL

        // Cache favicon before discarding tab
        if let tab {
            if let url = tab.faviconURL { entry.faviconURL = url }
            if let image = tab.favicon { entry.favicon = image }
            tabSubscriptions.removeValue(forKey: tab.id)
            tab.teardown()
        }
        entry.tab = nil  // Always make dormant, never remove entry
        entry.onFaviconDownloaded = { [weak self, weak entry] in
            guard let self, let entry else { return }
            for space in self.spaces {
                if let idx = space.pinnedEntries.firstIndex(where: { $0.id == entry.id }) {
                    self.notifyObservers { $0.tabStoreDidUpdatePinnedEntry(entry, at: idx, in: space) }
                    return
                }
            }
        }

        if tab != nil {
            registerUndo(actionName: "Close Tab") { [weak self] in
                guard let self else { return }
                guard let idx = space.pinnedEntries.firstIndex(where: { $0.id == id }) else { return }
                let entry = space.pinnedEntries[idx]
                guard entry.tab == nil else { return }  // Already live
                let restored = BrowserTab(
                    id: UUID(),
                    title: tabTitle ?? entry.pinnedTitle,
                    archivedInteractionState: stateData,
                    fallbackURL: tabURL ?? entry.pinnedURL,
                    faviconURL: tabFaviconURL ?? entry.faviconURL,
                    configuration: space.makeWebViewConfiguration()
                )
                restored.spaceID = space.id
                entry.tab = restored
                self.subscribeToTab(restored, spaceID: space.id)
                self.registerUndo(actionName: "Close Tab") { [weak self] in
                    self?.closePinnedTab(id: id, in: space)
                }
                self.notifyObservers { $0.tabStoreDidUpdatePinnedEntry(entry, at: idx, in: space) }
                self.scheduleSave()
                NotificationCenter.default.post(name: .tabRestoredByUndo, object: nil, userInfo: ["tabID": restored.id, "spaceID": space.id])
            }
        }

        notifyObservers { $0.tabStoreDidUpdatePinnedEntry(entry, at: index, in: space) }
        scheduleSave()
    }

    func deletePinnedEntry(id: UUID, in space: Space) {
        guard let index = space.pinnedEntries.firstIndex(where: { $0.id == id }) else { return }
        let entry = space.pinnedEntries[index]
        // Capture state for undo
        let savedPinnedURL = entry.pinnedURL
        let savedPinnedTitle = entry.pinnedTitle
        let savedFaviconURL = entry.faviconURL
        let savedFavicon = entry.favicon
        let savedFolderID = entry.folderID
        let savedSortOrder = entry.sortOrder

        if let tab = entry.tab {
            tabSubscriptions.removeValue(forKey: tab.id)
            tab.teardown()
        }
        space.pinnedEntries.remove(at: index)

        registerUndo(actionName: "Delete Tab") { [weak self] in
            guard let self else { return }
            let restored = PinnedEntry(
                id: id,
                pinnedURL: savedPinnedURL,
                pinnedTitle: savedPinnedTitle,
                faviconURL: savedFaviconURL,
                favicon: savedFavicon,
                folderID: savedFolderID,
                sortOrder: savedSortOrder
            )
            let insertAt = min(index, space.pinnedEntries.count)
            space.pinnedEntries.insert(restored, at: insertAt)
            self.registerUndo(actionName: "Delete Tab") { [weak self] in
                self?.deletePinnedEntry(id: id, in: space)
            }
            self.notifyObservers { $0.tabStoreDidInsertPinnedEntry(restored, at: insertAt, in: space) }
            self.scheduleSave()
        }

        notifyObservers { $0.tabStoreDidRemovePinnedEntry(entry, at: index, in: space) }
        scheduleSave()
    }

    func activatePinnedEntry(id: UUID, in space: Space) {
        guard let index = space.pinnedEntries.firstIndex(where: { $0.id == id }) else { return }
        let entry = space.pinnedEntries[index]
        guard entry.tab == nil else { return }  // Already live
        let tab = BrowserTab(
            id: UUID(),
            title: entry.pinnedTitle,
            archivedInteractionState: nil,
            fallbackURL: entry.pinnedURL,
            faviconURL: entry.faviconURL,
            configuration: space.makeWebViewConfiguration()
        )
        tab.spaceID = space.id
        entry.tab = tab
        subscribeToTab(tab, spaceID: space.id)
        notifyObservers { $0.tabStoreDidUpdatePinnedEntry(entry, at: index, in: space) }
        scheduleSave()
    }

    // MARK: - Pinned Folder Mutations

    @discardableResult
    func addPinnedFolder(name: String, parentFolderID: UUID? = nil, in space: Space) -> PinnedFolder {
        let maxFolderOrder = space.pinnedFolders.map(\.sortOrder).max() ?? -1
        let maxTabOrder = space.pinnedEntries.map(\.sortOrder).max() ?? -1
        let folder = PinnedFolder(name: name, parentFolderID: parentFolderID, sortOrder: max(maxFolderOrder, maxTabOrder) + 1)
        space.pinnedFolders.append(folder)
        registerUndo(actionName: "New Folder") { [weak self] in
            self?.deletePinnedFolder(id: folder.id, in: space)
        }
        notifyObservers { $0.tabStoreDidUpdatePinnedFolders(in: space) }
        scheduleSave()
        return folder
    }

    func deletePinnedFolder(id: UUID, in space: Space) {
        guard let folder = space.pinnedFolders.first(where: { $0.id == id }) else { return }
        let parentID = folder.parentFolderID
        let savedName = folder.name
        let savedIsCollapsed = folder.isCollapsed
        let savedSortOrder = folder.sortOrder

        // Capture which entries/folders will be reparented
        let reparentedEntryIDs = space.pinnedEntries.filter { $0.folderID == id }.map(\.id)
        let reparentedFolderIDs = space.pinnedFolders.filter { $0.parentFolderID == id }.map(\.id)

        // Reparent direct children (entries and folders) to the deleted folder's parent
        for entry in space.pinnedEntries where entry.folderID == id {
            entry.folderID = parentID
        }
        for child in space.pinnedFolders where child.parentFolderID == id {
            child.parentFolderID = parentID
        }

        space.pinnedFolders.removeAll { $0.id == id }

        registerUndo(actionName: "Delete Folder") { [weak self] in
            guard let self else { return }
            // Recreate folder
            let restored = PinnedFolder(id: id, name: savedName, parentFolderID: parentID, isCollapsed: savedIsCollapsed, sortOrder: savedSortOrder)
            space.pinnedFolders.append(restored)
            // Restore children's parent references
            for entry in space.pinnedEntries where reparentedEntryIDs.contains(entry.id) {
                entry.folderID = id
            }
            for child in space.pinnedFolders where reparentedFolderIDs.contains(child.id) {
                child.parentFolderID = id
            }
            self.registerUndo(actionName: "Delete Folder") { [weak self] in
                self?.deletePinnedFolder(id: id, in: space)
            }
            self.notifyObservers { $0.tabStoreDidUpdatePinnedFolders(in: space) }
            self.scheduleSave()
        }

        notifyObservers { $0.tabStoreDidUpdatePinnedFolders(in: space) }
        scheduleSave()
    }

    func renamePinnedEntry(id: UUID, name: String, in space: Space) {
        guard let index = space.pinnedEntries.firstIndex(where: { $0.id == id }) else { return }
        let oldName = space.pinnedEntries[index].pinnedTitle
        space.pinnedEntries[index].pinnedTitle = name
        registerUndo(actionName: "Rename") { [weak self] in
            self?.renamePinnedEntry(id: id, name: oldName, in: space)
        }
        notifyObservers { $0.tabStoreDidUpdatePinnedEntry(space.pinnedEntries[index], at: index, in: space) }
        scheduleSave()
    }

    func renamePinnedFolder(id: UUID, name: String, in space: Space) {
        guard let folder = space.pinnedFolders.first(where: { $0.id == id }) else { return }
        let oldName = folder.name
        folder.name = name
        registerUndo(actionName: "Rename Folder") { [weak self] in
            self?.renamePinnedFolder(id: id, name: oldName, in: space)
        }
        notifyObservers { $0.tabStoreDidUpdatePinnedFolders(in: space) }
        scheduleSave()
    }

    func togglePinnedFolderCollapsed(id: UUID, in space: Space) {
        guard let folder = space.pinnedFolders.first(where: { $0.id == id }) else { return }
        folder.isCollapsed.toggle()
        notifyObservers { $0.tabStoreDidUpdatePinnedFolders(in: space) }
        scheduleSave()
    }

    func movePinnedTabToFolder(tabID: UUID, folderID: UUID?, beforeItemID: UUID? = nil, in space: Space) {
        guard let entry = space.pinnedEntries.first(where: { $0.id == tabID }) else { return }
        let oldFolderID = entry.folderID
        let oldSortOrder = entry.sortOrder
        // Capture sort orders of all entries and folders for undo
        let savedEntrySortOrders = space.pinnedEntries.map { (id: $0.id, folderID: $0.folderID, sortOrder: $0.sortOrder) }
        let savedFolderSortOrders = space.pinnedFolders.map { (id: $0.id, parentFolderID: $0.parentFolderID, sortOrder: $0.sortOrder) }

        entry.folderID = folderID

        // Collect all sibling items (entries + folders) at the target level, excluding the moved entry
        struct SiblingItem {
            let id: UUID
            let sortOrder: Int
            enum Kind { case entry(PinnedEntry), folder(PinnedFolder) }
            let kind: Kind
        }

        var siblings: [SiblingItem] = []
        for e in space.pinnedEntries where e.folderID == folderID && e.id != tabID {
            siblings.append(SiblingItem(id: e.id, sortOrder: e.sortOrder, kind: .entry(e)))
        }
        for f in space.pinnedFolders where f.parentFolderID == folderID {
            siblings.append(SiblingItem(id: f.id, sortOrder: f.sortOrder, kind: .folder(f)))
        }
        siblings.sort { $0.sortOrder < $1.sortOrder }

        // Insert the moved entry at the right position
        let movedItem = SiblingItem(id: entry.id, sortOrder: 0, kind: .entry(entry))
        if let beforeItemID, let insertionPoint = siblings.firstIndex(where: { $0.id == beforeItemID }) {
            siblings.insert(movedItem, at: insertionPoint)
        } else {
            siblings.append(movedItem)
        }

        // Renumber all siblings
        for (i, sibling) in siblings.enumerated() {
            switch sibling.kind {
            case .entry(let e): e.sortOrder = i
            case .folder(let f): f.sortOrder = i
            }
        }

        registerUndo(actionName: "Move Tab") { [weak self] in
            guard let self else { return }
            // Restore all sort orders and folder assignments
            for saved in savedEntrySortOrders {
                if let e = space.pinnedEntries.first(where: { $0.id == saved.id }) {
                    e.folderID = saved.folderID
                    e.sortOrder = saved.sortOrder
                }
            }
            for saved in savedFolderSortOrders {
                if let f = space.pinnedFolders.first(where: { $0.id == saved.id }) {
                    f.parentFolderID = saved.parentFolderID
                    f.sortOrder = saved.sortOrder
                }
            }
            self.registerUndo(actionName: "Move Tab") { [weak self] in
                self?.movePinnedTabToFolder(tabID: tabID, folderID: folderID, beforeItemID: beforeItemID, in: space)
            }
            self.notifyObservers { $0.tabStoreDidUpdatePinnedFolders(in: space) }
            self.scheduleSave()
        }

        notifyObservers { $0.tabStoreDidUpdatePinnedFolders(in: space) }
        scheduleSave()
    }

    func movePinnedFolder(folderID: UUID, parentFolderID: UUID?, beforeItemID: UUID? = nil, in space: Space) {
        guard let folder = space.pinnedFolders.first(where: { $0.id == folderID }) else { return }
        // Capture state for undo
        let savedEntrySortOrders = space.pinnedEntries.map { (id: $0.id, folderID: $0.folderID, sortOrder: $0.sortOrder) }
        let savedFolderSortOrders = space.pinnedFolders.map { (id: $0.id, parentFolderID: $0.parentFolderID, sortOrder: $0.sortOrder) }

        folder.parentFolderID = parentFolderID

        // Collect all sibling items at the target level, excluding the moved folder
        struct SiblingItem {
            let id: UUID
            let sortOrder: Int
            enum Kind { case entry(PinnedEntry), folder(PinnedFolder) }
            let kind: Kind
        }

        var siblings: [SiblingItem] = []
        for e in space.pinnedEntries where e.folderID == parentFolderID {
            siblings.append(SiblingItem(id: e.id, sortOrder: e.sortOrder, kind: .entry(e)))
        }
        for f in space.pinnedFolders where f.parentFolderID == parentFolderID && f.id != folderID {
            siblings.append(SiblingItem(id: f.id, sortOrder: f.sortOrder, kind: .folder(f)))
        }
        siblings.sort { $0.sortOrder < $1.sortOrder }

        let movedItem = SiblingItem(id: folder.id, sortOrder: 0, kind: .folder(folder))
        if let beforeItemID, let insertionPoint = siblings.firstIndex(where: { $0.id == beforeItemID }) {
            siblings.insert(movedItem, at: insertionPoint)
        } else {
            siblings.append(movedItem)
        }

        for (i, sibling) in siblings.enumerated() {
            switch sibling.kind {
            case .entry(let e): e.sortOrder = i
            case .folder(let f): f.sortOrder = i
            }
        }

        registerUndo(actionName: "Move Folder") { [weak self] in
            guard let self else { return }
            for saved in savedEntrySortOrders {
                if let e = space.pinnedEntries.first(where: { $0.id == saved.id }) {
                    e.folderID = saved.folderID
                    e.sortOrder = saved.sortOrder
                }
            }
            for saved in savedFolderSortOrders {
                if let f = space.pinnedFolders.first(where: { $0.id == saved.id }) {
                    f.parentFolderID = saved.parentFolderID
                    f.sortOrder = saved.sortOrder
                }
            }
            self.registerUndo(actionName: "Move Folder") { [weak self] in
                self?.movePinnedFolder(folderID: folderID, parentFolderID: parentFolderID, beforeItemID: beforeItemID, in: space)
            }
            self.notifyObservers { $0.tabStoreDidUpdatePinnedFolders(in: space) }
            self.scheduleSave()
        }

        notifyObservers { $0.tabStoreDidUpdatePinnedFolders(in: space) }
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
        for space in spaces {
            let threshold = space.profile?.sleepThreshold ?? .oneHour
            guard threshold != .never else { continue }
            let cutoff = Date().addingTimeInterval(-threshold.rawValue)
            let pinnedTabIDs = Set(space.pinnedEntries.compactMap { $0.tab?.id })
            for tab in space.tabs {
                guard !tab.isSleeping, !pinnedTabIDs.contains(tab.id), !tab.isPlayingAudio,
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
                if let index = space.pinnedEntries.firstIndex(where: { $0.tab?.id == tab.id }) {
                    self.notifyObservers { $0.tabStoreDidUpdatePinnedEntry(space.pinnedEntries[index], at: index, in: space) }
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
        observe(\.$peekFavicon)
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
