import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

// TASK-132.13: the CDP commands `chrome.debugger.sendCommand` runs. Each
// domain Detour emulates has a handler; a method none of them takes fails the
// way Chrome's protocol does, `{"code":-32601,"message":"'X' wasn't found"}`.
// Input (TASK-132.14) and Runtime (TASK-132.15) add their own domain files and
// one line each to `run`.

extension ExtensionDebugger {

    /// Runs `method` on `session`'s tab and answers `reply` once, with the
    /// result object or a protocol error. `reply` fails with "Detached while
    /// handling command." if the session ends first.
    func run(_ method: String, params: [String: Any], in session: ExtensionDebuggerSession,
             reply: ExtensionDebuggerReply) {
        session.track(reply)
        let handled: Bool
        switch method.prefix(while: { $0 != "." }) {
        case "Page": handled = ExtensionDebuggerPage.run(method, params: params, in: session, reply: reply)
        default: handled = false
        }
        if !handled {
            let error = Self.methodNotFound(method)
            reply.fail(code: error.code, message: error.message)
        }
    }
}

// MARK: - Page

enum ExtensionDebuggerPage {

    /// Returns false for a method this domain does not emulate.
    static func run(_ method: String, params: [String: Any], in session: ExtensionDebuggerSession,
                    reply: ExtensionDebuggerReply) -> Bool {
        switch method {
        case "Page.enable":
            session.enabledDomains.insert("Page")
            reply.succeed()
        case "Page.disable":
            session.enabledDomains.remove("Page")
            reply.succeed()
        case "Page.captureScreenshot":
            captureScreenshot(params: params, in: session, reply: reply)
        default:
            return false
        }
        return true
    }

    private static func captureScreenshot(params: [String: Any], in session: ExtensionDebuggerSession,
                                          reply: ExtensionDebuggerReply) {
        let request: ExtensionDebuggerScreenshot.Request
        switch ExtensionDebuggerScreenshot.Request.parse(params) {
        case .failure(let error):
            reply.fail(code: ExtensionDebugger.invalidParamsCode, message: error.message)
            return
        case .success(let parsed):
            request = parsed
        }
        guard let webView = session.tab?.automationDrivableWebView() else {
            reply.fail(code: ExtensionDebugger.serverErrorCode, message: ExtensionDebuggerScreenshot.unableError)
            return
        }
        Task {
            switch await ExtensionDebuggerScreenshot.capture(webView, request) {
            case .success(let data): reply.succeed(["data": data.base64EncodedString()])
            case .failure(let error): reply.fail(code: ExtensionDebugger.serverErrorCode, message: error.message)
            }
        }
    }
}

// MARK: - Screenshots

/// `Page.captureScreenshot` over `WKWebView.takeSnapshot`.
///
/// Geometry follows Chrome: `clip` is in CSS pixels of the document (scroll
/// offset included), and the image is `clip.width × clip.scale ×
/// devicePixelRatio` pixels wide — the viewport's CSS size × devicePixelRatio
/// without a clip — which is what the Claude extension checks the decoded
/// image against before it falls back to resizing. Only the viewport is
/// captured (`captureBeyondViewport` is not emulated): a clip reaching past it
/// shows nothing there.
enum ExtensionDebuggerScreenshot {

    nonisolated static let unableError = "Unable to capture screenshot"
    /// Larger than any real viewport at any scale; keeps a bad clip from
    /// asking for gigabytes.
    static let maximumPixelCount = 16384 * 16384 / 4
    static let snapshotTimeout: Duration = .seconds(15)

    nonisolated struct Failure: Error, Equatable {
        let message: String
    }

    nonisolated enum Format: String, Sendable {
        case png, jpeg, webp

        var type: UTType {
            switch self {
            case .png: .png
            case .jpeg: .jpeg
            case .webp: .webP
            }
        }
    }

    struct Clip: Equatable {
        let rect: CGRect
        let scale: Double
    }

    struct Request: Equatable {
        var format: Format = .png
        /// 0–100, JPEG and WebP only.
        var quality: Int?
        var clip: Clip?

        static func parse(_ params: [String: Any]) -> Result<Request, Failure> {
            var request = Request()
            if let value = params["format"], !(value is NSNull) {
                guard let name = value as? String, let format = Format(rawValue: name) else {
                    return .failure(Failure(message: "Invalid parameters: format: unknown value"))
                }
                request.format = format
            }
            if let value = params["quality"], !(value is NSNull) {
                guard let quality = number(value), quality >= 0, quality <= 100 else {
                    return .failure(Failure(message: "Invalid parameters: quality must be an integer from 0 to 100"))
                }
                request.quality = Int(quality.rounded())
            }
            if let value = params["clip"], !(value is NSNull) {
                guard let clip = value as? [String: Any],
                      let x = number(clip["x"]), let y = number(clip["y"]),
                      let width = number(clip["width"]), let height = number(clip["height"]) else {
                    return .failure(Failure(message: "Invalid parameters: clip needs x, y, width and height"))
                }
                let scale = clip["scale"].flatMap(number) ?? 1
                guard width > 0, height > 0, scale > 0 else {
                    return .failure(Failure(message: "Invalid parameters: clip must have a positive size and scale"))
                }
                request.clip = Clip(rect: CGRect(x: x, y: y, width: width, height: height), scale: scale)
            }
            return .success(request)
        }

        private static func number(_ value: Any?) -> Double? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
    }

    /// The page's layout viewport, in CSS pixels, as the page itself reports it.
    struct Viewport: Equatable {
        var width: Double
        var height: Double
        var scrollX: Double
        var scrollY: Double
        var devicePixelRatio: Double
    }

    struct Geometry: Equatable {
        /// What to snapshot, in the web view's coordinates (points).
        let rect: CGRect
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// Where `request` falls in a web view of `viewSize` points showing
    /// `viewport`, and how many pixels the image has. Nil for a degenerate
    /// viewport or an image too large to make.
    static func geometry(_ request: Request, viewport: Viewport, viewSize: CGSize) -> Geometry? {
        guard viewport.width > 0, viewport.height > 0, viewSize.width > 0, viewSize.height > 0,
              viewport.devicePixelRatio > 0 else { return nil }
        // Points per CSS pixel: 1 at 100% zoom, more when zoomed in.
        let pointsPerCSSPixel = viewSize.width / viewport.width
        let cssRect: CGRect
        let scale: Double
        if let clip = request.clip {
            cssRect = clip.rect.offsetBy(dx: -viewport.scrollX, dy: -viewport.scrollY)
            scale = clip.scale
        } else {
            cssRect = CGRect(x: 0, y: 0, width: viewport.width, height: viewport.height)
            scale = 1
        }
        let rect = CGRect(x: cssRect.minX * pointsPerCSSPixel, y: cssRect.minY * pointsPerCSSPixel,
                          width: cssRect.width * pointsPerCSSPixel, height: cssRect.height * pointsPerCSSPixel)
        // Bounded in Double first: a huge clip or scale from the extension
        // would trap converting to Int, or multiplying the two Ints.
        let width = max(1, (cssRect.width * scale * viewport.devicePixelRatio).rounded())
        let height = max(1, (cssRect.height * scale * viewport.devicePixelRatio).rounded())
        guard width.isFinite, height.isFinite, width * height <= Double(maximumPixelCount) else { return nil }
        return Geometry(rect: rect, pixelWidth: Int(width), pixelHeight: Int(height))
    }

    /// The encoded image.
    static func capture(_ webView: WKWebView, _ request: Request) async -> Result<Data, Failure> {
        let viewSize = webView.bounds.size
        let backingScale = webView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let viewport = await readViewport(webView)
            ?? Viewport(width: viewSize.width, height: viewSize.height, scrollX: 0, scrollY: 0,
                        devicePixelRatio: backingScale)
        guard let geometry = geometry(request, viewport: viewport, viewSize: viewSize) else {
            return .failure(Failure(message: unableError))
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = geometry.rect
        // Ask for about the final resolution; the exact size is drawn below.
        configuration.snapshotWidth = NSNumber(value: Double(geometry.pixelWidth) / Double(backingScale))
        guard let image = await snapshot(webView, configuration),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .failure(Failure(message: unableError))
        }
        let format = request.format
        let quality = request.quality
        let width = geometry.pixelWidth
        let height = geometry.pixelHeight
        return await Task.detached(priority: .userInitiated) {
            encode(cgImage, width: width, height: height, format: format, quality: quality)
        }.value
    }

    /// `takeSnapshot`, given up on after `snapshotTimeout`.
    private static func snapshot(_ webView: WKWebView, _ configuration: WKSnapshotConfiguration) async -> NSImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            var finished = false
            var timeout: Task<Void, Never>?
            let finish: (NSImage?) -> Void = { image in
                guard !finished else { return }
                finished = true
                // The snapshot answered: no timer left sleeping per capture.
                timeout?.cancel()
                continuation.resume(returning: image)
            }
            timeout = Task {
                guard (try? await Task.sleep(for: snapshotTimeout)) != nil else { return }
                finish(nil)
            }
            webView.takeSnapshot(with: configuration) { image, _ in finish(image) }
        }
    }

    /// The viewport as the page's main frame reports it, read in a world of
    /// Detour's own so the page cannot see or intercept the question. Nil when
    /// the page cannot answer (between documents).
    private static func readViewport(_ webView: WKWebView) async -> Viewport? {
        let script = "return [innerWidth, innerHeight, scrollX, scrollY, devicePixelRatio];"
        let answer = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil,
                                                            contentWorld: ExtensionDebugger.contentWorld)
        guard let values = answer as? [NSNumber], values.count == 5 else { return nil }
        let numbers = values.map(\.doubleValue)
        guard numbers.allSatisfy(\.isFinite) else { return nil }
        return Viewport(width: numbers[0], height: numbers[1], scrollX: numbers[2], scrollY: numbers[3],
                        devicePixelRatio: numbers[4])
    }

    /// Draws `image` at exactly `width` × `height` pixels and encodes it.
    nonisolated static func encode(_ image: CGImage, width: Int, height: Int, format: Format,
                                   quality: Int?) -> Result<Data, Failure> {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return .failure(Failure(message: unableError))
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if format == .jpeg {
            // JPEG has no alpha: what shows through is white, as in Chrome.
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(bounds)
        }
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        guard let drawn = context.makeImage() else { return .failure(Failure(message: unableError)) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else {
            return .failure(Failure(message: "Unsupported image format: \(format.rawValue)"))
        }
        var properties: [CFString: Any] = [:]
        if format != .png {
            // Chrome's default quality is 80 for JPEG.
            properties[kCGImageDestinationLossyCompressionQuality] = Double(quality ?? 80) / 100
        }
        CGImageDestinationAddImage(destination, drawn, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return .failure(Failure(message: unableError)) }
        return .success(data as Data)
    }
}

extension ExtensionDebugger {
    /// The content world Detour's own page reads (the viewport, and later
    /// TASK-132.15's evaluation plumbing) run in.
    static let contentWorld = WKContentWorld.world(name: "DetourDebugger")
}
