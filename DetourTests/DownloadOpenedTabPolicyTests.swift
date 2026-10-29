import XCTest
@testable import Detour

final class DownloadOpenedTabPolicyTests: XCTestCase {

    private typealias Policy = DownloadOpenedTabPolicy

    // MARK: - Which tab closes

    func testANormalTabThatNeverShowedAPageCloses() {
        XCTAssertTrue(Policy.closesTab(.init(isNormalTab: true, hasCommittedPage: false)))
    }

    func testATabThatShowedAPageStaysOnIt() {
        XCTAssertFalse(Policy.closesTab(.init(isNormalTab: true, hasCommittedPage: true)))
    }

    func testAPinnedOrFavouriteBackingTabNeverCloses() {
        XCTAssertFalse(Policy.closesTab(.init(isNormalTab: false, hasCommittedPage: false)))
        XCTAssertFalse(Policy.closesTab(.init(isNormalTab: false, hasCommittedPage: true)))
    }

    // MARK: - Putting the windows back

    private let source = "source"
    private let other = "other"
    private let spaceA = UUID()
    private let spaceB = UUID()

    private func windows(open: Set<String>, key: String?, spaces: [String: UUID]) -> Policy.Windows<String> {
        .init(open: open, key: key, activeSpaceID: spaces)
    }

    /// The route switched the clicked window itself to another space.
    func testTheClickedWindowSwitchedToTheRoutedSpaceSwitchesBack() {
        let open = Policy.RoutedOpen(sourceWindow: source, placedWindow: source, placedWindowWasCreated: false, placedWindowIsPrivate: false,
                                     placedWindowPreviousSpaceID: spaceA, routedSpaceID: spaceB)
        XCTAssertEqual(Policy.restoration(of: open, windows: windows(open: [source], key: source, spaces: [source: spaceB])),
                       [.switchSpace(source, to: spaceA)])
    }

    /// Another window was switched and brought forward.
    func testAnotherWindowSwitchedSwitchesBackAndTheClickedWindowComesForward() {
        let open = Policy.RoutedOpen(sourceWindow: source, placedWindow: other, placedWindowWasCreated: false, placedWindowIsPrivate: false,
                                     placedWindowPreviousSpaceID: spaceA, routedSpaceID: spaceB)
        XCTAssertEqual(Policy.restoration(of: open, windows: windows(open: [source, other], key: other,
                                                                     spaces: [source: spaceA, other: spaceB])),
                       [.switchSpace(other, to: spaceA), .bringToFront(source)])
    }

    /// Another window already on the routed space was only brought forward.
    func testAWindowOnlyBroughtForwardGoesBehindTheClickedWindowAgain() {
        let open = Policy.RoutedOpen(sourceWindow: source, placedWindow: other, placedWindowWasCreated: false, placedWindowIsPrivate: false,
                                     placedWindowPreviousSpaceID: nil, routedSpaceID: spaceB)
        XCTAssertEqual(Policy.restoration(of: open, windows: windows(open: [source, other], key: other,
                                                                     spaces: [source: spaceA, other: spaceB])),
                       [.bringToFront(source)])
    }

    /// A window (or Private window) opened for the tab closes.
    func testAWindowOpenedForTheTabCloses() {
        let open = Policy.RoutedOpen(sourceWindow: source, placedWindow: other, placedWindowWasCreated: true, placedWindowIsPrivate: false,
                                     placedWindowPreviousSpaceID: nil, routedSpaceID: spaceB)
        XCTAssertEqual(Policy.restoration(of: open, windows: windows(open: [source, other], key: other,
                                                                     spaces: [source: spaceA, other: spaceB])),
                       [.closeWindow(other), .bringToFront(source)])
    }

    /// A Private window opened for the tab holds the download's only listing:
    /// closing it would cancel the download, so it stays, in front.
    func testAPrivateWindowOpenedForTheTabStays() {
        let open = Policy.RoutedOpen(sourceWindow: source, placedWindow: other, placedWindowWasCreated: true,
                                     placedWindowIsPrivate: true, placedWindowPreviousSpaceID: nil, routedSpaceID: spaceB)
        XCTAssertEqual(Policy.restoration(of: open, windows: windows(open: [source, other], key: other,
                                                                     spaces: [source: spaceA, other: spaceB])), [])
    }

    /// An existing Private window the link was sent to goes behind the
    /// clicked window again; its download goes on there.
    func testAnExistingPrivateWindowGoesBehindTheClickedWindowAgain() {
        let open = Policy.RoutedOpen(sourceWindow: source, placedWindow: other, placedWindowWasCreated: false,
                                     placedWindowIsPrivate: true, placedWindowPreviousSpaceID: nil, routedSpaceID: spaceB)
        XCTAssertEqual(Policy.restoration(of: open, windows: windows(open: [source, other], key: other,
                                                                     spaces: [source: spaceA, other: spaceB])),
                       [.bringToFront(source)])
    }

    /// The user moved on before the response came: nothing is put back.
    func testNothingIsPutBackOnceTheUserMovedOn() {
        let switched = Policy.RoutedOpen(sourceWindow: source, placedWindow: other, placedWindowWasCreated: false, placedWindowIsPrivate: false,
                                         placedWindowPreviousSpaceID: spaceA, routedSpaceID: spaceB)
        XCTAssertEqual(Policy.restoration(of: switched, windows: windows(open: [source, other], key: source,
                                                                         spaces: [source: spaceA, other: spaceB])),
                       [], "another window is key")
        XCTAssertEqual(Policy.restoration(of: switched, windows: windows(open: [source, other], key: other,
                                                                         spaces: [source: spaceA, other: spaceA])),
                       [], "the placed window shows another space now")
        XCTAssertEqual(Policy.restoration(of: switched, windows: windows(open: [source], key: source,
                                                                         spaces: [source: spaceA])),
                       [], "the placed window is gone")
    }

    /// The clicked window closed meanwhile: the placed window is still put back.
    func testAClosedSourceWindowIsNotBroughtForward() {
        let open = Policy.RoutedOpen(sourceWindow: source, placedWindow: other, placedWindowWasCreated: false, placedWindowIsPrivate: false,
                                     placedWindowPreviousSpaceID: spaceA, routedSpaceID: spaceB)
        XCTAssertEqual(Policy.restoration(of: open, windows: windows(open: [other], key: other, spaces: [other: spaceB])),
                       [.switchSpace(other, to: spaceA)])
        let unknown = Policy.RoutedOpen<String>(sourceWindow: nil, placedWindow: other, placedWindowWasCreated: true, placedWindowIsPrivate: false,
                                                placedWindowPreviousSpaceID: nil, routedSpaceID: spaceB)
        XCTAssertEqual(Policy.restoration(of: unknown, windows: windows(open: [other], key: other, spaces: [other: spaceB])),
                       [.closeWindow(other)])
    }
}
