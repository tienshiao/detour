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
    /// `tab` left `space.tabs` — closed, or handed off to another section of
    /// the same profile (`detachTab`). This is a list change, not a close: a
    /// closed tab was torn down before the notification, and the teardown is
    /// what reports the close (`BrowserTab.teardown`).
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

    /// Spaces `deleteSpace` removed since launch. Never emptied: Undo Delete
    /// Space can bring any of them back for as long as the session lasts, and
    /// `sweepHistoryOfDeletedSpaces` must not have taken their visits in the
    /// meantime (TASK-87). An undone delete puts the space back in `spaces`
    /// anyway, so leaving its id here costs nothing.
    private var spaceIDsDeletedThisSession: Set<UUID> = []

    /// How long a tab's title — or, since TASK-91, its URL — must hold still
    /// before the history follows it. Pages rewrite their title on a timer —
    /// unread counters, marquee titles, "(3) Inbox" — and a single-page app can
    /// push two URLs in a row; debouncing turns either into at most one write
    /// per quiet second (TASK-88). Injected so a test need not wait a real
    /// second per change.
    private let historySettleDebounce: TimeInterval

    /// Removes deleted profiles' on-disk WebKit data (TASK-32).
    private let profileDataRemoval: ProfileDataRemoval

    init(appDB: AppDatabase = .shared, historyDB: HistoryDatabase = .shared,
         profileDataRemover: ProfileDataRemoval.Remover = .webKit,
         profileDataRemovalRetryDelays: [TimeInterval] = ProfileDataRemoval.defaultRetryDelays,
         webKitStorageScope: WebKitStorageScope = .current,
         historySettleDebounce: TimeInterval = 1.0) {
        self.appDB = appDB
        self.historyDB = historyDB
        self.historySettleDebounce = historySettleDebounce
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
                self.subscribeToTab(tab)
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
                        self.subscribeToTab(tab)
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
                        self.subscribeToTab(tab)
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

    /// Moves a live tab out of `space` — its tab list, or the pinned section
    /// where `id` names a pinned entry with a backing tab — under a new favourite
    /// of `profileID`: the drop end of dragging onto the favourites bar. Returns
    /// whether the tab moved.
    ///
    /// Refused, changing nothing, for a tab with no URL to favourite (a blank
    /// new tab) or a pinned entry with no live tab (`addFavoriteFromEntry` is
    /// the dormant path). The URL check runs *before* the detach: a detached
    /// tab that then fails to be listed would sit in no section at all, still
    /// live and still registered with the extension contexts.
    ///
    /// Nothing about the tab changes: it keeps its web view, its profile and its
    /// registration with the extension contexts across the move (the detach is a
    /// hand-off, not a close, and the `favorites` didSet's `didPlace` is silent
    /// for an already-registered tab — TASK-52/59). So the contexts are told only
    /// what the move actually changed: a tab that was a pinned entry's backing
    /// tab a moment ago is not one now, which flips the flag
    /// `tabs.query({pinned})` reads — announced once the favourite lists the
    /// tab, since handling the change resolves its window and index.
    @discardableResult
    func moveTabToFavorites(id: UUID, from space: Space, profileID: UUID, at index: Int? = nil) -> Bool {
        guard profiles.contains(where: { $0.id == profileID }) else { return false }
        let tab: BrowserTab
        let wasPinned: Bool
        if let entry = space.pinnedEntries.first(where: { $0.id == id }) {
            guard let backing = entry.tab, backing.url != nil else { return false }
            tab = backing
            wasPinned = true
            _ = detachPinnedEntry(id: entry.id, from: space)
        } else if let listed = space.tabs.first(where: { $0.id == id }) {
            guard listed.url != nil else { return false }
            tab = listed
            wasPinned = false
            detachTab(id: tab.id, from: space)
        } else {
            return false
        }
        addFavorite(from: tab, profileID: profileID, at: index)
        if wasPinned { ExtensionTabLifecycle.didChangePinned(tab) }
        return true
    }

    /// Lists an already-detached live tab under a new favourite. The section
    /// moves go through `moveTabToFavorites`, which detaches and announces;
    /// this is the listing half on its own.
    func addFavorite(from tab: BrowserTab, profileID: UUID, at index: Int? = nil) {
        guard let url = tab.url, let profile = profiles.first(where: { $0.id == profileID }) else { return }

        let favorite = Favorite(url: url, title: tab.title, faviconURL: tab.faviconURL, sortOrder: 0, tab: tab)
        let insertAt = min(index ?? profile.favorites.count, profile.favorites.count)
        profile.favorites.insert(favorite, at: insertAt)
        reindexFavorites(profile)
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
        subscribeToTab(tab)
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

    /// Whether `tab` is the live backing tab of a pinned entry — the pinned flag
    /// extensions read (`BrowserTab.isPinned(for:)`), and the one the section
    /// moves announce when it flips (TASK-59).
    ///
    /// Asked of every space, not of `tab.spaceID`: a favourite's backing tab
    /// belongs to a profile rather than a space, and a tab can be listed by a
    /// space its own `spaceID` does not name.
    func isPinned(_ tab: BrowserTab) -> Bool {
        spaces.contains { space in space.pinnedEntries.contains { $0.tab === tab } }
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
        dormantTileRefusal(for: dormantTilePage(url: url, in: profile))
    }

    /// `dormantTileRefusal` for a page already classified — against whichever
    /// profile the caller judged it in (a move judges the page in the
    /// *destination*'s).
    private func dormantTileRefusal(for page: PersistedExtensionPage) -> DormantTileRefusal? {
        switch page {
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

    /// Rehomes an existing live tab onto `space` — for the paths that place a
    /// tab that already exists and so cannot go through `insertTab` (the
    /// favourite restores, TASK-58; a favourite left behind by a space delete).
    ///
    /// `spaceID` is the one place "which space is this tab's" lives:
    /// `BrowserTab.wake()` resolves its configuration through it, the per-space
    /// lookups key on it, and the tab's subscription reads it at visit time, so
    /// nothing has to be re-subscribed.
    private func adoptSpace(_ space: Space, for tab: BrowserTab) {
        tab.spaceID = space.id
    }

    /// A deleted space leaves behind the live favourite tabs that were brought
    /// to life in it: favourites belong to the profile, not the space, and their
    /// tabs live on `Favorite.tab` rather than in any space list, so the delete
    /// tears nothing of theirs down — but their `spaceID` would name a space
    /// that no longer resolves, and the next wake would build the page from a
    /// bare configuration (no data store, no extension controller — TASK-58).
    /// They move onto another space of the profile, where the tile still shows;
    /// when none is left the favourite is returned to a dormant tile, as a
    /// profile swap does (`updateSpace`).
    private func rehomeFavoriteTabs(boundTo space: Space) {
        guard let profile = profile(withID: space.profileID) else { return }
        let bound = profile.favorites.filter { $0.tab?.spaceID == space.id }
        guard !bound.isEmpty else { return }
        if let home = spaces.first(where: { $0.profileID == profile.id && $0.id != space.id }) {
            // Nothing a tile shows changes, so no favourites notification.
            for fav in bound { fav.tab.map { adoptSpace(home, for: $0) } }
        } else {
            for fav in bound { deactivateFavorite(id: fav.id, profileID: profile.id) }
        }
    }

    /// Moves a favorite back into the tab list, removing it from favorites.
    ///
    /// A live favourite's backing tab moves as it is, rehomed onto `space`
    /// (`adoptSpace`) — it belongs to this space now, not to whichever one it was
    /// activated in (TASK-58). A dormant one gets a new tab
    /// from `makeTab(loading:)` — an extension page is created sleeping, so wake
    /// builds it from its context's configuration — on its URL rehomed onto the
    /// extension's live origin (TASK-34). A dormant page of a disabled or
    /// uninstalled extension is refused (`favoriteDropTargets`): nothing moves,
    /// the favourite stays, and this returns false.
    @discardableResult
    func restoreFavoriteAsTab(id: UUID, profileID: UUID, in space: Space, at tabIndex: Int) -> Bool {
        // A favourite only moves into a space of its own profile: rehoming its
        // live tab onto another profile's space would rebuild it, on its next
        // wake, from that profile's data store and extension controller.
        guard space.profileID == profileID,
              let profile = profiles.first(where: { $0.id == profileID }),
              let favIdx = profile.favorites.firstIndex(where: { $0.id == id }) else { return false }
        let fav = profile.favorites[favIdx]

        let tab: BrowserTab
        if let liveTab = fav.tab {
            tab = liveTab
            adoptSpace(space, for: tab)
        } else {
            let page = dormantTilePage(url: fav.url, in: profile)
            guard dormantTileDropTargets(page).contains(.tabList),
                  let url = rehomedTileURL(fav.url, page: page, in: profile) else { return false }
            tab = makeTab(loading: url, title: fav.title, faviconURL: fav.faviconURL, in: space)
            subscribeToTab(tab)
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
    /// A live favourite's backing tab moves as it is, rehomed onto `space`
    /// (`adoptSpace`, TASK-58). A dormant one becomes a
    /// dormant entry whose home page is the favourite's URL rehomed (TASK-34): an
    /// enabled extension's page onto its live origin, a disabled one's kept with
    /// its origin registered as pending for a later enable. A dormant page of an
    /// uninstalled extension is refused: nothing moves, the favourite stays, and
    /// this returns false.
    @discardableResult
    func restoreFavoriteAsPinned(id: UUID, profileID: UUID, in space: Space, at pinnedIndex: Int) -> Bool {
        // Same profile only — see `restoreFavoriteAsTab`.
        guard space.profileID == profileID,
              let profile = profiles.first(where: { $0.id == profileID }),
              let favIdx = profile.favorites.firstIndex(where: { $0.id == id }) else { return false }
        let fav = profile.favorites[favIdx]

        let pinnedURL: URL
        if let liveTab = fav.tab {
            pinnedURL = fav.url
            adoptSpace(space, for: liveTab)
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
        // A live favourite's tab is now a pinned entry's backing tab: the
        // registration stands, the pinned flag flipped (TASK-59).
        if let tab = entry.tab { ExtensionTabLifecycle.didChangePinned(tab) }
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

        // A failed load leaves `tab.url` on the URL the user asked for while the
        // document in the web view is `browser-error://…` (`showErrorPage`), so
        // recording here would file a visit for a page that never loaded, titled
        // with the error page's own title (TASK-88). `lastRecordedHistoryURL` is
        // left alone too: the error document's title must not rename whatever
        // legitimate row that URL already has.
        if tab.webView?.url?.scheme == ErrorPage.scheme { return }

        // Never record history for incognito spaces
        if let space = space(withID: spaceID), space.isIncognito { return }

        guard let url = tab.url else { return }
        let urlString = url.absoluteString

        // Skip internal URLs
        guard url.scheme == "http" || url.scheme == "https" else { return }

        // Is this pass about the visit the tab is already holding? Only then may
        // a dedup-skipped recording keep that visit's id — and its correction
        // window. The space is part of the question: the same tab moved to
        // another space (TASK-63) is a different profile's history, and the
        // dedup marker it hits may be another tab's (TASK-91).
        let continuesLastRecording = tab.lastRecordedHistoryURL == url
            && tab.lastRecordedHistorySpaceID == spaceID

        // This URL has a `historyURL` row from here on — written below, or left
        // standing by the dedup — so a late title change may correct it (TASK-88).
        tab.lastRecordedHistoryURL = url
        tab.lastRecordedHistorySpaceID = spaceID
        // What a later same-document navigation is measured against (TASK-91).
        tab.lastRecordedBackForwardItem = tab.webView?.backForwardList.currentItem

        // Deduplicate: skip if same (url, spaceID) recorded within 30 seconds
        let dedupKey = "\(urlString)|\(spaceID.uuidString)"
        let now = Date().timeIntervalSince1970
        if !typed, let lastWrite = recentHistoryWrites[dedupKey], now - lastWrite < 30 {
            // No row was written, so the visit the tab may correct is the one it
            // already had — and only if this pass is about that same visit. For
            // any other URL, or the same URL in another space, the dedup entry
            // belongs to some other recording, which this tab must not correct.
            //
            // The correction window is *not* restarted: it belongs to the visit,
            // not to the recorder pass that found one already there. Restarting
            // it would let a reload ten minutes later write today's title onto a
            // visit made this morning (TASK-91).
            if !continuesLastRecording {
                tab.lastRecordedVisitID = nil
                tab.lastRecordedHistoryAt = Date()
                // The tab now holds a different visit (none), so an insert still
                // in flight from an earlier pass must not install its id over
                // that decision (TASK-91). A pass that *continues* the same
                // recording leaves the held visit exactly as it was, and its own
                // insert is still the right one — bumping there would throw away
                // the id of the visit this tab is holding.
                tab.historyRecordingGeneration &+= 1
            }
            // The title may have settled while the tab was still loading, in
            // which case the debounced correction was dropped and never retried
            // (TASK-88). The load has ended by the time the recorder runs, so
            // this is the moment that title can finally be written — the policy
            // still decides whether it may be.
            updateHistoryTitle(for: tab)
            return
        }
        recentHistoryWrites[dedupKey] = now

        // A visit is being written: the window starts now, and the id it will be
        // corrected by is not known yet. Until it arrives the tab holds none, so
        // a correction landing in between is dropped rather than written onto
        // the visit this one replaces (TASK-91). The generation moves with it,
        // so the insert this pass starts is the only one whose id may land.
        tab.lastRecordedHistoryAt = Date()
        tab.lastRecordedVisitID = nil
        tab.historyRecordingGeneration &+= 1
        let generation = tab.historyRecordingGeneration
        historyDB.recordVisit(
            url: urlString,
            title: tab.title,
            faviconURL: tab.faviconURL?.absoluteString,
            spaceID: spaceID.uuidString,
            typed: typed
        ) { [weak self, weak tab] visitID in
            guard let visitID else { return }
            // Back to main, where the tab's state lives — on the run loop, which
            // is what the rest of this pipeline (the debounced subscriptions
            // below, `.receive(on: RunLoop.main)`) is scheduled on, rather than
            // the main dispatch queue. An idle run loop would otherwise service
            // the block only at its next timer, so wake it.
            RunLoop.main.perform(inModes: [.common]) {
                // The tab may have recorded again while the insert was in
                // flight; that recording's id is the current one.
                guard let tab, tab.historyRecordingGeneration == generation else { return }
                tab.lastRecordedVisitID = visitID
                // A title that settled before the id arrived was dropped by the
                // policy and nothing would retry it — this is that retry, under
                // the same guards (TASK-91).
                self?.updateHistoryTitle(for: tab)
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    /// Records an in-page navigation — a `pushState` or a popstate traversal —
    /// as a visit (TASK-91, decision G).
    ///
    /// Driven by the debounced `$url` subscription in `subscribeToTab`: those
    /// navigations never toggle `isLoading`, so the ordinary recorder never sees
    /// them and a single-page app's page views reached the history only when an
    /// unrelated resource load happened to toggle it. The decision is a pure
    /// policy; the recording itself goes through `recordHistoryVisit`, so every
    /// rule it applies — incognito, http(s) only, error pages, internal pages,
    /// the typed flag, the 30 s dedup, the title handling — is shared rather
    /// than reimplemented here.
    func recordSameDocumentNavigationIfNeeded(for tab: BrowserTab) {
        let currentItem = tab.webView?.backForwardList.currentItem
        switch SameDocumentVisitPolicy.outcome(
            tabURL: tab.url,
            lastRecordedHistoryURL: tab.lastRecordedHistoryURL,
            currentItem: currentItem.map(ObjectIdentifier.init),
            lastRecordedItem: tab.lastRecordedBackForwardItem.map(ObjectIdentifier.init)
        ) {
        case .skip:
            return
        case .adoptBaseline:
            // Nothing to compare against, so nothing can be told apart: take the
            // entry the tab is on as the baseline and record from the next
            // genuinely different one (TASK-91).
            tab.lastRecordedBackForwardItem = currentItem
        case .record:
            guard let spaceID = tab.spaceID else { return }
            recordHistoryVisit(tab: tab, spaceID: spaceID)
        }
    }

    /// Writes a tab's settled title back onto the visit it recorded, when the
    /// policy below allows it (TASK-88, retargeted from the URL to the visit by
    /// TASK-91). Driven by the debounced `$title` subscription in
    /// `subscribeToTab`.
    func updateHistoryTitle(for tab: BrowserTab, now: Date = Date()) {
        // The space is resolved the way `recordHistoryVisit` resolves it, from
        // the tab's current `spaceID`: a favourite or peek tab that belongs to
        // no space never records a visit, so it has nothing to correct either.
        let space = tab.spaceID.flatMap { self.space(withID: $0) }
        guard let correction = HistoryTitleUpdatePolicy.correction(
            title: tab.title,
            webViewTitle: tab.webView?.title,
            isLoading: tab.isLoading,
            tabURL: tab.url,
            webViewURL: tab.webView?.url,
            lastRecordedHistoryURL: tab.lastRecordedHistoryURL,
            recordedVisitID: tab.lastRecordedVisitID,
            recordedAt: tab.lastRecordedHistoryAt,
            now: now,
            hasSpace: tab.spaceID != nil,
            isIncognito: space?.isIncognito ?? false
        ) else { return }

        historyDB.updateTitle(visitID: correction.visitID, url: correction.url.absoluteString,
                              title: tab.title)
    }

    /// After visits were deleted from the history (TASK-87): forgets what in
    /// memory still assumes those rows exist, and only that.
    ///
    /// `requestedAt` is when the delete was *asked for*, not when it committed.
    /// This runs on main after the write, and a visit recorded in between was
    /// recorded after the user chose what to delete — it is a new row the delete
    /// never saw, so the state it left behind is current and must survive:
    ///
    ///  - the 30 s dedup marker is dropped only when it is older than the
    ///    request, or revisiting a page right after deleting it would record
    ///    nothing;
    ///  - a tab's `lastRecordedHistoryURL` (TASK-88) is cleared only for a URL
    ///    in `removedURLs` — one whose `historyURL` row is gone, so a late title
    ///    change would otherwise write onto a row another profile recreated. A
    ///    merely *affected* URL still has its row, and correcting its title is
    ///    still the right thing to do.
    ///
    /// A tab can therefore be left holding the id of a visit this delete removed
    /// from a URL that survived. That is deliberate and harmless: `historyVisit`
    /// ids are `AUTOINCREMENT`, so the id is never handed to another row, and
    /// `updateTitle(visitID:url:title:)` simply matches nothing (TASK-91). The
    /// 60 s correction window closes the case shortly after anyway.
    ///
    /// `clearedScope` says the delete was a whole-scope clear: its URL list can
    /// run to tens of thousands, so the dedup entries go by space-id suffix
    /// rather than by looping urls × spaces here on the main thread.
    func historyDidDelete(_ result: HistoryDeletionResult, spaceIDs: [String], requestedAt: Date,
                          clearedScope: Bool = false) {
        guard result.deletedVisitCount > 0 else { return }
        let cutoff = requestedAt.timeIntervalSince1970
        var staleKeys: [String] = []
        if clearedScope {
            let suffixes = spaceIDs.map { "|\($0)" }
            for (key, writtenAt) in recentHistoryWrites
            where writtenAt <= cutoff && suffixes.contains(where: key.hasSuffix) {
                staleKeys.append(key)
            }
        } else {
            for url in result.affectedURLs {
                for spaceID in spaceIDs {
                    let key = "\(url)|\(spaceID)"
                    guard let writtenAt = recentHistoryWrites[key], writtenAt <= cutoff else { continue }
                    staleKeys.append(key)
                }
            }
        }
        for key in staleKeys { recentHistoryWrites[key] = nil }

        guard !result.removedURLs.isEmpty else { return }
        let removed = Set(result.removedURLs)
        let scope = Set(spaceIDs)
        for space in spaces where scope.contains(space.id.uuidString) {
            let tabs = space.tabs + space.pinnedEntries.compactMap(\.tab)
            for tab in tabs + tabs.compactMap(\.peekTab) {
                guard let recorded = tab.lastRecordedHistoryURL,
                      removed.contains(recorded.absoluteString),
                      let recordedAt = tab.lastRecordedHistoryAt, recordedAt <= requestedAt else { continue }
                tab.lastRecordedHistoryURL = nil
                tab.lastRecordedHistoryAt = nil
                // The visit row went with the URL (TASK-91): there is nothing
                // left to correct, and nothing for the next recording to
                // continue from.
                tab.lastRecordedHistorySpaceID = nil
                tab.lastRecordedVisitID = nil
            }
        }
    }

    /// Deletes the visits of spaces that no longer exist (TASK-87). At launch,
    /// not in `deleteSpace`: Undo Delete Space brings the space back under the
    /// same id and its history must still be there; the undo stack does not
    /// survive a relaunch.
    ///
    /// "Exists" therefore means the spaces the store holds *plus* the ones
    /// deleted since launch: the sweep runs seconds after launch and the undo
    /// stack lives for the whole session, so a space deleted before the timer
    /// fires is still undoable and must keep its history.
    ///
    /// The database refuses to sweep unless one of these spaces has visits of
    /// its own, so a session that failed to restore cannot make the whole
    /// history look orphaned.
    func sweepHistoryOfDeletedSpaces() {
        var existing = Set(spaces.filter { !$0.isIncognito }.map(\.id))
        existing.formUnion(spaceIDsDeletedThisSession)
        historyDB.deleteVisits(notInSpaceIDs: existing.map(\.uuidString)) { result in
            if case .failure(let error) = result {
                log.error("History sweep failed: \(error.localizedDescription)")
            }
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
        // The launch sweep runs on a timer and must not take the history of a
        // space Cmd+Z can still bring back (TASK-87).
        spaceIDsDeletedThisSession.insert(id)

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
        rehomeFavoriteTabs(boundTo: space)
        // The `Space` OBJECT survives the delete: the undo closure below holds it
        // and re-inserts that same instance, so every undo action registered
        // before this delete — Close Tab, Move Tab, Pin/Unpin, the pinned entry
        // and folder actions, all of which captured this instance — keeps acting
        // on the space the windows actually show once the delete is undone
        // (TASK-40). Only the contents go: the tabs were just torn down, and undo
        // repopulates the three lists from the snapshots above.
        space.tabs.removeAll()
        space.pinnedEntries.removeAll()
        space.pinnedFolders.removeAll()
        // Clean up closed tab records for this space (captured above for undo)
        appDB.deleteClosedTabs(spaceID: spaceIDString)
        closedTabStack.removeAll { $0.spaceID == spaceIDString }

        // `space` is captured strongly on purpose: the restored space must BE the
        // instance the older undo actions closed over (TASK-40).
        registerUndo(actionName: "Delete Space") { [weak self, space] in
            guard let self else { return }
            // deleteProfile clears the undo stack, so this only guards against
            // an action that outlived it: restoring onto a deleted profile would
            // bring back its removed storage (TASK-35). Nothing is restored and
            // no redo is registered.
            guard self.profile(withID: savedProfileID) != nil else {
                log.error("Undo Delete Space skipped: profile \(savedProfileID.uuidString, privacy: .public) of space \(id.uuidString, privacy: .public) no longer exists")
                return
            }
            // The same object, reset to the identity it had at the delete: an
            // Edit Space undone while it was detached could have changed any of
            // these on the retained instance.
            let restored = space
            restored.name = savedName
            restored.emoji = savedEmoji
            restored.colorHex = savedColorHex
            restored.profileID = savedProfileID
            restored.profile = self.profile(withID: savedProfileID)
            restored.selectedTabID = savedSelectedTabID
            // Its three lists are still the empty ones the delete left: nothing
            // can reach a detached space to refill them (undo is LIFO, so this
            // action always runs before any older one).

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
                self.subscribeToTab(tab)
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
        subscribeToTab(tab)
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

    /// Opens one of Detour's own pages in a new tab. The only store-level way
    /// in: `addTab(in:url:)` cannot open an internal page, and must not be able
    /// to — its callers include an extension's `tabs.create` and web content's
    /// `window.open` (TASK-86).
    @discardableResult
    func addTab(in space: Space, internalPage page: InternalPage, parentID: UUID? = nil) -> BrowserTab {
        let tab = BrowserTab(configuration: space.makeWebViewConfiguration())
        insertTab(tab, in: space, parentID: parentID)
        tab.loadInternalPage(page)
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
    ///
    /// The tab is not torn down, so the extension contexts keep it registered:
    /// a hand-off between sections of one profile is not a close (TASK-59).
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
    ///
    /// `registersUndo: false` records the tab on the closed-tab stack but
    /// registers no undo — the automatic archive sweep, which must not pollute
    /// the undo stack. `archivedAt` only stamps the record (TASK-115): the
    /// sidebar's "Archive Tab" / "Archive Tabs Below" set it and stay undoable.
    func closeTab(id: UUID, in space: Space, archivedAt: Date? = nil, undoable: Bool = true, registersUndo: Bool = true) {
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

        // Register undo (skip for automated archival). A manual archive is
        // undone under its own name, so Edit reads "Undo Archive Tab".
        let undoActionName = archivedAt == nil ? "Close Tab" : "Archive Tab"
        if undoable, registersUndo {
            registerUndo(actionName: undoActionName) { [weak self] in
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
                self.subscribeToTab(restored)
                // Remove the corresponding closed-tab-stack entry from both the
                // in-memory stack and the DB. Skipping the DB row would leave it to
                // be reloaded on next launch, so Cmd+Shift+T would reopen a duplicate.
                if let stackIdx = self.closedTabStack.firstIndex(where: { $0.tabID == id.uuidString }) {
                    self.closedTabStack.remove(at: stackIdx)
                }
                self.appDB.deleteClosedTab(tabID: id.uuidString)
                // Redo re-closes with the same stamp: an undone Archive Tab that
                // is redone stays an archive record, not a plain close (TASK-115).
                self.registerUndo(actionName: undoActionName) { [weak self] in
                    self?.closeTab(id: restored.id, in: space, archivedAt: archivedAt)
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

    // MARK: - Moving to Another Space (TASK-38)

    /// What a move does with a page it carries into `destination`.
    private enum MovedPage {
        /// Loads there as it is: an ordinary page, or any page moving within a
        /// profile.
        case unchanged
        /// An extension page whose `webkit-extension://` origin belongs to the
        /// source profile's loaded context: it is retargeted onto the
        /// destination profile's origin for the *same* extension.
        case retargeted(URL)
        /// The destination profile cannot show it in the section (TASK-34) —
        /// nothing installed there claims the origin, or the extension is off and
        /// only a dormant tile may wait on its pending origin. The hint says why,
        /// as for a refused dormant tile (TASK-37).
        case refused(DormantTileRefusal)
    }

    /// Where a page a move carries from `source` into `destination` opens there.
    ///
    /// Only an extension page can change, and only across profiles. Enabled in
    /// the destination gives a live origin; installed but disabled gives a
    /// pending one, which only a dormant tile may wait on (a tab would wake blank
    /// and the next restore would drop it); not installed gives nothing at all.
    /// An ordinary URL, or any move within a profile, never touches the database.
    private func movedPage(_ url: URL, from source: Space, to destination: Space,
                           section: FavoriteDropTargets, availability: ExtensionAvailability) -> MovedPage {
        guard source.profileID != destination.profileID, isExtensionPageURL(url) else { return .unchanged }
        let page = classifyCapturedPage(url: url,
                                        extensionID: source.profile?.extensionID(forPageURL: url),
                                        in: destination, availability: availability)
        guard dormantTileDropTargets(page).contains(section) else {
            return .refused(dormantTileRefusal(for: page) ?? .extensionUnavailable)
        }
        guard let rehomed = rehomedTileURL(url, page: page, in: destination) else {
            return .refused(.extensionUnavailable)
        }
        return rehomed == url ? .unchanged : .retargeted(rehomed)
    }

    /// What a cross-profile move does with the tab's peek. A peek's page is
    /// judged like the tab's own, but a peek the destination cannot show is
    /// dropped rather than refusing the move: it is an overlay on the tab, not
    /// the tab.
    private enum MovedPeek {
        case kept
        case retargeted(URL)
        case dropped
    }

    /// What carrying a live tab across resolves to: the URL to retarget the tab
    /// onto, if any, and the peek's fate. Both only matter across profiles.
    private struct TabCarry {
        let retargetURL: URL?
        let peek: MovedPeek
    }

    /// A planned move, or why it is refused.
    private enum MovePlan<Carried> {
        case proceed(Carried)
        case refused(DormantTileRefusal)
    }

    /// Resolves everything a tab move needs to know before mutating, so a
    /// refused page leaves the tab exactly where it was.
    private func planMove(of tab: BrowserTab, from source: Space, to destination: Space,
                          availability: ExtensionAvailability) -> MovePlan<TabCarry> {
        var retargetURL: URL?
        if let url = tab.url {
            switch movedPage(url, from: source, to: destination, section: .tabList, availability: availability) {
            case .unchanged: break
            case .retargeted(let rehomed): retargetURL = rehomed
            case .refused(let refusal): return .refused(refusal)
            }
        }
        // The peek's current page, as `savePeekStateForPersistence` would record
        // it: a live peek may have navigated since the URL was last saved.
        var peek = MovedPeek.kept
        if let peekURL = tab.peekTab?.webView?.url ?? tab.peekURL {
            switch movedPage(peekURL, from: source, to: destination, section: .tabList, availability: availability) {
            case .unchanged: peek = .kept
            case .retargeted(let rehomed): peek = .retargeted(rehomed)
            case .refused: peek = .dropped
            }
        }
        return .proceed(TabCarry(retargetURL: retargetURL, peek: peek))
    }

    /// `planMove` for a pinned entry: its home page has to be showable as a
    /// dormant tile there (a disabled extension's may wait on a pending origin),
    /// and a live entry's backing tab travels like a normal tab's.
    private func planMove(of entry: PinnedEntry, from source: Space, to destination: Space,
                          availability: ExtensionAvailability) -> MovePlan<(home: URL, carry: TabCarry?)> {
        var home = entry.pinnedURL
        switch movedPage(entry.pinnedURL, from: source, to: destination, section: .pinned, availability: availability) {
        case .unchanged: break
        case .retargeted(let rehomed): home = rehomed
        case .refused(let refusal): return .refused(refusal)
        }
        guard let tab = entry.tab else { return .proceed((home, nil)) }
        switch planMove(of: tab, from: source, to: destination, availability: availability) {
        case .proceed(let carry): return .proceed((home, carry))
        case .refused(let refusal): return .refused(refusal)
        }
    }

    /// Whether a move between these two spaces is allowed to happen at all.
    ///
    /// Refuses anything that crosses the incognito boundary: an incognito tab
    /// carries a live web view and — now that the tab itself moves — its whole
    /// interaction state, which landing in a persistent profile would write to
    /// the session database. The sidebar does not offer incognito spaces as
    /// destinations and hides the menu in an incognito window, so this is the
    /// invariant behind that, not a case the UI can reach.
    private func canMove(from source: Space, to destination: Space) -> Bool {
        source.id != destination.id && source.isIncognito == destination.isIncognito
    }

    /// Whether `moveTab(id:from:to:)` would move the tab: false for the same
    /// space, across the incognito boundary, an unknown id, or a page the
    /// destination profile cannot show. Mutates nothing, so a window can settle
    /// its own state before the move rather than undo it after a refusal.
    func canMoveTab(id: UUID, from source: Space, to destination: Space) -> Bool {
        guard canMove(from: source, to: destination),
              let tab = source.tabs.first(where: { $0.id == id }) else { return false }
        if case .proceed = planMove(of: tab, from: source, to: destination,
                                    availability: ExtensionAvailability(appDB: appDB)) { return true }
        return false
    }

    /// Why `moveTab` refuses the tab `id`'s page in `destination`, for the hint a
    /// refused move shows (TASK-37). Nil when the page is not the reason — the
    /// move is allowed, or refused for a reason with nothing to explain.
    func moveTabRefusal(id: UUID, from source: Space, to destination: Space) -> DormantTileRefusal? {
        guard canMove(from: source, to: destination),
              let tab = source.tabs.first(where: { $0.id == id }) else { return nil }
        if case .refused(let refusal) = planMove(of: tab, from: source, to: destination,
                                                availability: ExtensionAvailability(appDB: appDB)) {
            return refusal
        }
        return nil
    }

    /// `canMoveTab` for the pinned entry `id` (`movePinnedEntry`).
    func canMovePinnedEntry(id: UUID, from source: Space, to destination: Space) -> Bool {
        guard canMove(from: source, to: destination),
              let entry = source.pinnedEntries.first(where: { $0.id == id }) else { return false }
        if case .proceed = planMove(of: entry, from: source, to: destination,
                                    availability: ExtensionAvailability(appDB: appDB)) { return true }
        return false
    }

    /// `moveTabRefusal` for the pinned entry `id`.
    func movePinnedEntryRefusal(id: UUID, from source: Space, to destination: Space) -> DormantTileRefusal? {
        guard canMove(from: source, to: destination),
              let entry = source.pinnedEntries.first(where: { $0.id == id }) else { return nil }
        if case .refused(let refusal) = planMove(of: entry, from: source, to: destination,
                                                availability: ExtensionAvailability(appDB: appDB)) {
            return refusal
        }
        return nil
    }

    /// Selection the source space keeps after a move took its selected tab away.
    /// A window on that space settles its own selection first (it knows which
    /// tab *it* was showing); this is the store-level fallback, so a space no
    /// window is on does not keep naming a tab that now lives elsewhere. It picks
    /// what a window entering the space would (`tabToSelectOnEntry`), so the two
    /// agree.
    private func settleSelectionAfterMove(of tab: BrowserTab, from source: Space) {
        guard source.selectedTabID == tab.id else { return }
        source.selectedTabID = source.tabToSelectOnEntry()?.id
    }

    /// Carries a live tab from `source` into `destination`: the half of a move
    /// `moveTab` and `movePinnedEntry` share, run after the tab has left its
    /// source container and before it enters the destination one.
    ///
    /// Within one profile the tab is only rehomed: same object, same web view,
    /// so its back/forward list, scroll position and form state all survive.
    /// Across profiles the web view has to go — it was built from the source
    /// profile's data store and extension controller, and a configuration is
    /// only chosen at creation and at `wake()` — so the tab is slept exactly as
    /// a profile swap sleeps it (`updateSpace`), keeping its interaction state,
    /// and wakes rebuilt from the destination's configuration; an extension page
    /// is `retarget`ed onto the destination profile's origin instead. Its peek
    /// goes the same way: parked regardless of whether the host still had a web
    /// view (a non-forced sleep spares an audible peek, which would otherwise
    /// keep a source-profile web view under a destination-profile host), then
    /// retargeted or dropped as `planMove` decided.
    ///
    /// Only a move *across profiles* closes the tab for the extension contexts:
    /// the destination's contexts are different objects, the web view is rebuilt
    /// from their configuration, and the insertion that follows re-opens the tab
    /// under the destination profile. Within one profile the tab keeps the web
    /// view WebKit already maps, so closing it would make extensions drop the
    /// per-tab state (ports, frame maps) of a tab that never went away — the
    /// callers announce the move instead, with `announceSpaceMove` (TASK-61).
    private func carry(_ tab: BrowserTab, _ carry: TabCarry, from source: Space, to destination: Space) {
        if source.profileID != destination.profileID {
            ExtensionTabLifecycle.didClose(tab)
            if let retargetURL = carry.retargetURL {
                // Discards the interaction state with the dead origin's
                // back/forward list, and leaves the tab sleeping on the new URL.
                tab.retarget(to: retargetURL)
            } else {
                tab.sleep(force: true)
            }
            // `sleep` parks the peek only when the host had a web view to release.
            tab.parkPeek(force: true)
            switch carry.peek {
            case .kept:
                break
            case .retargeted(let url):
                // As `retarget` does for the tab: the saved state holds the dead
                // origin's back/forward list.
                tab.peekURL = url
                tab.peekInteractionState = nil
            case .dropped:
                tab.peekTab?.teardown()
                tab.clearPeekState()
            }
        }
        adoptSpace(destination, for: tab)
        settleSelectionAfterMove(of: tab, from: source)
    }

    /// The index the extension contexts knew `tab` at, in the window it is
    /// leaving — `BrowserWindowController.extensionTabs`, the same enumeration
    /// `tabs(for:)` reports. Must be read *before* the move mutates anything.
    ///
    /// With no old window (`ExtensionTabLifecycle.windowShowingTab` placed the
    /// tab in none) there is no such enumeration, so this falls back to the
    /// space's own sections in window order (pinned, then
    /// normal). That is a best effort: favourites belong to the profile and a
    /// live peek is interleaved by the window, and neither can be ordered
    /// without one — but a window-less source only ever produces the `onAttached`
    /// half, whose `fromIndex` no extension sees.
    private func extensionMoveIndex(of tab: BrowserTab, leaving source: Space,
                                    shownBy oldWindow: (any WKWebExtensionWindow)?) -> Int {
        if let wc = oldWindow as? BrowserWindowController,
           let index = wc.extensionTabs.firstIndex(where: { $0 === tab }) {
            return index
        }
        return (source.pinnedTabs + source.tabs).firstIndex { $0 === tab } ?? 0
    }

    /// Tells the contexts a same-profile "Move to Space" happened, once the tab
    /// is in the destination container (`ExtensionTabLifecycle.didMove`).
    ///
    /// Skipped when the tab was in no window before the move *and* none lists it
    /// now: `tabs.onDetached`/`onAttached`/`onMoved` all name a window, so with
    /// no window on either side there is no event either half could describe —
    /// and the tab is already reported open wherever it is. A window arriving on
    /// the destination later lists it from its first enumeration.
    private func announceSpaceMove(of tab: BrowserTab, fromIndex: Int,
                                   oldWindow: (any WKWebExtensionWindow)?) {
        guard oldWindow != nil || ExtensionTabLifecycle.windowListing(tab) != nil else { return }
        ExtensionTabLifecycle.didMove(tab, fromIndex: fromIndex, in: oldWindow)
    }

    /// Moves the tab `id` from `source` into `destination` — the sidebar's "Move
    /// to Space" — carrying the tab itself rather than rebuilding it (`carry`).
    ///
    /// An extension page crossing profiles is retargeted onto the destination
    /// profile's origin for its extension, and refused when that profile cannot
    /// serve it (`movedPage`): nothing moves and this returns false. A caller
    /// that wants to know beforehand asks `canMoveTab`; `moveTabRefusal` says
    /// why.
    ///
    /// Never a close: no closed-tab record and no Close Tab undo. The single
    /// "Move to Space" undo moves the tab back to the index it left, resolving
    /// both spaces by id at undo time, and restores the parent link the move
    /// cut. It restores the section and the index, not a split group the move
    /// dissolved — re-forming one needs the two members adjacent, which an index
    /// alone cannot promise.
    @discardableResult
    func moveTab(id: UUID, from source: Space, to destination: Space,
                 at destinationIndex: Int? = nil) -> Bool {
        guard canMove(from: source, to: destination),
              let index = source.tabs.firstIndex(where: { $0.id == id }) else { return false }
        let tab = source.tabs[index]

        // Resolved before anything is mutated: a refused page has to leave the
        // tab exactly where it was.
        guard case .proceed(let plan) = planMove(of: tab, from: source, to: destination,
                                                 availability: ExtensionAvailability(appDB: appDB))
        else { return false }

        // Resolved before the move mutates anything: both name where the tab is
        // *leaving* from (TASK-61).
        let sameProfile = source.profileID == destination.profileID
        let oldWindow = ExtensionTabLifecycle.windowShowingTab(tab)
        let fromIndex = extensionMoveIndex(of: tab, leaving: source, shownBy: oldWindow)

        source.tabs.remove(at: index)
        leaveSplitGroup(tab, in: source)
        // The views want the same redraw as a removal. The extension seam does
        // not listen to this notification (teardown is its close point); across
        // profiles `carry` closes the tab, and within one the insertion below
        // announces the move.
        notifyObservers { $0.tabStoreDidRemoveTab(tab, at: index, in: source) }
        carry(tab, plan, from: source, to: destination)
        // The tab it was opened from stays behind, so it arrives as a root tab.
        let savedParentID = tab.parentID
        tab.parentID = nil

        let insertAt = snappedToSplitGroupBoundary(
            min(destinationIndex ?? destination.tabs.count, destination.tabs.count),
            groupIDs: destination.tabs.map(\.splitGroupID)
        )
        destination.tabs.insert(tab, at: insertAt)
        notifyObservers { $0.tabStoreDidInsertTab(tab, at: insertAt, in: destination) }
        if sameProfile {
            announceSpaceMove(of: tab, fromIndex: fromIndex, oldWindow: oldWindow)
        }
        // Ids, not objects: the spaces are resolved at undo time, and the tab by
        // id in the reverse move (Undo Delete Space rebuilds a space's tabs as
        // fresh objects of the same ids — TASK-40).
        let sourceID = source.id
        let destinationID = destination.id
        registerUndo(actionName: "Move to Space") { [weak self] in
            guard let self,
                  let home = self.space(withID: sourceID),
                  let current = self.space(withID: destinationID),
                  self.moveTab(id: id, from: current, to: home, at: index) else { return }
            // Coming home means coming back under the tab it was opened from,
            // while that tab is still there. The reverse move captured the cut
            // link (nil), so the redo it registered leaves this alone.
            if let savedParentID, home.tabs.contains(where: { $0.id == savedParentID }),
               let returned = home.tabs.first(where: { $0.id == id }) {
                returned.parentID = savedParentID
                self.scheduleSave()
            }
        }
        scheduleSave()
        return true
    }

    /// Moves the pinned entry `id` from `source` into `destination`, staying
    /// pinned — the pinned half of "Move to Space".
    ///
    /// A live entry's backing tab travels like a normal tab's (`carry`); a
    /// dormant one stays dormant, its home page rehomed onto the destination
    /// profile's origin when it is an extension page (TASK-34). A dormant tile
    /// may wait on a pending origin, so a disabled extension's entry can still
    /// move; a live one cannot, since its tab has nowhere to wake. Nothing
    /// installed to claim the origin refuses the move entirely
    /// (`canMovePinnedEntry` / `movePinnedEntryRefusal` ask beforehand).
    ///
    /// Pinned folders belong to their space, so the entry lands at the
    /// destination's root with a fresh sort order. Its pinned split dissolves
    /// (both members would have to move together to survive); the undo rejoins
    /// it if the partner is still an ungrouped sibling, as the unpin undo does.
    @discardableResult
    func movePinnedEntry(id: UUID, from source: Space, to destination: Space,
                         at destinationIndex: Int? = nil) -> Bool {
        guard canMove(from: source, to: destination),
              let index = source.pinnedEntries.firstIndex(where: { $0.id == id }) else { return false }
        let entry = source.pinnedEntries[index]

        guard case .proceed(let plan) = planMove(of: entry, from: source, to: destination,
                                                 availability: ExtensionAvailability(appDB: appDB))
        else { return false }

        // As in `moveTab`: where the tab is leaving from, read before the move
        // mutates anything (TASK-61).
        let sameProfile = source.profileID == destination.profileID
        let oldWindow = entry.tab.flatMap { ExtensionTabLifecycle.windowShowingTab($0) }
        let fromIndex = entry.tab.map { extensionMoveIndex(of: $0, leaving: source, shownBy: oldWindow) } ?? 0

        let savedFolderID = entry.folderID
        let savedSortOrder = entry.sortOrder
        let membership = capturePinnedSplitMembership(of: entry, in: source)
        source.pinnedEntries.remove(at: index)
        entry.splitGroupID = nil
        entry.splitFraction = nil
        dissolvePinnedSplit(around: id, groupID: membership?.groupID, in: source)
        notifyObservers { $0.tabStoreDidRemovePinnedEntry(entry, at: index, in: source) }

        if let tab = entry.tab, let tabCarry = plan.carry {
            carry(tab, tabCarry, from: source, to: destination)
        }
        entry.pinnedURL = plan.home
        entry.folderID = nil
        let maxEntryOrder = destination.pinnedEntries.map(\.sortOrder).max() ?? -1
        let maxFolderOrder = destination.pinnedFolders.map(\.sortOrder).max() ?? -1
        entry.sortOrder = max(maxEntryOrder, maxFolderOrder) + 1

        let insertAt = min(destinationIndex ?? destination.pinnedEntries.count,
                           destination.pinnedEntries.count)
        destination.pinnedEntries.insert(entry, at: insertAt)
        notifyObservers { $0.tabStoreDidInsertPinnedEntry(entry, at: insertAt, in: destination) }
        if sameProfile, let tab = entry.tab {
            announceSpaceMove(of: tab, fromIndex: fromIndex, oldWindow: oldWindow)
        }
        // Ids, not objects: the spaces are resolved at undo time, and so is the
        // entry — Undo Delete Space rebuilds a space's pinned entries as fresh
        // objects of the same ids (TASK-40), so the instance captured here may
        // be an orphan by the time this runs.
        let sourceID = source.id
        let destinationID = destination.id
        registerUndo(actionName: "Move to Space") { [weak self] in
            guard let self,
                  let home = self.space(withID: sourceID),
                  let current = self.space(withID: destinationID),
                  self.movePinnedEntry(id: id, from: current, to: home, at: index),
                  let returned = home.pinnedEntries.first(where: { $0.id == id }) else { return }
            // Coming home means coming back to the folder and the sort order the
            // entry left from, which the move itself deliberately does not keep —
            // the folder while it still exists.
            returned.folderID = home.pinnedFolders.contains(where: { $0.id == savedFolderID }) ? savedFolderID : nil
            returned.sortOrder = savedSortOrder
            self.rejoinPinnedSplit(returned, membership: membership, in: home)
            // The saved sort order can tie with a sibling renumbered since the
            // move, which can land the entry between the members of a pinned
            // split; the invariant is re-checked whether or not a group was
            // rejoined (`rejoinPinnedSplit` only sanitizes when there was one).
            sanitizePinnedSplitGroups(entries: home.pinnedEntries, folders: home.pinnedFolders)
            self.notifyObservers { $0.tabStoreDidReorderPinnedEntries(in: home) }
            self.scheduleSave()
        }
        scheduleSave()
        return true
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
        subscribeToTab(tab)

        let groupID = UUID()
        for member in [anchor, tab] {
            member.splitGroupID = groupID
            member.splitFraction = 0.5
        }

        // Undo is a non-archiving removal: the pane never existed as a lone tab,
        // so it must not land in the Cmd+Shift+T closed-tab stack the way
        // closeTab's undo path would put it there.
        // The id, not the tab: Undo Delete Space rebuilds the space's tabs as
        // fresh objects of the same ids, so a captured instance would be an
        // orphan (TASK-40).
        let newTabID = tab.id
        registerUndo(actionName: "Open in Split") { [weak self] in
            guard let self else { return }
            guard let index = space.tabs.firstIndex(where: { $0.id == newTabID }) else {
                log.error("Undo Open in Split skipped: tab \(newTabID.uuidString, privacy: .public) is gone")
                return
            }
            self.tabSubscriptions.removeValue(forKey: newTabID)
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
                self.subscribeToTab(restored)
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
        // Both members crossed into the pinned section; announced once the pair
        // is whole, so a context resolving the tabs sees the finished group
        // (TASK-59).
        for tab in members { ExtensionTabLifecycle.didChangePinned(tab) }

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
        // Both members left the pinned section (TASK-59). A member this call just
        // materialized was first reported by the insert above, already unpinned
        // — nothing flipped for it (see `unpinTab`).
        for tab in tabs where !materialized.contains(where: { $0 === tab }) {
            ExtensionTabLifecycle.didChangePinned(tab)
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
        subscribeToTab(tab)
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
        // Same tab, same web view, same profile, new section: the extension
        // contexts keep it open and hear only that the pinned flag flipped
        // (TASK-59). Undo goes through `unpinTab`, which announces the flip back.
        ExtensionTabLifecycle.didChangePinned(tab)
        let savedTabIndex = index
        // The id, not the entry: Undo Delete Space rebuilds the pinned entries as
        // fresh objects of the same ids (TASK-40). unpinTab no-ops for an id the
        // space no longer has.
        let pinnedEntryID = entry.id
        registerUndo(actionName: "Pin Tab") { [weak self] in
            self?.unpinTab(id: pinnedEntryID, in: space, at: savedTabIndex)
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
        // The flag flipped the other way (TASK-59) — for a tab the contexts knew
        // as pinned. One this call just materialized from a dormant entry was
        // first reported by the insert above, already unpinned; announcing a
        // flip for it would be a change to nothing.
        if entry.tab != nil { ExtensionTabLifecycle.didChangePinned(tab) }
        // The id, not the tab: Undo Delete Space rebuilds the space's tabs as
        // fresh objects of the same ids (TASK-40).
        let unpinnedTabID = tab.id
        registerUndo(actionName: "Unpin Tab") { [weak self] in
            guard let self else { return }
            // Re-pin: remove from tabs, create entry, insert at original pinned position
            guard let tabIndex = space.tabs.firstIndex(where: { $0.id == unpinnedTabID }) else {
                log.error("Undo Unpin Tab skipped: tab \(unpinnedTabID.uuidString, privacy: .public) is gone")
                return
            }
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
            // This undo re-pins inline rather than calling `pinTab`, so it
            // announces the flip itself (TASK-59).
            ExtensionTabLifecycle.didChangePinned(tab)
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
                self.subscribeToTab(restored)
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
        // The id, not the folder: Undo Delete Space rebuilds the pinned folders as
        // fresh objects of the same ids (TASK-40). deletePinnedFolder no-ops for an
        // id the space no longer has.
        let newFolderID = folder.id
        registerUndo(actionName: "New Folder") { [weak self] in
            self?.deletePinnedFolder(id: newFolderID, in: space)
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
        subscribeToTab(tab)
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

    /// How many times a tab's web view may be hosted (`BrowserTab.showsSinceWake`)
    /// before the tab becomes eligible to sleep on the short
    /// `sleepShowBudgetGrace` instead of its profile's `sleepThreshold`.
    ///
    /// Why this exists (TASK-104): WebKit's GPU process keeps one IOSurfacePool
    /// per WebContent process and caps that pool by *bytes* only, while the
    /// kernel caps a process at 16,384 IOSurfaces. Every hidden -> visible
    /// transition of a web view leaves a few purged-but-alive surfaces in the
    /// pool that the byte budget never reclaims, and only the WebContent process
    /// going away — the tab sleeping or closing — frees them. After a long
    /// uptime the GPU process hits the 16,384 limit and WebGL contexts and
    /// accelerated canvases die browser-wide. The tabs shown most often are
    /// exactly the ones the idle rule never sleeps (pinned entries' and
    /// favourites' backing tabs, which it skips outright), so a tab that has
    /// spent its show budget gets a second, much shorter route to sleeping. It
    /// only ever *shortens* a threshold: a tab that is on screen
    /// (`lastDeselectedAt == nil`), playing audio, or was used within the grace
    /// is never slept by it.
    ///
    /// Overridable for the runtime harness via `DETOUR_SLEEP_SHOW_BUDGET`, read
    /// once at launch.
    static let sleepShowBudget = sleepShowBudgetSetting()
    /// How long a tab that has spent its show budget must stay out of sight
    /// before it sleeps. Overridable via `DETOUR_SLEEP_SHOW_BUDGET_GRACE_SECONDS`.
    static let sleepShowBudgetGrace = sleepShowBudgetGraceSetting()

    static let defaultSleepShowBudget = 50
    static let defaultSleepShowBudgetGrace: TimeInterval = 15 * 60

    /// A non-positive or unparseable override is ignored rather than disabling
    /// the rule by accident.
    static func sleepShowBudgetSetting(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let raw = environment["DETOUR_SLEEP_SHOW_BUDGET"],
              let value = Int(raw), value > 0 else { return defaultSleepShowBudget }
        return value
    }

    static func sleepShowBudgetGraceSetting(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TimeInterval {
        guard let raw = environment["DETOUR_SLEEP_SHOW_BUDGET_GRACE_SECONDS"],
              let value = TimeInterval(raw), value.isFinite, value >= 0 else { return defaultSleepShowBudgetGrace }
        return value
    }

    /// Sleeps tabs that have been out of sight long enough, on either of two
    /// rules: the profile's `sleepThreshold` for ordinary normal tabs, or — for
    /// any hidden, silent tab that has spent its show budget — the much shorter
    /// `sleepShowBudgetGrace`. The budget rule is the only one that reaches
    /// pinned entries' and favourites' backing tabs, which is the point: they are
    /// shown constantly and never idle long enough to sleep on time alone
    /// (TASK-104).
    ///
    /// A profile set to never sleep tabs is honoured by both rules.
    ///
    /// `now` is injectable for tests; production drives this from `archiveTimer`.
    func sleepStaleTabs(now: Date = Date()) {
        let budgetCutoff = now.addingTimeInterval(-Self.sleepShowBudgetGrace)

        /// When the tab went out of sight, or nil when it must not sleep at all
        /// — the preconditions both rules share. A nil `lastDeselectedAt` means
        /// the tab is selected in some window.
        ///
        /// A parented container means some window is hosting the tab right now
        /// ("has a superview" = "hosted somewhere", as in `removeContentViews`):
        /// two windows on one space share a single `lastDeselectedAt`, so the
        /// one that deselects the tab stamps it while the other still shows it,
        /// and releasing the web view would blank that window's content area.
        func offScreenSince(_ tab: BrowserTab) -> Date? {
            guard !tab.isPlayingAudio, tab.webViewContainer?.superview == nil else { return nil }
            return tab.lastDeselectedAt
        }

        /// Shown enough times to have stranded surfaces, and out of sight for
        /// the grace — so sleeping it now cannot be "right after it was used".
        func isOverShowBudget(_ tab: BrowserTab) -> Bool {
            guard tab.showsSinceWake >= Self.sleepShowBudget,
                  let since = offScreenSince(tab) else { return false }
            return since < budgetCutoff
        }

        for space in spaces {
            let threshold = space.profile?.sleepThreshold ?? .oneHour
            guard threshold != .never else { continue }
            let cutoff = now.addingTimeInterval(-threshold.rawValue)
            let pinnedTabIDs = Set(space.pinnedEntries.compactMap { $0.tab?.id })

            func isStale(_ tab: BrowserTab) -> Bool {
                guard !pinnedTabIDs.contains(tab.id), let since = offScreenSince(tab) else { return false }
                return since < cutoff
            }

            func shouldSleep(_ tab: BrowserTab) -> Bool {
                isStale(tab) || isOverShowBudget(tab)
            }

            for tab in space.tabs {
                guard !tab.isSleeping, shouldSleep(tab) else { continue }
                // A split renders both members at once — never sleep one while
                // its partner is fresh, or a visible pane goes blank.
                if let groupID = tab.splitGroupID {
                    let partners = space.tabs.filter { $0.splitGroupID == groupID && $0.id != tab.id }
                    guard partners.allSatisfy({ $0.isSleeping || shouldSleep($0) }) else { continue }
                }
                tab.sleep()
            }

            // Pinned entries stay *live but asleep*: the entry keeps its tab, so
            // selecting it wakes back into the cached interaction state instead
            // of reloading a dormant tile.
            for entry in space.pinnedEntries {
                guard let tab = entry.tab, !tab.isSleeping, isOverShowBudget(tab) else { continue }
                // A pinned split's group lives on the entries (§12), so its
                // partners are resolved there rather than through `splitGroupID`
                // on the tabs — same rule, same reason.
                if let groupID = entry.splitGroupID {
                    let partners = pinnedSplitEntries(groupID: groupID, in: space)
                        .compactMap(\.tab).filter { $0 !== tab }
                    guard partners.allSatisfy({ $0.isSleeping || isOverShowBudget($0) }) else { continue }
                }
                tab.sleep()
            }
        }

        // Favourites hang off the profile, not off any space, and are never
        // split — their backing tabs only ever sleep on the budget rule.
        for profile in profiles where profile.sleepThreshold != .never {
            for favorite in profile.favorites {
                guard let tab = favorite.tab, !tab.isSleeping, isOverShowBudget(tab) else { continue }
                tab.sleep()
            }
        }

        scheduleSave()
    }

    func archiveStaleTabs(now: Date = Date()) {
        for space in spaces where !space.isIncognito {
            let threshold = space.profile?.archiveThreshold ?? .twelveHours
            guard threshold != .never else { continue }
            let cutoff = now.addingTimeInterval(-threshold.rawValue)

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
                closeTab(id: tabID, in: space, archivedAt: now, registersUndo: false)
            }
        }
    }

    // MARK: - Per-Tab Subscriptions

    /// The tab's `spaceID` is read when a visit is recorded, not captured here,
    /// so a tab rehomed onto another space (`adoptSpace`) keeps its
    /// subscription and records under its current space.
    private func subscribeToTab(_ tab: BrowserTab) {
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
                if !isLoading, let spaceID = tab.spaceID {
                    self.recordHistoryVisit(tab: tab, spaceID: spaceID)
                }
            }
            .store(in: &cancellables)

        // An in-page navigation — `pushState`, or a Back within the document —
        // moves the tab's URL without ever toggling `isLoading`, so the recorder
        // above never sees it (TASK-91). Debounced on the same interval as the
        // title below: the URL has to have stopped moving (a site that pushes
        // twice in a row records only where it came to rest), and by then the
        // title has usually settled too.
        tab.$url
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .seconds(historySettleDebounce), scheduler: RunLoop.main)
            .sink { [weak self, weak tab] url in
                guard let self, let tab, tab.url == url else { return }
                self.recordSameDocumentNavigationIfNeeded(for: tab)
            }
            .store(in: &cancellables)

        // A title that settles after the visit was recorded corrects the stored
        // one (TASK-88). Separate from `observe(\.$title)` above, which only
        // redraws the sidebar: this one is debounced, and the guards in
        // `updateHistoryTitle` need the title to have stopped moving.
        tab.$title
            .dropFirst()
            .removeDuplicates()
            // The URL travels with the title: the debounce fires a second after
            // the title changed, and by then the tab may have moved — a
            // pushState to another page and a Back within the same second would
            // otherwise write the second page's title onto the first URL
            // (TASK-88).
            .map { [weak tab] title in (title: title, url: tab?.url) }
            .debounce(for: .seconds(historySettleDebounce), scheduler: RunLoop.main)
            .sink { [weak self, weak tab] titled in
                guard let self, let tab, tab.url == titled.url else { return }
                self.updateHistoryTitle(for: tab)
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

/// When a tab's title change may correct the visit it recorded.
///
/// A visit is recorded the moment loading finishes, but a single-page app
/// rewrites `document.title` after that, so the visit keeps the previous page's
/// title (TASK-88). The correction is deliberately narrow: only the visit this
/// tab itself recorded, only a title the document actually reports, and only
/// under the exclusions that governed the recording.
///
/// Pure so the whole guard matrix is testable without a web view.
enum HistoryTitleUpdatePolicy {

    /// The visit to rewrite, and the URL it must still belong to — the database
    /// refuses the write if the two have come apart (TASK-91).
    struct Correction: Equatable {
        let visitID: Int64
        let url: URL
    }

    /// How long after the visit was recorded a late title may still correct it.
    ///
    /// Long enough for a slow single-page app to fetch its data and set the
    /// title; short enough that an unread counter or a marquee title does not
    /// keep rewriting the history for as long as the tab stays open — and
    /// nobody wants "(211) YouTube" as the stored title of youtube.com anyway.
    static let correctionWindow: TimeInterval = 60

    /// The visit whose stored title should become `title`, or nil to write
    /// nothing.
    ///
    /// - Parameters:
    ///   - title: the tab's settled title (`BrowserTab.title`).
    ///   - webViewTitle: `tab.webView?.title` — nil for a sleeping tab.
    ///   - isLoading: a navigation is in flight, so the title in hand may
    ///     belong to either side of it.
    ///   - tabURL: where the tab is now.
    ///   - webViewURL: the URL of the document the title came from
    ///     (`tab.webView?.url`).
    ///   - lastRecordedHistoryURL: the URL this tab last got a history row for.
    ///   - recordedVisitID: the visit row that recording produced. Nil while the
    ///     insert is still in flight — the correction waits for the next title
    ///     event or the recorder's own retry rather than guessing a row
    ///     (TASK-91).
    ///   - recordedAt: when the recorder last saw that URL.
    ///   - now: the current time, against `recordedAt`.
    ///   - hasSpace: the tab belongs to a space, the way a recorded visit does.
    ///   - isIncognito: that space is incognito.
    static func correction(title: String,
                           webViewTitle: String?,
                           isLoading: Bool,
                           tabURL: URL?,
                           webViewURL: URL?,
                           lastRecordedHistoryURL: URL?,
                           recordedVisitID: Int64?,
                           recordedAt: Date?,
                           now: Date,
                           hasSpace: Bool,
                           isIncognito: Bool) -> Correction? {
        guard hasSpace, !isIncognito, !isLoading else { return nil }
        // The title has to be one the live document reports. `BrowserTab.updateTitle`
        // also publishes stand-ins — the scheme-stripped URL while a navigation is
        // pending, an internal page's name, the persisted title of a session still
        // being restored — and none of those may reach the history. A sleeping tab
        // has no web view and so never passes.
        guard !title.isEmpty, title == webViewTitle else { return nil }
        // Only the URL this tab recorded: never the previous page after an
        // in-page navigation moved the tab on, and never a URL nothing wrote a
        // row for.
        guard let url = tabURL, url == lastRecordedHistoryURL else { return nil }
        // And only a visit this tab is actually holding: without an id there is
        // nothing to correct (TASK-91).
        guard let recordedVisitID else { return nil }
        // The title has to have come from the document at that very URL. A
        // failed load is the case that matters: `showErrorPage` leaves
        // `tab.url` on the URL the user asked for while the web view shows
        // `browser-error://…`, and the error page's title must not rename that
        // row (TASK-88). Any other disagreement between the tab's URL and the
        // live document is refused for the same reason.
        guard webViewURL == url else { return nil }
        // Only while the visit is still settling. Past the window the page is
        // no longer catching up with its own navigation, it is just rewriting
        // its title, and the history stops following.
        guard let recordedAt, now.timeIntervalSince(recordedAt) <= correctionWindow else { return nil }
        // The same exclusion the recorder applies: `detour://` internal pages,
        // `browser-error://` and extension pages are not in the history at all.
        guard url.scheme == "http" || url.scheme == "https" else { return nil }
        return Correction(visitID: recordedVisitID, url: url)
    }
}

/// Whether a tab's URL moving within the document it is already showing is a
/// visit (TASK-91, decision G).
///
/// `history.pushState` and popstate traversals never toggle `isLoading`, so the
/// ordinary recorder — which runs when a load ends — never sees a single-page
/// app's page views. They are told apart from `replaceState` by back/forward
/// *item identity*: a pushState or a traversal makes the web view's
/// `backForwardList.currentItem` a different object, while a replaceState
/// rewrites the current item's URL in place. Query-string churn (and the
/// History page's own `?q=`) is therefore never a visit.
///
/// Deliberately not gated on `isLoading`: a single-page app whose subresource
/// keeps loading for a minute would otherwise lose every page view made in the
/// meantime. Item identity already excludes a navigation that has not committed
/// (while a load is provisional `currentItem` is still the old entry — asserted
/// against a real web view in `SameDocumentVisitTests`), the recorder's own
/// guards still exclude error pages and non-web schemes, and the ordinary
/// `isLoading → false` recording that follows a real navigation is absorbed by
/// the 30 s dedup — whose branch also retries the title correction (TASK-88).
/// The accepted cost is a second visit for a cross-document load that takes
/// more than 30 s *after* committing.
///
/// Pure — identity arrives as `ObjectIdentifier` — so the matrix is testable
/// without a web view.
enum SameDocumentVisitPolicy {

    enum Outcome: Equatable {
        /// Record a visit for where the tab is now.
        case record
        /// Nothing to record.
        case skip
        /// Take the tab's current entry as the baseline without recording: with
        /// no entry to compare against, a `replaceState` is indistinguishable
        /// from a `pushState`, and inventing a visit is the worse error. The
        /// next genuinely different entry records (TASK-91).
        case adoptBaseline
    }

    /// - Parameters:
    ///   - tabURL: where the tab is now.
    ///   - lastRecordedHistoryURL: the URL this tab last recorded — the same URL
    ///     is this tab's own recording, not a new page view.
    ///   - currentItem: identity of `backForwardList.currentItem`. Nil means the
    ///     document has no back/forward entry at all (a `loadHTMLString`
    ///     document has none), and without one nothing can be told apart.
    ///   - lastRecordedItem: identity of the entry that was current when this
    ///     tab last recorded. Nil when nothing has been recorded for this
    ///     document — a fresh tab, a favourite or peek tab promoted into a
    ///     space — or when the entry has gone (the reference is weak).
    static func outcome(tabURL: URL?,
                        lastRecordedHistoryURL: URL?,
                        currentItem: ObjectIdentifier?,
                        lastRecordedItem: ObjectIdentifier?) -> Outcome {
        guard let tabURL, tabURL != lastRecordedHistoryURL else { return .skip }
        guard let currentItem else { return .skip }
        guard let lastRecordedItem else { return .adoptBaseline }
        return currentItem == lastRecordedItem ? .skip : .record
    }
}
