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

    lazy var dataStore: WKWebsiteDataStore = {
        if isIncognito {
            return .nonPersistent()
        }
        return WKWebsiteDataStore(forIdentifier: id)
    }()

    // MARK: - Extension Controller

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
        let controller = WKWebExtensionController(configuration: config)
        controller.delegate = ExtensionManager.shared
        return controller
    }()

    /// Extension contexts loaded in this profile's controller. ExtensionID → context.
    var extensionContexts: [String: WKWebExtensionContext] = [:]

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

        for permission in wkExt.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in wkExt.requestedPermissionMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        if let allURLs = Self.allURLsPattern {
            context.setPermissionStatus(.grantedExplicitly, for: allURLs)
        }

        do {
            try extensionController.load(context)
            extensionContexts[ext.id] = context
            log.info("Context loaded for \(ext.id, privacy: .public), baseURL: \(context.baseURL.absoluteString, privacy: .public)")
            return wkExt.hasBackgroundContent
        } catch {
            let nsError = error as NSError
            log.error("Failed to load \(ext.id, privacy: .public): domain=\(nsError.domain, privacy: .public) code=\(nsError.code)")
            return false
        }
    }

    /// Start background content for an extension. Times out after 10s to avoid blocking forever.
    @MainActor
    func startBackgroundContent(for ext: WebExtension) async {
        guard let context = extensionContexts[ext.id] else { return }

        log.info("Loading background content for \(ext.id, privacy: .public)")
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in
                    try await context.loadBackgroundContent()
                }
                group.addTask { @MainActor in
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    throw CancellationError()
                }
                try await group.next()
                group.cancelAll()
            }
            log.info("Background content loaded for \(ext.id, privacy: .public)")
        } catch {
            log.error("Background content failed/timed out for \(ext.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        if !context.errors.isEmpty {
            log.error("Context errors for \(ext.id, privacy: .public): \(context.errors.map { $0.localizedDescription }, privacy: .public)")
        }
    }

    /// Load context + start background in one call. Used by install and enable flows.
    @MainActor
    func loadExtension(_ ext: WebExtension) async {
        let needsBackground = loadExtensionContext(ext)
        if needsBackground {
            await startBackgroundContent(for: ext)
        }
    }

    /// Unload an extension from this profile's controller.
    func unloadExtension(id: String) {
        guard let context = extensionContexts.removeValue(forKey: id) else { return }
        try? extensionController.unload(context)
    }

    /// Get the extension context for a given extension ID in this profile.
    func extensionContext(for extensionID: String) -> WKWebExtensionContext? {
        extensionContexts[extensionID]
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
