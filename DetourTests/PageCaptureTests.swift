import XCTest
import AppKit
import ImageIO
import WebKit
@testable import Detour

/// TASK-186.3: the dev toolbar's capture buttons. The pixel math, the file
/// name, PNG encoding and delivery are pure or local; the captures themselves
/// run against a real WKWebView, at 2x through WebKit's device scale override
/// so the Retina path is covered on a 1x display too.
final class PageCaptureGeometryTests: XCTestCase {

    // MARK: - Pixel size

    func testAt1xThePixelSizeIsThePointSize() {
        XCTAssertEqual(CaptureGeometry.pixelSize(points: CGSize(width: 1000, height: 700), scale: 1),
                       .init(pixelWidth: 1000, pixelHeight: 700, scale: 1))
    }

    func testAt2xThePixelSizeIsTwiceThePointSize() {
        XCTAssertEqual(CaptureGeometry.pixelSize(points: CGSize(width: 1000, height: 700), scale: 2),
                       .init(pixelWidth: 2000, pixelHeight: 1400, scale: 2))
    }

    func testATallPageIsScaledDownToTheLongEdgeCap() throws {
        // 2000 x 40000 px raw: the long edge comes down to 16384.
        let out = try XCTUnwrap(CaptureGeometry.pixelSize(points: CGSize(width: 1000, height: 20000), scale: 2))
        XCTAssertEqual(out.pixelHeight, 16384)
        XCTAssertEqual(out.pixelWidth, 819)
        XCTAssertEqual(out.scale, 0.8192, accuracy: 0.0001)
    }

    func testAWidePageIsScaledDownByItsWidth() throws {
        let out = try XCTUnwrap(CaptureGeometry.pixelSize(points: CGSize(width: 30000, height: 800), scale: 1))
        XCTAssertEqual(out.pixelWidth, 16384)
        XCTAssertEqual(out.pixelHeight, 437, "800 x 0.5461 = 436.9, rounded")
    }

    func testABigSquarePageIsScaledDownByArea() throws {
        // 12000 x 12000 px is under the edge cap but over 2^26 px.
        let out = try XCTUnwrap(CaptureGeometry.pixelSize(points: CGSize(width: 6000, height: 6000), scale: 2))
        XCTAssertEqual(out.pixelWidth, 8192)
        XCTAssertEqual(out.pixelHeight, 8192)
        XCTAssertLessThanOrEqual(out.pixelWidth * out.pixelHeight, CaptureGeometry.maxPixelArea)
    }

    func testScaledDownSizesNeverExceedTheCaps() throws {
        for points in [CGSize(width: 1234.5, height: 98765.4), CGSize(width: 7777, height: 9999), CGSize(width: 50000, height: 3)] {
            let out = try XCTUnwrap(CaptureGeometry.pixelSize(points: points, scale: 2))
            XCTAssertLessThanOrEqual(max(out.pixelWidth, out.pixelHeight), CaptureGeometry.maxPixelEdge, "\(points)")
            XCTAssertLessThanOrEqual(out.pixelWidth * out.pixelHeight, CaptureGeometry.maxPixelArea, "\(points)")
            XCTAssertGreaterThanOrEqual(min(out.pixelWidth, out.pixelHeight), 1, "\(points)")
        }
    }

    func testAPageWithinTheCapsIsNeverScaledUpOrDown() {
        XCTAssertEqual(CaptureGeometry.pixelSize(points: CGSize(width: 100, height: 50), scale: 3, maxEdge: 1000, maxArea: 1 << 20),
                       .init(pixelWidth: 300, pixelHeight: 150, scale: 3))
    }

    func testFractionalPointSizesRound() {
        XCTAssertEqual(CaptureGeometry.pixelSize(points: CGSize(width: 1000.6, height: 700.4), scale: 1),
                       .init(pixelWidth: 1001, pixelHeight: 700, scale: 1))
    }

    func testAnEmptySizeHasNoImage() {
        XCTAssertNil(CaptureGeometry.pixelSize(points: .zero, scale: 2))
        XCTAssertNil(CaptureGeometry.pixelSize(points: CGSize(width: 0, height: 700), scale: 2))
        XCTAssertNil(CaptureGeometry.pixelSize(points: CGSize(width: 1000, height: 700), scale: 0))
    }

    // MARK: - Full-page method

    func testAFullPageWithinTheRawLimitUsesWebKitsContentsSnapshot() {
        XCTAssertEqual(CaptureGeometry.fullPageMethod(points: CGSize(width: 1000, height: 5320), scale: 2,
                                                      contentsRectAvailable: true), .contentsRect)
        // Over the edge cap but not the raw area: still the contents snapshot,
        // scaled down afterwards.
        XCTAssertEqual(CaptureGeometry.fullPageMethod(points: CGSize(width: 800, height: 10000), scale: 2,
                                                      contentsRectAvailable: true), .contentsRect)
    }

    func testAFullPageOverTheRawLimitIsDrawnFromAPDF() {
        XCTAssertEqual(CaptureGeometry.fullPageMethod(points: CGSize(width: 1440, height: 30000), scale: 2,
                                                      contentsRectAvailable: true), .pdf)
    }

    func testWithoutWebKitsContentsSnapshotTheFullPageIsDrawnFromAPDF() {
        XCTAssertEqual(CaptureGeometry.fullPageMethod(points: CGSize(width: 100, height: 100), scale: 1,
                                                      contentsRectAvailable: false), .pdf)
    }

    // MARK: - Document size and resolution

    func testTheDocumentSizeIsTheScrollSize() {
        XCTAssertEqual(CaptureGeometry.documentPoints(scrollWidth: 1000, scrollHeight: 5320,
                                                      viewportWidth: 1000, viewportHeight: 700, pageZoom: 1),
                       CGSize(width: 1000, height: 5320))
    }

    func testAShortPageIsAtLeastTheViewport() {
        XCTAssertEqual(CaptureGeometry.documentPoints(scrollWidth: 1000, scrollHeight: 300,
                                                      viewportWidth: 1000, viewportHeight: 700, pageZoom: 1),
                       CGSize(width: 1000, height: 700))
    }

    func testPageZoomScalesCSSPixelsToPoints() {
        XCTAssertEqual(CaptureGeometry.documentPoints(scrollWidth: 800, scrollHeight: 2000,
                                                      viewportWidth: 800, viewportHeight: 600, pageZoom: 1.5),
                       CGSize(width: 1200, height: 3000))
    }

    func testTheDPIMakesThePNGPreviewAtItsPointSize() {
        XCTAssertEqual(CaptureGeometry.dpi(pixelWidth: 2000, pointWidth: 1000), 144)
        XCTAssertEqual(CaptureGeometry.dpi(pixelWidth: 1000, pointWidth: 1000), 72)
        XCTAssertEqual(CaptureGeometry.dpi(pixelWidth: 819, pointWidth: 1000), 58.968, accuracy: 0.001)
        XCTAssertEqual(CaptureGeometry.dpi(pixelWidth: 100, pointWidth: 0), 72, "no width: plain 72 dpi")
    }

    // MARK: - File name

    private let date = ISO8601DateFormatter().date(from: "2026-10-24T21:05:03Z")!
    private let utc = TimeZone(identifier: "UTC")!

    func testTheFileNameNamesTheHostAndTheTime() {
        XCTAssertEqual(CaptureFileName.make(host: "localhost:3000", date: date, fullPage: false, timeZone: utc),
                       "Screenshot localhost-3000 2026-10-24 at 21.05.03.png")
    }

    func testAFullPageCaptureSaysSo() {
        XCTAssertEqual(CaptureFileName.make(host: "app.test", date: date, fullPage: true, timeZone: utc),
                       "Screenshot app.test 2026-10-24 at 21.05.03 (full page).png")
    }

    func testTheTimeIsLocal() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(CaptureFileName.make(host: "localhost", date: date, fullPage: false, timeZone: tokyo),
                       "Screenshot localhost 2026-10-25 at 06.05.03.png")
    }

    func testTheNameHasNoPathOrFinderSeparators() {
        let name = CaptureFileName.make(host: "[::1]:8080", date: date, fullPage: false, timeZone: utc)
        XCTAssertFalse(name.contains(":"), name)
        XCTAssertFalse(name.contains("/"), name)
        XCTAssertTrue(name.hasPrefix("Screenshot "), name)
    }

    func testWithoutAHostTheNameIsJustTheTime() {
        XCTAssertEqual(CaptureFileName.make(host: "", date: date, fullPage: false, timeZone: utc),
                       "Screenshot 2026-10-24 at 21.05.03.png")
    }

    func testAUniqueNameNeverOverwrites() {
        let dir = URL(fileURLWithPath: "/captures", isDirectory: true)
        let name = "Screenshot a 2026-10-24 at 21.05.03.png"
        XCTAssertEqual(CaptureFileName.unique(name, in: dir, exists: { _ in false }).lastPathComponent, name)
        var taken: Set<String> = [name]
        XCTAssertEqual(CaptureFileName.unique(name, in: dir, exists: { taken.contains($0.lastPathComponent) }).lastPathComponent,
                       "Screenshot a 2026-10-24 at 21.05.03 (2).png")
        taken.insert("Screenshot a 2026-10-24 at 21.05.03 (2).png")
        let third = CaptureFileName.unique(name, in: dir, exists: { taken.contains($0.lastPathComponent) })
        XCTAssertEqual(third.lastPathComponent, "Screenshot a 2026-10-24 at 21.05.03 (3).png")
        XCTAssertEqual(third.deletingLastPathComponent().path, "/captures")
    }
}

// MARK: - Images and delivery

/// Reads a PNG back: pixel size, DPI and the colour at a pixel (row 0 at the top).
struct DecodedPNG {
    let width: Int
    let height: Int
    let dpi: Double?
    private let pixels: [UInt8]

    init?(_ data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        pixels = buffer
    }

    /// "rrggbb" at (x, y), y from the top.
    func color(x: Int, y: Int) -> String {
        let i = (y * width + x) * 4
        return String(format: "%02x%02x%02x", pixels[i], pixels[i + 1], pixels[i + 2])
    }
}

final class PageCaptureImageTests: XCTestCase {

    private func solidImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    func testThePNGKeepsThePixelSizeAndRecordsTheDPI() throws {
        let data = try XCTUnwrap(CaptureImage.pngData(solidImage(width: 20, height: 10, red: 1, green: 0, blue: 0), dpi: 144))
        let png = try XCTUnwrap(DecodedPNG(data))
        XCTAssertEqual(png.width, 20)
        XCTAssertEqual(png.height, 10)
        XCTAssertEqual(png.dpi, 144)
        XCTAssertEqual(png.color(x: 10, y: 5), "ff0000")
    }

    func testScalingRedrawsAtTheNewPixelSize() throws {
        let scaled = try XCTUnwrap(CaptureImage.scaled(solidImage(width: 20, height: 10, red: 0, green: 0, blue: 1), width: 10, height: 5))
        XCTAssertEqual(scaled.width, 10)
        XCTAssertEqual(scaled.height, 5)
    }

    /// A 100 x 300 pt PDF page: red on top, blue at the bottom.
    private func twoBandPDF() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 100, height: 300)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 150))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 150, width: 100, height: 150))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    func testAPDFPageIsRasterisedAtTheOutputSizeTheRightWayUp() throws {
        let pdf = twoBandPDF()
        XCTAssertEqual(CaptureImage.pdfPageSize(pdf), CGSize(width: 100, height: 300))
        let image = try XCTUnwrap(CaptureImage.rasterizePDF(pdf, output: .init(pixelWidth: 200, pixelHeight: 600, scale: 2)))
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 600)
        let png = try XCTUnwrap(DecodedPNG(try XCTUnwrap(CaptureImage.pngData(image, dpi: 144))))
        XCTAssertEqual(png.color(x: 100, y: 10), "ff0000", "the top of the page is the top of the image")
        XCTAssertEqual(png.color(x: 100, y: 590), "0000ff")
    }

    func testNotAPDFHasNoPage() {
        XCTAssertNil(CaptureImage.pdfPageSize(Data("nope".utf8)))
        XCTAssertNil(CaptureImage.rasterizePDF(Data("nope".utf8), output: .init(pixelWidth: 10, pixelHeight: 10, scale: 1)))
    }

    func testCopyPutsThePNGOnThePasteboardAndTIFFOnDemand() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DetourTests.capture.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let png = try XCTUnwrap(CaptureImage.pngData(solidImage(width: 30, height: 20, red: 0, green: 1, blue: 0), dpi: 144))
        CaptureDelivery.copy(png: png, to: pasteboard)
        XCTAssertEqual(pasteboard.data(forType: .png), png)
        let tiff = try XCTUnwrap(pasteboard.data(forType: .tiff))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        XCTAssertEqual(rep.pixelsWide, 30)
        XCTAssertEqual(rep.pixelsHigh, 20)
        XCTAssertEqual(rep.size, NSSize(width: 15, height: 10), "the TIFF keeps the 2x point size")
    }

    func testSavingTwiceKeepsBothFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PageCaptureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = try XCTUnwrap(CaptureImage.pngData(solidImage(width: 4, height: 4, red: 1, green: 1, blue: 0), dpi: 72))
        let name = "Screenshot x 2026-10-24 at 21.05.03.png"
        let first = try CaptureDelivery.save(png: png, name: name, in: dir)
        let second = try CaptureDelivery.save(png: png, name: name, in: dir)
        XCTAssertEqual(first.lastPathComponent, name)
        XCTAssertEqual(second.lastPathComponent, "Screenshot x 2026-10-24 at 21.05.03 (2).png")
        XCTAssertEqual(try Data(contentsOf: first), png)
        XCTAssertEqual(try Data(contentsOf: second), png)
    }
}

// MARK: - Captures of a real web view

@MainActor
final class PageCaptureWebViewTests: XCTestCase, WKNavigationDelegate {

    private var window: NSWindow?
    private var loaded: XCTestExpectation?

    override func tearDown() {
        window?.close()
        window = nil
        super.tearDown()
    }

    /// Red, green, blue bands of 500 px and a 50 px magenta marker at the
    /// bottom: 1550 CSS px tall. The page fixes its width so a legacy
    /// scrollbar cannot change it.
    private let tallPage = """
    <!doctype html><html><head><style>
    html,body{margin:0;padding:0}
    div{width:400px;height:500px}
    </style></head><body>
    <div style="background:#ff0000"></div><div style="background:#00ff00"></div>
    <div style="background:#0000ff"></div><div style="height:50px;background:#ff00ff"></div>
    </body></html>
    """

    /// A 400 x 300 pt web view in a window, at `scale` through WebKit's
    /// device scale override.
    private func makeWebView(scale: CGFloat, html: String?) throws -> WKWebView {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WKWebViewConfiguration())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        self.window = window
        let setter = NSSelectorFromString("_setOverrideDeviceScaleFactor:")
        try XCTSkipUnless(webView.responds(to: setter), "this WebKit has no device scale override")
        typealias SetScale = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        unsafeBitCast(webView.method(for: setter), to: SetScale.self)(webView, setter, scale)
        if let html {
            webView.navigationDelegate = self
            let loaded = expectation(description: "loaded")
            self.loaded = loaded
            webView.loadHTMLString(html, baseURL: URL(string: "http://capture.test/"))
            wait(for: [loaded], timeout: 10)
        }
        return webView
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { loaded?.fulfill() }
    }

    private func evaluate(_ webView: WKWebView, _ script: String) -> Any? {
        let done = expectation(description: "evaluated")
        var value: Any?
        webView.evaluateJavaScript(script) { result, _ in
            value = result
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return value
    }

    private func capture(_ kind: PageCapture.Kind, _ webView: WKWebView,
                         method: CaptureGeometry.FullPageMethod? = nil) -> Result<PageCapture.Result, PageCapture.Failure> {
        let done = expectation(description: "captured")
        var outcome: Result<PageCapture.Result, PageCapture.Failure>?
        PageCapture.capture(kind, of: webView, fullPageMethod: method) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        return outcome ?? .failure(.snapshotFailed)
    }

    func testTheVisibleAreaIsCapturedAtDevicePixels() throws {
        let webView = try makeWebView(scale: 2, html: tallPage)
        _ = evaluate(webView, "window.scrollTo(0, 600); 0")
        let result = try capture(.visible, webView).get()
        XCTAssertEqual(result.pixelWidth, 800)
        XCTAssertEqual(result.pixelHeight, 600)
        XCTAssertFalse(result.scaledDown)
        let png = try XCTUnwrap(DecodedPNG(result.png))
        XCTAssertEqual(png.width, 800)
        XCTAssertEqual(png.height, 600)
        XCTAssertEqual(png.dpi, 144)
        XCTAssertEqual(png.color(x: 200, y: 10), "00ff00", "scrolled to 600: the green band is at the top")
        XCTAssertEqual(png.color(x: 200, y: 590), "00ff00")
    }

    func testTheVisibleAreaAt1x() throws {
        let webView = try makeWebView(scale: 1, html: tallPage)
        let result = try capture(.visible, webView).get()
        let png = try XCTUnwrap(DecodedPNG(result.png))
        XCTAssertEqual([png.width, png.height], [400, 300])
        XCTAssertEqual(png.dpi, 72)
        XCTAssertEqual(png.color(x: 200, y: 150), "ff0000")
    }

    private func assertWholeTallPage(_ result: PageCapture.Result, file: StaticString = #filePath, line: UInt = #line) throws {
        let png = try XCTUnwrap(DecodedPNG(result.png), file: file, line: line)
        XCTAssertEqual(png.width, 800, file: file, line: line)
        XCTAssertEqual(png.height, 3100, "the whole 1550 pt document at 2x", file: file, line: line)
        XCTAssertEqual(png.dpi, 144, file: file, line: line)
        XCTAssertFalse(result.scaledDown, file: file, line: line)
        XCTAssertEqual(png.color(x: 200, y: 10), "ff0000", "the top of the document", file: file, line: line)
        XCTAssertEqual(png.color(x: 200, y: 1500), "00ff00", file: file, line: line)
        XCTAssertEqual(png.color(x: 200, y: 2500), "0000ff", file: file, line: line)
        XCTAssertEqual(png.color(x: 200, y: 3090), "ff00ff", "the bottom marker", file: file, line: line)
    }

    func testTheFullPageHoldsTheWholeDocumentWhereverItIsScrolled() throws {
        let webView = try makeWebView(scale: 2, html: tallPage)
        _ = evaluate(webView, "window.scrollTo(0, 700); 0")
        try assertWholeTallPage(try capture(.fullPage, webView).get())
        let scrollY = evaluate(webView, "scrollY") as? Double
        XCTAssertEqual(scrollY, 700, "the capture leaves the page where it was")
    }

    func testTheFullPageFromAPDFHoldsTheWholeDocument() throws {
        let webView = try makeWebView(scale: 2, html: tallPage)
        _ = evaluate(webView, "window.scrollTo(0, 700); 0")
        try assertWholeTallPage(try capture(.fullPage, webView, method: .pdf).get())
    }

    func testAWebViewWithNoPageFails() throws {
        let webView = try makeWebView(scale: 2, html: nil)
        XCTAssertEqual(capture(.visible, webView), .failure(.noPage))
        XCTAssertEqual(capture(.fullPage, webView), .failure(.noPage))
    }
}

// MARK: - The toolbar's capture group

@MainActor
final class DevToolbarCaptureGroupTests: XCTestCase {

    func testTheGroupSitsBetweenTheLinkAndTheInspector() throws {
        let toolbar = DevToolbarView(frame: NSRect(x: 0, y: 0, width: 800, height: DevToolbarLayout.height))
        DevToolbarInspectorGroup.install(in: toolbar, capabilities: [.console])
        let group = DevToolbarCaptureGroup.install(in: toolbar)
        XCTAssertTrue(DevToolbarCaptureGroup.install(in: toolbar) === group, "installed once")
        let views = toolbar.trailingStack.arrangedSubviews
        XCTAssertEqual(views.count, 6)
        XCTAssertTrue(views[0] === toolbar.copyButton)
        XCTAssertTrue(views[1] is NSBox)
        XCTAssertTrue(views[2] === group.visibleButton)
        XCTAssertTrue(views[3] === group.fullPageButton)
        XCTAssertTrue(views[4] is NSBox)
        XCTAssertTrue(views[5] === toolbar.inspectorGroup?.consoleButton)
        XCTAssertEqual(group.visibleButton.accessibilityLabel(), "Capture Visible Area")
        XCTAssertEqual(group.fullPageButton.accessibilityLabel(), "Capture Full Page")
    }

    /// Two groups, two separators: each stays a 1 pt vertical hairline and
    /// the stack stays packed at the right (an unconstrained NSBox separator
    /// once stretched across the bar and pulled the link button left).
    func testTheSeparatorsStayHairlinesAndTheButtonsStayAtTheRight() throws {
        let toolbar = DevToolbarView(frame: NSRect(x: 0, y: 0, width: 900, height: DevToolbarLayout.height))
        toolbar.url = URL(string: "http://localhost:8863/a.html")
        DevToolbarInspectorGroup.install(in: toolbar, capabilities: [.console, .network, .elementPicker])
        let group = DevToolbarCaptureGroup.install(in: toolbar)
        toolbar.layoutSubtreeIfNeeded()
        let separators = toolbar.trailingStack.arrangedSubviews.filter { $0 is NSBox }
        XCTAssertEqual(separators.count, 2)
        for separator in separators {
            XCTAssertLessThanOrEqual(separator.alignmentRect(forFrame: separator.frame).width, 1, "a vertical hairline")
            XCTAssertLessThan(separator.frame.width, separator.frame.height)
        }
        let copy = toolbar.copyButton.convert(toolbar.copyButton.bounds, to: toolbar)
        let camera = group.visibleButton.convert(group.visibleButton.bounds, to: toolbar)
        XCTAssertLessThan(camera.minX - copy.maxX, 24, "the link sits just before the capture group")
        XCTAssertGreaterThan(copy.minX, 600, "the trailing stack is packed at the right")
    }

    func testAClickCopiesAndAnOptionClickSaves() throws {
        let toolbar = DevToolbarView(frame: NSRect(x: 0, y: 0, width: 800, height: DevToolbarLayout.height))
        let group = DevToolbarCaptureGroup.install(in: toolbar)
        var calls: [String] = []
        group.onCapture = { kind, toFile in calls.append("\(kind == .visible ? "visible" : "full") \(toFile ? "file" : "clipboard")") }
        var flags: NSEvent.ModifierFlags = []
        group.modifierFlags = { flags }
        group.visibleButton.performClick(nil)
        group.fullPageButton.performClick(nil)
        flags = [.option]
        group.visibleButton.performClick(nil)
        flags = [.option, .shift]
        group.fullPageButton.performClick(nil)
        XCTAssertEqual(calls, ["visible clipboard", "full clipboard", "visible file", "full file"])
    }

    func testTheButtonsAreDisabledWhileACaptureIsInFlight() throws {
        let toolbar = DevToolbarView(frame: NSRect(x: 0, y: 0, width: 800, height: DevToolbarLayout.height))
        let group = DevToolbarCaptureGroup.install(in: toolbar)
        group.isCapturing = true
        XCTAssertFalse(group.visibleButton.isEnabled)
        XCTAssertFalse(group.fullPageButton.isEnabled)
        group.isCapturing = false
        XCTAssertTrue(group.visibleButton.isEnabled)
        XCTAssertTrue(group.fullPageButton.isEnabled)
    }
}
