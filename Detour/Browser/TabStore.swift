import Foundation
import AppKit
import Combine
import WebKit

extension Notification.Name {
    static let tabRestoredByUndo = Notification.Name("tabRestoredByUndo")
    /// Posted after a space's profile changes and its live tabs were slept so
    /// they rebind to the new profile. Windows showing the space re-select
    /// their own displayed tab (userInfo: "spaceID").
    static let spaceProfileDidSwap = Notification.Name("spaceProfileDidSwap")
}

protocol TabStoreObserver: AnyObject {
    func tabStoreDidInsertTab(_ tab: BrowserTab, at index: Int, in space: Space)
    func tabStoreDidRemoveTab(_ tab: BrowserTab, at index: Int, in space: Space)
    func tabStoreDidReorderTabs(in space: Space)
    func tabStoreDidUpdateTab(_ tab: BrowserTab, at index: Int, in space: Space)
    /// Split divider fraction changed — no structural change (structural split
    /// create/dissolve arrives as insert/remove/reorder callbacks).
    func tabStoreDidUpdateSplitLayout(in space: Space)
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
    func tabStoreDidUpdateSplitLayout(in space: Space) {}
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

    var nonIncognitoSpaces: [Space] { spaces.filter { !$0.isIncognito } }

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
                    peekFaviconURL: tab.peekFaviconURL?.absoluteString,
                    splitGroupID: tab.splitGroupID?.uuidString,
                    splitFraction: tab.splitFraction
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
                    tabID: entry.tab?.id.uuidString,
                    splitGroupID: entry.splitGroupID?.uuidString,
                    splitFraction: entry.splitFraction
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
                tab.splitGroupID = tabRecord.splitGroupID.flatMap { UUID(uuidString: $0) }
                tab.splitFraction = tabRecord.splitFraction
                tab.downloadPeekFavicon()
                space.tabs.append(tab)
                self.subscribeToTab(tab, spaceID: spaceID)
            }
            sanitizeSplitGroups(space.tabs)

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
                entry.splitGroupID = pinnedRecord.splitGroupID.flatMap { UUID(uuidString: $0) }
                entry.splitFraction = pinnedRecord.splitFraction
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
            sanitizePinnedSplitGroups(entries: space.pinnedEntries, folders: space.pinnedFolders)

            self.spaces.append(space)
        }

        // Load favorites for each profile. This MUST run after the spaces loop
        // above: a favorite's live backing tab is hosted in a restored space, so
        // `hostSpace` can only be resolved once `self.spaces` is populated. Running
        // it earlier left `hostSpace` nil, the backing tab was never recreated, and
        // its orphaned TabRecord got garbage-collected on the next save.
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

    /// Discards a favorite's live backing tab, returning it to a dormant tile
    /// (the favorite itself is kept). Used when the user closes a favorite-backed
    /// tab (Cmd+W). No-op if the favorite is already dormant.
    func deactivateFavorite(id: UUID, profileID: UUID) {
        guard let profile = profiles.first(where: { $0.id == profileID }),
              let fav = profile.favorites.first(where: { $0.id == id }),
              let tab = fav.tab else { return }
        tabSubscriptions.removeValue(forKey: tab.id)
        tab.teardown()
        fav.tab = nil
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

        let insertAt = snappedToSplitGroupBoundary(
            min(tabIndex, space.tabs.count),
            groupIDs: space.tabs.map(\.splitGroupID)
        )
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
        // Consume the typed flag even if this visit ends up skipped below, so it
        // can't leak onto a later, unrelated navigation.
        let typed = tab.consumeNextVisitIsTyped()

        // Never record history for incognito spaces
        if let space = space(withID: spaceID), space.isIncognito { return }

        guard let url = tab.url else { return }
        let urlString = url.absoluteString

        // Skip internal URLs
        guard url.scheme == "http" || url.scheme == "https" else { return }

        // Deduplicate: skip if same (url, spaceID) recorded within 30 seconds
        let dedupKey = "\(urlString)|\(spaceID.uuidString)"
        let now = Date().timeIntervalSince1970
        if !typed, let lastWrite = recentHistoryWrites[dedupKey], now - lastWrite < 30 {
            return
        }
        recentHistoryWrites[dedupKey] = now

        historyDB.recordVisit(
            url: urlString,
            title: tab.title,
            faviconURL: tab.faviconURL?.absoluteString,
            spaceID: spaceID.uuidString,
            typed: typed
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
        let savedSelectedTabID = space.selectedTabID
        let savedIndex = index
        let spaceIDString = id.uuidString

        // Snapshot the FULL space contents for undo BEFORE teardown discards the
        // webviews. teardown() releases each webView and its interaction state, so
        // undo rebuilds fresh BrowserTab objects from these value snapshots — the
        // same reconstruction restoreSession performs (selected tab live, rest
        // sleeping). Capturing interaction state here (via currentInteractionStateData)
        // must happen before the teardown loops below.
        struct TabSnapshot {
            let id: UUID
            let title: String
            let url: URL?
            let faviconURL: URL?
            let interactionState: Data?
            let parentID: UUID?
            let lastDeselectedAt: Date?
            let peekURL: URL?
            let peekInteractionState: Data?
            let peekFaviconURL: URL?
            let splitGroupID: UUID?
            let splitFraction: Double?
            let isSelected: Bool
        }
        struct EntrySnapshot {
            let id: UUID
            let pinnedURL: URL
            let pinnedTitle: String
            let faviconURL: URL?
            let favicon: NSImage?
            let folderID: UUID?
            let sortOrder: Int
            let backingTab: TabSnapshot?
            // Pinned split membership lives ONLY on the entry (design §12), so it
            // must be snapshotted here — the backing tab's splitGroupID is nil.
            let splitGroupID: UUID?
            let splitFraction: Double?
        }
        struct FolderSnapshot {
            let id: UUID
            let name: String
            let parentFolderID: UUID?
            let isCollapsed: Bool
            let sortOrder: Int
        }

        func snapshot(_ tab: BrowserTab) -> TabSnapshot {
            TabSnapshot(
                id: tab.id,
                title: tab.title,
                url: tab.url,
                faviconURL: tab.faviconURL,
                interactionState: tab.currentInteractionStateData(),
                parentID: tab.parentID,
                lastDeselectedAt: tab.lastDeselectedAt,
                peekURL: tab.peekURL,
                peekInteractionState: tab.peekInteractionState,
                peekFaviconURL: tab.peekFaviconURL,
                splitGroupID: tab.splitGroupID,
                splitFraction: tab.splitFraction,
                isSelected: space.selectedTabID == tab.id
            )
        }

        let savedTabs = space.tabs.map(snapshot)
        let savedEntries: [EntrySnapshot] = space.pinnedEntries.map { entry in
            EntrySnapshot(
                id: entry.id,
                pinnedURL: entry.pinnedURL,
                pinnedTitle: entry.pinnedTitle,
                faviconURL: entry.faviconURL,
                favicon: entry.favicon,
                folderID: entry.folderID,
                sortOrder: entry.sortOrder,
                backingTab: entry.tab.map(snapshot),
                splitGroupID: entry.splitGroupID,
                splitFraction: entry.splitFraction
            )
        }
        let savedFolders: [FolderSnapshot] = space.pinnedFolders.map { folder in
            FolderSnapshot(
                id: folder.id,
                name: folder.name,
                parentFolderID: folder.parentFolderID,
                isCollapsed: folder.isCollapsed,
                sortOrder: folder.sortOrder
            )
        }
        // Capture closed-tab records before they're purged so undo can restore them.
        let savedClosedTabs = closedTabStack.filter { $0.spaceID == spaceIDString }

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
        // Clean up closed tab records for this space (captured above for undo)
        appDB.deleteClosedTabs(spaceID: spaceIDString)
        closedTabStack.removeAll { $0.spaceID == spaceIDString }

        registerUndo(actionName: "Delete Space") { [weak self] in
            guard let self else { return }
            let restored = Space(id: id, name: savedName, emoji: savedEmoji, colorHex: savedColorHex, profileID: savedProfileID)
            restored.profile = self.profile(withID: savedProfileID)
            restored.selectedTabID = savedSelectedTabID

            // Rebuild a tab from its snapshot: selected tab live (displays
            // immediately), the rest sleeping — mirroring restoreSession.
            func rebuild(_ s: TabSnapshot) -> BrowserTab {
                let tab: BrowserTab
                if s.isSelected {
                    tab = BrowserTab(
                        id: s.id,
                        title: s.title,
                        archivedInteractionState: s.interactionState,
                        fallbackURL: s.url,
                        faviconURL: s.faviconURL,
                        configuration: restored.makeWebViewConfiguration()
                    )
                    tab.lastDeselectedAt = nil
                } else {
                    tab = BrowserTab(
                        id: s.id,
                        title: s.title,
                        url: s.url,
                        faviconURL: s.faviconURL,
                        cachedInteractionState: s.interactionState,
                        spaceID: restored.id
                    )
                    tab.lastDeselectedAt = s.lastDeselectedAt ?? Date()
                }
                tab.spaceID = restored.id
                tab.parentID = s.parentID
                tab.peekURL = s.peekURL
                tab.peekInteractionState = s.peekInteractionState
                tab.peekFaviconURL = s.peekFaviconURL
                tab.splitGroupID = s.splitGroupID
                tab.splitFraction = s.splitFraction
                tab.downloadPeekFavicon()
                self.subscribeToTab(tab, spaceID: restored.id)
                return tab
            }

            for s in savedTabs {
                restored.tabs.append(rebuild(s))
            }
            for f in savedFolders {
                restored.pinnedFolders.append(PinnedFolder(
                    id: f.id, name: f.name, parentFolderID: f.parentFolderID,
                    isCollapsed: f.isCollapsed, sortOrder: f.sortOrder
                ))
            }
            for e in savedEntries {
                let backing = e.backingTab.map(rebuild)
                let entry = PinnedEntry(
                    id: e.id,
                    pinnedURL: e.pinnedURL,
                    pinnedTitle: e.pinnedTitle,
                    faviconURL: e.faviconURL,
                    favicon: e.favicon,
                    folderID: e.folderID,
                    sortOrder: e.sortOrder,
                    tab: backing
                )
                // Pinned split membership lives ONLY on the entry (design §12) —
                // the backing tab's splitGroupID stays nil, so nothing re-derives
                // it. Restore it explicitly. savedEntries preserve original sort
                // order/adjacency, so the restored pair survives sanitizePinnedSplitGroups.
                entry.splitGroupID = e.splitGroupID
                entry.splitFraction = e.splitFraction
                if backing == nil {
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
                restored.pinnedEntries.append(entry)
            }

            let insertAt = min(savedIndex, self.spaces.count)
            self.spaces.insert(restored, at: insertAt)

            // Restore closed-tab records to both the DB and the in-memory stack so
            // Cmd+Shift+T works again after undo.
            for record in savedClosedTabs {
                self.appDB.pushClosedTab(record)
            }
            self.closedTabStack.insert(contentsOf: savedClosedTabs, at: 0)

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

            // Existing live tabs still hold WKWebViews that were built against the
            // OLD profile's data store and extension controller (configs are only
            // built at tab creation/wake via makeWebViewConfiguration). Sleep each
            // live tab so it releases the stale webView; on next display the tab
            // wakes and is rebuilt from the NEW profile's configuration. sleep()
            // preserves interaction state (cachedInteractionState) and sets
            // isSleeping, which the display path (selectTab → wake) relies on.
            // force: a profile swap is an explicit isolation action, so audio
            // playback does not exempt a tab — its media is paused and the tab
            // rebinds like any other.
            var liveTabs = space.tabs
            liveTabs.append(contentsOf: space.pinnedEntries.compactMap(\.tab))
            for tab in liveTabs where tab.webView != nil {
                tab.sleep(force: true)
            }

            // The OLD profile's favorites can hold live backing tabs bound to this
            // space (favorites are per-profile; their tabs live on Favorite.tab,
            // not in space.tabs/pinnedEntries, so the loop above misses them).
            // Those favorites disappear from this space's sidebar after the swap,
            // so return them to dormant tiles rather than leaving live webviews on
            // the old profile. Like Cmd+W on a favorite (deactivateFavorite), this
            // is not reversed by Edit Space undo.
            if let oldProfile = profile(withID: oldProfileID) {
                var deactivatedAny = false
                for fav in oldProfile.favorites {
                    guard let favTab = fav.tab, favTab.spaceID == id else { continue }
                    // Move selection off the favorite's tab before teardown so the
                    // refresh notification below re-selects a tab that still
                    // exists (selectTab no-ops on unresolvable IDs, which would
                    // leave the window on an empty pane).
                    if space.selectedTabID == favTab.id {
                        space.selectedTabID = space.tabs.first?.id
                            ?? space.pinnedEntries.first(where: { $0.tab != nil })?.tab?.id
                    }
                    tabSubscriptions.removeValue(forKey: favTab.id)
                    favTab.teardown()
                    fav.tab = nil
                    deactivatedAny = true
                }
                if deactivatedAny {
                    notifyObservers { $0.tabStoreDidUpdateFavorites(for: oldProfile) }
                }
            }

            // Every window on this space is now showing a dead pane (the sleeps
            // above released the displayed webViews). Nudge each window to
            // re-select and wake its own displayed tab under the new profile —
            // per-window, so a second window showing a different tab of this
            // space keeps its place (it falls back to space.selectedTabID only
            // when its own tab no longer resolves).
            NotificationCenter.default.post(
                name: .spaceProfileDidSwap, object: nil,
                userInfo: ["spaceID": id]
            )
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
        // Tear down tabs (mirror deleteSpace) so incognito webviews stop media and
        // release memory. Without this, audio keeps playing and content stays
        // resident — especially if an undo closure retains the space.
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
        let insertionIndex = snappedToSplitGroupBoundary(
            tabInsertionIndex(
                parentID: parentID,
                existingTabs: existingTabs,
                pinnedTabIDs: pinnedTabIDs
            ),
            groupIDs: space.tabs.map(\.splitGroupID)
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
        leaveSplitGroup(tab, in: space)
        notifyObservers { $0.tabStoreDidRemoveTab(tab, at: index, in: space) }
        scheduleSave()
    }

    /// Detaches a pinned entry from a space without closing or archiving it.
    /// Returns the backing tab if it was live.
    func detachPinnedEntry(id: UUID, from space: Space) -> BrowserTab? {
        guard let index = space.pinnedEntries.firstIndex(where: { $0.id == id }) else { return nil }
        let entry = space.pinnedEntries.remove(at: index)
        // Favorites can't be split members — leaving dissolves the pinned split.
        let groupID = entry.splitGroupID
        entry.splitGroupID = nil
        entry.splitFraction = nil
        dissolvePinnedSplit(around: id, groupID: groupID, in: space)
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
        let tabSplitFraction = tab.splitFraction
        let closedSplitGroup = splitGroup(containing: tab.id, in: space)
        let splitPartnerID = closedSplitGroup?.members.first { $0.id != tab.id }?.id
        // Partner sits left of the closing tab iff the closing tab wasn't the first member.
        let splitPartnerWasLeft = splitPartnerID != nil && closedSplitGroup?.members.first?.id != tab.id

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
        leaveSplitGroup(tab, in: space)

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
                let insertAt: Int
                // Rejoin the split if the partner is still an ungrouped normal tab.
                if let partnerID = splitPartnerID,
                   let partnerIndex = space.tabs.firstIndex(where: { $0.id == partnerID }),
                   space.tabs[partnerIndex].splitGroupID == nil {
                    let partner = space.tabs[partnerIndex]
                    insertAt = splitPartnerWasLeft ? partnerIndex + 1 : partnerIndex
                    let groupID = UUID()
                    partner.splitGroupID = groupID
                    partner.splitFraction = tabSplitFraction
                    restored.splitGroupID = groupID
                    restored.splitFraction = tabSplitFraction
                } else {
                    insertAt = snappedToSplitGroupBoundary(
                        min(index, space.tabs.count),
                        groupIDs: space.tabs.map(\.splitGroupID)
                    )
                }
                space.tabs.insert(restored, at: insertAt)
                self.subscribeToTab(restored, spaceID: space.id)
                // Remove the corresponding closed-tab-stack entry from both the
                // in-memory stack and the DB. Skipping the DB row would leave it to
                // be reloaded on next launch, so Cmd+Shift+T would reopen a duplicate.
                if let stackIdx = self.closedTabStack.firstIndex(where: { $0.tabID == id.uuidString }) {
                    self.closedTabStack.remove(at: stackIdx)
                }
                self.appDB.deleteClosedTab(tabID: id.uuidString)
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
        // No source==destination shortcut here: source is pre-removal, destination
        // post-removal — for a non-first split member the spaces differ and equal
        // numbers can still be a real move. resolveTabMove owns the no-op check.
        guard destinationIndex >= 0, destinationIndex < space.tabs.count,
              let move = resolveTabMove(
                  sourceIndex: sourceIndex,
                  destinationIndex: destinationIndex,
                  groupIDs: space.tabs.map(\.splitGroupID)
              ) else { return }
        performTabMove(move, in: space)
    }

    /// Drop-handling entry point: `gapIndex` is a pre-removal insertion gap
    /// (0...count). The gap→destination conversion happens in resolveTabMove,
    /// which knows the moved block's width — callers cannot (a split row is 2).
    func moveTab(id: UUID, toGapIndex gapIndex: Int, in space: Space) {
        guard let sourceIndex = space.tabs.firstIndex(where: { $0.id == id }),
              let move = resolveTabMove(
                  sourceIndex: sourceIndex,
                  toGapIndex: gapIndex,
                  groupIDs: space.tabs.map(\.splitGroupID)
              ) else { return }
        performTabMove(move, in: space)
    }

    /// Moving a split member moves the whole contiguous block; destinations
    /// inside another group snap past it (resolveTabMove, TabInsertion.swift).
    private func performTabMove(_ move: (blockRange: Range<Int>, insertAt: Int), in space: Space) {
        let block = Array(space.tabs[move.blockRange])
        space.tabs.removeSubrange(move.blockRange)
        space.tabs.insert(contentsOf: block, at: move.insertAt)
        let originalBlockStart = move.blockRange.lowerBound
        registerUndo(actionName: "Move Tab") { [weak self] in
            self?.moveTab(from: move.insertAt, to: originalBlockStart, in: space)
        }
        notifyObservers { $0.tabStoreDidReorderTabs(in: space) }
        scheduleSave()
    }

    // MARK: - Split Tab Mutations

    /// The split group containing `tabID`, if any — normal-tab groups, or a
    /// pinned split when `tabID` backs a grouped pinned entry (§12). For a
    /// pinned split the members are the group's LIVE tabs in visual order; a
    /// dormant partner is absent until selection wakes it, so hosting sees a
    /// single pane until then.
    func splitGroup(containing tabID: UUID, in space: Space) -> (groupID: UUID, members: [BrowserTab])? {
        if let tab = space.tabs.first(where: { $0.id == tabID }),
           let groupID = tab.splitGroupID {
            return (groupID, space.tabs.filter { $0.splitGroupID == groupID })
        }
        if let entry = space.pinnedEntries.first(where: { $0.tab?.id == tabID }),
           let groupID = entry.splitGroupID {
            return (groupID, pinnedSplitEntries(groupID: groupID, in: space).compactMap(\.tab))
        }
        return nil
    }

    /// The pinned split's entries in visual order (left pane first).
    func pinnedSplitEntries(groupID: UUID, in space: Space) -> [PinnedEntry] {
        space.pinnedEntries.filter { $0.splitGroupID == groupID }.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// The left pane's stored divider fraction for the group containing `tabID`,
    /// wherever the group lives (tab members or pinned entries).
    func splitFraction(containing tabID: UUID, in space: Space) -> Double? {
        if let tab = space.tabs.first(where: { $0.id == tabID }), tab.splitGroupID != nil {
            return tab.splitFraction
        }
        if let entry = space.pinnedEntries.first(where: { $0.tab?.id == tabID }),
           let groupID = entry.splitGroupID {
            return pinnedSplitEntries(groupID: groupID, in: space).first?.splitFraction
        }
        return nil
    }

    /// Clears group membership when a group has fewer than two members left.
    private func dissolveUndersizedSplitGroup(_ groupID: UUID?, in space: Space) {
        guard let groupID else { return }
        let members = space.tabs.filter { $0.splitGroupID == groupID }
        guard members.count < 2 else { return }
        for member in members {
            member.splitGroupID = nil
            member.splitFraction = nil
        }
    }

    /// A tab exits its split group: clears its membership and dissolves the
    /// group its departure leaves undersized. Every exit path (close, pin,
    /// detach, drag-out) must run through here.
    private func leaveSplitGroup(_ tab: BrowserTab, in space: Space) {
        guard let groupID = tab.splitGroupID else { return }
        tab.splitGroupID = nil
        tab.splitFraction = nil
        dissolveUndersizedSplitGroup(groupID, in: space)
    }

    /// Forms a split from two existing ungrouped normal tabs: `draggedTabID`
    /// moves adjacent to `targetTabID` (left edge → before, right → after) and
    /// both join a fresh group. One split per tab: grouped participants reject.
    func createSplit(draggedTabID: UUID, targetTabID: UUID, edge: SplitEdge,
                     fraction: Double = 0.5, in space: Space) {
        guard draggedTabID != targetTabID,
              let sourceIndex = space.tabs.firstIndex(where: { $0.id == draggedTabID }),
              let target = space.tabs.first(where: { $0.id == targetTabID }),
              space.tabs[sourceIndex].splitGroupID == nil,
              target.splitGroupID == nil else { return }

        let dragged = space.tabs.remove(at: sourceIndex)
        guard let targetIndex = space.tabs.firstIndex(where: { $0.id == targetTabID }) else {
            space.tabs.insert(dragged, at: sourceIndex)
            return
        }
        let insertAt = edge == .left ? targetIndex : targetIndex + 1
        space.tabs.insert(dragged, at: insertAt)

        let groupID = UUID()
        for member in [dragged, target] {
            member.splitGroupID = groupID
            member.splitFraction = fraction
        }

        registerUndo(actionName: "Split Tabs") { [weak self] in
            guard let self,
                  let currentIndex = space.tabs.firstIndex(where: { $0.id == draggedTabID }) else { return }
            // removeTabFromSplit takes a PRE-removal gap: when the dragged tab now
            // sits before its old position, the gap that restores it shifts by one.
            let gap = currentIndex < sourceIndex ? sourceIndex + 1 : sourceIndex
            self.removeTabFromSplit(tabID: draggedTabID, toGapIndex: gap, in: space)
        }
        notifyObservers { $0.tabStoreDidReorderTabs(in: space) }
        scheduleSave()
    }

    /// Option-click path: opens `url` as a new right pane split with `tabID`.
    /// Returns nil (caller falls back) if `tabID` is not an ungrouped normal tab.
    @discardableResult
    func addTabInSplit(with tabID: UUID, url: URL, in space: Space) -> BrowserTab? {
        guard let anchorIndex = space.tabs.firstIndex(where: { $0.id == tabID }),
              space.tabs[anchorIndex].splitGroupID == nil else { return nil }

        let anchor = space.tabs[anchorIndex]
        let tab = BrowserTab(configuration: space.makeWebViewConfiguration())
        tab.spaceID = space.id
        tab.parentID = tabID
        let insertAt = anchorIndex + 1
        space.tabs.insert(tab, at: insertAt)
        subscribeToTab(tab, spaceID: space.id)

        let groupID = UUID()
        for member in [anchor, tab] {
            member.splitGroupID = groupID
            member.splitFraction = 0.5
        }

        // Undo is a non-archiving removal: the pane never existed as a lone tab,
        // so it must not land in the Cmd+Shift+T closed-tab stack the way
        // closeTab's undo path would put it there.
        registerUndo(actionName: "Open in Split") { [weak self] in
            guard let self,
                  let index = space.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
            self.tabSubscriptions.removeValue(forKey: tab.id)
            let removed = space.tabs.remove(at: index)
            removed.teardown()
            self.leaveSplitGroup(removed, in: space)
            self.notifyObservers { $0.tabStoreDidRemoveTab(removed, at: index, in: space) }
            self.scheduleSave()
        }
        notifyObservers { $0.tabStoreDidInsertTab(tab, at: insertAt, in: space) }
        scheduleSave()
        tab.load(url)
        return tab
    }

    /// "Separate Tabs": dissolves the group; members stay adjacent as two rows.
    func separateSplit(groupID: UUID, in space: Space) {
        let members = space.tabs.filter { $0.splitGroupID == groupID }
        guard !members.isEmpty else { return }
        let fraction = members.first?.splitFraction
        let memberIDs = members.map(\.id)
        for member in members {
            member.splitGroupID = nil
            member.splitFraction = nil
        }

        registerUndo(actionName: "Separate Tabs") { [weak self] in
            guard let self else { return }
            // Rejoin only if the members are still adjacent ungrouped normal tabs.
            let indices = memberIDs.compactMap { id in space.tabs.firstIndex { $0.id == id } }.sorted()
            guard indices.count == memberIDs.count,
                  indices == Array(indices.first!...(indices.first! + indices.count - 1)),
                  indices.allSatisfy({ space.tabs[$0].splitGroupID == nil }) else { return }
            let rejoinedID = UUID()
            for i in indices {
                space.tabs[i].splitGroupID = rejoinedID
                space.tabs[i].splitFraction = fraction
            }
            self.registerUndo(actionName: "Separate Tabs") { [weak self] in
                self?.separateSplit(groupID: rejoinedID, in: space)
            }
            self.notifyObservers { $0.tabStoreDidReorderTabs(in: space) }
            self.scheduleSave()
        }
        notifyObservers { $0.tabStoreDidReorderTabs(in: space) }
        scheduleSave()
    }

    /// Drag-out path: removes one member from its group (dissolving it) and
    /// moves the tab to `toGapIndex`, a pre-removal insertion gap (0...count) —
    /// the same contract as `moveTab(id:toGapIndex:)`.
    func removeTabFromSplit(tabID: UUID, toGapIndex: Int, in space: Space) {
        guard let sourceIndex = space.tabs.firstIndex(where: { $0.id == tabID }),
              let group = splitGroup(containing: tabID, in: space) else { return }

        let tab = space.tabs[sourceIndex]
        let partnerID = group.members.first { $0.id != tabID }?.id
        let fraction = tab.splitFraction ?? 0.5
        let wasLeftPane = group.members.first?.id == tabID

        leaveSplitGroup(tab, in: space)

        space.tabs.remove(at: sourceIndex)
        let clampedGap = max(0, min(toGapIndex, space.tabs.count + 1))
        let insertAt = snappedToSplitGroupBoundary(
            clampedGap > sourceIndex ? clampedGap - 1 : clampedGap,
            groupIDs: space.tabs.map(\.splitGroupID)
        )
        space.tabs.insert(tab, at: insertAt)

        registerUndo(actionName: "Move Tab Out of Split") { [weak self] in
            guard let self, let partnerID else { return }
            self.createSplit(
                draggedTabID: tabID,
                targetTabID: partnerID,
                edge: wasLeftPane ? .left : .right,
                fraction: fraction,
                in: space
            )
        }
        notifyObservers { $0.tabStoreDidReorderTabs(in: space) }
        scheduleSave()
    }

    /// Closes both members of a split as ONE gesture: single undo restores the
    /// whole split. (Two sequential closeTab calls would need two undos, and
    /// their rejoin logic cannot pair up because each undo mints fresh tab IDs.)
    func closeSplitGroup(groupID: UUID, in space: Space) {
        let members = space.tabs.filter { $0.splitGroupID == groupID }
        guard !members.isEmpty else { return }
        let fraction = members.first?.splitFraction ?? 0.5

        struct MemberSnapshot {
            let index: Int
            let tabID: String
            let title: String
            let url: String?
            let faviconURL: String?
            let interactionState: Data?
            let parentID: UUID?
        }

        var snapshots: [MemberSnapshot] = []
        for member in members {
            guard let index = space.tabs.firstIndex(where: { $0.id == member.id }) else { continue }
            let snapshot = MemberSnapshot(
                index: index,
                tabID: member.id.uuidString,
                title: member.title,
                url: member.url?.absoluteString,
                faviconURL: member.faviconURL?.absoluteString,
                interactionState: member.currentInteractionStateData(),
                parentID: member.parentID
            )
            snapshots.append(snapshot)
            if !space.isIncognito {
                let record = ClosedTabRecord(
                    id: nil,
                    tabID: snapshot.tabID,
                    spaceID: space.id.uuidString,
                    url: snapshot.url,
                    title: snapshot.title,
                    faviconURL: snapshot.faviconURL,
                    interactionState: snapshot.interactionState,
                    sortOrder: index,
                    archivedAt: nil
                )
                appDB.pushClosedTab(record)
                closedTabStack.insert(record, at: 0)
            }
        }
        if closedTabStack.count > 100 {
            closedTabStack = Array(closedTabStack.prefix(100))
        }

        // Remove highest index first so the captured lower index stays valid.
        for snapshot in snapshots.sorted(by: { $0.index > $1.index }) {
            let member = space.tabs.remove(at: snapshot.index)
            tabSubscriptions.removeValue(forKey: member.id)
            member.teardown()
        }

        registerUndo(actionName: "Close Both Splits") { [weak self] in
            guard let self else { return }
            let newGroupID = UUID()
            var restoredFirst: BrowserTab?
            for snapshot in snapshots.sorted(by: { $0.index < $1.index }) {
                let restored = BrowserTab(
                    id: UUID(),
                    title: snapshot.title,
                    archivedInteractionState: snapshot.interactionState,
                    fallbackURL: snapshot.url.flatMap { URL(string: $0) },
                    faviconURL: snapshot.faviconURL.flatMap { URL(string: $0) },
                    configuration: space.makeWebViewConfiguration()
                )
                restored.spaceID = space.id
                restored.parentID = snapshot.parentID
                restored.splitGroupID = newGroupID
                restored.splitFraction = fraction
                let insertAt: Int
                if let first = restoredFirst,
                   let firstIndex = space.tabs.firstIndex(where: { $0.id == first.id }) {
                    insertAt = firstIndex + 1  // right pane lands beside the left
                } else {
                    insertAt = snappedToSplitGroupBoundary(
                        min(snapshot.index, space.tabs.count),
                        groupIDs: space.tabs.map(\.splitGroupID)
                    )
                    restoredFirst = restored
                }
                space.tabs.insert(restored, at: insertAt)
                self.subscribeToTab(restored, spaceID: space.id)
                if let stackIdx = self.closedTabStack.firstIndex(where: { $0.tabID == snapshot.tabID }) {
                    self.closedTabStack.remove(at: stackIdx)
                }
                self.appDB.deleteClosedTab(tabID: snapshot.tabID)
                self.notifyObservers { $0.tabStoreDidInsertTab(restored, at: insertAt, in: space) }
            }
            self.registerUndo(actionName: "Close Both Splits") { [weak self] in
                self?.closeSplitGroup(groupID: newGroupID, in: space)
            }
            if let restoredFirst {
                NotificationCenter.default.post(name: .tabRestoredByUndo, object: nil,
                                                userInfo: ["tabID": restoredFirst.id, "spaceID": space.id])
            }
            self.scheduleSave()
        }

        for snapshot in snapshots {
            notifyObservers { observer in
                if let member = members.first(where: { $0.id.uuidString == snapshot.tabID }) {
                    observer.tabStoreDidRemoveTab(member, at: snapshot.index, in: space)
                }
            }
        }
        scheduleSave()
    }

    /// Divider position persistence — no undo, no structural change. Writes to
    /// whichever side owns the group: tab members, or pinned entries (§12).
    func setSplitFraction(groupID: UUID, fraction: Double, in space: Space) {
        let clamped = max(0.2, min(0.8, fraction))
        let members = space.tabs.filter { $0.splitGroupID == groupID }
        if !members.isEmpty {
            for member in members {
                member.splitFraction = clamped
            }
        } else {
            let entries = pinnedSplitEntries(groupID: groupID, in: space)
            guard !entries.isEmpty else { return }
            for entry in entries {
                entry.splitFraction = clamped
            }
        }
        notifyObservers { $0.tabStoreDidUpdateSplitLayout(in: space) }
        scheduleSave()
    }

    // MARK: - Pinned Split Mutations (§12)

    /// An entry exits its pinned split: clears its membership and dissolves the
    /// group its departure leaves undersized. Every pinned exit path (unpin,
    /// delete, detach-to-favorite) must run through here. `closePinnedTab` does
    /// NOT — a dormant member stays in its group.
    private func dissolvePinnedSplit(around entryID: UUID, groupID: UUID?, in space: Space) {
        guard let groupID else { return }
        for e in space.pinnedEntries where e.splitGroupID == groupID || e.id == entryID {
            e.splitGroupID = nil
            e.splitFraction = nil
        }
    }

    /// Pins both members of a normal-tab split as two adjacent entries that KEEP
    /// the group — a pinned split. Appended at the end of the pinned section;
    /// drops anchor it afterwards via `movePinnedTabToFolder` (block move).
    func pinSplitGroup(groupID: UUID, in space: Space) {
        let members = space.tabs.filter { $0.splitGroupID == groupID }
        guard members.count == 2,
              let firstIndex = space.tabs.firstIndex(where: { $0.id == members[0].id }) else { return }
        let fraction = members[0].splitFraction

        space.tabs.removeAll { $0.splitGroupID == groupID }
        var order = max(space.pinnedEntries.map(\.sortOrder).max() ?? -1,
                        space.pinnedFolders.map(\.sortOrder).max() ?? -1)
        for tab in members {
            tab.splitGroupID = nil
            tab.splitFraction = nil
            order += 1
            let entry = PinnedEntry(
                id: tab.id,
                pinnedURL: tab.url ?? URL(string: "about:blank")!,
                pinnedTitle: tab.title,
                faviconURL: tab.faviconURL,
                sortOrder: order,
                tab: tab
            )
            entry.splitGroupID = groupID
            entry.splitFraction = fraction
            space.pinnedEntries.append(entry)
        }

        registerUndo(actionName: "Pin Split") { [weak self] in
            self?.unpinSplitGroup(groupID: groupID, toGapIndex: firstIndex, in: space)
        }
        notifyObservers { $0.tabStoreDidUpdatePinnedFolders(in: space) }
        scheduleSave()
    }

    /// Unpins a pinned split back into the tab list as a normal split: both
    /// entries leave the pinned section and their tabs land adjacent at the
    /// (snapped) gap with the group restored. A dormant member materializes a
    /// tab exactly like `unpinTab`.
    func unpinSplitGroup(groupID: UUID, toGapIndex: Int? = nil, in space: Space) {
        let entries = pinnedSplitEntries(groupID: groupID, in: space)
        guard entries.count == 2 else { return }
        let fraction = entries.first?.splitFraction ?? 0.5
        let savedFolderID = entries[0].folderID
        // The sibling that follows the pair at its level: the undo re-places
        // the block positionally. Restoring raw sortOrders instead can collide
        // with items pinned after the unpin (their orders come from a global
        // max), interleave the pair, and the sanitizer would then dissolve the
        // very group the undo is restoring.
        let pairMaxOrder = entries.map(\.sortOrder).max() ?? Int.min
        let savedAnchorID = pinnedLevelSiblings(folderID: savedFolderID,
                                                excluding: Set(entries.map(\.id)), in: space)
            .first { $0.sortOrder > pairMaxOrder }?.id

        var tabs: [BrowserTab] = []
        for entry in entries {
            space.pinnedEntries.removeAll { $0.id == entry.id }
            entry.splitGroupID = nil
            entry.splitFraction = nil
            tabs.append(entry.tab ?? materializeDormantEntry(entry, in: space))
        }

        let insertAt = snappedToSplitGroupBoundary(
            min(toGapIndex ?? 0, space.tabs.count),
            groupIDs: space.tabs.map(\.splitGroupID)
        )
        space.tabs.insert(contentsOf: tabs, at: insertAt)
        for tab in tabs {
            tab.splitGroupID = groupID
            tab.splitFraction = fraction
        }

        registerUndo(actionName: "Unpin Split") { [weak self] in
            guard let self else { return }
            self.pinSplitGroup(groupID: groupID, in: space)
            // Restore the original pinned placement (pinSplitGroup appends):
            // positional, so items pinned since the unpin can't collide.
            let restored = self.pinnedSplitEntries(groupID: groupID, in: space)
            guard restored.count == 2 else { return }
            self.placePinnedBlock(restored, folderID: savedFolderID, beforeItemID: savedAnchorID, in: space)
            sanitizePinnedSplitGroups(entries: space.pinnedEntries, folders: space.pinnedFolders)
            self.notifyObservers { $0.tabStoreDidUpdatePinnedFolders(in: space) }
            self.scheduleSave()
        }
        notifyObservers { $0.tabStoreDidUpdatePinnedFolders(in: space) }
        scheduleSave()
    }

    /// "Separate Tabs" on a pinned split: dissolves the group; the entries stay
    /// adjacent as two pinned rows.
    func separatePinnedSplit(groupID: UUID, in space: Space) {
        let entries = pinnedSplitEntries(groupID: groupID, in: space)
        guard !entries.isEmpty else { return }
        let fraction = entries.first?.splitFraction
        let entryIDs = entries.map(\.id)
        for entry in entries {
            entry.splitGroupID = nil
            entry.splitFraction = nil
        }

        registerUndo(actionName: "Separate Tabs") { [weak self] in
            guard let self else { return }
            let members = entryIDs.compactMap { id in space.pinnedEntries.first { $0.id == id } }
            guard members.count == entryIDs.count,
                  members.allSatisfy({ $0.splitGroupID == nil }) else { return }
            let rejoinedID = UUID()
            for member in members {
                member.splitGroupID = rejoinedID
                member.splitFraction = fraction
            }
            // Rejoin only if they're still a valid group (same folder, adjacent).
            sanitizePinnedSplitGroups(entries: space.pinnedEntries, folders: space.pinnedFolders)
            self.registerUndo(actionName: "Separate Tabs") { [weak self] in
                self?.separatePinnedSplit(groupID: rejoinedID, in: space)
            }
            self.notifyObservers { $0.tabStoreDidUpdatePinnedFolders(in: space) }
            self.scheduleSave()
        }
        notifyObservers { $0.tabStoreDidUpdatePinnedFolders(in: space) }
        scheduleSave()
    }

    /// Member-segment drag to a pinned gap: the member breaks out of its pinned
    /// split (dissolving it) into its own pinned row at the anchor. One
    /// mutation, one undo — the pinned analog of `removeTabFromSplit`.
    func removePinnedEntryFromSplit(entryID: UUID, folderID: UUID?, beforeItemID: UUID?, in space: Space) {
        guard let entry = space.pinnedEntries.first(where: { $0.id == entryID }),
              let groupID = entry.splitGroupID else { return }
        let snapshot = capturePinnedOrder(in: space)
        dissolvePinnedSplit(around: entryID, groupID: groupID, in: space)
        placePinnedBlock([entry], folderID: folderID, beforeItemID: beforeItemID, in: space)
        registerUndo(actionName: "Move Tab Out of Split") { [weak self] in
            guard let self else { return }
            self.restorePinnedOrder(snapshot, in: space)
            self.registerUndo(actionName: "Move Tab Out of Split") { [weak self] in
                self?.removePinnedEntryFromSplit(entryID: entryID, folderID: folderID, beforeItemID: beforeItemID, in: space)
            }
            self.notifyObservers { $0.tabStoreDidUpdatePinnedFolders(in: space) }
            self.scheduleSave()
        }
        notifyObservers { $0.tabStoreDidUpdatePinnedFolders(in: space) }
        scheduleSave()
    }

    /// Full pinned-section order/grouping snapshot for undo.
    private struct PinnedOrderSnapshot {
        let entries: [(id: UUID, folderID: UUID?, sortOrder: Int, splitGroupID: UUID?, splitFraction: Double?)]
        let folders: [(id: UUID, parentFolderID: UUID?, sortOrder: Int)]
    }

    private func capturePinnedOrder(in space: Space) -> PinnedOrderSnapshot {
        PinnedOrderSnapshot(
            entries: space.pinnedEntries.map { ($0.id, $0.folderID, $0.sortOrder, $0.splitGroupID, $0.splitFraction) },
            folders: space.pinnedFolders.map { ($0.id, $0.parentFolderID, $0.sortOrder) }
        )
    }

    private func restorePinnedOrder(_ snapshot: PinnedOrderSnapshot, in space: Space) {
        for saved in snapshot.entries {
            if let e = space.pinnedEntries.first(where: { $0.id == saved.id }) {
                e.folderID = saved.folderID
                e.sortOrder = saved.sortOrder
                e.splitGroupID = saved.splitGroupID
                e.splitFraction = saved.splitFraction
            }
        }
        for saved in snapshot.folders {
            if let f = space.pinnedFolders.first(where: { $0.id == saved.id }) {
                f.parentFolderID = saved.parentFolderID
                f.sortOrder = saved.sortOrder
            }
        }
        // Entries removed since the snapshot can leave a restored group
        // undersized — never trust a snapshot over the invariant.
        sanitizePinnedSplitGroups(entries: space.pinnedEntries, folders: space.pinnedFolders)
    }

    /// Resolves a drop anchor so nothing can land inside a pinned split: an
    /// anchor naming a non-first member of a group retargets to the group's
    /// first member. `excluded` (the moved block) is invisible to the scan.
    private func snappedPinnedAnchor(_ beforeItemID: UUID?, excluding excluded: Set<UUID> = [], in space: Space) -> UUID? {
        guard let beforeItemID,
              let target = space.pinnedEntries.first(where: { $0.id == beforeItemID }),
              let groupID = target.splitGroupID else { return beforeItemID }
        let group = pinnedSplitEntries(groupID: groupID, in: space).filter { !excluded.contains($0.id) }
        return group.first?.id ?? beforeItemID
    }

    /// A sibling (entry or folder) of one pinned level, in visual order.
    private struct PinnedSiblingItem {
        let id: UUID
        let sortOrder: Int
        enum Kind { case entry(PinnedEntry), folder(PinnedFolder) }
        let kind: Kind
    }

    /// The sorted siblings of one pinned level, minus `excluded` ids.
    private func pinnedLevelSiblings(folderID: UUID?, excluding excluded: Set<UUID> = [], in space: Space) -> [PinnedSiblingItem] {
        var siblings: [PinnedSiblingItem] = []
        for e in space.pinnedEntries where e.folderID == folderID && !excluded.contains(e.id) {
            siblings.append(PinnedSiblingItem(id: e.id, sortOrder: e.sortOrder, kind: .entry(e)))
        }
        for f in space.pinnedFolders where f.parentFolderID == folderID && !excluded.contains(f.id) {
            siblings.append(PinnedSiblingItem(id: f.id, sortOrder: f.sortOrder, kind: .folder(f)))
        }
        return siblings.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Renumbers a level's siblings 0..n-1 in the given order.
    private func renumberPinnedLevel(_ siblings: [PinnedSiblingItem]) {
        for (i, sibling) in siblings.enumerated() {
            switch sibling.kind {
            case .entry(let e): e.sortOrder = i
            case .folder(let f): f.sortOrder = i
            }
        }
    }

    /// Moves `block` (a lone entry or a pinned split's pair, in visual order)
    /// to `folderID`, anchored before `beforeItemID` (nil → end of level), and
    /// renumbers the level's siblings.
    private func placePinnedBlock(_ block: [PinnedEntry], folderID: UUID?, beforeItemID: UUID?, in space: Space) {
        let blockIDs = Set(block.map(\.id))
        for entry in block {
            entry.folderID = folderID
        }
        var siblings = pinnedLevelSiblings(folderID: folderID, excluding: blockIDs, in: space)
        let anchor = snappedPinnedAnchor(beforeItemID, excluding: blockIDs, in: space)
        let insertionPoint = anchor.flatMap { a in siblings.firstIndex { $0.id == a } } ?? siblings.count
        siblings.insert(contentsOf: block.map { PinnedSiblingItem(id: $0.id, sortOrder: 0, kind: .entry($0)) },
                        at: insertionPoint)
        renumberPinnedLevel(siblings)
    }

    /// Folder analog of `placePinnedBlock`: reparents `folder` to
    /// `parentFolderID`, anchored before `beforeItemID`, renumbering the level.
    private func placePinnedFolder(_ folder: PinnedFolder, parentFolderID: UUID?, beforeItemID: UUID?, in space: Space) {
        folder.parentFolderID = parentFolderID
        var siblings = pinnedLevelSiblings(folderID: parentFolderID, excluding: [folder.id], in: space)
        // Snap anchors out of pinned split interiors — a folder must not land
        // between a group's members.
        let anchor = snappedPinnedAnchor(beforeItemID, in: space)
        let insertionPoint = anchor.flatMap { a in siblings.firstIndex { $0.id == a } } ?? siblings.count
        siblings.insert(PinnedSiblingItem(id: folder.id, sortOrder: 0, kind: .folder(folder)), at: insertionPoint)
        renumberPinnedLevel(siblings)
    }

    // MARK: - Pinned Tab Mutations

    /// Materializes a dormant pinned entry into a live, subscribed tab loading
    /// the pinned URL. The caller decides the entry's fate: keep it live
    /// (`entry.tab = tab`) or remove it (the unpin paths).
    private func materializeDormantEntry(_ entry: PinnedEntry, in space: Space) -> BrowserTab {
        let tab = BrowserTab(
            id: UUID(),
            title: entry.pinnedTitle,
            archivedInteractionState: nil,
            fallbackURL: entry.pinnedURL,
            faviconURL: entry.faviconURL,
            configuration: space.makeWebViewConfiguration()
        )
        tab.spaceID = space.id
        subscribeToTab(tab, spaceID: space.id)
        return tab
    }

    /// What an exiting member's undo needs to rejoin its pinned split.
    private struct PinnedSplitMembership {
        let groupID: UUID
        let fraction: Double?
        let partnerEntryID: UUID
    }

    /// Captures `entry`'s pinned-split membership for an exit path's undo.
    /// Safe to call before or after the entry leaves `pinnedEntries`.
    private func capturePinnedSplitMembership(of entry: PinnedEntry, in space: Space) -> PinnedSplitMembership? {
        guard let groupID = entry.splitGroupID,
              let partner = space.pinnedEntries.first(where: { $0.splitGroupID == groupID && $0.id != entry.id })
        else { return nil }
        return PinnedSplitMembership(groupID: groupID, fraction: entry.splitFraction, partnerEntryID: partner.id)
    }

    /// Undo-time rejoin: restores the group on `entry` and its partner if the
    /// partner is still an ungrouped sibling — the sanitizer clears an invalid
    /// rejoin (wrong folder, non-adjacent).
    private func rejoinPinnedSplit(_ entry: PinnedEntry, membership: PinnedSplitMembership?, in space: Space) {
        guard let membership,
              let partner = space.pinnedEntries.first(where: { $0.id == membership.partnerEntryID }),
              partner.splitGroupID == nil else { return }
        entry.splitGroupID = membership.groupID
        entry.splitFraction = membership.fraction
        partner.splitGroupID = membership.groupID
        partner.splitFraction = membership.fraction
        sanitizePinnedSplitGroups(entries: space.pinnedEntries, folders: space.pinnedFolders)
    }

    func pinTab(id: UUID, in space: Space, at destinationIndex: Int? = nil) {
        guard let index = space.tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = space.tabs.remove(at: index)
        // Pinned tabs can't be split members — leaving the group is implicit.
        leaveSplitGroup(tab, in: space)
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
        // A lone member leaving dissolves its pinned split (whole-group unpin
        // goes through unpinSplitGroup instead). Captured for undo rejoin.
        let membership = capturePinnedSplitMembership(of: entry, in: space)
        entry.splitGroupID = nil
        entry.splitFraction = nil
        dissolvePinnedSplit(around: id, groupID: membership?.groupID, in: space)
        let tab = entry.tab ?? materializeDormantEntry(entry, in: space)
        let insertAt = snappedToSplitGroupBoundary(
            min(destinationIndex ?? 0, space.tabs.count),
            groupIDs: space.tabs.map(\.splitGroupID)
        )
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
            self.rejoinPinnedSplit(reEntry, membership: membership, in: space)
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
        // Deleting a member dissolves its pinned split (the partner entry stays).
        let membership = capturePinnedSplitMembership(of: entry, in: space)

        if let tab = entry.tab {
            tabSubscriptions.removeValue(forKey: tab.id)
            tab.teardown()
        }
        space.pinnedEntries.remove(at: index)
        dissolvePinnedSplit(around: id, groupID: membership?.groupID, in: space)

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
            self.rejoinPinnedSplit(restored, membership: membership, in: space)
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
        entry.tab = materializeDormantEntry(entry, in: space)
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

        // Children take the deleted folder's place in the parent level, in
        // their existing order, and the level renumbers. Reparenting them with
        // their per-level sortOrders intact would collide with the parent
        // level's numbering — a tie interleaving into a pinned split pair
        // renders the pair broken while the group survives in the model.
        let children = pinnedLevelSiblings(folderID: id, in: space)
        var parentLevel = pinnedLevelSiblings(folderID: parentID, in: space)
        let folderPosition = parentLevel.firstIndex { $0.id == id } ?? parentLevel.count
        parentLevel.removeAll { $0.id == id }
        parentLevel.insert(contentsOf: children, at: min(folderPosition, parentLevel.count))

        // Reparent direct children (entries and folders) to the deleted folder's parent
        for entry in space.pinnedEntries where entry.folderID == id {
            entry.folderID = parentID
        }
        for child in space.pinnedFolders where child.parentFolderID == id {
            child.parentFolderID = parentID
        }
        renumberPinnedLevel(parentLevel)
        // A folder can't sit inside a pair, so the block insert keeps existing
        // groups intact — sanitize anyway, matching every other pinned mutation.
        sanitizePinnedSplitGroups(entries: space.pinnedEntries, folders: space.pinnedFolders)

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
            // The restored folder's saved sortOrder lands in a level that was
            // renumbered by the delete — a tie could sort it into a split pair.
            sanitizePinnedSplitGroups(entries: space.pinnedEntries, folders: space.pinnedFolders)
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
        // A grouped entry moves as its whole pair, in visual order — the pinned
        // analog of moveTab's block move. Member-level moves go through
        // removePinnedEntryFromSplit instead.
        let block: [PinnedEntry]
        if let groupID = entry.splitGroupID {
            block = pinnedSplitEntries(groupID: groupID, in: space)
        } else {
            block = [entry]
        }

        let snapshot = capturePinnedOrder(in: space)
        placePinnedBlock(block, folderID: folderID, beforeItemID: beforeItemID, in: space)

        registerUndo(actionName: "Move Tab") { [weak self] in
            guard let self else { return }
            self.restorePinnedOrder(snapshot, in: space)
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
        // Reject moves that would create a parent cycle (folder into itself or a
        // descendant) — a cycle makes flattenPinnedTree recurse forever.
        var ancestorID = parentFolderID
        while let currentID = ancestorID {
            if currentID == folderID { return }
            ancestorID = space.pinnedFolders.first(where: { $0.id == currentID })?.parentFolderID
        }
        let snapshot = capturePinnedOrder(in: space)
        placePinnedFolder(folder, parentFolderID: parentFolderID, beforeItemID: beforeItemID, in: space)

        registerUndo(actionName: "Move Folder") { [weak self] in
            guard let self else { return }
            self.restorePinnedOrder(snapshot, in: space)
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

        let insertionIndex = snappedToSplitGroupBoundary(
            min(record.sortOrder, space.tabs.count),
            groupIDs: space.tabs.map(\.splitGroupID)
        )
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

            func isStale(_ tab: BrowserTab) -> Bool {
                guard !pinnedTabIDs.contains(tab.id), !tab.isPlayingAudio,
                      let lastDeselected = tab.lastDeselectedAt else { return false }
                return lastDeselected < cutoff
            }

            for tab in space.tabs {
                guard !tab.isSleeping, isStale(tab) else { continue }
                // A split renders both members at once — never sleep one while
                // its partner is fresh, or a visible pane goes blank.
                if let groupID = tab.splitGroupID {
                    let partners = space.tabs.filter { $0.splitGroupID == groupID && $0.id != tab.id }
                    guard partners.allSatisfy({ $0.isSleeping || isStale($0) }) else { continue }
                }
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

            func isStale(_ tab: BrowserTab) -> Bool {
                guard let lastDeselected = tab.lastDeselectedAt else { return false }
                return lastDeselected < cutoff
            }

            let staleTabIDs = space.tabs.compactMap { tab -> UUID? in
                guard isStale(tab) else { return nil }
                // Archive a split member only when the whole group is stale —
                // a split is one visual unit and half of it may be on screen.
                if let groupID = tab.splitGroupID {
                    let partners = space.tabs.filter { $0.splitGroupID == groupID && $0.id != tab.id }
                    guard partners.allSatisfy(isStale) else { return nil }
                }
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
