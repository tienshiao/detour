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

    /// Where a main-frame navigation in a quarantine window should go instead,
    /// nil to let it through: a GET to an http(s) URL carrying tracking
    /// parameters (`TrackingParameters.cleanLink(for:)`: the built-in names,
    /// and the downloaded filter's rules and exceptions for the address while
    /// it is loaded) is loaded again without them. Left alone: back/forward and
    /// reloads (the entry is already what it is), anything that is not a GET
    /// (a form post cannot be replayed), a download (loading it again would
    /// drop the link's `download` attribute and its Referer: the file would
    /// show as a page), and a jump to an anchor of `currentURL`, the page
    /// shown (a same-document navigation would become a full reload).
    ///
    /// Whether the rewrite may happen at all is `QuarantineTrackingRewrites`'
    /// call: it keeps a page that insists on its parameters from looping.
    static func trackingFreeURL(for url: URL?, httpMethod: String?, isBackForwardOrReload: Bool,
                                shouldPerformDownload: Bool = false, currentURL: URL? = nil) -> URL? {
        guard let url, !isBackForwardOrReload, !shouldPerformDownload,
              (httpMethod ?? "GET").uppercased() == "GET",
              !isSameDocument(url, as: currentURL) else { return nil }
        // The built-in list plus the downloaded filter when it is loaded and
        // on, as Copy URL (the user's decision, TASK-329 AC #4); the built-in
        // names alone otherwise.
        let stripped = TrackingParameters.cleanLink(for: url)
        return stripped == url ? nil : stripped
    }

    /// Whether going to `url` from `current` only moves to an anchor of the
    /// same document: it names a fragment and is otherwise the same address,
    /// as WebKit decides a same-document navigation for a GET.
    private static func isSameDocument(_ url: URL, as current: URL?) -> Bool {
        guard let current, url.fragment != nil else { return false }
        func withoutFragment(_ url: URL) -> String {
            let text = url.absoluteString
            return text.firstIndex(of: "#").map { String(text[..<$0]) } ?? text
        }
        return withoutFragment(url) == withoutFragment(current)
    }

    // MARK: - User agent

    /// The user agent of a quarantine page: Safari's own, exactly as the
    /// Safari mode sends it (`UserAgentMode.safariUserAgent`: the macOS
    /// version frozen at 10_15_7, no Detour token), whatever the Private
    /// profile's setting, so the page sees one of many Safari users.
    static var userAgent: String { UserAgentMode.safariUserAgent }

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

/// Keeps a quarantine page's tracking-parameter rewrite from looping (code
/// review, TASK-194 follow-up). A rewrite cancels the navigation and loads the
/// clean address, so a server redirect or a page script (`location.replace`)
/// that sends the clean address straight back to its parameters would loop
/// forever; WebKit's `_isRedirect` SPI tells only the first apart, and only
/// while it exists.
///
/// So each clean address is rewritten to once, and at most `limit` are,
/// between two navigations the user starts (`userNavigated`: an address the
/// window loads, a link the user clicks). The navigation that brings the
/// parameters back the second time is let through, and the page settles
/// where it would have without quarantine.
struct QuarantineTrackingRewrites {
    /// Rewrites allowed between two navigations the user starts: a page that
    /// keeps inventing new addresses is let through after this many.
    static let limit = 8
    private var rewritten: Set<URL> = []

    /// Whether a navigation may be rewritten to `clean`; recorded when it may.
    mutating func allows(_ clean: URL) -> Bool {
        guard rewritten.count < Self.limit, rewritten.insert(clean).inserted else { return false }
        return true
    }

    /// The user started a navigation: the page gets a fresh budget.
    mutating func userNavigated() {
        rewritten.removeAll()
    }
}
