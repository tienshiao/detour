import Foundation
import WebKit

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
}

// MARK: - ArchiveThreshold

enum ArchiveThreshold: TimeInterval, CaseIterable {
    case twelveHours = 43200
    case twentyFourHours = 86400
    case sevenDays = 604800
    case thirtyDays = 2592000
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
    var searchEngine: SearchEngine
    var searchSuggestionsEnabled: Bool
    let isIncognito: Bool

    lazy var dataStore: WKWebsiteDataStore = {
        if isIncognito {
            return .nonPersistent()
        }
        return WKWebsiteDataStore(forIdentifier: id)
    }()

    init(id: UUID = UUID(), name: String, userAgentMode: UserAgentMode = .detour,
         customUserAgent: String? = nil, archiveThreshold: ArchiveThreshold = .twelveHours,
         searchEngine: SearchEngine = .google, searchSuggestionsEnabled: Bool = true,
         isIncognito: Bool = false) {
        self.id = id
        self.name = name
        self.userAgentMode = userAgentMode
        self.customUserAgent = customUserAgent
        self.archiveThreshold = archiveThreshold
        self.searchEngine = searchEngine
        self.searchSuggestionsEnabled = searchSuggestionsEnabled
        self.isIncognito = isIncognito
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
            searchEngine: searchEngine.rawValue,
            searchSuggestionsEnabled: searchSuggestionsEnabled
        )
    }

    static func from(record: ProfileRecord) -> Profile? {
        guard let id = UUID(uuidString: record.id) else { return nil }
        let mode = UserAgentMode(rawValue: record.userAgentMode) ?? .detour
        let threshold = ArchiveThreshold(rawValue: record.archiveThreshold) ?? .twelveHours
        let engine = SearchEngine(rawValue: record.searchEngine) ?? .google
        return Profile(
            id: id,
            name: record.name,
            userAgentMode: mode,
            customUserAgent: record.customUserAgent,
            archiveThreshold: threshold,
            searchEngine: engine,
            searchSuggestionsEnabled: record.searchSuggestionsEnabled
        )
    }
}
