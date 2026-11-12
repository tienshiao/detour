import XCTest
@testable import Detour

/// TASK-293.1: reading `Arc Data Export.md`. The first fixture has the shape of
/// a real Arc 1.172.1 export (links replaced): a Favorites list that is the
/// profile's favourites, then the space's top-level pinned tabs, then its
/// Today tabs, with nothing between them; a `##` section per folder and a
/// `###` section per folder inside it.
nonisolated final class ArcExportReaderTests: XCTestCase {

    private static let realShape = """
        # Home

        ## Favorites
        - https://mail.example.com/inbox
        - arc://history/
        - https://music.example.com/
        - https://localhost.example.com:4000/

        ## News
        - https://reader.example.com/
        - https://news.example.com/

        ### Nested Folder
        - https://deep.example.com/

        # Work

        ## Favorites
        - https://mail.example.com/inbox
        - https://calendar.example.com/

        """

    private func parse(_ text: String) throws -> ArcImportSnapshot {
        try ArcExportReader.parse(text)
    }

    @MainActor func testSpacesFoldersAndTheSharedLeadOfFavorites() throws {
        let snapshot = try parse(Self.realShape)
        XCTAssertEqual(snapshot.profiles.map(\.id), [.export])
        XCTAssertEqual(snapshot.profiles[0].favorites.map(\.url.absoluteString), ["https://mail.example.com/inbox"],
                       "only the link opening the Favorites list of two spaces is a favourite")
        XCTAssertEqual(snapshot.spaces.map(\.title), ["Home", "Work"])
        XCTAssertEqual(snapshot.spaces.map(\.profileID), [.export, .export])

        let home = snapshot.spaces[0]
        XCTAssertEqual(home.unpinned.flatMap(\.allTabs).map(\.url.absoluteString),
                       ["https://music.example.com/", "https://localhost.example.com:4000/"],
                       "the rest of the list are Today tabs; arc:// is skipped")
        guard home.pinned.count == 1, case .folder(let news) = home.pinned[0] else {
            return XCTFail("expected the News folder: \(home.pinned)")
        }
        XCTAssertEqual(news.title, "News")
        guard news.children.count == 3, case .folder(let nested) = news.children[2] else {
            return XCTFail("expected the nested folder last in News: \(news.children)")
        }
        XCTAssertEqual(news.children.flatMap(\.allTabs).map(\.title),
                       ["reader.example.com", "news.example.com", "deep.example.com"],
                       "an export has no titles; the host stands in")
        XCTAssertEqual(nested.title, "Nested Folder", "a ### heading is a folder inside the ## above it")

        XCTAssertEqual(snapshot.spaces[1].unpinned.flatMap(\.allTabs).map(\.url.absoluteString),
                       ["https://calendar.example.com/"])
        XCTAssertEqual(snapshot.skipped, [ArcSkippedItem(reason: .unusableURL, title: "arc://history/",
                                                         spaceTitle: "Home")])
    }

    @MainActor func testOneSpaceHasNoFavourites() throws {
        let snapshot = try parse("""
            # Solo
            ## Favorites
            - https://a.example.com/
            - https://b.example.com/
            """)
        XCTAssertEqual(snapshot.profiles[0].favorites, [])
        XCTAssertEqual(snapshot.spaces[0].unpinned.count, 2)
    }

    @MainActor func testSourceKeysAreStableAndDistinctForRepeatedLinks() throws {
        let text = """
            # Home
            ## Docs
            - https://a.example.com/
            - https://a.example.com/
            ## Favorites
            - https://t.example.com/
            """
        let first = try parse(text)
        let second = try parse(text)
        XCTAssertEqual(first, second, "the same export reads the same keys")
        let docs = first.spaces[0].pinned.flatMap(\.allTabs).map(\.sourceKey)
        XCTAssertEqual(docs, ["export:space:Home/pinned/Docs/https://a.example.com/",
                              "export:space:Home/pinned/Docs/https://a.example.com/#2"])
        XCTAssertEqual(first.spaces[0].unpinned.flatMap(\.allTabs).map(\.sourceKey),
                       ["export:space:Home/today/https://t.example.com/"])
    }

    @MainActor func testDeeperHeadingsAndIndentedBulletsNest() throws {
        let snapshot = try parse("""
            # Home
            ## Projects
            - https://top.example.com/
            ### Client
            - https://client.example.com/
            - Archive
              - [Old site](https://old.example.com/)
              - <https://older.example.com/>
            - https://after.example.com/
            ## Reading
            * https://read.example.com/
            """)
        let pinned = snapshot.spaces[0].pinned
        guard pinned.count == 2, case .folder(let projects) = pinned[0], case .folder(let reading) = pinned[1],
              projects.children.count == 2, case .folder(let client) = projects.children[1],
              client.children.count == 3, case .folder(let archive) = client.children[1] else {
            return XCTFail("unexpected shape: \(pinned)")
        }
        XCTAssertEqual(projects.children.first.map { $0.allTabs.map(\.title) }, ["top.example.com"])
        XCTAssertEqual(client.title, "Client")
        XCTAssertEqual(archive.title, "Archive")
        XCTAssertEqual(archive.children.flatMap(\.allTabs).map(\.title), ["Old site", "older.example.com"],
                       "a [title](url) link keeps its title")
        XCTAssertEqual(client.children[2].allTabs.map(\.title), ["after.example.com"],
                       "a bullet back at the folder's indent leaves the bullet folder")
        XCTAssertEqual(reading.children.flatMap(\.allTabs).map(\.title), ["read.example.com"])
    }

    @MainActor func testAnEmptySpaceAndAFileWithoutSpaces() throws {
        XCTAssertEqual(try parse("# Empty\n").spaces.map(\.title), ["Empty"])
        XCTAssertThrowsError(try parse("just some text\n- https://a.example.com/")) { error in
            guard case ArcImportError.unrecognizedFormat = error else { return XCTFail("\(error)") }
        }
    }

    @MainActor func testReadingAFileSetsTheSource() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "ArcExport-\(UUID().uuidString).md")
        try Self.realShape.write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try ArcExportReader.read(file: file).source, .exportFile(file))
        XCTAssertThrowsError(try ArcExportReader.read(file: file.appending(path: "missing"))) { error in
            guard case ArcImportError.unreadable = error else { return XCTFail("\(error)") }
        }
    }

    @MainActor func testLinkForms() {
        XCTAssertEqual(ArcExportReader.link("https://a.example.com/x?q=1#f"),
                       ArcExportReader.Link(url: "https://a.example.com/x?q=1#f", title: nil))
        XCTAssertEqual(ArcExportReader.link("[A](https://a.example.com/)"),
                       ArcExportReader.Link(url: "https://a.example.com/", title: "A"))
        XCTAssertNil(ArcExportReader.link("Just a folder name"))
        XCTAssertNil(ArcExportReader.link("Notes: see https://a.example.com/"))
    }

    @MainActor func testOpaqueSchemeLinksAreSkippedNotFolders() throws {
        let snapshot = try parse("""
            # Space
            ## Tools
            - javascript:alert(1)
            - about:blank
            - https://a.example.com/
            - TODO:
            """)
        guard case .folder(let tools)? = snapshot.spaces.first?.pinned.first else { return XCTFail("no folder") }
        XCTAssertEqual(tools.children.count, 2, "only the web page and the plain-text bullet folder")
        XCTAssertEqual(tools.children.flatMap(\.allTabs).map(\.title), ["a.example.com"])
        XCTAssertEqual(snapshot.skipped.map(\.title), ["javascript:alert(1)", "about:blank"])
    }

    @MainActor func testALaterFavoritesHeadingIsAFolderAndSharedBadFavouritesAreSkippedOnce() throws {
        let snapshot = try parse("""
            # One
            ## Favorites
            - arc://settings
            - https://today.example.com/
            ## Favorites
            - https://pinned.example.com/
            # Two
            ## Favorites
            - arc://settings
            """)
        guard case .folder(let folder)? = snapshot.spaces.first?.pinned.first else { return XCTFail("no folder") }
        XCTAssertEqual(folder.title, "Favorites")
        XCTAssertEqual(folder.children.flatMap(\.allTabs).map(\.title), ["pinned.example.com"])
        XCTAssertEqual(snapshot.spaces.first?.unpinned.flatMap(\.allTabs).map(\.title), ["today.example.com"])
        XCTAssertEqual(snapshot.skipped.map(\.title), ["arc://settings"])
    }
}
