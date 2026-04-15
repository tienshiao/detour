import AppKit

enum UIConstants {
    static let hoverBackgroundColor = NSColor(name: nil) { appearance in
        let isDark = appearance.isDark
        return NSColor.labelColor.withAlphaComponent(isDark ? 0.10 : 0.06)
    }
    static let defaultCornerRadius: CGFloat = 6
}
