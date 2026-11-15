import Foundation

/// Link tracking parameters: the built-in list Detour removes from a link,
/// and the pure rule that removes them. Both users take the clean link
/// (`cleanLink(for:)`: the built-in list plus the downloaded AdGuard URL
/// Tracking filter, TASK-329): a quarantine page's navigations
/// (`Quarantine.trackingFreeURL`, TASK-194), and every Copy URL / Copy Link /
/// Share… of a page or tab (TASK-326), whose page, history and session keep
/// the address as loaded.
enum TrackingParameters {
    /// The downloaded tracking filter's rules (`TrackingParameterList`), nil
    /// until a download or the cached copy has parsed into rules, and while
    /// the list is turned off. Copy, Share and quarantine navigations use
    /// them on top of `names`; without them they use `names` alone.
    static var downloadedFilter: TrackingParameterFilter?

    /// Query parameters that only identify a click or a campaign: click IDs
    /// that ad networks and mail tools add (`gclid`, `fbclid`, `msclkid`,
    /// `mc_eid`, …), Google Analytics' cross-domain linker (`_ga`) and the
    /// campaign tags (`utm_*`, matched by prefix in `isTracking`). Compared
    /// without case. A name that only resembles one (a site's own `ref`,
    /// `source`, `id`) is kept unless it is listed here.
    /// WebKit's own link decoration filtering (on in quarantine) removed
    /// `gclid`, `fbclid` and `mc_eid` on macOS 26.7 but kept `utm_*`
    /// (measured, TASK-194); this list is the floor whatever WebKit's does.
    static let names: Set<String> = [
        // Google Ads, DoubleClick, Google's app and iOS click IDs, Analytics' linker
        "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "_ga",
        // Meta, Microsoft Ads, Instagram, Yandex, X, TikTok, LinkedIn
        "fbclid", "msclkid", "igshid", "yclid", "twclid", "ttclid", "li_fat_id",
        // Mailchimp, HubSpot, Marketo, Omeda, Vero, Adobe, Rakuten
        "mc_eid", "mc_cid", "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_id", "s_cid",
        "rb_clickid",
    ]

    /// Whether `name` is a tracking parameter (`names`, or any `utm_`
    /// parameter).
    static func isTracking(_ name: String) -> Bool {
        let name = name.lowercased()
        return names.contains(name) || (name.hasPrefix("utm_") && name.count > 4)
    }

    /// `url` without its tracking query parameters (the built-in `names`,
    /// and `filter`'s rules when given); the same URL when it has none, or is
    /// not http(s). Built-in names are compared without case after
    /// percent-decoding; `filter` decides its own (`TrackingParameterFilter`).
    /// A parameter one of `filter`'s exceptions keeps for this address is kept
    /// even when it is a built-in name: the list says the site needs it (only
    /// an exception as written and limited to some sites; a widened or global
    /// one cancels the list's own rules alone).
    /// The other parameters keep their order, repeats and spelling (their
    /// encoding untouched), and the fragment is kept. A query left with
    /// nothing in it goes, `?` included; empty pieces (`a=1&&b=2`, a trailing
    /// `&`) go with the parameters removed.
    static func removing(from url: URL, using filter: TrackingParameterFilter? = nil) -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = components.percentEncodedQuery, !query.isEmpty else { return url }
        let verdict = filter?.verdict(for: url)
        func isTrackingPair(_ pair: Substring) -> Bool {
            let rawName = String(pair.prefix { $0 != "=" })
            let name = rawName.removingPercentEncoding ?? rawName
            if let verdict {
                if verdict.protects(rawName: rawName, name: name) { return false }
                if verdict.removes(rawName: rawName, name: name, hasValue: pair.contains("=")) { return true }
            }
            return isTracking(name)
        }
        let pairs = query.split(separator: "&", omittingEmptySubsequences: false)
        let kept = pairs.filter { !$0.isEmpty && !isTrackingPair($0) }
        // Nothing removed but empty pieces: the URL as it came.
        guard kept.count < pairs.lazy.filter({ !$0.isEmpty }).count else { return url }
        components.percentEncodedQuery = kept.isEmpty ? nil : kept.joined(separator: "&")
        return components.url ?? url
    }

    /// The link Copy URL / Copy Link / Share… of a page or tab hands out, and
    /// the address a quarantine page loads instead: `url` without the
    /// built-in list's tracking parameters nor the downloaded filter's
    /// (`downloadedFilter`), when it has loaded.
    static func cleanLink(for url: URL) -> URL {
        removing(from: url, using: downloadedFilter)
    }

    /// The string a Copy URL / Copy Link of a page or tab puts on the
    /// clipboard: `cleanLink(for:)`.
    static func copyableString(for url: URL) -> String {
        cleanLink(for: url).absoluteString
    }
}
