import Foundation

/// The Media Session actions the now-playing bar can ask a page for. Any other
/// action a page registers is ignored.
enum MediaSessionAction: String, CaseIterable {
    case play, pause, previoustrack, nexttrack
}

/// What a page's main frame reported about its Media Session
/// (`navigator.mediaSession`): the actions it has handlers for and its
/// metadata. The page writes all of it, so it is display text and a list of
/// buttons to enable, nothing more.
struct MediaSessionReport: Equatable {
    var actions: Set<MediaSessionAction> = []
    var title: String?
    var artist: String?
    var album: String?
    var artworkURL: URL?

    /// The longest text the bar keeps from a page.
    static let maxTextLength = 200
    /// The artwork the bar draws, in pixels (its 28 pt square at 2x is 56).
    static let preferredArtworkPixels = 64
}

/// A message from `MediaSessionBridge`'s isolated-world script, validated.
enum MediaBridgeMessage: Equatable {
    /// The main frame started a new document: forget the old page's session
    /// and picture in picture.
    case document
    case session(MediaSessionReport)
    /// A frame's videos entered (`active`) or left picture in picture. `frame`
    /// is a random token the frame's script made, so each frame is counted once.
    case pictureInPicture(frame: String, active: Bool)

    /// Nil for anything malformed, and for a document or session message from
    /// a subframe (only the main frame's Media Session drives the bar).
    init?(body: Any, isMainFrame: Bool) {
        guard let body = body as? [String: Any], let kind = body["kind"] as? String else { return nil }
        switch kind {
        case "document":
            guard isMainFrame else { return nil }
            self = .document
        case "session":
            guard isMainFrame else { return nil }
            self = .session(MediaSessionReport(body))
        case "pip":
            guard let frame = body["frame"] as? String, (1...Self.maxFrameTokenLength).contains(frame.count),
                  let active = body["active"] as? Bool else { return nil }
            self = .pictureInPicture(frame: frame, active: active)
        default:
            return nil
        }
    }

    static let maxFrameTokenLength = 64
}

extension MediaSessionReport {
    /// Reads a `session` message; a field of the wrong type is treated as absent.
    fileprivate init(_ body: [String: Any]) {
        let names = body["actions"] as? [Any] ?? []
        actions = Set(names.compactMap { ($0 as? String).flatMap(MediaSessionAction.init(rawValue:)) })
        title = Self.displayText(body["title"])
        artist = Self.displayText(body["artist"])
        album = Self.displayText(body["album"])
        artworkURL = Self.artworkURL(body["artwork"])
    }

    /// One line of plain text: control characters become spaces, runs of
    /// whitespace collapse, and the result is bounded. Nil when nothing is left.
    static func displayText(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let flattened = String(string.prefix(maxTextLength * 4).unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
                ? " " : Character(scalar)
        })
        let collapsed = flattened.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxTextLength))
    }

    /// The `MediaImage` to draw: the smallest declared size that covers the
    /// bar's artwork, else the largest declared, else the first. Only http and
    /// https: the image is fetched outside the page.
    static func artworkURL(_ value: Any?) -> URL? {
        let images: [(url: URL, pixels: Int?)] = (value as? [Any] ?? []).compactMap { item in
            guard let item = item as? [String: Any], let src = item["src"] as? String,
                  let url = URL(string: src), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
            return (url, largestSide(item["sizes"] as? String))
        }
        let sized = images.compactMap { image in image.pixels.map { (url: image.url, pixels: $0) } }
        if let covering = sized.filter({ $0.pixels >= preferredArtworkPixels }).min(by: { $0.pixels < $1.pixels }) {
            return covering.url
        }
        return sized.max(by: { $0.pixels < $1.pixels })?.url ?? images.first?.url
    }

    /// The largest side named in a `sizes` attribute ("96x96 128x128"); nil
    /// for "any" or nothing readable.
    private static func largestSide(_ sizes: String?) -> Int? {
        sizes?.lowercased().split(separator: " ").compactMap { size -> Int? in
            let sides = size.split(separator: "x").compactMap { Int($0) }
            return sides.count == 2 ? sides.max() : nil
        }.max()
    }
}
