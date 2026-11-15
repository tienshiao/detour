import CoreGraphics

/// How tall the Settings window's content area is for one pane, and how far
/// the user can drag it (TASK-189). All values are content heights: the
/// window's area below the toolbar, excluding the title bar and toolbar.
///
/// The window opens at the pane's natural height, but no taller than the
/// design maximum (TASK-347) or the screen; the user can drag it between
/// `minHeight` and `maxHeight` (the natural height capped to the screen);
/// below the natural height the pane scrolls.
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
        // Never open below an explicit minimum (a list pane's); a fixed pane
        // (no minimum) taller than the design maximum opens at it and scrolls.
        let openingFloor = minimum == nil ? 0 : floorHeight
        let initial = min(full, max(SettingsMetrics.designMaximumContentHeight, openingFloor))
        return SettingsPaneHeight(initial: initial, minHeight: min(floorHeight, cap, initial), maxHeight: full)
    }

    /// The height to take when the shown pane's fit changes from `old` to
    /// `new` (a row appeared, a list grew). A window still at its opening
    /// height follows the pane to the new opening height, and one dragged all
    /// the way open to the new maximum; one the user dragged elsewhere keeps
    /// its height, moved into the new bounds.
    static func refit(current: CGFloat, from old: SettingsPaneHeight, to new: SettingsPaneHeight) -> CGFloat {
        if abs(current - old.initial) < 0.5 { return new.initial }
        if abs(current - old.maxHeight) < 0.5 { return new.maxHeight }
        return min(max(current, new.minHeight), new.maxHeight)
    }
}
