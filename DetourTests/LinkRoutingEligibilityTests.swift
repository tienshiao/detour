import XCTest
@testable import Detour

/// TASK-191.4: which links inside Detour are routed by Link Routes at all
/// (`linkRoutingEligibility`, `typedURLIsRoutable`), the precedence between a
/// route and the pinned/favourite Peek intercept, and what the two layers give
/// together with `resolveLinkRoute`.
final class LinkRoutingEligibilityTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    private let page = "https://example.com/start"

    /// A link activation in `decidePolicyFor`, as WebKit reports a real click.
    private func click(_ target: String, from page: String? = "https://example.com/start",
                       modifiers: LinkClickModifiers = [], gesture: Bool = true,
                       mainFrame: Bool = true, newWindow: Bool = false, redirect: Bool = false,
                       linkActivation: Bool = true, inPeek: Bool = false,
                       quickDetourClick: Bool = true) -> LinkRoutingEligibility {
        linkRoutingEligibility(InPageLinkRequest(
            entry: .navigationAction(isLinkActivation: linkActivation, targetsMainFrame: mainFrame && !newWindow,
                                     opensNewWindow: newWindow, isRedirect: redirect),
            modifiers: modifiers, isUserGesture: gesture, isInPeek: inPeek,
            pageURL: page.map(url), targetURL: url(target), quickDetourClickEnabled: quickDetourClick))
    }

    /// A page's own new window in `createWebViewWith`.
    private func windowOpen(_ target: String, popup: Bool = false, gesture: Bool = true,
                            linkActivation: Bool = false, inPeek: Bool = false) -> LinkRoutingEligibility {
        linkRoutingEligibility(InPageLinkRequest(
            entry: .pageWindowRequest(isLinkActivation: linkActivation, wantsPopup: popup),
            isUserGesture: gesture, isInPeek: inPeek, pageURL: url(page), targetURL: url(target)))
    }

    // MARK: - New-tab opens route

    func testCommandClickRoutesWhateverTheHost() {
        XCTAssertEqual(click("https://other.test/x", modifiers: .command), .routable(.commandClick))
        XCTAssertEqual(click("https://example.com/y", modifiers: .command), .routable(.commandClick),
                       "a new tab, so the same host routes too")
    }

    func testCommandWinsOverShiftAsTheDelegateOrderDoes() {
        XCTAssertEqual(click("https://other.test/", modifiers: [.command, .shift]), .routable(.commandClick))
    }

    // MARK: - Opt-Cmd-click: Quick Detour (TASK-193.5)

    func testOptionCommandIsTheQuickDetourClickAndIsNeverRouted() {
        // The user chose Quick Detour: Link Routes do not move it.
        XCTAssertEqual(click("https://other.test/", modifiers: [.command, .option]), .notRouted(.quickDetourClick))
        XCTAssertEqual(click("https://example.com/b", modifiers: [.command, .option]), .notRouted(.quickDetourClick))
        XCTAssertEqual(click("https://other.test/", modifiers: [.command, .option, .shift]),
                       .notRouted(.quickDetourClick), "Shift does not matter once Cmd and Option are held")
        XCTAssertEqual(click("https://other.test/", modifiers: [.command, .option], mainFrame: false),
                       .notRouted(.quickDetourClick), "in any frame")
        XCTAssertEqual(click("https://other.test/", modifiers: [.command, .option], newWindow: true),
                       .notRouted(.quickDetourClick), "a target=_blank link too")
    }

    func testWithTheSettingOffOptionCommandIsACommandClickAsBefore() {
        XCTAssertEqual(click("https://other.test/", modifiers: [.command, .option], quickDetourClick: false),
                       .routable(.commandClick))
    }

    func testOptionCommandToANonWebURLIsNotRoutedAndNotAQuickDetour() {
        XCTAssertEqual(click("mailto:a@example.com", modifiers: [.command, .option]), .notRouted(.notWebURL))
    }

    func testTheModifierBranchesInTheirOrder() {
        let web = url("https://other.test/")
        func branch(_ modifiers: LinkClickModifiers, _ target: URL? = nil, on: Bool = true) -> InPageLinkClickBranch {
            inPageLinkClickBranch(modifiers, target: target ?? web, quickDetourClickEnabled: on)
        }
        XCTAssertEqual(branch([.command, .option]), .quickDetour)
        XCTAssertEqual(branch([.command, .option, .shift]), .quickDetour)
        XCTAssertEqual(branch([.command, .option], on: false), .backgroundTab, "off: Cmd wins over Option as before")
        XCTAssertEqual(branch([.command, .option], url("mailto:a@example.com")), .backgroundTab,
                       "a non-web link keeps the Cmd branch (its own handling)")
        XCTAssertEqual(branch([.command, .option], url("http://example.com/")), .quickDetour)
        XCTAssertEqual(branch(.command), .backgroundTab)
        XCTAssertEqual(branch([.command, .shift]), .backgroundTab)
        XCTAssertEqual(branch(.shift), .peek)
        XCTAssertEqual(branch([.shift, .option]), .peek, "Shift before Option")
        XCTAssertEqual(branch(.option), .split)
        XCTAssertEqual(branch([]), .none)
    }

    func testOptionCommandInAPeekIsNotRouted() {
        XCTAssertEqual(click("https://other.test/", modifiers: [.command, .option], inPeek: true), .notRouted(.inPeek))
    }

    func testABlankTargetLinkRoutesWhateverTheHost() {
        XCTAssertEqual(click("https://other.test/", newWindow: true), .routable(.blankTarget))
        XCTAssertEqual(click("https://example.com/other", newWindow: true), .routable(.blankTarget))
    }

    func testABlankTargetLinkInASubframeStillOpensANewTabAndRoutes() {
        XCTAssertEqual(click("https://other.test/", mainFrame: false, newWindow: true), .routable(.blankTarget))
    }

    func testCommandClickInASubframeRoutes() {
        XCTAssertEqual(click("https://other.test/", modifiers: .command, mainFrame: false), .routable(.commandClick),
                       "a background tab whichever frame the link is in")
    }

    func testATabStyleWindowOpenRoutes() {
        XCTAssertEqual(windowOpen("https://other.test/"), .routable(.scriptedWindow))
        XCTAssertEqual(windowOpen("https://example.com/same"), .routable(.scriptedWindow))
    }

    // MARK: - Plain clicks route only off the host

    func testAPlainClickToAnotherHostRoutes() {
        XCTAssertEqual(click("https://other.test/a"), .routable(.crossHostClick))
    }

    func testAPlainClickOnTheSameHostNeverRoutes() {
        XCTAssertEqual(click("https://example.com/b"), .notRouted(.sameHost))
        XCTAssertEqual(click("https://EXAMPLE.com/b"), .notRouted(.sameHost), "hosts compare without case")
        XCTAssertEqual(click("http://example.com/b"), .notRouted(.sameHost), "the scheme does not matter")
        XCTAssertEqual(click("https://example.com:8443/b"), .notRouted(.sameHost), "nor the port: host, not origin")
        XCTAssertEqual(click("https://example.com./b"), .notRouted(.sameHost), "a trailing dot is the same host")
    }

    func testALeadingWWWIsTheSameHost() {
        XCTAssertEqual(click("https://www.example.com/b"), .notRouted(.sameHost))
        XCTAssertEqual(click("https://example.com/b", from: "https://www.example.com/"), .notRouted(.sameHost))
        XCTAssertEqual(click("https://WWW.example.com/b", from: "https://www.example.com/"), .notRouted(.sameHost))
    }

    func testASubdomainIsAnotherHostNotTheSameSite() {
        // No public-suffix list in the codebase: the rule compares hosts, so
        // mail.example.com is another host than example.com.
        XCTAssertEqual(click("https://mail.example.com/"), .routable(.crossHostClick))
        XCTAssertEqual(click("https://example.com/", from: "https://docs.example.com/"), .routable(.crossHostClick))
    }

    func testWWWIsDroppedOnlyWhenADomainRemains() {
        XCTAssertTrue(isSameLinkRoutingHost("www.example.com", "example.com"))
        XCTAssertTrue(isSameLinkRoutingHost("Example.COM.", "www.example.com"))
        XCTAssertFalse(isSameLinkRoutingHost("www.com", "com"), "www.com is not com")
        XCTAssertFalse(isSameLinkRoutingHost("www.example.com", "www2.example.com"))
        XCTAssertFalse(isSameLinkRoutingHost(nil, "example.com"))
        XCTAssertFalse(isSameLinkRoutingHost(nil, nil), "two hostless pages are not one host")
    }

    func testAPlainClickFromAPageWithNoHostRoutes() {
        // about:blank or a data: page has no host to stay on.
        XCTAssertEqual(click("https://other.test/", from: "about:blank"), .routable(.crossHostClick))
        XCTAssertEqual(click("https://other.test/", from: nil), .routable(.crossHostClick))
    }

    func testALinkOnAnInternalPageIsAClickLikeAnyOther() {
        // The History page's rows are plain links (detour://history).
        XCTAssertEqual(click("https://other.test/", from: "detour://history"), .routable(.crossHostClick))
    }

    func testATopTargetLinkInASubframeIsAMainFrameNavigationAndRoutes() {
        // target=_top: WebKit reports the main frame as the target.
        XCTAssertEqual(click("https://other.test/", mainFrame: true), .routable(.crossHostClick))
    }

    // MARK: - Never routed

    func testRedirectsNeverRoute() {
        // A server redirect keeps the link activation and the user gesture of
        // the click it interrupts (WebKit asks again with _isRedirect).
        XCTAssertEqual(click("https://other.test/landing", redirect: true), .notRouted(.redirect))
        XCTAssertEqual(click("https://other.test/landing", modifiers: .command, redirect: true), .notRouted(.redirect))
        XCTAssertEqual(click("https://other.test/landing", newWindow: true, redirect: true), .notRouted(.redirect))
    }

    func testClientRedirectsAndScriptNavigationsNeverRoute() {
        // location.href = … in a click handler keeps the gesture but is not a link activation.
        XCTAssertEqual(click("https://other.test/", gesture: true, linkActivation: false), .notRouted(.notLinkActivation))
        // location.replace on load, a meta refresh, a timer.
        XCTAssertEqual(click("https://other.test/", gesture: false, linkActivation: false), .notRouted(.notLinkActivation))
    }

    func testAScriptsClickWithoutAUserGestureNeverRoutes() {
        XCTAssertEqual(click("https://other.test/", gesture: false), .notRouted(.noUserGesture))
        XCTAssertEqual(click("https://other.test/", gesture: false, newWindow: true), .notRouted(.noUserGesture))
        XCTAssertEqual(click("https://other.test/", modifiers: .command, gesture: false), .notRouted(.noUserGesture))
        XCTAssertEqual(windowOpen("https://other.test/", gesture: false), .notRouted(.noUserGesture))
    }

    func testShiftClickPeeksAndIsNeverRouted() {
        XCTAssertEqual(click("https://other.test/", modifiers: .shift), .notRouted(.shiftClickPeek))
        XCTAssertEqual(click("https://other.test/", modifiers: [.shift, .option]), .notRouted(.shiftClickPeek),
                       "Shift before Option, as the delegate's branches")
        XCTAssertEqual(click("https://other.test/", modifiers: .shift, newWindow: true), .notRouted(.shiftClickPeek))
    }

    func testOptionClickSplitsAndIsNeverRouted() {
        XCTAssertEqual(click("https://other.test/", modifiers: .option), .notRouted(.optionClickSplit))
        XCTAssertEqual(click("https://example.com/b", modifiers: .option), .notRouted(.optionClickSplit))
    }

    func testAPopupWindowOpenKeepsItsOpenerAndIsNeverRouted() {
        XCTAssertEqual(windowOpen("https://accounts.other.test/signin", popup: true), .notRouted(.popupWindow))
        XCTAssertEqual(windowOpen("https://accounts.other.test/signin", popup: true, gesture: false), .notRouted(.popupWindow))
    }

    func testABlankLinkInCreateWebViewWasAlreadyDecidedByTheNavigationPolicy() {
        XCTAssertEqual(windowOpen("https://other.test/", linkActivation: true), .notRouted(.decidedByNavigationPolicy))
    }

    func testTheLinkMenusActionsAreNeverRouted() {
        let request = InPageLinkRequest(entry: .linkMenuAction, isUserGesture: true, pageURL: url(page),
                                        targetURL: url("https://other.test/"))
        XCTAssertEqual(linkRoutingEligibility(request), .notRouted(.linkMenuAction))
    }

    func testNothingInAPeekIsRouted() {
        XCTAssertEqual(click("https://other.test/", inPeek: true), .notRouted(.inPeek))
        XCTAssertEqual(click("https://other.test/", modifiers: .command, inPeek: true), .notRouted(.inPeek))
        XCTAssertEqual(click("https://other.test/", newWindow: true, inPeek: true), .notRouted(.inPeek))
        XCTAssertEqual(windowOpen("https://other.test/", inPeek: true), .notRouted(.inPeek))
    }

    func testASubframeNavigationNeverRoutes() {
        XCTAssertEqual(click("https://other.test/frame", mainFrame: false), .notRouted(.subframe))
    }

    func testOnlyWebURLsRoute() {
        for target in ["mailto:a@example.com", "detour://history", "data:text/html,hi", "about:blank",
                       "file:///tmp/a.html", "zoommtg://zoom.us/join", "blob:https://example.com/1"] {
            XCTAssertEqual(click(target), .notRouted(.notWebURL), target)
            XCTAssertEqual(click(target, modifiers: .command), .notRouted(.notWebURL), target)
            XCTAssertEqual(click(target, newWindow: true), .notRouted(.notWebURL), target)
            XCTAssertEqual(windowOpen(target), .notRouted(.notWebURL), target)
        }
        XCTAssertEqual(click("HTTPS://other.test/"), .routable(.crossHostClick), "the scheme without case")
    }

    // MARK: - A route against the Peek intercept

    func testARouteElsewhereWinsOverTheAnchorIntercept() {
        let work = UUID()
        XCTAssertEqual(inPageLinkOutcome(routed: .openInSpace(work), anchorPeeks: true), .route(.openInSpace(work)))
        XCTAssertEqual(inPageLinkOutcome(routed: .privateWindow, anchorPeeks: true), .route(.privateWindow))
        XCTAssertEqual(inPageLinkOutcome(routed: .openInSpace(work), anchorPeeks: false), .route(.openInSpace(work)))
    }

    func testWithNoRouteTheAnchorInterceptBehavesAsBefore() {
        XCTAssertEqual(inPageLinkOutcome(routed: nil, anchorPeeks: true), .peek)
        XCTAssertEqual(inPageLinkOutcome(routed: nil, anchorPeeks: false), .asBefore)
    }

    func testStayIsNoRoute() {
        XCTAssertEqual(inPageLinkOutcome(routed: .stay, anchorPeeks: true), .peek)
        XCTAssertEqual(inPageLinkOutcome(routed: .stay, anchorPeeks: false), .asBefore)
    }

    func testTheResolverIsAskedOnlyForARoutableLink() {
        var asked = 0
        XCTAssertNil(routedLinkDecision(.notRouted(.sameHost)) { asked += 1; return .privateWindow })
        XCTAssertEqual(asked, 0)
        XCTAssertNil(routedLinkDecision(.routable(.crossHostClick)) { asked += 1; return .stay },
                     "a route that keeps the link where it is changes nothing")
        XCTAssertEqual(routedLinkDecision(.routable(.blankTarget)) { asked += 1; return .privateWindow }, .privateWindow)
        XCTAssertEqual(asked, 2)
    }

    // MARK: - Typed URLs

    func testATypedURLInTheNewTabPaletteRoutes() {
        XCTAssertTrue(typedURLIsRoutable(url("https://other.test/"), isSearch: false, navigatesInPlace: false))
        XCTAssertTrue(typedURLIsRoutable(url("HTTP://other.test/"), isSearch: false, navigatesInPlace: false))
    }

    func testNavigatingInPlaceNeverRoutes() {
        // Cmd+L or a click on the address bar: the user picked the tab.
        XCTAssertFalse(typedURLIsRoutable(url("https://other.test/"), isSearch: false, navigatesInPlace: true))
    }

    func testASearchNeverRoutes() {
        XCTAssertFalse(typedURLIsRoutable(url("https://www.google.com/search?q=work"), isSearch: true, navigatesInPlace: false))
        XCTAssertFalse(typedURLIsRoutable(url("https://www.google.com/search?q=work"), isSearch: true, navigatesInPlace: true))
    }

    func testATypedInternalPageNeverRoutes() {
        XCTAssertFalse(typedURLIsRoutable(url("detour://history"), isSearch: false, navigatesInPlace: false))
        XCTAssertFalse(typedURLIsRoutable(url("file:///tmp/a.html"), isSearch: false, navigatesInPlace: false))
    }

    // MARK: - With the resolver: where a routable link goes

    private let work = UUID()
    private let personal = UUID()
    private var context: LinkRouteContext { LinkRouteContext(spaceIDs: [work, personal]) }

    private func routes() -> [LinkRoute] {
        [LinkRoute(match: LinkRouteMatch(kind: .domainIs, pattern: "work.test"), target: .space(work), sortOrder: 0),
         LinkRoute(match: LinkRouteMatch(kind: .contains, pattern: "secret"), target: .privateWindow, sortOrder: 1),
         LinkRoute(match: LinkRouteMatch(kind: .domainIs, pattern: "later.test"), target: .quarantine, sortOrder: 2)]
    }

    /// Both layers, as the window runs them for a click.
    private func routedClick(_ target: String, in space: UUID, isPrivate: Bool = false,
                             newWindow: Bool = false, defaultTarget: LinkRouteTarget = .mostRecentSpace) -> LinkRouteDecision? {
        routedLinkDecision(click(target, newWindow: newWindow)) {
            resolveLinkRoute(url: url(target), origin: .clicked(inSpace: space, isPrivateWindow: isPrivate),
                             routes: routes(), defaultTarget: defaultTarget, context: context)
        }
    }

    func testACrossHostClickToARoutedHostOpensInItsSpace() {
        XCTAssertEqual(routedClick("https://app.work.test/inbox", in: personal), .openInSpace(work))
    }

    func testARouteToTheCurrentSpaceChangesNothing() {
        XCTAssertNil(routedClick("https://app.work.test/inbox", in: work))
    }

    func testFromAPrivateWindowRoutesToNormalSpacesAreIgnored() {
        XCTAssertNil(routedClick("https://app.work.test/inbox", in: UUID(), isPrivate: true))
        XCTAssertNil(routedClick("https://unrouted.test/", in: UUID(), isPrivate: true, defaultTarget: .space(work)),
                     "nor the Default")
    }

    func testAPrivateRouteAppliesFromANormalWindowButNotFromAPrivateOne() {
        XCTAssertEqual(routedClick("https://other.test/secret", in: personal), .privateWindow)
        XCTAssertNil(routedClick("https://other.test/secret", in: UUID(), isPrivate: true))
    }

    func testQuarantineNeverAppliesToAClick() {
        XCTAssertNil(routedClick("https://later.test/", in: personal))
        XCTAssertNil(routedClick("https://later.test/", in: personal, defaultTarget: .quarantine))
    }

    func testTheDefaultAppliesToAClick() {
        XCTAssertEqual(routedClick("https://unrouted.test/", in: personal, defaultTarget: .space(work)), .openInSpace(work))
        XCTAssertNil(routedClick("https://unrouted.test/", in: personal, defaultTarget: .mostRecentSpace),
                     "Most Recent Space keeps it in the current space")
    }

    func testASameHostClickNeverReachesTheRoutesOrTheDefault() {
        XCTAssertNil(routedClick("https://example.com/work.test", in: personal, defaultTarget: .space(work)))
    }
}
