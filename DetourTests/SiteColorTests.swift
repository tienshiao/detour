import XCTest
import GRDB
@testable import Detour

/// TASK-290: the site-search chip's color — the dominant-color rule, the text
/// color, and the fallback order in a real palette.
nonisolated final class SiteColorTests: XCTestCase {

    /// `count` pixels of one color, as non-premultiplied RGBA bytes.
    private func pixels(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255, count: Int) -> [UInt8] {
        (0..<count).flatMap { _ in [r, g, b, a] }
    }

    private func assertClose(_ color: SiteColor.RGB?, _ r: Double, _ g: Double, _ b: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let color else { return XCTFail("no color", file: file, line: line) }
        XCTAssertEqual(color.red, r, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(color.green, g, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(color.blue, b, accuracy: 0.02, file: file, line: line)
    }

    func testASolidIconIsItsColor() {
        assertClose(SiteColor.dominant(rgba: pixels(255, 0, 0, count: 256)), 1, 0, 0)
    }

    func testTheLogoWinsOverAWhiteOrBlackBackground() {
        let icon = pixels(255, 255, 255, count: 150) + pixels(0, 0, 0, count: 50) + pixels(0, 0, 255, count: 56)
        assertClose(SiteColor.dominant(rgba: icon), 0, 0, 1)
    }

    func testTheLargerHueWins() {
        let icon = pixels(0, 0, 255, count: 150) + pixels(255, 0, 0, count: 80)
        assertClose(SiteColor.dominant(rgba: icon), 0, 0, 1)
    }

    func testAGreyMonochromeOrTransparentIconHasNoColor() {
        XCTAssertNil(SiteColor.dominant(rgba: pixels(128, 128, 128, count: 256)), "grey")
        XCTAssertNil(SiteColor.dominant(rgba: pixels(0, 0, 0, count: 128) + pixels(255, 255, 255, count: 128)),
                     "black and white")
        XCTAssertNil(SiteColor.dominant(rgba: pixels(255, 0, 0, 10, count: 256)), "transparent")
        XCTAssertNil(SiteColor.dominant(rgba: []), "empty")
    }

    func testASmallColoredDetailOnAGreyLogoIsNotTheColor() {
        let icon = pixels(90, 90, 90, count: 240) + pixels(255, 0, 0, count: 16)  // about 6%
        XCTAssertNil(SiteColor.dominant(rgba: icon))
    }

    func testTransparentPixelsDoNotCountAgainstTheShare() {
        let icon = pixels(0, 0, 0, 0, count: 240) + pixels(0, 200, 0, count: 16)
        assertClose(SiteColor.dominant(rgba: icon), 0, 200.0 / 255, 0)
    }

    func testAnImageIsReadThroughItsDrawing() throws {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 6, dy: 6)).fill()
            return true
        }
        assertClose(SiteColor.dominant(in: image), 1, 0, 0)
    }

    func testARedLogoIsNotSplitAcrossTheHueSeam() {
        // Reds just below and just above 0 degrees, against a smaller blue.
        let icon = pixels(255, 0, 30, count: 60) + pixels(255, 30, 0, count: 60) + pixels(0, 0, 255, count: 80)
        let color = SiteColor.dominant(rgba: icon)
        XCTAssertGreaterThan(color?.red ?? 0, 0.9, "the reds together outweigh the blue")
        XCTAssertLessThan(color?.blue ?? 1, 0.2)
    }

    func testTextIsWhiteUnlessItWouldBeHardToRead() {
        XCTAssertFalse(SiteColor.prefersDarkText(on: .init(red: 1, green: 0, blue: 0)), "YouTube red")
        XCTAssertFalse(SiteColor.prefersDarkText(on: .init(red: 0, green: 0.478, blue: 1)), "system blue")
        XCTAssertFalse(SiteColor.prefersDarkText(on: .init(red: 0.1, green: 0.1, blue: 0.1)), "near black")
        XCTAssertTrue(SiteColor.prefersDarkText(on: .init(red: 1, green: 0.84, blue: 0)), "yellow")
        XCTAssertTrue(SiteColor.prefersDarkText(on: .init(red: 0.2, green: 0.78, blue: 0.35)), "green")
        XCTAssertTrue(SiteColor.prefersDarkText(on: .init(red: 1, green: 1, blue: 1)), "white")
    }
}

/// Which recorded favicon a site search's color is read from: the profile's
/// visits to the site's host, with or without `www.`, and no one else's.
nonisolated final class SiteFaviconURLTests: XCTestCase {

    @MainActor func testTheHostWithOrWithoutWWWAndOnlyInScope() throws {
        let history = try HistoryDatabase(dbQueue: try DatabaseQueue())
        let provider = SuggestionProvider(db: history)
        history.recordVisit(url: "https://www.example.com/a", title: "A",
                            faviconURL: "https://www.example.com/icon.png", spaceID: "mine")
        history.recordVisit(url: "https://other.org/", title: "O",
                            faviconURL: "https://other.org/icon.png", spaceID: "theirs")

        XCTAssertEqual(provider.siteFaviconURL(forHost: "example.com", historySpaceIDs: ["mine"]),
                       "https://www.example.com/icon.png", "the www. host, from a page below its root")
        XCTAssertNil(provider.siteFaviconURL(forHost: "other.org", historySpaceIDs: ["mine"]),
                     "visited only from another profile's space")
        XCTAssertEqual(provider.siteFaviconURL(forHost: "other.org", historySpaceIDs: ["theirs"]),
                       "https://other.org/icon.png")
        XCTAssertNil(provider.siteFaviconURL(forHost: "example.com", historySpaceIDs: []), "Private: no scope")
        XCTAssertNil(provider.siteFaviconURL(forHost: "never.example", historySpaceIDs: ["mine"]))
    }
}

/// The chip in a real palette: the space's color at once, the site's when the
/// profile has a recorded icon with a clear color, nothing read in Private.
nonisolated final class SiteSearchChipColorTests: XCTestCase {

    private var window: NSWindow?
    private var palette: CommandPaletteView?
    private var createdTabs: [BrowserTab] = []
    private var originalFetch: ((URL, @escaping @Sendable (NSImage?) -> Void) -> Void)?
    private var fetched: [URL] = []

    @MainActor override func setUp() async throws {
        try await super.setUp()
        originalFetch = FaviconLoader.shared.fetch
        FaviconLoader.shared.resetForTesting()
        let red = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill(); rect.fill(); return true
        }
        nonisolated(unsafe) let image = red  // handed straight to the completion, never shared
        FaviconLoader.shared.fetch = { [weak self] url, completion in
            MainActor.assumeIsolated { self?.fetched.append(url) }  // the loader calls it on the main thread
            completion(image)
        }
    }

    @MainActor override func tearDown() async throws {
        palette?.delegate = nil
        palette?.dismiss()
        palette = nil
        window?.close()
        window = nil
        for tab in createdTabs { tab.teardown() }
        createdTabs.removeAll()
        if let originalFetch { FaviconLoader.shared.fetch = originalFetch }
        FaviconLoader.shared.resetForTesting()
        try await super.tearDown()
    }

    /// A palette over a store with one space of `colorHex`, whose history
    /// recorded a favicon for example.com when `visited`.
    @MainActor private func showPalette(colorHex: String = "34C759", visited: Bool,
                                        privateScope: Bool = false) throws -> CommandPaletteView {
        let store = TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()),
                             historyDB: try HistoryDatabase(dbQueue: try DatabaseQueue()))
        let profile = store.addProfile(name: "Chip")
        let space = store.addSpace(name: "Green", emoji: "🟢", colorHex: colorHex, profileID: profile.id)
        store.undoManager.removeAllActions()

        let sites = SiteSearchStore(database: try AppDatabase(dbQueue: DatabaseQueue()))
        for entry in sites.entries { sites.remove(id: entry.id) }
        XCTAssertNotNil(sites.add(SiteSearch(name: "Example", keyword: "ex",
                                             urlTemplate: "https://www.example.com/find?q=%s")))

        let history = try HistoryDatabase(dbQueue: try DatabaseQueue())
        if visited {
            history.recordVisit(url: "https://www.example.com/", title: "Example",
                                faviconURL: "https://www.example.com/icon.png", spaceID: space.id.uuidString)
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        self.window = window
        let palette = CommandPaletteView()
        palette.tabStore = store
        palette.activeSpaceID = space.id
        palette.siteSearches = sites
        palette.suggestionProvider = SuggestionProvider(db: history)
        palette.historySpaceIDs = privateScope ? [] : [space.id.uuidString]
        self.palette = palette
        palette.show(in: try XCTUnwrap(window.contentView))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        for ch in "ex " { editor.insertText(String(ch), replacementRange: editor.selectedRange()) }
        XCTAssertEqual(palette.activeSiteSearch?.name, "Example")
        return palette
    }

    @MainActor private func fillRGB(_ palette: CommandPaletteView) -> SiteColor.RGB? {
        SiteColor.RGB(palette.siteSearchChip.fill)
    }

    @MainActor private func spin(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    @MainActor func testTheChipStartsInTheSpacesColorAndTakesTheSitesIcon() throws {
        let palette = try showPalette(visited: true)
        let green = try XCTUnwrap(NSColor(hex: "34C759").flatMap(SiteColor.RGB.init))
        let start = try XCTUnwrap(fillRGB(palette))
        XCTAssertEqual(start.green, green.green, accuracy: 0.01, "the space's color at once")

        spin { (fillRGB(palette)?.red ?? 0) > 0.95 }
        let site = try XCTUnwrap(fillRGB(palette))
        XCTAssertEqual(site.red, 1, accuracy: 0.02, "the icon's red")
        XCTAssertEqual(site.green, 0, accuracy: 0.02)
        XCTAssertEqual(fetched.map(\.absoluteString), ["https://www.example.com/icon.png"])
        XCTAssertEqual(palette.siteSearchChip.textColor, .white, "white reads on red")
    }

    @MainActor func testASiteTheProfileNeverVisitedKeepsTheSpacesColorAndFetchesNothing() throws {
        let palette = try showPalette(colorHex: "FF9500", visited: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let fill = try XCTUnwrap(fillRGB(palette))
        XCTAssertEqual(fill.red, 1, accuracy: 0.01)
        XCTAssertEqual(fill.green, 0x95 / 255.0, accuracy: 0.01, "the space's orange")
        XCTAssertEqual(fetched, [])
        XCTAssertEqual(palette.siteSearchChip.textColor, .black, "dark text on orange")
    }

    @MainActor func testARescopedPaletteDropsTheOldProfilesSiteColor() throws {
        let palette = try showPalette(visited: true)
        spin { (fillRGB(palette)?.red ?? 0) > 0.95 }
        // The window switched to a space of a profile with no history scope.
        palette.historySpaceIDs = []
        palette.reloadSuggestions()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let fill = try XCTUnwrap(fillRGB(palette))
        XCTAssertLessThan(fill.red, 0.5, "back to the space's green, not the old profile's site red")
    }

    @MainActor func testAPrivatePaletteReadsNoHistoryForTheColor() throws {
        let palette = try showPalette(visited: true, privateScope: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(fetched, [], "no scope, no lookup")
        let fill = try XCTUnwrap(fillRGB(palette))
        XCTAssertLessThan(fill.red, 0.5, "still the space's green")
    }
}
