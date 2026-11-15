import Foundation
import os

nonisolated private let log = Logger(subsystem: "com.detourbrowser.mac", category: "content-blocker")

/// The AdGuard URL Tracking filter (filter 17, TASK-329): downloaded and
/// refreshed with the content blocker's lists, parsed into a
/// `TrackingParameterFilter` and installed as `TrackingParameters.downloadedFilter`,
/// which Copy URL, Share… and quarantine navigations use on top of the
/// built-in names.
///
/// It is not one of `ContentBlockerManager.filterLists`: it is never compiled
/// into a WebKit rule list and has no profile switch. The manager drives it
/// from the same places (`initialize`, `forceRefreshAll`,
/// `clearCacheAndRedownload`) with the same bookkeeping: the text cached as
/// `<identifier>.txt` in the data directory's content blocker folder, the
/// `ContentBlocker.<identifier>.etag` / `.lastFetch` / `.ruleCount` defaults,
/// a conditional refresh once 24 hours have passed.
///
/// Settings > Content Blocking turns it off (TASK-337, `isEnabled`, on by
/// default). Off, it is neither fetched nor used, whatever asks (launch,
/// Update Now, Clear Cache & Redownload): every path checks the setting
/// here, not in the manager, so the tests reach the gate. Its cached text
/// stays on disk, so turning it on again works offline.
///
/// Every way it can fail falls back quietly: before the first download,
/// offline, on an error response or a text that parses into no rule, the
/// rules in use stay (none at first, so the built-in names alone). Downloaded
/// text is cached only once it has parsed into rules. The list is GPL-3.0
/// and is never bundled.
final class TrackingParameterList {
    static let identifier = "adguard-url-tracking"
    static let name = "AdGuard URL Tracking filter"
    /// The uBlock Origin build of filter 17. AdGuard's own builds
    /// (`extension/chromium/filters/17.txt`) also carry global `utm_*` rules
    /// that the built-in names already cover; their extra exceptions would
    /// be the reason to switch.
    static let defaultURL = URL(string: "https://filters.adtidy.org/extension/ublock/filters/17.txt")!
    /// Debug builds: replaces `defaultURL`, so a runtime check can serve a
    /// fixture list locally.
    static let urlEnvironmentKey = "DETOUR_TRACKING_FILTER_URL"

    /// Where the list is downloaded from: `defaultURL`, or in a Debug build
    /// the `DETOUR_TRACKING_FILTER_URL` environment variable when set.
    static func listURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        #if DEBUG
        if let override = environment[urlEnvironmentKey].flatMap(URL.init(string:)), override.scheme != nil {
            return override
        }
        #endif
        return defaultURL
    }

    /// How a refresh ended.
    enum Outcome: Equatable {
        /// New text parsed into rules, now in use and cached.
        case installed
        /// The list answered 304.
        case notModified
        /// A network error or an error response: the rules in use stay.
        case failed
        /// The text parsed into no rule: the rules in use stay, the cache is
        /// not overwritten.
        case empty
        /// Text older than rules already in use, or read before Clear Cache &
        /// Redownload or before the list was turned off: dropped.
        case superseded
        /// The list is turned off: no request was made.
        case off
    }

    let url: URL
    private let cacheFile: URL
    private let defaults: UserDefaults
    private let session: URLSession
    private let fetchInterval: TimeInterval
    private let now: () -> Date
    private let install: (TrackingParameterFilter?) -> Void

    /// The counts of the rules in use, nil while none are.
    private(set) var counts: TrackingParameterFilter.Counts?

    /// Text is ticketed when it is asked for (a cache read, a download's
    /// request is sent); rules are installed only from text newer than the rules in
    /// use, and never from text ticketed before the last clear.
    private var lastTicket = 0
    private var installedTicket = 0
    private var supersededTicket = 0

    init(url: URL = TrackingParameterList.listURL(),
         cacheDirectory: URL,
         defaults: UserDefaults,
         session: URLSession = .shared,
         fetchInterval: TimeInterval = 86400,
         now: @escaping () -> Date = Date.init,
         install: @escaping (TrackingParameterFilter?) -> Void = { TrackingParameters.downloadedFilter = $0 }) {
        self.url = url
        cacheFile = cacheDirectory.appendingPathComponent("\(Self.identifier).txt")
        self.defaults = defaults
        self.session = session
        self.fetchInterval = fetchInterval
        self.now = now
        self.install = install
    }

    private var etagKey: String { "ContentBlocker.\(Self.identifier).etag" }
    private var lastFetchKey: String { "ContentBlocker.\(Self.identifier).lastFetch" }
    private var ruleCountKey: String { "ContentBlocker.\(Self.identifier).ruleCount" }
    static let enabledKey = "ContentBlocker.\(identifier).enabled"

    /// Whether Copy URL, Share… and quarantine navigations use the list, and
    /// so whether it is fetched (TASK-337). On unless turned off; stored in
    /// the data directory's content blocker defaults, beside the fetch
    /// bookkeeping.
    var isEnabled: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }

    /// Stores the setting. Turning it off stops using the list at once (the
    /// built-in names alone) and drops any text asked for before, so a
    /// download already in flight is neither installed nor cached; the
    /// cached text and its bookkeeping stay. Turning it on loads nothing by
    /// itself: `turnedOn()` does, so the test host can store the setting
    /// without fetching.
    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        guard !enabled else { return }
        supersededTicket = lastTicket
        counts = nil
        install(nil)
    }

    /// After `setEnabled(true)`: the cached rules, then a fetch (conditional
    /// on the cached text's ETag; in full without a usable cache). Offline,
    /// the cached rules stay in use.
    func turnedOn() async {
        await load(refreshAfterCache: { true })
    }

    /// Launch: the rules from the cached text, then a download when there is
    /// no usable cache (in full) or a refresh is due (conditional). Nothing,
    /// not even the cache, while the list is off.
    func loadAtLaunch() async {
        await load(refreshAfterCache: { self.isDue })
    }

    /// The cached rules, then a full download without a usable cache, or a
    /// conditional one when `refreshAfterCache` says so.
    private func load(refreshAfterCache: () -> Bool) async {
        guard isEnabled else { return }
        let ticket = takeTicket()
        let cacheFile = cacheFile
        let cached = await Task.detached(priority: .utility) { () -> TrackingParameterFilter? in
            guard let text = try? String(contentsOf: cacheFile, encoding: .utf8) else { return nil }
            return TrackingParameterFilter(text: text)
        }.value
        guard let cached, !cached.isEmpty else {
            // A Clear Cache & Redownload during the read runs its own download.
            if ticket > supersededTicket { await refresh(conditional: false) }
            return
        }
        if installIfNewest(cached, ticket: ticket) { logCounts(cached.counts, source: "cache") }
        // A Clear Cache & Redownload during the cache read runs its own
        // download; a second one here would only repeat it. Turned off
        // during the read: no download.
        if ticket > supersededTicket, refreshAfterCache() { await refresh() }
    }

    /// Whether 24 hours have passed since the last fetch (or there was none).
    var isDue: Bool {
        guard let lastFetch = defaults.object(forKey: lastFetchKey) as? Date else { return true }
        return now().timeIntervalSince(lastFetch) >= fetchInterval
    }

    /// Downloads the list; `conditional` sends the saved ETag, so an
    /// unchanged list answers 304. New text is parsed off the main thread,
    /// and installed and cached when it gives rules.
    @discardableResult
    func refresh(conditional: Bool = true) async -> Outcome {
        guard isEnabled else {
            log.info("Not fetching \(Self.identifier, privacy: .public): turned off in Settings")
            return .off
        }
        var request = URLRequest.withSafariUserAgent(url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if conditional, let etag = defaults.string(forKey: etagKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        log.info("Fetching \(Self.identifier, privacy: .public) from \(self.url, privacy: .public)")
        // Ticketed when the request is sent, so a response to a request sent
        // before Clear Cache & Redownload is refused however late it lands.
        let ticket = takeTicket()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            log.error("Fetch error for \(Self.identifier, privacy: .public): \(error.localizedDescription)")
            return .failed
        }
        guard let http = response as? HTTPURLResponse else { return .failed }
        if http.statusCode == 304 {
            guard ticket > supersededTicket else { return .superseded }
            defaults.set(now(), forKey: lastFetchKey)
            log.info("\(Self.identifier, privacy: .public) not modified")
            return .notModified
        }
        guard http.statusCode == 200 else {
            log.error("Bad response for \(Self.identifier, privacy: .public): \(http.statusCode)")
            return .failed
        }
        let etag = http.value(forHTTPHeaderField: "ETag")
        let parsed = await Task.detached(priority: .utility) { () -> TrackingParameterFilter? in
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return TrackingParameterFilter(text: text)
        }.value
        guard let parsed, !parsed.isEmpty else {
            log.error("\(Self.identifier, privacy: .public) gave no rules: the rules in use stay")
            return .empty
        }
        guard installIfNewest(parsed, ticket: ticket) else { return .superseded }
        // Cached only once it is known to be a list (never an error page) and
        // is the text in use: written here, after the ticket check and with no
        // suspension in between, so superseded text (an older response, one
        // read before Clear Cache & Redownload) never overwrites the cache or
        // brings back a cleared one.
        try? data.write(to: cacheFile, options: .atomic)
        if let etag { defaults.set(etag, forKey: etagKey) } else { defaults.removeObject(forKey: etagKey) }
        defaults.set(now(), forKey: lastFetchKey)
        logCounts(parsed.counts, source: "download")
        return .installed
    }

    /// Clear Cache & Redownload: drops the rules in use (the built-in names
    /// alone until the download parses), the cached text and the bookkeeping,
    /// refuses text read before now, and downloads the list in full. While
    /// the list is off it is cleared like the others but not downloaded.
    func clearCacheAndRedownload() async {
        supersededTicket = lastTicket
        try? FileManager.default.removeItem(at: cacheFile)
        for key in [etagKey, lastFetchKey, ruleCountKey] { defaults.removeObject(forKey: key) }
        counts = nil
        install(nil)
        await refresh(conditional: false)
    }

    private func takeTicket() -> Int {
        lastTicket += 1
        return lastTicket
    }

    private func installIfNewest(_ filter: TrackingParameterFilter, ticket: Int) -> Bool {
        guard isEnabled, ticket > supersededTicket, ticket > installedTicket else { return false }
        installedTicket = ticket
        counts = filter.counts
        defaults.set(filter.counts.supported, forKey: ruleCountKey)
        install(filter)
        return true
    }

    private func logCounts(_ counts: TrackingParameterFilter.Counts, source: String) {
        log.info("""
            Installed \(Self.identifier, privacy: .public) from \(source, privacy: .public): \
            \(counts.supported) rules (\(counts.exceptions) exceptions, \(counts.widenedExceptions) widened); \
            skipped \(counts.regex) regex, \(counts.notForPages) not for pages, \
            \(counts.unsupported) unsupported, \(counts.other) other
            """)
    }
}
