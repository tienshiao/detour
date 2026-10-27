import Foundation
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "content-blocker")

extension Notification.Name {
    static let contentBlockerRulesDidChange = Notification.Name("contentBlockerRulesDidChange")
    static let contentBlockerStatusDidChange = Notification.Name("contentBlockerStatusDidChange")
}

/// `-[WKWebpagePreferences _setContentBlockersEnabled:]`, declared in WebKit's
/// `WKWebpagePreferencesPrivate.h` (macOS 10.15+). Safari's per-site content
/// blocker switch is this setter; there is no public equivalent.
@objc protocol WKWebpagePreferencesContentBlockerShim {
    @objc(_setContentBlockersEnabled:)
    func setContentBlockersEnabled(_ enabled: Bool)
}

/// Orders the compiles of each filter list by the age of their text
/// (TASK-200).
///
/// A list's text is parsed off the main queue, so a compile of older text
/// (the cached file read at launch) can be ready after one of newer text (a
/// download that arrived meanwhile). `ContentRuleStore` runs a list's
/// compiles in the order they are asked for, so the older one would replace
/// the newer one. A ticket is taken on the main queue when the text is
/// chosen; a compile asks `shouldStartCompile` on the main queue just before
/// it is handed to the store, and is dropped when a compile of newer text
/// already started.
///
/// Clear Cache & Redownload refuses every ticket taken before it (TASK-202):
/// that text was read before the cache was deleted, and a compile of it
/// would bring back the lists the user cleared.
struct FilterListCompileOrder {
    private var lastTicket = 0
    /// Tickets up to this one are refused: taken before the last clear.
    private var lastSupersededTicket = 0
    /// The ticket of the newest compile started, by list identifier.
    private var started: [String: Int] = [:]

    /// A ticket newer than every ticket taken before, for any list.
    mutating func takeTicket() -> Int {
        lastTicket += 1
        return lastTicket
    }

    /// Whether the compile of the text ticketed `ticket` may start: false
    /// when a compile of the list's newer text has started, or the ticket
    /// was taken before the last clear. Records the start when true.
    mutating func shouldStartCompile(ticket: Int, for identifier: String) -> Bool {
        if isSuperseded(ticket: ticket) { return false }
        if let newest = started[identifier], newest > ticket { return false }
        started[identifier] = ticket
        return true
    }

    /// Clear Cache & Redownload: refuses every ticket taken so far.
    mutating func supersedeTicketsTaken() {
        lastSupersededTicket = lastTicket
    }

    /// Whether the ticket was taken before the last clear.
    func isSuperseded(ticket: Int) -> Bool {
        ticket <= lastSupersededTicket
    }
}

/// The refreshes Settings shows as "Updating...", by list (TASK-202).
///
/// A refresh is one fetch the user asked for (Update Now, Clear Cache &
/// Redownload). Every way that fetch ends (no change, an error, a dropped
/// or superseded compile, a compile) ends its refresh by its token, so a
/// fetch from before a newer refresh of the same list, ending late, leaves
/// the newer one running.
struct FilterListRefreshes {
    private var lastToken = 0
    /// The token of each list's running refresh.
    private var running: [String: Int] = [:]

    /// The lists being refreshed.
    var identifiers: Set<String> { Set(running.keys) }

    /// Starts a refresh of the list, taking over from one already running,
    /// and returns its token.
    mutating func begin(_ identifier: String) -> Int {
        lastToken += 1
        running[identifier] = lastToken
        return lastToken
    }

    /// Ends the list's refresh `token`; a refresh begun since keeps running.
    mutating func end(_ identifier: String, token: Int) {
        if running[identifier] == token { running[identifier] = nil }
    }
}

class ContentBlockerManager {
    static let shared = ContentBlockerManager()

    let ruleStore = ContentRuleStore(storage: .current)
    let parser = EasyListParser()
    let whitelist: ContentBlockerWhitelist
    /// Fetch bookkeeping (etag, last fetch, rule counts): the standard defaults
    /// in the default data directory, the data directory's own suite elsewhere.
    private let defaults = ContentBlockerStorage.current.defaults

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
        whitelist = ContentBlockerWhitelist()
        // Detour/ContentBlocker in the default data directory, as before; an
        // isolated data directory downloads into its own (TASK-36).
        cacheDir = ContentBlockerStorage.current.filterListCacheDirectory
    }

    private var pendingLookups = 0

    func initialize() {
        // Drop the per-profile whitelist rule lists earlier builds compiled: the
        // per-site switch is preferences-based now and nothing else deletes them.
        ruleStore.removeRetiredLists(withPrefix: "content-blocker-whitelist-")

        // For each list, try to look up compiled rules first, then fetch if needed
        pendingLookups = Self.filterLists.count
        for list in Self.filterLists {
            // Refused once Clear Cache & Redownload runs: a look-up answered
            // after it finds nothing, and its redownload stands in for the
            // launch compile and the fallback download (TASK-202).
            let lookUpTicket = compileOrder.takeTicket()
            ruleStore.lookUpList(identifier: list.identifier) { [weak self] existingLists in
                guard let self else { return }
                guard !self.compileOrder.isSuperseded(ticket: lookUpTicket) else {
                    log.info("Not compiling \(list.identifier, privacy: .public) at launch: the cache was cleared")
                    return self.lookupCompleted()
                }
                let recordedFormat = self.defaults.object(forKey: self.rulesFormatKey(list.identifier)) as? Int
                if !existingLists.isEmpty && Self.shouldReuseCompiledList(recordedFormat: recordedFormat) {
                    // Already compiled, check if refresh needed
                    self.refreshIfNeeded(list: list)
                    self.lookupCompleted()
                } else {
                    if !existingLists.isEmpty {
                        // Compiled by an older parser: the found lists stay
                        // attached until the recompile replaces them.
                        log.info("Recompiling \(list.identifier, privacy: .public): compiled from rules format \(recordedFormat ?? 0), current \(EasyListParser.rulesFormatVersion)")
                    }
                    // Try loading from cached text
                    self.loadAndCompileFromCache(list: list) { [weak self] in
                        // No usable cache: fetch the list in full. A
                        // conditional request would answer 304 for an
                        // unchanged list and leave nothing to compile.
                        self?.fetchAndCompile(list: list, conditional: false)
                    }
                    // loadAndCompileFromCache/fetchAndCompile call reapplyRuleLists on success
                    self.lookupCompleted()
                }
            }
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

    /// Adds the profile's enabled filter lists to `userContentController`.
    ///
    /// Adds no user script: this is called again on every rules change (after
    /// `removeAllContentRuleLists`), and the blocked-load counter now comes from
    /// WebKit's own per-list action callback instead (TASK-69).
    func applyRuleLists(to userContentController: WKUserContentController, profile: Profile) {
        for list in Self.ruleLists(for: profile, in: ruleStore) {
            userContentController.add(list)
        }
    }

    /// The compiled rule lists `profile` has switched on: **every chunk** of
    /// every enabled filter list (a list over the rule cap is several rule
    /// lists, TASK-145), and none when the master switch is off.
    static func ruleLists(for profile: Profile, in ruleStore: ContentRuleStore) -> [WKContentRuleList] {
        guard profile.isAdBlockingEnabled else { return [] }

        let enabledLists: [(String, Bool)] = [
            ("easylist", profile.isEasyListEnabled),
            ("easyprivacy", profile.isEasyPrivacyEnabled),
            ("easylist-cookie", profile.isEasyListCookieEnabled),
            ("urlhaus-filter", profile.isMalwareFilterEnabled),
        ]

        return enabledLists.flatMap { identifier, isEnabled in
            isEnabled ? ruleStore.cachedLists(forList: identifier) : []
        }
    }

    // MARK: - Per-site switch (TASK-69)

    /// Turns content blocking off for this navigation when its host is
    /// whitelisted for `profile`.
    ///
    /// `-[WKWebpagePreferences _setContentBlockersEnabled:]` (SPI, macOS 10.15+)
    /// disables every content rule list for the main-frame document the
    /// navigation creates and for every subresource and subframe load under it —
    /// which an `ignore-previous-rules` rule in a separate rule list cannot do,
    /// because WebKit evaluates each list independently and merges their Block
    /// results.
    ///
    /// Call only for main-frame navigations: a subframe's preferences do not
    /// govern the document's blocking.
    func configure(_ preferences: WKWebpagePreferences, forNavigationTo url: URL?, profile: Profile) {
        Self.configure(preferences, forNavigationTo: url, profileID: profile.id, whitelist: whitelist)
    }

    /// `configure(_:forNavigationTo:profile:)` against any whitelist, so tests
    /// run the production decision and SPI call rather than a copy of them.
    static func configure(_ preferences: WKWebpagePreferences, forNavigationTo url: URL?, profileID: UUID,
                          whitelist: ContentBlockerWhitelist) {
        if !contentBlockersEnabled(forNavigationTo: url, profileID: profileID, whitelist: whitelist) {
            setContentBlockersEnabled(false, on: preferences)
        }
    }

    /// Whether a main-frame navigation to `url` in `profileID` keeps its content
    /// rule lists: false only when the host is whitelisted. Read from the store
    /// at every navigation, with nothing compiled or cached from it, so a
    /// dropped Private session (`SiteSettingsStore.discardPrivateSession`) is
    /// in effect at the next Private window's first load (TASK-195).
    static func contentBlockersEnabled(forNavigationTo url: URL?, profileID: UUID,
                                       whitelist: ContentBlockerWhitelist) -> Bool {
        guard let host = url?.host else { return true }
        return !whitelist.isWhitelisted(host: host, profileID: profileID)
    }

    /// The SPI call itself, guarded so a WebKit that dropped the selector logs
    /// once instead of trapping.
    static func setContentBlockersEnabled(_ enabled: Bool, on preferences: WKWebpagePreferences) {
        let selector = NSSelectorFromString("_setContentBlockersEnabled:")
        guard preferences.responds(to: selector) else {
            reportMissingContentBlockerSPI()
            return
        }
        unsafeBitCast(preferences, to: WKWebpagePreferencesContentBlockerShim.self)
            .setContentBlockersEnabled(enabled)
    }

    private static var reportedMissingSPI = false

    private static func reportMissingContentBlockerSPI() {
        guard !reportedMissingSPI else { return }
        reportedMissingSPI = true
        log.error("WKWebpagePreferences does not respond to _setContentBlockersEnabled: — the per-site content blocker switch cannot take effect")
    }

    /// Whether a list found compiled in WebKit's store at launch is used as
    /// it is: only when it was compiled from the parser's current output
    /// (`EasyListParser.rulesFormatVersion`, recorded by every successful
    /// compile). Otherwise it is recompiled from the cached list text: a
    /// refresh alone would not do it, since an unchanged list answers 304 and
    /// is never compiled again. A list compiled before the format was
    /// recorded (nil) is from before TASK-199.
    static func shouldReuseCompiledList(recordedFormat: Int?) -> Bool {
        recordedFormat == EasyListParser.rulesFormatVersion
    }

    private func rulesFormatKey(_ identifier: String) -> String {
        "ContentBlocker.\(identifier).rulesFormat"
    }

    private func recordRulesFormat(of identifier: String) {
        defaults.set(EasyListParser.rulesFormatVersion, forKey: rulesFormatKey(identifier))
    }

    func reapplyRuleLists() {
        NotificationCenter.default.post(name: .contentBlockerRulesDidChange, object: self)
    }

    // MARK: - Status Queries

    /// Number of rules parsed from the filter list text.
    func parsedRuleCount(for identifier: String) -> Int? {
        let key = "ContentBlocker.\(identifier).ruleCount"
        return defaults.object(forKey: key) as? Int
    }

    /// Number of rules actually compiled and active in WebKit, over every
    /// chunk of the list.
    func compiledRuleCount(for identifier: String) -> Int? {
        ruleStore.compiledRuleCount(forList: identifier)
    }

    func lastFetchDate(for identifier: String) -> Date? {
        let key = "ContentBlocker.\(identifier).lastFetch"
        return defaults.object(forKey: key) as? Date
    }

    func isCompiled(identifier: String) -> Bool {
        ruleStore.isCompiled(list: identifier)
    }

    // MARK: - Force Refresh

    /// Main queue only.
    private var refreshes = FilterListRefreshes()

    var refreshingIdentifiers: Set<String> { refreshes.identifiers }

    func forceRefreshAll() {
        for list in Self.filterLists {
            fetchAndCompile(list: list, refresh: refreshes.begin(list.identifier))
        }
        postStatusChange()
    }

    /// Main queue only.
    private func endRefresh(of identifier: String, _ refresh: Int?) {
        if let refresh { refreshes.end(identifier, token: refresh) }
    }

    func clearCacheAndRedownload() {
        // Invalidate all compiled rules in WebKit, every chunk of every list.
        // Compiles already handed to the store complete `.superseded`, and
        // text ticketed before now (a cache read, or a download whose
        // response was handled) is never compiled (TASK-202). A download
        // still in flight is fresh text and compiles when it arrives.
        ruleStore.invalidateAll()
        compileOrder.supersedeTicketsTaken()

        // Delete cached text files
        for list in Self.filterLists {
            let textFile = cacheDir.appendingPathComponent("\(list.identifier).txt")
            try? FileManager.default.removeItem(at: textFile)

            // Clear UserDefaults keys
            let id = list.identifier
            defaults.removeObject(forKey: "ContentBlocker.\(id).ruleCount")
            defaults.removeObject(forKey: "ContentBlocker.\(id).compiledRuleCount")
            defaults.removeObject(forKey: "ContentBlocker.\(id).lastFetch")
            defaults.removeObject(forKey: "ContentBlocker.\(id).etag")
            defaults.removeObject(forKey: rulesFormatKey(id))
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

    /// Orders each list's compiles by the age of their text. Main queue only.
    private var compileOrder = FilterListCompileOrder()
    /// Parses cached text and downloads one list at a time: a parse holds
    /// hundreds of thousands of rule dictionaries, and Clear Cache & Redownload
    /// or the launch after a `rulesFormatVersion` change would otherwise hold
    /// all four lists' at once (TASK-200 review). Compile order is still
    /// decided by `compileOrder`'s tickets, not by this queue.
    private let parseQueue = DispatchQueue(label: "com.detourbrowser.content-blocker-parse", qos: .utility)

    /// Compiles the list from its cached text, read and parsed off the main
    /// thread (every list is parsed at the launch after a
    /// `rulesFormatVersion` change), then checks whether it is due a refresh.
    /// `onMiss` runs on the main queue when there is no cached text or it did
    /// not compile. Call on the main queue.
    private func loadAndCompileFromCache(list: FilterList, onMiss: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        let textFile = cacheDir.appendingPathComponent("\(list.identifier).txt")
        // A missing cache goes straight to its fallback download instead of
        // waiting behind the other lists' parses on the serial queue.
        guard FileManager.default.fileExists(atPath: textFile.path) else {
            DispatchQueue.main.async(execute: onMiss)
            return
        }
        let ticket = compileOrder.takeTicket()
        parseQueue.async { [weak self] in
            guard let self else { return }
            guard let text = try? String(contentsOf: textFile, encoding: .utf8) else {
                DispatchQueue.main.async {
                    // Deleted by Clear Cache & Redownload since: its
                    // redownload stands in for this one (TASK-202).
                    guard !self.compileOrder.isSuperseded(ticket: ticket) else {
                        log.info("Not compiling \(list.identifier, privacy: .public) from cache: the cache was cleared")
                        return
                    }
                    onMiss()
                }
                return
            }

            let result = self.parser.parse(text: text)
            log.info("Compiling \(list.identifier, privacy: .public) from cache: \(result.rules.count) rules (\(result.skippedCount) skipped)")

            DispatchQueue.main.async {
                guard self.compileOrder.shouldStartCompile(ticket: ticket, for: list.identifier) else {
                    log.info("Not compiling \(list.identifier, privacy: .public) from cache: a compile of newer text has started, or the cache was cleared")
                    return
                }
                self.defaults.set(result.rules.count, forKey: "ContentBlocker.\(list.identifier).ruleCount")
                self.ruleStore.compile(identifier: list.identifier, rules: result.rules) { [weak self] outcome in
                    switch outcome {
                    case .compiled:
                        self?.recordRulesFormat(of: list.identifier)
                        self?.postStatusChange()
                        self?.reapplyRuleLists()
                        self?.refreshIfNeeded(list: list)
                    case .failed:
                        onMiss()
                    case .superseded:
                        // Cleared meanwhile: the redownload replaces it.
                        break
                    }
                }
            }
        }
    }

    /// Downloads the list and compiles it when it changed. `conditional`
    /// sends the saved ETag and fetch date, so an unchanged list answers 304
    /// and is not compiled again.
    ///
    /// The response is handled on `URLSession`'s queue only to write the
    /// text to the cache; the bookkeeping (ETag, fetch date, rule count,
    /// `refreshingIdentifiers`) is recorded on the main queue, and the text
    /// is parsed on a utility queue. `refresh` is the token of the refresh
    /// this fetch is (nil for one nobody asked for), ended on every path.
    private func fetchAndCompile(list: FilterList, conditional: Bool = true, refresh: Int? = nil) {
        var request = URLRequest(url: list.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        // Add conditional fetch headers
        let etagKey = "ContentBlocker.\(list.identifier).etag"
        let lastFetchKey = "ContentBlocker.\(list.identifier).lastFetch"
        if conditional, let etag = defaults.string(forKey: etagKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if conditional, let lastFetch = defaults.object(forKey: lastFetchKey) as? Date {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            request.setValue(formatter.string(from: lastFetch), forHTTPHeaderField: "If-Modified-Since")
        }

        log.info("Fetching \(list.identifier, privacy: .public) from \(list.url, privacy: .public)")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            /// Ends the refresh without compiling, on the main queue.
            func finish(recordingFetch: Bool = false) {
                DispatchQueue.main.async {
                    if recordingFetch { self.defaults.set(Date(), forKey: lastFetchKey) }
                    self.endRefresh(of: list.identifier, refresh)
                    self.postStatusChange()
                }
            }

            if let error {
                log.error("Fetch error for \(list.identifier, privacy: .public): \(error.localizedDescription)")
                return finish()
            }

            guard let httpResponse = response as? HTTPURLResponse else { return finish() }

            if httpResponse.statusCode == 304 {
                log.info("\(list.identifier, privacy: .public) not modified")
                return finish(recordingFetch: true)
            }

            guard httpResponse.statusCode == 200, let data, let text = String(data: data, encoding: .utf8) else {
                log.error("Bad response for \(list.identifier, privacy: .public): \(httpResponse.statusCode)")
                return finish()
            }

            // Cache raw text, before the ticket is taken: a cache read
            // ticketed after this download then reads this text.
            let textFile = self.cacheDir.appendingPathComponent("\(list.identifier).txt")
            try? text.write(to: textFile, atomically: true, encoding: .utf8)
            let etag = httpResponse.value(forHTTPHeaderField: "ETag")

            DispatchQueue.main.async {
                // Save ETag and timestamp
                if let etag { self.defaults.set(etag, forKey: etagKey) }
                self.defaults.set(Date(), forKey: lastFetchKey)
                let ticket = self.compileOrder.takeTicket()

                self.parseQueue.async {
                    let result = self.parser.parse(text: text)
                    log.info("Parsed \(list.identifier, privacy: .public): \(result.rules.count) rules (\(result.skippedCount) skipped)")

                    DispatchQueue.main.async {
                        guard self.compileOrder.shouldStartCompile(ticket: ticket, for: list.identifier) else {
                            log.info("Not compiling the download of \(list.identifier, privacy: .public): a compile of newer text has started, or the cache was cleared")
                            self.endRefresh(of: list.identifier, refresh)
                            self.postStatusChange()
                            return
                        }
                        self.defaults.set(result.rules.count, forKey: "ContentBlocker.\(list.identifier).ruleCount")
                        self.ruleStore.compile(identifier: list.identifier, rules: result.rules) { [weak self] outcome in
                            self?.endRefresh(of: list.identifier, refresh)
                            self?.postStatusChange()
                            if case .compiled = outcome {
                                self?.recordRulesFormat(of: list.identifier)
                                log.info("Compiled \(list.identifier, privacy: .public) successfully")
                                self?.reapplyRuleLists()
                            }
                        }
                    }
                }
            }
        }.resume()
    }

    private func refreshIfNeeded(list: FilterList) {
        let lastFetchKey = "ContentBlocker.\(list.identifier).lastFetch"
        if let lastFetch = defaults.object(forKey: lastFetchKey) as? Date,
           Date().timeIntervalSince(lastFetch) < fetchInterval {
            return
        }
        fetchAndCompile(list: list)
    }
}
