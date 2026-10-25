import AppKit

/// The spacing every Settings pane uses (TASK-189). Panes take their margins,
/// gaps, column widths and list sizes from here rather than from local
/// constants, so the panes read as one window.
enum SettingsMetrics {
    /// The window's width. The window resizes in height only.
    static let windowWidth: CGFloat = 740

    /// Space between the pane's content and the window's edges.
    static let paneMargin: CGFloat = 20
    /// Space between two sections of a pane, and between a list and its detail column.
    static let sectionGap: CGFloat = 20
    /// Space from the pane's description text to the content below it.
    static let descriptionToBody: CGFloat = 12
    /// Space between two rows of controls.
    static let rowGap: CGFloat = 10
    /// Space from a control to the help text that belongs to it.
    static let controlToHelp: CGFloat = 4
    /// Space from a row's label to its control.
    static let labelToControl: CGFloat = 8
    /// Width of the right-aligned label column, shared by every pane that has one.
    static let labelColumnWidth: CGFloat = 124
    /// Width of text fields and the cap on pop-up buttons in a detail column.
    static let fieldWidth: CGFloat = 260

    /// Width of the master list (Spaces, Profiles, Extensions).
    static let listWidth: CGFloat = 220
    /// Row height of the master lists.
    static let listRowHeight: CGFloat = 28
    /// Size of the add / remove buttons under a list.
    static let listButtonSize: CGFloat = 24
    /// Height of the bar under a list: separator, padding, buttons, padding.
    static let listBarHeight: CGFloat = 1 + 2 + listButtonSize + 2
    static let listCornerRadius: CGFloat = 4
    /// Width of the detail column beside a master list.
    static let detailColumnWidth: CGFloat = windowWidth - 2 * paneMargin - listWidth - sectionGap

    /// The smallest content height of a pane with a master list; other panes
    /// use their natural height as their minimum.
    static let listPaneMinimumHeight: CGFloat = 400
    /// How far the tallest window stays short of the screen's usable height.
    static let screenMargin: CGFloat = 80
    /// The smallest content height the screen cap can come down to, so a
    /// tiny or misreported screen still leaves a usable window.
    static let minimumCappedHeight: CGFloat = 200
}
