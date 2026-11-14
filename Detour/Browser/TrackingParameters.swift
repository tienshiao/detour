import Foundation

/// Link tracking parameters: the one list Detour removes from a link, and the
/// pure rule that removes them. Used by a quarantine page's navigations
/// (`Quarantine.trackingFreeURL`, TASK-194) and by every Copy URL / Copy Link
/// of a page or tab (TASK-326), which copy the clean link while the page,
/// history and session keep the address as loaded.
enum TrackingParameters {
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

    /// `url` without its tracking query parameters; the same URL when it has
    /// none, or is not http(s). Names are compared after percent-decoding.
    /// The other parameters keep their order, repeats and spelling (their
    /// encoding untouched), and the fragment is kept. A query left with
    /// nothing in it goes, `?` included; empty pieces (`a=1&&b=2`, a trailing
    /// `&`) go with the parameters removed.
    static func removing(from url: URL) -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = components.percentEncodedQuery, !query.isEmpty else { return url }
        func isTrackingPair(_ pair: Substring) -> Bool {
            let rawName = String(pair.prefix { $0 != "=" })
            return isTracking(rawName.removingPercentEncoding ?? rawName)
        }
        let pairs = query.split(separator: "&", omittingEmptySubsequences: false)
        let kept = pairs.filter { !$0.isEmpty && !isTrackingPair($0) }
        // Nothing removed but empty pieces: the URL as it came.
        guard kept.count < pairs.lazy.filter({ !$0.isEmpty }).count else { return url }
        components.percentEncodedQuery = kept.isEmpty ? nil : kept.joined(separator: "&")
        return components.url ?? url
    }

    /// The string a Copy URL / Copy Link of a page or tab puts on the
    /// clipboard: `url` without its tracking parameters (`removing`).
    static func copyableString(for url: URL) -> String {
        removing(from: url).absoluteString
    }
}
