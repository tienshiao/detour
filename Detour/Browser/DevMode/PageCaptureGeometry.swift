import AppKit

/// The pixel math of the dev toolbar's captures (TASK-186.3): the PNG is at
/// device pixels (a 1000 x 700 pt pane on a 2x display gives 2000 x 1400 px),
/// scaled down, never up, to fit `maxPixelEdge` and `maxPixelArea`.
enum CaptureGeometry {
    /// The longest edge a capture may have. 16384 px is the texture limit of
    /// most GPUs and about the largest image browsers, chat clients and
    /// design tools take on paste without refusing or shrinking it; a longer
    /// page is scaled down to it.
    static let maxPixelEdge = 16384
    /// The most pixels a capture, or the raw full-page snapshot it is made
    /// from, may have: 2^26 px (8192 x 8192) is 256 MB of RGBA, which the
    /// page's process paints and the app then copies and encodes.
    static let maxPixelArea = 1 << 26

    struct Output: Equatable {
        let pixelWidth: Int
        let pixelHeight: Int
        /// Output pixels per point.
        let scale: CGFloat
    }

    /// The image size for `points` at `scale` pixels per point, scaled down
    /// to fit the caps. Nil for an empty size.
    static func pixelSize(points: CGSize, scale: CGFloat,
                          maxEdge: Int = maxPixelEdge, maxArea: Int = maxPixelArea) -> Output? {
        guard points.width > 0, points.height > 0, scale > 0 else { return nil }
        let rawWidth = points.width * scale
        let rawHeight = points.height * scale
        let factor = min(1,
                         CGFloat(maxEdge) / max(rawWidth, rawHeight),
                         (CGFloat(maxArea) / (rawWidth * rawHeight)).squareRoot())
        let outScale = scale * factor
        func size(_ rule: FloatingPointRoundingRule) -> (Int, Int) {
            let width = Int((points.width * outScale).rounded(rule))
            let height = Int((points.height * outScale).rounded(rule))
            return (max(1, min(maxEdge, width)), max(1, min(maxEdge, height)))
        }
        var (width, height) = size(.toNearestOrAwayFromZero)
        if width * height > maxArea { (width, height) = size(.down) }
        return Output(pixelWidth: width, pixelHeight: height, scale: outScale)
    }

    /// How the full page is captured. `contentsRect`: WebKit's own
    /// whole-document snapshot (`_usesContentsRect`), the same paint as the
    /// visible capture, but always at device scale (it ignores
    /// `snapshotWidth`), so it is used only while that raw image stays
    /// within `maxRawArea`, and scaled down afterwards to the caps. `pdf`: the
    /// document as a PDF (`createPDF`), rasterised straight at the capped
    /// size; it loses CSS `filter` effects, so it is the fallback.
    enum FullPageMethod: Equatable {
        case contentsRect
        case pdf
    }

    static func fullPageMethod(points: CGSize, scale: CGFloat, contentsRectAvailable: Bool,
                               maxRawArea: Int = maxPixelArea) -> FullPageMethod {
        guard contentsRectAvailable else { return .pdf }
        let rawArea = (points.width * scale) * (points.height * scale)
        return rawArea <= CGFloat(maxRawArea) ? .contentsRect : .pdf
    }

    /// The document's size in points from the page's metrics in CSS pixels:
    /// its scroll size, at least the viewport, times the page zoom.
    static func documentPoints(scrollWidth: Double, scrollHeight: Double,
                               viewportWidth: Double, viewportHeight: Double, pageZoom: Double) -> CGSize {
        let zoom = pageZoom > 0 ? pageZoom : 1
        return CGSize(width: max(scrollWidth, viewportWidth) * zoom,
                      height: max(scrollHeight, viewportHeight) * zoom)
    }

    /// The PNG's resolution, so it previews at the page's size in points:
    /// 72 dpi per pixel per point (144 at 2x).
    static func dpi(pixelWidth: Int, pointWidth: CGFloat) -> CGFloat {
        guard pointWidth > 0 else { return 72 }
        return 72 * CGFloat(pixelWidth) / pointWidth
    }
}

/// The name of a capture saved to Downloads: "Screenshot localhost-3000
/// 2026-10-24 at 21.05.03.png", "... (full page).png", made unique with
/// " (2)", " (3)" ... so a capture never overwrites a file.
enum CaptureFileName {
    static func make(host: String, date: Date, fullPage: Bool, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        // A colon is a path separator to Finder, which shows it as a slash.
        let safeHost = host.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
        var parts = ["Screenshot"]
        if !safeHost.isEmpty { parts.append(safeHost) }
        parts.append(formatter.string(from: date))
        if fullPage { parts.append("(full page)") }
        return parts.joined(separator: " ") + ".png"
    }

    /// The first of `name`, "name (2)", "name (3)" ... (before the extension)
    /// in `directory` that does not exist.
    static func unique(_ name: String, in directory: URL,
                       exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var number = 2
        while exists(candidate) {
            candidate = directory.appendingPathComponent("\(base) (\(number))" + (ext.isEmpty ? "" : ".\(ext)"))
            number += 1
        }
        return candidate
    }
}
