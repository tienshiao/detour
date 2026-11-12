import Foundation

// What an Arc import found, independent of where it was read from: Arc's own
// files on this Mac (`ArcSidebarReader`) or the Markdown file Arc's Settings ›
// Advanced › Export Data writes (`ArcExportReader`). The mapping into Detour
// (TASK-293.2) and the import window (TASK-293.3) only ever see this.
//
// Every item carries a `sourceKey`: stable across reads of the same source, so
// a second import can tell what it already brought over. A direct read uses
// Arc's own item ids; an export file has no ids, so its keys are built from
// the space title, the folder path and the URL (see `ArcExportReader`).

/// The source an Arc snapshot was read from.
nonisolated enum ArcImportSource: Sendable, Equatable {
    /// Arc's data folder on this Mac (`~/Library/Application Support/Arc`).
    case installation(URL)
    /// An `Arc Data Export.md` file.
    case exportFile(URL)
}

/// One Arc profile. A direct read lists every profile Arc knows; an export
/// file has no profiles, so its snapshot has exactly one, `.export`.
nonisolated struct ArcProfile: Sendable, Equatable, Identifiable {
    nonisolated enum ID: Sendable, Hashable {
        /// Arc's default profile (`User Data/Default`).
        case `default`
        /// A profile Arc created, by its folder under `User Data` ("Profile 1").
        case directory(String)
        /// The single stand-in profile of an export file.
        case export
    }

    let id: ID
    /// The name Arc shows for the profile.
    var name: String
    /// The profile's favourites (Arc's "top apps"), in Arc's order.
    var favorites: [ArcTab]
    /// The profile's Chromium `History` database, when a direct read found one.
    var historyFile: URL?

    /// The stable key a second import matches this profile by.
    var sourceKey: String {
        switch id {
        case .default: "profile:default"
        case .directory(let name): "profile:dir:\(name)"
        case .export: "profile:export"
        }
    }
}

/// A space and what its sidebar holds, in Arc's order.
nonisolated struct ArcSpace: Sendable, Equatable {
    let sourceKey: String
    var title: String
    /// The space's emoji, or nil when Arc shows a symbol (or nothing) instead.
    var emoji: String?
    /// The space's theme colour as `RRGGBB`, when Arc stored one.
    var colorHex: String?
    var profileID: ArcProfile.ID
    var pinned: [ArcSidebarNode]
    /// Arc's unpinned ("Today") tabs, which Arc archives on its own.
    var unpinned: [ArcSidebarNode]
}

nonisolated indirect enum ArcSidebarNode: Sendable, Equatable {
    case tab(ArcTab)
    case folder(ArcFolder)
    case split(ArcSplit)
}

nonisolated struct ArcTab: Sendable, Equatable {
    let sourceKey: String
    var url: URL
    /// The title the user gave the tab, else the page's saved title, else the host.
    var title: String
}

nonisolated struct ArcFolder: Sendable, Equatable {
    let sourceKey: String
    var title: String
    var children: [ArcSidebarNode]
}

/// An Arc split view: two or more tabs shown side by side, in Arc's order.
nonisolated struct ArcSplit: Sendable, Equatable {
    let sourceKey: String
    var tabs: [ArcTab]
    /// The first pane's share of the width (Arc's `itemWidthFactors`), when stored.
    var leadingFraction: Double? = nil
}

/// Something the reader saw and could not bring over, so the import window can
/// say so instead of dropping it silently.
nonisolated struct ArcSkippedItem: Sendable, Equatable {
    nonisolated enum Reason: Sendable, Equatable {
        /// An item kind Detour has no counterpart for (an Easel, a Note, …),
        /// named by Arc's own key for it.
        case unsupportedKind(String)
        /// A tab whose URL is missing or not a web page Detour can open.
        case unusableURL
    }

    var reason: Reason
    /// The item's title, when it had one.
    var title: String?
    /// The title of the space it was in, when known.
    var spaceTitle: String?
}

nonisolated struct ArcImportSnapshot: Sendable, Equatable {
    var source: ArcImportSource
    var profiles: [ArcProfile]
    var spaces: [ArcSpace]
    var skipped: [ArcSkippedItem]

    func profile(_ id: ArcProfile.ID) -> ArcProfile? {
        profiles.first { $0.id == id }
    }
}

nonisolated enum ArcImportError: Error, Equatable, Sendable {
    /// No Arc data folder, or no sidebar file in it.
    case arcNotFound
    /// The file exists but could not be read (permissions, I/O).
    case unreadable(path: String, reason: String)
    /// The file was read but is not in a shape this reader understands.
    case unrecognizedFormat(path: String, reason: String)
}

extension ArcSidebarNode {
    /// Every tab in this node, depth first, in Arc's order.
    nonisolated var allTabs: [ArcTab] {
        switch self {
        case .tab(let tab): [tab]
        case .split(let split): split.tabs
        case .folder(let folder): folder.children.flatMap(\.allTabs)
        }
    }
}
