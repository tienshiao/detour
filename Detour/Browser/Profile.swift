import Foundation
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "EXT-LOAD")

// MARK: - UserAgentMode

enum UserAgentMode: Int {
    case detour = 0
    case safari = 1
    case custom = 2

    /// Constructs a Safari-matching UA using the real macOS version and Safari version.
    /// AppleWebKit/605.1.15 and Safari/605.1.15 are frozen tokens that never change.
    static var safariUserAgent: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "\(os.majorVersion)_\(os.minorVersion)_\(os.patchVersion)"
        let safariVersion: String
        if let bundle = Bundle(path: "/Applications/Safari.app"),
           let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String {
            safariVersion = version
        } else {
            safariVersion = "18.0"
        }
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X \(osString)) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) Safari/605.1.15"
    }

    static var detourAppName: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
        let major = version.split(separator: ".").first.map(String.init) ?? "1"
        return "Detour/\(major)"
    }

    /// Chrome-compatible UA for sites that block non-Chrome browsers (e.g. Chrome Web Store).
    static var chromeUserAgent: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "\(os.majorVersion)_\(os.minorVersion)_\(os.patchVersion)"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X \(osString)) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    }

    /// Domains that require a Chrome UA to function properly.
    static let chromeUASpoofDomains: Set<String> = [
        "chromewebstore.google.com",
        "clients2.google.com",
    ]

    /// Returns a Chrome UA if the given host requires spoofing, otherwise nil.
    static func spoofedUserAgent(for host: String?) -> String? {
        guard let host else { return nil }
        if chromeUASpoofDomains.contains(host) { return chromeUserAgent }
        return nil
    }
}

// MARK: - ArchiveThreshold

enum ArchiveThreshold: TimeInterval, CaseIterable {
    case twelveHours = 43200
    case twentyFourHours = 86400
    case sevenDays = 604800
    case thirtyDays = 2592000
    case never = 0
}

// MARK: - SleepThreshold

enum SleepThreshold: TimeInterval, CaseIterable {
    case fifteenMinutes = 900
    case thirtyMinutes = 1800
    case oneHour = 3600
    case twoHours = 7200
    case never = 0
}

// MARK: - SearchEngine

enum SearchEngine: Int, CaseIterable {
    case google = 0
    case duckDuckGo = 1
    case bing = 2
    case yahoo = 3
    case ecosia = 4
    case kagi = 5

    var name: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .yahoo: return "Yahoo"
        case .ecosia: return "Ecosia"
        case .kagi: return "Kagi"
        }
    }

    func searchURL(for query: String) -> URL? {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        switch self {
        case .google: return URL(string: "https://www.google.com/search?q=\(q)")
        case .duckDuckGo: return URL(string: "https://duckduckgo.com/?q=\(q)")
        case .bing: return URL(string: "https://www.bing.com/search?q=\(q)")
        case .yahoo: return URL(string: "https://search.yahoo.com/search?p=\(q)")
        case .ecosia: return URL(string: "https://www.ecosia.org/search?q=\(q)")
        case .kagi: return URL(string: "https://kagi.com/search?q=\(q)")
        }
    }

    func suggestionsURL(for query: String) -> URL? {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        switch self {
        case .google: return URL(string: "https://suggestqueries.google.com/complete/search?client=firefox&q=\(q)")
        case .duckDuckGo: return URL(string: "https://duckduckgo.com/ac/?q=\(q)&type=list")
        case .bing: return URL(string: "https://api.bing.com/osjson.aspx?query=\(q)")
        case .yahoo: return URL(string: "https://search.yahoo.com/sugg/gossip/gossip-us-ura/?command=\(q)&output=sd1")
        case .ecosia: return URL(string: "https://ac.ecosia.org/?q=\(q)&type=list")
        case .kagi: return URL(string: "https://kagi.com/api/autosuggest?q=\(q)")
        }
    }
}

// MARK: - Profile

class Profile {
    let id: UUID
    var name: String
    var userAgentMode: UserAgentMode
    var customUserAgent: String?
    var archiveThreshold: ArchiveThreshold
    var sleepThreshold: SleepThreshold
    var searchEngine: SearchEngine
    var searchSuggestionsEnabled: Bool
    var isPerTabIsolation: Bool
    var isIncognito: Bool
    var isAdBlockingEnabled: Bool
    var isEasyListEnabled: Bool
    var isEasyPrivacyEnabled: Bool
    var isEasyListCookieEnabled: Bool
    var isMalwareFilterEnabled: Bool
    var favorites: [Favorite] = []

    lazy var dataStore: WKWebsiteDataStore = {
        if isIncognito {
            return .nonPersistent()
        }
        return WKWebsiteDataStore(forIdentifier: id)
    }()

    // MARK: - Extension Controller

    /// Retained polyfill handler for APIs not natively provided by WKWebExtension.
    var polyfillHandler: ExtensionPolyfillHandler?

    /// Extension controller for this profile. Lazy-initialized like dataStore.
    /// Non-persistent for incognito profiles so extension data isn't written to disk.
    lazy var extensionController: WKWebExtensionController = {
        let config: WKWebExtensionController.Configuration
        if isIncognito {
            config = .nonPersistent()
        } else {
            config = WKWebExtensionController.Configuration(identifier: id)
        }
        config.defaultWebsiteDataStore = dataStore

        // Register favicon scheme handler so extensions can use chrome.runtime.getURL("/_favicon/...")
        config.webViewConfiguration.setURLSchemeHandler(
            FaviconSchemeHandler(), forURLScheme: FaviconSchemeHandler.scheme
        )

        // Inject polyfills for Chrome APIs not natively provided by WKWebExtension
        // (idle, notifications, history, management, fontSettings, sessions, search, offscreen, etc.)
        let handler = ExtensionPolyfillHandler(profile: self)
        self.polyfillHandler = handler
        let ucc = config.webViewConfiguration.userContentController
        ucc.addScriptMessageHandler(handler, contentWorld: .page, name: ExtensionPolyfillHandler.handlerName)
        let polyfillScript = WKUserScript(
            source: ExtensionAPIPolyfill.polyfillJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        ucc.addUserScript(polyfillScript)

        let controller = WKWebExtensionController(configuration: config)
        controller.delegate = ExtensionManager.shared
        return controller
    }()

    /// Extension contexts loaded in this profile's controller. ExtensionID → context.
    var extensionContexts: [String: WKWebExtensionContext] = [:]

    /// errorsDidUpdate observer tokens per extension id, removed in `unloadExtension`
    /// so a reload does not accumulate observers.
    private var extensionErrorObservers: [String: NSObjectProtocol] = [:]

    /// Load an extension context into this profile's controller (synchronous).
    /// Returns true if the context was loaded and background content should be started.
    @MainActor
    func loadExtensionContext(_ ext: WebExtension) -> Bool {
        guard let wkExt = ext.wkExtension else {
            log.error("Skipping \(ext.id, privacy: .public) — wkExtension is nil")
            return false
        }

        if extensionContexts[ext.id] != nil {
            log.info("Skipping \(ext.id, privacy: .public) — already loaded")
            return false
        }

        let context = WKWebExtensionContext(for: wkExt)
        context.uniqueIdentifier = ext.id
        context.isInspectable = true

        // Always grant nativeMessaging at the context level so the polyfill
        // bridge can use browser.runtime.sendNativeMessage() at all. A real
        // native host is gated separately, by `ExtensionManager.nativeHostAccess`
        // — and that gate looks only at the manifest's nativeMessaging
        // declaration: the user's saved nativeMessaging decision is not enforced
        // anywhere today. The restore loop below therefore skips the saved row,
        // so it cannot flip this grant to a denial the bridge would trip over.
        context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)

        // Grant content script match patterns as host permissions when the extension
        // has activeTab. In Chrome, extensions with active content scripts can use
        // tab APIs (detectLanguage, sendMessage, etc.) on pages where their content
        // scripts run. WebKit doesn't grant this implicitly, so we set the content
        // script match patterns as granted permissions on the context.
        //
        // Applied *before* the DB restore so the user's saved decisions take
        // precedence: a restored denial for the same or a broader pattern must
        // not be overwritten by this implicit grant.
        if ext.manifest.permissions?.contains("activeTab") == true {
            for cs in ext.manifest.contentScripts ?? [] {
                for pattern in cs.matches {
                    if let matchPattern = try? WKWebExtension.MatchPattern(string: pattern) {
                        context.setPermissionStatus(.grantedExplicitly, for: matchPattern)
                    }
                }
            }
        }

        // Restore saved permission decisions from DB — API permissions, host
        // match patterns (`<all_urls>` included), and the per-URL decisions taken
        // at the site-access prompt; leave undecided permissions for WebKit to
        // prompt via the delegate.
        // One read, partitioned by type: a `.url` key can be the same string as
        // a `.matchPattern` key, so the two must never share a dictionary.
        let saved = AppDatabase.shared.loadPermissions(extensionID: ext.id)
        let savedAPI = saved.statusByKey(type: .apiPermission)
        let savedPatterns = saved.statusByKey(type: .matchPattern)

        // Both the up-front manifest lists and the optional ones: WebKit prompts
        // for an `optional_permissions` / `optional_host_permissions` entry when
        // the extension calls `permissions.request`, and ExtensionManager saves
        // that answer under the very same key — so restoring only the requested
        // sets would re-prompt (or silently drop) every decision the user already
        // made about an optional permission on each context (re)load.
        //
        // A key in neither set is left alone (TASK-11's rule): rows are never
        // purged on extension update, and re-applying a grant the current
        // manifest no longer asks for would widen the extension's access.
        for permission in ext.askablePermissions {
            // nativeMessaging is granted unconditionally above so the polyfill
            // bridge works; a saved denial must not undo that grant.
            if permission == .nativeMessaging { continue }
            if let saved = savedAPI[permission.rawValue] {
                context.setPermissionStatus(saved.contextStatus, for: permission)
            }
        }

        // Walk the *saved rows*, not the manifest's patterns, and gate each row
        // by MATCH rather than by exact string membership: `permissions.request
        // ({origins})` prompts with the caller's own pattern verbatim (e.g.
        // "https://mail.example/*" under an optional "<all_urls>"), and
        // ExtensionManager saves the answer under that sub-pattern's string —
        // which is in neither manifest set. A row is restorable iff some
        // requested/optional manifest pattern matches it, the same rule the
        // `.url` rows below already use. Rows outside every manifest pattern
        // stay inert (TASK-11's rule): rows are never purged on extension
        // update, and re-applying a grant the current manifest no longer asks
        // for would widen the extension's access.
        //
        // `<all_urls>` needs no special case: WebKit reports it verbatim, which
        // is exactly the key the prompt saves, and it matches itself.
        //
        // Grants are applied before denials because a later overlapping write
        // *erases* the earlier entry from the other set: granted and denied
        // patterns live in separate dictionaries, and setting a (non-all-hosts)
        // pattern removes whatever the opposite dictionary held that the new
        // pattern subsumes. Denials therefore go last, so that no grant can
        // erase a denial (fail closed) — these are unordered rows, so the
        // two passes are the only thing making the outcome deterministic.
        let askablePatterns = ext.askableMatchPatterns   // hoisted once; reused by the .url loop
        for status in [ExtensionPermissionStatus.granted, .denied] {
            for (key, saved) in savedPatterns where saved == status {
                guard let pattern = try? WKWebExtension.MatchPattern(string: key) else { continue }
                guard askablePatterns.contains(where: { $0.matches(pattern) }) else {
                    log.debug("Skipping stale pattern decision \(key, privacy: .public) for \(ext.id, privacy: .public) — outside the manifest's host patterns")
                    continue
                }
                context.setPermissionStatus(status.contextStatus, for: pattern)
            }
        }

        // Site access granted or denied for specific URLs while browsing (the
        // promptForPermissionToAccess delegate). WebKit converts each URL to an
        // origin match pattern, so the decision is independent of the context's
        // base URL and survives the reload in recoverFromBackgroundLoadFailure.
        //
        // `setPermissionStatus(_:for: URL)` is not checked against the manifest
        // and rows are never purged on update, so a stale grant could otherwise
        // re-appear for an origin a newer manifest no longer asks about. The URL
        // is what the user was asked about, so it is matched against what the
        // extension may ask for: its requested and optional host patterns
        // (`<all_urls>` / `*://*/*` match everything). The gate is the hoisted
        // `askablePatterns` — the same set `ext.canAskForAccess(to:)` consults,
        // which Settings still uses for its site-access list.
        //
        // Grants before denials here too: WebKit widens each URL into an origin
        // match pattern, so two rows on one origin produce overlapping patterns
        // and the later write erases the earlier one from the opposite set —
        // the same ordering rule as the match-pattern loop above.
        let savedURLs = saved.filter { $0.permissionType == ExtensionPermissionType.url.rawValue }
        for status in [ExtensionPermissionStatus.granted, .denied] {
            for record in savedURLs
            where (ExtensionPermissionStatus(rawValue: record.status) ?? .denied) == status {
                guard let url = URL(string: record.permissionKey) else { continue }
                guard askablePatterns.contains(where: { $0.matches(url) }) else {
                    log.debug("Skipping stale URL grant \(record.permissionKey, privacy: .public) for \(ext.id, privacy: .public) — outside the manifest's host patterns")
                    continue
                }
                context.setPermissionStatus(status.contextStatus, for: url)
            }
        }

        do {
            try extensionController.load(context)
            extensionContexts[ext.id] = context
            // Observe extension context errors for debugging. `context.errors` is
            // cumulative but WebKit consolidates repeats and may clear it, so the
            // *log* is deduped by error content rather than by position; the set
            // lives with this observer (one per context) and dies with it.
            //
            // Recovery is deliberately not gated by that dedupe: it fires whenever
            // the array holds a background-load failure, and the rate limiter in
            // `recoverFromBackgroundLoadFailure` is its only suppressor. Tying it to
            // "newly logged" would make a failure that outlives the limiter's window
            // unrecoverable, because its key is already in the set.
            let extID = ext.id
            // Keys of the errors present at the previous notification; an error
            // is logged when it is not among them. Rebuilt from the current array
            // each time, so it is bounded by the array and a WebKit clear drops
            // the old keys by itself (a recurring failure is logged again).
            var loggedErrorKeys = Set<String>()
            extensionErrorObservers[extID] = NotificationCenter.default.addObserver(forName: WKWebExtensionContext.errorsDidUpdateNotification, object: context, queue: .main) { [weak self, weak context] _ in
                guard let context else { return }
                let errors = context.errors
                var currentKeys = Set<String>()
                var backgroundLoadFailed = false
                for error in errors {
                    let nsError = error as NSError
                    if nsError.domain == WKWebExtensionContext.errorDomain,
                       nsError.code == WKWebExtensionContext.Error.backgroundContentFailedToLoad.rawValue {
                        backgroundLoadFailed = true
                    }
                    let key = "\(nsError.domain)#\(nsError.code)#\(nsError.localizedDescription)"
                    currentKeys.insert(key)
                    guard !loggedErrorKeys.contains(key) else { continue }
                    log.error("Extension error [\(extID, privacy: .public)]: domain=\(nsError.domain, privacy: .public) code=\(nsError.code) \(nsError.localizedDescription, privacy: .public)")
                }
                loggedErrorKeys = currentKeys
                if backgroundLoadFailed, let self {
                    // Recover outside the notification callback: WebKit is still
                    // recording the error when it posts, so don't unload from here.
                    Task { @MainActor in
                        self.recoverFromBackgroundLoadFailure(extensionID: extID, failedContext: context)
                    }
                }
            }
            // Cache favicon permission for the scheme handler (checked per-request on any thread)
            if let host = context.baseURL.host,
               ext.manifest.permissions?.contains("favicon") == true {
                FaviconSchemeHandler.grantFaviconPermission(forWebKitHost: host)
            }
            log.info("Context loaded for \(ext.id, privacy: .public), baseURL: \(context.baseURL.absoluteString, privacy: .public)")
            return wkExt.hasBackgroundContent
        } catch {
            let nsError = error as NSError
            log.error("Failed to load \(ext.id, privacy: .public): domain=\(nsError.domain, privacy: .public) code=\(nsError.code)")
            return false
        }
    }

    /// Load an extension context into this profile. Background content loads on demand.
    @MainActor
    func loadExtension(_ ext: WebExtension) {
        loadExtensionContext(ext)
    }

    /// Unload an extension from this profile's controller.
    ///
    /// Returns the unloaded context's `baseURL` — the origin every page the
    /// extension had open is now stranded on — or nil when nothing was loaded.
    /// Callers either move those pages to the replacement context's origin
    /// (`retargetExtensionPages`) or close them (disable/uninstall).
    @discardableResult
    func unloadExtension(id: String, removeData: Bool = false) -> URL? {
        guard let context = extensionContexts.removeValue(forKey: id) else { return nil }
        if let token = extensionErrorObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(token)
        }
        if let host = context.baseURL.host {
            FaviconSchemeHandler.revokeFaviconPermission(forWebKitHost: host)
        }
        // The offscreen document belongs to this context's origin; a reloaded
        // context gets a new origin, so a lingering host would both leak a web
        // view and make offscreen.createDocument report a document that no
        // longer serves the extension.
        polyfillHandler?.closeOffscreenDocument(for: id)
        // The console rate-limit window too: a reloaded context starts its own
        // burst, and an extension that never comes back leaves no entry behind.
        polyfillHandler?.forgetConsoleRateLimit(for: id)
        // Likewise the worker's keep-alive port: WebKit is not relied on to
        // report its disconnect once the context is gone.
        ExtensionManager.shared.closeExtensionPorts(for: id, in: extensionController)
        try? extensionController.unload(context)
        if removeData {
            let allTypes = WKWebExtensionController.allExtensionDataTypes
            extensionController.fetchDataRecord(ofTypes: allTypes, for: context) { [weak self] record in
                guard let record, let self else { return }
                self.extensionController.removeData(ofTypes: allTypes, from: [record]) {
                    log.info("Removed extension data for \(id, privacy: .public)")
                }
            }
        }
        return context.baseURL
    }

    /// Unload every extension loaded in this profile. Called before the profile
    /// is discarded (`TabStore.deleteProfile`): each unload releases the state
    /// other owners key on this profile's controller (keep-alive ports in
    /// ExtensionManager, offscreen hosts, error observers), which would
    /// otherwise outlive the profile under a recyclable `ObjectIdentifier`.
    func unloadAllExtensions() {
        for id in Array(extensionContexts.keys) {
            unloadExtension(id: id)
        }
    }

    /// Get the extension context for a given extension ID in this profile.
    func extensionContext(for extensionID: String) -> WKWebExtensionContext? {
        extensionContexts[extensionID]
    }

    /// The id of the loaded extension whose context serves pages from the
    /// given origin, i.e. whose `baseURL` has that scheme and host. WebKit
    /// assigns each loaded context a fresh `webkit-extension://<UUID>/` base
    /// URL (not the `uniqueIdentifier`), so this is the only trustworthy way
    /// to attribute an extension page to its extension. Nil when no loaded
    /// context matches, including after the context was unloaded.
    func extensionID(forOriginScheme scheme: String, host: String) -> String? {
        guard !host.isEmpty else { return nil }
        return extensionContexts.first { _, context in
            context.baseURL.scheme?.caseInsensitiveCompare(scheme) == .orderedSame
                && context.baseURL.host?.caseInsensitiveCompare(host) == .orderedSame
        }?.key
    }

    // MARK: - Extension pages open in tabs

    /// Where a tab of this profile showing an extension page lives. A tab can be
    /// in four places, and an extension page can be in any of them: a space's
    /// normal tabs, a space's pinned entries, a favourite's backing tab (which is
    /// detached from `space.tabs`), and a tab's peek overlay. Consumers that
    /// mutate through `TabStore` need the container, not just the tab, to pick
    /// the right API (`closeTab` / `closePinnedTab` / `deactivateFavorite`).
    enum ExtensionPageLocation {
        case tab(Space, BrowserTab)
        case pinned(Space, PinnedEntry, BrowserTab)
        case favorite(Favorite, BrowserTab)
        case peek(host: BrowserTab, BrowserTab)

        var tab: BrowserTab {
            switch self {
            case .tab(_, let tab), .pinned(_, _, let tab), .favorite(_, let tab), .peek(_, let tab):
                return tab
            }
        }
    }

    /// Every tab in this profile currently showing a page served from `host`,
    /// i.e. from one context's `webkit-extension://<host>/` origin, with where
    /// it lives. Spaces are global, so only those referencing this profile are
    /// walked; favourites are per-profile already.
    func extensionPageLocations(forOriginHost host: String) -> [ExtensionPageLocation] {
        var result: [ExtensionPageLocation] = []

        func considerPeek(of host_: BrowserTab) {
            if let peek = host_.peekTab, peek.showsExtensionPage(ofOriginHost: host) {
                result.append(.peek(host: host_, peek))
            }
        }

        for space in TabStore.shared.spaces where space.profileID == id {
            for tab in space.tabs {
                if tab.showsExtensionPage(ofOriginHost: host) { result.append(.tab(space, tab)) }
                considerPeek(of: tab)
            }
            for entry in space.pinnedEntries {
                guard let tab = entry.tab else { continue }
                if tab.showsExtensionPage(ofOriginHost: host) { result.append(.pinned(space, entry, tab)) }
                considerPeek(of: tab)
            }
        }
        for favorite in favorites {
            guard let tab = favorite.tab else { continue }
            if tab.showsExtensionPage(ofOriginHost: host) { result.append(.favorite(favorite, tab)) }
            considerPeek(of: tab)
        }
        return result
    }

    /// Move every page open on `oldBase`'s origin onto `newBase`'s, keeping each
    /// page's path so the user stays where they were.
    ///
    /// A reloaded context is a *new* origin. The pages left on the old one are
    /// dead — their native `chrome.*` bindings went with the old context and the
    /// polyfill bridge resolves an extension by the loaded contexts' base URLs,
    /// so it rejects them — and they cannot simply be navigated, because their
    /// web views were built from the old context's configuration and cannot load
    /// the new origin at all. `BrowserTab.retarget` therefore drops each web view
    /// and leaves the tab sleeping on the rewritten URL; the rehost notification
    /// makes each window re-select its own displayed tab, and the display path
    /// rebuilds it from the new context's configuration. Nothing here touches a
    /// web view, so a tab whose view another window owns (this one shows a
    /// snapshot) or a tab that is already asleep is handled identically.
    ///
    /// The pinned entries' and favourites' own URLs (`pinnedURL` / `url`) are
    /// rewritten too — dormant or not — since they are what a later reactivation
    /// loads, and they are what a "same page" comparison (`isAtPinnedHome`) uses.
    ///
    /// The rehost notification is posted on the next main-queue turn rather than
    /// inline: a caller reloads the context and then announces the profile's
    /// live tabs to it (`didReloadExtensionContext`), and a synchronous post
    /// would have the window wake the displayed tab first — announcing it once
    /// from `wake()` and again from that sweep. Deferred, every rehosted tab is
    /// still asleep when the sweep runs and announces itself exactly once, on
    /// wake.
    @MainActor
    func retargetExtensionPages(from oldBase: URL, to newBase: URL) {
        // Not conditioned on the two origins differing (WebKit always mints a new
        // UUID): even if they somehow matched, the open pages' web views still
        // belong to the *unloaded* context and must be rebuilt from the new one.
        guard let oldHost = oldBase.host else { return }
        let store = TabStore.shared
        let profileSpaces = store.spaces.filter { $0.profileID == id }

        var affectedSpaceIDs = Set<UUID>()
        var retargetedTabIDs = Set<UUID>()
        for location in extensionPageLocations(forOriginHost: oldHost) {
            let tab = location.tab
            guard let url = tab.webView?.url ?? tab.url,
                  let rewritten = rewriteExtensionPageURL(url, from: oldBase, to: newBase) else { continue }
            tab.retarget(to: rewritten)
            retargetedTabIDs.insert(tab.id)
            switch location {
            case .tab(let space, _), .pinned(let space, _, _):
                affectedSpaceIDs.insert(space.id)
            case .favorite:
                // A favourite is shown in every space of the profile, and its
                // backing tab's `spaceID` is only the space it was first
                // activated in — a window on any of the profile's spaces may be
                // displaying it.
                affectedSpaceIDs.formUnion(profileSpaces.map(\.id))
            case .peek(let host, _):
                // The peek is rebuilt from the host's persisted `peekURL` (its web
                // view is gone), so that must point at the new origin too. The
                // window that shows the host re-presents the overlay on re-select.
                host.peekURL = rewritten
                retargetedTabIDs.insert(host.id)
                if let spaceID = host.spaceID { affectedSpaceIDs.insert(spaceID) }
                else { affectedSpaceIDs.formUnion(profileSpaces.map(\.id)) }
            }
        }

        var rewroteBookmarks = false
        for space in profileSpaces {
            for entry in space.pinnedEntries {
                if let rewritten = rewriteExtensionPageURL(entry.pinnedURL, from: oldBase, to: newBase) {
                    entry.pinnedURL = rewritten
                    rewroteBookmarks = true
                }
            }
        }
        for favorite in favorites {
            if let rewritten = rewriteExtensionPageURL(favorite.url, from: oldBase, to: newBase) {
                favorite.url = rewritten
                rewroteBookmarks = true
            }
        }
        if rewroteBookmarks { store.scheduleSave() }

        guard !affectedSpaceIDs.isEmpty else { return }

        log.info("Rehosted \(retargetedTabIDs.count) extension page tab(s) across \(affectedSpaceIDs.count) space(s) of profile \(self.name, privacy: .public) onto \(newBase.absoluteString, privacy: .public)")
        for spaceID in affectedSpaceIDs {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .spaceTabsNeedRehost, object: nil,
                    userInfo: ["spaceID": spaceID, "tabIDs": retargetedTabIDs]
                )
            }
        }
    }

    // MARK: - Background content recovery

    /// Timestamps of recent background-load recoveries per extension id, for rate limiting.
    private var backgroundRecoveryAttempts: [String: [Date]] = [:]
    private static let backgroundRecoveryWindow: TimeInterval = 10 * 60
    private static let backgroundRecoveryLimit = 3

    /// Recover from `WKWebExtensionContextError.backgroundContentFailedToLoad`.
    ///
    /// Observed with 1Password (2026-09-11): after WebKit unloads an idle
    /// background service worker, the worker's registration can survive in the
    /// network process bound to the old content process. Every later wake then
    /// re-registers, gets that registration back as "directly reusable", never
    /// starts a worker, and fails 30 s later when WebKit closes the hidden page,
    /// once a minute, forever. The registration is keyed by the context's base
    /// URL, and WebKit assigns a fresh one to each context, so reloading the
    /// context in this profile sidesteps the stale registration entirely. Rate
    /// limited so a background script that genuinely fails to evaluate cannot
    /// keep the extension reloading; once the limit is hit, the failing context
    /// stays loaded and is retried again after the window passes.
    ///
    /// `failedContext` is the context that reported the failure: a stale or
    /// duplicate notification must not reload the replacement context.
    @MainActor
    func recoverFromBackgroundLoadFailure(extensionID: String, failedContext: WKWebExtensionContext) {
        guard extensionContexts[extensionID] === failedContext,
              let ext = ExtensionManager.shared.extension(withID: extensionID) else { return }

        let now = Date()
        var attempts = (backgroundRecoveryAttempts[extensionID] ?? []).filter {
            now.timeIntervalSince($0) < Self.backgroundRecoveryWindow
        }
        guard attempts.count < Self.backgroundRecoveryLimit else {
            // Announced at .error when the last allowed reload ran; every later
            // errorsDidUpdate for the still-failing context lands here.
            log.debug("Background content for \(extensionID, privacy: .public) still failing; not reloading (\(attempts.count) reloads in the last \(Int(Self.backgroundRecoveryWindow)) s)")
            return
        }
        attempts.append(now)
        backgroundRecoveryAttempts[extensionID] = attempts

        log.notice("Background content for \(extensionID, privacy: .public) failed to load; reloading its context in profile \(self.name, privacy: .public) (attempt \(attempts.count) of \(Self.backgroundRecoveryLimit))")
        let oldBase = unloadExtension(id: extensionID)
        // `loadExtensionContext`'s Bool means "has background content", not "loaded";
        // the dictionary is the source of truth for whether the reload took.
        _ = loadExtensionContext(ext)
        guard let context = extensionContexts[extensionID] else {
            log.error("Background recovery for \(extensionID, privacy: .public) could not reload its context; the extension is unloaded in profile \(self.name, privacy: .public) until it is re-enabled or the app relaunches")
            // Any page it had open stays on the dead origin: there is no new
            // origin to move it to, and closing the user's tabs over a failure
            // we mean to retry would be worse than leaving them.
            return
        }
        if attempts.count == Self.backgroundRecoveryLimit {
            log.error("Background content for \(extensionID, privacy: .public) has been reloaded \(attempts.count) times in \(Int(Self.backgroundRecoveryWindow)) s; further failures are not retried until that window passes")
        }
        // Before `didReloadExtensionContext`, deliberately: retargeting puts each
        // rehosted tab to sleep (and defers the window's re-select to the next
        // main-queue turn), and `notifyExistingTabs` skips sleeping tabs, so each
        // one announces itself exactly once — on wake — instead of being
        // announced here and again from `wake()`.
        if let oldBase {
            retargetExtensionPages(from: oldBase, to: context.baseURL)
        }
        ExtensionManager.shared.didReloadExtensionContext(context, in: self)
        context.loadBackgroundContent { error in
            if let error {
                let nsError = error as NSError
                log.error("Background reload for \(extensionID, privacy: .public) failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code)")
            } else {
                log.notice("Background content for \(extensionID, privacy: .public) reloaded")
            }
        }
    }

    init(id: UUID = UUID(), name: String, userAgentMode: UserAgentMode = .detour,
         customUserAgent: String? = nil, archiveThreshold: ArchiveThreshold = .twelveHours,
         sleepThreshold: SleepThreshold = .oneHour, searchEngine: SearchEngine = .google,
         searchSuggestionsEnabled: Bool = true,
         isPerTabIsolation: Bool = false, isIncognito: Bool = false,
         isAdBlockingEnabled: Bool = true, isEasyListEnabled: Bool = true,
         isEasyPrivacyEnabled: Bool = true, isEasyListCookieEnabled: Bool = true,
         isMalwareFilterEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.userAgentMode = userAgentMode
        self.customUserAgent = customUserAgent
        self.archiveThreshold = archiveThreshold
        self.sleepThreshold = sleepThreshold
        self.searchEngine = searchEngine
        self.searchSuggestionsEnabled = searchSuggestionsEnabled
        self.isPerTabIsolation = isPerTabIsolation
        self.isIncognito = isIncognito
        self.isAdBlockingEnabled = isAdBlockingEnabled
        self.isEasyListEnabled = isEasyListEnabled
        self.isEasyPrivacyEnabled = isEasyPrivacyEnabled
        self.isEasyListCookieEnabled = isEasyListCookieEnabled
        self.isMalwareFilterEnabled = isMalwareFilterEnabled
    }

    func resolvedUserAgent() -> String? {
        switch userAgentMode {
        case .detour:
            return "\(UserAgentMode.safariUserAgent) \(UserAgentMode.detourAppName)"
        case .safari:
            return UserAgentMode.safariUserAgent
        case .custom:
            return customUserAgent ?? ""
        }
    }

    func toRecord() -> ProfileRecord {
        ProfileRecord(
            id: id.uuidString,
            name: name,
            userAgentMode: userAgentMode.rawValue,
            customUserAgent: customUserAgent,
            archiveThreshold: archiveThreshold.rawValue,
            sleepThreshold: sleepThreshold.rawValue,
            searchEngine: searchEngine.rawValue,
            searchSuggestionsEnabled: searchSuggestionsEnabled,
            isPerTabIsolation: isPerTabIsolation,
            isAdBlockingEnabled: isAdBlockingEnabled,
            isEasyListEnabled: isEasyListEnabled,
            isEasyPrivacyEnabled: isEasyPrivacyEnabled,
            isEasyListCookieEnabled: isEasyListCookieEnabled,
            isMalwareFilterEnabled: isMalwareFilterEnabled
        )
    }

    static func from(record: ProfileRecord) -> Profile? {
        guard let id = UUID(uuidString: record.id) else { return nil }
        let mode = UserAgentMode(rawValue: record.userAgentMode) ?? .detour
        let threshold = ArchiveThreshold(rawValue: record.archiveThreshold) ?? .twelveHours
        let sleepThreshold = SleepThreshold(rawValue: record.sleepThreshold) ?? .oneHour
        let engine = SearchEngine(rawValue: record.searchEngine) ?? .google
        return Profile(
            id: id,
            name: record.name,
            userAgentMode: mode,
            customUserAgent: record.customUserAgent,
            archiveThreshold: threshold,
            sleepThreshold: sleepThreshold,
            searchEngine: engine,
            searchSuggestionsEnabled: record.searchSuggestionsEnabled,
            isPerTabIsolation: record.isPerTabIsolation,
            isAdBlockingEnabled: record.isAdBlockingEnabled,
            isEasyListEnabled: record.isEasyListEnabled,
            isEasyPrivacyEnabled: record.isEasyPrivacyEnabled,
            isEasyListCookieEnabled: record.isEasyListCookieEnabled,
            isMalwareFilterEnabled: record.isMalwareFilterEnabled
        )
    }
}
