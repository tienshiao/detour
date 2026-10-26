import XCTest
import CoreServices
@testable import Detour

/// TASK-191.2: where a link from another app opens once its route decision is
/// known (`linkPlacement`), and whose bundle ID a Get URL event's sender is
/// (`linkSenderBundleID`). Pure; the AppKit side is `ExternalLinkRoutingTests`.
final class LinkPlacementTests: XCTestCase {

    private let work = UUID()
    private let personal = UUID()
    private let other = UUID()

    private typealias Window = LinkPlacementWindow<String>

    private func normal(_ id: String, _ space: UUID?) -> Window {
        Window(id: id, activeSpaceID: space, isPrivate: false)
    }

    private func privateWindow(_ id: String) -> Window {
        Window(id: id, activeSpaceID: UUID(), isPrivate: true)
    }

    private func place(_ decision: LinkRouteDecision, _ windows: [Window]) -> LinkPlacement<String> {
        linkPlacement(for: decision, windows: windows)
    }

    // MARK: - A specific space

    func testASpaceShownByAWindowOpensInThatWindow() {
        XCTAssertEqual(place(.openInSpace(work), [normal("a", personal), normal("b", work)]), .openInWindow("b"))
    }

    func testASpaceShownByTheFrontWindowOpensThere() {
        XCTAssertEqual(place(.openInSpace(work), [normal("a", work), normal("b", personal)]), .openInWindow("a"))
    }

    func testASpaceShownBySeveralWindowsOpensInTheMostRecentOfThem() {
        let windows = [normal("front", personal), normal("recent", work), normal("older", work)]
        XCTAssertEqual(place(.openInSpace(work), windows), .openInWindow("recent"))
    }

    func testASpaceShownByNoWindowSwitchesTheMostRecentNormalWindow() {
        let windows = [normal("front", personal), normal("back", other)]
        XCTAssertEqual(place(.openInSpace(work), windows), .switchWindow("front", toSpace: work))
    }

    func testAPrivateWindowInFrontIsNeverSwitchedToANormalSpace() {
        let windows = [privateWindow("p"), normal("normal", personal)]
        XCTAssertEqual(place(.openInSpace(work), windows), .switchWindow("normal", toSpace: work))
    }

    func testANormalWindowWithoutAnActiveSpaceCanBeSwitched() {
        XCTAssertEqual(place(.openInSpace(work), [normal("empty", nil)]), .switchWindow("empty", toSpace: work))
    }

    func testOnlyPrivateWindowsOpenANewWindowOnTheSpace() {
        XCTAssertEqual(place(.openInSpace(work), [privateWindow("p1"), privateWindow("p2")]),
                       .openInNewWindow(space: work))
    }

    func testNoWindowsOpenANewWindowOnTheSpace() {
        XCTAssertEqual(place(.openInSpace(work), []), .openInNewWindow(space: work))
    }

    func testAPrivateWindowNeverCountsAsShowingANormalSpace() {
        // A Private window shows only its own space; were an id ever shared,
        // the link must still not open in Private.
        let windows = [Window(id: "p", activeSpaceID: work, isPrivate: true), normal("n", personal)]
        XCTAssertEqual(place(.openInSpace(work), windows), .switchWindow("n", toSpace: work))
    }

    // MARK: - Private window

    func testPrivateOpensInTheMostRecentPrivateWindow() {
        let windows = [normal("n", work), privateWindow("p1"), normal("m", personal), privateWindow("p2")]
        XCTAssertEqual(place(.privateWindow, windows), .openInPrivateWindow("p1"))
    }

    func testPrivateWithNoPrivateWindowOpensANewOne() {
        XCTAssertEqual(place(.privateWindow, [normal("n", work)]), .openInNewPrivateWindow)
        XCTAssertEqual(place(.privateWindow, []), .openInNewPrivateWindow)
    }

    // MARK: - Today's behaviour

    func testMostRecentSpaceIsTodaysBehaviour() {
        XCTAssertEqual(place(.mostRecentSpace, [normal("a", work), privateWindow("p")]), .mostRecentSpace)
        XCTAssertEqual(place(.mostRecentSpace, []), .mostRecentSpace)
    }

    func testQuarantineIsTodaysBehaviourUntilItExists() {
        // TASK-194 (Quarantine) is not built.
        XCTAssertEqual(place(.quarantine, [normal("a", work)]), .mostRecentSpace)
    }

    func testQuickDetourOpensAQuickDetourWhateverTheWindows() {
        // TASK-193.5: never the Most Recent Space fallback.
        XCTAssertEqual(place(.quickDetour, [normal("a", work)]), .openInQuickDetour)
        XCTAssertEqual(place(.quickDetour, [privateWindow("p"), normal("a", work)]), .openInQuickDetour)
        XCTAssertEqual(place(.quickDetour, []), .openInQuickDetour)
    }

    func testStayIsTodaysBehaviour() {
        // The resolver never says stay for a link from another app; if it did,
        // the link must still open somewhere.
        XCTAssertEqual(place(.stay, [normal("a", work)]), .mostRecentSpace)
    }

    // MARK: - The sender

    private func getURLEvent() -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
                               targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                               transactionID: AETransactionID(kAnyTransactionID))
    }

    private let bundleIDs: [pid_t: String] = [501: "com.tinyspeck.slackmacgap", 77: "com.apple.mail"]
    private func lookup(_ pid: pid_t) -> String? { bundleIDs[pid] }

    // `keySenderPIDAttr` is stamped by the Apple Event Manager on delivery and
    // cannot be set on an event built here (`setAttribute` ignores it), so
    // that path is checked at runtime (docs/harness/task191-2-harness.patch).

    func testTheAddressNamesTheSenderProcess() {
        let event = getURLEvent()
        event.setAttribute(NSAppleEventDescriptor(processIdentifier: 77), forKeyword: AEKeyword(keyAddressAttr))
        XCTAssertEqual(linkSenderPID(of: event), 77, "a kernel PID descriptor, read from its bytes")
    }

    func testAnEventWithoutASenderNamesNoProcess() {
        XCTAssertNil(linkSenderPID(of: nil))
        XCTAssertNil(linkSenderPID(of: getURLEvent()))
    }

    func testTheSenderPIDNamesTheSendingApp() {
        XCTAssertEqual(linkSenderBundleID(senderPID: 501, ownPID: 9, bundleIDForPID: lookup), "com.tinyspeck.slackmacgap")
        XCTAssertEqual(linkSenderBundleID(senderPID: 77, ownPID: 9, bundleIDForPID: lookup), "com.apple.mail")
    }

    func testDetourItselfIsNoSender() {
        XCTAssertNil(linkSenderBundleID(senderPID: 501, ownPID: 501, bundleIDForPID: lookup))
    }

    func testNoPIDOrNoBundleIDIsNoSender() {
        XCTAssertNil(linkSenderBundleID(senderPID: nil, ownPID: 9, bundleIDForPID: { _ in "x" }))
        XCTAssertNil(linkSenderBundleID(senderPID: 0, ownPID: 9, bundleIDForPID: { _ in "x" }))
        XCTAssertNil(linkSenderBundleID(senderPID: 4242, ownPID: 9, bundleIDForPID: lookup),
                     "a process without a bundle ID (a command-line tool) matches no source-app route")
        XCTAssertNil(linkSenderBundleID(senderPID: 4242, ownPID: 9, bundleIDForPID: { _ in "  " }))
    }
}
