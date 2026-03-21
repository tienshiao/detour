import Foundation
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "content-blocker")

extension Notification.Name {
    static let contentBlockerRulesDidChange = Notification.Name("contentBlockerRulesDidChange")
    static let contentBlockerStatusDidChange = Notification.Name("contentBlockerStatusDidChange")
}

class ContentBlockerManager {
    static let shared = ContentBlockerManager()

    let ruleStore = ContentRuleStore()
    let parser = EasyListParser()
    let whitelist: ContentBlockerWhitelist

    struct FilterList {
        let identifier: String
        let url: URL
        let name: String
    }

    static let filterLists: [FilterList] = [
        FilterList(identifier: "easylist", url: URL(string: "https://easylist.to/easylist/easylist.txt")!, name: "EasyList (ads)"),
        FilterList(identifier: "easyprivacy", url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!, name: "EasyPrivacy (trackers)"),
        FilterList(identifier: "easylist-cookie", url: URL(string: "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt")!, name: "Cookie notices"),
        FilterList(identifier: "urlhaus-filter", url: URL(string: "https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-online.txt")!, name: "Malicious URLs"),
    ]

    private let cacheDir: URL
    private let fetchInterval: TimeInterval = 86400 // 24 hours

    private init() {
        whitelist = ContentBlockerWhitelist(ruleStore: ruleStore)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cacheDir = appSupport.appendingPathComponent("Detour/ContentBlocker", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    private var pendingLookups = 0

    func initialize() {
        whitelist.loadFromDatabase()

        // For each list, try to look up compiled rules first, then fetch if needed
        pendingLookups = Self.filterLists.count
        for list in Self.filterLists {
            ruleStore.lookupOrCompile(identifier: list.identifier, rules: []) { [weak self] existingList in
                if existingList != nil {
                    // Already compiled, check if refresh needed
                    self?.refreshIfNeeded(list: list)
                    self?.lookupCompleted()
                } else {
                    // Try loading from cached text
                    self?.loadAndCompileFromCache(list: list) {
                        // If no cache, fetch
                        self?.fetchAndCompile(list: list)
                    }
                    // loadAndCompileFromCache/fetchAndCompile call reapplyRuleLists on success
                    self?.lookupCompleted()
                }
            }
        }

        // Recompile whitelist for all profiles
        for profile in TabStore.shared.profiles {
            whitelist.recompileWhitelistRules(profileID: profile.id) {}
        }
    }

    /// Called when an async WebKit store lookup finishes. Once all lookups are done,
    /// re-apply rules to any tabs that were created before the lookups completed.
    private func lookupCompleted() {
        pendingLookups -= 1
        if pendingLookups <= 0 {
            reapplyRuleLists()
        }
    }

    // MARK: - Apply Rules

    func applyRuleLists(to userContentController: WKUserContentController, profile: Profile) {
        // Add blocked resource tracker script
        userContentController.addUserScript(BlockedResourceTracker.userScript)

        guard profile.isAdBlockingEnabled else { return }

        let enabledLists: [(String, Bool)] = [
            ("easylist", profile.isEasyListEnabled),
            ("easyprivacy", profile.isEasyPrivacyEnabled),
            ("easylist-cookie", profile.isEasyListCookieEnabled),
            ("urlhaus-filter", profile.isMalwareFilterEnabled),
        ]

        for (identifier, isEnabled) in enabledLists {
            guard isEnabled, let list = ruleStore.getCachedList(identifier: identifier) else { continue }
            userContentController.add(list)
        }

        // Add whitelist (ignore-previous-rules) last so it overrides
        if let whitelistRules = whitelist.getWhitelistRuleList(profileID: profile.id) {
            userContentController.add(whitelistRules)
        }
    }

    func reapplyRuleLists() {
        NotificationCenter.default.post(name: .contentBlockerRulesDidChange, object: self)
    }

    // MARK: - Status Queries

    /// Number of rules parsed from the filter list text.
    func parsedRuleCount(for identifier: String) -> Int? {
        let key = "ContentBlocker.\(identifier).ruleCount"
        return UserDefaults.standard.object(forKey: key) as? Int
    }

    /// Number of rules actually compiled and active in WebKit.
    func compiledRuleCount(for identifier: String) -> Int? {
        ruleStore.compiledRuleCounts[identifier]
    }

    func lastFetchDate(for identifier: String) -> Date? {
        let key = "ContentBlocker.\(identifier).lastFetch"
        return UserDefaults.standard.object(forKey: key) as? Date
    }

    func isCompiled(identifier: String) -> Bool {
        ruleStore.getCachedList(identifier: identifier) != nil
    }

    // MARK: - Force Refresh

    private(set) var refreshingIdentifiers: Set<String> = []

    func forceRefreshAll() {
        for list in Self.filterLists {
            refreshingIdentifiers.insert(list.identifier)
            fetchAndCompile(list: list)
        }
        postStatusChange()
    }

    func clearCacheAndRedownload() {
        // Invalidate all compiled rules in WebKit
        ruleStore.invalidateAll()

        // Delete cached text files
        for list in Self.filterLists {
            let textFile = cacheDir.appendingPathComponent("\(list.identifier).txt")
            try? FileManager.default.removeItem(at: textFile)

            // Clear UserDefaults keys
            let id = list.identifier
            UserDefaults.standard.removeObject(forKey: "ContentBlocker.\(id).ruleCount")
            UserDefaults.standard.removeObject(forKey: "ContentBlocker.\(id).compiledRuleCount")
            UserDefaults.standard.removeObject(forKey: "ContentBlocker.\(id).lastFetch")
            UserDefaults.standard.removeObject(forKey: "ContentBlocker.\(id).etag")
        }

        postStatusChange()

        // Re-fetch everything
        forceRefreshAll()
    }

    private func postStatusChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .contentBlockerStatusDidChange, object: self)
        }
    }

    // MARK: - Fetch & Compile

    private func loadAndCompileFromCache(list: FilterList, onMiss: @escaping () -> Void) {
        let textFile = cacheDir.appendingPathComponent("\(list.identifier).txt")
        guard let text = try? String(contentsOf: textFile, encoding: .utf8) else {
            onMiss()
            return
        }

        let result = parser.parse(text: text)
        log.info("Compiling \(list.identifier, privacy: .public) from cache: \(result.rules.count) rules (\(result.skippedCount) skipped)")
        UserDefaults.standard.set(result.rules.count, forKey: "ContentBlocker.\(list.identifier).ruleCount")

        ruleStore.compile(identifier: list.identifier, rules: result.rules) { [weak self] compiled in
            if compiled != nil {
                self?.postStatusChange()
                self?.reapplyRuleLists()
            } else {
                onMiss()
            }
        }
    }

    private func fetchAndCompile(list: FilterList) {
        var request = URLRequest(url: list.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        // Add conditional fetch headers
        let etagKey = "ContentBlocker.\(list.identifier).etag"
        let lastFetchKey = "ContentBlocker.\(list.identifier).lastFetch"
        if let etag = UserDefaults.standard.string(forKey: etagKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastFetch = UserDefaults.standard.object(forKey: lastFetchKey) as? Date {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            request.setValue(formatter.string(from: lastFetch), forHTTPHeaderField: "If-Modified-Since")
        }

        log.info("Fetching \(list.identifier, privacy: .public) from \(list.url, privacy: .public)")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                log.error("Fetch error for \(list.identifier, privacy: .public): \(error.localizedDescription)")
                self.refreshingIdentifiers.remove(list.identifier)
                self.postStatusChange()
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                self.refreshingIdentifiers.remove(list.identifier)
                self.postStatusChange()
                return
            }

            if httpResponse.statusCode == 304 {
                log.info("\(list.identifier, privacy: .public) not modified")
                UserDefaults.standard.set(Date(), forKey: lastFetchKey)
                self.refreshingIdentifiers.remove(list.identifier)
                self.postStatusChange()
                return
            }

            guard httpResponse.statusCode == 200, let data, let text = String(data: data, encoding: .utf8) else {
                log.error("Bad response for \(list.identifier, privacy: .public): \(httpResponse.statusCode)")
                self.refreshingIdentifiers.remove(list.identifier)
                self.postStatusChange()
                return
            }

            // Cache raw text
            let textFile = self.cacheDir.appendingPathComponent("\(list.identifier).txt")
            try? text.write(to: textFile, atomically: true, encoding: .utf8)

            // Save ETag and timestamp
            if let etag = httpResponse.value(forHTTPHeaderField: "ETag") {
                UserDefaults.standard.set(etag, forKey: etagKey)
            }
            UserDefaults.standard.set(Date(), forKey: lastFetchKey)

            // Parse and compile
            let result = self.parser.parse(text: text)
            log.info("Parsed \(list.identifier, privacy: .public): \(result.rules.count) rules (\(result.skippedCount) skipped)")
            UserDefaults.standard.set(result.rules.count, forKey: "ContentBlocker.\(list.identifier).ruleCount")

            DispatchQueue.main.async {
                self.ruleStore.compile(identifier: list.identifier, rules: result.rules) { [weak self] compiled in
                    self?.refreshingIdentifiers.remove(list.identifier)
                    self?.postStatusChange()
                    if compiled != nil {
                        log.info("Compiled \(list.identifier, privacy: .public) successfully")
                        self?.reapplyRuleLists()
                    }
                }
            }
        }.resume()
    }

    private func refreshIfNeeded(list: FilterList) {
        let lastFetchKey = "ContentBlocker.\(list.identifier).lastFetch"
        if let lastFetch = UserDefaults.standard.object(forKey: lastFetchKey) as? Date,
           Date().timeIntervalSince(lastFetch) < fetchInterval {
            return
        }
        fetchAndCompile(list: list)
    }
}
