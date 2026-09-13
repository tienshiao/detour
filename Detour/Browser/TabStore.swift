import Foundation
import AppKit
import Combine
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "profiles")

extension Notification.Name {
    static let tabRestoredByUndo = Notification.Name("tabRestoredByUndo")
    /// Posted after a space's tabs were slept because the configuration their web
    /// views were built from is no longer the right one, so each must be rebuilt
    /// through the display path. Two callers: a space's profile changing
    /// (`TabStore.updateSpace`), and an extension context reloading under the
    /// pages it serves (`Profile.retargetExtensionPages`). Windows showing the
    /// space re-select their own displayed tab (userInfo: "spaceID").
    static let spaceTabsNeedRehost = Notification.Name("spaceTabsNeedRehost")
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

    /// A profile was created and added to `profiles` mid-session (`addProfile`,
    /// or the built-in Default/Private profile created on demand). Not sent for
    /// the saved profiles `restoreSession` loads.
    func tabStoreDidAddProfile(_ profile: Profile)
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
    func tabStoreDidAddProfile(_ profile: Profile) {}
}

// MARK: - Space

class Space {
    let id: UUID
    var name: String
    var emoji: String
    var colorHex: String
    /// Entering either list makes a tab enumerable by the window, which is when
    /// the extension contexts are told (TASK-52, see `ExtensionTabLifecycle`).
    var tabs: [BrowserTab] = [] {
        didSet { ExtensionTabLifecycle.didPlace(listed: tabs) }
    }
    var pinnedEntries: [PinnedEntry] = [] {
        didSet { ExtensionTabLifecycle.didPlace(listed: pinnedTabs) }
    }
    var pinnedFolders: [PinnedFolder] = []
    var selectedTabID: UUID?
    var profileID: UUID
    var profile: Profile?

    var isIncognito: Bool { profile?.isIncognito ?? false }

    var pinnedTabs: [BrowserTab] { pinnedEntries.compactMap(\.tab) }

    /// The tab with `id` a window on this space can display, resolved in the
    /// window's own order: a pinned entry's backing tab, then the profile's
    /// favourite backing tab, then a normal tab. Nil when no section holds it.
    ///
    /// The one place the "is this a tab of this space" predicate lives: a
    /// favourite's backing tab hangs off the *profile*, outside `tabs` and
    /// `pinnedEntries`, and a copy of the test that forgets that silently drops
    /// a selected favourite (TASK-54).
    func displayableTab(id: UUID) -> BrowserTab? {
        pinnedEntries.first { $0.tab?.id == id }?.tab
            ?? profile?.favorites.first { $0.tab?.id == id }?.tab
            ?? tabs.first { $0.id == id }
    }

    /// The tab a window selects on entering — or returning to — this space:
    /// the saved selection while it still resolves to a displayable tab
    /// (a favourite's backing tab included, TASK-54), else the first live
    /// pinned tab, else the first normal tab. Nil for an empty space, which
    /// the window then shows deselected.
    func tabToSelectOnEntry() -> BrowserTab? {
        selectedTabID.flatMap { displayableTab(id: $0) } ?? pinnedTabs.first ?? tabs.first
    }

    var color: NSColor {
        NSColor(hex: colorHex) ?? .controlAccentColor
    }

    /// The profile whose website data store and extension controller this
    /// space's web views use, or nil when it is missing or was deleted.
    /// Every live space has one: `deleteProfile` refuses a profile a space uses.
    /// A space rebuilt for a profile deleted since (TASK-35) must not bring back
    /// that profile's storage, which `deleteProfile` removes from disk.
    var usableProfile: Profile? {
        guard let profile, !profile.isDeleted else { return nil }
        return profile
    }

    /// Data store is delegated to the profile. A space without a usable profile
    /// (TASK-35) gets a throwaway non-persistent store rather than a crash or a
    /// fresh identifier store for a deleted profile; callers are expected to
    /// have refused such a space before building a web view for it.
    var dataStore: WKWebsiteDataStore {
        guard let profile = usableProfile else {
            log.error("Space \(self.id.uuidString, privacy: .public) has no usable profile (\(self.profileID.uuidString, privacy: .public) is missing or deleted); using a non-persistent data store")
            return .nonPersistent()
        }
        return profile.dataStore
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
        let profile = usableProfile
        if profile?.isPerTabIsolation == true {
            config.websiteDataStore = .nonPersistent()
        } else {
            config.websiteDataStore = dataStore
        }

        // Wire this profile's extension controller so content scripts inject automatically.
        // None for a space without a usable profile: a deleted profile's
        // controller would recreate its extension storage (TASK-35).
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
    /// A space's tabs become enumerable by a window only once the space is here:
    /// session restore and Undo Delete Space fill `space.tabs` while the space is
    /// still detached, so their live tabs were reported before any window could
    /// list them. Re-announce them now (TASK-52, see `ExtensionTabLifecycle`).
    private(set) var spaces: [Space] = [] {
        didSet {
            for space in spaces where !oldValue.contains(where: { $0 === space }) {
                ExtensionTabLifecycle.didList(space)
            }
        }
    }

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

    /// Removes deleted profiles' on-disk WebKit data (TASK-32).
    private let profileDataRemoval: ProfileDataRemoval

    init(appDB: AppDatabase = .shared, historyDB: HistoryDatabase = .shared,
         profileDataRemover: ProfileDataRemoval.Remover = .webKit,
         profileDataRemovalRetryDelays: [TimeInterval] = ProfileDataRemoval.defaultRetryDelays,
         webKitStorageScope: WebKitStorageScope = .current) {
        self.appDB = appDB
        self.historyDB = historyDB
        self.profileDataRemoval = ProfileDataRemoval(
            appDB: appDB, remover: profileDataRemover, retryDelays: profileDataRemovalRetryDelays,
            storageScope: webKitStorageScope)
        profileDataRemoval.inMemoryProfileIDs = { [weak self] in
            Set(self?.profiles.map(\.id) ?? [])
        }
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
        notifyObservers { $0.tabStoreDidAddProfile(profile) }
        return profile
    }

    func updateProfile(_ profile: Profile) {
        appDB.saveProfile(profile.toRecord())
        scheduleSave()
        NotificationCenter.default.post(name: .init("UserAgentDidChange"), object: nil, userInfo: ["profileID": profile.id])
    }

    /// Deletes a profile no space uses, with its rows (TASK-31) and its on-disk
    /// WebKit data (TASK-32). The order matters twice over. The row delete goes
    /// first and nothing is touched unless it succeeded, so a refused or failed
    /// delete leaves the profile whole. Then, because `WKWebsiteDataStore.remove`
    /// fails while anything still uses the store, everything holding the
    /// profile's store or extension controller is torn down and the `Profile` is
    /// dropped, and only then is the removal attempted, on a later main-actor
    /// turn. The pending removal is recorded in the transaction that deletes the
    /// profile row, so a removal that fails (or never runs because the app quits)
    /// is retried at the next launch.
    ///
    /// Returns the removal task, or nil when nothing was deleted.
    @discardableResult
    func deleteProfile(id: UUID) -> Task<ProfileDataRemoval.Outcome, Never>? {
        guard id != Self.incognitoProfileID else { return nil }
        guard profiles.filter({ !$0.isIncognito }).count > 1 else { return nil }
        let hasSpaces = spaces.contains { $0.profileID == id && !$0.isIncognito }
        guard !hasSpaces else { return nil }

        // A space moved off this profile less than a save interval ago still
        // references it in the database, which would refuse the row delete.
        saveNow()

        // Nothing is torn down until the row delete has actually happened: it
        // returns false for a write error or a space row that still references
        // the profile, and a half-deleted profile — gone from memory and flagged
        // deleted, but with its row and its on-disk data kept and no pending
        // removal — is unrecoverable.
        let deleted = appDB.deleteProfile(id: id.uuidString)
        guard deleted else { return nil }

        // Undo actions can bring back what referenced this profile: Delete
        // Space and Edit Space rebuild or re-home a space onto a captured
        // profile id, and others capture spaces, which hold their profile
        // strongly. Profile deletion happens in Settings, outside the browsing
        // undo flow, and UndoManager cannot drop only the actions that
        // reference one profile, so the whole stack goes (TASK-35). This also
        // releases the Profile those closures retain, so its store is no
        // longer in use when the removal below runs.
        undoManager.removeAllActions()

        let profile = self.profile(withID: id)
        if let profile {
            // Favourites are per profile, and a live favourite's backing tab can
            // outlive the space it was opened in (deleteSpace does not touch it),
            // so its web view may still be using this profile's store.
            for favorite in profile.favorites {
                guard let tab = favorite.tab else { continue }
                tabSubscriptions.removeValue(forKey: tab.id)
                tab.teardown()
                favorite.tab = nil
            }
            // Extension contexts: background content, offscreen documents,
            // keep-alive ports, native hosts and relayed WebSockets.
            profile.unloadAllExtensions()
        }

        profile?.isDeleted = true
        profiles.removeAll { $0.id == id }
        scheduleSave()
        return profileDataRemoval.removeDataOfDeletedProfile(id: id, released: profile)
    }

    /// Retries the on-disk data removals of profiles deleted in an earlier run
    /// (TASK-32). Call at launch, before anything creates a profile's data store
    /// or extension controller.
    @discardableResult
    func retryPendingProfileDataRemovals() -> Task<[UUID: ProfileDataRemoval.Outcome], Never> {
        profileDataRemoval.retryPendingRemovals()
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
                tabRecords.append(TabRecord(
                    tab: tab,
                    spaceID: space.id,
                    sortOrder: tabIndex,
                    profile: space.profile,
                    splitGroupID: tab.splitGroupID,
                    splitFraction: tab.splitFraction
                ))
            }

            // Also save backing tabs for live pinned entries (FK from pinnedTab.tabID → tab.id)
            for entry in space.pinnedEntries {
                guard let tab = entry.tab else { continue }
                tabRecords.append(TabRecord(
                    tab: tab,
                    spaceID: space.id,
                    sortOrder: -1,  // Convention for backing tabs
                    profile: space.profile
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
                // Persisted exactly like a pinned backing tab's row: a favourite
                // peeks the same way (TASK-42), and no longer zeroes
                // lastDeselectedAt/parentID (TASK-49 — see the factory).
                let tabRecord = TabRecord(
                    tab: tab,
                    spaceID: hostSpaceID,
                    sortOrder: -2,
                    profile: profile
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
                    splitFraction: entry.splitFraction,
                    extensionID: space.profile?.extensionID(forPageURL: entry.pinnedURL)
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
                    tabID: fav.tab?.id.uuidString,
                    extensionID: profile.extensionID(forPageURL: fav.url)
                )
            }
            appDB.saveFavorites(records, profileID: profile.id.uuidString)
        }
    }

    /// Restores session. Returns (activeSpaceID, selectedTabID) for the window to use.
    func restoreSession() -> (spaceID: UUID, tabID: UUID?)? {
        // Load profiles first — before the session, and whether or not there is
        // one. `loadSession` returns nil whenever the space table is empty (the
        // last persistent space deleted while a Private window is open) and on
        // any read error; a save then writes only the profiles this store holds,
        // and `saveProfiles` sweeps every stored profile missing from that set.
        // A launch that never loaded them must not look like a launch that
        // deleted them (TASK-32/TASK-33): holding them costs nothing when there
        // is no session to restore.
        let profileRecords = appDB.loadProfiles()
        for record in profileRecords {
            if let profile = Profile.from(record: record) {
                profiles.append(profile)
            }
        }

        // Ensure the built-in incognito profile exists
        ensureIncognitoProfile()

        guard let session = appDB.loadSession() else { return nil }

        // Extension pages (TASK-24). A persisted webkit-extension:// URL names an
        // origin that died with the previous launch's context; the extension id
        // saved alongside it is the durable identity (`classifyPersistedExtensionPage`):
        // - not installed (or no saved id): dropped everywhere, so no tab or tile
        //   is ever restored for a page that can never load;
        // - installed but disabled in the profile: pinned entries, favourites and
        //   closed-tab records keep it for a later enable, but a tab open on it
        //   (session or backing tab) is dropped — what a mid-session disable does;
        // - enabled: tabs are restored *sleeping*, without their interaction
        //   state (its back/forward list is all on the dead origin).
        // Every kept page registers its origin as pending on the profile:
        // contexts load asynchronously after this returns, and
        // `Profile.resolvePendingExtensionPages` moves the pages onto them then
        // (or on the enable, for a disabled extension).
        // One availability for the whole restore: it reads the installed set, and
        // each profile's enabled set, once.
        let availability = ExtensionAvailability(appDB: appDB)
        var droppedTabIDs = Set<UUID>()
        func persistedPage(_ urlString: String?, extensionID: String?, in profile: Profile?) -> PersistedExtensionPage {
            classifyCapturedPage(url: urlString.flatMap { URL(string: $0) }, extensionID: extensionID,
                                 in: profile, availability: availability)
        }
        /// Registers the pending origin of a page that is being kept.
        func keep(_ page: PersistedExtensionPage, in profile: Profile?) {
            guard let origin = page.pendingOrigin else { return }
            profile?.registerPendingExtensionOrigin(host: origin.originHost, extensionID: origin.extensionID)
        }
        /// Whether a tab open on `page` can be restored: an ordinary page, or an
        /// enabled extension's page.
        func isRestorableAsTab(_ page: PersistedExtensionPage) -> Bool {
            switch page {
            case .notExtensionPage, .restorable: return true
            case .disabled, .unavailable: return false
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

            // Identify backing tab IDs (referenced by pinned entries)
            let pinnedRecords = appDB.loadPinnedTabs(spaceID: spaceRecord.id)
            let backingTabIDs = Set(pinnedRecords.compactMap(\.tabID))

            // Load normal tabs (exclude pinned backing tabs and favorite backing tabs)
            for tabRecord in tabRecords {
                guard let tabID = UUID(uuidString: tabRecord.id) else { continue }
                guard !backingTabIDs.contains(tabRecord.id) else { continue }
                guard tabRecord.sortOrder >= 0 else { continue }
                let page = persistedPage(tabRecord.url, extensionID: tabRecord.extensionID, in: space.profile)
                guard isRestorableAsTab(page) else {
                    droppedTabIDs.insert(tabID)
                    continue
                }
                keep(page, in: space.profile)
                let isExtensionPage = page != .notExtensionPage
                let isSelected = space.selectedTabID == tabID
                let tab: BrowserTab
                if isExtensionPage {
                    tab = BrowserTab(
                        id: tabID,
                        title: tabRecord.title,
                        url: tabRecord.url.flatMap { URL(string: $0) },
                        faviconURL: tabRecord.faviconURL.flatMap { URL(string: $0) },
                        cachedInteractionState: nil,
                        spaceID: spaceID
                    )
                    tab.lastDeselectedAt = isSelected
                        ? nil
                        : tabRecord.lastDeselectedAt.map { Date(timeIntervalSince1970: $0) } ?? Date()
                } else if isSelected {
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
                tab.applyPersistedPeekState(from: tabRecord)
                tab.splitGroupID = tabRecord.splitGroupID.flatMap { UUID(uuidString: $0) }
                tab.splitFraction = tabRecord.splitFraction
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
                // An entry whose home page belongs to an extension that is not
                // installed is dropped with its backing tab (a tile that can only
                // open a dead page). A split partner left alone is dissolved by
                // `sanitizePinnedSplitGroups` below. A disabled extension's entry
                // is kept, dormant, for a later enable.
                let pinnedPage = persistedPage(pinnedRecord.pinnedURL, extensionID: pinnedRecord.extensionID, in: space.profile)
                if pinnedPage == .unavailable {
                    if let backingTabID = pinnedRecord.tabID.flatMap({ UUID(uuidString: $0) }) {
                        droppedTabIDs.insert(backingTabID)
                    }
                    continue
                }
                keep(pinnedPage, in: space.profile)
                let pinnedURL = URL(string: pinnedRecord.pinnedURL) ?? URL(string: "about:blank")!

                var backingTab: BrowserTab? = nil
                if let backingTabIDStr = pinnedRecord.tabID,
                   let backingTabID = UUID(uuidString: backingTabIDStr),
                   let tabRecord = tabRecordsByID[backingTabIDStr] {
                    // The backing tab falls back to the entry's URL, so it is that
                    // page (already classified) when the record has none. One on a
                    // page of an extension that is gone or disabled is dropped,
                    // leaving the entry dormant — what closing the tab by hand does.
                    let backingPage = tabRecord.url == nil
                        ? pinnedPage
                        : persistedPage(tabRecord.url, extensionID: tabRecord.extensionID, in: space.profile)
                    let isSelected = space.selectedTabID == backingTabID
                    if !isRestorableAsTab(backingPage) {
                        droppedTabIDs.insert(backingTabID)
                    } else if backingPage != .notExtensionPage {
                        keep(backingPage, in: space.profile)
                        backingTab = BrowserTab(
                            id: backingTabID,
                            title: tabRecord.title,
                            url: tabRecord.url.flatMap { URL(string: $0) } ?? pinnedURL,
                            faviconURL: tabRecord.faviconURL.flatMap { URL(string: $0) },
                            cachedInteractionState: nil,
                            spaceID: spaceID
                        )
                    } else if isSelected {
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
                    backingTab?.applyPersistedPeekState(from: tabRecord)
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
                // As for pinned entries: a favourite of an uninstalled extension's
                // page is dropped with its backing tab, a disabled one's is kept;
                // a backing tab on either is dropped, leaving the favourite dormant.
                let favoritePage = persistedPage(record.url, extensionID: record.extensionID, in: profile)
                if favoritePage == .unavailable {
                    if let tabID = record.tabID.flatMap({ UUID(uuidString: $0) }) {
                        droppedTabIDs.insert(tabID)
                    }
                    continue
                }
                keep(favoritePage, in: profile)

                var backingTab: BrowserTab? = nil
                if let tabIDStr = record.tabID,
                   let tabID = UUID(uuidString: tabIDStr),
                   let (tabRecord, _) = allTabRecordsByID[tabIDStr],
                   let hostSpace {
                    let backingPage = persistedPage(tabRecord.url, extensionID: tabRecord.extensionID, in: profile)
                    if !isRestorableAsTab(backingPage) {
                        droppedTabIDs.insert(tabID)
                    } else {
                        keep(backingPage, in: profile)
                        backingTab = BrowserTab(
                            id: tabID,
                            title: tabRecord.title,
                            url: tabRecord.url.flatMap { URL(string: $0) },
                            faviconURL: tabRecord.faviconURL.flatMap { URL(string: $0) },
                            cachedInteractionState: backingPage == .notExtensionPage ? tabRecord.interactionState : nil,
                            spaceID: hostSpace.id
                        )
                    }
                    backingTab?.spaceID = hostSpace.id
                    backingTab?.applyPersistedPeekState(from: tabRecord)
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
                // No favicon callback is installed here: the favourite publishes
                // `$favicon` and every window's tile subscribes, so a download
                // reaches all of them rather than the last registered closure
                // (TASK-53).
                profile.favorites.append(favorite)
            }
        }

        // A space whose selected tab was dropped above must not keep pointing at it.
        for space in self.spaces {
            guard let selectedID = space.selectedTabID, droppedTabIDs.contains(selectedID) else { continue }
            space.selectedTabID = space.tabs.first?.id
                ?? space.pinnedEntries.first(where: { $0.tab != nil })?.tab?.id
        }

        // Load closed tab stack from DB. A closed extension page is resolved when
        // it is reopened (`reopenClosedTab`), which skips (and keeps) a disabled
        // extension's; one whose extension is not installed can never be reopened
        // and is deleted now.
        self.closedTabStack = appDB.loadClosedTabs().filter { record in
            guard let space = UUID(uuidString: record.spaceID).flatMap({ self.space(withID: $0) }),
                  persistedPage(record.url, extensionID: record.extensionID, in: space.profile) == .unavailable
            else { return true }
            appDB.deleteClosedTab(tabID: record.tabID)
            return false
        }

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
        // The tab was just detached from its section, which reported it closed to
        // the extension contexts. It is still live and still running content
        // scripts; the insert above re-opens it under the favourite — the
        // `favorites` didSet reports it once it is listed (TASK-52).
        notifyObservers { $0.tabStoreDidUpdateFavorites(for: profile) }
        scheduleSave()
    }

    /// Adds a dormant favourite from a dormant tile (a pinned entry dragged to the
    /// favourites bar). Its URL is rehomed like any tile's (TASK-34); a page of an
    /// uninstalled extension is refused — returns false and adds nothing — so the
    /// caller can leave the entry where it is.
    @discardableResult
    func addFavoriteFromEntry(url: URL, title: String, faviconURL: URL?, favicon: NSImage?,
                              profileID: UUID, at index: Int) -> Bool {
        guard let profile = profiles.first(where: { $0.id == profileID }),
              let url = rehomedTileURL(url, page: dormantTilePage(url: url, in: profile), in: profile)
        else { return false }

        let favorite = Favorite(url: url, title: title, faviconURL: faviconURL, sortOrder: 0)
        favorite.favicon = favicon
        let insertAt = min(index, profile.favorites.count)
        profile.favorites.insert(favorite, at: insertAt)
        reindexFavorites(profile)
        notifyObservers { $0.tabStoreDidUpdateFavorites(for: profile) }
        scheduleSave()
        return true
    }

    /// Gives a dormant favourite a live backing tab (clicking the tile).
    ///
    /// A dormant extension page is gated exactly as a move out of the bar is
    /// (TASK-34): a disabled or uninstalled extension's page cannot become a tab,
    /// which would wake blank on a pending or dead origin, so the favourite is
    /// left dormant instead.
    ///
    /// Returns whether the favourite gained a backing tab; a caller acting on a
    /// click shows `dormantTileRefusal(url:in:)` when it did not (TASK-37).
    @discardableResult
    func activateFavorite(id: UUID, profileID: UUID, in space: Space) -> Bool {
        guard let profile = profiles.first(where: { $0.id == profileID }),
              let fav = profile.favorites.first(where: { $0.id == id }),
              fav.tab == nil else { return false }
        let page = dormantTilePage(url: fav.url, in: profile)
        guard dormantTileDropTargets(page).contains(.tabList),
              let url = rehomedTileURL(fav.url, page: page, in: profile) else { return false }

        let tab = makeTab(loading: url, title: fav.title, faviconURL: fav.faviconURL, in: space)
        // A favourite's tab never enters space.tabs, so no insert notification
        // reports it — but its web view is built from the profile's
        // configuration and runs content scripts, which need the tab to be known
        // to the contexts or every runtime.sendMessage fails (TASK-50). The
        // assignment below is its placement, and reports it (TASK-52).
        fav.tab = tab
        subscribeToTab(tab, spaceID: space.id)
        notifyObservers { $0.tabStoreDidUpdateFavorites(for: profile) }
        scheduleSave()
        return true
    }

    /// Removes a favorite outright. A live backing tab goes with it — the tab is
    /// torn down (which also tears down any peek it hosts, see
    /// `BrowserTab.teardown()`), so nothing is left alive off-list.
    func removeFavorite(id: UUID, profileID: UUID) {
        guard let profile = profiles.first(where: { $0.id == profileID }),
              let fav = profile.favorites.first(where: { $0.id == id }) else { return }
        if let tab = fav.tab {
            tabSubscriptions.removeValue(forKey: tab.id)
            tab.teardown()
        }
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

    /// The favourite whose live backing tab is `tab`, with the profile that owns it.
    func favorite(backedBy tab: BrowserTab) -> (profile: Profile, favorite: Favorite)? {
        for profile in profiles {
            if let favorite = profile.favorites.first(where: { $0.tab === tab }) {
                return (profile, favorite)
            }
        }
        return nil
    }

    /// The tab hosting `peek` as its Peek, in any section: a space's normal or
    /// pinned tabs, or a profile's favourites.
    func tab(hostingPeek peek: BrowserTab) -> BrowserTab? {
        for space in spaces {
            if let host = (space.tabs + space.pinnedTabs).first(where: { $0.peekTab === peek }) { return host }
        }
        for profile in profiles {
            if let host = profile.favoriteTabs.first(where: { $0.peekTab === peek }) { return host }
        }
        return nil
    }

    /// What a dormant tile's page is now (TASK-34) — a favourite's URL, or a
    /// dormant pinned entry's home page — judged by the extension claiming its
    /// origin in `profile`: the loaded context serving it, or the id registered
    /// for its pending origin (`Profile.extensionID(forPageURL:)`). A tile holds
    /// no extension id in memory and needs none: a context reload rewrites its
    /// URL (`retargetExtensionPages`), and a restore or a disable registers its
    /// origin as pending. Only an uninstall forgets the origin, which leaves no
    /// id and so classifies as `.unavailable`.
    private func dormantTilePage(url: URL, in profile: Profile?,
                                 availability: ExtensionAvailability? = nil) -> PersistedExtensionPage {
        classifyCapturedPage(url: url, extensionID: profile?.extensionID(forPageURL: url), in: profile,
                             availability: availability)
    }

    /// Where a dormant tile on `page` may move (TASK-34). An ordinary page and an
    /// enabled extension's page may go anywhere. A disabled extension's page may
    /// only stay a dormant tile (a pinned entry): as a tab it would sit unloaded
    /// on its pending origin, and the next restore drops open tabs of a disabled
    /// extension. An uninstalled extension's page may go nowhere.
    private func dormantTileDropTargets(_ page: PersistedExtensionPage) -> FavoriteDropTargets {
        switch page {
        case .notExtensionPage, .restorable: return .all
        case .disabled: return .pinned
        case .unavailable: return []
        }
    }

    /// Why a dormant tile on `url` cannot become a tab (TASK-37), for the hint
    /// shown when the user's click or unpin is refused. Nil when it can — an
    /// ordinary page, or an enabled extension's — so a caller may ask
    /// unconditionally after a mutation returned false.
    ///
    /// The same classification the refusal itself uses (`dormantTilePage`):
    /// `.disabled` is an installed extension that is off, `.unavailable` one
    /// that is not installed. A legacy page carries the unknown-id sentinel,
    /// which names no extension and can never be enabled — unavailable, not off.
    func dormantTileRefusal(url: URL, in profile: Profile?) -> DormantTileRefusal? {
        switch dormantTilePage(url: url, in: profile) {
        case .notExtensionPage, .restorable:
            return nil
        case .disabled(let extensionID, _):
            guard extensionID != ExtensionPageURL.unknownExtensionID else {
                return .extensionUnavailable
            }
            // Only a loaded extension has a display name; `displayName(for:)`
            // hands back the raw id otherwise (the classification is DB-based,
            // so it answers before `loadInstalledExtensions` has run).
            let name = ExtensionManager.shared.extension(withID: extensionID)
                .map { _ in ExtensionManager.shared.displayName(for: extensionID) }
            return .extensionDisabled(name: name)
        case .unavailable:
            // Nothing installed can claim the origin — `.unavailable` means the
            // id is absent from the installed set — so there is no name to show.
            return .extensionUnavailable
        }
    }

    /// The sidebar sections favourite `id` may be dragged into now (TASK-34),
    /// for the sidebar's drop validation. A live favourite may go anywhere: its
    /// backing tab moves as it is.
    func favoriteDropTargets(id: UUID, profileID: UUID) -> FavoriteDropTargets {
        guard let profile = profiles.first(where: { $0.id == profileID }),
              let fav = profile.favorites.first(where: { $0.id == id }) else { return [] }
        if fav.tab != nil { return .all }
        // Called from drop validation, per mouse move: read the availability once.
        return dormantTileDropTargets(dormantTilePage(url: fav.url, in: profile,
                                                      availability: ExtensionAvailability(appDB: appDB)))
    }

    /// Moves a favorite back into the tab list, removing it from favorites.
    ///
    /// A live favourite's backing tab moves as it is. A dormant one gets a new tab
    /// from `makeTab(loading:)` — an extension page is created sleeping, so wake
    /// builds it from its context's configuration — on its URL rehomed onto the
    /// extension's live origin (TASK-34). A dormant page of a disabled or
    /// uninstalled extension is refused (`favoriteDropTargets`): nothing moves,
    /// the favourite stays, and this returns false.
    @discardableResult
    func restoreFavoriteAsTab(id: UUID, profileID: UUID, in space: Space, at tabIndex: Int) -> Bool {
        guard let profile = profiles.first(where: { $0.id == profileID }),
              let favIdx = profile.favorites.firstIndex(where: { $0.id == id }) else { return false }
        let fav = profile.favorites[favIdx]

        let tab: BrowserTab
        if let liveTab = fav.tab {
            tab = liveTab
        } else {
            let page = dormantTilePage(url: fav.url, in: profile)
            guard dormantTileDropTargets(page).contains(.tabList),
                  let url = rehomedTileURL(fav.url, page: page, in: profile) else { return false }
            tab = makeTab(loading: url, title: fav.title, faviconURL: fav.faviconURL, in: space)
            subscribeToTab(tab, spaceID: space.id)
        }
        profile.favorites.remove(at: favIdx)
        reindexFavorites(profile)

        let insertAt = snappedToSplitGroupBoundary(
            min(tabIndex, space.tabs.count),
            groupIDs: space.tabs.map(\.splitGroupID)
        )
        space.tabs.insert(tab, at: insertAt)
        notifyObservers { $0.tabStoreDidInsertTab(tab, at: insertAt, in: space) }
        notifyObservers { $0.tabStoreDidUpdateFavorites(for: profile) }
        scheduleSave()
        return true
    }

    /// Moves a favorite back into the pinned section, removing it from favorites.
    ///
    /// A live favourite's backing tab moves as it is. A dormant one becomes a
    /// dormant entry whose home page is the favourite's URL rehomed (TASK-34): an
    /// enabled extension's page onto its live origin, a disabled one's kept with
    /// its origin registered as pending for a later enable. A dormant page of an
    /// uninstalled extension is refused: nothing moves, the favourite stays, and
    /// this returns false.
    @discardableResult
    func restoreFavoriteAsPinned(id: UUID, profileID: UUID, in space: Space, at pinnedIndex: Int) -> Bool {
        guard let profile = profiles.first(where: { $0.id == profileID }),
              let favIdx = profile.favorites.firstIndex(where: { $0.id == id }) else { return false }
        let fav = profile.favorites[favIdx]

        let pinnedURL: URL
        if fav.tab != nil {
            pinnedURL = fav.url
        } else {
            let page = dormantTilePage(url: fav.url, in: profile)
            guard dormantTileDropTargets(page).contains(.pinned),
                  let url = rehomedTileURL(fav.url, page: page, in: profile) else { return false }
            pinnedURL = url
        }
        profile.favorites.remove(at: favIdx)
        reindexFavorites(profile)

        let maxEntryOrder = space.pinnedEntries.map(\.sortOrder).max() ?? -1
        let maxFolderOrder = space.pinnedFolders.map(\.sortOrder).max() ?? -1
        let entry = PinnedEntry(
            id: UUID(),
            pinnedURL: pinnedURL,
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
        return true
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
            let extensionID: String?
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
            let extensionID: String?
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
                isSelected: space.selectedTabID == tab.id,
                extensionID: space.profile?.extensionID(forPageURL: tab.url)
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
                splitFraction: entry.splitFraction,
                extensionID: space.profile?.extensionID(forPageURL: entry.pinnedURL)
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
            // deleteProfile clears the undo stack, so this only guards against
            // an action that outlived it: restoring onto a deleted profile would
            // bring back its removed storage (TASK-35). Nothing is restored and
            // no redo is registered.
            guard self.profile(withID: savedProfileID) != nil else {
                log.error("Undo Delete Space skipped: profile \(savedProfileID.uuidString, privacy: .public) of space \(id.uuidString, privacy: .public) no longer exists")
                return
            }
            let restored = Space(id: id, name: savedName, emoji: savedEmoji, colorHex: savedColorHex, profileID: savedProfileID)
            restored.profile = self.profile(withID: savedProfileID)
            restored.selectedTabID = savedSelectedTabID

            // Rebuild a tab from its snapshot: selected tab live (displays
            // immediately), the rest sleeping — mirroring restoreSession. As there,
            // an extension page (TASK-28) comes back sleeping on its extension's
            // live origin without its interaction state, and one whose extension
            // was disabled or uninstalled since does not come back (nil).
            var droppedTabIDs = Set<UUID>()
            // One availability for the whole rebuild, like a restore.
            let availability = ExtensionAvailability(appDB: self.appDB)
            func rebuild(_ s: TabSnapshot) -> BrowserTab? {
                let page = self.classifyCapturedPage(url: s.url, extensionID: s.extensionID, in: restored,
                                                     availability: availability)
                let tab: BrowserTab
                if page != .notExtensionPage {
                    guard let extensionPageTab = self.restoredTab(
                        id: s.id, url: s.url, title: s.title, faviconURL: s.faviconURL,
                        interactionState: nil, page: page, in: restored
                    ) else {
                        droppedTabIDs.insert(s.id)
                        return nil
                    }
                    tab = extensionPageTab
                    tab.lastDeselectedAt = s.isSelected ? nil : s.lastDeselectedAt ?? Date()
                } else if s.isSelected {
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
                if let tab = rebuild(s) { restored.tabs.append(tab) }
            }
            // A dropped tab's split partner is left a lone tab.
            sanitizeSplitGroups(restored.tabs)
            for f in savedFolders {
                restored.pinnedFolders.append(PinnedFolder(
                    id: f.id, name: f.name, parentFolderID: f.parentFolderID,
                    isCollapsed: f.isCollapsed, sortOrder: f.sortOrder
                ))
            }
            for e in savedEntries {
                // An entry whose home page belongs to an extension uninstalled
                // since is dropped with its backing tab, as restore drops it
                // (TASK-30); a lone split partner is dissolved below.
                guard let pinnedURL = self.rehomedTileURL(e.pinnedURL, extensionID: e.extensionID, in: restored,
                                                         availability: availability) else {
                    if let backingTabID = e.backingTab?.id { droppedTabIDs.insert(backingTabID) }
                    continue
                }
                // A backing tab that is not rebuilt leaves the entry dormant.
                let backing = e.backingTab.flatMap(rebuild)
                let entry = PinnedEntry(
                    id: e.id,
                    pinnedURL: pinnedURL,
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
            // A dropped entry's pinned split partner is left a lone entry.
            sanitizePinnedSplitGroups(entries: restored.pinnedEntries, folders: restored.pinnedFolders)
            if let selectedID = savedSelectedTabID, droppedTabIDs.contains(selectedID) {
                restored.selectedTabID = restored.tabs.first?.id
                    ?? restored.pinnedEntries.first(where: { $0.tab != nil })?.tab?.id
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
        // A space is never moved onto a profile that does not exist (TASK-35).
        guard space.profileID == profileID || profile(withID: profileID) != nil else {
            log.error("Edit Space refused: profile \(profileID.uuidString, privacy: .public) does not exist")
            return
        }
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
            for tab in liveTabs {
                // The tab was reported open to the OLD profile's contexts; sleeping
                // does not close it, and the wake below re-registers it under the new
                // profile — so close it here or the old profile keeps a phantom open
                // tab that can never be closed (TASK-50). A tab that is already
                // asleep is still registered, so the close is not gated on the
                // web view (didClose is a no-op for an unregistered tab).
                ExtensionTabLifecycle.didClose(tab)
                if tab.webView != nil { tab.sleep(force: true) }
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
                name: .spaceTabsNeedRehost, object: nil,
                userInfo: ["spaceID": id]
            )
        }
        registerUndo(actionName: "Edit Space") { [weak self] in
            guard let self else { return }
            // As for Delete Space (TASK-35): never move the space back onto a
            // profile deleted since. The space stays as it is, and no redo is
            // registered.
            guard self.profile(withID: oldProfileID) != nil else {
                log.error("Undo Edit Space skipped: profile \(oldProfileID.uuidString, privacy: .public) of space \(id.uuidString, privacy: .public) no longer exists")
                return
            }
            self.updateSpace(id: id, name: oldName, emoji: oldEmoji, colorHex: oldColorHex, profileID: oldProfileID)
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

    /// The profile a new default space goes on. The built-in Private profile is
    /// never it: `restoreSession` loads (or mints) it before any default one
    /// exists, so `profiles.first` can be Private on a session-less launch.
    @discardableResult
    private func ensureDefaultProfile() -> Profile {
        if let existing = profiles.first(where: { !$0.isIncognito }) { return existing }
        let profile = Profile(name: "Default")
        profiles.append(profile)
        appDB.saveProfile(profile.toRecord())
        notifyObservers { $0.tabStoreDidAddProfile(profile) }
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
        notifyObservers { $0.tabStoreDidAddProfile(profile) }
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

    /// `undoable: false` neither records the tab on the closed-tab stack nor
    /// registers an undo — for a page that could never be reopened (an extension
    /// page whose context is gone: its origin dies with the context, and a
    /// restore would rebuild it from the space configuration, which cannot load
    /// the scheme at all).
    func closeTab(id: UUID, in space: Space, archivedAt: Date? = nil, undoable: Bool = true) {
        guard let index = space.tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = space.tabs[index]

        // Capture state for undo before teardown
        let stateData = tab.currentInteractionStateData()
        let tabURL = tab.url?.absoluteString
        let tabTitle = tab.title
        let tabFaviconURL = tab.faviconURL?.absoluteString
        let tabParentID = tab.parentID
        let tabSplitFraction = tab.splitFraction
        // The page's durable identity if it is an extension page (TASK-24): its
        // origin can die before an undo or reopen (a context reload, a disable).
        let tabExtensionID = space.profile?.extensionID(forPageURL: tab.url)
        let closedSplitGroup = splitGroup(containing: tab.id, in: space)
        let splitPartnerID = closedSplitGroup?.members.first { $0.id != tab.id }?.id
        // Partner sits left of the closing tab iff the closing tab wasn't the first member.
        let splitPartnerWasLeft = splitPartnerID != nil && closedSplitGroup?.members.first?.id != tab.id

        // Archive to closed tab stack (skip incognito)
        if undoable, !space.isIncognito {
            let record = ClosedTabRecord(
                id: nil,
                tabID: tab.id.uuidString,
                spaceID: space.id.uuidString,
                url: tabURL,
                title: tabTitle,
                faviconURL: tabFaviconURL,
                interactionState: stateData,
                sortOrder: index,
                archivedAt: archivedAt?.timeIntervalSince1970,
                extensionID: tabExtensionID
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
        if undoable, archivedAt == nil {
            registerUndo(actionName: "Close Tab") { [weak self] in
                guard let self else { return }
                // An extension page comes back on its extension's live origin. One
                // whose extension was disabled or uninstalled since cannot come back
                // at all (TASK-28): the undo does nothing, and leaves the closed-tab
                // record to Reopen Closed Tab, which skips or discards it.
                guard let restored = self.restoredTab(
                    url: tabURL.flatMap { URL(string: $0) },
                    title: tabTitle,
                    faviconURL: tabFaviconURL.flatMap { URL(string: $0) },
                    interactionState: stateData,
                    extensionID: tabExtensionID, in: space
                ) else { return }
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
            let extensionID: String?
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
                parentID: member.parentID,
                extensionID: space.profile?.extensionID(forPageURL: member.url)
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
                    archivedAt: nil,
                    extensionID: snapshot.extensionID
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
            // A member on a page of an extension disabled or uninstalled since the
            // close cannot come back (TASK-28). It stays closed, its closed-tab
            // record left to Reopen Closed Tab's rules, and the other member comes
            // back on its own: a split needs both panes.
            let rebuilt: [(snapshot: MemberSnapshot, tab: BrowserTab)] = snapshots
                .sorted(by: { $0.index < $1.index })
                .compactMap { snapshot in
                    self.restoredTab(
                        url: snapshot.url.flatMap { URL(string: $0) },
                        title: snapshot.title,
                        faviconURL: snapshot.faviconURL.flatMap { URL(string: $0) },
                        interactionState: snapshot.interactionState,
                        extensionID: snapshot.extensionID, in: space
                    ).map { (snapshot, $0) }
                }
            guard !rebuilt.isEmpty else { return }
            let rejoinsSplit = rebuilt.count == snapshots.count
            let newGroupID = UUID()
            var restoredFirst: BrowserTab?
            for (snapshot, restored) in rebuilt {
                restored.parentID = snapshot.parentID
                if rejoinsSplit {
                    restored.splitGroupID = newGroupID
                    restored.splitFraction = fraction
                }
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
            if rejoinsSplit {
                self.registerUndo(actionName: "Close Both Splits") { [weak self] in
                    self?.closeSplitGroup(groupID: newGroupID, in: space)
                }
            } else if let lone = restoredFirst {
                self.registerUndo(actionName: "Close Tab") { [weak self] in
                    self?.closeTab(id: lone.id, in: space)
                }
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
    ///
    /// Returns whether the group was unpinned; a refused unpin shows
    /// `dormantTileRefusal(url:in:)` where the user asked for it (TASK-37).
    @discardableResult
    func unpinSplitGroup(groupID: UUID, toGapIndex: Int? = nil, in space: Space) -> Bool {
        let entries = pinnedSplitEntries(groupID: groupID, in: space)
        guard entries.count == 2 else { return false }
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

        // Both members' tabs first: if either dormant page cannot become a tab
        // (a disabled or uninstalled extension's), the whole group stays pinned
        // untouched rather than half-unpinned (TASK-34).
        var tabs: [BrowserTab] = []
        var materialized: [BrowserTab] = []
        for entry in entries {
            if let live = entry.tab {
                tabs.append(live)
                continue
            }
            guard let tab = materializeDormantEntry(entry, in: space) else {
                // Discard a sibling materialized a moment ago: bailing must leave
                // no subscribed tab behind either.
                for tab in materialized {
                    tabSubscriptions.removeValue(forKey: tab.id)
                    tab.teardown()
                }
                return false
            }
            materialized.append(tab)
            tabs.append(tab)
        }
        for entry in entries {
            space.pinnedEntries.removeAll { $0.id == entry.id }
            entry.splitGroupID = nil
            entry.splitFraction = nil
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
        return true
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
    ///
    /// Returns nil for an extension page that cannot become a tab (TASK-34): a
    /// disabled — or uninstalled, or legacy — extension's page would wake blank
    /// on a pending or dead origin, and the next restore would drop it. The
    /// entry must then stay dormant, so every caller has to bail *before*
    /// mutating anything.
    private func materializeDormantEntry(_ entry: PinnedEntry, in space: Space) -> BrowserTab? {
        let page = dormantTilePage(url: entry.pinnedURL, in: space.profile)
        guard dormantTileDropTargets(page).contains(.tabList),
              let url = rehomedTileURL(entry.pinnedURL, page: page, in: space) else { return nil }
        let tab = makeTab(loading: url, title: entry.pinnedTitle, faviconURL: entry.faviconURL, in: space)
        subscribeToTab(tab, spaceID: space.id)
        return tab
    }

    /// A new tab that opens `url` — for a tile (dormant pinned entry, favourite)
    /// or record that has no web view yet.
    ///
    /// An extension page is created *sleeping* instead of loaded here: it can only
    /// load in the configuration of the context serving its origin, which the
    /// space configuration is not, and `BrowserTab.wake` resolves exactly that
    /// when the window displays the tab (TASK-24). A restored page whose context
    /// has not loaded yet stays unloaded until `resolvePendingExtensionPages`
    /// moves it.
    private func makeTab(id: UUID = UUID(), loading url: URL, title: String, faviconURL: URL?, in space: Space) -> BrowserTab {
        if isExtensionPageURL(url) {
            return BrowserTab(id: id, title: title, url: url, faviconURL: faviconURL,
                              cachedInteractionState: nil, spaceID: space.id)
        }
        let tab = BrowserTab(
            id: id,
            title: title,
            archivedInteractionState: nil,
            fallbackURL: url,
            faviconURL: faviconURL,
            configuration: space.makeWebViewConfiguration()
        )
        tab.spaceID = space.id
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

    /// Returns whether the entry was unpinned; a refused unpin shows
    /// `dormantTileRefusal(url:in:)` where the user asked for it (TASK-37).
    @discardableResult
    func unpinTab(id: UUID, in space: Space, at destinationIndex: Int? = nil) -> Bool {
        guard let index = space.pinnedEntries.firstIndex(where: { $0.id == id }) else { return false }
        let entry = space.pinnedEntries[index]
        // Resolve the backing tab before anything is mutated: a dormant page that
        // cannot become a tab (a disabled or uninstalled extension's) leaves the
        // entry pinned exactly as it was (TASK-34).
        guard let tab = entry.tab ?? materializeDormantEntry(entry, in: space) else { return false }
        space.pinnedEntries.remove(at: index)
        let savedFolderID = entry.folderID
        let savedSortOrder = entry.sortOrder
        let savedPinnedIndex = index
        // A lone member leaving dissolves its pinned split (whole-group unpin
        // goes through unpinSplitGroup instead). Captured for undo rejoin.
        let membership = capturePinnedSplitMembership(of: entry, in: space)
        entry.splitGroupID = nil
        entry.splitFraction = nil
        dissolvePinnedSplit(around: id, groupID: membership?.groupID, in: space)
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
        return true
    }

    /// `undoable: false` skips the undo registration — see `closeTab`.
    func closePinnedTab(id: UUID, in space: Space, undoable: Bool = true) {
        guard let index = space.pinnedEntries.firstIndex(where: { $0.id == id }) else { return }
        let entry = space.pinnedEntries[index]
        // Capture tab state for undo before discarding
        let tab = entry.tab
        let stateData = tab?.currentInteractionStateData()
        let tabURL = tab?.url
        let tabTitle = tab?.title
        let tabFaviconURL = tab?.faviconURL
        let tabExtensionID = space.profile?.extensionID(forPageURL: tabURL ?? entry.pinnedURL)

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

        if undoable, tab != nil {
            registerUndo(actionName: "Close Tab") { [weak self] in
                guard let self else { return }
                guard let idx = space.pinnedEntries.firstIndex(where: { $0.id == id }) else { return }
                let entry = space.pinnedEntries[idx]
                guard entry.tab == nil else { return }  // Already live
                // With no URL captured the tab reopens the entry's home page, which
                // a context reload may have moved since: identify it as it is now.
                let url = tabURL ?? entry.pinnedURL
                let extensionID = tabURL == nil
                    ? space.profile?.extensionID(forPageURL: url) ?? tabExtensionID
                    : tabExtensionID
                // An extension page comes back on its live origin. One whose
                // extension was disabled or uninstalled since cannot come back: the
                // undo does nothing and the entry stays dormant (TASK-28).
                guard let restored = self.restoredTab(
                    url: url,
                    title: tabTitle ?? entry.pinnedTitle,
                    faviconURL: tabFaviconURL ?? entry.faviconURL,
                    interactionState: stateData,
                    extensionID: extensionID, in: space
                ) else { return }
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
        // The home page's durable identity if it is an extension page (TASK-24):
        // its origin can die before the undo (a context reload, a disable).
        let savedExtensionID = space.profile?.extensionID(forPageURL: savedPinnedURL)
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
            // An extension page entry comes back on its extension's live origin,
            // or dormant on a pending origin if the extension is disabled. One
            // whose extension was uninstalled since cannot come back (TASK-30):
            // the undo does nothing, registers no redo, and the split partner
            // stays dissolved.
            guard let pinnedURL = self.rehomedTileURL(savedPinnedURL, extensionID: savedExtensionID, in: space) else {
                return
            }
            let restored = PinnedEntry(
                id: id,
                pinnedURL: pinnedURL,
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

    /// Gives a dormant pinned entry a live backing tab (clicking the tile).
    ///
    /// Returns whether the entry gained one; a caller acting on a click shows
    /// `dormantTileRefusal(url:in:)` when it did not (TASK-37). False also for
    /// an entry that was already live, which needs no hint.
    @discardableResult
    func activatePinnedEntry(id: UUID, in space: Space) -> Bool {
        guard let index = space.pinnedEntries.firstIndex(where: { $0.id == id }) else { return false }
        let entry = space.pinnedEntries[index]
        guard entry.tab == nil else { return false }  // Already live
        // A page that cannot become a tab leaves the entry dormant, unchanged
        // and unannounced (TASK-34).
        guard let tab = materializeDormantEntry(entry, in: space) else { return false }
        entry.tab = tab
        notifyObservers { $0.tabStoreDidUpdatePinnedEntry(entry, at: index, in: space) }
        scheduleSave()
        return true
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
        // Menu validation: one availability for the whole scan, which can reach
        // every record in the stack.
        let availability = ExtensionAvailability(appDB: appDB)
        return closedTabStack.contains { record in
            guard record.spaceID == spaceIDString else { return false }
            switch closedTabPage(record, in: space, availability: availability) {
            case .notExtensionPage, .restorable: return true
            case .disabled, .unavailable: return false
            }
        }
    }

    /// What a closed-tab record's page is now (TASK-24).
    private func closedTabPage(_ record: ClosedTabRecord, in space: Space,
                               availability: ExtensionAvailability? = nil) -> PersistedExtensionPage {
        classifyCapturedPage(url: record.url.flatMap { URL(string: $0) }, extensionID: record.extensionID,
                             in: space, availability: availability)
    }

    // MARK: - Rebuilding closed tabs (TASK-24, TASK-28)

    /// The installed and per-profile enabled extension sets, read from the
    /// database at most once each and then held for the length of one operation
    /// (a restore, a menu validation, a drop, a reopen).
    ///
    /// Classification is a hot path — validating Reopen Closed Tab scans up to
    /// 100 records, and drop validation runs per mouse move — and each
    /// classification otherwise opens two read transactions. Behaviour is
    /// unchanged: nothing installs, enables or disables an extension in the
    /// middle of one of these operations. Ordinary URLs never touch the database.
    private final class ExtensionAvailability {
        private let appDB: AppDatabase
        private var installed: Set<String>?
        private var enabledByProfile: [UUID: Set<String>] = [:]

        init(appDB: AppDatabase) { self.appDB = appDB }

        func classify(url: URL?, extensionID: String?, in profile: Profile?) -> PersistedExtensionPage {
            guard isExtensionPageURL(url) else { return .notExtensionPage }
            let installedIDs: Set<String>
            if let installed {
                installedIDs = installed
            } else {
                installedIDs = appDB.installedExtensionIDs()
                installed = installedIDs
            }
            var enabled: Set<String> = []
            if let profile {
                if let cached = enabledByProfile[profile.id] {
                    enabled = cached
                } else {
                    enabled = appDB.enabledExtensionIDs(for: profile.id.uuidString)
                    enabledByProfile[profile.id] = enabled
                }
            }
            return classifyPersistedExtensionPage(url: url, extensionID: extensionID,
                                                  installedExtensionIDs: installedIDs,
                                                  enabledExtensionIDs: enabled)
        }
    }

    /// What a page captured earlier — a closed-tab record, a dormant tile's URL,
    /// or the state an undo closure captured at close time — is now, judged by
    /// the extension id captured with it (`Profile.extensionID(forPageURL:)` at
    /// that moment) against the extensions installed and enabled in `profile`.
    /// Only an extension page consults the database.
    ///
    /// Pass an `availability` shared by every classification of one operation;
    /// the default reads the database afresh, for a lone call.
    private func classifyCapturedPage(url: URL?, extensionID: String?, in profile: Profile?,
                                      availability: ExtensionAvailability? = nil) -> PersistedExtensionPage {
        (availability ?? ExtensionAvailability(appDB: appDB))
            .classify(url: url, extensionID: extensionID, in: profile)
    }

    /// `classifyCapturedPage` against `space`'s profile.
    private func classifyCapturedPage(url: URL?, extensionID: String?, in space: Space,
                                      availability: ExtensionAvailability? = nil) -> PersistedExtensionPage {
        classifyCapturedPage(url: url, extensionID: extensionID, in: space.profile, availability: availability)
    }

    /// Where a captured page of an installed extension (`page.pendingOrigin`)
    /// opens now. Its origin may be dead: saved by a previous launch, or the
    /// context was reloaded (or disabled) since. With the extension's context
    /// loaded the URL is rewritten onto its current base; otherwise the origin is
    /// registered as pending, so `resolvePendingExtensionPages` moves the page
    /// once the context loads and `BrowserTab.wake` leaves it unloaded until then.
    private func liveExtensionPageURL(_ url: URL, extensionID: String, originHost: String, in profile: Profile?) -> URL {
        guard let profile else { return url }
        guard let context = profile.extensionContext(for: extensionID) else {
            profile.registerPendingExtensionOrigin(host: originHost, extensionID: extensionID)
            return url
        }
        guard let oldBase = extensionOriginBaseURL(host: originHost) else { return url }
        return rewriteExtensionPageURL(url, from: oldBase, to: context.baseURL) ?? url
    }

    /// `liveExtensionPageURL` in `space`'s profile.
    private func liveExtensionPageURL(_ url: URL, extensionID: String, originHost: String, in space: Space) -> URL {
        liveExtensionPageURL(url, extensionID: extensionID, originHost: originHost, in: space.profile)
    }

    /// A captured tile URL (a pinned entry's home page, a favourite's URL) brought
    /// back or moved: an enabled extension's page moves to its live origin, and a
    /// disabled one's origin is registered as pending so a later enable moves it —
    /// what restore does for the tiles it keeps. An ordinary URL is returned as it
    /// is. An uninstalled extension's page returns nil: restore drops such a tile,
    /// so an undo must not bring it back (TASK-30) and a move must not carry it
    /// anywhere (TASK-34).
    private func rehomedTileURL(_ url: URL, page: PersistedExtensionPage, in profile: Profile?) -> URL? {
        switch page {
        case .restorable(let extensionID, let originHost):
            return liveExtensionPageURL(url, extensionID: extensionID, originHost: originHost, in: profile)
        case .disabled(let extensionID, let originHost):
            profile?.registerPendingExtensionOrigin(host: originHost, extensionID: extensionID)
            return url
        case .notExtensionPage:
            return url
        case .unavailable:
            return nil
        }
    }

    /// `rehomedTileURL` in `space`'s profile.
    private func rehomedTileURL(_ url: URL, page: PersistedExtensionPage, in space: Space) -> URL? {
        rehomedTileURL(url, page: page, in: space.profile)
    }

    /// `rehomedTileURL` for a tile URL captured with `extensionID`, classified now.
    private func rehomedTileURL(_ url: URL, extensionID: String?, in space: Space,
                                availability: ExtensionAvailability? = nil) -> URL? {
        rehomedTileURL(url, page: classifyCapturedPage(url: url, extensionID: extensionID, in: space,
                                                       availability: availability), in: space)
    }

    /// Rebuilds a tab that was closed, from what was captured when it closed:
    /// for Reopen Closed Tab and the close undos. `page` is `classifyCapturedPage`
    /// of `url` now.
    ///
    /// - An ordinary page comes back live, from the space configuration and its
    ///   interaction state (back/forward list), as it always has.
    /// - An enabled extension's page comes back *sleeping* on the extension's
    ///   live origin (`liveExtensionPageURL`) without its interaction state, whose
    ///   back/forward list is on the old origin; `BrowserTab.wake` builds it from
    ///   the context's configuration, the only one that can load the scheme.
    /// - A disabled or uninstalled extension's page returns nil: there is nothing
    ///   that could show it, and a blank tab is worse than none.
    private func restoredTab(
        id: UUID = UUID(), url: URL?, title: String, faviconURL: URL?, interactionState: Data?,
        page: PersistedExtensionPage, in space: Space
    ) -> BrowserTab? {
        switch page {
        case .notExtensionPage:
            let tab = BrowserTab(
                id: id,
                title: title,
                archivedInteractionState: interactionState,
                fallbackURL: url,
                faviconURL: faviconURL,
                configuration: space.makeWebViewConfiguration()
            )
            tab.spaceID = space.id
            return tab
        case .restorable(let extensionID, let originHost):
            guard let url else { return nil }
            let liveURL = liveExtensionPageURL(url, extensionID: extensionID, originHost: originHost, in: space)
            return makeTab(id: id, loading: liveURL, title: title, faviconURL: faviconURL, in: space)
        case .disabled, .unavailable:
            return nil
        }
    }

    /// `restoredTab` for a page captured with `extensionID`, classified now.
    private func restoredTab(
        url: URL?, title: String, faviconURL: URL?, interactionState: Data?,
        extensionID: String?, in space: Space
    ) -> BrowserTab? {
        restoredTab(url: url, title: title, faviconURL: faviconURL, interactionState: interactionState,
                    page: classifyCapturedPage(url: url, extensionID: extensionID, in: space), in: space)
    }

    @discardableResult
    func reopenClosedTab(in space: Space) -> BrowserTab? {
        let spaceIDString = space.id.uuidString

        // The most recent record of this space that can be reopened now. An
        // extension page (TASK-24) is judged by its saved extension id: one whose
        // extension has been uninstalled since can never load again and is
        // discarded; one whose extension is disabled is skipped but *kept*, so
        // it can be reopened after the extension is enabled again.
        var candidate: (index: Int, record: ClosedTabRecord, page: PersistedExtensionPage)?
        var index = 0
        let availability = ExtensionAvailability(appDB: appDB)
        scan: while index < closedTabStack.count {
            let record = closedTabStack[index]
            guard record.spaceID == spaceIDString else { index += 1; continue }
            let page = closedTabPage(record, in: space, availability: availability)
            switch page {
            case .unavailable:
                closedTabStack.remove(at: index)
                appDB.deleteClosedTab(tabID: record.tabID)
            case .disabled:
                index += 1
            case .notExtensionPage, .restorable:
                candidate = (index, record, page)
                break scan
            }
        }
        guard let (stackIndex, record, page) = candidate else { return nil }
        closedTabStack.remove(at: stackIndex)
        // By tab id rather than popping the space's newest row: skipped records
        // may sit above this one.
        appDB.deleteClosedTab(tabID: record.tabID)

        // The candidate is an ordinary page or a restorable one, so this builds a
        // tab; an extension page lands on its live origin (`restoredTab`).
        guard let tab = restoredTab(
            url: record.url.flatMap { URL(string: $0) },
            title: record.title,
            faviconURL: record.faviconURL.flatMap { URL(string: $0) },
            interactionState: record.interactionState,
            page: page, in: space
        ) else { return nil }

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
