import XCTest
@testable import Detour

/// TASK-329: the downloaded AdGuard URL Tracking filter's `$removeparam`
/// rules (`TrackingParameterFilter`), applied by `TrackingParameters` on top
/// of the built-in names. Parsing and matching against a trimmed excerpt of
/// the real list (`TrackingParameterFilterFixture`) and a few hand-written
/// lines; the download path is `TrackingParameterListTests`, the copy entry
/// points `CopyURLTests`.
nonisolated final class TrackingParameterFilterTests: XCTestCase {

    private static let fixture = TrackingParameterFilter(text: TrackingParameterFilterFixture.text)

    @MainActor private func clean(_ s: String, _ filter: TrackingParameterFilter? = fixture) -> String {
        TrackingParameters.removing(from: URL(string: s)!, using: filter).absoluteString
    }

    @MainActor private func assertUnchanged(_ s: String, _ filter: TrackingParameterFilter? = fixture,
                                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(clean(s, filter), s, file: file, line: line)
    }

    // MARK: - Parsing

    /// AC #3: what the parser uses and what it skips, by kind, on the excerpt.
    @MainActor func testTheExcerptsRulesAreCountedByKind() {
        var expected = TrackingParameterFilter.Counts()
        expected.supported = 30
        expected.exceptions = 7
        expected.widenedExceptions = 1 // the msn.com exception's $app option is ignored
        expected.regex = 5
        expected.notForPages = 3 // xhr, font, and the xhr exception
        expected.unsupported = 0
        expected.other = 1 // element hiding
        XCTAssertEqual(Self.fixture.counts, expected)
        XCTAssertFalse(Self.fixture.isEmpty)
    }

    @MainActor func testTextWithoutRulesGivesAnEmptyFilter() {
        let page = TrackingParameterFilter(text: "<!doctype html>\n<html><body>502 Bad Gateway</body></html>\n")
        XCTAssertTrue(page.isEmpty)
        XCTAssertTrue(TrackingParameterFilter(text: "").isEmpty)
        XCTAssertTrue(TrackingParameterFilter(text: "! only comments\n[Adblock Plus 2.0]\n").isEmpty)
    }

    @MainActor func testUnknownOptionsDropABlockRule() {
        let filter = TrackingParameterFilter(text: "||a.test^$removeparam=x,match-case\n||a.test^$removeparam=y,denyallow=b.test\n")
        XCTAssertEqual(filter.counts.unsupported, 2)
        assertUnchanged("https://a.test/?x=1&y=2", filter)
    }

    /// A rule that would strip every parameter of every address is no
    /// tracking rule; the parser refuses it rather than trusting the list.
    @MainActor func testARemoveAllRuleWithoutAPatternIsRefused() {
        let filter = TrackingParameterFilter(text: "$removeparam\n*$removeparam=~q\n$removeparam,domain=~a.test\n")
        XCTAssertEqual(filter.counts.unsupported, 3)
        assertUnchanged("https://b.test/search?q=1&page=2", filter)
    }

    // MARK: - Global rules

    @MainActor func testGlobalNamesAreRemovedEverywhere() {
        XCTAssertEqual(clean("https://shop.test/p?id=1&pjclid=abc&b=2"), "https://shop.test/p?id=1&b=2")
        XCTAssertEqual(clean("http://news.test/?pjclid=1"), "http://news.test/")
    }

    @MainActor func testTheBuiltInNamesStillApply() {
        XCTAssertEqual(clean("https://shop.test/p?utm_source=x&fbclid=y&id=1"), "https://shop.test/p?id=1")
    }

    @MainActor func testRegexRulesAreSkipped() {
        assertUnchanged("https://a.test/?at_custom1=x&cm=1")
        assertUnchanged("https://www.chaturbate.com/?tour=1&campaign=2")
    }

    // MARK: - Per-site rules

    @MainActor func testAHostPatternCoversTheHostAndItsSubdomains() {
        XCTAssertEqual(clean("https://supply.amazon.com/item?ref_=nav&id=1"), "https://supply.amazon.com/item?id=1")
        XCTAssertEqual(clean("https://eu.supply.amazon.com/?ref_=nav"), "https://eu.supply.amazon.com/")
        assertUnchanged("https://notsupply.amazon.com/?ref_=nav")
        assertUnchanged("https://www.amazon.com/dp/B0?ref_=nav") // ref_ is listed for supply.amazon.com only
    }

    @MainActor func testAHostPatternsPathMustMatch() {
        XCTAssertEqual(clean("https://www.youtube.com/shorts/abc?si=xyz&feature=share"),
                       "https://www.youtube.com/shorts/abc?feature=share")
        assertUnchanged("https://www.youtube.com/watch?v=abc&si=xyz")
        XCTAssertEqual(clean("https://www.check24.de/suche/?q=tv&source=a"), "https://www.check24.de/suche/?q=tv")
    }

    /// `||amazon.*/stores/`: the wildcard stands for a public suffix only.
    @MainActor func testAWildcardTopLevelDomainInAPattern() {
        XCTAssertEqual(clean("https://www.amazon.co.uk/stores/page/X?a=1&lp_asin=B0&b=2#reviews"),
                       "https://www.amazon.co.uk/stores/page/X?a=1&b=2#reviews")
        XCTAssertEqual(clean("https://www.amazon.de/stores/x?lp_asin=1"), "https://www.amazon.de/stores/x")
        XCTAssertEqual(clean("https://www.audible.com.au/series/Foo?ref=a&x=1"), "https://www.audible.com.au/series/Foo?x=1")
        XCTAssertEqual(clean("https://luna.amazon.com/game?ref=x"), "https://luna.amazon.com/game")
        XCTAssertEqual(clean("https://luna.amazon.co.jp:443/game?ref=x"), "https://luna.amazon.co.jp:443/game")
        assertUnchanged("https://amazon.evil.com/stores/?lp_asin=1")
        assertUnchanged("https://www.amazon.com/dp/X?lp_asin=1")
        assertUnchanged("https://luna.amazon.example.org/?ref=x")
    }

    /// `||read.amazon.` ends inside the host: any `read.amazon.<anything>`.
    /// `||amazon.*&linkCode=*&tag=*&linkId=`: `.*` not ending the host is a
    /// plain wildcard over the address.
    @MainActor func testAWildcardAfterAHostThatDoesNotEndIt() {
        let filter = TrackingParameterFilter(text: "||amazon.*&linkCode=*&tag=*&linkId=$removeparam=crid\n")
        XCTAssertEqual(clean("https://www.amazon.com/dp/B0?crid=1&linkCode=ll1&tag=a-20&linkId=x", filter),
                       "https://www.amazon.com/dp/B0?linkCode=ll1&tag=a-20&linkId=x")
        assertUnchanged("https://www.amazon.com/dp/B0?crid=1&tag=a-20", filter)
    }

    @MainActor func testAnOpenEndedHostPrefix() {
        XCTAssertEqual(clean("https://read.amazon.com/?ref=a&asin=1"), "https://read.amazon.com/?asin=1")
        XCTAssertEqual(clean("https://read.amazon.co.jp/?ref=a"), "https://read.amazon.co.jp/")
    }

    @MainActor func testDomainOptionWithAWildcardTopLevelDomain() {
        XCTAssertEqual(clean("https://www.amazon.com/b?asc_campaign=x&node=1"), "https://www.amazon.com/b?node=1")
        XCTAssertEqual(clean("https://smile.amazon.co.uk/?asc_campaign=1"), "https://smile.amazon.co.uk/")
        XCTAssertEqual(clean("https://www.aboutamazon.com/?asc_campaign=1"), "https://www.aboutamazon.com/")
        XCTAssertEqual(clean("https://amzn.to/x?asc_campaign=1"), "https://amzn.to/x")
        assertUnchanged("https://amazon.example.org/?asc_campaign=1")
        assertUnchanged("https://notamazon.com/?asc_campaign=1")
        assertUnchanged("https://amazon.com.evil.net/?asc_campaign=1")
    }

    @MainActor func testDomainOptionCoversSubdomainsNotParents() {
        XCTAssertEqual(clean("https://news.ksb.co.jp/a?ro=1&id=2"), "https://news.ksb.co.jp/a?id=2")
        XCTAssertEqual(clean("https://www.kab.co.jp/?ro=1"), "https://www.kab.co.jp/")
        assertUnchanged("https://ksb.co.jp/?ro=1")
        XCTAssertEqual(clean("https://www.notebook.de/p?channable=a&id=1"), "https://www.notebook.de/p?id=1")
    }

    @MainActor func testNegatedDomains() {
        let filter = TrackingParameterFilter(text: """
            $removeparam=foo,domain=example.com|~shop.example.com
            $removeparam=baz,domain=~nobaz.test
            ||site.test^$removeparam=bar,domain=~keep.site.test
            $removeparam=qux,domain=~amazon.*
            """)
        XCTAssertEqual(clean("https://example.com/?foo=1&a=2", filter), "https://example.com/?a=2")
        XCTAssertEqual(clean("https://www.example.com/?foo=1", filter), "https://www.example.com/")
        assertUnchanged("https://shop.example.com/?foo=1", filter)
        assertUnchanged("https://a.shop.example.com/?foo=1", filter)
        XCTAssertEqual(clean("https://other.test/?baz=1", filter), "https://other.test/")
        assertUnchanged("https://nobaz.test/?baz=1", filter)
        assertUnchanged("https://www.nobaz.test/?baz=1", filter)
        XCTAssertEqual(clean("https://www.site.test/?bar=1", filter), "https://www.site.test/")
        assertUnchanged("https://keep.site.test/?bar=1", filter)
        XCTAssertEqual(clean("https://a.test/?qux=1", filter), "https://a.test/")
        assertUnchanged("https://www.amazon.co.uk/?qux=1", filter)
    }

    // MARK: - Substring patterns, remove-all, keep-only

    @MainActor func testSubstringPatterns() {
        XCTAssertEqual(clean("https://shop.test/go?pid=7&af_xp=custom&c=camp"), "https://shop.test/go?pid=7&af_xp=custom")
        assertUnchanged("https://shop.test/go?af_xp=custom&c=camp") // `&af_xp=`, not `?af_xp=`
        assertUnchanged("https://shop.test/go?c=camp")
        XCTAssertEqual(clean("https://www.weblio.jp/ranking/?from=glia"), "https://www.weblio.jp/ranking/")
        assertUnchanged("https://www.weblio.jp/ranking/?from=gliacloud") // `^` needs a separator or the end
        XCTAssertEqual(clean("https://t.test/?rtkcid=1&clickid=2&x=3"), "https://t.test/?rtkcid=1&x=3")
        assertUnchanged("https://t.test/?clickid=2&rtkcid=1")
    }

    @MainActor func testBareRemoveparamRemovesEveryParameter() {
        XCTAssertEqual(clean("https://shop.test/?affijet-click=1&a=2#top"), "https://shop.test/#top")
        assertUnchanged("https://shop.test/p?a=2&affijet-click=1")
    }

    @MainActor func testInvertedRemoveparamKeepsOnlyItsName() {
        XCTAssertEqual(clean("https://go.mysku.ru/?r=https%3A%2F%2Fshop.test&tag=1&id=2"),
                       "https://go.mysku.ru/?r=https%3A%2F%2Fshop.test")
    }

    // MARK: - Request types

    @MainActor func testRulesForOtherRequestTypesDoNotTouchAPage() {
        assertUnchanged("https://alia-cloudflare.com/launcher/?ip_address=1&x=2")
        XCTAssertEqual(clean("https://www.bandsintown.com/e/1?app_id=fb&came_from=2"),
                       "https://www.bandsintown.com/e/1?came_from=2", "a $document rule applies to pages")
    }

    // MARK: - Exceptions

    /// `@@||archive.*^$removeparam`: an archived address carries the original
    /// link's query, built-in tracking names included, and must keep it.
    @MainActor func testABareExceptionKeepsEveryParameterBuiltInNamesIncluded() {
        assertUnchanged("https://web.archive.org/web/2020/https://example.com/?utm_source=x&gclid=1&pjclid=2")
        XCTAssertEqual(clean("https://web.archive.org/web/2020/https://example.com/?utm_source=x", nil),
                       "https://web.archive.org/web/2020/https://example.com/",
                       "without the list, the built-in names are the floor")
    }

    @MainActor func testANamedExceptionKeepsOnlyThatParameter() {
        XCTAssertEqual(clean("https://www.eneba.com/x?utm_source=a&utm_medium=b"), "https://www.eneba.com/x?utm_source=a")
        XCTAssertEqual(clean("https://hobbygames.ru/?utm_source=x&gclid=1"), "https://hobbygames.ru/?utm_source=x")
        XCTAssertEqual(clean("https://www.greenbuildingadvisor.com/?oly_enc_id=1&utm_term=2"),
                       "https://www.greenbuildingadvisor.com/?oly_enc_id=1")
    }

    @MainActor func testAnExceptionsPatternAndWildcardMustMatch() {
        assertUnchanged("https://www.google.co.uk/maps/place?utm_campaign=x")
        XCTAssertEqual(clean("https://www.google.com/search?q=a&utm_campaign=x"), "https://www.google.com/search?q=a")
        // `@@||3dnews.ru/*?utm_source=^`: only an empty utm_source, `^` after it.
        assertUnchanged("https://3dnews.ru/1/page?utm_source=&id=2")
        XCTAssertEqual(clean("https://3dnews.ru/1/page?utm_source=rss&id=2"), "https://3dnews.ru/1/page?id=2")
    }

    @MainActor func testAnExceptionWithAnUnknownOptionIsKeptWithoutIt() {
        let filter = TrackingParameterFilter(text: TrackingParameterFilterFixture.text + "\n$removeparam=ocid\n")
        assertUnchanged("https://www.msn.com/en-us/news?ocid=abc", filter)
        XCTAssertEqual(clean("https://www.bing.com/news?ocid=abc", filter), "https://www.bing.com/news")
    }

    /// A widened exception (an unknown option, a regex, `~name`) or one for
    /// every site cancels the list's rules only: the built-in names stay.
    @MainActor func testOnlyAnExceptionAsWrittenForSomeSitesKeepsBuiltInNames() {
        let filter = TrackingParameterFilter(text: """
            @@||app.test^$app=x.exe,removeparam=utm_source
            @@||regex.test^$removeparam=/^utm_/
            @@$removeparam=gclid
            $removeparam=foo
            @@$removeparam=foo,domain=~nofoo.test
            """)
        XCTAssertEqual(clean("https://app.test/?utm_source=1", filter), "https://app.test/")
        XCTAssertEqual(clean("https://regex.test/?utm_source=1&foo=2", filter), "https://regex.test/?foo=2")
        XCTAssertEqual(clean("https://a.test/?gclid=1", filter), "https://a.test/")
        assertUnchanged("https://a.test/?foo=1", filter)
        XCTAssertEqual(clean("https://nofoo.test/?foo=1", filter), "https://nofoo.test/")
    }

    /// A fully qualified host's trailing dot changes nothing.
    @MainActor func testATrailingDotHost() {
        XCTAssertEqual(clean("https://supply.amazon.com./item?ref_=nav&id=1"), "https://supply.amazon.com./item?id=1")
        XCTAssertEqual(clean("https://www.amazon.co.uk./b?asc_campaign=1"), "https://www.amazon.co.uk./b")
    }

    @MainActor func testAnExceptionForAnotherRequestTypeDoesNotKeepAPagesParameter() {
        let filter = TrackingParameterFilter(text: "||meituan.test^$removeparam=foo\n@@||meituan.test^$removeparam=foo,xhr\n")
        XCTAssertEqual(clean("https://meituan.test/?foo=1", filter), "https://meituan.test/")
    }

    /// A regex exception keeps all of its address's parameters rather than
    /// letting a plain rule remove what it protects.
    @MainActor func testARegexExceptionKeepsItsAddressesParameters() {
        let filter = TrackingParameterFilter(text: "$removeparam=foo\n@@||keep.test^$removeparam=/^foo/\n")
        assertUnchanged("https://keep.test/?foo=1", filter)
        XCTAssertEqual(clean("https://keep.test/?foo=1&gclid=2", filter), "https://keep.test/?foo=1",
                       "but not the built-in names")
        XCTAssertEqual(clean("https://other.test/?foo=1", filter), "https://other.test/")
        XCTAssertEqual(filter.counts.widenedExceptions, 1)
    }

    // MARK: - Case, encoding, repeats

    /// List names are compared exactly, as AdGuard and uBlock Origin do;
    /// patterns and domains without case; exceptions without case (keeping a
    /// parameter is the safe side).
    @MainActor func testCase() {
        XCTAssertEqual(clean("https://sell.amazon.de/?refTag=1&reftag=2&REFTAG=3"), "https://sell.amazon.de/?reftag=2&REFTAG=3")
        XCTAssertEqual(clean("https://SUPPLY.Amazon.COM/item?ref_=1&id=2"), "https://SUPPLY.Amazon.COM/item?id=2")
        XCTAssertEqual(clean("https://www.AMAZON.co.UK/b?asc_campaign=1"), "https://www.AMAZON.co.UK/b")
        XCTAssertEqual(clean("https://www.eneba.com/x?UTM_SOURCE=a&utm_medium=b"), "https://www.eneba.com/x?UTM_SOURCE=a")
        assertUnchanged("https://shop.test/?PJCLID=1")
    }

    @MainActor func testRepeatedKeysAreAllRemoved() {
        XCTAssertEqual(clean("https://x.com/user/status/1?s=20&t=abc&s=46"), "https://x.com/user/status/1?t=abc")
        XCTAssertEqual(clean("https://shop.test/?pjclid=1&a=1&pjclid=2&a=2"), "https://shop.test/?a=1&a=2")
    }

    @MainActor func testNamesAsTheListWritesThem() {
        XCTAssertEqual(clean("https://www.reddit.com/r/x?%243p=e_as&%24deep_link=true&keep=1"),
                       "https://www.reddit.com/r/x?%24deep_link=true&keep=1")
        XCTAssertEqual(clean("https://wetransfer.com/downloads/x?utm_source=a&amp;utm_campaign=b&k=1"),
                       "https://wetransfer.com/downloads/x?k=1")
    }

    @MainActor func testNonWebAddressesAreLeftAlone() {
        assertUnchanged("detour://history?pjclid=1")
        assertUnchanged("file:///tmp/a.html?pjclid=1")
        XCTAssertNil(Self.fixture.verdict(for: URL(string: "mailto:a@b.test?pjclid=1")!))
    }

    // MARK: - Real-world links

    /// Ordinary links the excerpt must not change.
    @MainActor func testRealWorldLinksSurviveUnchanged() {
        for link in Self.realWorldLinks { assertUnchanged(link) }
    }

    static let realWorldLinks = [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s",
        "https://www.google.com/search?q=swift+concurrency&hl=en",
        "https://www.google.com/maps/place/Berlin/@52.5,13.4,11z?entry=ttu",
        "https://github.com/swiftlang/swift/issues?q=is%3Aissue+is%3Aopen+label%3Abug&page=2",
        "https://www.amazon.com/dp/B08N5WRWNW?psc=1", // the whole list removes Amazon's th=
        "https://www.amazon.co.uk/s?k=usb+c+cable&crid=1&sprefix=usb",
        "https://en.wikipedia.org/w/index.php?title=Special:Search&search=WebKit&ns0=1",
        "https://news.ycombinator.com/item?id=42",
        "https://www.reddit.com/r/swift/comments/abc/title/?sort=new",
        "https://x.com/search?q=detour&f=live",
        "https://stackoverflow.com/questions/1/x?answertab=votes#tab-top",
        "https://docs.google.com/document/d/abc/edit?tab=t.0#heading=h.1",
        "https://shop.test/cart?coupon=SAVE10&qty=2",
        "https://web.archive.org/web/20200101000000*/example.com",
        "https://example.com/?ref=home&source=feed",
    ]

    // MARK: - Pieces

    @MainActor func testPublicSuffixApproximation() {
        for suffix in ["com", "de", "jp", "co.uk", "com.au", "co.jp", "xn--p1ai", "com.br"] {
            XCTAssertTrue(isPublicSuffixLike(Substring(suffix)), suffix)
        }
        for rest in ["evil.com", "example.org", "c", "1", "co.uk.evil", "", "com.", "co.123"] {
            XCTAssertFalse(isPublicSuffixLike(Substring(rest)), rest)
        }
    }

    // MARK: - Where the downloaded rules apply

    /// Copy and Share use the downloaded rules; without them, the built-in
    /// names alone.
    @MainActor func testCleanLinkUsesTheDownloadedFilterWhenThereIsOne() {
        let saved = TrackingParameters.downloadedFilter
        defer { TrackingParameters.downloadedFilter = saved }
        let url = URL(string: "https://supply.amazon.com/item?ref_=nav&utm_source=x&id=1")!

        TrackingParameters.downloadedFilter = nil
        XCTAssertEqual(TrackingParameters.cleanLink(for: url).absoluteString, "https://supply.amazon.com/item?ref_=nav&id=1")

        TrackingParameters.downloadedFilter = Self.fixture
        XCTAssertEqual(TrackingParameters.cleanLink(for: url).absoluteString, "https://supply.amazon.com/item?id=1")
        XCTAssertEqual(TrackingParameters.copyableString(for: url), "https://supply.amazon.com/item?id=1")
    }

    /// AC #4 (PROVISIONAL): quarantine navigations keep to the built-in list,
    /// with the downloaded rules loaded or not.
    @MainActor func testQuarantineNavigationsUseTheBuiltInListOnly() {
        let saved = TrackingParameters.downloadedFilter
        defer { TrackingParameters.downloadedFilter = saved }
        TrackingParameters.downloadedFilter = Self.fixture

        let url = URL(string: "https://supply.amazon.com/item?ref_=nav&utm_source=x")!
        XCTAssertEqual(Quarantine.trackingFreeURL(for: url, httpMethod: "GET", isBackForwardOrReload: false)?.absoluteString,
                       "https://supply.amazon.com/item?ref_=nav")
        XCTAssertNil(Quarantine.trackingFreeURL(for: URL(string: "https://supply.amazon.com/item?ref_=nav")!,
                                                httpMethod: "GET", isBackForwardOrReload: false))
    }

    // MARK: - The whole list (opt-in)

    /// Runs against a downloaded copy of the whole list when
    /// `TEST_RUNNER_TRACKING_FILTER_FILE` names one: the counts the AC #3
    /// notes quote, the real-world links unchanged, and the time a menu
    /// click's verdict takes. Skipped otherwise (the list is not bundled).
    @MainActor func testTheWholeDownloadedList() throws {
        guard let path = ProcessInfo.processInfo.environment["TRACKING_FILTER_FILE"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_TRACKING_FILTER_FILE to a downloaded copy of the list")
        }
        let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        let start = Date()
        let filter = TrackingParameterFilter(text: text)
        let parseTime = Date().timeIntervalSince(start)
        print("TrackingParameterFilter whole list: \(filter.counts), parsed in \(Int(parseTime * 1000)) ms")
        XCTAssertFalse(filter.isEmpty)
        for link in Self.realWorldLinks { assertUnchanged(link, filter) }

        let links = Self.realWorldLinks.map { URL(string: $0)! }
        let matchStart = Date()
        for _ in 0..<10 { for link in links { _ = TrackingParameters.removing(from: link, using: filter) } }
        let perLink = Date().timeIntervalSince(matchStart) / Double(10 * links.count)
        print("TrackingParameterFilter whole list: \(String(format: "%.3f", perLink * 1000)) ms per link")
        XCTAssertLessThan(perLink, 0.05, "a menu click's match stays well under a frame")
    }
}
