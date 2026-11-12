import XCTest
import GRDB
@testable import Detour

/// TASK-293.1: reading Arc's own files into an `ArcImportSnapshot`. The
/// fixtures are synthetic, built in the shape Arc 1.172.1 writes
/// (`wiki/features/arc-import.md`).
nonisolated final class ArcSidebarReaderTests: XCTestCase {

    // MARK: - Fixture building

    /// An item in Arc's `items` ordered map.
    private struct Item {
        var id: String
        var parentID: String?
        var title: String? = nil
        var children: [String] = []
        var data: [String: Any]

        var json: [String: Any] {
            var object: [String: Any] = [
                "id": id, "childrenIds": children, "data": data,
                "isUnread": false, "createdAt": 700000000.0,
            ]
            object["parentID"] = parentID ?? NSNull()
            object["title"] = title ?? NSNull()
            return object
        }
    }

    private static func tab(_ id: String, in parent: String, url: String, savedTitle: String? = "Saved",
                            title: String? = nil) -> Item {
        var tab: [String: Any] = ["savedURL": url, "savedMuteStatus": "allowAudio",
                                  "timeLastActiveAt": 811838010.0]
        tab["savedTitle"] = savedTitle
        return Item(id: id, parentID: parent, title: title, data: ["tab": tab])
    }

    private static func folder(_ id: String, in parent: String, title: String?, children: [String]) -> Item {
        Item(id: id, parentID: parent, title: title, children: children, data: ["list": [String: Any]()])
    }

    private static func spaceContainer(_ id: String, space: String, children: [String]) -> Item {
        Item(id: id, parentID: nil, children: children,
             data: ["itemContainer": ["containerType": ["spaceItems": ["_0": space]]]])
    }

    private static func topApps(_ id: String, profile: [String: Any], children: [String]) -> Item {
        Item(id: id, parentID: nil, children: children,
             data: ["itemContainer": ["containerType": ["topApps": ["_0": profile]]]])
    }

    private static var defaultProfile: [String: Any] { ["default": true] }
    private static func customProfile(_ directory: String) -> [String: Any] {
        ["custom": ["_0": ["directoryBasename": directory, "machineID": "MACHINE"]]]
    }

    private static func space(_ id: String, title: String?, profile: [String: Any], pinned: String,
                              unpinned: String, customInfo: [String: Any] = [:]) -> [String: Any] {
        var space: [String: Any] = [
            "id": id, "profile": profile, "customInfo": customInfo,
            "containerIDs": ["unpinned", unpinned, "pinned", pinned],
            "newContainerIDs": [["pinned": [String: Any]()], pinned,
                                ["unpinned": ["_0": ["shared": [String: Any]()]]], unpinned],
        ]
        space["title"] = title
        return space
    }

    private static func color(_ red: Double, _ green: Double, _ blue: Double) -> [String: Any] {
        ["red": red, "green": green, "blue": blue, "alpha": 1, "colorSpace": "extendedSRGB"]
    }

    private static func sidebarJSON(spaces: [(String, [String: Any])], items: [Item],
                                    topApps: [([String: Any], String)] = []) -> Data {
        let root: [String: Any] = [
            "version": 1,
            "sidebar": ["containers": [
                ["global": [String: Any]()],
                [
                    "spaces": spaces.flatMap { [$0.0, $0.1] as [Any] },
                    "items": items.flatMap { [$0.id, $0.json] as [Any] },
                    "topAppsContainerIDs": topApps.flatMap { [$0.0, $0.1] as [Any] },
                ] as [String: Any],
            ]],
            // A stale sync shadow with a space that is no longer in the sidebar.
            "sidebarSyncState": ["spaceModels": ["GHOST", ["value": ["id": "GHOST", "title": "Ghost"]]]],
        ]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    private static func localState(_ profiles: [String: (name: String, placeholder: Bool)]) -> Data {
        let cache = profiles.mapValues { ["name": $0.name, "is_using_default_name": $0.placeholder] }
        return try! JSONSerialization.data(withJSONObject: ["profile": ["info_cache": cache]])
    }

    /// Two spaces on two profiles, nested folders, unpinned tabs, favourites
    /// for both profiles, a split view, an Easel and an unusable URL.
    private static func richSidebar() -> Data {
        let workInfo: [String: Any] = [
            "iconType": ["emoji_v2": "💼", "emoji": 128188],
            "windowTheme": ["primaryColorPalette": ["shaded": color(0.0, 0.5, 1.0),
                                                    "midTone": color(1, 1, 1)]],
        ]
        let personalInfo: [String: Any] = [
            "iconType": ["icon": "star"],
            "windowTheme": ["primaryColorPalette": ["midTone": color(1.2, -0.1, 0.2)]],
        ]
        return sidebarJSON(
            spaces: [
                ("WORK", space("WORK", title: "Work", profile: defaultProfile, pinned: "W-P", unpinned: "W-U",
                               customInfo: workInfo)),
                ("PERSONAL", space("PERSONAL", title: "Personal stuff", profile: customProfile("Profile 1"),
                                   pinned: "P-P", unpinned: "P-U", customInfo: personalInfo)),
            ],
            items: [
                spaceContainer("W-P", space: "WORK", children: ["T1", "F1", "SPLIT", "EASEL", "BAD"]),
                tab("T1", in: "W-P", url: "https://mail.example.com/", savedTitle: "Inbox", title: "Mail"),
                folder("F1", in: "W-P", title: "Projects", children: ["T2", "F2"]),
                tab("T2", in: "F1", url: "https://a.example.com/", savedTitle: "A"),
                folder("F2", in: "F1", title: "Deep", children: ["T3"]),
                tab("T3", in: "F2", url: "https://b.example.com/x", savedTitle: nil),
                Item(id: "SPLIT", parentID: "W-P", children: ["S1", "S2", "S3"],
                     data: ["splitView": ["layoutOrientation": "horizontal",
                                          "itemWidthFactors": ["S1", 0.3] as [Any]] as [String: Any]]),
                tab("S1", in: "SPLIT", url: "https://left.example.com/", savedTitle: "Left"),
                tab("S2", in: "SPLIT", url: "https://right.example.com/", savedTitle: "Right"),
                tab("S3", in: "SPLIT", url: "https://third.example.com/", savedTitle: "Third"),
                Item(id: "EASEL", parentID: "W-P", title: "Moodboard", data: ["easel": ["id": "E"]]),
                tab("BAD", in: "W-P", url: "arc://settings", savedTitle: "Settings"),
                spaceContainer("W-U", space: "WORK", children: ["U1", "WELCOME"]),
                tab("U1", in: "W-U", url: "https://news.example.com/", savedTitle: "News"),
                Item(id: "WELCOME", parentID: "W-U", data: ["welcomeToArc": ["timeLastActiveAt": 1.0]]),
                spaceContainer("P-P", space: "PERSONAL", children: ["PT1"]),
                tab("PT1", in: "P-P", url: "https://bank.example.com/", savedTitle: "Bank"),
                spaceContainer("P-U", space: "PERSONAL", children: []),
                topApps("TOP-D", profile: defaultProfile, children: ["FAV1", "FAV2"]),
                tab("FAV1", in: "TOP-D", url: "https://calendar.example.com/", savedTitle: "Calendar"),
                tab("FAV2", in: "TOP-D", url: "https://chat.example.com/", savedTitle: "Chat"),
                topApps("TOP-1", profile: customProfile("Profile 1"), children: ["FAV3"]),
                tab("FAV3", in: "TOP-1", url: "https://music.example.com/", savedTitle: "Music"),
            ],
            topApps: [(defaultProfile, "TOP-D"), (customProfile("Profile 1"), "TOP-1")])
    }

    private func parse(_ sidebar: Data, localState: Data? = nil) throws -> ArcImportSnapshot {
        try ArcSidebarReader.parse(sidebarJSON: sidebar, localStateJSON: localState)
    }

    // MARK: - Spaces and the pinned tree

    @MainActor func testSpacesComeInArcOrderWithTitleEmojiColourAndProfile() throws {
        let snapshot = try parse(Self.richSidebar())
        XCTAssertEqual(snapshot.spaces.map(\.title), ["Work", "Personal stuff"],
                       "the sync shadow's ghost space is ignored")
        XCTAssertEqual(snapshot.spaces.map(\.sourceKey), ["space:WORK", "space:PERSONAL"])
        XCTAssertEqual(snapshot.spaces[0].emoji, "💼")
        XCTAssertNil(snapshot.spaces[1].emoji, "a symbol icon has no emoji")
        XCTAssertEqual(snapshot.spaces[0].colorHex, "0080FF", "the shaded colour wins over the mid tone")
        XCTAssertEqual(snapshot.spaces[1].colorHex, "FF0033", "extended sRGB components are clamped")
        XCTAssertEqual(snapshot.spaces[0].profileID, .default)
        XCTAssertEqual(snapshot.spaces[1].profileID, .directory("Profile 1"))
    }

    @MainActor func testPinnedTreeKeepsOrderNestingAndTitles() throws {
        let work = try parse(Self.richSidebar()).spaces[0]
        guard work.pinned.count == 3,
              case .tab(let mail) = work.pinned[0],
              case .folder(let projects) = work.pinned[1],
              case .split(let split) = work.pinned[2] else {
            return XCTFail("unexpected pinned shape: \(work.pinned)")
        }
        XCTAssertEqual(mail.title, "Mail", "the user's own title wins over the saved page title")
        XCTAssertEqual(mail.url.absoluteString, "https://mail.example.com/")
        XCTAssertEqual(mail.sourceKey, "item:T1")
        XCTAssertEqual(projects.title, "Projects")
        guard projects.children.count == 2,
              case .tab(let a) = projects.children[0],
              case .folder(let deep) = projects.children[1],
              deep.children.count == 1, case .tab(let b) = deep.children[0] else {
            return XCTFail("unexpected folder shape: \(projects)")
        }
        XCTAssertEqual(a.title, "A")
        XCTAssertEqual(deep.title, "Deep")
        XCTAssertEqual(b.title, "b.example.com", "no title at all falls back to the host")
        XCTAssertEqual(split.tabs.map(\.title), ["Left", "Right", "Third"],
                       "a split keeps every pane; how many Detour can show is the mapping's call")
        XCTAssertEqual(split.leadingFraction, 0.3, "the first pane's width share")
        XCTAssertEqual(work.unpinned.flatMap(\.allTabs).map(\.title), ["News"],
                       "Arc's onboarding item is dropped silently")
    }

    @MainActor func testUnsupportedItemsAndUnusableURLsAreReportedNotDropped() throws {
        let snapshot = try parse(Self.richSidebar())
        XCTAssertEqual(snapshot.skipped, [
            ArcSkippedItem(reason: .unsupportedKind("easel"), title: "Moodboard", spaceTitle: "Work"),
            ArcSkippedItem(reason: .unusableURL, title: "Settings", spaceTitle: "Work"),
        ])
    }

    // MARK: - Profiles and favourites

    @MainActor func testProfilesAreNamedFromLocalStateAndCarryTheirFavourites() throws {
        let localState = Self.localState([
            "Default": ("Person 1", true),
            "Profile 1": ("Home", false),
            "Profile 3": ("Side project", false),
        ])
        let snapshot = try parse(Self.richSidebar(), localState: localState)
        XCTAssertEqual(snapshot.profiles.map(\.id), [.default, .directory("Profile 1"), .directory("Profile 3")],
                       "a profile with no space or favourite is still listed: its history can come over")
        XCTAssertEqual(snapshot.profiles.map(\.name), ["Default", "Home", "Side project"],
                       "Chromium's placeholder name is not shown")
        XCTAssertEqual(snapshot.profile(.default)?.favorites.map(\.title), ["Calendar", "Chat"])
        XCTAssertEqual(snapshot.profile(.directory("Profile 1"))?.favorites.map(\.title), ["Music"])
        XCTAssertEqual(snapshot.profile(.directory("Profile 3"))?.favorites, [])
    }

    @MainActor func testProfilesSortDefaultFirstThenInFinderOrder() throws {
        let localState = Self.localState([
            "Profile 10": ("Ten", false), "Profile 2": ("Two", false), "Default": ("Me", false),
        ])
        let snapshot = try parse(Self.sidebarJSON(spaces: [], items: []), localState: localState)
        XCTAssertEqual(snapshot.profiles.map(\.name), ["Me", "Two", "Ten"])
    }

    @MainActor func testWithoutLocalStateFolderNamesStandIn() throws {
        let snapshot = try parse(Self.richSidebar())
        XCTAssertEqual(snapshot.profiles.map(\.name), ["Default", "Profile 1"])
    }

    // MARK: - Edge shapes

    @MainActor func testEmptySidebarGivesNoSpaces() throws {
        let snapshot = try parse(Self.sidebarJSON(spaces: [], items: []))
        XCTAssertEqual(snapshot.spaces, [])
        XCTAssertEqual(snapshot.skipped, [])
    }

    @MainActor func testBuiltInPersonalSpaceWithoutATitleIsNamed() throws {
        let id = ArcSidebarReader.builtInPersonalSpaceID
        let sidebar = Self.sidebarJSON(
            spaces: [(id, Self.space(id, title: nil, profile: Self.defaultProfile, pinned: "P", unpinned: "U")),
                     ("OTHER", Self.space("OTHER", title: "  ", profile: Self.defaultProfile,
                                          pinned: "P2", unpinned: "U2"))],
            items: [Self.spaceContainer("P", space: id, children: [])])
        XCTAssertEqual(try parse(sidebar).spaces.map(\.title), ["Personal", "Untitled Space"])
    }

    @MainActor func testOnlyTaggedContainerIDsStillFindThePinnedTabs() throws {
        var space = Self.space("S", title: "S", profile: Self.defaultProfile, pinned: "P", unpinned: "U")
        space["containerIDs"] = nil
        let sidebar = Self.sidebarJSON(spaces: [("S", space)], items: [
            Self.spaceContainer("P", space: "S", children: ["T"]),
            Self.tab("T", in: "P", url: "https://x.example.com/"),
        ])
        XCTAssertEqual(try parse(sidebar).spaces[0].pinned.flatMap(\.allTabs).map(\.sourceKey), ["item:T"])
    }

    @MainActor func testACyclicChildChainEndsInsteadOfLooping() throws {
        let sidebar = Self.sidebarJSON(
            spaces: [("S", Self.space("S", title: "S", profile: Self.defaultProfile, pinned: "P", unpinned: "U"))],
            items: [
                Self.spaceContainer("P", space: "S", children: ["F"]),
                Self.folder("F", in: "P", title: "Loop", children: ["G"]),
                Self.folder("G", in: "F", title: "Back", children: ["F", "P"]),
            ])
        guard case .folder(let loop) = try parse(sidebar).spaces[0].pinned.first,
              case .folder(let back) = loop.children.first else {
            return XCTFail("expected the two folders")
        }
        XCTAssertEqual(back.children, [], "an item already on the path is not visited again")
    }

    @MainActor func testSplitOfOneTabIsAPlainTab() throws {
        let sidebar = Self.sidebarJSON(
            spaces: [("S", Self.space("S", title: "S", profile: Self.defaultProfile, pinned: "P", unpinned: "U"))],
            items: [
                Self.spaceContainer("P", space: "S", children: ["SPLIT"]),
                Item(id: "SPLIT", parentID: "P", children: ["A", "GONE"], data: ["splitView": [String: Any]()]),
                Self.tab("A", in: "SPLIT", url: "https://a.example.com/"),
            ])
        guard case .tab(let tab) = try parse(sidebar).spaces[0].pinned.first else {
            return XCTFail("expected a plain tab")
        }
        XCTAssertEqual(tab.sourceKey, "item:A")
    }

    @MainActor func testMalformedFilesAreTypedErrors() {
        XCTAssertThrowsError(try parse(Data("not json".utf8))) { error in
            guard case ArcImportError.unrecognizedFormat = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try parse(Data(#"{"version": 1}"#.utf8))) { error in
            guard case ArcImportError.unrecognizedFormat = error else { return XCTFail("\(error)") }
        }
    }

    @MainActor func testImportableURLsAreWebPagesOnly() {
        for good in ["https://example.com/", "http://localhost:8080/x"] {
            XCTAssertTrue(ArcSidebarReader.isImportable(URL(string: good)!), good)
        }
        for bad in ["arc://settings", "chrome://extensions", "chrome-extension://abc/popup.html",
                    "file:///Users/me/a.html", "https://", "about:blank"] {
            XCTAssertFalse(ArcSidebarReader.isImportable(URL(string: bad)!), bad)
        }
    }

    // MARK: - Reading a data folder

    @MainActor func testReadingAFolderFindsEachProfilesHistory() throws {
        let folder = try temporaryFolder()
        try Self.richSidebar().write(to: folder.appending(path: "StorableSidebar.json"))
        let userData = folder.appending(path: "User Data")
        try FileManager.default.createDirectory(at: userData.appending(path: "Default"),
                                                withIntermediateDirectories: true)
        try Self.localState(["Default": ("Me", false), "Profile 1": ("Home", false)])
            .write(to: userData.appending(path: "Local State"))
        try Data().write(to: userData.appending(path: "Default/History"))

        let snapshot = try ArcSidebarReader.read(dataDirectory: folder)
        XCTAssertEqual(snapshot.source, .installation(folder))
        XCTAssertEqual(snapshot.profile(.default)?.historyFile?.lastPathComponent, "History")
        XCTAssertNil(snapshot.profile(.directory("Profile 1"))?.historyFile)
    }

    @MainActor func testAFolderWithoutArcDataIsArcNotFound() throws {
        let folder = try temporaryFolder()
        XCTAssertThrowsError(try ArcSidebarReader.read(dataDirectory: folder)) { error in
            XCTAssertEqual(error as? ArcImportError, .arcNotFound)
        }
    }

    // MARK: - History

    @MainActor func testHistoryReadsRecentTopLevelWebVisitsFromACopy() throws {
        let folder = try temporaryFolder()
        let history = folder.appending(path: "History")
        let now = Date().timeIntervalSince1970
        let queue = try DatabaseQueue(path: history.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT, url LONGVARCHAR, title LONGVARCHAR,
                    visit_count INTEGER DEFAULT 0 NOT NULL, typed_count INTEGER DEFAULT 0 NOT NULL,
                    last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0 NOT NULL);
                CREATE TABLE visits(id INTEGER PRIMARY KEY AUTOINCREMENT, url INTEGER NOT NULL,
                    visit_time INTEGER NOT NULL, from_visit INTEGER, transition INTEGER DEFAULT 0 NOT NULL);
                """)
            func url(_ id: Int, _ url: String, _ title: String, hidden: Int = 0) throws {
                try db.execute(sql: "INSERT INTO urls (id, url, title, last_visit_time, hidden) VALUES (?, ?, ?, 0, ?)",
                               arguments: [id, url, title, hidden])
            }
            func visit(_ url: Int, daysAgo: Double, transition: Int) throws {
                let time = ArcHistoryReader.chromiumMicroseconds(unixTime: now - daysAgo * 86_400)
                try db.execute(sql: "INSERT INTO visits (url, visit_time, transition) VALUES (?, ?, ?)",
                               arguments: [url, time, transition])
            }
            try url(1, "https://news.example.com/", "News")
            try url(2, "https://ads.example.com/frame", "Ad", hidden: 1)
            try url(3, "chrome://settings/", "Settings")
            try url(4, "https://old.example.com/", "")
            try visit(1, daysAgo: 2, transition: 0x3000_0001)   // typed, with qualifier bits
            try visit(1, daysAgo: 1, transition: 0)             // link
            try visit(2, daysAgo: 1, transition: 0)             // hidden URL
            try visit(1, daysAgo: 0.5, transition: 3)           // auto subframe
            try visit(3, daysAgo: 1, transition: 1)             // not a web page
            try visit(4, daysAgo: 200, transition: 0)           // older than the cutoff
            try visit(4, daysAgo: 3, transition: 0)
        }
        try queue.close()

        let visits = try ArcHistoryReader.readVisits(historyFile: history, since: now - 90 * 86_400)
        XCTAssertEqual(visits.map(\.url), ["https://old.example.com/", "https://news.example.com/",
                                           "https://news.example.com/"], "oldest first")
        XCTAssertEqual(visits.map(\.isTyped), [false, true, false])
        XCTAssertEqual(visits.map(\.title), [nil, "News", "News"], "an empty title is no title")
        XCTAssertEqual(visits[1].visitTime, now - 2 * 86_400, accuracy: 0.001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.path), "the original is untouched")
    }

    @MainActor func testHistoryOfAMissingFileIsEmptyAndANonHistoryFileIsAnError() throws {
        let folder = try temporaryFolder()
        XCTAssertEqual(try ArcHistoryReader.readVisits(historyFile: folder.appending(path: "History"), since: 0), [])
        let notHistory = folder.appending(path: "Other")
        let queue = try DatabaseQueue(path: notHistory.path)
        try queue.write { try $0.execute(sql: "CREATE TABLE t(x)") }
        try queue.close()
        XCTAssertThrowsError(try ArcHistoryReader.readVisits(historyFile: notHistory, since: 0)) { error in
            guard case ArcImportError.unrecognizedFormat = error else { return XCTFail("\(error)") }
        }
    }

    @MainActor func testChromiumTimeConversionRoundTrips() {
        XCTAssertEqual(ArcHistoryReader.unixTime(chromiumMicroseconds: 11_644_473_600_000_000), 0)
        XCTAssertEqual(ArcHistoryReader.chromiumMicroseconds(unixTime: 1_700_000_000.25),
                       13_344_473_600_250_000)
    }

    // MARK: - Helpers

    @MainActor private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "ArcSidebarReaderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
}
