import AppKit
import UniformTypeIdentifiers
import WebKit

/// Encoding and scaling for the dev toolbar's captures (TASK-186.3).
enum CaptureImage {
    /// PNG data for `image` at its own pixel size, with `dpi` recorded so it
    /// previews at the page's size in points.
    static func pngData(_ image: CGImage, dpi: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let properties = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// `image` redrawn at `width` x `height` pixels.
    static func scaled(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = bitmapContext(width: width, height: height, colorSpace: image.colorSpace) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// The first page of a PDF, rasterised at `output`'s pixel size on white.
    static func rasterizePDF(_ data: Data, output: CaptureGeometry.Output) -> CGImage? {
        guard let page = firstPage(data),
              let context = bitmapContext(width: output.pixelWidth, height: output.pixelHeight, colorSpace: nil) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: output.pixelWidth, height: output.pixelHeight))
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(output.pixelWidth) / box.width, y: CGFloat(output.pixelHeight) / box.height)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    /// The first page's size in points.
    static func pdfPageSize(_ data: Data) -> CGSize? {
        firstPage(data)?.getBoxRect(.mediaBox).size
    }

    private static func firstPage(_ data: Data) -> CGPDFPage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages > 0 else { return nil }
        return document.page(at: 1)
    }

    private static func bitmapContext(width: Int, height: Int, colorSpace: CGColorSpace?) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        let space = colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

/// Where a capture goes: the clipboard, or a file.
enum CaptureDelivery {
    /// Puts `png` on `pasteboard` as PNG, and as TIFF made on demand for
    /// apps that read only TIFF (a TIFF of a tall page is tens of MB, so it
    /// is made only if someone asks for it).
    static func copy(png: Data, to pasteboard: NSPasteboard) {
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        let provider = TIFFProvider(png: png)
        item.setDataProvider(provider, forTypes: [.tiff])
        TIFFProvider.current = provider
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// Where the window runs `save`, off the main thread and one at a time.
    static let saveQueue = DispatchQueue(label: "com.detourbrowser.capture-save", qos: .userInitiated)

    /// Writes `png` to `directory` under `name`, made unique so nothing is
    /// overwritten, and returns where it went.
    static func save(png: Data, name: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = CaptureFileName.unique(name, in: directory)
        try png.write(to: url, options: .withoutOverwriting)
        return url
    }

    /// Makes the TIFF from the PNG when a reader asks for it. Kept alive
    /// until the pasteboard is done with it (the next copy replaces it).
    private final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
        static var current: TIFFProvider?
        let png: Data

        init(png: Data) { self.png = png }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            guard type == .tiff, let tiff = Self.tiff(from: png) else { return }
            item.setData(tiff, forType: .tiff)
        }

        func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
            if Self.current === self { Self.current = nil }
        }

        /// LZW-compressed, keeping the PNG's DPI.
        static func tiff(from png: Data) -> Data? {
            guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil) else { return nil }
            var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return data as Data
        }
    }
}

/// Takes the dev toolbar's captures of a web view (TASK-186.3).
///
/// Visible area: `takeSnapshot` of the web view's bounds, so the dev toolbar
/// and a docked Web Inspector (siblings in the tab's container) are not in
/// it. Full page: WebKit's whole-document snapshot when the page is small
/// enough, else a PDF of the document rasterised at a capped scale
/// (`CaptureGeometry.fullPageMethod`). A snapshot rect larger than the view
/// does not work on macOS: WebKit paints only the visible part of it and
/// leaves the rest blank. Both are software paints in the page's process, so
/// WebGL and video do not show.
@MainActor
enum PageCapture {
    enum Kind: Equatable {
        case visible
        case fullPage
    }

    struct Result: Equatable {
        let png: Data
        let pixelWidth: Int
        let pixelHeight: Int
        /// The full page was taller (or wider) than the caps allow.
        let scaledDown: Bool
    }

    enum Failure: Error, Equatable {
        case noPage
        case snapshotFailed
        case encodingFailed
    }

    typealias Completion = (Swift.Result<Result, Failure>) -> Void

    /// WebKit can drop a snapshot or PDF request without answering (no
    /// local main frame); the capture then fails after this long instead of
    /// leaving its buttons disabled.
    static var timeout: TimeInterval = 60

    /// Captures `webView`; `completion` runs once, on the main thread.
    /// `fullPageMethod` forces a method, for tests.
    static func capture(_ kind: Kind, of webView: WKWebView,
                        fullPageMethod: CaptureGeometry.FullPageMethod? = nil,
                        completion: @escaping Completion) {
        guard webView.url != nil, !webView.bounds.isEmpty else {
            completion(.failure(.noPage))
            return
        }
        let once = Once(completion)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once.call(.failure(.snapshotFailed)) }
        switch kind {
        case .visible: captureVisible(webView, completion: once.call)
        case .fullPage: captureFullPage(webView, forcing: fullPageMethod, completion: once.call)
        }
    }

    private final class Once {
        private var completion: Completion?
        init(_ completion: @escaping Completion) { self.completion = completion }
        func call(_ result: Swift.Result<Result, Failure>) {
            guard let completion else { return }
            self.completion = nil
            completion(result)
        }
    }

    private static func captureVisible(_ webView: WKWebView, completion: @escaping Completion) {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        let pointWidth = webView.bounds.width
        webView.takeSnapshot(with: configuration) { image, _ in
            // The NSImage is sized in points; its CGImage is at device pixels.
            guard let image = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return completion(.failure(.snapshotFailed))
            }
            encode(dpi: CaptureGeometry.dpi(pixelWidth: image.width, pointWidth: pointWidth),
                   scaledDown: false, completion: completion) { image }
        }
    }

    /// The page's scroll size, viewport and device pixel ratio, read in an
    /// isolated world so the page's own scripts cannot change the answer.
    private static let metricsScript = """
        [document.documentElement.scrollWidth, document.documentElement.scrollHeight,
         document.documentElement.clientWidth, document.documentElement.clientHeight, window.devicePixelRatio]
        """

    private static func captureFullPage(_ webView: WKWebView, forcing forced: CaptureGeometry.FullPageMethod?,
                                        completion: @escaping Completion) {
        webView.evaluateJavaScript(metricsScript, in: nil, in: .defaultClient) { [weak webView] result in
            guard let webView else { return completion(.failure(.noPage)) }
            let zoom = Double(webView.pageZoom)
            let fallbackScale = webView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
            guard case .success(let value) = result,
                  let metrics = (value as? [NSNumber])?.map(\.doubleValue), metrics.count == 5, metrics[4] > 0 else {
                // No metrics: the PDF needs none, and its size is bounded.
                return captureFromPDF(webView, scale: fallbackScale, completion: completion)
            }
            let points = CaptureGeometry.documentPoints(scrollWidth: metrics[0], scrollHeight: metrics[1],
                                                        viewportWidth: metrics[2], viewportHeight: metrics[3],
                                                        pageZoom: zoom)
            // devicePixelRatio is the device scale times the page zoom.
            let scale = CGFloat(metrics[4] / (zoom > 0 ? zoom : 1))
            let method = forced ?? CaptureGeometry.fullPageMethod(points: points, scale: scale,
                                                                  contentsRectAvailable: supportsContentsRect)
            switch method {
            case .contentsRect: captureContentsRect(webView, scale: scale, completion: completion)
            case .pdf: captureFromPDF(webView, scale: scale, completion: completion)
            }
        }
    }

    // MARK: WebKit's whole-document snapshot

    private static let usesContentsRectSetter = NSSelectorFromString("_setUsesContentsRect:")

    /// `-[WKSnapshotConfiguration _setUsesContentsRect:]` (private, macOS
    /// 15+): WebKit snapshots its whole contents size, laid out as if the
    /// viewport were the whole document, at device scale.
    static var supportsContentsRect: Bool {
        WKSnapshotConfiguration.instancesRespond(to: usesContentsRectSetter)
    }

    private static func captureContentsRect(_ webView: WKWebView, scale: CGFloat, completion: @escaping Completion) {
        let configuration = WKSnapshotConfiguration()
        typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(configuration.method(for: usesContentsRectSetter), to: SetBool.self)(configuration, usesContentsRectSetter, true)
        webView.takeSnapshot(with: configuration) { image, _ in
            // Here WebKit sizes the NSImage in pixels; the CGImage is the snapshot.
            guard let raw = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let target = CaptureGeometry.pixelSize(points: CGSize(width: raw.width, height: raw.height), scale: 1) else {
                return completion(.failure(.snapshotFailed))
            }
            let dpi = 72 * scale * target.scale
            let scaledDown = target.pixelWidth != raw.width || target.pixelHeight != raw.height
            encode(dpi: dpi, scaledDown: scaledDown, completion: completion) {
                scaledDown ? CaptureImage.scaled(raw, width: target.pixelWidth, height: target.pixelHeight) : raw
            }
        }
    }

    // MARK: PDF

    private static func captureFromPDF(_ webView: WKWebView, scale: CGFloat, completion: @escaping Completion) {
        webView.createPDF(configuration: WKPDFConfiguration()) { result in
            guard case .success(let data) = result, let size = CaptureImage.pdfPageSize(data),
                  let output = CaptureGeometry.pixelSize(points: size, scale: scale) else {
                return completion(.failure(.snapshotFailed))
            }
            encode(dpi: 72 * output.scale, scaledDown: output.scale < scale - 0.001, completion: completion) {
                CaptureImage.rasterizePDF(data, output: output)
            }
        }
    }

    /// Makes the image (`make` scales or rasterises it, if need be) and its
    /// PNG in one trip off the main thread: both take a while for a tall page.
    private static func encode(dpi: CGFloat, scaledDown: Bool, completion: @escaping Completion,
                               image make: @escaping () -> CGImage?) {
        DispatchQueue.global(qos: .userInitiated).async {
            let image = make()
            let png = image.flatMap { CaptureImage.pngData($0, dpi: dpi) }
            DispatchQueue.main.async {
                guard let image, let png else { return completion(.failure(.encodingFailed)) }
                completion(.success(Result(png: png, pixelWidth: image.width, pixelHeight: image.height, scaledDown: scaledDown)))
            }
        }
    }
}
