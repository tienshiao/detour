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
    /// Width of text fields (Spaces' and Profiles' name, Profiles' custom
    /// user agent) and the cap on pop-up buttons in a detail column.
    static let fieldWidth: CGFloat = 260

    /// Width of the master list (Spaces, Profiles, Extensions).
    static let listWidth: CGFloat = 220
    /// Row height of the master lists.
    static let listRowHeight: CGFloat = 28
    /// Size of the add / remove buttons under a list.
    static let listButtonSize: CGFloat = 24
    /// Height of the bar under a list: separator, padding, buttons, padding.
    static let listBarHeight: CGFloat = 1 + 2 + listButtonSize + 2
    /// Width of the detail column beside a master list.
    static let detailColumnWidth: CGFloat = windowWidth - 2 * paneMargin - listWidth - sectionGap

    /// The smallest content height of a pane with a master list; other panes
    /// use their natural height as their minimum.
    static let listPaneMinimumHeight: CGFloat = 400
    /// The tallest content height a pane opens at, whatever the screen
    /// (TASK-347): a taller pane scrolls, and the user can drag the window
    /// taller, up to the screen's cap. Tall enough that a normal profile's
    /// Profiles pane (709) opens whole.
    static let designMaximumContentHeight: CGFloat = 720
    /// How far the tallest window stays short of the screen's usable height.
    static let screenMargin: CGFloat = 80
    /// The smallest content height the screen cap can come down to, so a
    /// tiny or misreported screen still leaves a usable window.
    static let minimumCappedHeight: CGFloat = 200

    // MARK: Grouped form (TASK-338)
    // Measured on macOS 26 from a SwiftUI grouped `Form` (what System
    // Settings is built with) and from a System Settings screenshot.

    /// A form's width in a pane's body.
    static let formWidth: CGFloat = windowWidth - 2 * paneMargin
    /// A row's name and a section's header; help text and footnotes.
    static let formTitleFontSize: CGFloat = 13
    static let formHelpFontSize: CGFloat = 11
    /// From a group (or the buttons under it) to the next section's header.
    static let formSectionGap: CGFloat = 30
    /// Added to `descriptionToBody` above a form: its first header sits 20
    /// pt under the pane's description or Learn more link.
    static let formBelowPaneHeader: CGFloat = 8
    /// From a section's header to its group.
    static let formHeaderToGroup: CGFloat = 10
    static let formGroupCornerRadius: CGFloat = 12
    /// A row's text and its control from the group's sides; the separators
    /// are inset as far.
    static let formRowInsetX: CGFloat = 10
    /// A row's text from the row's top and bottom.
    static let formRowInsetY: CGFloat = 10
    /// A control from the row's top and bottom, at least; a push button 10
    /// (System Settings' button rows are 44 pt, its pop-up rows 38).
    static let formControlInsetY: CGFloat = 7
    static let formButtonInsetY: CGFloat = 10
    /// The text column's end to the control.
    static let formLabelToControl: CGFloat = 16
    /// A row's name to its help text, and between the lines under it.
    static let formTitleToHelp: CGFloat = 3
    /// From a group to the buttons under it, and between those buttons.
    static let formGroupToButtons: CGFloat = 10
    static let formButtonGap: CGFloat = 8
}
