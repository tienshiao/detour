import Foundation

/// Where an installed extension's files came from (TASK-113). Decides how it
/// can move to a newer version: a CRX install is polled at its update URL and
/// replaced in place; an unpacked one is reloaded from the folder it was loaded
/// from, on request only (Chrome's developer-mode rule — nothing polls a folder).
enum ExtensionSource: String, Codable, Equatable {
    /// A CRX downloaded from the Chrome Web Store.
    case webStore
    /// A CRX from anywhere else (a self-hosted `update_url`, a local file).
    case crx
    /// A folder loaded with Develop > Load Unpacked Extension.
    case unpacked

    /// The update2 endpoint every Web Store manifest declares. Used when a store
    /// download's manifest carries no `update_url` of its own.
    static let webStoreUpdateURL = URL(string: "https://clients2.google.com/service/update2/crx")!

    /// Hosts a Web Store CRX is served from. `chrome.google.com` is the legacy
    /// store; the others are the download and update endpoints the store's own
    /// pages and update2 responses point at.
    static let webStoreHosts: Set<String> = [
        "clients2.google.com", "clients2.googleusercontent.com",
        "chrome.google.com", "chromewebstore.google.com",
    ]

    /// Whether `url` is on a Web Store host, so a CRX from it counts as a store
    /// install and a manifest without `update_url` still updates from the store.
    static func isWebStoreURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return webStoreHosts.contains(host)
    }

    /// The source and update URL to record for a CRX that was just downloaded from
    /// `downloadURL` and whose manifest declares `manifestUpdateURL`.
    ///
    /// A store download always gets an update URL — the manifest's, or the store's
    /// default — because store extensions are meant to update. Any other CRX
    /// updates only from a URL its manifest names; without one it stays put.
    static func classifyCRX(downloadURL: URL?, manifestUpdateURL: String?) -> (source: ExtensionSource, updateURL: URL?) {
        let declared = manifestUpdateURL.flatMap { URL(string: $0) }.filter { $0.scheme?.lowercased() == "https" }
        if let downloadURL, isWebStoreURL(downloadURL) {
            return (.webStore, declared ?? webStoreUpdateURL)
        }
        return (.crx, declared)
    }
}

private extension Optional {
    /// `Optional.filter`: nil unless the wrapped value passes `predicate`.
    func filter(_ predicate: (Wrapped) -> Bool) -> Wrapped? {
        flatMap { predicate($0) ? $0 : nil }
    }
}
