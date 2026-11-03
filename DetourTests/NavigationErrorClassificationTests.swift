import XCTest
import Foundation
@testable import Detour

/// TASK-121: a standalone video URL renders as a media document, and WebKit
/// cancels its main-resource load with `WebKitErrorPlugInWillHandleLoad` (204)
/// once the media player takes over. That error must be ignored like the other
/// benign interruptions, or the playing video is replaced by the error page.
/// The domain matters: only WebKitErrorDomain codes are WebKit's own.
///
/// The predicate has two callers with two questions. The window delegate asks
/// "must this become an error page?" (`isIgnoredNavigationError`); the
/// offscreen document host asks "will another callback still follow?"
/// (`isSupersededNavigationError`). 204 answers them differently: no error
/// page, but also no `didFinish` to wait for.
nonisolated final class NavigationErrorClassificationTests: XCTestCase {
    @MainActor private func webKitError(_ code: Int) -> Error {
        NSError(domain: "WebKitErrorDomain", code: code)
    }

    @MainActor private func urlError(_ code: Int) -> Error {
        NSError(domain: NSURLErrorDomain, code: code)
    }

    @MainActor func testFrameLoadInterruptedByPolicyChangeIsIgnored() {
        XCTAssertTrue(webKitError(102).isIgnoredNavigationError)
    }

    @MainActor func testPlugInWillHandleLoadIsIgnored() {
        XCTAssertTrue(webKitError(204).isIgnoredNavigationError)
    }

    @MainActor func testURLCancelledIsIgnored() {
        XCTAssertTrue(urlError(NSURLErrorCancelled).isIgnoredNavigationError)
    }

    @MainActor func testCannotConnectToHostIsNotIgnored() {
        XCTAssertFalse(urlError(NSURLErrorCannotConnectToHost).isIgnoredNavigationError)
    }

    @MainActor func testWebKitCannotShowURLIsNotIgnored() {
        XCTAssertFalse(webKitError(101).isIgnoredNavigationError)
    }

    @MainActor func testCode204InAnotherDomainIsNotIgnored() {
        XCTAssertFalse(urlError(204).isIgnoredNavigationError)
    }

    // MARK: - Superseded vs. ended

    @MainActor func testPolicyChangeAndCancellationAreSuperseded() {
        XCTAssertTrue(webKitError(102).isSupersededNavigationError)
        XCTAssertTrue(urlError(NSURLErrorCancelled).isSupersededNavigationError)
    }

    /// The offscreen host keeps a load pending on a superseded error. 204 must
    /// not qualify: WebKit sends no `didFinish` after it, so a host waiting on
    /// one would never settle `createDocument`.
    @MainActor func testPlugInWillHandleLoadIsNotSuperseded() {
        XCTAssertFalse(webKitError(204).isSupersededNavigationError)
        XCTAssertTrue(webKitError(204).isPlugInHandledLoadError)
    }

    @MainActor func testRealFailuresAreNeitherSupersededNorPlugInHandled() {
        for error in [urlError(NSURLErrorCannotConnectToHost), webKitError(101), urlError(204)] {
            XCTAssertFalse(error.isSupersededNavigationError, "\(error)")
            XCTAssertFalse(error.isPlugInHandledLoadError, "\(error)")
        }
    }
}
