import CoreGraphics

/// A page of the sidebar's horizontal page strip.
enum SidebarPage: Equatable {
    /// The Archived Tabs page (TASK-119), left of the first space.
    case archive
    /// The page of the space at this index of the sidebar's space list.
    case space(Int)
}

/// Maps between pages and strip positions. Non-incognito sidebars put the
/// Archived Tabs page at strip index 0, so space `i` sits at `i + 1`; an
/// incognito sidebar has no archive page and space `i` sits at `i`. Every strip
/// x the sidebar computes goes through here, so the offset lives in one place.
struct SidebarPageStrip: Equatable {
    let hasArchivePage: Bool
    let spaceCount: Int

    private var offset: Int { hasArchivePage ? 1 : 0 }

    var pageCount: Int { spaceCount + offset }

    func stripIndex(for page: SidebarPage) -> Int {
        switch page {
        case .archive: return 0
        case .space(let index): return index + offset
        }
    }

    /// The page at a strip index, or nil outside the strip.
    func page(atStripIndex index: Int) -> SidebarPage? {
        guard index >= 0, index < pageCount else { return nil }
        if hasArchivePage && index == 0 { return .archive }
        return .space(index - offset)
    }

    /// The bottom bar's fractional space-button index for a fractional strip
    /// position. Negative while the strip moves onto the archive page (-1 once
    /// it is there), which has no button.
    func spaceButtonIndex(forFractionalStripIndex index: CGFloat) -> CGFloat {
        index - CGFloat(offset)
    }

    /// Where the chrome that belongs to the space pages but stays put between
    /// them (the address bar) sits, given the strip's x in the clip view: at 0
    /// on any space page, and riding the first space's page on its way to and
    /// from the archive page, fully off to the right (`pageWidth`) once the
    /// archive shows. Always 0 without an archive page.
    func spaceChromeX(forStripX stripX: CGFloat, pageWidth: CGFloat) -> CGFloat {
        guard hasArchivePage else { return 0 }
        return max(0, stripX + CGFloat(stripIndex(for: .space(0))) * pageWidth)
    }
}
