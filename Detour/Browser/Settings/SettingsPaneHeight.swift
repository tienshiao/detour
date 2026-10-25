import CoreGraphics

/// How tall the Settings window's content area is for one pane, and how far
/// the user can drag it (TASK-189). All values are content heights: the
/// window's area below the toolbar, excluding the title bar and toolbar.
///
/// The window opens at the pane's natural height, capped to the screen; the
/// user can drag it between `minHeight` and `maxHeight`; beyond the cap the
/// pane scrolls.
struct SettingsPaneHeight: Equatable {
    /// The height the window takes when the pane is shown.
    var initial: CGFloat
    /// The smallest height the user can drag the window to.
    var minHeight: CGFloat
    /// The largest height the user can drag the window to.
    var maxHeight: CGFloat

    /// The tallest content height the screen allows.
    static func cap(screenUsableHeight: CGFloat, chromeHeight: CGFloat) -> CGFloat {
        max(floor(screenUsableHeight - chromeHeight - SettingsMetrics.screenMargin),
            SettingsMetrics.minimumCappedHeight)
    }

    /// - Parameters:
    ///   - natural: the pane's content height with nothing clipped or stretched.
    ///   - minimum: the pane's own minimum (list panes), or nil to use `natural`.
    ///   - screenUsableHeight: the height of the screen's visible frame.
    ///   - chromeHeight: the window's title bar and toolbar.
    static func fit(natural: CGFloat, minimum: CGFloat?, screenUsableHeight: CGFloat,
                    chromeHeight: CGFloat) -> SettingsPaneHeight {
        let cap = cap(screenUsableHeight: screenUsableHeight, chromeHeight: chromeHeight)
        let natural = ceil(natural)
        let floorHeight = minimum.map { ceil($0) } ?? natural
        let full = min(max(natural, floorHeight), cap)
        return SettingsPaneHeight(initial: full, minHeight: min(floorHeight, cap), maxHeight: full)
    }

    /// The height to take when the shown pane's fit changes from `old` to
    /// `new` (a row appeared, a list grew). A window still at its full height
    /// follows the pane to the new full height; one the user dragged shorter
    /// keeps its height, moved into the new bounds.
    static func refit(current: CGFloat, from old: SettingsPaneHeight, to new: SettingsPaneHeight) -> CGFloat {
        if abs(current - old.maxHeight) < 0.5 { return new.initial }
        return min(max(current, new.minHeight), new.maxHeight)
    }
}
