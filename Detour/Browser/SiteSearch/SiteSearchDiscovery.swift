import Foundation
import WebKit

/// The rules for adding a site search from a page's OpenSearch description
/// (TASK-288). Pure; `SiteSearchDiscoverer` applies them.
nonisolated enum SiteSearchDiscovery {
    /// The link a page names its description with. Case-insensitive, as
    /// HTML's `rel` and `type` are. The first one on the page's own site
    /// counts (`descriptionURL(hrefs:pageURL:)`).
    static let descriptionLinkSelector =
        "link[rel~='search' i][type='application/opensearchdescription+xml' i]"

    /// Gives every description link's resolved `href`, in document order.
    static let lookupScript =
        "Array.from(document.querySelectorAll(\"\(descriptionLinkSelector)\"), (link) => link.href)"

    /// The largest description fetched; real ones are a few hundred bytes.
    static let sizeLimit = 64 * 1024
    /// How long a description may take, from the request to its last byte.
    static let timeout: TimeInterval = 10
    /// How many pages of a site without a usable link are asked per launch.
    /// Sites put the link in a shared page head, so a few pages without one
    /// mean the site has none; the rest of its loads cost nothing.
    static let pagesAskedPerSite = 3

    /// Whether a page may be looked at at all: a normal profile's page (not a
    /// Private window's, a Private Quick Detour's or a quarantine's), on http
    /// or https with a host. `pageURL` is the web view's URL, so an error
    /// page (`browser-error:`) or an internal page (`detour:`) is not one.
    static func mayLook(at pageURL: URL?, isPrivate: Bool, isQuarantined: Bool) -> Bool {
        guard !isPrivate, !isQuarantined, let pageURL, let scheme = pageURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        return SiteSearch.displayHost(of: pageURL) != nil
    }

    /// Whether `url` belongs to the same site as `pageURL`: http or https,
    /// no user or password, the same host (`SiteSearch.displayHost`, so
    /// `www.` does not count), and not http when the page is https. The port
    /// is not compared: a site is its host, as site searches name sites (and
    /// as the web's "same site" does). A description, the redirects it takes
    /// and its results template must all pass, so discovery never contacts
    /// or adds another host.
    static func isSameSite(_ url: URL, as pageURL: URL) -> Bool {
        let pageScheme = pageURL.scheme?.lowercased()
        switch url.scheme?.lowercased() {
        case "https": break
        case "http" where pageScheme == "http": break
        default: return false
        }
        guard url.user == nil, url.password == nil, let host = SiteSearch.displayHost(of: url) else { return false }
        return host == SiteSearch.displayHost(of: pageURL)
    }

    /// The description to fetch: the first of the page's links whose `href`
    /// is on the page's site, or nil when none is.
    static func descriptionURL(hrefs: [String], pageURL: URL) -> URL? {
        hrefs.lazy.compactMap { descriptionURL(href: $0, pageURL: pageURL) }.first
    }

    /// The description to fetch for a link's `href` (resolved against the
    /// page), or nil when it is not on the page's site.
    static func descriptionURL(href: String, pageURL: URL) -> URL? {
        guard let url = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: pageURL)?
            .absoluteURL, isSameSite(url, as: pageURL) else { return nil }
        return url
    }

    /// A redirect a description fetch may follow: to the same site only.
    static let allowsRedirect: CappedDataFetcher.RedirectPolicy = { original, target in
        isSameSite(target, as: original)
    }

    /// The site search `description` makes for the page, or nil when its
    /// results are on another site. Named after the page's host when the
    /// description has no name. `SiteSearchStore.addDiscovered` marks it and
    /// applies the store's rules.
    static func entry(from description: OpenSearchDescription, pageURL: URL) -> SiteSearch? {
        guard let host = SiteSearch.displayHost(of: pageURL),
              let sample = SiteSearch.url(template: description.urlTemplate, query: "x"),
              isSameSite(sample, as: pageURL) else { return nil }
        return SiteSearch(name: description.name.isEmpty ? host : description.name, keyword: "",
                          urlTemplate: description.urlTemplate)
    }
}

/// Fetches OpenSearch descriptions (TASK-288) with the app's own session, not
/// a profile's: no cookies sent or kept, nothing cached, `sizeLimit` bytes
/// and `timeout` seconds at most, redirects only within the site.
final class OpenSearchFetcher {
    private let fetcher: CappedDataFetcher

    init(configuration: URLSessionConfiguration = OpenSearchFetcher.makeSessionConfiguration(),
         limit: Int = SiteSearchDiscovery.sizeLimit) {
        fetcher = CappedDataFetcher(configuration: configuration, limit: limit)
    }

    static func makeSessionConfiguration(timeout: TimeInterval = SiteSearchDiscovery.timeout)
        -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpMaximumConnectionsPerHost = 1
        return configuration
    }

    /// The description at `url`, or nil (not a 200, too big, too slow, or a
    /// redirect off the site).
    func fetch(_ url: URL) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = fetcher.start(url, allowsRedirect: SiteSearchDiscovery.allowsRedirect) { data in
                continuation.resume(returning: data)
            }
        }
    }

    /// Ends the session (tests: a session keeps its delegate alive until
    /// invalidated).
    func invalidate() { fetcher.invalidate() }
}

/// Adds site searches from the OpenSearch descriptions pages link
/// (TASK-288). `TabStore` calls `pageDidFinishLoading(in:)` when a tab's load
/// ends; a site is looked at only while discovery may add it, and its
/// description is fetched at most once per launch.
final class SiteSearchDiscoverer {
    static let shared = SiteSearchDiscoverer(store: .shared, fetch: OpenSearchFetcher().fetch)

    /// The lookup runs here, away from page script: a page can neither see
    /// it nor patch `querySelector` to answer it.
    static let contentWorld = WKContentWorld.world(name: "DetourSiteSearch")

    private let store: SiteSearchStore
    private let fetch: (URL) async -> Data?

    /// The sites (`SiteSearch.displayHost`) whose description was fetched,
    /// or is being fetched, this launch.
    private(set) var attemptedHosts: Set<String> = []
    /// How many of each site's pages were asked for a link this launch
    /// without naming a usable one (`pagesAskedPerSite` at most).
    private(set) var pagesAsked: [String: Int] = [:]

    init(store: SiteSearchStore, fetch: @escaping (URL) async -> Data?) {
        self.store = store
        self.fetch = fetch
    }

    /// Looks for a description link on the page `tab` shows, when discovery
    /// may: a normal profile, an http(s) page, a site not listed, not
    /// removed by the user, not fetched yet this launch, and with fewer than
    /// `pagesAskedPerSite` pages asked already. Those are all checked before
    /// the page is asked; past them a load costs nothing.
    func pageDidFinishLoading(in tab: BrowserTab) {
        guard let webView = tab.webView, let pageURL = webView.url,
              SiteSearchDiscovery.mayLook(at: pageURL, isPrivate: tab.owningProfile?.isIncognito ?? true,
                                          isQuarantined: tab.isQuarantined),
              let host = SiteSearch.displayHost(of: pageURL), mayLook(atHost: host),
              pagesAsked[host, default: 0] < SiteSearchDiscovery.pagesAskedPerSite else { return }
        pagesAsked[host, default: 0] += 1
        webView.evaluateJavaScript(SiteSearchDiscovery.lookupScript, in: nil, in: Self.contentWorld) {
            [weak self, weak webView] result in
            // The answer is the document's that is there now: a page that
            // navigated to another site since is not this one.
            guard let self, let current = webView?.url, SiteSearch.displayHost(of: current) == host,
                  case .success(let value) = result, let hrefs = value as? [String] else { return }
            self.discover(descriptionHrefs: hrefs, pageURL: pageURL)
        }
    }

    /// Fetches the first description of `descriptionHrefs` (the page's
    /// links) on `pageURL`'s site and adds the site search it makes. Nil,
    /// fetching nothing, when the site may not be looked at or no link is on
    /// its site; otherwise the task gives the added entry, or nil. Tests
    /// start here.
    @discardableResult
    func discover(descriptionHrefs: [String], pageURL: URL) -> Task<SiteSearch?, Never>? {
        guard let host = SiteSearch.displayHost(of: pageURL), mayLook(atHost: host),
              let descriptionURL = SiteSearchDiscovery.descriptionURL(hrefs: descriptionHrefs, pageURL: pageURL)
        else { return nil }
        attemptedHosts.insert(host)
        return Task { [weak self] in
            guard let fetch = self?.fetch, let data = await fetch(descriptionURL),
                  let description = OpenSearchDescription(data: data),
                  let found = SiteSearchDiscovery.entry(from: description, pageURL: pageURL) else { return nil }
            // Checked again by the store: the list may have changed while the
            // description was on its way.
            return self?.store.addDiscovered(found)
        }
    }

    private func mayLook(atHost host: String) -> Bool {
        !attemptedHosts.contains(host) && store.mayDiscover(host: host)
    }
}
