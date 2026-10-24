import AppKit

/// Dev mode's "under construction" colours, defined once (TASK-197): the
/// sidebar's hazard border (`HazardBorderView`) and the dev toolbar's stripes
/// (`DevToolbarView`). Each colour may be dynamic; views resolve it against
/// their own appearance when they draw.
struct DevModePalette {
    /// The bright half of the hazard border: the solid stroke under the dashes.
    var hazard: NSColor
    /// The dark half: the dashes over the hazard stroke.
    var hazardDash: NSColor
    /// The dev toolbar's faint diagonal bands, over `DevToolbarView.backgroundColor`.
    var toolbarStripe: NSColor

    static let standard = DevModePalette(
        // The app icon's orange plate (Detour.icon, detour-orange.svg), so the
        // border reads as the brand's road-sign orange and black. Chosen over
        // systemYellow, which nearly vanished on the light sidebar (TASK-197).
        hazard: brandOrange,
        // Near-black in both appearances, slightly lifted in dark mode so the
        // dashes still separate from a dark sidebar.
        hazardDash: dynamic(light: NSColor(white: 0.1, alpha: 1), dark: NSColor(white: 0.05, alpha: 1)),
        toolbarStripe: dynamic(light: NSColor.black.withAlphaComponent(0.03),
                               dark: NSColor.white.withAlphaComponent(0.035))
    )

    /// rgb(255, 118, 0), the same in both appearances.
    static let brandOrange = NSColor(srgbRed: 1, green: 118 / 255, blue: 0, alpha: 1)

    /// The palette the views draw with.
    static var current: DevModePalette {
        #if DEBUG
        return debugOverride ?? standard
        #else
        return standard
        #endif
    }

    #if DEBUG
    /// Replaces the palette for runtime comparisons (a harness). Views pick it
    /// up when they next resolve their colours: `HazardBorderView.updateColors()`,
    /// or a redraw of `DevToolbarView`.
    static var debugOverride: DevModePalette?
    #endif

    /// A colour with one value for light appearances and one for dark.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in appearance.isDark ? dark : light }
    }
}
