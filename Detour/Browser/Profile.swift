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

    private static let allURLsPattern = try? WKWebExtension.MatchPattern(string: "<all_urls>")

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

        // Always grant nativeMessaging at the context level so the polyfill bridge
        // can use browser.runtime.sendNativeMessage(). The user's grant/deny decision
        // for nativeMessaging is checked after the polyfill bridge logic.
        context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)

        // Restore saved permission decisions from DB — API permissions, requested
        // match patterns, <all_urls>, and the per-URL decisions taken at the
        // site-access prompt; leave unknown permissions for WebKit to prompt via
        // the delegate.
        // One read, partitioned by type: a `.url` key can be the same string as
        // a `.matchPattern` key, so the two must never share a dictionary.
        let saved = AppDatabase.shared.loadPermissions(extensionID: ext.id)
        let savedAPI = saved.statusByKey(type: .apiPermission)
        let savedPatterns = saved.statusByKey(type: .matchPattern)

        for permission in wkExt.requestedPermissions {
            if permission == .nativeMessaging { continue }
            if let saved = savedAPI[permission.rawValue] {
                context.setPermissionStatus(
                    saved == .granted ? .grantedExplicitly : .deniedExplicitly,
                    for: permission
                )
            }
        }

        for pattern in wkExt.requestedPermissionMatchPatterns {
            if let saved = savedPatterns[pattern.string] {
                context.setPermissionStatus(
                    saved == .granted ? .grantedExplicitly : .deniedExplicitly,
                    for: pattern
                )
            }
        }

        if let allURLs = Self.allURLsPattern {
            if let saved = savedPatterns["<all_urls>"], saved == .granted {
                context.setPermissionStatus(.grantedExplicitly, for: allURLs)
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
        // (`<all_urls>` / `*://*/*` match everything).
        let askablePatterns = wkExt.requestedPermissionMatchPatterns
            .union(wkExt.optionalPermissionMatchPatterns)
        for record in saved where record.permissionType == ExtensionPermissionType.url.rawValue {
            guard let url = URL(string: record.permissionKey) else { continue }
            guard askablePatterns.contains(where: { $0.matches(url) }) else {
                log.debug("Skipping stale URL grant \(record.permissionKey, privacy: .public) for \(ext.id, privacy: .public) — outside the manifest's host patterns")
                continue
            }
            let status = ExtensionPermissionStatus(rawValue: record.status) ?? .denied
            context.setPermissionStatus(status == .granted ? .grantedExplicitly : .deniedExplicitly, for: url)
        }

        // Grant content script match patterns as host permissions when the extension
        // has activeTab. In Chrome, extensions with active content scripts can use
        // tab APIs (detectLanguage, sendMessage, etc.) on pages where their content
        // scripts run. WebKit doesn't grant this implicitly, so we set the content
        // script match patterns as granted permissions on the context.
        if ext.manifest.permissions?.contains("activeTab") == true {
            for cs in ext.manifest.contentScripts ?? [] {
                for pattern in cs.matches {
                    if let matchPattern = try? WKWebExtension.MatchPattern(string: pattern) {
                        context.setPermissionStatus(.grantedExplicitly, for: matchPattern)
                    }
                }
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
    func unloadExtension(id: String, removeData: Bool = false) {
        guard let context = extensionContexts.removeValue(forKey: id) else { return }
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
        // Likewise the worker's keep-alive port: WebKit is not relied on to
        // report its disconnect once the context is gone.
        ExtensionManager.shared.closeKeepAlivePort(for: id, in: extensionController)
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
        unloadExtension(id: extensionID)
        // `loadExtensionContext`'s Bool means "has background content", not "loaded";
        // the dictionary is the source of truth for whether the reload took.
        _ = loadExtensionContext(ext)
        guard let context = extensionContexts[extensionID] else {
            log.error("Background recovery for \(extensionID, privacy: .public) could not reload its context; the extension is unloaded in profile \(self.name, privacy: .public) until it is re-enabled or the app relaunches")
            return
        }
        if attempts.count == Self.backgroundRecoveryLimit {
            log.error("Background content for \(extensionID, privacy: .public) has been reloaded \(attempts.count) times in \(Int(Self.backgroundRecoveryWindow)) s; further failures are not retried until that window passes")
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
