import AppKit

// Pure rules behind the sidebar's tab hover card (TASK-190): when it shows,
// what it says, and which tab or tile a hovered row describes.

/// When a hovered row's card appears.
enum HoverCardTiming {
    /// A fresh hover waits this long, a little sooner than AppKit's tooltip.
    static let showDelay: TimeInterval = 0.45
    /// A card hidden this recently (the pointer moved off its row) counts as
    /// still showing, so moving to the next row swaps the card at once.
    static let swapWindow: TimeInterval = 0.3

    /// The wait before showing a card for a newly hovered row.
    static func delay(isShowing: Bool, lastHiddenAt: Date?, now: Date) -> TimeInterval {
        if isShowing { return 0 }
        if let lastHiddenAt {
            let since = now.timeIntervalSince(lastHiddenAt)
            if since >= 0, since < swapWindow { return 0 }
        }
        return showDelay
    }
}

/// The card's two lines of text.
struct HoverCardText: Equatable {
    /// The display form of a URL: the host (emphasised by the card) and the
    /// path, query and fragment after it.
    struct URLLine: Equatable {
        let host: String
        let rest: String
        var joined: String { host + rest }
    }

    let title: String
    /// Nil when the tab has no URL, or when the title already is the URL.
    let url: URLLine?

    /// The full title (trimmed). A blank title falls back to the URL's
    /// display form, which then is not repeated on the URL line.
    static func make(title: String, url: URL?) -> HoverCardText {
        let line = urlLine(for: url)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return HoverCardText(title: trimmed, url: line) }
        if let line, !line.joined.isEmpty { return HoverCardText(title: line.joined, url: nil) }
        return HoverCardText(title: "Untitled", url: nil)
    }

    /// The URL without its scheme, user info or a leading `www.`, split at the
    /// host; the path is percent-decoded and a bare root path dropped. A
    /// `file:` URL is its path; other non-web schemes (`about:`, `detour:`)
    /// are shown whole.
    static func urlLine(for url: URL?) -> URLLine? {
        guard let url else { return nil }
        let scheme = url.scheme?.lowercased()
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return URLLine(host: url.absoluteString, rest: "")
        }
        // Decoded for reading, unless that would put control or format
        // characters (bidi overrides, zero-width) into the displayed URL.
        let encodedPath = components.percentEncodedPath
        let decodedPath = encodedPath.removingPercentEncoding
        let path = decodedPath.flatMap { decoded in
            decoded.unicodeScalars.contains { $0.properties.generalCategory == .control
                || $0.properties.generalCategory == .format } ? nil : decoded
        } ?? encodedPath
        if scheme == "file" {
            return URLLine(host: "", rest: path)
        }
        guard scheme == "http" || scheme == "https", var host = components.host, !host.isEmpty else {
            return URLLine(host: url.absoluteString, rest: "")
        }
        if host.lowercased().hasPrefix("www.") { host.removeFirst(4) }
        if let port = components.port { host += ":\(port)" }
        var rest = path
        if let query = components.percentEncodedQuery { rest += "?" + query }
        if let fragment = components.percentEncodedFragment { rest += "#" + fragment }
        if rest == "/" { rest = "" }
        return URLLine(host: host, rest: rest)
    }
}

/// What a hovered sidebar row stands for.
enum HoverCardTarget {
    case tab(BrowserTab)
    case pinned(PinnedEntry)
    case favorite(Favorite)

    /// The same row content, by object identity.
    func isSame(as other: HoverCardTarget) -> Bool {
        switch (self, other) {
        case (.tab(let a), .tab(let b)): return a === b
        case (.pinned(let a), .pinned(let b)): return a === b
        case (.favorite(let a), .favorite(let b)): return a === b
        default: return false
        }
    }

    /// The live tab behind the row, if any.
    var tab: BrowserTab? {
        switch self {
        case .tab(let tab): return tab
        case .pinned(let entry): return entry.tab
        case .favorite(let favorite): return favorite.tab
        }
    }

    /// The hovered half of a split row (0 = left, 1 = right), or the row's
    /// single tab. A split row with no side known gets no card.
    static func forTabItem(_ item: TabListItem, splitSide: Int?) -> HoverCardTarget? {
        switch item {
        case .single(let tab):
            return .tab(tab)
        case .split(_, let members):
            guard let splitSide, members.indices.contains(splitSide) else { return nil }
            return .tab(members[splitSide])
        }
    }

    /// A pinned entry's row, or the hovered half of a pinned split. Folders
    /// get no card.
    static func forPinnedItem(_ item: PinnedItem, splitSide: Int?) -> HoverCardTarget? {
        switch item {
        case .entry(let entry, _):
            return .pinned(entry)
        case .folder:
            return nil
        case .split(_, let entries, _):
            guard let splitSide, entries.indices.contains(splitSide) else { return nil }
            return .pinned(entries[splitSide])
        }
    }
}

/// Everything the card shows for a target, short of the disk read.
struct HoverCardContent {
    let text: HoverCardText
    /// The tab's in-memory picture, used as is.
    let preview: NSImage?
    /// Where to look on disk when there is no `preview`; nil when the row
    /// gets no thumbnail at all.
    let thumbnailKey: UUID?

    /// - Parameters:
    ///   - isOnScreen: whether a tab is showing in this window (no thumbnail).
    ///   - thumbnailKey: `TabStore.thumbnailKey(for:)` for a live tab.
    static func make(for target: HoverCardTarget,
                     isOnScreen: (BrowserTab) -> Bool,
                     thumbnailKey: (BrowserTab) -> UUID?) -> HoverCardContent {
        // A live pinned entry or favourite describes the tab's current page,
        // not the pinned one; a dormant tile its own.
        let text: HoverCardText
        switch target {
        case .tab(let tab):
            text = .make(title: tab.title, url: tab.url)
        case .pinned(let entry):
            text = entry.tab.map { .make(title: $0.title, url: $0.url) }
                ?? .make(title: entry.pinnedTitle, url: entry.pinnedURL)
        case .favorite(let favorite):
            text = favorite.tab.map { .make(title: $0.title, url: $0.url) }
                ?? .make(title: favorite.title, url: favorite.url)
        }
        guard let tab = target.tab else {
            // Dormant: only the disk can have a picture, under the tile's id.
            let key: UUID
            switch target {
            case .pinned(let entry): key = entry.id
            case .favorite(let favorite): key = favorite.id
            case .tab(let tab): key = tab.id
            }
            return HoverCardContent(text: text, preview: nil, thumbnailKey: key)
        }
        // The page is in front of the user already.
        if isOnScreen(tab) {
            return HoverCardContent(text: text, preview: nil, thumbnailKey: nil)
        }
        return HoverCardContent(text: text, preview: tab.switcherPreview, thumbnailKey: thumbnailKey(tab))
    }
}

/// Where the card goes on screen.
enum HoverCardPlacement {
    /// The gap between the sidebar's edge and the card.
    static let gap: CGFloat = 6

    /// Just outside the sidebar's trailing edge, its top level with the
    /// hovered row's top, kept inside `visibleFrame` (all screen coordinates).
    static func frame(cardSize: NSSize, sidebarMaxX: CGFloat, rowTop: CGFloat, visibleFrame: NSRect) -> NSRect {
        var x = sidebarMaxX + gap
        var y = rowTop - cardSize.height
        x = min(x, visibleFrame.maxX - cardSize.width)
        x = max(x, visibleFrame.minX)
        y = max(y, visibleFrame.minY)
        y = min(y, visibleFrame.maxY - cardSize.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: cardSize)
    }
}
