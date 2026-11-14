import XCTest
@testable import Detour

/// The link tracking parameter rule (`TrackingParameters`): the one list
/// Detour removes, used by a quarantine page's navigations (TASK-194) and by
/// Copy URL / Copy Link (TASK-326). Pure; the copy entry points are covered
/// in `CopyURLTests`, `DevToolbarHostingTests` and `QuickDetourWindowTests`.
nonisolated final class TrackingParametersTests: XCTestCase {

    @MainActor private func stripped(_ s: String) -> String {
        TrackingParameters.removing(from: URL(string: s)!).absoluteString
    }

    // MARK: - The list

    @MainActor func testClickIDsAndCampaignTagsAreRemoved() {
        XCTAssertEqual(stripped("https://a.test/p?gclid=1&fbclid=2&msclkid=3&utm_source=news&utm_medium=email"
                                + "&utm_campaign=fall&utm_term=t&utm_content=c&mc_eid=4&mc_cid=5"),
                       "https://a.test/p")
        for name in ["gclid", "gclsrc", "dclid", "gbraid", "wbraid", "_ga", "fbclid", "msclkid", "mc_eid", "mc_cid",
                     "igshid", "yclid", "twclid", "ttclid", "li_fat_id", "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id",
                     "oly_enc_id", "vero_id", "rb_clickid", "s_cid", "utm_id", "utm_source_platform"] {
            XCTAssertTrue(TrackingParameters.isTracking(name), name)
        }
    }

    /// TASK-326 AC #1 names these; each one goes on its own.
    @MainActor func testEachNameTheCopyTaskListsIsRemoved() {
        for name in ["utm_source", "utm_medium", "utm_campaign", "fbclid", "gclid", "msclkid", "mc_eid", "mc_cid",
                     "igshid", "_ga", "yclid", "dclid"] {
            XCTAssertEqual(stripped("https://a.test/p?keep=1&\(name)=v"), "https://a.test/p?keep=1", name)
        }
    }

    @MainActor func testNamesAreComparedWithoutCase() {
        XCTAssertEqual(stripped("https://a.test/?GCLID=1&UTM_Source=x&FbClId=2&_GA=3&keep=1"), "https://a.test/?keep=1")
    }

    /// AC #4: a name that only resembles a tracking one stays unless the list
    /// names it.
    @MainActor func testLookalikeNamesAreKept() {
        XCTAssertEqual(stripped("https://a.test/?utm=1&xutm_source=2&gclid_extra=3&fbclid2=4&ga=5&_gac=6"),
                       "https://a.test/?utm=1&xutm_source=2&gclid_extra=3&fbclid2=4&ga=5&_gac=6")
        XCTAssertEqual(stripped("https://a.test/item?ref=home&source=feed&utm_source=x&campaign=7"),
                       "https://a.test/item?ref=home&source=feed&campaign=7")
        for name in ["utm", "utm_", "id", "ref", "source", "campaign", "ga", "click_id"] {
            XCTAssertFalse(TrackingParameters.isTracking(name), name)
        }
    }

    // MARK: - What the rest of the URL keeps

    @MainActor func testOtherParametersKeepTheirOrderAndSpelling() {
        XCTAssertEqual(stripped("https://a.test/p?a=1&gclid=x&b=two%20words&utm_source=y&c"),
                       "https://a.test/p?a=1&b=two%20words&c")
        XCTAssertEqual(stripped("https://a.test/search?q=utm_source%3Dx&id=7"), "https://a.test/search?q=utm_source%3Dx&id=7",
                       "a value that mentions a tracking name is not one")
    }

    @MainActor func testPercentEncodedValuesSurviveByteForByte() {
        XCTAssertEqual(stripped("https://a.test/p?q=a+b%2Bc&tags%5B%5D=x%26y&fbclid=1&e=%C3%A9%20%7E"),
                       "https://a.test/p?q=a+b%2Bc&tags%5B%5D=x%26y&e=%C3%A9%20%7E")
    }

    @MainActor func testPercentEncodedNamesAreDecodedBeforeTheyAreCompared() {
        XCTAssertEqual(stripped("https://a.test/p?utm%5Fsource=x&%67clid=1&keep=1"), "https://a.test/p?keep=1")
    }

    @MainActor func testRepeatedKeysAreAllRemovedOrAllKept() {
        XCTAssertEqual(stripped("https://a.test/?utm_source=a&x=1&utm_source=b&gclid"), "https://a.test/?x=1",
                       "repeated and valueless tracking parameters all go")
        XCTAssertEqual(stripped("https://a.test/?a=1&utm_source=x&a=2&a=1"), "https://a.test/?a=1&a=2&a=1",
                       "repeated other parameters all stay, in order")
    }

    // MARK: - The query and the fragment

    @MainActor func testOnlyTrackingParametersLeaveNoQuestionMark() {
        XCTAssertEqual(stripped("https://a.test/doc?utm_source=x"), "https://a.test/doc")
        XCTAssertEqual(stripped("https://a.test/doc?utm_source=x&gclid=2&_ga=3"), "https://a.test/doc")
        XCTAssertEqual(stripped("https://a.test/doc?utm_source=x&"), "https://a.test/doc", "a trailing &")
        XCTAssertEqual(stripped("https://a.test/doc?gclid=1&&fbclid=2"), "https://a.test/doc", "an empty piece")
        XCTAssertEqual(stripped("https://a.test/doc?a=1&&gclid=2&"), "https://a.test/doc?a=1")
    }

    @MainActor func testTheFragmentIsKept() {
        XCTAssertEqual(stripped("https://a.test/doc?fbclid=1#section-2"), "https://a.test/doc#section-2")
        XCTAssertEqual(stripped("https://a.test/doc?a=1&fbclid=1#s?utm_source=x"), "https://a.test/doc?a=1#s?utm_source=x",
                       "what the fragment says is not a query")
    }

    @MainActor func testAURLWithoutTrackingParametersIsUnchanged() {
        for s in ["https://a.test/", "https://a.test/p?q=1", "http://a.test:8080/p?x=1#y", "https://a.test/p?",
                  "https://a.test/p#frag", "https://a.test/p?a=1&&b=2&", "https://user@a.test/p?q=a+b%2B#f"] {
            XCTAssertEqual(stripped(s), s)
        }
    }

    @MainActor func testOnlyWebURLsAreTouched() {
        for s in ["mailto:someone@a.test?utm_source=x", "detour://history?utm_source=x", "data:text/plain,utm_source=x",
                  "file:///tmp/a.html?utm_source=x"] {
            XCTAssertEqual(stripped(s), s)
        }
    }

    @MainActor func testTheCopiedStringIsTheCleanAddress() {
        XCTAssertEqual(TrackingParameters.copyableString(for: URL(string: "https://a.test/p?id=1&utm_source=x#top")!),
                       "https://a.test/p?id=1#top")
        XCTAssertEqual(TrackingParameters.copyableString(for: URL(string: "https://a.test/p?id=1")!), "https://a.test/p?id=1")
    }
}
