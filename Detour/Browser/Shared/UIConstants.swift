import AppKit

enum UIConstants {
    static let hoverBackgroundColor = NSColor(name: nil) { appearance in
        let isDark = appearance.isDark
        return NSColor.labelColor.withAlphaComponent(isDark ? 0.10 : 0.06)
    }
    static let defaultCornerRadius: CGFloat = 6

    // Split drop-target highlight, shared by the sidebar's half-row overlay and
    // the content area's edge-zone preview so the two affordances can't drift.
    static let splitDropAccentFillColor = NSColor.controlAccentColor.withAlphaComponent(0.18)
    static let splitDropAccentBorderColor = NSColor.controlAccentColor.withAlphaComponent(0.6)
    static let splitDropAccentBorderWidth: CGFloat = 1.5

    // Hosted split pane chrome. Shared with the content-area drop-zone preview
    // so the preview shows exactly where the panes will land: at a 50/50 split,
    // an inset split view with a `splitPaneGap`-thick invisible divider puts
    // each pane `splitPaneGap / 2` off the midline — the preview geometry.
    //
    // On macOS 26 (Tahoe) ONLY, the window corner radius is 26pt (measured via
    // the theme frame's cornerRadius): the inset matches the sidebar's 10pt
    // content inset, and radius = 26 − 10 keeps the right pane's rounded
    // corners concentric with the window's. macOS 27 (Golden Gate) and earlier
    // systems have smaller window corners, where the 8pt/8pt card looks right.
    private static let isTahoe: Bool = {
        if #available(macOS 27.0, *) { return false }
        if #available(macOS 26.0, *) { return true }
        return false
    }()
    static let splitPaneInset: CGFloat = isTahoe ? 10 : 8
    static let splitPaneGap: CGFloat = 8
    static let splitPaneCornerRadius: CGFloat = isTahoe ? 16 : 8
    /// Focused-pane border: black in light mode, white in dark — a pure black
    /// border would vanish against dark web content and the dark gutter.
    static let splitPaneFocusBorderColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.85)
                          : NSColor.black.withAlphaComponent(0.8)
    }
    /// Soft drop shadow lifting each pane card off the gutter background.
    static let splitPaneShadowOpacity: Float = 0.25
    static let splitPaneShadowRadius: CGFloat = 5
    static let splitPaneShadowOffset = CGSize(width: 0, height: -2)
}
