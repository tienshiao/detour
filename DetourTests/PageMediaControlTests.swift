import XCTest
import WebKit
@testable import Detour

/// TASK-192: the private page-mute call is guarded, and changing the audio
/// bit leaves capture mutes alone.
@MainActor
final class PageMediaControlTests: XCTestCase {

    func testMutingSetsOnlyTheAudioBit() {
        XCTAssertEqual(PageMediaControl.mutedState(from: 0, audioMuted: true), 1)
        XCTAssertEqual(PageMediaControl.mutedState(from: 0b110, audioMuted: true), 0b111,
                       "a muted camera, microphone or screen capture stays muted")
    }

    func testUnmutingClearsOnlyTheAudioBit() {
        XCTAssertEqual(PageMediaControl.mutedState(from: 1, audioMuted: false), 0)
        XCTAssertEqual(PageMediaControl.mutedState(from: 0b111, audioMuted: false), 0b110)
    }

    func testPageMuteNeedsBothSelectors() {
        XCTAssertTrue(PageMediaControl.canMutePage(webViewResponds: { _ in true }))
        XCTAssertFalse(PageMediaControl.canMutePage(webViewResponds: { $0 != PageMediaControl.Selectors.setPageMuted }))
        XCTAssertFalse(PageMediaControl.canMutePage(webViewResponds: { $0 != PageMediaControl.Selectors.mediaMutedState }))
    }

    func testThisWebKitCanMuteAPageAndReadItBack() {
        XCTAssertTrue(PageMediaControl.canMutePage, "the shipped WebKit has _setPageMuted: and _mediaMutedState")
        let control = PageMediaControl(webView: WKWebView())
        XCTAssertFalse(control.isPageAudioMuted)
        XCTAssertTrue(control.setPageAudioMuted(true))
        XCTAssertTrue(control.isPageAudioMuted)
        XCTAssertTrue(control.setPageAudioMuted(false))
        XCTAssertFalse(control.isPageAudioMuted)
    }
}
