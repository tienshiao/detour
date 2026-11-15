import Foundation

/// The chip at the start of the palette's field, and the keys that leave it.
/// Two modes put one there: a site search (TASK-287) and a command that asks
/// for its space, tab or extension (TASK-320 AC #3). Both leave it the same
/// way, by these rules. Pure, so they can be tested without a window.
enum PaletteChip {

    /// A command's chip: which command the field is choosing an argument
    /// for, and what the user had typed when they chose it.
    struct CommandState: Equatable {
        let commandID: CommandID
        /// The typed text the command was chosen from (`>move`, `move to`),
        /// which Backspace puts back. Not the field's text: after arrowing
        /// to the command's row the field shows the row's title.
        let enteredText: String
    }

    /// Entering a command's chip from what was typed: the state, and the
    /// field's text in the mode (empty: it filters the choices).
    static func enter(_ commandID: CommandID, typedText: String) -> (state: CommandState, fieldText: String) {
        (CommandState(commandID: commandID, enteredText: typedText), "")
    }

    /// Whether Backspace leaves the chip: only with the caret at the start
    /// of the field and nothing selected; otherwise it edits the text.
    static func backspaceLeaves(selection: NSRange) -> Bool {
        selection == NSRange(location: 0, length: 0)
    }

    /// The field after Backspace leaves the chip: the text the mode was
    /// entered from, then a space and what was typed in the mode, if
    /// anything; the caret after the entered text (as Chrome leaves a site
    /// search). `caret` is in UTF-16 units, as the field editor counts.
    static func restoredField(enteredFrom entered: String, query: String) -> (text: String, caret: Int) {
        (query.isEmpty ? entered : entered + " " + query, entered.utf16.count)
    }

    enum EscapeAction: Equatable {
        /// Dismiss the palette.
        case dismiss
        /// Leave the chip's mode and clear the field.
        case leaveChip
        /// Drop the pending inline completion.
        case dropCompletion
        /// Clear the typed text.
        case clearField
    }

    /// What Escape does, staged: a palette that opened pre-filled (Cmd+L, the
    /// address bar) dismisses at once, chip or not; otherwise the chip goes
    /// first (clearing the field), then an inline completion, then the text,
    /// and only an empty palette is dismissed.
    static func escapeAction(wasPrepopulated: Bool, hasChip: Bool, hasCompletion: Bool,
                             fieldIsEmpty: Bool) -> EscapeAction {
        if wasPrepopulated { return .dismiss }
        if hasChip { return .leaveChip }
        if hasCompletion { return .dropCompletion }
        if !fieldIsEmpty { return .clearField }
        return .dismiss
    }
}
