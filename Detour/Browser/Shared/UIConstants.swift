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
}
