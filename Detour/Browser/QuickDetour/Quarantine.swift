import Foundation
import WebKit

// Quarantine (TASK-194): a link opened in a throwaway Quick Detour window
// whose page has a website data store of its own, so the destination sees and
// sets none of your cookies or site data and nothing is recorded in history;
// it moves to a profile and space only on purpose (Open in), as a fresh load.
//
// The window is a Quick Detour on the Private profile (its extension
// controller, so extensions allowed in Private run; its rules, so no history,
// no archive and no idle close) whose web view does NOT use the Private
// profile's shared store but a fresh non-persistent one per window
// (`QuarantineSession`). Pure rules here; the store, the window and the
// app delegate act on them. See wiki/features/quarantine.md.

/// One quarantine's website data: a fresh non-persistent store, shared only by
/// the windows its page opens itself (`window.open`, a `target=_blank` link,
/// which must keep their opener and so their store). Held by its pages; when
/// the last one goes, the store's data is removed and the store released.
final class QuarantineSession {
    /// The store every page of this quarantine uses. Never a profile's.
    let dataStore: WKWebsiteDataStore
    /// The link as it arrived, before any tracking parameter was removed: what
    /// the window says it was opened from (where the page has since gone is the
    /// title bar's host).
    let originalURL: URL?

    init(originalURL: URL?, dataStore: WKWebsiteDataStore = .nonPersistent()) {
        self.originalURL = originalURL
        self.dataStore = dataStore
    }

    deinit {
        // A non-persistent store keeps its data in memory for as long as the
        // store lives; with no page left it goes anyway, but say so explicitly
        // rather than rely on WebKit's release order.
        let store = dataStore
        DispatchQueue.main.async {
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        }
    }
}

/// What the download question names (TASK-194): the file and the site.
struct QuarantineDownloadQuestion: Equatable {
    var filename: String
    /// The host the download comes from; nil when the URL has none.
    var host: String?
}

/// A quarantine download's first delegate (TASK-194, the user's decision:
/// ask each time). WebKit names the file only when it asks where to save it,
/// so the question is asked then; a yes hands the download to the
/// `DownloadManager` (listed and saved as a Private window's), a no refuses a
/// destination, which cancels it before a byte is written.
final class QuarantineDownloadGate: NSObject, WKDownloadDelegate {
    private weak var controller: QuickDetourWindowController?
    private let sourceURL: URL?
    /// `WKDownload.delegate` is weak: the gate keeps itself until it has
    /// handed the download on or it has ended.
    private var keepAlive: QuarantineDownloadGate?
    /// The download ended (failed or was cancelled) while the question was
    /// up: a late yes then hands nothing on, so the download list never shows
    /// one that will not finish.
    private var hasFailed = false

    init(controller: QuickDetourWindowController, sourceURL: URL?) {
        self.controller = controller
        self.sourceURL = sourceURL
        super.init()
        keepAlive = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let question = QuarantineDownloadQuestion(filename: suggestedFilename,
                                                  host: (sourceURL ?? response.url)?.host)
        let allowed: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let controller = self?.controller else { return continuation.resume(returning: false) }
                controller.askToDownload(question) { continuation.resume(returning: $0) }
            }
        }
        let admitted: Bool = await MainActor.run {
            defer { keepAlive = nil }
            guard allowed, !hasFailed, let controller, !controller.isTornDown else { return false }
            controller.admitQuarantineDownload(download, sourceURL: sourceURL ?? response.url, filename: suggestedFilename)
            return true
        }
        // Refused: no destination cancels the download.
        guard admitted else { return nil }
        return await DownloadManager.shared.download(download, decideDestinationUsing: response,
                                                     suggestedFilename: suggestedFilename)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        hasFailed = true
        keepAlive = nil
    }
}

enum Quarantine {
    /// The name in the UI: the Links pane's target, the title bar's badge.
    static let displayName = "Quarantine"

    /// The download question's second line: where the file comes from and
    /// what quarantine does not do for it.
    static func downloadQuestionDetail(_ question: QuarantineDownloadQuestion) -> String {
        let from = question.host.map { "From \($0), to" } ?? "To"
        return "\(from) your Downloads folder. Quarantine keeps your cookies away from the site; "
            + "it does not check the file."
    }

    // MARK: - Link tracking parameters

    /// Query parameters that only identify a click or a campaign: click IDs
    /// that ad networks and mail tools add (`gclid`, `fbclid`, `msclkid`,
    /// `mc_eid`, …) and the campaign tags (`utm_*`). Compared without case.
    /// WebKit's own link decoration filtering (on in quarantine, below)
    /// removed `gclid`, `fbclid` and `mc_eid` on macOS 26.7 but kept `utm_*`
    /// (measured, TASK-194); this list is the floor whatever WebKit's does.
    static let trackingParameterNames: Set<String> = [
        // Google Ads, DoubleClick, Google's app and iOS click IDs
        "gclid", "gclsrc", "dclid", "gbraid", "wbraid",
        // Meta, Microsoft Ads, Instagram, Yandex, X, TikTok, LinkedIn
        "fbclid", "msclkid", "igshid", "yclid", "twclid", "ttclid", "li_fat_id",
        // Mailchimp, HubSpot, Marketo, Omeda, Vero, Adobe, Rakuten
        "mc_eid", "mc_cid", "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_id", "s_cid",
        "rb_clickid",
    ]

    /// Whether `name` is a tracking parameter (`trackingParameterNames`, or any
    /// `utm_` parameter).
    static func isTrackingParameter(_ name: String) -> Bool {
        let name = name.lowercased()
        return trackingParameterNames.contains(name) || (name.hasPrefix("utm_") && name.count > 4)
    }

    /// `url` without its tracking query parameters; the same URL when it has
    /// none, or is not http(s). The other parameters keep their order and
    /// spelling (their encoding untouched), and the fragment is kept.
    static func removingTrackingParameters(from url: URL) -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = components.percentEncodedQuery, !query.isEmpty else { return url }
        let pairs = query.split(separator: "&", omittingEmptySubsequences: false)
        let kept = pairs.filter { pair in
            let rawName = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let name = String(rawName).removingPercentEncoding ?? String(rawName)
            return !isTrackingParameter(name)
        }
        guard kept.count < pairs.count else { return url }
        components.percentEncodedQuery = kept.isEmpty ? nil : kept.joined(separator: "&")
        return components.url ?? url
    }

    /// Where a main-frame navigation in a quarantine window should go instead,
    /// nil to let it through: a GET to an http(s) URL carrying tracking
    /// parameters is loaded again without them. Back/forward and reloads are
    /// left alone (the entry is already what it is), and so is anything that
    /// is not a GET (a form post cannot be replayed).
    static func trackingFreeURL(for url: URL?, httpMethod: String?, isBackForwardOrReload: Bool) -> URL? {
        guard let url, !isBackForwardOrReload, (httpMethod ?? "GET").uppercased() == "GET" else { return nil }
        let stripped = removingTrackingParameters(from: url)
        return stripped == url ? nil : stripped
    }

    // MARK: - User agent

    /// The user agent of a quarantine page: Safari's own, as Safari sends it —
    /// the macOS version frozen at 10_15_7, as every Safari does — and no
    /// "Detour/1" token, so the page sees one of many Safari users.
    static func userAgent(safariVersion: String) -> String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(safariVersion) Safari/605.1.15"
    }

    /// `userAgent(safariVersion:)` with the installed Safari's version.
    static var userAgent: String {
        userAgent(safariVersion: UserAgentMode.installedSafariVersion)
    }

    // MARK: - WebKit's privacy protections (SPI)

    /// The bits of `WKWebpagePreferences._networkConnectionIntegrityPolicy`
    /// (SPI; WebKit's `_WKWebsiteNetworkConnectionIntegrityPolicy`, whose names
    /// are deliberately vague) that a quarantine page gets, as WebKit maps them
    /// to its `AdvancedPrivacyProtections` (WKWebpagePreferences.mm):
    ///
    /// | Bit | SPI name | Protection |
    /// |---|---|---|
    /// | 1 << 0 | `Enabled` | `BaselineProtections` |
    /// | 1 << 6 | `EnhancedTelemetry` | `FingerprintingProtections`: canvas and audio readback noised per session, `screen` reporting the window (measured on macOS 26.7) |
    /// | 1 << 8 | `SanitizeLookalikeCharacters` | `LinkDecorationFiltering`: WebKit's list of click IDs removed from navigations (`gclid`, `fbclid`, `mc_eid`; not `utm_*`) |
    ///
    /// Left out: `RequestValidation` (1 << 7, `EnhancedNetworkPrivacy`, which
    /// rests on iCloud Private Relay, not Detour's to use) and the HTTPS-only
    /// and fail-closed bits (they change which pages load at all).
    static let privacyProtectionPolicy: UInt = 1 << 0 | 1 << 6 | 1 << 8

    private static let policySetter = NSSelectorFromString("_setNetworkConnectionIntegrityPolicy:")
    private static let policyGetter = NSSelectorFromString("_networkConnectionIntegrityPolicy")

    /// Whether this WebKit has the SPI. Without it a quarantine still has its
    /// own store, Safari's user agent and the tracking-parameter rule.
    static func privacyProtectionsAvailable(on preferences: WKWebpagePreferences) -> Bool {
        preferences.responds(to: policySetter) && preferences.responds(to: policyGetter)
    }

    /// The policy bits `preferences` carries; nil without the SPI.
    static func privacyProtections(of preferences: WKWebpagePreferences) -> UInt? {
        guard privacyProtectionsAvailable(on: preferences) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
        return unsafeBitCast(preferences.method(for: policyGetter), to: Getter.self)(preferences, policyGetter)
    }

    /// Adds `privacyProtectionPolicy` to what `preferences` already carries,
    /// for the navigation they are handed back with. Returns whether it could:
    /// false, changing nothing, on a WebKit without the SPI.
    ///
    /// Called through the method's implementation, not key-value coding: KVC
    /// maps `_networkConnectionIntegrityPolicy` to a `set_…` setter that does
    /// not exist and throws (`NSUnknownKeyException`, seen in the spike).
    @discardableResult
    static func applyPrivacyProtections(to preferences: WKWebpagePreferences) -> Bool {
        guard let current = privacyProtections(of: preferences) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(preferences.method(for: policySetter), to: Setter.self)(
            preferences, policySetter, current | privacyProtectionPolicy)
        return true
    }
}
