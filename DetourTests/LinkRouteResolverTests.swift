import XCTest
@testable import Detour

/// TASK-191.1: Air Traffic Control's pure rules — which route a link matches,
/// where it then opens from each origin, and what targets a space.
final class LinkRouteResolverTests: XCTestCase {

    private let work = UUID()
    private let personal = UUID()
    private let privateSpace = UUID()
    private var context: LinkRouteContext { LinkRouteContext(spaceIDs: [work, personal]) }

    private func url(_ s: String) -> URL { URL(string: s)! }

    private func route(_ kind: LinkRouteMatchKind?, _ pattern: String = "", app: String? = nil,
                       to target: LinkRouteTarget, order: Int = 0) -> LinkRoute {
        LinkRoute(match: kind.map { LinkRouteMatch(kind: $0, pattern: pattern) }, sourceApp: app,
                  target: target, sortOrder: order)
    }

    private func resolve(_ s: String, from origin: LinkOrigin = .external(sourceApp: nil), _ routes: [LinkRoute],
                         default defaultTarget: LinkRouteTarget = .mostRecentSpace) -> LinkRouteDecision {
        resolveLinkRoute(url: url(s), origin: origin, routes: routes, defaultTarget: defaultTarget, context: context)
    }

    private func matches(_ kind: LinkRouteMatchKind, _ pattern: String, _ s: String) -> Bool {
        linkRouteMatch(LinkRouteMatch(kind: kind, pattern: pattern), matches: url(s))
    }

    // MARK: - Match kinds

    func testIsEqualToMatchesTheWholeURLOnly() {
        XCTAssertTrue(matches(.isEqualTo, "https://example.com/a?b=1", "https://example.com/a?b=1"))
        XCTAssertFalse(matches(.isEqualTo, "https://example.com/a", "https://example.com/a/b"))
        XCTAssertFalse(matches(.isEqualTo, "https://example.com/a", "http://example.com/a"), "the scheme counts")
        XCTAssertFalse(matches(.isEqualTo, "example.com/a", "https://example.com/a"),
                       "a pattern without a scheme is not a URL, so it equals none")
    }

    func testIsEqualToIgnoresCaseFragmentDefaultPortAndAnEmptyPath() {
        XCTAssertTrue(matches(.isEqualTo, "HTTPS://Example.com/A", "https://example.com/a"))
        XCTAssertTrue(matches(.isEqualTo, "https://example.com/a", "https://example.com/a#section"))
        XCTAssertTrue(matches(.isEqualTo, "https://example.com/a#x", "https://example.com/a"))
        XCTAssertTrue(matches(.isEqualTo, "https://example.com", "https://example.com/"))
        XCTAssertTrue(matches(.isEqualTo, "https://example.com:443/", "https://example.com/"))
        XCTAssertFalse(matches(.isEqualTo, "https://example.com:8443/", "https://example.com/"))
        XCTAssertTrue(matches(.isEqualTo, "  https://example.com/  ", "https://example.com/"), "whitespace is trimmed")
    }

    func testContainsIsACaseInsensitiveSubstringOfTheFullURL() {
        XCTAssertTrue(matches(.contains, "github.com/acme", "https://github.com/Acme/repo"))
        XCTAssertTrue(matches(.contains, "?TAB=", "https://example.com/p?tab=2"))
        XCTAssertTrue(matches(.contains, "#inbox", "https://mail.example.com/#inbox"), "the fragment is part of the text")
        XCTAssertFalse(matches(.contains, "gitlab", "https://github.com/acme"))
    }

    func testDomainIsMatchesTheHostAndSubdomainsOnADotBoundary() {
        XCTAssertTrue(matches(.domainIs, "example.com", "https://example.com/x"))
        XCTAssertTrue(matches(.domainIs, "example.com", "https://a.example.com/"))
        XCTAssertTrue(matches(.domainIs, "example.com", "https://a.b.example.com/"))
        XCTAssertFalse(matches(.domainIs, "example.com", "https://badexample.com/"))
        XCTAssertFalse(matches(.domainIs, "example.com", "https://example.com.evil.test/"))
        XCTAssertFalse(matches(.domainIs, "a.example.com", "https://example.com/"), "a subdomain does not cover its parent")
        XCTAssertFalse(matches(.domainIs, "example.com", "https://other.test/?u=example.com"), "only the host counts")
    }

    func testDomainIsIgnoresCase() {
        XCTAssertTrue(matches(.domainIs, "Example.COM", "https://WWW.example.com/"))
    }

    func testDomainIsPatternMayBeWrittenAsAURL() {
        XCTAssertTrue(matches(.domainIs, "https://example.com/some/path", "https://a.example.com/"))
        XCTAssertTrue(matches(.domainIs, "*.example.com", "https://a.example.com/"))
        XCTAssertTrue(matches(.domainIs, "*.example.com", "https://example.com/"))
        XCTAssertTrue(matches(.domainIs, ".example.com", "https://example.com/"))
        XCTAssertTrue(matches(.domainIs, "example.com.", "https://a.example.com/"), "a trailing dot is dropped")
        XCTAssertTrue(matches(.domainIs, "example.com", "https://example.com./"), "on the URL's host too")
    }

    func testDomainIsTreatsALeadingWWWAsTheBareDomain() {
        XCTAssertTrue(matches(.domainIs, "www.example.com", "https://example.com/"))
        XCTAssertTrue(matches(.domainIs, "www.example.com", "https://www.example.com/"))
        XCTAssertTrue(matches(.domainIs, "www.example.com", "https://mail.example.com/"))
        XCTAssertTrue(matches(.domainIs, "example.com", "https://www.example.com/"))
        XCTAssertFalse(matches(.domainIs, "www.example.com", "https://example.org/"))
        XCTAssertEqual(linkRouteDomain(fromPattern: "www.example.com"), "example.com")
        XCTAssertEqual(linkRouteDomain(fromPattern: "www"), "www", "a bare www is a host, not a prefix")
        XCTAssertEqual(linkRouteDomain(fromPattern: "www.com"), "www.com", "a www prefix never leaves a bare TLD")
        XCTAssertFalse(matches(.domainIs, "www.com", "https://example.com/"))
    }

    func testDomainIsIgnoresPortsOnBothSides() {
        XCTAssertTrue(matches(.domainIs, "localhost", "http://localhost:3000/"))
        XCTAssertTrue(matches(.domainIs, "localhost:3000", "http://localhost:4000/"))
        XCTAssertEqual(linkRouteDomain(fromPattern: "example.com:8080"), "example.com")
    }

    func testDomainIsComparesIDNsInPunycode() {
        XCTAssertEqual(linkRouteDomain(fromPattern: "münchen.de"), "xn--mnchen-3ya.de")
        XCTAssertEqual(linkRouteDomain(fromPattern: "MÜNCHEN.de"), "xn--mnchen-3ya.de")
        XCTAssertTrue(matches(.domainIs, "münchen.de", "https://xn--mnchen-3ya.de/"))
        XCTAssertTrue(matches(.domainIs, "münchen.de", "https://stadt.münchen.de/"))
        XCTAssertTrue(matches(.domainIs, "xn--mnchen-3ya.de", "https://münchen.de/"))
    }

    func testDomainIsMatchesIPLiteralsExactly() {
        XCTAssertEqual(linkRouteDomain(fromPattern: "::1"), "[::1]")
        XCTAssertEqual(linkRouteDomain(fromPattern: "[::1]:3000"), "[::1]")
        XCTAssertTrue(matches(.domainIs, "::1", "http://[::1]:3000/"))
        XCTAssertTrue(matches(.domainIs, "[::1]", "http://[::1]/"))
        XCTAssertFalse(matches(.domainIs, "::1", "http://[::2]/"))
        XCTAssertTrue(matches(.domainIs, "10.0.0.1", "http://10.0.0.1:8080/"))
        XCTAssertFalse(matches(.domainIs, "0.0.1", "http://10.0.0.1/"), "no subdomain rule for an IPv4 address")
        XCTAssertFalse(matches(.domainIs, "0.1", "http://10.0.0.1/"))
    }

    func testAnEmptyPatternMatchesNothing() {
        for kind in LinkRouteMatchKind.allCases {
            XCTAssertFalse(matches(kind, "", "https://example.com/"), "\(kind)")
            XCTAssertFalse(matches(kind, "   ", "https://example.com/"), "\(kind)")
        }
        XCTAssertNil(linkRouteDomain(fromPattern: "https://"))
    }

    func testOnlyHTTPAndHTTPSURLsMatch() {
        XCTAssertFalse(matches(.contains, "history", "detour://history"))
        XCTAssertFalse(matches(.contains, "tmp", "file:///tmp/a.html"))
        XCTAssertFalse(matches(.domainIs, "example.com", "ftp://example.com/"))
        XCTAssertTrue(matches(.contains, "example", "http://example.com/"))
    }

    // MARK: - Ordering

    func testTheFirstMatchingRouteInSortOrderWins() {
        let routes = [
            route(.domainIs, "example.com", to: .space(personal), order: 1),
            route(.contains, "example.com/work", to: .space(work), order: 0),
        ]
        XCTAssertEqual(resolve("https://example.com/work/1", routes), .openInSpace(work),
                       "sortOrder decides, not the array's order")
        XCTAssertEqual(resolve("https://example.com/home", routes), .openInSpace(personal))
    }

    func testAnUnmatchedExternalLinkGoesToTheDefault() {
        let routes = [route(.domainIs, "example.com", to: .space(work))]
        XCTAssertEqual(resolve("https://other.test/", routes), .mostRecentSpace)
        XCTAssertEqual(resolve("https://other.test/", routes, default: .space(personal)), .openInSpace(personal))
        XCTAssertEqual(resolve("https://other.test/", routes, default: .privateWindow), .privateWindow)
        XCTAssertEqual(resolve("https://other.test/", routes, default: .quarantine), .quarantine)
        XCTAssertEqual(resolve("https://other.test/", routes, default: .quickDetour), .quickDetour)
        XCTAssertEqual(resolve("https://other.test/", [], default: .space(work)), .openInSpace(work))
    }

    func testAMatchedExternalLinkOpensInEachTargetKind() {
        let ext = LinkOrigin.external(sourceApp: nil)
        XCTAssertEqual(resolve("https://a.test/", from: ext, [route(.domainIs, "a.test", to: .space(work))]), .openInSpace(work))
        XCTAssertEqual(resolve("https://a.test/", from: ext, [route(.domainIs, "a.test", to: .mostRecentSpace)],
                               default: .space(work)), .mostRecentSpace)
        XCTAssertEqual(resolve("https://a.test/", from: ext, [route(.domainIs, "a.test", to: .privateWindow)]), .privateWindow)
        XCTAssertEqual(resolve("https://a.test/", from: ext, [route(.domainIs, "a.test", to: .quarantine)]), .quarantine)
        XCTAssertEqual(resolve("https://a.test/", from: ext, [route(.domainIs, "a.test", to: .quickDetour)]), .quickDetour)
    }

    // MARK: - Source app

    func testASourceAppRouteMatchesOnlyExternalLinksFromThatApp() {
        let slack = route(nil, app: "com.tinyspeck.slackmacgap", to: .space(work))
        XCTAssertEqual(resolve("https://any.test/", from: .external(sourceApp: "com.tinyspeck.slackmacgap"), [slack]),
                       .openInSpace(work), "an app-only route matches any URL from the app")
        XCTAssertEqual(resolve("https://any.test/", from: .external(sourceApp: "COM.TinySpeck.SlackMacGap"), [slack]),
                       .openInSpace(work), "bundle IDs compare without case")
        XCTAssertEqual(resolve("https://any.test/", from: .external(sourceApp: "com.apple.mail"), [slack]), .mostRecentSpace)
        XCTAssertEqual(resolve("https://any.test/", from: .external(sourceApp: nil), [slack]), .mostRecentSpace,
                       "a link with no known sender matches no source-app route")
        XCTAssertEqual(resolve("https://any.test/", from: .typed(fromSpace: personal, isPrivateWindow: false), [slack]), .stay)
        XCTAssertEqual(resolve("https://any.test/", from: .clicked(inSpace: personal, isPrivateWindow: false), [slack]), .stay)
    }

    func testARouteWithAURLAndASourceAppNeedsBoth() {
        let r = route(.domainIs, "acme.test", app: "com.tinyspeck.slackmacgap", to: .space(work))
        XCTAssertEqual(resolve("https://acme.test/", from: .external(sourceApp: "com.tinyspeck.slackmacgap"), [r]),
                       .openInSpace(work))
        XCTAssertEqual(resolve("https://other.test/", from: .external(sourceApp: "com.tinyspeck.slackmacgap"), [r]),
                       .mostRecentSpace)
        XCTAssertEqual(resolve("https://acme.test/", from: .external(sourceApp: "com.apple.mail"), [r]), .mostRecentSpace)
        XCTAssertEqual(resolve("https://acme.test/", from: .typed(fromSpace: personal, isPrivateWindow: false), [r]), .stay)
    }

    func testARouteWithNoConditionNeverMatches() {
        let r = route(nil, to: .space(work))
        XCTAssertFalse(r.hasCondition)
        XCTAssertEqual(resolve("https://a.test/", [r]), .mostRecentSpace)
        let blank = route(.contains, "  ", app: " ", to: .space(work))
        XCTAssertFalse(blank.hasCondition)
        XCTAssertEqual(resolve("https://a.test/", from: .external(sourceApp: " "), [blank]), .mostRecentSpace)
    }

    // MARK: - Typed URLs and clicks

    func testATypedOrClickedLinkMovesToTheRoutedSpace() {
        let r = [route(.domainIs, "work.test", to: .space(work))]
        XCTAssertEqual(resolve("https://work.test/", from: .typed(fromSpace: personal, isPrivateWindow: false), r),
                       .openInSpace(work))
        XCTAssertEqual(resolve("https://work.test/", from: .clicked(inSpace: personal, isPrivateWindow: false), r),
                       .openInSpace(work))
    }

    func testARouteToTheSpaceTheLinkIsAlreadyInStays() {
        let r = [route(.domainIs, "work.test", to: .space(work)), route(.contains, "work", to: .space(personal), order: 1)]
        XCTAssertEqual(resolve("https://work.test/", from: .typed(fromSpace: work, isPrivateWindow: false), r), .stay,
                       "the first match decides: it stays, the later route is not tried")
        XCTAssertEqual(resolve("https://work.test/", from: .clicked(inSpace: work, isPrivateWindow: false), r), .stay)
    }

    // MARK: - The Default for typed URLs and clicks (user decision 2026-10-25)
    //
    // The Default applies to every origin, not only to links from other apps.
    // Which clicks reach the resolver at all is TASK-191.4's click rule; the
    // resolver applies the Default to every `.typed` and `.clicked` origin it
    // is handed.

    private var typedFromPersonal: LinkOrigin { .typed(fromSpace: personal, isPrivateWindow: false) }
    private var clickedInPersonal: LinkOrigin { .clicked(inSpace: personal, isPrivateWindow: false) }

    func testAnUnmatchedTypedOrClickedLinkOpensInTheDefaultSpace() {
        let r = [route(.domainIs, "example.com", to: .space(personal))]
        XCTAssertEqual(resolve("https://other.test/", from: typedFromPersonal, r, default: .space(work)), .openInSpace(work))
        XCTAssertEqual(resolve("https://other.test/", from: clickedInPersonal, r, default: .space(work)), .openInSpace(work))
    }

    func testAnUnmatchedTypedOrClickedLinkInTheDefaultSpaceStays() {
        XCTAssertEqual(resolve("https://other.test/", from: .typed(fromSpace: work, isPrivateWindow: false), [],
                               default: .space(work)), .stay)
        XCTAssertEqual(resolve("https://other.test/", from: .clicked(inSpace: work, isPrivateWindow: false), [],
                               default: .space(work)), .stay)
    }

    func testAMostRecentSpaceDefaultLeavesATypedOrClickedLinkWhereItIs() {
        XCTAssertEqual(resolve("https://other.test/", from: typedFromPersonal, [], default: .mostRecentSpace), .stay)
        XCTAssertEqual(resolve("https://other.test/", from: clickedInPersonal, [], default: .mostRecentSpace), .stay)
        XCTAssertEqual(resolve("https://other.test/", [], default: .mostRecentSpace), .mostRecentSpace,
                       "an external link still goes to the most recent space")
    }

    func testAPrivateWindowDefaultAppliesToEveryOrigin() {
        XCTAssertEqual(resolve("https://other.test/", [], default: .privateWindow), .privateWindow)
        XCTAssertEqual(resolve("https://other.test/", from: typedFromPersonal, [], default: .privateWindow), .privateWindow)
        XCTAssertEqual(resolve("https://other.test/", from: clickedInPersonal, [], default: .privateWindow), .privateWindow)
    }

    func testAPrivateWindowDefaultFromAPrivateWindowStays() {
        XCTAssertEqual(resolve("https://other.test/", from: .typed(fromSpace: privateSpace, isPrivateWindow: true), [],
                               default: .privateWindow), .stay)
        XCTAssertEqual(resolve("https://other.test/", from: .clicked(inSpace: privateSpace, isPrivateWindow: true), [],
                               default: .privateWindow), .stay)
    }

    func testQuarantineAndQuickDetourDefaultsApplyOnlyToExternalLinks() {
        for defaultTarget: LinkRouteTarget in [.quarantine, .quickDetour] {
            XCTAssertEqual(resolve("https://other.test/", from: typedFromPersonal, [], default: defaultTarget), .stay,
                           "\(defaultTarget): a typed URL stays, rather than going to the most recent space")
            XCTAssertEqual(resolve("https://other.test/", from: clickedInPersonal, [], default: defaultTarget), .stay,
                           "\(defaultTarget)")
        }
        XCTAssertEqual(resolve("https://other.test/", [], default: .quarantine), .quarantine)
        XCTAssertEqual(resolve("https://other.test/", [], default: .quickDetour), .quickDetour)
    }

    func testANormalSpaceDefaultIsIgnoredFromAPrivateWindow() {
        for origin: LinkOrigin in [.typed(fromSpace: privateSpace, isPrivateWindow: true),
                                   .clicked(inSpace: privateSpace, isPrivateWindow: true)] {
            XCTAssertEqual(resolve("https://other.test/", from: origin, [], default: .space(work)), .stay, "\(origin)")
            XCTAssertEqual(resolve("https://other.test/", from: origin, [], default: .mostRecentSpace), .stay, "\(origin)")
        }
    }

    func testATypedURLWhoseRouteIsSkippedFallsThroughToTheDefault() {
        let r = [route(.domainIs, "a.test", to: .quarantine), route(.domainIs, "a.test", to: .space(UUID()), order: 1)]
        XCTAssertEqual(resolve("https://a.test/", from: typedFromPersonal, r, default: .space(work)), .openInSpace(work),
                       "Quarantine and a missing space are skipped; the Default decides")
    }

    func testAMostRecentSpaceRouteLeavesATypedOrClickedLinkWhereItIs() {
        let r = [route(.domainIs, "a.test", to: .mostRecentSpace), route(.domainIs, "a.test", to: .space(work), order: 1)]
        XCTAssertEqual(resolve("https://a.test/", from: .typed(fromSpace: personal, isPrivateWindow: false), r), .stay)
        XCTAssertEqual(resolve("https://a.test/", from: .clicked(inSpace: personal, isPrivateWindow: false), r), .stay)
    }

    // MARK: - Quarantine and Quick Detour: links from other apps only

    func testQuarantineAndQuickDetourRoutesApplyOnlyToExternalLinks() {
        for target: LinkRouteTarget in [.quarantine, .quickDetour] {
            let r = [route(.domainIs, "a.test", to: target), route(.domainIs, "a.test", to: .space(work), order: 1)]
            XCTAssertEqual(resolve("https://a.test/", from: .typed(fromSpace: personal, isPrivateWindow: false), r),
                           .openInSpace(work), "\(target) is skipped for a typed URL; the next route applies")
            XCTAssertEqual(resolve("https://a.test/", from: .clicked(inSpace: personal, isPrivateWindow: false), r),
                           .openInSpace(work), "\(target) is skipped for a click")
            XCTAssertEqual(resolve("https://a.test/", from: .clicked(inSpace: personal, isPrivateWindow: false), [r[0]]),
                           .stay)
        }
    }

    // MARK: - Private windows

    func testAPrivateWindowRouteMatchesFromEveryNormalOrigin() {
        let r = [route(.domainIs, "secret.test", to: .privateWindow)]
        XCTAssertEqual(resolve("https://secret.test/", from: .external(sourceApp: nil), r), .privateWindow)
        XCTAssertEqual(resolve("https://secret.test/", from: .typed(fromSpace: personal, isPrivateWindow: false), r),
                       .privateWindow)
        XCTAssertEqual(resolve("https://secret.test/", from: .clicked(inSpace: personal, isPrivateWindow: false), r),
                       .privateWindow)
    }

    func testAPrivateRouteFromAPrivateWindowStays() {
        let r = [route(.domainIs, "secret.test", to: .privateWindow), route(.domainIs, "secret.test", to: .space(work), order: 1)]
        XCTAssertEqual(resolve("https://secret.test/", from: .typed(fromSpace: privateSpace, isPrivateWindow: true), r), .stay)
        XCTAssertEqual(resolve("https://secret.test/", from: .clicked(inSpace: privateSpace, isPrivateWindow: true), r), .stay)
    }

    func testNothingRoutesOutOfAPrivateWindow() {
        let r = [
            route(.domainIs, "a.test", to: .space(work)),
            route(.domainIs, "a.test", to: .mostRecentSpace, order: 1),
            route(.domainIs, "a.test", to: .quarantine, order: 2),
            route(.domainIs, "a.test", to: .quickDetour, order: 3),
        ]
        for origin: LinkOrigin in [.typed(fromSpace: privateSpace, isPrivateWindow: true),
                                   .clicked(inSpace: privateSpace, isPrivateWindow: true)] {
            XCTAssertEqual(resolve("https://a.test/", from: origin, r, default: .space(work)), .stay, "\(origin)")
        }
        XCTAssertEqual(resolve("https://a.test/", from: .typed(fromSpace: privateSpace, isPrivateWindow: true),
                               r + [route(.domainIs, "a.test", to: .privateWindow, order: 4)]), .stay,
                       "a later Private route still only stays")
    }

    func testAPrivateWindowsSpaceIsNeverARouteTarget() {
        // A route can only name a space by id; a Private window's space is not
        // in the context, so it is skipped like a missing space.
        let r = [route(.domainIs, "a.test", to: .space(privateSpace))]
        XCTAssertEqual(resolve("https://a.test/", r), .mostRecentSpace)
        XCTAssertEqual(resolve("https://a.test/", from: .typed(fromSpace: personal, isPrivateWindow: false), r), .stay)
    }

    // MARK: - Missing spaces

    func testARouteToAMissingSpaceIsSkipped() {
        let gone = UUID()
        let r = [route(.domainIs, "a.test", to: .space(gone)), route(.contains, "a.test", to: .space(work), order: 1)]
        XCTAssertEqual(resolve("https://a.test/", r), .openInSpace(work))
        XCTAssertEqual(resolve("https://a.test/", from: .typed(fromSpace: personal, isPrivateWindow: false), r),
                       .openInSpace(work))
        XCTAssertEqual(resolve("https://a.test/", [r[0]], default: .space(personal)), .openInSpace(personal))
        XCTAssertEqual(resolve("https://a.test/", from: .clicked(inSpace: personal, isPrivateWindow: false), [r[0]]), .stay)
    }

    func testADefaultToAMissingSpaceFallsBackToTheMostRecentSpaceForAnExternalLink() {
        XCTAssertEqual(resolve("https://a.test/", [], default: .space(UUID())), .mostRecentSpace)
        XCTAssertEqual(resolve("https://a.test/", [], default: .space(privateSpace)), .mostRecentSpace)
    }

    func testADefaultToAMissingSpaceLeavesATypedOrClickedLinkWhereItIs() {
        for gone in [UUID(), privateSpace] {
            XCTAssertEqual(resolve("https://a.test/", from: typedFromPersonal, [], default: .space(gone)), .stay)
            XCTAssertEqual(resolve("https://a.test/", from: clickedInPersonal, [], default: .space(gone)), .stay)
        }
    }

    // MARK: - Routes targeting a space

    func testRoutesTargetingASpaceListsThemInSortOrderAndTheDefault() {
        let a = route(.domainIs, "a.test", to: .space(work), order: 2)
        let b = route(.domainIs, "b.test", to: .space(personal), order: 1)
        let c = route(.contains, "c", to: .space(work), order: 0)
        let d = route(.contains, "d", to: .mostRecentSpace, order: 3)
        let refs = linkRoutesTargeting(spaceID: work, routes: [a, b, c, d], defaultTarget: .mostRecentSpace)
        XCTAssertEqual(refs.routes.map(\.id), [c.id, a.id])
        XCTAssertFalse(refs.isDefaultTarget)
        XCTAssertFalse(refs.isEmpty)

        let byDefault = linkRoutesTargeting(spaceID: personal, routes: [a, c], defaultTarget: .space(personal))
        XCTAssertEqual(byDefault.routes, [])
        XCTAssertTrue(byDefault.isDefaultTarget)
        XCTAssertFalse(byDefault.isEmpty)

        XCTAssertTrue(linkRoutesTargeting(spaceID: UUID(), routes: [a, b, c, d], defaultTarget: .privateWindow).isEmpty)
    }
}
