import XCTest
import WebKit
import GRDB
@testable import Detour

/// TASK-51: while a Peek overlay is presented it is the page the user is looking
/// at, so it — not the host hidden behind it — is the window's
/// extension-visible active tab. `selectedTabID` is unchanged by that rule; it
/// still names the focused pane / the peek's host.
///
/// Two levels are covered here: the pure rule
/// (`extensionActiveTab(selected:peekPresented:)`) and the announcement funnel
/// (`ExtensionActiveTabTracker`), driven through the `ExtensionTabLifecycle`
/// seam with a recording notifier so no extension has to be installed.
@MainActor
final class ExtensionActiveTabTests: XCTestCase {

    // MARK: - Recording notifier

    private struct Activation: Equatable, CustomStringConvertible {
        let tabID: UUID
        let previousTabID: UUID?

        var description: String {
            "activate(\(tabID.uuidString.prefix(4)), prev: \(previousTabID?.uuidString.prefix(4) ?? "-"))"
        }
    }

    private final class RecordingNotifier: ExtensionTabLifecycleNotifying {
        var activations: [Activation] = []
        var opened: [UUID] = []
        var closed: [UUID] = []

        func didOpen(_ tab: BrowserTab, in profile: Profile, contexts: [WKWebExtensionContext]?) {
            opened.append(tab.id)
        }
        func didClose(_ tab: BrowserTab, in profile: Profile) {
            closed.append(tab.id)
        }
        func didActivate(_ tab: BrowserTab, previousActiveTab: BrowserTab?, in profile: Profile,
                         contexts: [WKWebExtensionContext]?) {
            activations.append(Activation(tabID: tab.id, previousTabID: previousActiveTab?.id))
        }
        func didChangeProperties(_ tab: BrowserTab, in profile: Profile,
                                 properties: WKWebExtension.TabChangedProperties) {}
    }

    private var notifier = RecordingNotifier()
    private var previousNotifier: (any ExtensionTabLifecycleNotifying)!
    private var createdTabs: [BrowserTab] = []
    private var controller: BrowserWindowController?

    override func setUp() {
        super.setUp()
        notifier = RecordingNotifier()
        previousNotifier = ExtensionTabLifecycle.notifier
        ExtensionTabLifecycle.notifier = notifier
    }

    override func tearDown() {
        controller?.window?.close()
        controller = nil
        for tab in createdTabs { tab.teardown() }
        createdTabs.removeAll()
        ExtensionTabLifecycle.notifier = previousNotifier
        super.tearDown()
    }

    /// The notifier is a process-wide seam: only assert on the tabs a test made.
    private func activations(among tabs: [BrowserTab]) -> [Activation] {
        let ids = Set(tabs.map(\.id))
        return notifier.activations.filter { ids.contains($0.tabID) }
    }

    private func makeLiveTab() -> BrowserTab {
        let tab = BrowserTab(configuration: WKWebViewConfiguration())
        createdTabs.append(tab)
        return tab
    }

    /// A live tab already reported open to `profile`'s contexts — the tracker
    /// only names a *registered* previous tab in a handover.
    private func makeOpenTab(in profile: Profile) -> BrowserTab {
        let tab = makeLiveTab()
        ExtensionTabLifecycle.didOpen(tab, in: profile)
        return tab
    }

    private func makeParkedTab() -> BrowserTab {
        BrowserTab(id: UUID(), title: "Parked", url: URL(string: "https://example.com/parked"),
                   faviconURL: nil, cachedInteractionState: nil, spaceID: UUID())
    }

    /// A private store with one profile, so activations have somewhere to go.
    private func makeProfile() throws -> Profile {
        let db = try AppDatabase(dbQueue: try DatabaseQueue())
        let store = TabStore(appDB: db)
        return store.addProfile(name: "ActiveTab")
    }

    // MARK: - The pure rule

    func testActiveTabIsTheSelectedTabWithNoPeek() {
        let host = makeLiveTab()

        XCTAssertTrue(extensionActiveTab(selected: host, peekPresented: false) === host)
    }

    func testActiveTabIsThePresentedPeek() {
        let host = makeLiveTab()
        host.peekTab = makeLiveTab()

        XCTAssertTrue(extensionActiveTab(selected: host, peekPresented: true) === host.peekTab,
                      "the presented peek is the page the user is looking at")
    }

    func testAPeekThatIsNotPresentedIsNotActive() {
        let host = makeLiveTab()
        host.peekTab = makeLiveTab()

        XCTAssertTrue(extensionActiveTab(selected: host, peekPresented: false) === host)
    }

    func testAParkedPeekIsNotActiveEvenWhilePresented() {
        let host = makeLiveTab()
        host.peekTab = makeParkedTab()

        XCTAssertTrue(extensionActiveTab(selected: host, peekPresented: true) === host,
                      "a peek with no web view was never reported open, so it cannot be active")
    }

    func testNoSelectionHasNoActiveTab() {
        XCTAssertNil(extensionActiveTab(selected: nil, peekPresented: true))
    }

    // MARK: - The announcement funnel

    func testFirstAnnouncementHasNoPreviousTab() throws {
        let profile = try makeProfile()
        let host = makeLiveTab()
        let tracker = ExtensionActiveTabTracker()

        tracker.announce(host, in: profile)

        XCTAssertEqual(activations(among: [host]), [Activation(tabID: host.id, previousTabID: nil)])
    }

    func testPresentingAPeekHandsOverFromTheHost() throws {
        let profile = try makeProfile()
        let host = makeOpenTab(in: profile)
        let peek = makeOpenTab(in: profile)
        host.peekTab = peek
        let tracker = ExtensionActiveTabTracker()

        tracker.announce(host, in: profile)
        tracker.announce(peek, in: profile)

        XCTAssertEqual(activations(among: [host, peek]),
                       [Activation(tabID: host.id, previousTabID: nil),
                        Activation(tabID: peek.id, previousTabID: host.id)])
    }

    func testClosingThePeekHandsBackToTheHost() throws {
        let profile = try makeProfile()
        let host = makeOpenTab(in: profile)
        let peek = makeOpenTab(in: profile)
        host.peekTab = peek
        let tracker = ExtensionActiveTabTracker()

        tracker.announce(host, in: profile)
        tracker.announce(peek, in: profile)
        tracker.announce(host, in: profile)

        XCTAssertEqual(activations(among: [host, peek]),
                       [Activation(tabID: host.id, previousTabID: nil),
                        Activation(tabID: peek.id, previousTabID: host.id),
                        Activation(tabID: host.id, previousTabID: peek.id)])
    }

    func testAnnouncingTheSameTabTwiceReportsItOnce() throws {
        let profile = try makeProfile()
        let host = makeLiveTab()
        let tracker = ExtensionActiveTabTracker()

        tracker.announce(host, in: profile)
        tracker.announce(host, in: profile)

        XCTAssertEqual(activations(among: [host]), [Activation(tabID: host.id, previousTabID: nil)],
                       "overlapping paths (select, pane focus, peek restore) must not double-announce")
    }

    func testDeselectingClearsThePreviousTabWithoutAnnouncing() throws {
        let profile = try makeProfile()
        let host = makeOpenTab(in: profile)
        let other = makeOpenTab(in: profile)
        let tracker = ExtensionActiveTabTracker()

        tracker.announce(host, in: profile)
        tracker.announce(nil, in: profile)
        tracker.announce(other, in: profile)

        XCTAssertEqual(activations(among: [host, other]),
                       [Activation(tabID: host.id, previousTabID: nil),
                        Activation(tabID: other.id, previousTabID: nil)],
                       "nothing was active in between, so the handover has no previous tab")
    }

    /// WebKit runs `getOrCreateTab` on `previousActiveTab`, so a tab the target
    /// contexts do not know would be resurrected there as a phantom tab — which
    /// is exactly what a space switch across profiles would hand them.
    func testAPreviousTabFromAnotherProfileIsNotReported() throws {
        let profileA = try makeProfile()
        let profileB = try makeProfile()
        let x = makeOpenTab(in: profileA)
        let y = makeOpenTab(in: profileB)
        let tracker = ExtensionActiveTabTracker()

        tracker.announce(x, in: profileA)
        tracker.announce(y, in: profileB)

        XCTAssertEqual(activations(among: [x, y]),
                       [Activation(tabID: x.id, previousTabID: nil),
                        Activation(tabID: y.id, previousTabID: nil)],
                       "another profile's contexts have never heard of x")
    }

    /// `expandPeekToNewTab` reports the peek closed before the handover
    /// `selectTab` fires.
    func testAClosedPreviousTabIsNotReported() throws {
        let profile = try makeProfile()
        let x = makeOpenTab(in: profile)
        let tracker = ExtensionActiveTabTracker()

        tracker.announce(x, in: profile)
        ExtensionTabLifecycle.didClose(x)
        let y = makeOpenTab(in: profile)
        tracker.announce(y, in: profile)

        XCTAssertEqual(activations(among: [x, y]),
                       [Activation(tabID: x.id, previousTabID: nil),
                        Activation(tabID: y.id, previousTabID: nil)],
                       "a closed tab must not be resurrected as the previous active tab")
    }

    func testAWindowlessProfileAnnouncesNothing() {
        let host = makeLiveTab()
        let tracker = ExtensionActiveTabTracker()

        tracker.announce(host, in: nil)

        XCTAssertTrue(activations(among: [host]).isEmpty)
    }

    // MARK: - End to end in a real window

    /// Drives the real controller: selecting a tab, presenting a Peek on it and
    /// closing the Peek must hand activation over and back (AC1/AC2).
    func testPresentingAndClosingAPeekMovesTheWindowsActiveTab() throws {
        let wc = BrowserWindowController(incognito: true)
        controller = wc
        let space = try XCTUnwrap(wc.activeSpace)
        let host = wc.store.addTab(in: space, url: URL(string: "https://host.example.com/"))
        createdTabs.append(host)
        // Idempotent in production (the store observer does this); keeps the test
        // independent of whether the shared ExtensionManager observes this store.
        ExtensionTabLifecycle.didOpen(host, in: try XCTUnwrap(space.profile))

        wc.selectTab(id: host.id)
        XCTAssertTrue(wc.extensionActiveTab === host)

        wc.showPeekOverlay(url: URL(string: "https://peeked.example.org/")!)
        let peek = try XCTUnwrap(host.peekTab)
        XCTAssertTrue(wc.extensionActiveTab === peek, "the presented peek is the active tab")
        XCTAssertEqual(wc.selectedTabID, host.id, "selection still names the host pane")
        XCTAssertEqual(activations(among: [host, peek]),
                       [Activation(tabID: host.id, previousTabID: nil),
                        Activation(tabID: peek.id, previousTabID: host.id)])

        wc.closePeekOverlay()
        XCTAssertTrue(wc.extensionActiveTab === host)
        XCTAssertEqual(activations(among: [host, peek]).last,
                       Activation(tabID: host.id, previousTabID: peek.id),
                       "closing the overlay re-activates the host")
    }

    /// A tab switch onto a tab that has a peek must announce the peek once —
    /// not the host first and then the peek (TASK-51 F2).
    func testSwitchingOntoATabWithAPeekAnnouncesOnlyThePeek() throws {
        let wc = BrowserWindowController(incognito: true)
        controller = wc
        let space = try XCTUnwrap(wc.activeSpace)
        let profile = try XCTUnwrap(space.profile)
        let host = wc.store.addTab(in: space, url: URL(string: "https://host.example.com/"))
        let other = wc.store.addTab(in: space, url: URL(string: "https://other.example.com/"))
        createdTabs.append(contentsOf: [host, other])
        ExtensionTabLifecycle.didOpen(host, in: profile)
        ExtensionTabLifecycle.didOpen(other, in: profile)

        wc.selectTab(id: host.id)
        wc.showPeekOverlay(url: URL(string: "https://peeked.example.org/")!)
        let peek = try XCTUnwrap(host.peekTab)
        wc.selectTab(id: other.id)

        notifier.activations.removeAll()
        wc.selectTab(id: host.id)

        XCTAssertEqual(activations(among: [host, other, peek]),
                       [Activation(tabID: peek.id, previousTabID: other.id)],
                       "the restored peek is the only activation for the switch")
        XCTAssertTrue(wc.extensionActiveTab === peek)
    }
}
