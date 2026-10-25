import XCTest
@testable import Detour

/// TASK-192: the messages `MediaSessionBridge`'s script posts are written from
/// what the page put in `navigator.mediaSession`, so they are validated as
/// untrusted: known actions only, plain bounded text, web artwork URLs only.
final class MediaBridgeMessageTests: XCTestCase {

    private func session(_ body: [String: Any], mainFrame: Bool = true) -> MediaSessionReport? {
        guard case .session(let report)? = MediaBridgeMessage(body: body, isMainFrame: mainFrame) else { return nil }
        return report
    }

    func testASessionReportCarriesTheKnownActionsAndMetadata() {
        let report = session(["kind": "session", "actions": ["play", "pause", "nexttrack", "seekto", "skipad"],
                              "title": "Song", "artist": "Band", "album": "Record",
                              "artwork": [["src": "https://cdn.test/a.png", "sizes": "96x96"]]])
        XCTAssertEqual(report, MediaSessionReport(actions: [.play, .pause, .nexttrack], title: "Song",
                                                  artist: "Band", album: "Record",
                                                  artworkURL: URL(string: "https://cdn.test/a.png")))
    }

    func testAnEmptySessionClearsEverything() {
        XCTAssertEqual(session(["kind": "session", "actions": [String](), "title": NSNull()]), MediaSessionReport())
    }

    func testTextIsFlattenedTrimmedAndBounded() {
        let long = String(repeating: "x", count: 500)
        let report = session(["kind": "session", "actions": [String](), "title": "  Line one\nLine\ttwo\u{0}  ",
                              "artist": long, "album": "   "])
        XCTAssertEqual(report?.title, "Line one Line two")
        XCTAssertEqual(report?.artist?.count, MediaSessionReport.maxTextLength)
        XCTAssertNil(report?.album, "blank text is no text")
    }

    func testNonStringFieldsAreIgnored() {
        let report = session(["kind": "session", "actions": "play", "title": 42, "artist": ["Band"]])
        XCTAssertEqual(report, MediaSessionReport())
    }

    func testArtworkMustBeAWebURL() {
        for src in ["javascript:alert(1)", "file:///etc/passwd", "data:image/png;base64,AAAA", "detour://history", "not a url"] {
            XCTAssertNil(session(["kind": "session", "artwork": [["src": src]]])?.artworkURL, src)
        }
        XCTAssertEqual(session(["kind": "session", "artwork": [["src": "http://cdn.test/a.png"]]])?.artworkURL,
                       URL(string: "http://cdn.test/a.png"))
    }

    func testTheArtworkClosestAboveTheBarsSizeIsChosen() {
        let report = session(["kind": "session", "artwork": [
            ["src": "https://cdn.test/32.png", "sizes": "32x32"],
            ["src": "https://cdn.test/512.png", "sizes": "512x512"],
            ["src": "https://cdn.test/96.png", "sizes": "96x96"],
            ["src": "https://cdn.test/128.png", "sizes": "128x128"],
        ]])
        XCTAssertEqual(report?.artworkURL, URL(string: "https://cdn.test/96.png"))
    }

    func testWithoutALargeEnoughArtworkTheLargestIsChosen() {
        let report = session(["kind": "session", "artwork": [
            ["src": "https://cdn.test/16.png", "sizes": "16x16"],
            ["src": "https://cdn.test/48.png", "sizes": "48x48"],
            ["src": "https://cdn.test/none.png"],
        ]])
        XCTAssertEqual(report?.artworkURL, URL(string: "https://cdn.test/48.png"))
    }

    func testArtworkWithoutSizesFallsBackToTheFirst() {
        let report = session(["kind": "session", "artwork": [["src": "https://cdn.test/a.png"], ["src": "https://cdn.test/b.png"]]])
        XCTAssertEqual(report?.artworkURL, URL(string: "https://cdn.test/a.png"))
    }

    func testSessionAndDocumentMessagesAreHeardOnlyFromTheMainFrame() {
        XCTAssertNil(MediaBridgeMessage(body: ["kind": "session", "title": "x"], isMainFrame: false))
        XCTAssertNil(MediaBridgeMessage(body: ["kind": "document"], isMainFrame: false))
        XCTAssertEqual(MediaBridgeMessage(body: ["kind": "document"], isMainFrame: true), .document)
    }

    func testPictureInPictureIsHeardFromAnyFrame() {
        XCTAssertEqual(MediaBridgeMessage(body: ["kind": "pip", "frame": "f1", "active": true], isMainFrame: false),
                       .pictureInPicture(frame: "f1", active: true))
        XCTAssertEqual(MediaBridgeMessage(body: ["kind": "pip", "frame": "f1", "active": false], isMainFrame: true),
                       .pictureInPicture(frame: "f1", active: false))
    }

    func testMalformedMessagesAreDropped() {
        XCTAssertNil(MediaBridgeMessage(body: "session", isMainFrame: true))
        XCTAssertNil(MediaBridgeMessage(body: ["kind": "other"], isMainFrame: true))
        XCTAssertNil(MediaBridgeMessage(body: ["kind": "pip", "active": true], isMainFrame: true))
        XCTAssertNil(MediaBridgeMessage(body: ["kind": "pip", "frame": "", "active": true], isMainFrame: true))
        XCTAssertNil(MediaBridgeMessage(body: ["kind": "pip", "frame": "f", "active": "yes"], isMainFrame: true))
        XCTAssertNil(MediaBridgeMessage(body: ["kind": "pip", "frame": String(repeating: "f", count: 200), "active": true],
                                        isMainFrame: true), "a frame token is short")
    }
}
