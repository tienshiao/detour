import XCTest
import AppKit
import GRDB
@testable import Detour

/// TASK-292.11: Settings links each feature that has a guide page on the
/// website to it with Learn more. The URLs come from the Help menu's
/// definition (`GuidePage` under `HelpLinks.detourHelp`), and a link opens
/// its page through the Help menu's opener.
nonisolated final class SettingsGuideLinkTests: XCTestCase {

    // MARK: - The pages

    @MainActor func testGuidePagesAreFeaturePagesUnderTheHelpMenusGuideIndex() {
        let index = HelpLinks.detourHelp.url.absoluteString
        XCTAssertEqual(index, "https://detourbrowser.com/features/")
        for page in GuidePage.allCases {
            XCTAssertEqual(page.url.absoluteString, "\(index)\(page.rawValue)/", "\(page)")
            XCTAssertEqual(page.url.scheme, "https")
            XCTAssertEqual(page.url.host, "detourbrowser.com")
        }
    }

    /// The slugs of the website's pages (src/content/features in the website
    /// repository; all checked live on Nov 14 2026).
    @MainActor func testTheSlugsAreTheWebsitesPages() {
        XCTAssertEqual(GuidePage.allCases.map(\.rawValue),
                       ["spaces", "profiles", "link-routes", "quick-detour", "site-search", "web-extensions",
                        "content-blocker", "peek", "quarantine", "tab-archiving", "private-browsing"])
        XCTAssertEqual(GuidePage.quickDetour.name, "Quick Detour")
    }

    // MARK: - Which links each pane has

    @MainActor private func links(in view: NSView) -> [SettingsGuideLink] {
        view.subviews.flatMap { ($0 as? SettingsGuideLink).map { [$0] } ?? links(in: $0) }
    }

    @MainActor private func pages(in pane: SettingsPaneViewController) -> Set<GuidePage> {
        Set(links(in: pane.view).map(\.page))
    }

    @MainActor func testEachPaneLinksTheGuidesOfItsFeatures() throws {
        let links = LinksSettingsViewController(
            linkRoutes: LinkRouteStore(database: try AppDatabase(dbQueue: DatabaseQueue())))
        let search = SearchSettingsViewController(
            siteSearches: SiteSearchStore(database: try AppDatabase(dbQueue: DatabaseQueue())))
        let expected: [(SettingsPaneViewController, Set<GuidePage>)] = [
            (GeneralSettingsViewController(), [.peek]),
            (SpacesSettingsViewController(), [.spaces]),
            (links, [.linkRoutes, .quarantine]),
            (QuickDetourSettingsViewController(), [.quickDetour]),
            (ProfilesSettingsViewController(), [.profiles, .privateBrowsing, .tabArchiving, .contentBlocker, .webExtensions]),
            (search, [.siteSearch]),
            (ExtensionsSettingsViewController(), [.webExtensions]),
            (ContentBlockerSettingsViewController(), [.contentBlocker]),
        ]
        for (pane, pages) in expected {
            XCTAssertEqual(self.pages(in: pane), pages, "\(type(of: pane))")
        }
        // Every page Settings knows is linked from somewhere.
        XCTAssertEqual(Set(expected.flatMap(\.1)), Set(GuidePage.allCases))
    }

    @MainActor func testPanesWithAGuideNameItAtTheirTop() {
        XCTAssertNil(GeneralSettingsViewController().guidePage, "General's guide is Peek's section")
        XCTAssertEqual(SpacesSettingsViewController().guidePage, .spaces)
        XCTAssertEqual(QuickDetourSettingsViewController().guidePage, .quickDetour)
        XCTAssertEqual(ProfilesSettingsViewController().guidePage, .profiles)
        XCTAssertEqual(ExtensionsSettingsViewController().guidePage, .webExtensions)
        XCTAssertEqual(ContentBlockerSettingsViewController().guidePage, .contentBlocker)
    }

    @MainActor func testProfileSectionsLinkTheirFeaturesGuides() {
        XCTAssertEqual(ProfileSettingsSection.allCases.map(\.guidePage),
                       [nil, nil, .tabArchiving, .contentBlocker, .webExtensions, nil, nil])
    }

    // MARK: - Opening

    @MainActor func testClickingALinkOpensItsPageThroughTheOpener() throws {
        let original = SettingsGuideLink.open
        defer { SettingsGuideLink.open = original }
        var opened: [URL] = []
        SettingsGuideLink.open = { opened.append($0) }

        let pane = SpacesSettingsViewController()
        let link = try XCTUnwrap(links(in: pane.view).first)
        link.performClick(nil)
        XCTAssertEqual(opened, [GuidePage.spaces.url])

        let profiles = ProfilesSettingsViewController()
        for link in links(in: profiles.view) { link.performClick(nil) }
        XCTAssertEqual(Set(opened.dropFirst()), Set(pages(in: profiles).map(\.url)))
    }

    @MainActor func testTheLinkNamesItsPageForAccessibility() {
        let link = SettingsGuideLink(.tabArchiving, title: "Learn more")
        XCTAssertEqual(link.title, "Learn more")
        XCTAssertEqual(link.accessibilityLabel(), "Learn more about Tab Archiving")
        XCTAssertEqual(link.accessibilityIdentifier(), "learnMore.tab-archiving")
        XCTAssertEqual(SettingsGuideLink(.linkRoutes).title, "Learn more about Link Routes")
    }

    // MARK: - Place in the pane

    @MainActor private final class Pane: SettingsPaneViewController {
        let text: String?
        let page: GuidePage?
        let content = NSView()
        init(text: String?, page: GuidePage?) {
            self.text = text
            self.page = page
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError() }
        override var paneDescription: String? { text }
        override var guidePage: GuidePage? { page }
        override func makeBody() -> NSView {
            let body = NSView()
            content.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: body.topAnchor),
                content.leadingAnchor.constraint(equalTo: body.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: body.bottomAnchor),
                content.heightAnchor.constraint(equalToConstant: 100),
            ])
            return body
        }
    }

    @MainActor private func laidOut(_ pane: Pane) -> Pane {
        pane.view.setFrameSize(NSSize(width: SettingsMetrics.windowWidth, height: pane.naturalContentHeight))
        pane.view.layoutSubtreeIfNeeded()
        return pane
    }

    /// Distance from the pane's top edge (the root view is not flipped).
    @MainActor private func top(of view: NSView, in pane: Pane) -> CGFloat {
        pane.view.bounds.height - view.convert(view.bounds, to: pane.view).maxY
    }

    @MainActor private func bottom(of view: NSView, in pane: Pane) -> CGFloat {
        pane.view.bounds.height - view.convert(view.bounds, to: pane.view).minY
    }

    @MainActor func testTheLinkSitsUnderTheDescriptionAndTheBodyBelowIt() throws {
        let pane = laidOut(Pane(text: "A description.", page: .spaces))
        let link = try XCTUnwrap(links(in: pane.view).first)
        let label = try XCTUnwrap(pane.view.subviews.first { $0 is NSTextField })
        XCTAssertEqual(top(of: link, in: pane) - bottom(of: label, in: pane), SettingsMetrics.controlToHelp, accuracy: 0.5)
        XCTAssertEqual(top(of: pane.content, in: pane) - bottom(of: link, in: pane),
                       SettingsMetrics.descriptionToBody, accuracy: 0.5)
        // Its alignment rect (the text, not the button's inset) on the margin.
        XCTAssertEqual(link.alignmentRect(forFrame: link.frame).minX, SettingsMetrics.paneMargin, accuracy: 0.5)
        // The natural height counts the link: the body ends a margin above the bottom.
        XCTAssertEqual(pane.view.bounds.height - bottom(of: pane.content, in: pane), SettingsMetrics.paneMargin,
                       accuracy: 0.5)
        let without = laidOut(Pane(text: "A description.", page: nil))
        XCTAssertEqual(pane.naturalContentHeight - without.naturalContentHeight,
                       SettingsMetrics.controlToHelp + link.fittingSize.height, accuracy: 0.5)
    }

    /// A list pane held taller than its content gives the room to its list,
    /// never to the links (Links at its 400 pt minimum stretched its top link).
    @MainActor func testSpareHeightNeverStretchesALink() throws {
        let pane = LinksSettingsViewController(
            linkRoutes: LinkRouteStore(database: try AppDatabase(dbQueue: DatabaseQueue())))
        for height: CGFloat in [SettingsMetrics.listPaneMinimumHeight, 700] {
            pane.view.setFrameSize(NSSize(width: SettingsMetrics.windowWidth, height: height))
            pane.view.layoutSubtreeIfNeeded()
            let found = links(in: pane.view)
            XCTAssertEqual(found.count, 2)
            for link in found {
                XCTAssertEqual(link.frame.height, link.intrinsicContentSize.height, accuracy: 0.5,
                               "\(link.page) at \(height)")
            }
        }
    }

    @MainActor func testWithoutADescriptionTheLinkTakesItsPlace() throws {
        let pane = laidOut(Pane(text: nil, page: .quickDetour))
        let link = try XCTUnwrap(links(in: pane.view).first)
        XCTAssertEqual(top(of: link, in: pane), SettingsMetrics.paneMargin, accuracy: 0.5)
        XCTAssertEqual(top(of: pane.content, in: pane) - bottom(of: link, in: pane),
                       SettingsMetrics.descriptionToBody, accuracy: 0.5)
        XCTAssertEqual(pane.view.bounds.height - bottom(of: pane.content, in: pane), SettingsMetrics.paneMargin,
                       accuracy: 0.5)
    }
}
