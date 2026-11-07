import AppKit

/// A site's color, taken from its favicon (TASK-290): what the site-search
/// chip is filled with, as Arc colors a site by its icon. Pure over pixels so
/// the rule is testable without images.
nonisolated enum SiteColor {
    /// sRGB, each component in 0...1.
    struct RGB: Equatable, Sendable {
        var red: Double
        var green: Double
        var blue: Double
    }

    /// The side of the square an icon is drawn at before it is read: enough
    /// to see a logo's colors, few enough pixels to read on the main thread.
    static let sampleSide = 16

    /// Pixels less opaque than this are background, not the logo.
    static let minimumAlpha = 0.5
    /// Pixels less saturated than this, or darker than `minimumBrightness`,
    /// are greys, black or white: a logo's outline or background, not its color.
    static let minimumSaturation = 0.25
    static let minimumBrightness = 0.2
    /// The winning hue's share of the opaque pixels below which the icon has
    /// no clear color (a grey logo with a small colored detail).
    static let minimumShare = 0.1
    static let hueBuckets = 12

    /// The dominant color of `rgba` (non-premultiplied sRGB bytes, four per
    /// pixel): the opaque, saturated pixels are grouped into `hueBuckets`
    /// hues, weighted by saturation, and the heaviest group gives the color:
    /// the average of its pixels within `saturationBand` of its most
    /// saturated one, so a logo's anti-aliased edges against white (pinker,
    /// paler pixels of the same hue) do not wash it out. Nil when the icon is
    /// transparent, grey, black-and-white, or its colored pixels are too few.
    static func dominant(rgba: [UInt8]) -> RGB? {
        var weights = [Double](repeating: 0, count: hueBuckets)
        var members = [[(color: RGB, saturation: Double)]](repeating: [], count: hueBuckets)
        var opaque = 0
        var index = 0
        while index + 3 < rgba.count {
            let alpha = Double(rgba[index + 3]) / 255
            if alpha >= minimumAlpha {
                opaque += 1
                let color = RGB(red: Double(rgba[index]) / 255, green: Double(rgba[index + 1]) / 255,
                                blue: Double(rgba[index + 2]) / 255)
                let (hue, saturation, brightness) = hsb(color)
                if saturation >= minimumSaturation, brightness >= minimumBrightness {
                    // Buckets centered on their hues (red is 345-15 degrees),
                    // so a red logo is not split across the 0/360 seam.
                    let bucket = Int(hue * Double(hueBuckets) + 0.5) % hueBuckets
                    weights[bucket] += saturation
                    members[bucket].append((color, saturation))
                }
            }
            index += 4
        }
        guard opaque > 0, let best = weights.indices.max(by: { weights[$0] < weights[$1] }),
              !members[best].isEmpty, Double(members[best].count) / Double(opaque) >= minimumShare
        else { return nil }
        let strongest = members[best].map(\.saturation).max() ?? 0
        let core = members[best].filter { $0.saturation >= strongest - saturationBand }
        let n = Double(core.count)
        return RGB(red: core.map(\.color.red).reduce(0, +) / n,
                   green: core.map(\.color.green).reduce(0, +) / n,
                   blue: core.map(\.color.blue).reduce(0, +) / n)
    }

    /// How far below the winning hue's most saturated pixel a pixel may be
    /// and still count towards the color.
    static let saturationBand = 0.15

    /// `image`'s dominant color, read from a `sampleSide` square drawing of it.
    static func dominant(in image: NSImage) -> RGB? {
        let side = sampleSide
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        let bytes = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var rgba = [UInt8](UnsafeBufferPointer(start: bytes, count: side * side * 4))
        // Un-premultiply, so a half-transparent edge reads as its own color.
        var index = 0
        while index + 3 < rgba.count {
            let alpha = Int(rgba[index + 3])
            if alpha > 0, alpha < 255 {
                for c in 0..<3 { rgba[index + c] = UInt8(min(255, Int(rgba[index + c]) * 255 / alpha)) }
            }
            index += 4
        }
        return dominant(rgba: rgba)
    }

    /// Whether the chip's text is dark rather than white on `fill`: white
    /// unless its contrast falls below 3:1, WCAG's minimum for large and bold
    /// text. Picking the higher contrast would put black on YouTube's red and
    /// the system blue, where white is what Arc and macOS use.
    static func prefersDarkText(on fill: RGB) -> Bool {
        contrastAgainstWhite(fill) < 3
    }

    static func contrastAgainstWhite(_ fill: RGB) -> Double {
        1.05 / (relativeLuminance(fill) + 0.05)
    }

    static func relativeLuminance(_ color: RGB) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    static func hsb(_ color: RGB) -> (hue: Double, saturation: Double, brightness: Double) {
        let maxC = max(color.red, color.green, color.blue), minC = min(color.red, color.green, color.blue)
        let delta = maxC - minC
        let saturation = maxC == 0 ? 0 : delta / maxC
        guard delta > 0 else { return (0, saturation, maxC) }
        var hue: Double
        if maxC == color.red {
            hue = (color.green - color.blue) / delta
        } else if maxC == color.green {
            hue = 2 + (color.blue - color.red) / delta
        } else {
            hue = 4 + (color.red - color.green) / delta
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, saturation, maxC)
    }
}

extension SiteColor.RGB {
    nonisolated init?(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(red: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent))
    }

    nonisolated var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1)
    }
}
