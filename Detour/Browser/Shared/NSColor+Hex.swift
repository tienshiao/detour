import AppKit

extension NSColor {
    convenience init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard hex.count == 6 else { return nil }
        var int: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&int) else { return nil }
        let r = CGFloat((int >> 16) & 0xFF) / 255.0
        let g = CGFloat((int >> 8) & 0xFF) / 255.0
        let b = CGFloat(int & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    func toHex() -> String {
        let rgb = usingColorSpace(.sRGB) ?? self
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "%02X%02X%02X", r, g, b)
    }

    /// Relative luminance (WCAG 2.0).
    var luminance: CGFloat {
        let rgb = usingColorSpace(.sRGB) ?? self
        func linearize(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(rgb.redComponent)
             + 0.7152 * linearize(rgb.greenComponent)
             + 0.0722 * linearize(rgb.blueComponent)
    }

    /// Returns a darkened variant if the color is too light for use on a light sidebar background.
    var sidebarSafe: NSColor {
        luminance > 0.7 ? blended(withFraction: 0.5, of: .black) ?? self : self
    }
}
