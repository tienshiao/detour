import AppKit

extension TabGroupColor {
    /// How the sidebar draws each of Chrome's nine group colour names: the
    /// macOS system colour of the same name (TASK-132.11). System colours are
    /// dynamic, so they have light, dark and increased-contrast variants made
    /// to read on the system's own backgrounds, which the sidebar is.
    var displayColor: NSColor {
        switch self {
        case .grey: return .systemGray
        case .blue: return .systemBlue
        case .red: return .systemRed
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .pink: return .systemPink
        case .purple: return .systemPurple
        case .cyan: return .systemCyan
        case .orange: return .systemOrange
        }
    }
}

/// A rectangle filled with a tab group's colour: the stripe on a member's
/// sidebar row, and the dot beside the group's title on the hover card.
/// The colour is resolved in `updateLayer`, which AppKit runs again when the
/// effective appearance changes, so a dynamic colour follows light and dark.
final class TabGroupColorView: NSView {
    var color: TabGroupColor? {
        didSet { if color != oldValue { needsDisplay = true } }
    }
    var cornerRadius: CGFloat = 0 {
        didSet { if cornerRadius != oldValue { needsDisplay = true } }
    }
    /// Which corners `cornerRadius` rounds, in the layer's coordinates.
    var roundedCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                        .layerMinXMaxYCorner, .layerMaxXMaxYCorner] {
        didSet { if roundedCorners != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Resolved against the plain light or dark appearance (keeping
        // increased contrast): a selected table row gives its subviews a
        // variant in which system colours come out lighter, and a group's
        // stripe must be one colour from row to row.
        let names: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                          .accessibilityHighContrastDarkAqua]
        let appearance = effectiveAppearance.bestMatch(from: names).flatMap(NSAppearance.init(named:))
            ?? effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color?.displayColor.cgColor
        }
        layer?.cornerRadius = cornerRadius
        layer?.maskedCorners = roundedCorners
    }

    /// Decoration only: clicks go to the row underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
